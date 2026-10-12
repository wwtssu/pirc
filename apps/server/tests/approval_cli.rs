use pirc_core::client::Client;
use std::{
    fs,
    path::PathBuf,
    process::{Child, Command},
    time::{Duration, Instant},
};
struct Service {
    process: Child,
    directory: PathBuf,
    address: String,
}
#[test]
fn occupied_port_reports_port_before_initializing_approval() {
    let listener = std::net::TcpListener::bind("0.0.0.0:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let directory = std::env::temp_dir().join(format!("pirc-port-test-{}", uuid::Uuid::new_v4()));
    let output = Command::new(env!("CARGO_BIN_EXE_pirc"))
        .args(["server", "--port", &port.to_string()])
        .env("HOME", &directory)
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert_eq!(
        String::from_utf8(output.stderr).unwrap(),
        format!("Port {port} is already in use.\n")
    );
    assert!(!directory.exists());
}
impl Service {
    async fn start() -> Self {
        let directory =
            std::env::temp_dir().join(format!("pirc-approval-wire-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&directory).unwrap();
        let socket = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = socket.local_addr().unwrap().port();
        drop(socket);
        let log = fs::File::create(directory.join("server.log")).unwrap();
        let process = Command::new(env!("CARGO_BIN_EXE_pirc"))
            .args(["server", &format!("--port={port}")])
            .env("HOME", &directory)
            .stdout(log.try_clone().unwrap())
            .stderr(log)
            .spawn()
            .unwrap();
        let mut service = Self {
            process,
            directory,
            address: format!("http://127.0.0.1:{port}"),
        };
        let deadline = Instant::now() + Duration::from_secs(10);
        while !fs::read_to_string(service.directory.join("server.log"))
            .unwrap_or_default()
            .contains("PiRC Server listening on")
        {
            assert!(
                service.process.try_wait().unwrap().is_none(),
                "server exited: {}",
                fs::read_to_string(service.directory.join("server.log")).unwrap_or_default()
            );
            assert!(Instant::now() < deadline, "server startup timed out");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        service
    }
    fn allow(&self, code: &str) -> std::process::Output {
        Command::new(env!("CARGO_BIN_EXE_pirc"))
            .args(["allow", code])
            .env("HOME", &self.directory)
            .output()
            .unwrap()
    }
    fn waitlist(&self) -> String {
        let output = Command::new(env!("CARGO_BIN_EXE_pirc"))
            .arg("waitlist")
            .env("HOME", &self.directory)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap()
    }
}
impl Drop for Service {
    fn drop(&mut self) {
        let _ = self.process.kill();
        let _ = self.process.wait();
        let _ = fs::remove_dir_all(&self.directory);
    }
}
async fn until(client: &Client, state: &str) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while client.view().connection != state {
        assert!(
            Instant::now() < deadline,
            "expected {state}, got {}: {:?}",
            client.view().connection,
            client.view().error
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}
#[tokio::test]
async fn connection_requires_local_approval_and_remembers_client_identity() {
    let service = Service::start().await;
    assert!(service.waitlist().contains("No pending connections."));
    let secret = pirc_crypto::generate_key().unwrap();
    let client = Client::with_security(
        vec![service.address.clone()],
        None,
        vec![],
        secret.clone(),
        None,
    )
    .unwrap();
    until(&client, "pairing").await;
    assert!(client.view().server_key.is_none());
    assert!(client.view().sessions.is_empty());
    assert!(client
        .create_directory("/tmp".into(), "forbidden".into())
        .await
        .is_err());
    let pairing = client.view().pairing.unwrap();
    assert!(service.waitlist().contains(&pairing.code));
    assert_eq!(client.view().connection, "pairing");
    assert!(!service.allow("XXXX-XXXX").status.success());
    assert_eq!(client.view().connection, "pairing");
    let result = service.allow(&pairing.code);
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    until(&client, "connected").await;
    // An idle, healthy encrypted client must survive the server's idle timeout.
    tokio::time::sleep(Duration::from_secs(21)).await;
    assert_eq!(client.view().connection, "connected");
    assert!(!service.waitlist().contains(&pairing.code));
    assert_eq!(client.view().server_key, Some(pairing.public_key.clone()));
    assert!(!service.allow(&pairing.code).status.success());
    let extra = Client::with_security(
        vec![service.address.clone()],
        client.view().server_id,
        vec![],
        secret.clone(),
        Some(pairing.public_key.clone()),
    )
    .unwrap();
    until(&extra, "blocked").await;
    assert_eq!(
        extra.view().error.as_deref(),
        Some("SERVER_BUSY: A client is already connected")
    );
    assert_eq!(client.view().connection, "connected");
    extra.close();
    until(&extra, "disconnected").await;
    client.close();
    until(&client, "disconnected").await;
    let deadline = Instant::now() + Duration::from_secs(3);
    let same_client = Client::with_security(
        vec![service.address.clone()],
        client.view().server_id,
        vec![],
        secret,
        Some(pairing.public_key.clone()),
    )
    .unwrap();
    until(&same_client, "connected").await;
    assert!(Instant::now() < deadline);
    same_client.close();
    until(&same_client, "disconnected").await;
    let unknown = Client::with_security(
        vec![service.address.clone()],
        None,
        vec![],
        pirc_crypto::generate_key().unwrap(),
        Some(pairing.public_key),
    )
    .unwrap();
    until(&unknown, "pairing").await;
    let code = unknown.view().pairing.unwrap().code;
    assert_ne!(code, pairing.code);
    unknown.close();
    until(&unknown, "disconnected").await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(!service.allow(&code).status.success());
    assert!(!service.waitlist().contains(&code));
}

// Keep TCP open without answering WebSocket pings to model a suspended app.
async fn silent_client(service: &Service) -> (tokio::net::TcpStream, pirc_protocol::Envelope) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let address = service.address.strip_prefix("http://").unwrap();
    let mut stream = tokio::net::TcpStream::connect(address).await.unwrap();
    let request = format!(
        "GET /control HTTP/1.1\r\nHost: {address}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
    );
    stream.write_all(request.as_bytes()).await.unwrap();
    let mut response = Vec::new();
    while !response.ends_with(b"\r\n\r\n") {
        response.push(stream.read_u8().await.unwrap());
        assert!(response.len() < 8192);
    }
    assert!(response.starts_with(b"HTTP/1.1 101"));
    let auth = br#"{"version":1,"request_id":"idle-client","message":{"type":"auth"}}"#;
    assert!(auth.len() < 126);
    let mask = [1, 2, 3, 4];
    let mut frame = vec![0x81, 0x80 | auth.len() as u8];
    frame.extend_from_slice(&mask);
    frame.extend(auth.iter().enumerate().map(|(i, byte)| byte ^ mask[i % 4]));
    stream.write_all(&frame).await.unwrap();
    let packet = tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let opcode = stream.read_u8().await.unwrap() & 0x0f;
            let length = stream.read_u8().await.unwrap();
            assert_eq!(length & 0x80, 0);
            let length = match length {
                126 => stream.read_u16().await.unwrap() as usize,
                127 => stream.read_u64().await.unwrap() as usize,
                length => length as usize,
            };
            assert!(length < 1024 * 1024);
            let mut payload = vec![0; length];
            stream.read_exact(&mut payload).await.unwrap();
            if opcode == 1 {
                break pirc_protocol::Envelope::decode(std::str::from_utf8(&payload).unwrap())
                    .unwrap();
            }
            assert_eq!(opcode, 9);
        }
    })
    .await
    .unwrap();
    (stream, packet)
}

#[tokio::test]
async fn silent_client_expires_and_releases_the_server_slot() {
    let service = Service::start().await;
    let (_silent, welcome) = silent_client(&service).await;
    assert!(matches!(
        welcome.message,
        pirc_protocol::Message::Welcome { .. }
    ));
    let (blocked, error) = silent_client(&service).await;
    assert!(
        matches!(error.message, pirc_protocol::Message::Error { code, .. } if code == "SERVER_BUSY")
    );
    drop(blocked);
    tokio::time::sleep(Duration::from_secs(21)).await;
    let (_replacement, welcome) = silent_client(&service).await;
    assert!(matches!(
        welcome.message,
        pirc_protocol::Message::Welcome { .. }
    ));
}
