use pirc_protocol::Message;
use std::{path::PathBuf, process::Stdio, time::Duration};
use tokio::{io::AsyncReadExt, process::Command, sync::Semaphore};

pub struct DirectoryBrowser {
    node: String,
    helper: PathBuf,
    home: String,
    slots: Semaphore,
    timeout: Duration,
}
impl DirectoryBrowser {
    pub fn new() -> Self {
        Self {
            node: "node".into(),
            helper: PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../scripts/list-directories.mjs"),
            home: std::env::var("HOME").unwrap_or_else(|_| "/tmp".into()),
            slots: Semaphore::new(2),
            timeout: Duration::from_secs(5),
        }
    }
    pub async fn browse(
        &self,
        path: Option<&str>,
        cursor: Option<&str>,
        show_hidden: bool,
    ) -> Message {
        self.run(path, cursor, show_hidden, None).await
    }
    pub async fn create(&self, parent: &str, name: &str) -> Message {
        if name.trim().is_empty()
            || name == "."
            || name == ".."
            || name.len() > 255
            || name.contains(['/', '\\', '\0'])
        {
            return Message::Error {
                code: "INVALID_DIRECTORY_NAME".into(),
                detail: "Enter a single folder name without / or backslash, at most 255 bytes"
                    .into(),
            };
        }
        if parent.is_empty() {
            return Message::Error {
                code: "INVALID_DIRECTORY".into(),
                detail: "Open the parent directory before creating a folder".into(),
            };
        }
        self.run(Some(parent), None, false, Some(name)).await
    }
    async fn run(
        &self,
        path: Option<&str>,
        cursor: Option<&str>,
        show_hidden: bool,
        name: Option<&str>,
    ) -> Message {
        let fail = |code: &str, detail: &str| Message::Error {
            code: code.into(),
            detail: detail.into(),
        };
        if path.is_some_and(|p| p.len() > 4096 || p.contains('\0'))
            || cursor.is_some_and(|c| c.len() > 1024 || c.contains('\0'))
        {
            return fail("INVALID_DIRECTORY", "Directory path is too long or invalid");
        }
        let Ok(_permit) = self.slots.try_acquire() else {
            return fail(
                "DIRECTORY_BUSY",
                "Device is processing a directory. Try again later.",
            );
        };
        // A timeout on spawn_blocking/tokio::fs doesn't cancel a filesystem call
        // awaiting macOS consent. A child process gives it a bounded lifetime.
        let mut child = match Command::new(&self.node)
            .arg(&self.helper)
            .args([
                self.home.as_str(),
                path.unwrap_or(""),
                cursor.unwrap_or(""),
                if show_hidden { "true" } else { "false" },
                if name.is_some() { "create" } else { "browse" },
                name.unwrap_or(""),
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
        {
            Ok(child) => child,
            Err(_) => {
                return fail(
                    "DIRECTORY_UNAVAILABLE",
                    "Unable to browse directories. Check the device server.",
                )
            }
        };
        let mut stdout = child.stdout.take().unwrap().take(1024 * 1024 + 1);
        let mut bytes = Vec::new();
        let read = async {
            stdout.read_to_end(&mut bytes).await?;
            if bytes.len() > 1024 * 1024 {
                return Err(std::io::Error::other("Output too large"));
            }
            let status = child.wait().await?;
            if !status.success() {
                return Err(std::io::Error::other("Directory helper failed"));
            }
            Ok::<_, std::io::Error>(())
        };
        match tokio::time::timeout(self.timeout, read).await {
            Err(_) => {
                let _ = child.start_kill();
                fail(
                    "DIRECTORY_TIMEOUT",
                    if name.is_some() {
                        "Folder creation timed out and is unconfirmed. Close and refresh the directory before retrying."
                    } else {
                        "Reading timed out. The directory may be unavailable or awaiting device permission. Choose another directory."
                    },
                )
            }
            Ok(Err(_)) => fail(
                "DIRECTORY_UNAVAILABLE",
                if name.is_some() {
                    "Creation is unconfirmed. Close and refresh the directory before retrying."
                } else {
                    "Unable to read this directory. Retry or choose another directory."
                },
            ),
            Ok(Ok(())) => match serde_json::from_slice(&bytes) {
                Ok(message @ Message::Error { .. }) => message,
                Ok(message @ Message::DirectoryList { .. }) if name.is_none() => message,
                Ok(message @ Message::DirectoryCreated { .. }) if name.is_some() => message,
                _ => fail(
                    "DIRECTORY_UNAVAILABLE",
                    "Unable to read directory data returned by the device",
                ),
            },
        }
    }
}
