use super::*;
use axum::{
    extract::{
        ws::{Message as SocketMessage, WebSocketUpgrade},
        State,
    },
    http::StatusCode,
    routing::get,
    Json, Router,
};
use futures_util::SinkExt;
use std::sync::atomic::{AtomicUsize, Ordering};

#[derive(Clone)]
struct Fixture {
    id: String,
    key: String,
    authentications: Arc<AtomicUsize>,
    approve: Arc<tokio::sync::Notify>,
    reject: bool,
    discoveries: Arc<AtomicUsize>,
    controls: Arc<AtomicUsize>,
    mutations: Arc<AtomicUsize>,
    close: tokio::sync::broadcast::Sender<()>,
}
struct Server {
    url: String,
    fixture: Fixture,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}
async fn server(id: &str, reject: bool) -> Server {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/", listener.local_addr().unwrap());
    let (close, _) = tokio::sync::broadcast::channel(8);
    let fixture = Fixture {
        id: id.into(),
        key: fixture_key(id),
        authentications: Arc::default(),
        approve: Arc::default(),
        reject,
        discoveries: Arc::default(),
        controls: Arc::default(),
        mutations: Arc::default(),
        close,
    };
    async fn info(
        State(f): State<Fixture>,
        headers: axum::http::HeaderMap,
    ) -> Json<serde_json::Value> {
        assert!(headers.get("authorization").is_none());
        f.discoveries.fetch_add(1, Ordering::SeqCst);
        Json(
            serde_json::json!({"server_id": f.id, "protocol_version": 1, "encryption": pirc_crypto::SUBPROTOCOL}),
        )
    }
    async fn control(State(f): State<Fixture>, ws: WebSocketUpgrade) -> axum::response::Response {
        use axum::response::IntoResponse;
        f.controls.fetch_add(1, Ordering::SeqCst);
        if f.reject {
            return StatusCode::UNAUTHORIZED.into_response();
        }
        ws.protocols([pirc_crypto::SUBPROTOCOL]).on_upgrade(move |mut socket| async move {
            let mut close = f.close.subscribe();
            let Some(Ok(SocketMessage::Binary(first))) = socket.recv().await else { return; };
            let mut h = pirc_crypto::handshake(&f.key, false).unwrap();
            let mut out = vec![0; 65535]; let mut wire = vec![0; 65535];
            h.read_message(&first, &mut out).unwrap();
            let n = h.write_message(f.id.as_bytes(), &mut wire).unwrap();
            socket.send(SocketMessage::Binary(wire[..n].to_vec().into())).await.unwrap();
            let Some(Ok(SocketMessage::Binary(third))) = socket.recv().await else { return; };
            h.read_message(&third, &mut out).unwrap();
            let pairing_code = pirc_crypto::pairing_code(h.get_handshake_hash());
            let mut channel = pirc_crypto::Channel::new(h).unwrap();
            let Some(Ok(SocketMessage::Binary(auth))) = socket.recv().await else { return; };
            let mut decoded = channel.decrypt(&auth).unwrap();
            if matches!(Envelope::decode(&decoded).unwrap().message, Message::PairingRequest {}) {
                let code = if f.id == "bad-code" { "AAAA-AAAA".into() } else { pairing_code };
                let required = packet(Message::PairingRequired { code, expires_in: 300 });
                socket.send(SocketMessage::Binary(channel.encrypt(&serde_json::to_string(&required).unwrap()).unwrap().into())).await.unwrap();
                f.approve.notified().await;
                let approved = packet(Message::PairingApproved {});
                if socket.send(SocketMessage::Binary(channel.encrypt(&serde_json::to_string(&approved).unwrap()).unwrap().into())).await.is_err() { return; }
                let Some(Ok(SocketMessage::Binary(auth))) = socket.recv().await else { return; };
                decoded = channel.decrypt(&auth).unwrap();
            }
            assert!(matches!(Envelope::decode(&decoded).unwrap().message, Message::Auth {..}));
            f.authentications.fetch_add(1, Ordering::SeqCst);
            let welcome = packet(Message::Welcome { server_id: Some(f.id), generation_id: "g".into(), history_paging: true });
            socket.send(SocketMessage::Binary(channel.encrypt(&serde_json::to_string(&welcome).unwrap()).unwrap().into())).await.unwrap();
            socket.send(SocketMessage::Binary(channel.encrypt(&serde_json::to_string(&packet(Message::Sessions { sessions: vec![] })).unwrap()).unwrap().into())).await.unwrap();
            loop {
                tokio::select! {
                    _ = close.recv() => { let _ = socket.close().await; break; },
                    incoming = socket.recv() => match incoming {
                        Some(Ok(SocketMessage::Binary(bytes))) => {
                            let text = channel.decrypt(&bytes).unwrap();
                            let e = Envelope::decode(&text).unwrap();
                            if matches!(e.message, Message::CreateDirectory { .. }) { f.mutations.fetch_add(1, Ordering::SeqCst); }
                        },
                        Some(Ok(SocketMessage::Ping(p))) => { let _ = socket.send(SocketMessage::Pong(p)).await; },
                        Some(Ok(SocketMessage::Close(_))) | Some(Err(_)) | None => break,
                        _ => {},
                    }
                }
            }
        })
    }
    let router = Router::new()
        .route("/pirc/info", get(info))
        .route("/control", get(control))
        .with_state(fixture.clone());
    let task = tokio::spawn(async move {
        axum::serve(listener, router).await.unwrap();
    });
    Server { url, fixture, task }
}
fn client(urls: Vec<String>, expected: Option<String>) -> (Client, tokio::task::JoinHandle<()>) {
    let (actions, rx) = mpsc::channel(32);
    let (updates, changes) = watch::channel(0);
    let state = Arc::new(Mutex::new(Projection::default()));
    let task = tokio::spawn(worker(
        urls,
        expected,
        vec![],
        pirc_crypto::generate_key().unwrap(),
        Some(pirc_crypto::public_key(&fixture_key("computer")).unwrap()),
        rx,
        state.clone(),
        updates,
    ));
    (
        Client {
            actions,
            state,
            changes,
        },
        task,
    )
}
async fn until(client: &Client, predicate: impl Fn(&View) -> bool) {
    let mut changes = client.subscribe();
    tokio::time::timeout(Duration::from_secs(4), async {
        loop {
            if predicate(&client.view()) {
                break;
            }
            changes.changed().await.unwrap();
        }
    })
    .await
    .unwrap();
}
#[tokio::test]
async fn cold_start_falls_back_and_binds_the_computer() {
    let dead = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let unavailable = format!("http://{}", dead.local_addr().unwrap());
    drop(dead);
    let b = server("computer", false).await;
    let (c, task) = client(vec![unavailable, b.url.clone()], None);
    until(&c, |v| v.connection == "connected").await;
    assert_eq!(c.view().current_address, Some(b.url.clone()));
    assert_eq!(c.view().server_id.as_deref(), Some("computer"));
    assert_eq!(c.view().attempt_index, 1);
    c.close();
    task.await.unwrap();
}
#[tokio::test]
async fn identity_mismatch_blocks_before_authentication_and_does_not_try_next_address() {
    let wrong = server("wrong", false).await;
    let next = server("computer", false).await;
    let (c, task) = client(
        vec![wrong.url.clone(), next.url.clone()],
        Some("computer".into()),
    );
    until(&c, |v| v.connection == "blocked").await;
    assert_eq!(wrong.fixture.controls.load(Ordering::SeqCst), 0);
    assert_eq!(next.fixture.discoveries.load(Ordering::SeqCst), 0);
    c.close();
    task.await.unwrap();
}
#[tokio::test]
async fn auth_rejection_blocks_without_rotating_or_retrying() {
    let a = server("computer", true).await;
    let b = server("computer", false).await;
    let (c, task) = client(vec![a.url.clone(), b.url.clone()], None);
    until(&c, |v| v.connection == "blocked").await;
    tokio::time::sleep(Duration::from_millis(1200)).await;
    assert_eq!(a.fixture.controls.load(Ordering::SeqCst), 1);
    assert_eq!(b.fixture.discoveries.load(Ordering::SeqCst), 0);
    c.close();
    task.await.unwrap();
}
#[tokio::test]
async fn live_failover_keeps_identity_and_never_replays_a_mutation() {
    let a = server("computer", false).await;
    let b = server("computer", false).await;
    let (c, task) = client(vec![a.url.clone(), b.url.clone()], None);
    until(&c, |v| v.connection == "connected").await;
    let request = {
        let c = c.clone();
        tokio::spawn(async move { c.create_directory("/tmp".into(), "test".into()).await })
    };
    tokio::time::timeout(Duration::from_secs(2), async {
        while a.fixture.mutations.load(Ordering::SeqCst) == 0 {
            tokio::task::yield_now().await;
        }
    })
    .await
    .unwrap();
    a.fixture.close.send(()).unwrap();
    until(&c, |v| {
        v.connection == "connected" && v.current_address == Some(b.url.clone())
    })
    .await;
    assert!(request.await.unwrap().unwrap_err().contains("unconfirmed"));
    assert_eq!(b.fixture.mutations.load(Ordering::SeqCst), 0);
    assert_eq!(c.view().server_id.as_deref(), Some("computer"));
    c.close();
    task.await.unwrap();
}
#[tokio::test]
async fn list_updates_keep_the_active_socket_and_disconnect_cancels_retries() {
    let a = server("computer", false).await;
    let b = server("computer", false).await;
    let (c, task) = client(vec![a.url.clone(), b.url.clone()], None);
    until(&c, |v| v.connection == "connected").await;
    c.set_addresses(vec![b.url.clone(), a.url.clone()]).unwrap();
    until(&c, |v| v.attempt_index == 1).await;
    assert_eq!(a.fixture.controls.load(Ordering::SeqCst), 1);
    assert_eq!(b.fixture.controls.load(Ordering::SeqCst), 0);
    c.reconnect();
    until(&c, |v| {
        v.connection == "connected" && a.fixture.controls.load(Ordering::SeqCst) == 2
    })
    .await;
    assert_eq!(c.view().current_address, Some(a.url.clone()));
    c.close();
    task.await.unwrap();
    assert_eq!(c.view().connection, "disconnected");
}

#[tokio::test]
async fn already_added_computer_is_rejected_before_authentication() {
    let existing = server("existing-computer", false).await;
    let error = crate::transport::connect_service(
        &existing.url,
        &pirc_crypto::generate_key().unwrap(),
        None,
        &["existing-computer".into()],
    )
    .await
    .unwrap_err();
    assert!(error.fatal);
    assert!(error.detail.contains("already added"));
    assert_eq!(existing.fixture.controls.load(Ordering::SeqCst), 0);
}

fn fixture_key(id: &str) -> String {
    static KEYS: OnceLock<Mutex<std::collections::HashMap<String, String>>> = OnceLock::new();
    KEYS.get_or_init(|| Mutex::new(Default::default()))
        .lock()
        .unwrap()
        .entry(id.into())
        .or_insert_with(|| pirc_crypto::generate_key().unwrap())
        .clone()
}
#[tokio::test]
async fn first_pairing_sends_no_authentication_until_server_approval() {
    let server = server("new-computer", false).await;
    let client = Client::new(server.url.clone()).unwrap();
    until(&client, |v| v.connection == "pairing").await;
    assert_eq!(server.fixture.authentications.load(Ordering::SeqCst), 0);
    let key = client.view().pairing.unwrap().public_key;
    assert!(client.view().pairing.as_ref().unwrap().code.len() == 9);
    server.fixture.approve.notify_one();
    until(&client, |v| v.connection == "connected").await;
    assert_eq!(client.view().server_key, Some(key));
    assert_eq!(server.fixture.authentications.load(Ordering::SeqCst), 1);
    client.close();
}
#[tokio::test]
async fn changed_key_with_same_computer_id_blocks_before_authentication() {
    let server = server("computer", false).await;
    let client = Client::with_security(
        vec![server.url.clone()],
        Some("computer".into()),
        vec![],
        pirc_crypto::generate_key().unwrap(),
        Some(pirc_crypto::public_key(&fixture_key("different")).unwrap()),
    )
    .unwrap();
    until(&client, |v| v.connection == "blocked").await;
    assert!(client
        .view()
        .error
        .unwrap()
        .contains("encryption key changed"));
    assert!(client.view().pairing.is_none());
    assert_eq!(server.fixture.authentications.load(Ordering::SeqCst), 0);
    client.close();
}

#[tokio::test]
async fn handshake_mismatched_pairing_code_blocks_without_authentication() {
    let server = server("bad-code", false).await;
    let client = Client::new(server.url.clone()).unwrap();
    until(&client, |v| v.connection == "blocked").await;
    assert!(client
        .view()
        .error
        .unwrap()
        .contains("Pairing code does not match"));
    assert_eq!(server.fixture.authentications.load(Ordering::SeqCst), 0);
    client.close();
}
