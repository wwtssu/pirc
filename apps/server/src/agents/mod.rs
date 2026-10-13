use pirc_protocol::{AgentInfo, SavedSession};
use serde::Deserialize;
use std::{
    ffi::OsStr,
    future::Future,
    path::{Path, PathBuf},
    pin::Pin,
};
mod omp;
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
    fn command(
        &self,
        cwd: &Path,
        session: Option<&Path>,
        search_path: &OsStr,
    ) -> Result<Vec<String>, String>;
}

/// Built-in adapters supported by this server installation.
pub(crate) fn adapters(root: &Path) -> Vec<Box<dyn AgentAdapter>> {
    let search_path = std::env::var_os("PATH").unwrap_or_default();
    let mut adapters: Vec<Box<dyn AgentAdapter>> = Vec::new();
    if crate::launcher::executable_path("pi", &search_path).is_some() {
        adapters.push(Box::new(pi::PiAdapter::new(root)));
    }
    if crate::launcher::executable_path("omp", &search_path).is_some() {
        adapters.push(Box::new(omp::OmpAdapter::new(root)));
    }
    adapters
}
