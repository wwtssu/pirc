//! HTTP discovery followed by a pinned Noise-encrypted WebSocket channel.
//! Credentials never appear in HTTP headers or unencrypted application frames.
use tokio_tungstenite::tungstenite::{
    client::IntoClientRequest, handshake::client::Request, http::HeaderValue,
};
use url::Url;

pub(crate) fn service_address(address: &str) -> Result<Url, String> {
    let input = address.trim();
    let input = if input.contains("://") {
        input.to_owned()
    } else {
        format!("http://{input}")
    };
    let mut parsed = Url::parse(&input).map_err(|_| "Invalid connection address")?;
    let scheme = match parsed.scheme() {
        "http" => "http",
        "https" => "https",
        _ => return Err("Invalid connection address".into()),
    };
    parsed
        .set_scheme(scheme)
        .map_err(|_| "Invalid connection address")?;
    if parsed.host().is_none() {
        return Err("Invalid connection address".into());
    }
    if !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
    {
        return Err(
            "Connection addresses cannot contain credentials, query parameters, or fragments"
                .into(),
        );
    }
    // url::Url removes an explicitly supplied scheme-default port (80/443).
    // Inspect the input authority so an explicit :80 keeps its meaning.
    let authority = input
        .split_once("://")
        .unwrap()
        .1
        .split(['/', '?', '#'])
        .next()
        .unwrap();
    let has_port = if authority.starts_with('[') {
        authority
            .split_once(']')
            .is_some_and(|(_, suffix)| suffix.starts_with(':'))
    } else {
        authority.contains(':')
    };
    if !has_port {
        parsed
            .set_port(Some(43123))
            .map_err(|_| "Invalid connection address")?;
    }
    let path = parsed.path().trim_end_matches('/');
    let base = path.to_owned();
    parsed.set_path(&base);
    Ok(parsed)
}

/// Preserve explicit scheme-default ports when a normalized URL is reused.
pub(crate) fn canonical_service_address(address: &str) -> Result<String, String> {
    let parsed = service_address(address)?;
    if parsed.port().is_none() {
        Ok(format!(
            "{}:{}{}",
            &parsed[..url::Position::AfterHost],
            parsed.port_or_known_default().unwrap(),
            &parsed[url::Position::BeforePath..],
        ))
    } else {
        Ok(parsed.to_string())
    }
}

/// Build a fresh HTTP Upgrade request for every connection attempt. The socket
/// library needs ws/wss internally; those schemes never enter saved settings.
/// Authentication is sent only after the encrypted channel and key trust exist.
pub(crate) fn upgrade_request(address: &str) -> Result<Request, String> {
    let mut endpoint = service_address(address)?;
    let route = format!("{}/control", endpoint.path().trim_end_matches('/'));
    endpoint.set_path(&route);
    let scheme = if endpoint.scheme() == "https" {
        "wss"
    } else {
        "ws"
    };
    endpoint
        .set_scheme(scheme)
        .map_err(|_| "Invalid connection address")?;
    let mut request = endpoint
        .as_str()
        .into_client_request()
        .map_err(|_| "Unable to create HTTP upgrade request")?;
    request.headers_mut().insert(
        "sec-websocket-protocol",
        HeaderValue::from_static(pirc_crypto::SUBPROTOCOL),
    );
    Ok(request)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn http_addresses_have_no_local_network_restriction_and_upgrade_internally() {
        for (address, expected) in [
            ("127.0.0.1:43123", "ws://127.0.0.1:43123/control"),
            ("127.0.0.1", "ws://127.0.0.1:43123/control"),
            ("agent.local", "ws://agent.local:43123/control"),
            ("http://[::1]", "ws://[::1]:43123/control"),
            ("http://example.com:80", "ws://example.com/control"),
            ("http://example.com:43124", "ws://example.com:43124/control"),
            ("https://example.com", "wss://example.com:43123/control"),
            ("https://example.com:443", "wss://example.com/control"),
            (
                "https://example.com:43124",
                "wss://example.com:43124/control",
            ),
            ("http://8.8.8.8:43123", "ws://8.8.8.8:43123/control"),
            ("http://example.com/", "ws://example.com:43123/control"),
            (
                "https://example.com/pirc",
                "wss://example.com:43123/pirc/control",
            ),
        ] {
            let request = upgrade_request(address).unwrap();
            assert_eq!(request.uri().to_string(), expected);
            let canonical = canonical_service_address(address).unwrap();
            assert_eq!(
                upgrade_request(&canonical).unwrap().uri().to_string(),
                expected,
            );
            assert_eq!(request.headers()["upgrade"], "websocket");
            assert_eq!(request.headers()["connection"], "Upgrade");
        }
    }

    #[test]
    fn handshake_sends_no_credentials_and_keys_are_fresh() {
        let first = upgrade_request("https://example.com").unwrap();
        let next = upgrade_request("https://example.com").unwrap();
        assert!(first.headers().get("authorization").is_none());
        assert_eq!(
            first.headers()["sec-websocket-protocol"],
            pirc_crypto::SUBPROTOCOL
        );
        assert_ne!(
            first.headers()["sec-websocket-key"],
            next.headers()["sec-websocket-key"]
        );
        for invalid in [
            "ftp://example.com",
            "ws://example.com",
            "wss://example.com",
            "http://user:secret@example.com",
            "http://example.com?secret=value",
            "http://example.com#secret",
        ] {
            assert!(service_address(invalid).is_err());
        }
    }

    // The handshake callback signature comes from tungstenite.
    #[allow(clippy::result_large_err)]
    #[tokio::test]
    async fn http_upgrade_reaches_server_with_route_and_encryption_protocol() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let request =
            upgrade_request(&format!("http://{}", listener.local_addr().unwrap())).unwrap();
        let client = tokio::spawn(tokio_tungstenite::connect_async(request));
        let (stream, _) = listener.accept().await.unwrap();
        let server = tokio_tungstenite::accept_hdr_async(stream, |request: &Request, mut response: tokio_tungstenite::tungstenite::handshake::server::Response| {
            assert_eq!(request.uri().path(), "/control");
            assert!(request.headers().get("authorization").is_none());
            response.headers_mut().insert("sec-websocket-protocol", HeaderValue::from_static(pirc_crypto::SUBPROTOCOL));
            Ok(response)
        })
        .await
        .unwrap();
        assert!(client.await.unwrap().is_ok());
        drop(server);
    }
}

#[derive(Debug)]
pub(crate) struct AttemptError {
    pub fatal: bool,
    pub detail: String,
}
impl AttemptError {
    fn fatal(detail: &str) -> Self {
        Self {
            fatal: true,
            detail: detail.into(),
        }
    }
    fn network(detail: &str) -> Self {
        Self {
            fatal: false,
            detail: detail.into(),
        }
    }
}
fn http_error(error: reqwest::Error) -> AttemptError {
    use std::error::Error;
    let mut cause: Option<&dyn Error> = Some(&error);
    while let Some(e) = cause {
        let text = e.to_string().to_lowercase();
        if text.contains("certificate") || text.contains("invalid peer") {
            return AttemptError::fatal(
                "Certificate verification failed. Check the HTTPS configuration.",
            );
        }
        cause = e.source();
    }
    AttemptError::network("Address is temporarily unavailable")
}

pub(crate) async fn connect_service(
    address: &str,
    secret: &str,
    expected_id: Option<&str>,
    other_ids: &[String],
) -> Result<(SecureSocket, String, String), AttemptError> {
    let mut info_url = service_address(address).map_err(|e| AttemptError::fatal(&e))?;
    info_url.set_path(&format!(
        "{}/pirc/info",
        info_url.path().trim_end_matches('/')
    ));
    let http = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .map_err(|_| AttemptError::fatal("Unable to establish an HTTP connection"))?;
    let mut response = http.get(info_url).send().await.map_err(http_error)?;
    let status = response.status().as_u16();
    if matches!(status, 401 | 403) {
        return Err(AttemptError::fatal(
            "HTTP handshake authorization rejected. Check server authorization and reconnect.",
        ));
    }
    if status >= 500 || matches!(status, 408 | 429) {
        return Err(AttemptError::network("Service temporarily unavailable"));
    }
    if status != 200 {
        return Err(AttemptError::fatal(
            "This address does not provide a compatible PiRC service",
        ));
    }
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(http_error)? {
        if body.len() + chunk.len() > 4096 {
            return Err(AttemptError::fatal("Invalid service discovery response"));
        }
        body.extend_from_slice(&chunk);
    }
    #[derive(serde::Deserialize)]
    struct Info {
        server_id: String,
        protocol_version: u32,
        encryption: String,
    }
    let info: Info = serde_json::from_slice(&body)
        .map_err(|_| AttemptError::fatal("Invalid service discovery response"))?;
    if info.encryption != pirc_crypto::SUBPROTOCOL {
        return Err(AttemptError::fatal(
            "Update the device server to enable traffic encryption",
        ));
    }
    if info.protocol_version != pirc_protocol::PROTOCOL_VERSION || info.server_id.is_empty() {
        return Err(AttemptError::fatal(
            "Unsupported protocol version or invalid device identity",
        ));
    }
    if other_ids.contains(&info.server_id) {
        return Err(AttemptError::fatal(
            "This device is already added. Use the existing connection.",
        ));
    }
    if expected_id.is_some_and(|id| id != info.server_id) {
        return Err(AttemptError::fatal(
            "This address belongs to another device. Check connection settings.",
        ));
    }
    let request = upgrade_request(address).map_err(|e| AttemptError::fatal(&e))?;
    let config = tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default()
        .max_message_size(Some(pirc_crypto::MAX_RECORD + 1024))
        .max_frame_size(Some(pirc_crypto::MAX_RECORD + 1024));
    let (mut socket, response) =
        tokio_tungstenite::connect_async_with_config(request, Some(config), false)
            .await
            .map_err(|e| {
                use tokio_tungstenite::tungstenite::Error;
                match e {
                    Error::Http(response) if matches!(response.status().as_u16(), 401 | 403) => {
                        AttemptError::fatal("HTTP handshake authorization rejected. Check server authorization and reconnect.")
                    }
                    Error::Protocol(_) | Error::Capacity(_) => {
                        AttemptError::fatal("Encryption protocol negotiation failed. Connection stopped.")
                    }
                    Error::Tls(_) => AttemptError::fatal("TLS verification failed. Check the HTTPS configuration."),
                    Error::Http(response) if response.status().is_client_error() => {
                        AttemptError::fatal("Server rejected the connection. Check the address and protocol.")
                    }
                    _ => AttemptError::network("Address is temporarily unavailable"),
                }
            })?;
    if response
        .headers()
        .get("sec-websocket-protocol")
        .and_then(|v| v.to_str().ok())
        != Some(pirc_crypto::SUBPROTOCOL)
    {
        return Err(AttemptError::fatal(
            "Server did not confirm encryption. Connection stopped.",
        ));
    }
    use futures_util::SinkExt;
    let mut handshake =
        pirc_crypto::handshake(secret, true).map_err(|e| AttemptError::fatal(&e))?;
    let mut wire = vec![0; 65535];
    let n = handshake
        .write_message(&[], &mut wire)
        .map_err(|_| AttemptError::fatal("Encrypted handshake failed"))?;
    socket
        .send(Ws::Binary(wire[..n].to_vec().into()))
        .await
        .map_err(|_| AttemptError::network("Encrypted handshake connection lost"))?;
    let second = handshake_frame(&mut socket).await?;
    let mut plain = vec![0; 65535];
    let n = handshake
        .read_message(&second, &mut plain)
        .map_err(|_| AttemptError::fatal("Encrypted handshake verification failed"))?;
    if plain[..n] != *info.server_id.as_bytes() {
        return Err(AttemptError::fatal(
            "Encrypted handshake device identity mismatch",
        ));
    }
    let server_key = hex_key(
        handshake
            .get_remote_static()
            .ok_or_else(|| AttemptError::fatal("Device did not provide a public key"))?,
    );
    let n = handshake
        .write_message(&[], &mut wire)
        .map_err(|_| AttemptError::fatal("Encrypted handshake failed"))?;
    socket
        .send(Ws::Binary(wire[..n].to_vec().into()))
        .await
        .map_err(|_| AttemptError::network("Encrypted handshake connection lost"))?;
    let pairing_code = pirc_crypto::pairing_code(handshake.get_handshake_hash());
    let channel = pirc_crypto::Channel::new(handshake).map_err(|e| AttemptError::fatal(&e))?;
    Ok((
        SecureSocket {
            inner: socket,
            channel,
            pairing_code,
        },
        info.server_id,
        server_key,
    ))
}

use tokio_tungstenite::tungstenite::Message as Ws;
type Socket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;
fn hex_key(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
async fn handshake_frame(socket: &mut Socket) -> Result<Vec<u8>, AttemptError> {
    use futures_util::StreamExt;
    match socket.next().await {
        Some(Ok(Ws::Binary(bytes))) if bytes.len() <= 65535 => Ok(bytes.to_vec()),
        Some(Err(_)) | None => Err(AttemptError::network("Encrypted handshake connection lost")),
        _ => Err(AttemptError::fatal(
            "Server did not use an encrypted handshake. Connection stopped.",
        )),
    }
}
pub(crate) struct SecureSocket {
    inner: Socket,
    channel: pirc_crypto::Channel,
    pub pairing_code: String,
}
impl SecureSocket {
    pub async fn send(&mut self, message: Ws) -> Result<(), String> {
        use futures_util::SinkExt;
        let message = match message {
            Ws::Text(text) => Ws::Binary(self.channel.encrypt(&text)?.into()),
            other => other,
        };
        self.inner
            .send(message)
            .await
            .map_err(|_| "Connection lost".into())
    }
    pub async fn next(&mut self) -> Option<Result<Ws, AttemptError>> {
        use futures_util::StreamExt;
        match self.inner.next().await? {
            Ok(Ws::Binary(bytes)) => Some(
                self.channel
                    .decrypt(&bytes)
                    .map(|s| Ws::Text(s.into()))
                    .map_err(|e| AttemptError::fatal(&e)),
            ),
            Ok(Ws::Text(_)) => Some(Err(AttemptError::fatal(
                "Received plaintext on the encrypted channel. Connection stopped.",
            ))),
            Ok(other) => Some(Ok(other)),
            Err(_) => Some(Err(AttemptError::network("Connection lost"))),
        }
    }
    pub async fn close(
        &mut self,
        reason: Option<tokio_tungstenite::tungstenite::protocol::CloseFrame>,
    ) -> Result<(), String> {
        self.inner
            .close(reason)
            .await
            .map_err(|_| "Connection lost".into())
    }
}

impl std::fmt::Debug for SecureSocket {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SecureSocket").finish_non_exhaustive()
    }
}
