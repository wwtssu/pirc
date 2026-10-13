use super::{AgentAdapter, StoredSession};
use pirc_protocol::AgentInfo;
use std::{
    ffi::OsStr,
    future::Future,
    path::{Path, PathBuf},
    pin::Pin,
    time::Duration,
};
use tokio::process::Command;

pub(crate) struct OmpAdapter {
    pub helper: PathBuf,
    pub extension: PathBuf,
    pub node: String,
    pub executable: String,
}
impl OmpAdapter {
    pub fn new(root: &Path) -> Self {
        Self {
            helper: root.join("extensions/omp/sessions.mjs"),
            extension: root.join("extensions/omp/index.ts"),
            node: "node".into(),
            executable: "omp".into(),
        }
    }
}
impl AgentAdapter for OmpAdapter {
    fn info(&self) -> AgentInfo {
        AgentInfo {
            id: "omp".into(),
            name: "OMP".into(),
        }
    }
    fn saved_sessions(
        &self,
    ) -> Pin<Box<dyn Future<Output = Result<Vec<StoredSession>, String>> + Send + '_>> {
        Box::pin(async move {
            let output = tokio::time::timeout(
                Duration::from_secs(15),
                Command::new(&self.node)
                    .arg(&self.helper)
                    .kill_on_drop(true)
                    .output(),
            )
            .await
            .map_err(|_| "Reading saved sessions timed out. Try again.")?
            .map_err(|_| "Unable to read saved sessions. Check the device server.")?;
            if !output.status.success() {
                return Err("Unable to read saved sessions. Check the device server.".into());
            }
            let sessions: Vec<StoredSession> = serde_json::from_slice(&output.stdout)
                .map_err(|_| "Unable to read saved session data")?;
            if sessions
                .iter()
                .any(|s| s.session.agent_id != self.info().id)
            {
                return Err("Saved session belongs to another agent".into());
            }
            Ok(sessions)
        })
    }
    fn environment_keys(&self) -> &[&str] {
        &[
            "PI_CODING_AGENT_DIR",
            "PI_CODING_AGENT_SESSION_DIR",
            "OMP_PROFILE",
            "PI_PROFILE",
            "XDG_DATA_HOME",
            "XDG_STATE_HOME",
            "XDG_CACHE_HOME",
        ]
    }
    fn command(&self, session: Option<&Path>, search_path: &OsStr) -> Result<Vec<String>, String> {
        if !self.extension.is_file() {
            return Err("PiRC adapter not found. Check the device server installation.".into());
        }
        if session.is_some_and(|path| !path.is_file()) {
            return Err("Session file no longer exists. Refresh the list.".into());
        }
        let executable = crate::launcher::executable_path(&self.executable, search_path)
            .ok_or("Agent executable not found. Check the device installation.")?;
        let mut args = vec![
            executable.to_string_lossy().into_owned(),
            "-e".into(),
            self.extension.to_string_lossy().into_owned(),
        ];
        if let Some(path) = session {
            args.extend(["--resume".into(), path.to_string_lossy().into_owned()]);
        }
        Ok(args)
    }
}
