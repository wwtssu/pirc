use axum::extract::ws::{Message, WebSocket};
use pirc_crypto::{Channel, MAX_RECORD};
use std::{
    fs,
    io::{self, Write},
    path::Path,
};

pub fn load_key() -> io::Result<String> {
    load_at(&crate::state::directory()?.join("server-key"))
}
fn load_at(path: &Path) -> io::Result<String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    match options.open(path) {
        Ok(mut file) => {
            let key = pirc_crypto::generate_key().map_err(io::Error::other)?;
            file.write_all(key.as_bytes())?;
            file.sync_all()?;
            Ok(key)
        }
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
            let metadata = fs::symlink_metadata(path)?;
            if !metadata.is_file() {
                return Err(io::Error::other("Invalid encryption key file"));
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                if metadata.permissions().mode() & 0o077 != 0 {
                    return Err(io::Error::other("Encryption key file must have mode 0600"));
                }
            }
            let key = fs::read_to_string(path)?.trim().to_owned();
            pirc_crypto::public_key(&key).map_err(io::Error::other)?;
            Ok(key)
        }
        Err(e) => Err(e),
    }
}
pub struct Socket {
    inner: WebSocket,
    channel: Option<Channel>,
    pub client_key: Option<String>,
    pub pairing_code: Option<String>,
}
impl Socket {
    pub async fn start(
        mut inner: WebSocket,
        key: &str,
        id: &str,
        encrypted: bool,
    ) -> Result<Self, String> {
        let mut client_key = None;
        let mut pairing_code = None;
        let channel = if encrypted {
            let mut handshake = pirc_crypto::handshake(key, false)?;
            let first = handshake_frame(&mut inner).await?;
            let mut plain = vec![0; 65535];
            let n = handshake
                .read_message(&first, &mut plain)
                .map_err(|_| "Invalid Noise handshake")?;
            if n != 0 {
                return Err("Unexpected handshake payload".into());
            }
            let mut wire = vec![0; 65535];
            let n = handshake
                .write_message(id.as_bytes(), &mut wire)
                .map_err(|_| "Invalid Noise handshake")?;
            inner
                .send(Message::Binary(wire[..n].to_vec().into()))
                .await
                .map_err(|_| "Handshake disconnected")?;
            let third = handshake_frame(&mut inner).await?;
            let n = handshake
                .read_message(&third, &mut plain)
                .map_err(|_| "Invalid Noise handshake")?;
            if n != 0 {
                return Err("Unexpected handshake payload".into());
            }
            client_key = Some(
                handshake
                    .get_remote_static()
                    .ok_or("Client identity missing")?
                    .iter()
                    .map(|b| format!("{b:02x}"))
                    .collect(),
            );
            pairing_code = Some(pirc_crypto::pairing_code(handshake.get_handshake_hash()));
            Some(Channel::new(handshake)?)
        } else {
            None
        };
        Ok(Self {
            inner,
            channel,
            client_key,
            pairing_code,
        })
    }
    pub async fn recv(&mut self) -> Option<Result<Message, String>> {
        match self.inner.recv().await? {
            Ok(Message::Binary(bytes)) if self.channel.is_some() => Some(
                self.channel
                    .as_mut()
                    .unwrap()
                    .decrypt(&bytes)
                    .map(|s| Message::Text(s.into())),
            ),
            Ok(Message::Text(_)) if self.channel.is_some() => {
                Some(Err("Plaintext is not allowed".into()))
            }
            value => Some(value.map_err(|_| "Connection closed".into())),
        }
    }
    pub async fn send(&mut self, message: Message) -> Result<(), String> {
        let message = match (message, self.channel.as_mut()) {
            (Message::Text(text), Some(channel)) => Message::Binary(channel.encrypt(&text)?.into()),
            (message, _) => message,
        };
        self.inner
            .send(message)
            .await
            .map_err(|_| "Connection closed".into())
    }
}
async fn handshake_frame(socket: &mut WebSocket) -> Result<Vec<u8>, String> {
    match socket.recv().await {
        Some(Ok(Message::Binary(bytes))) if bytes.len() <= 65535 => Ok(bytes.to_vec()),
        _ => Err("Encrypted handshake required".into()),
    }
}
pub const WIRE_LIMIT: usize = MAX_RECORD + 1024;
#[cfg(test)]
mod tests {
    #[test]
    fn key_is_private_persistent_and_never_silently_replaced() {
        let path = std::env::temp_dir().join(format!("pirc-key-{}", uuid::Uuid::new_v4()));
        let key = super::load_at(&path).unwrap();
        assert_eq!(key, super::load_at(&path).unwrap());
        std::fs::write(&path, "broken").unwrap();
        assert!(super::load_at(&path).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "broken");
        std::fs::remove_file(path).unwrap();
    }
}
