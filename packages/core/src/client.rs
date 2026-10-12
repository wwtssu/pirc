use crate::projection::{packet, Projection, View};
use crate::transport::{canonical_service_address, connect_service, upgrade_request};
use pirc_protocol::{Envelope, HistoryDirection, Message};
use std::{
    sync::{Arc, Mutex, OnceLock},
    time::{Duration, Instant},
};
use tokio::sync::{mpsc, oneshot, watch};
use tokio_tungstenite::tungstenite::Message as Ws;

enum Action {
    Request {
        message: Box<Message>,
        reply: oneshot::Sender<Result<Message, String>>,
    },
    Send {
        instance: String,
        text: Option<String>,
        closing: bool,
        reply: oneshot::Sender<Result<String, String>>,
    },
    History {
        instance: String,
        direction: HistoryDirection,
        cursor: Option<u64>,
        reply: oneshot::Sender<Result<(), String>>,
    },
    Addresses(Vec<String>),
    Reconnect,
    Close,
    Confirm(String),
    Select(String),
}
#[derive(Clone)]
pub struct Client {
    actions: mpsc::Sender<Action>,
    state: Arc<Mutex<Projection>>,
    changes: watch::Receiver<u64>,
}
fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .unwrap()
    })
}
impl Client {
    pub async fn saved_sessions(&self) -> Result<Message, String> {
        self.request(Message::SavedSessions {}).await
    }
    pub async fn browse_directories(
        &self,
        path: Option<String>,
        cursor: Option<String>,
        show_hidden: bool,
    ) -> Result<Message, String> {
        tokio::time::timeout(
            Duration::from_secs(8),
            self.request(Message::BrowseDirectories {
                path,
                cursor,
                show_hidden,
            }),
        )
        .await
        .map_err(|_| {
            "Reading the directory timed out. Retry or choose another directory.".to_string()
        })?
    }
    pub async fn launch_session(
        &self,
        cwd: String,
        session_id: Option<String>,
        name: Option<String>,
    ) -> Result<Message, String> {
        let generation_id = self
            .view()
            .generation
            .ok_or("Wait for the connection to recover, then retry.")?;
        self.request(Message::LaunchSession {
            generation_id,
            cwd,
            session_id,
            name,
        })
        .await
    }
    pub async fn create_directory(&self, parent: String, name: String) -> Result<Message, String> {
        tokio::time::timeout(
            Duration::from_secs(8),
            self.request(Message::CreateDirectory { parent, name }),
        )
        .await
        .map_err(|_| {
            "Creation is unconfirmed. Refresh the directory before retrying.".to_string()
        })?
    }
    async fn request(&self, message: Message) -> Result<Message, String> {
        let disconnected = if matches!(&message, Message::LaunchSession { .. }) {
            "Connection lost. If the terminal opened, wait for the session rather than creating another one."
        } else if matches!(&message, Message::CreateDirectory { .. }) {
            "Connection lost. Creation is unconfirmed. Reconnect and refresh the directory before retrying."
        } else {
            "Device disconnected. Reconnect and try again."
        };
        let (reply, result) = oneshot::channel();
        self.actions
            .send(Action::Request {
                message: Box::new(message),
                reply,
            })
            .await
            .map_err(|_| "Connection closed")?;
        result.await.map_err(|_| disconnected.to_string())?
    }
    pub fn new(url: String) -> Result<Self, String> {
        Self::with_addresses(vec![url], None)
    }
    pub fn with_addresses(
        addresses: Vec<String>,
        server_id: Option<String>,
    ) -> Result<Self, String> {
        Self::with_options(addresses, server_id, vec![])
    }
    pub fn with_options(
        addresses: Vec<String>,
        server_id: Option<String>,
        other_ids: Vec<String>,
    ) -> Result<Self, String> {
        Self::with_security(
            addresses,
            server_id,
            other_ids,
            pirc_crypto::generate_key()?,
            None,
        )
    }
    pub fn with_security(
        addresses: Vec<String>,
        server_id: Option<String>,
        other_ids: Vec<String>,
        secret: String,
        server_key: Option<String>,
    ) -> Result<Self, String> {
        pirc_crypto::public_key(&secret)?;
        if let Some(key) = &server_key {
            pirc_crypto::fingerprint(key)?;
        }
        if addresses.is_empty() {
            return Err("Enter at least one connection address".into());
        }
        let mut urls = Vec::new();
        for address in addresses {
            let url = canonical_service_address(&address)?;
            if urls.contains(&url) {
                return Err("Duplicate connection address".into());
            }
            upgrade_request(&url)?;
            urls.push(url);
        }
        // Validate the handshake before starting a retry loop.
        let (actions, rx) = mpsc::channel(32);
        let (updates, changes) = watch::channel(0);
        let state = Arc::new(Mutex::new(Projection::default()));
        runtime().spawn(worker(
            urls,
            server_id,
            other_ids,
            secret,
            server_key,
            rx,
            state.clone(),
            updates,
        ));
        Ok(Self {
            actions,
            state,
            changes,
        })
    }
    pub fn view(&self) -> View {
        let p = self.state.lock().unwrap();
        View {
            server_key: p.view.server_key.clone(),
            pairing: p.view.pairing.clone(),
            connection: p.view.connection.clone(),
            error: p.view.error.clone(),
            generation: p.view.generation.clone(),
            server_id: p.view.server_id.clone(),
            current_address: p.view.current_address.clone(),
            attempt_index: p.view.attempt_index,
            commands: p.view.commands.clone(),
            sessions: p
                .view
                .sessions
                .iter()
                .map(|s| s.display(p.selected.as_ref() == Some(&s.snapshot.instance_id)))
                .collect(),
        }
    }
    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.changes.clone()
    }
    pub async fn send(&self, instance: String, text: Option<String>) -> Result<String, String> {
        let (reply, result) = oneshot::channel();
        self.actions
            .send(Action::Send {
                instance,
                text,
                closing: false,
                reply,
            })
            .await
            .map_err(|_| "Connection closed")?;
        result
            .await
            .map_err(|_| String::from("Connection closed"))?
    }
    pub async fn close_session(&self, instance: String) -> Result<String, String> {
        let (reply, result) = oneshot::channel();
        self.actions
            .send(Action::Send {
                instance,
                text: None,
                closing: true,
                reply,
            })
            .await
            .map_err(|_| "Connection closed")?;
        result
            .await
            .map_err(|_| String::from("Connection closed"))?
    }
    pub async fn history(
        &self,
        instance: String,
        direction: HistoryDirection,
        cursor: Option<u64>,
    ) -> Result<(), String> {
        let (reply, result) = oneshot::channel();
        self.actions
            .send(Action::History {
                instance,
                direction,
                cursor,
                reply,
            })
            .await
            .map_err(|_| "Connection closed")?;
        result
            .await
            .map_err(|_| String::from("Connection closed"))?
    }
    pub fn set_addresses(&self, addresses: Vec<String>) -> Result<(), String> {
        let urls = addresses
            .into_iter()
            .map(|a| canonical_service_address(&a))
            .collect::<Result<Vec<_>, _>>()?;
        if urls.is_empty()
            || urls.iter().collect::<std::collections::HashSet<_>>().len() != urls.len()
        {
            return Err("Address list is empty or contains duplicates".into());
        }
        self.actions
            .try_send(Action::Addresses(urls))
            .map_err(|_| "Unable to update connection settings".to_owned())
    }
    pub fn reconnect(&self) {
        let _ = self.actions.try_send(Action::Reconnect);
    }
    pub fn close(&self) {
        let _ = self.actions.try_send(Action::Close);
    }
    pub fn confirm(&self, id: String) {
        let _ = self.actions.try_send(Action::Confirm(id));
    }
    pub fn select(&self, id: String) {
        let _ = self.actions.try_send(Action::Select(id));
    }
}
fn changed(updates: &watch::Sender<u64>) {
    updates.send_modify(|v| *v += 1);
}
fn confirm(state: &Arc<Mutex<Projection>>, id: String) {
    if let Some(c) = state
        .lock()
        .unwrap()
        .view
        .commands
        .iter_mut()
        .find(|c| c.request_id == id && c.status == "unknown")
    {
        c.status = "acknowledged".into();
    }
}
#[allow(clippy::too_many_arguments)]
async fn worker(
    mut urls: Vec<String>,
    mut known_id: Option<String>,
    other_ids: Vec<String>,
    secret: String,
    mut known_key: Option<String>,
    mut actions: mpsc::Receiver<Action>,
    state: Arc<Mutex<Projection>>,
    updates: watch::Sender<u64>,
) {
    state.lock().unwrap().view.server_key = known_key.clone();
    let mut blocked = false;
    let mut index = 0;
    let mut failures = 0usize;
    let mut rounds = 0u32;
    'reconnect: loop {
        let mut refreshing = false;
        if blocked {
            match actions.recv().await {
                Some(Action::Addresses(next)) => {
                    urls = next;
                    index = 0;
                    continue;
                }
                Some(Action::Reconnect) => {
                    blocked = false;
                    index = 0;
                    failures = 0;
                    rounds = 0;
                }
                Some(Action::History { reply, .. }) => {
                    let _ =
                        reply.send(Err("Wait for the connection to recover, then retry.".into()));
                    continue;
                }
                Some(Action::Send { reply, .. }) => {
                    let _ = reply.send(Err("Check connection settings and reconnect".into()));
                    continue;
                }
                Some(Action::Request { reply, .. }) => {
                    let _ =
                        reply.send(Err("Wait for the connection to recover, then retry.".into()));
                    continue;
                }
                Some(Action::Confirm(id)) => {
                    confirm(&state, id);
                    changed(&updates);
                    continue;
                }
                Some(Action::Select(id)) => {
                    state.lock().unwrap().selected = Some(id);
                    changed(&updates);
                    continue;
                }
                _ => break,
            }
        }
        {
            let mut p = state.lock().unwrap();
            p.view.pairing = None;
            p.view.error = None;
            p.view.connection = if known_id.is_some() {
                "reconnecting"
            } else {
                "connecting"
            }
            .into();
            p.view.current_address = Some(urls[index].clone());
            p.view.attempt_index = index;
        }
        changed(&updates);
        let attempt_started = Instant::now();
        let attempt = tokio::time::timeout(
            Duration::from_secs(5),
            connect_service(&urls[index], &secret, known_id.as_deref(), &other_ids),
        );
        let connection = tokio::select! {
            result = attempt => result,
            action = actions.recv() => {
                match action {
                    Some(Action::History { reply, .. }) => { let _ = reply.send(Err("Wait for the connection to recover, then retry.".into())); },
                    Some(Action::Send { reply, .. }) => { let _ = reply.send(Err("Connecting to device".into())); },
                    Some(Action::Request { reply, .. }) => { let _ = reply.send(Err("Wait for the connection to recover, then retry.".into())); },
                    Some(Action::Confirm(id)) => confirm(&state, id),
                    Some(Action::Select(id)) => { state.lock().unwrap().selected = Some(id); changed(&updates); },
                    Some(Action::Addresses(next)) => { urls = next; index = 0; },
                    Some(Action::Reconnect) => { index = 0; failures = 0; rounds = 0; },
                    _ => break,
                }
                continue;
            }
        };
        if let Ok(Err(error)) = &connection {
            blocked = error.fatal;
            state.lock().unwrap().view.error = Some(error.detail.clone());
        }
        if let Ok(Ok((mut socket, discovered_id, server_key))) = connection {
            if known_key.as_ref().is_some_and(|key| key != &server_key) {
                state.lock().unwrap().view.error =
                    Some("Device encryption key changed. Connection stopped. Verify the device before pairing again.".into());
                blocked = true;
                let _ = socket.close(None).await;
            } else {
                let mut authenticated = false;
                let mut auth_started = attempt_started;
                let mut pair_deadline = None;
                let mut approved = known_key.is_some();
                let initial = if known_key.is_none() {
                    Message::PairingRequest {}
                } else {
                    Message::Auth {}
                };
                let auth = serde_json::to_string(&packet(initial)).unwrap();
                if socket.send(Ws::Text(auth.into())).await.is_ok() {
                    let mut tick = tokio::time::interval(Duration::from_millis(200));
                    let mut received = Instant::now();
                    let mut ping = Instant::now();
                    let mut pending: Vec<(String, Instant)> = vec![];
                    let mut requests = std::collections::HashMap::<
                        String,
                        (Instant, oneshot::Sender<Result<Message, String>>),
                    >::new();
                    loop {
                        tokio::select! {
                            action = actions.recv() => match action {
                                Some(Action::Addresses(next)) => {
                                    let retained = next.iter().position(|a| a == &urls[index]);
                                    urls = next;
                                    index = retained.unwrap_or(0);
                                    state.lock().unwrap().view.attempt_index = index;
                                    changed(&updates);
                                    if retained.is_none() { refreshing = true; let _ = socket.close(None).await; break; }
                                },
                                Some(Action::Close) | None => { let _ = socket.close(None).await; break 'reconnect; },
                                Some(Action::Reconnect) => { refreshing = true; let _ = socket.close(None).await; break; },
                                Some(Action::Confirm(id)) => { confirm(&state, id); changed(&updates); },
                                Some(Action::Request { message, reply }) => {
                                    if reply.is_closed() { continue; }
                                    if state.lock().unwrap().view.connection != "connected" { let _ = reply.send(Err("Wait for the connection to recover, then retry.".into())); continue; }
                                    let e = packet(*message);
                                    requests.insert(e.request_id.clone(), (Instant::now(), reply));
                                    if socket.send(Ws::Text(serde_json::to_string(&e).unwrap().into())).await.is_err() { break; }
                                },
                                Some(Action::Select(id)) => {
                                    let outgoing = if authenticated { state.lock().unwrap().select(id) } else { state.lock().unwrap().selected = Some(id); vec![] };
                                    changed(&updates);
                                    for e in outgoing { if socket.send(Ws::Text(serde_json::to_string(&e).unwrap().into())).await.is_err() { break; } }
                                },
                                Some(Action::History { instance, direction, cursor, reply }) => {
                                    if !authenticated { let _ = reply.send(Err("Wait for server approval, then retry.".into())); continue; }
                                    let e = state.lock().unwrap().history(&instance, direction, cursor);
                                    match e {
                                        Ok(e) => {
                                            changed(&updates);
                                            if socket.send(Ws::Text(serde_json::to_string(&e).unwrap().into())).await.is_err() { let _ = reply.send(Err("Connection lost".into())); break; }
                                            let _ = reply.send(Ok(()));
                                        }
                                        Err(error) => { let _ = reply.send(Err(error)); }
                                    }
                                },
                                Some(Action::Send { instance, text, closing, reply }) => {
                                    let e = if closing { state.lock().unwrap().close_session(&instance) } else { state.lock().unwrap().command(&instance, text) };
                                    match e {
                                        Ok(e) => {
                                            let id = e.request_id.clone();
                                            let sent = socket.send(Ws::Text(serde_json::to_string(&e).unwrap().into())).await;
                                            // A write failure does not prove that Pi did not receive it.
                                            let _ = reply.send(Ok(id.clone()));
                                            pending.push((id, Instant::now())); changed(&updates);
                                            if sent.is_err() { break; }
                                        },
                                        Err(error) => { let _ = reply.send(Err(error)); }
                                    }
                                }
                            },
                            incoming = socket.next() => {
                                received = Instant::now();
                                match incoming {
                                    Some(Ok(Ws::Text(text))) => {
                                        let Ok(e) = Envelope::decode(&text) else { break; };
                                        if let Message::PairingRequired { code, expires_in } = &e.message {
                                            if authenticated || pair_deadline.is_some() || code != &socket.pairing_code || !(1..=300).contains(expires_in) {
                                                blocked = true;
                                                state.lock().unwrap().view.error = Some("Pairing code does not match the encrypted handshake. Connection stopped.".into());
                                                break;
                                            }
                                            pair_deadline = Some(Instant::now() + Duration::from_secs((*expires_in).into()));
                                            approved = false;
                                            {
                                                let mut p = state.lock().unwrap();
                                                p.view.pairing = Some(crate::projection::Pairing { server_id: discovered_id.clone(), public_key: server_key.clone(), code: code.clone(), expires_in: *expires_in });
                                                p.view.connection = "pairing".into();
                                                p.view.error = None;
                                            }
                                            changed(&updates);
                                            continue;
                                        }
                                        if let Message::PairingApproved {} = &e.message {
                                            if pair_deadline.is_none_or(|deadline| Instant::now() >= deadline) || approved || authenticated {
                                                blocked = true;
                                                state.lock().unwrap().view.error = Some("Invalid server approval state. Reconnect to retry.".into());
                                                break;
                                            }
                                            approved = true;
                                            pair_deadline = None;
                                            auth_started = Instant::now();
                                            {
                                                let mut p = state.lock().unwrap();
                                                p.view.pairing = None;
                                                p.view.connection = "connecting".into();
                                            }
                                            changed(&updates);
                                            let auth = serde_json::to_string(&packet(Message::Auth {})).unwrap();
                                            if socket.send(Ws::Text(auth.into())).await.is_err() { break; }
                                            continue;
                                        }
                                        if let Message::Welcome { server_id, .. } = &e.message {
                                            if !approved || server_id.as_deref() != Some(discovered_id.as_str()) {
                                                blocked = true;
                                                state.lock().unwrap().view.error = Some("Device identity does not match the handshake. Check the address.".into());
                                                break;
                                            }
                                            known_key = Some(server_key.clone());
                                            state.lock().unwrap().view.server_key = Some(server_key.clone());
                                            known_id = server_id.clone();
                                            state.lock().unwrap().view.server_id = server_id.clone();
                                            authenticated = true;
                                            failures = 0;
                                            rounds = 0;
                                        }
                                        if !authenticated && !matches!(e.message, Message::Error { .. }) {
                                            blocked = true;
                                            state.lock().unwrap().view.error = Some("Server did not confirm device identity".into());
                                            break;
                                        }
                                        if let Some((_, reply)) = requests.remove(&e.request_id) {
                                            let result = match e.message { Message::Error { detail, .. } => Err(detail), message => Ok(message) };
                                            let _ = reply.send(result);
                                            continue;
                                        }
                                        let fatal = matches!(&e.message, Message::Error { code, .. } if code == "UNAUTHORIZED" || code == "SERVER_BUSY" || code.starts_with("PAIRING_"));
                                        let outgoing = state.lock().unwrap().receive(e);
                                        changed(&updates);
                                        for e in outgoing {
                                            if socket.send(Ws::Text(serde_json::to_string(&e).unwrap().into())).await.is_err() { break; }
                                        }
                                        if fatal { blocked = true; break; }
                                    },
                                    Some(Ok(Ws::Ping(bytes))) => { if socket.send(Ws::Pong(bytes)).await.is_err() { break; } },
                                    Some(Ok(Ws::Pong(_))) => {},
                                    Some(Err(error)) => {
                                        if error.fatal { blocked = true; state.lock().unwrap().view.error = Some(error.detail); }
                                        break;
                                    },
                                    Some(Ok(Ws::Close(_))) | None => break,
                                    _ => {},
                                }
                            },
                            _ = tick.tick() => {
                                if pair_deadline.is_some_and(|deadline| Instant::now() >= deadline) {
                                    blocked = true;
                                    state.lock().unwrap().view.error = Some("Pairing code expired. Reconnect to retry.".into());
                                    break;
                                }
                                if !authenticated && pair_deadline.is_none() && auth_started.elapsed() > Duration::from_secs(5) { break; }
                                if received.elapsed() > Duration::from_secs(20) { break; }
                                if ping.elapsed() > Duration::from_secs(5) {
                                    if socket.send(Ws::Ping(vec![].into())).await.is_err() { break; }
                                    ping = Instant::now();
                                }
                                let mut edited = state.lock().unwrap().expire_history();
                                pending.retain(|(id, sent)| {
                                    let mut p = state.lock().unwrap();
                                    let Some(c) = p.view.commands.iter_mut().find(|c| c.request_id == *id) else { return false; };
                                    if c.status != "pending" && !(c.kind != "prompt" && c.status == "accepted") { return false; }
                                    // Compaction is an acknowledged, potentially long model operation.
                                    if c.kind == "compact" && c.status == "accepted" { return true; }
                                    if sent.elapsed() > Duration::from_secs(10) { c.status = "unknown".into(); c.code = Some("CONFIRMATION_TIMEOUT".into()); edited = true; false } else { true }
                                });
                                if edited { changed(&updates); }
                                let expired = requests.iter().filter(|(_, (started, reply))| reply.is_closed() || started.elapsed() > Duration::from_secs(20)).map(|(id, _)| id.clone()).collect::<Vec<_>>();
                                for id in expired { if let Some((_, reply)) = requests.remove(&id) { let _ = reply.send(Err("Operation result unconfirmed. Check the device terminal and refresh.".into())); } }
                            }
                        }
                    }
                }
            }
        }
        {
            let mut p = state.lock().unwrap();
            let error = if blocked {
                p.view.error.clone()
            } else if refreshing {
                None
            } else {
                Some("Connection lost. Reconnecting…".into())
            };
            p.view.pairing = None;
            p.disconnected(error);
            if refreshing {
                p.view.connection = "syncing".into();
            }
            if blocked {
                p.view.connection = if p.view.pairing.is_some() {
                    "pairing"
                } else {
                    "blocked"
                }
                .into();
            }
        }
        changed(&updates);
        if refreshing {
            continue;
        }
        if !blocked {
            index = (index + 1) % urls.len();
            failures += 1;
            let delay = if failures < urls.len() {
                Duration::ZERO
            } else {
                failures = 0;
                index = 0;
                let millis = (1000u64 << rounds.min(5)).min(30_000);
                rounds = rounds.saturating_add(1);
                Duration::from_millis(millis + u64::from(uuid::Uuid::new_v4().as_bytes()[0]))
            };
            tokio::select! {
                _ = tokio::time::sleep(delay) => {},
                action = actions.recv() => match action {
                    Some(Action::Addresses(next)) => { urls = next; index = 0; },
                    Some(Action::Close) | None => break,
                    Some(Action::History { reply, .. }) => { let _ = reply.send(Err("Wait for the connection to recover, then retry.".into())); },
                    Some(Action::Send { reply, .. }) => { let _ = reply.send(Err("Restoring connection".into())); },
                    Some(Action::Request { reply, .. }) => { let _ = reply.send(Err("Wait for the connection to recover, then retry.".into())); },
                    Some(Action::Confirm(id)) => confirm(&state, id),
                    Some(Action::Select(id)) => { state.lock().unwrap().selected = Some(id); changed(&updates); },
                    _ => {},
                }
            }
        }
    }
    let mut p = state.lock().unwrap();
    p.disconnected(None);
    p.view.connection = "disconnected".into();
    changed(&updates);
}

#[cfg(test)]
#[path = "connection_tests.rs"]
mod tests;
