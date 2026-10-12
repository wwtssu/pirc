use std::{
    collections::{HashMap, HashSet},
    fs,
    io::{self, Write},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{UnixListener, UnixStream},
    sync::{oneshot, Mutex},
};

pub const TTL: u32 = 300;
const MAX_PENDING: usize = 32;
struct Pending {
    key: String,
    started: Instant,
    reply: oneshot::Sender<()>,
}
pub struct Approval {
    directory: PathBuf,
    inner: Mutex<Inner>,
}
struct Inner {
    allowed: HashSet<String>,
    pending: HashMap<String, Pending>,
}
pub fn directory() -> PathBuf {
    crate::state::directory()
        .expect("HOME is missing")
        .join("access")
}
// macOS has a short Unix socket path limit. Keep the socket in a private,
// deterministic short directory; the durable authorization file stays in HOME.
fn socket_directory(directory: &Path) -> io::Result<PathBuf> {
    use sha2::{Digest, Sha256};
    use std::os::unix::{ffi::OsStrExt, fs::MetadataExt};
    let directory = fs::canonicalize(directory)?;
    let hash = Sha256::digest(directory.as_os_str().as_bytes());
    let suffix: String = hash[..12].iter().map(|b| format!("{b:02x}")).collect();
    Ok(PathBuf::from(format!(
        "/tmp/pirc-admin-{}-{suffix}",
        fs::metadata(directory)?.uid()
    )))
}
fn validate_socket_directory(path: &Path, state: &Path) -> io::Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir()
        || metadata.permissions().mode() & 0o077 != 0
        || metadata.uid() != fs::metadata(state)?.uid()
    {
        return Err(io::Error::other("Invalid local approval socket directory"));
    }
    Ok(())
}
fn private_directory(path: &Path) -> io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    if !path.exists() {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut builder = fs::DirBuilder::new();
        builder.mode(0o700);
        builder.create(path)?;
    }
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir() || metadata.permissions().mode() & 0o077 != 0 {
        return Err(io::Error::other(
            "Approval directory must be a private directory (0700)",
        ));
    }
    Ok(())
}
impl Approval {
    pub fn open(directory: PathBuf) -> io::Result<Self> {
        use std::os::unix::fs::PermissionsExt;
        private_directory(&directory)?;
        let path = directory.join("clients.json");
        let allowed: HashSet<String> = match fs::symlink_metadata(&path) {
            Ok(metadata) => {
                if !metadata.is_file() || metadata.permissions().mode() & 0o077 != 0 {
                    return Err(io::Error::other(
                        "Client approvals must be a private file (0600)",
                    ));
                }
                serde_json::from_slice(&fs::read(&path)?).map_err(io::Error::other)?
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => HashSet::new(),
            Err(e) => return Err(e),
        };
        for key in &allowed {
            pirc_crypto::fingerprint(key).map_err(io::Error::other)?;
        }
        Ok(Self {
            directory,
            inner: Mutex::new(Inner {
                allowed,
                pending: HashMap::new(),
            }),
        })
    }
    pub async fn allowed(&self, key: &str) -> bool {
        self.inner.lock().await.allowed.contains(key)
    }
    pub async fn request(
        &self,
        key: String,
        code: String,
    ) -> Result<oneshot::Receiver<()>, String> {
        let mut inner = self.inner.lock().await;
        inner.pending.retain(|_, p| {
            p.started.elapsed() < Duration::from_secs(TTL.into()) && !p.reply.is_closed()
        });
        if inner.pending.len() >= MAX_PENDING || inner.pending.contains_key(&code) {
            return Err("Too many pairing requests. Try again later.".into());
        }
        // Only one live approval request per client identity.
        if inner.pending.values().any(|p| p.key == key) {
            return Err("This client already has a pending pairing request.".into());
        }
        let (reply, receiver) = oneshot::channel();
        inner.pending.insert(
            code,
            Pending {
                key,
                started: Instant::now(),
                reply,
            },
        );
        Ok(receiver)
    }
    pub async fn cancel(&self, code: &str) {
        self.inner.lock().await.pending.remove(code);
    }
    pub async fn waitlist(&self) -> String {
        let mut inner = self.inner.lock().await;
        inner.pending.retain(|_, p| {
            p.started.elapsed() < Duration::from_secs(TTL.into()) && !p.reply.is_closed()
        });
        let mut pending: Vec<_> = inner.pending.iter().collect();
        pending.sort_by_key(|(_, p)| p.started);
        if pending.is_empty() {
            return "No pending connections.".into();
        }
        let mut text = "Pairing code  Expires in".to_owned();
        for (code, p) in pending {
            let seconds = TTL.saturating_sub(p.started.elapsed().as_secs() as u32);
            text.push_str(&format!("\n{code}     {seconds}s"));
        }
        text
    }
    pub async fn allow(&self, code: &str) -> Result<(), String> {
        validate_code(code)?;
        let mut inner = self.inner.lock().await;
        let pending = inner
            .pending
            .get(code)
            .ok_or("Pairing code not found. Check the current code in the app.")?;
        if pending.started.elapsed() >= Duration::from_secs(TTL.into()) || pending.reply.is_closed()
        {
            inner.pending.remove(code);
            return Err("Pairing code is no longer valid. Reconnect in the app.".into());
        }
        let mut allowed = inner.allowed.clone();
        allowed.insert(pending.key.clone());
        self.persist(&allowed)
            .map_err(|_| "Failed to save client authorization. Connection not approved.")?;
        inner.allowed = allowed;
        let pending = inner.pending.remove(code).unwrap();
        pending.reply.send(()).map_err(|_| {
            "Authorization saved, but the client disconnected. Reconnect to continue.".to_owned()
        })
    }
    fn persist(&self, allowed: &HashSet<String>) -> io::Result<()> {
        use std::os::unix::fs::OpenOptionsExt;
        let temporary = self
            .directory
            .join(format!(".clients-{}", uuid::Uuid::new_v4()));
        let result = (|| {
            let mut file = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&temporary)?;
            file.write_all(&serde_json::to_vec(allowed).map_err(io::Error::other)?)?;
            file.sync_all()?;
            fs::rename(&temporary, self.directory.join("clients.json"))?;
            fs::File::open(&self.directory)?.sync_all()
        })();
        if result.is_err() {
            let _ = fs::remove_file(temporary);
        }
        result
    }
    pub async fn listen(self: &std::sync::Arc<Self>) -> io::Result<()> {
        use std::os::unix::fs::{FileTypeExt, PermissionsExt};
        let socket_directory = socket_directory(&self.directory)?;
        private_directory(&socket_directory)?;
        validate_socket_directory(&socket_directory, &self.directory)?;
        let path = socket_directory.join("admin.sock");
        if let Ok(metadata) = fs::symlink_metadata(&path) {
            if !metadata.file_type().is_socket() {
                return Err(io::Error::other("Invalid approval socket path"));
            }
            if UnixStream::connect(&path).await.is_ok() {
                return Err(io::Error::other(
                    "PiRC Server is already running for this user",
                ));
            }
            fs::remove_file(&path)?;
        }
        let listener = UnixListener::bind(&path)?;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
        let service = self.clone();
        tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                // Sequential, bounded, local-only requests. A stalled caller cannot hold the service forever.
                let mut bytes = [0u8; 10];
                let reply = match tokio::time::timeout(
                    Duration::from_secs(2),
                    socket.read_exact(&mut bytes),
                )
                .await
                {
                    Ok(Ok(_)) if &bytes == b"WAITLIST \n" => Ok(service.waitlist().await),
                    Ok(Ok(_)) if bytes[9] == b'\n' => match std::str::from_utf8(&bytes[..9]) {
                        Ok(code) => service
                            .allow(code)
                            .await
                            .map(|_| "Client authorized.".to_owned()),
                        Err(_) => Err("Invalid pairing code.".into()),
                    },
                    _ => Err("Invalid pairing code.".into()),
                };
                let message = match reply {
                    Ok(text) => format!("OK {text}"),
                    Err(text) => format!("ERR {text}"),
                };
                let _ = tokio::time::timeout(
                    Duration::from_secs(2),
                    socket.write_all(message.as_bytes()),
                )
                .await;
            }
        });
        Ok(())
    }
}
fn validate_code(code: &str) -> Result<(), String> {
    if code.len() != 9
        || code.as_bytes()[4] != b'-'
        || !code
            .bytes()
            .enumerate()
            .all(|(i, b)| i == 4 || b.is_ascii_uppercase() || b.is_ascii_digit())
    {
        return Err("Expected pairing code XXXX-XXXX (uppercase letters and digits).".into());
    }
    Ok(())
}
pub async fn cli_allow(code: &str) -> Result<(), String> {
    validate_code(code)?;
    admin_request(format!("{code}\n").as_bytes()).await?;
    println!("Client authorized.");
    Ok(())
}
pub async fn cli_waitlist() -> Result<(), String> {
    println!("{}", admin_request(b"WAITLIST \n").await?);
    Ok(())
}
async fn admin_request(request: &[u8]) -> Result<String, String> {
    let state = directory();
    let socket_directory = socket_directory(&state)
        .map_err(|_| "Cannot find the local PiRC Server. Make sure it is running.")?;
    validate_socket_directory(&socket_directory, &state)
        .map_err(|_| "Invalid permissions on the local authorization interface.")?;
    let mut socket = UnixStream::connect(socket_directory.join("admin.sock"))
        .await
        .map_err(|_| "Cannot connect to the local PiRC Server. Run it under the same user.")?;
    socket
        .write_all(request)
        .await
        .map_err(|_| "Failed to submit authorization request.")?;
    let mut reply = Vec::new();
    tokio::time::timeout(
        Duration::from_secs(5),
        socket.take(4096).read_to_end(&mut reply),
    )
    .await
    .map_err(|_| "Authorization request timed out. Check the server log.")?
    .map_err(|_| "Failed to read authorization response.")?;
    let reply = String::from_utf8(reply).map_err(|_| "Invalid server response.")?;
    if let Some(text) = reply.strip_prefix("OK ") {
        Ok(text.to_owned())
    } else {
        Err(reply
            .strip_prefix("ERR ")
            .unwrap_or("Invalid server response.")
            .to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn manager() -> Approval {
        Approval::open(
            std::env::temp_dir().join(format!("pirc-access-test-{}", uuid::Uuid::new_v4())),
        )
        .unwrap()
    }
    fn key() -> String {
        pirc_crypto::public_key(&pirc_crypto::generate_key().unwrap()).unwrap()
    }
    #[tokio::test]
    async fn waitlist_only_includes_live_requests_and_does_not_approve() {
        let manager = manager();
        assert_eq!(manager.waitlist().await, "No pending connections.");
        let client_key = key();
        let live = manager
            .request(client_key.clone(), "LIVE-2345".into())
            .await
            .unwrap();
        let expired = manager.request(key(), "EXPR-2345".into()).await.unwrap();
        let closed = manager.request(key(), "CLSD-2345".into()).await.unwrap();
        drop(closed);
        manager
            .inner
            .lock()
            .await
            .pending
            .get_mut("EXPR-2345")
            .unwrap()
            .started = Instant::now() - Duration::from_secs(TTL.into());
        let list = manager.waitlist().await;
        assert!(list.contains("LIVE-2345"));
        assert!(!list.contains("EXPR-2345"));
        assert!(!list.contains("CLSD-2345"));
        assert!(!manager.allowed(&client_key).await);
        assert!(!live.is_terminated());
        manager.cancel("LIVE-2345").await;
        assert_eq!(manager.waitlist().await, "No pending connections.");
        drop((live, expired));
        fs::remove_dir_all(manager.directory).unwrap();
    }
    #[tokio::test]
    async fn approvals_persist_and_codes_are_one_time() {
        use std::os::unix::fs::PermissionsExt;
        let manager = manager();
        let key = key();
        let receiver = manager
            .request(key.clone(), "ABCD-2345".into())
            .await
            .unwrap();
        assert!(!manager.allowed(&key).await);
        assert!(manager.allow("WRNG-2345").await.is_err());
        assert!(manager.allow("abcd-2345").await.is_err());
        assert!(!manager.allowed(&key).await);
        manager.allow("ABCD-2345").await.unwrap();
        receiver.await.unwrap();
        assert!(manager.allow("ABCD-2345").await.is_err());
        let restored = Approval::open(manager.directory.clone()).unwrap();
        assert!(restored.allowed(&key).await);
        assert_eq!(
            fs::metadata(manager.directory.join("clients.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        fs::remove_dir_all(manager.directory).unwrap();
    }
    #[tokio::test]
    async fn expired_cancelled_and_disconnected_requests_cannot_be_approved() {
        let manager = manager();
        let key = key();
        let receiver = manager
            .request(key.clone(), "ABCD-2345".into())
            .await
            .unwrap();
        manager
            .inner
            .lock()
            .await
            .pending
            .get_mut("ABCD-2345")
            .unwrap()
            .started = Instant::now() - Duration::from_secs(301);
        assert!(manager.allow("ABCD-2345").await.is_err());
        drop(receiver);
        let receiver = manager
            .request(key.clone(), "ABCD-2346".into())
            .await
            .unwrap();
        manager.cancel("ABCD-2346").await;
        assert!(manager.allow("ABCD-2346").await.is_err());
        drop(receiver);
        let receiver = manager
            .request(key.clone(), "ABCD-2347".into())
            .await
            .unwrap();
        drop(receiver);
        assert!(manager.allow("ABCD-2347").await.is_err());
        assert!(!manager.allowed(&key).await);
        assert!(!manager.directory.join("clients.json").exists());
        fs::remove_dir_all(manager.directory).unwrap();
    }
    #[tokio::test]
    async fn pending_requests_are_bounded_and_collisions_never_overwrite() {
        let manager = manager();
        let mut receivers = vec![];
        for i in 0..MAX_PENDING {
            receivers.push(
                manager
                    .request(key(), format!("ABCD-{i:04}"))
                    .await
                    .unwrap(),
            );
        }
        assert!(manager.request(key(), "WXYZ-2345".into()).await.is_err());
        assert!(manager.request(key(), "ABCD-0000".into()).await.is_err());
        drop(receivers);
        assert!(manager.request(key(), "WXYZ-2345".into()).await.is_ok());
        fs::remove_dir_all(manager.directory).unwrap();
    }
    #[test]
    fn invalid_or_public_approval_data_fails_closed() {
        use std::os::unix::fs::PermissionsExt;
        let manager = manager();
        let directory = manager.directory.clone();
        fs::write(directory.join("clients.json"), "broken").unwrap();
        fs::set_permissions(
            directory.join("clients.json"),
            fs::Permissions::from_mode(0o600),
        )
        .unwrap();
        assert!(Approval::open(directory.clone()).is_err());
        fs::write(directory.join("clients.json"), "[]").unwrap();
        fs::set_permissions(
            directory.join("clients.json"),
            fs::Permissions::from_mode(0o644),
        )
        .unwrap();
        assert!(Approval::open(directory.clone()).is_err());
        fs::remove_dir_all(directory).unwrap();
    }
}
