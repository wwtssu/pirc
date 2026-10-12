use pirc_protocol::{AgentInfo, SavedSession};
use serde::Deserialize;
use std::{
    ffi::OsStr,
    future::Future,
    path::{Path, PathBuf},
    pin::Pin,
};
mod pi;
#[cfg(test)]
pub(crate) use pi::PiAdapter;

#[derive(Deserialize)]
pub(crate) struct StoredSession {
    #[serde(flatten)]
    pub session: SavedSession,
    pub path: PathBuf,
}

/// Agent-specific discovery and command construction. Terminal ownership,
/// launch deduplication and registration remain the server's responsibility.
pub(crate) trait AgentAdapter: Send + Sync {
    fn info(&self) -> AgentInfo;
    fn saved_sessions(
        &self,
    ) -> Pin<Box<dyn Future<Output = Result<Vec<StoredSession>, String>> + Send + '_>>;
    fn environment_keys(&self) -> &[&str];
    fn command(&self, session: Option<&Path>, search_path: &OsStr) -> Result<Vec<String>, String>;
}

/// Built-in adapters supported by this server installation.
pub(crate) fn adapters(root: &Path) -> Vec<Box<dyn AgentAdapter>> {
    vec![Box::new(pi::PiAdapter::new(root))]
}
