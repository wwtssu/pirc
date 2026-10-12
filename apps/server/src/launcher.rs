use crate::agents::AgentAdapter;
#[cfg(test)]
use crate::agents::PiAdapter;
use pirc_protocol::*;
use std::{
    collections::HashMap,
    path::PathBuf,
    process::Stdio,
    time::{Duration, Instant},
};
use tokio::{process::Command, sync::Mutex};

struct Launch {
    original: Message,
    result: Message,
    started: Instant,
    registered: bool,
}
pub struct Launcher {
    pub default_cwd: String,
    pub directories: crate::directories::DirectoryBrowser,
    agents: Vec<Box<dyn AgentAdapter>>,
    #[cfg(test)]
    terminal: Option<String>,
    headless: bool,
    port: u16,
    launches: Mutex<HashMap<String, Launch>>,
}
impl Launcher {
    pub async fn registered(&self, id: &str) {
        if let Some(launch) = self.launches.lock().await.get_mut(id) {
            launch.registered = true;
        }
    }
    pub fn new(port: u16) -> Self {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
        Self {
            default_cwd: std::env::var("HOME").unwrap_or_else(|_| "/tmp".into()),
            directories: crate::directories::DirectoryBrowser::new(),
            agents: crate::agents::adapters(&root),
            #[cfg(test)]
            terminal: None,
            headless: cfg!(target_os = "linux")
                && std::env::var_os("DISPLAY").is_none_or(|v| v.is_empty())
                && std::env::var_os("WAYLAND_DISPLAY").is_none_or(|v| v.is_empty()),
            port,
            launches: Mutex::new(HashMap::new()),
        }
    }
    fn adapter(&self, id: &str) -> Result<&dyn AgentAdapter, String> {
        self.agents
            .iter()
            .find(|a| a.info().id == id)
            .map(|a| a.as_ref())
            .ok_or_else(|| "Agent is not supported by this device".into())
    }
    pub async fn catalog(&self, online: &[(String, String)]) -> Result<Message, String> {
        let mut sessions = Vec::new();
        for adapter in &self.agents {
            sessions.extend(
                adapter
                    .saved_sessions()
                    .await?
                    .into_iter()
                    .map(|s| s.session)
                    .filter(|s| !online.contains(&(s.agent_id.clone(), s.session_id.clone()))),
            );
        }
        sessions.sort_by_key(|s| std::cmp::Reverse(s.modified_ms));
        sessions.truncate(1000);
        Ok(Message::SavedSessionList {
            agents: self.agents.iter().map(|a| a.info()).collect(),
            sessions,
            default_cwd: self.default_cwd.clone(),
        })
    }
    pub async fn launch(&self, id: &str, message: &Message) -> Result<Message, String> {
        let Message::LaunchSession {
            agent_id,
            cwd,
            session_id,
            name,
            create_cwd,
            ..
        } = message
        else {
            unreachable!()
        };
        let adapter = self.adapter(agent_id)?;
        let name = name.as_deref().unwrap_or("").trim();
        if name.chars().count() > 256 || name.contains(['\0', '\n', '\r']) {
            return Err("Session name is too long or contains invalid characters".into());
        }
        if session_id.is_some() && !name.is_empty() {
            return Err("An initial name cannot be set when restoring a session".into());
        }
        let mut launches = self.launches.lock().await;
        launches.retain(|_, l| l.started.elapsed() < Duration::from_secs(600));
        if let Some(previous) = launches.get(id) {
            return if previous.original == *message {
                Ok(previous.result.clone())
            } else {
                Err("Request ID was used for another operation".into())
            };
        }
        // A lost acknowledgement must not open a second terminal on a quick retry.
        if let Some((_, previous)) = launches.iter().find(|(_, l)| {
            !l.registered && l.original == *message && l.started.elapsed() < Duration::from_secs(45)
        }) {
            return Ok(previous.result.clone());
        }
        let stored = if let Some(sid) = session_id {
            Some(
                adapter
                    .saved_sessions()
                    .await?
                    .into_iter()
                    .find(|s| s.session.session_id == *sid)
                    .ok_or("Saved session no longer exists. Refresh the list.")?,
            )
        } else {
            None
        };
        let cwd = stored
            .as_ref()
            .map_or(cwd.as_str(), |s| s.session.cwd.as_str());
        let cwd = if cwd == "~" {
            PathBuf::from(&self.default_cwd)
        } else if let Some(path) = cwd.strip_prefix("~/") {
            PathBuf::from(&self.default_cwd).join(path)
        } else {
            PathBuf::from(cwd)
        };
        if !cwd.is_absolute() {
            return Err("Enter an absolute directory path on the device".into());
        }
        match self
            .directories
            .prepare(&cwd.to_string_lossy(), *create_cwd)
            .await
        {
            Message::WorkingDirectoryReady { .. } => {}
            missing @ Message::WorkingDirectoryMissing { .. } => return Ok(missing),
            Message::Error { detail, .. } => return Err(detail),
            _ => return Err("Unable to prepare the working directory".into()),
        }
        let search_path = std::env::var_os("PATH").unwrap_or_default();
        let args = adapter.command(stored.as_ref().map(|s| s.path.as_path()), &search_path)?;
        #[cfg(not(test))]
        let terminal: Option<&str> = None;
        #[cfg(test)]
        let terminal = self.terminal.as_deref();
        let headless = self.headless && terminal.is_none();
        let tmux = if headless {
            Some(
                executable_path("tmux", &search_path)
                    .ok_or("This device has no graphical environment. Install tmux and retry.")?,
            )
        } else {
            None
        };
        let script = terminal_script(
            &cwd.to_string_lossy(),
            &args,
            &format!("ws://127.0.0.1:{}/extension", self.port),
            id,
            stored.is_some(),
            name,
            &search_path.to_string_lossy(),
            adapter.environment_keys(),
        );
        let dir = std::env::temp_dir().join(format!("pirc-launches-{}", std::process::id()));
        tokio::fs::create_dir_all(&dir)
            .await
            .map_err(|_| "Unable to prepare terminal launch file")?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            tokio::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))
                .await
                .map_err(|_| "Unable to protect terminal launch file")?;
        }
        // Use a generated filename; request IDs are never interpreted as paths.
        let path = dir.join(format!("{}.command", uuid::Uuid::new_v4()));
        tokio::fs::write(&path, script)
            .await
            .map_err(|_| "Unable to create terminal launch file")?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            tokio::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700))
                .await
                .map_err(|_| "Unable to protect terminal launch file")?;
        }
        // A dedicated profile runs this script as the terminal's shell process.
        // Its exit policy belongs to this launch, without changing default profiles
        // or driving Terminal's UI to find and close a window later.
        let terminal_path = if cfg!(target_os = "macos") && terminal.is_none() && !headless {
            let profile = path.with_extension("terminal");
            tokio::fs::write(&profile, terminal_profile(&path.to_string_lossy()))
                .await
                .map_err(|_| "Unable to create terminal configuration")?;
            profile
        } else {
            path.clone()
        };
        let mut command = if let Some(terminal) = terminal {
            Command::new(terminal)
        } else if let Some(tmux) = tmux {
            let mut c = Command::new(tmux);
            #[cfg(not(test))]
            let socket = "pirc".to_owned();
            // Unit tests use a private socket and never touch live agent sessions.
            #[cfg(test)]
            let socket = format!("pirc-test-{}", self.port);
            let session = format!("pirc-{}", path.file_stem().unwrap().to_string_lossy());
            c.args([
                "-f",
                "/dev/null",
                "-L",
                &socket,
                "new-session",
                "-d",
                "-s",
                &session,
                "-x",
                "120",
                "-y",
                "40",
            ]);
            c.arg(format!("exec {}", quote(&path.to_string_lossy())));
            c
        } else if cfg!(target_os = "macos") {
            let mut c = Command::new("open");
            c.args(["-a", "Terminal"]);
            c
        } else {
            let mut c = Command::new("x-terminal-emulator");
            c.arg("-e");
            c
        };
        if !headless {
            command.arg(&terminal_path);
        }
        command
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        let status = tokio::time::timeout(Duration::from_secs(10), command.status()).await;
        if !matches!(status, Ok(Ok(s)) if s.success()) {
            eprintln!(
                "{} launch failed",
                if headless {
                    "Headless tmux session"
                } else {
                    "Terminal"
                }
            );
            let _ = tokio::fs::remove_file(&terminal_path).await;
            let _ = tokio::fs::remove_file(&path).await;
            return Err(if headless {
                "Unable to start background session. Check tmux and the agent installation."
            } else {
                "Unable to open terminal. Check the agent and terminal configuration."
            }
            .into());
        }
        let result = Message::SessionLaunched {
            launch_id: id.into(),
            instance_id: None,
        };
        launches.insert(
            id.into(),
            Launch {
                original: message.clone(),
                result: result.clone(),
                started: Instant::now(),
                registered: false,
            },
        );
        Ok(result)
    }
}
fn quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}
pub(crate) fn executable_path(program: &str, search_path: &std::ffi::OsStr) -> Option<PathBuf> {
    let path = std::path::Path::new(program);
    let candidates = if path.is_absolute() || path.components().count() > 1 {
        vec![path.to_path_buf()]
    } else {
        std::env::split_paths(search_path)
            .map(|dir| dir.join(path))
            .collect()
    };
    candidates
        .into_iter()
        .find(|path| {
            let Ok(metadata) = std::fs::metadata(path) else {
                return false;
            };
            if !metadata.is_file() {
                return false;
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                metadata.permissions().mode() & 0o111 != 0
            }
            #[cfg(not(unix))]
            {
                true
            }
        })
        .and_then(|path| path.canonicalize().ok())
}
fn terminal_profile(script: &str) -> String {
    let name = std::path::Path::new(script)
        .file_stem()
        .unwrap_or_default()
        .to_string_lossy()
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;");
    // Terminal retains imported profiles after this one-shot script is consumed.
    // Reopening a stale window must neither fail nor launch a second agent process.
    let script = quote(script);
    let command = format!("if [ -f {script} ]; then exec {script}; else exit 0; fi")
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;");
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
         <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
         <plist version=\"1.0\"><dict>\n\
         <key>name</key><string>PiRC · {name}</string>\n\
         <key>type</key><string>Window Settings</string>\n\
         <key>ProfileCurrentVersion</key><real>2.07</real>\n\
         <key>CommandString</key><string>{command}</string>\n\
         <key>RunCommandAsShell</key><false/>\n\
         <key>shellExitAction</key><integer>0</integer>\n\
         <key>ShouldRestoreContent</key><false/>\n\
         </dict></plist>\n"
    )
}
#[allow(clippy::too_many_arguments)]
fn terminal_script(
    cwd: &str,
    args: &[String],
    url: &str,
    launch_id: &str,
    restore: bool,
    name: &str,
    search_path: &str,
    environment_keys: &[&str],
) -> String {
    let shell = if cfg!(target_os = "macos") {
        "#!/bin/zsh -l"
    } else {
        "#!/bin/sh"
    };
    let inherited = environment_keys
        .iter()
        .map(|key| {
            // An already-running Terminal may retain another launch's environment.
            // Both configured and absent agent overrides must match this server.
            match std::env::var(key) {
                Ok(value) => format!("export {key}={}\n", quote(&value)),
                Err(_) => format!("unset {key}\n"),
            }
        })
        .collect::<String>();
    format!("{shell}\n{inherited}export PATH={}\nexport PIRC_URL={}\nexport PIRC_LAUNCH_ID={}\nexport PIRC_INITIAL_NAME={}\nexport PIRC_MANAGED_TERMINAL=1\nexport PIRC_RESTORE_HISTORY={}\nrm -f -- \"${{0%.command}}.terminal\"\ncd {} || exit 1\nrm -- \"$0\"\nexec {}\n", quote(search_path), quote(url), quote(launch_id), quote(name), if restore { 1 } else { 0 }, quote(cwd), args.iter().map(|s| quote(s)).collect::<Vec<_>>().join(" "))
}

#[cfg(test)]
mod tests {
    use super::*;
    struct FixtureAdapter(&'static str);
    impl AgentAdapter for FixtureAdapter {
        fn info(&self) -> AgentInfo {
            AgentInfo {
                id: self.0.into(),
                name: self.0.into(),
            }
        }
        fn environment_keys(&self) -> &[&str] {
            &[]
        }
        fn command(
            &self,
            session: Option<&std::path::Path>,
            _: &std::ffi::OsStr,
        ) -> Result<Vec<String>, String> {
            Ok(vec![
                self.0.into(),
                session.unwrap().to_string_lossy().into(),
            ])
        }
        fn saved_sessions(
            &self,
        ) -> std::pin::Pin<
            Box<
                dyn std::future::Future<Output = Result<Vec<crate::agents::StoredSession>, String>>
                    + Send
                    + '_,
            >,
        > {
            Box::pin(async move {
                Ok(vec![crate::agents::StoredSession {
                    session: SavedSession {
                        agent_id: self.0.into(),
                        session_id: "shared-id".into(),
                        cwd: "/workspace".into(),
                        name: None,
                        modified_ms: 1,
                    },
                    path: PathBuf::from(format!("/history/{}", self.0)),
                }])
            })
        }
    }
    #[tokio::test]
    async fn catalog_keeps_same_session_id_from_another_agent() {
        let mut launcher = Launcher::new(43123);
        launcher.agents = vec![
            Box::new(FixtureAdapter("first")),
            Box::new(FixtureAdapter("second")),
        ];
        let Message::SavedSessionList {
            agents, sessions, ..
        } = launcher
            .catalog(&[("first".into(), "shared-id".into())])
            .await
            .unwrap()
        else {
            panic!()
        };
        assert_eq!(agents.len(), 2);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].agent_id, "second");
        let selected = launcher.adapter(&sessions[0].agent_id).unwrap();
        let saved = selected.saved_sessions().await.unwrap();
        assert_eq!(
            selected
                .command(Some(&saved[0].path), std::ffi::OsStr::new(""))
                .unwrap(),
            vec!["second", "/history/second"]
        );
        let unsupported = Message::LaunchSession {
            agent_id: "unknown".into(),
            generation_id: "g".into(),
            cwd: "/does-not-exist".into(),
            session_id: None,
            name: None,
            create_cwd: true,
        };
        assert_eq!(
            launcher.launch("unknown", &unsupported).await.unwrap_err(),
            "Agent is not supported by this device"
        );
        assert!(launcher.launches.lock().await.is_empty());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn headless_launch_has_a_tty_and_removes_session_on_exit() {
        use std::os::unix::fs::PermissionsExt;
        struct Cleanup(String);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = std::process::Command::new("tmux")
                    .args(["-L", &self.0, "kill-server"])
                    .output();
            }
        }
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let socket = format!("pirc-test-{port}");
        let _cleanup = Cleanup(socket.clone());
        let dir = std::env::temp_dir().join(format!("pirc-headless-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let marker = dir.join("started");
        let finish = dir.join("finish");
        let pi = dir.join("fake pi 'quoted");
        std::fs::write(&pi, format!("#!/bin/sh\ntest -t 0 && test -t 1 || exit 1\nprintf '%s' \"$PIRC_LAUNCH_ID\" > {}\nwhile [ ! -f {} ]; do sleep 0.1; done\n", quote(&marker.to_string_lossy()), quote(&finish.to_string_lossy()))).unwrap();
        std::fs::set_permissions(&pi, std::fs::Permissions::from_mode(0o700)).unwrap();
        let extension = dir.join("extension.ts");
        std::fs::write(&extension, "").unwrap();
        let launcher = Launcher {
            default_cwd: dir.to_string_lossy().into(),
            directories: crate::directories::DirectoryBrowser::new(),
            agents: vec![Box::new(PiAdapter {
                helper: PathBuf::new(),
                extension,
                node: "node".into(),
                executable: pi.to_string_lossy().into(),
            })],
            terminal: None,
            headless: true,
            port,
            launches: Mutex::new(HashMap::new()),
        };
        let message = Message::LaunchSession {
            agent_id: "pi".into(),
            generation_id: "g".into(),
            cwd: dir.to_string_lossy().into(),
            session_id: None,
            name: None,
            create_cwd: false,
        };
        let first = launcher.launch("headless", &message).await.unwrap();
        assert_eq!(launcher.launch("headless", &message).await.unwrap(), first);
        let deadline = Instant::now() + Duration::from_secs(5);
        while !marker.exists() {
            assert!(Instant::now() < deadline, "headless process did not start");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert_eq!(std::fs::read_to_string(&marker).unwrap(), "headless");
        let output = Command::new("tmux")
            .args(["-L", &socket, "list-sessions", "-F", "#{session_name}"])
            .output()
            .await
            .unwrap();
        assert!(output.status.success());
        assert_eq!(String::from_utf8(output.stdout).unwrap().lines().count(), 1);
        std::fs::write(&finish, "").unwrap();
        loop {
            let status = Command::new("tmux")
                .args(["-L", &socket, "has-session"])
                .output()
                .await
                .unwrap();
            if !status.status.success() {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "headless session survived process exit"
            );
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[cfg(unix)]
    #[tokio::test]
    async fn launch_retries_open_once_and_registered_sessions_allow_a_new_launch() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("pirc-launch-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let count = dir.join("count");
        let terminal = dir.join("terminal");
        std::fs::write(
            &terminal,
            format!(
                "#!/bin/sh\nprintf '.\\n' >> {}\nrm -- \"$1\"\n",
                quote(&count.to_string_lossy())
            ),
        )
        .unwrap();
        std::fs::set_permissions(&terminal, std::fs::Permissions::from_mode(0o700)).unwrap();
        let extension = dir.join("extension.ts");
        std::fs::write(&extension, "").unwrap();
        let launcher = Launcher {
            default_cwd: dir.to_string_lossy().into(),
            directories: crate::directories::DirectoryBrowser::new(),
            agents: vec![Box::new(PiAdapter {
                helper: PathBuf::new(),
                extension,
                node: "node".into(),
                executable: terminal.to_string_lossy().into(),
            })],
            terminal: Some(terminal.to_string_lossy().into()),
            headless: false,
            port: 43123,
            launches: Mutex::new(HashMap::new()),
        };
        let message = Message::LaunchSession {
            agent_id: "pi".into(),
            generation_id: "g".into(),
            cwd: dir.to_string_lossy().into(),
            session_id: None,
            name: None,
            create_cwd: false,
        };
        let first = launcher.launch("first", &message).await.unwrap();
        assert_eq!(launcher.launch("first", &message).await.unwrap(), first);
        assert_eq!(launcher.launch("retry", &message).await.unwrap(), first);
        assert_eq!(std::fs::read_to_string(&count).unwrap().lines().count(), 1);
        launcher.registered("first").await;
        launcher.launch("second", &message).await.unwrap();
        assert_eq!(std::fs::read_to_string(&count).unwrap().lines().count(), 2);
        let other = Message::LaunchSession {
            agent_id: "pi".into(),
            generation_id: "g".into(),
            cwd: "/".into(),
            session_id: None,
            name: None,
            create_cwd: false,
        };
        assert!(launcher.launch("first", &other).await.is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn terminal_paths_and_arguments_are_shell_quoted() {
        let script = terminal_script(
            "/tmp/a'$(touch bad)",
            &["pi".into(), "/tmp/a b.jsonl".into()],
            "ws://localhost",
            "id",
            false,
            "Title'`bad`",
            "/tmp/bin'`bad`:/usr/bin:/bin",
            &[],
        );
        assert!(script.contains("cd '/tmp/a'\\''$(touch bad)'"));
        assert!(script.contains("export PIRC_INITIAL_NAME='Title'\\''`bad`'"));
        assert!(script.contains("exec 'pi' '/tmp/a b.jsonl'"));
        assert!(script.contains("export PATH='/tmp/bin'\\''`bad`:/usr/bin:/bin'"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn login_terminal_finds_pi_and_its_runtime_without_interactive_shell_config() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("pirc-login-test-{}", uuid::Uuid::new_v4()));
        let bin = dir.join("bin café 'quote");
        std::fs::create_dir_all(&bin).unwrap();
        for (name, contents) in [
            ("pi", "#!/usr/bin/env pirc-test-runtime\n"),
            ("pirc-test-runtime", "#!/bin/sh\nprintf started > started\nprintf '%s\\n' \"${PI_CODING_AGENT_DIR-unset}\" \"${PI_CODING_AGENT_SESSION_DIR-unset}\" \"${PI_OFFLINE-unset}\" \"${PI_TELEMETRY-unset}\" > environment\n"),
        ] {
            let path = bin.join(name);
            std::fs::write(&path, contents).unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let search_path = format!("{}:/usr/bin:/bin", bin.to_string_lossy());
        let pi = executable_path("pi", std::ffi::OsStr::new(&search_path)).unwrap();
        assert!(pi.is_absolute());
        assert!(executable_path("missing-pi", std::ffi::OsStr::new(&search_path)).is_none());
        let script = dir.join("launch.command");
        std::fs::write(
            &script,
            terminal_script(
                &dir.to_string_lossy(),
                &[pi.to_string_lossy().into()],
                "ws://localhost",
                "id",
                false,
                "",
                &search_path,
                PiAdapter::new(&dir).environment_keys(),
            ),
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
        let output = std::process::Command::new("/usr/bin/env")
            .args([
                "-i",
                "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
                "PI_CODING_AGENT_DIR=/tmp/stale-pirc-agent",
                "PI_CODING_AGENT_SESSION_DIR=/tmp/stale-pirc-sessions",
                "PI_OFFLINE=1",
                "PI_TELEMETRY=0",
            ])
            .arg(&script)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(output.stderr.is_empty());
        let expected = [
            "PI_CODING_AGENT_DIR",
            "PI_CODING_AGENT_SESSION_DIR",
            "PI_OFFLINE",
            "PI_TELEMETRY",
        ]
        .map(|key| std::env::var(key).unwrap_or_else(|_| "unset".into()))
        .join("\n")
            + "\n";
        assert_eq!(
            std::fs::read_to_string(dir.join("environment")).unwrap(),
            expected
        );
        assert_eq!(
            std::fs::read_to_string(dir.join("started")).unwrap(),
            "started"
        );
        assert!(!script.exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn managed_terminal_profile_is_valid_and_closes_on_shell_exit() {
        let profile = terminal_profile("/tmp/a & <b> 'Unicode.command");
        let path = std::env::temp_dir().join(format!(
            "pirc-profile-test-{}.terminal",
            uuid::Uuid::new_v4()
        ));
        std::fs::write(&path, &profile).unwrap();
        let valid = std::process::Command::new("plutil")
            .args(["-lint", "--"])
            .arg(&path)
            .output()
            .unwrap();
        std::fs::remove_file(path).unwrap();
        assert!(
            valid.status.success(),
            "{}",
            String::from_utf8_lossy(&valid.stderr)
        );
        assert!(profile.contains("<key>shellExitAction</key><integer>0</integer>"));
        assert!(profile.contains("<key>RunCommandAsShell</key><false/>"));
        assert!(profile.contains("<key>CommandString</key><string>if [ -f "));
        assert!(profile.contains("&amp; &lt;b&gt;"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn consumed_terminal_profile_does_not_fail_or_launch_again() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("pirc-profile-run-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let script = dir.join("a & <b> 'Unicode $(touch unwanted).command");
        std::fs::write(
            &script,
            "#!/bin/sh\nprintf started >> started\nrm -- \"$0\"\n",
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
        let profile = dir.join("launch.terminal");
        std::fs::write(&profile, terminal_profile(&script.to_string_lossy())).unwrap();
        let extracted = std::process::Command::new("plutil")
            .args(["-extract", "CommandString", "raw", "-o", "-", "--"])
            .arg(&profile)
            .output()
            .unwrap();
        assert!(extracted.status.success());
        let command = String::from_utf8(extracted.stdout).unwrap();
        for _ in 0..2 {
            let output = std::process::Command::new("/bin/zsh")
                .args(["-f", "-c", &command])
                .current_dir(&dir)
                .output()
                .unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            assert!(output.stderr.is_empty());
            assert_eq!(
                std::fs::read_to_string(dir.join("started")).unwrap(),
                "started"
            );
            assert!(!script.exists());
            assert!(!dir.join("unwanted").exists());
        }
        std::fs::remove_dir_all(dir).unwrap();
    }
}
