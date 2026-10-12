use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use ts_rs::TS;

pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum SessionState {
    Idle,
    Running,
    Stopping,
    Offline,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema, TS)]
#[serde(deny_unknown_fields)]
pub struct SlashCommand {
    pub name: String,
    pub description: Option<String>,
    pub source: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum BuiltinCommand {
    Model,
    Thinking,
    Name,
    Session,
    Compact,
}
impl BuiltinCommand {
    pub fn parse(name: &str) -> Option<Self> {
        Some(match name {
            "model" => Self::Model,
            "thinking" => Self::Thinking,
            "name" => Self::Name,
            "session" => Self::Session,
            "compact" => Self::Compact,
            _ => return None,
        })
    }
    pub fn name(&self) -> &'static str {
        match self {
            Self::Model => "model",
            Self::Thinking => "thinking",
            Self::Name => "name",
            Self::Session => "session",
            Self::Compact => "compact",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema, TS)]
#[serde(deny_unknown_fields)]
pub struct ModelInfo {
    pub provider: String,
    pub id: String,
    pub name: String,
    pub reasoning: bool,
    pub context_window: u32,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema, TS)]
#[serde(deny_unknown_fields)]
pub struct SessionControls {
    pub model: Option<ModelInfo>,
    pub thinking_level: String,
    pub thinking_levels: Vec<String>,
    pub compacting: bool,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema, TS)]
#[serde(deny_unknown_fields)]
pub struct SessionInfo {
    pub session_id: String,
    pub name: Option<String>,
    pub cwd: String,
    pub session_file: Option<String>,
    pub user_messages: u32,
    pub assistant_messages: u32,
    pub tool_calls: u32,
    pub tool_results: u32,
    pub total_messages: u32,
    #[ts(type = "number")]
    pub input_tokens: u64,
    #[ts(type = "number")]
    pub output_tokens: u64,
    #[ts(type = "number")]
    pub cache_read_tokens: u64,
    #[ts(type = "number")]
    pub cache_write_tokens: u64,
    pub cost_usd: String,
    #[ts(type = "number | null")]
    pub context_tokens: Option<u64>,
    pub context_window: u32,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema, TS)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum CommandData {
    Model {
        current: Option<ModelInfo>,
        models: Vec<ModelInfo>,
    },
    Thinking {
        level: String,
        levels: Vec<String>,
    },
    Name {
        name: Option<String>,
    },
    Session {
        info: SessionInfo,
    },
    Compact {
        summary: String,
        #[ts(type = "number")]
        tokens_before: u64,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema, TS)]
#[serde(deny_unknown_fields)]
pub struct SessionSnapshot {
    pub session_id: String,
    pub instance_id: String,
    pub cwd: String,
    pub name: Option<String>,
    pub state: SessionState,
    #[ts(type = "number")]
    pub revision: u64,
    pub needs_local_attention: bool,
    #[serde(default)]
    pub slash_commands: Option<Vec<SlashCommand>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub controls: Option<SessionControls>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub launch_id: Option<String>,
    /// Extension supports graceful exit for this Server-launched terminal.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub can_close: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema, TS)]
#[serde(deny_unknown_fields)]
pub struct SavedSession {
    pub session_id: String,
    pub cwd: String,
    pub name: Option<String>,
    #[ts(type = "number")]
    pub modified_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema, TS)]
#[serde(deny_unknown_fields)]
pub struct DirectoryEntry {
    pub name: String,
    pub path: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum CommandStatus {
    Accepted,
    Completed,
    Rejected,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum EventKind {
    AgentStart,
    AgentSettled,
    UserMessage,
    MessageStart,
    TextStart,
    MessageDelta,
    TextEnd,
    ThinkingStart,
    ThinkingDelta,
    ThinkingEnd,
    ToolCallStart,
    ToolCallDelta,
    ToolCallEnd,
    MessageEnd,
    ToolStart,
    ToolUpdate,
    ToolEnd,
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema, TS)]
#[serde(deny_unknown_fields)]
pub struct EventData {
    pub kind: EventKind,
    pub message_id: Option<String>,
    /// Stable content block position within an assistant message.
    pub content_index: Option<u32>,
    pub text: Option<String>,
    pub tool_call_id: Option<String>,
    pub tool_name: Option<String>,
    pub is_error: bool,
    pub truncated: bool,
}

/// A materialized content block. Pages never split its stream of deltas.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema, TS)]
#[serde(deny_unknown_fields)]
pub struct TranscriptItem {
    pub id: String,
    pub role: String,
    pub text: String,
    pub title: Option<String>,
    pub arguments: Option<String>,
    pub phase: Option<String>,
    pub complete: bool,
    pub is_error: bool,
    pub truncated: bool,
    #[ts(type = "number")]
    pub first_seq: u64,
    #[ts(type = "number")]
    pub last_seq: u64,
    pub message_id: Option<String>,
    pub content_index: Option<u32>,
    pub tool_call_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum HistoryDirection {
    Latest,
    Before,
    After,
    Around,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Message {
    PairingRequest {},
    PairingRequired {
        code: String,
        expires_in: u32,
    },
    PairingApproved {},
    Auth {},
    Welcome {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        server_id: Option<String>,
        generation_id: String,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        history_paging: bool,
    },
    Register {
        session: SessionSnapshot,
    },
    Snapshot {
        session: SessionSnapshot,
    },
    Heartbeat {
        session: SessionSnapshot,
        #[ts(type = "number")]
        source_seq: u64,
    },
    Unregister {
        session_id: String,
        instance_id: String,
    },
    List {},
    Sessions {
        sessions: Vec<SessionSnapshot>,
    },
    SavedSessions {},
    SavedSessionList {
        sessions: Vec<SavedSession>,
        default_cwd: String,
    },
    BrowseDirectories {
        path: Option<String>,
        cursor: Option<String>,
        #[serde(default)]
        show_hidden: bool,
    },
    CreateDirectory {
        parent: String,
        name: String,
    },
    DirectoryCreated {
        path: String,
    },
    DirectoryList {
        path: String,
        parent: Option<String>,
        home: String,
        directories: Vec<DirectoryEntry>,
        next_cursor: Option<String>,
    },
    LaunchSession {
        generation_id: String,
        cwd: String,
        session_id: Option<String>,
        name: Option<String>,
    },
    SessionLaunched {
        launch_id: String,
        instance_id: Option<String>,
    },
    Replay {
        session_id: String,
        instance_id: String,
        #[ts(type = "number")]
        after_seq: u64,
    },
    ReplayEnd {
        session_id: String,
        instance_id: String,
        #[ts(type = "number")]
        last_seq: u64,
    },
    History {
        session_id: String,
        instance_id: String,
        direction: HistoryDirection,
        #[ts(type = "number | null")]
        cursor: Option<u64>,
        limit: u32,
    },
    HistoryPage {
        session_id: String,
        instance_id: String,
        items: Vec<TranscriptItem>,
        has_before: bool,
        has_after: bool,
        #[ts(type = "number")]
        last_seq: u64,
        #[ts(type = "number")]
        source_seq: u64,
        /// The retained range may start after records that were discarded.
        history_truncated: bool,
    },
    Event {
        session_id: String,
        instance_id: String,
        #[ts(type = "number")]
        source_seq: u64,
        #[ts(type = "number")]
        seq: u64,
        event: EventData,
    },
    Gap {
        session_id: String,
        instance_id: String,
        reason: String,
    },
    Stop {
        generation_id: String,
        session_id: String,
        instance_id: String,
    },
    CloseSession {
        generation_id: String,
        session_id: String,
        instance_id: String,
        #[ts(type = "number")]
        expected_revision: u64,
    },
    Prompt {
        generation_id: String,
        session_id: String,
        instance_id: String,
        #[ts(type = "number")]
        expected_revision: u64,
        text: String,
    },
    Builtin {
        generation_id: String,
        session_id: String,
        instance_id: String,
        #[ts(type = "number")]
        expected_revision: u64,
        command: BuiltinCommand,
        args: String,
    },
    CommandResult {
        session_id: String,
        instance_id: String,
        status: CommandStatus,
        code: Option<String>,
        detail: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        data: Option<CommandData>,
    },
    GetResult {
        command_id: String,
    },
    Error {
        code: String,
        detail: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema, TS)]
#[serde(deny_unknown_fields)]
pub struct Envelope {
    pub version: u32,
    pub request_id: String,
    pub message: Message,
}

impl Envelope {
    pub fn new(request_id: impl Into<String>, message: Message) -> Self {
        Self {
            version: PROTOCOL_VERSION,
            request_id: request_id.into(),
            message,
        }
    }
    pub fn decode(json: &str) -> Result<Self, String> {
        if json.len() > 1024 * 1024 {
            return Err("Frame exceeds 1 MiB".into());
        }
        let envelope: Self = serde_json::from_str(json).map_err(|e| e.to_string())?;
        if envelope.version != PROTOCOL_VERSION {
            return Err(format!(
                "Unsupported protocol version: {}",
                envelope.version
            ));
        }
        if envelope.request_id.is_empty() || envelope.request_id.len() > 128 {
            return Err("Invalid request ID".into());
        }
        // JSON/TypeScript transport uses exact integer numbers, rather than BigInt.
        const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;
        let safe = match &envelope.message {
            Message::Register { session } | Message::Snapshot { session } => {
                session.revision <= MAX_SAFE_INTEGER
            }
            Message::Heartbeat {
                session,
                source_seq,
            } => session.revision <= MAX_SAFE_INTEGER && *source_seq <= MAX_SAFE_INTEGER,
            Message::Sessions { sessions } => {
                sessions.iter().all(|s| s.revision <= MAX_SAFE_INTEGER)
            }
            Message::Event {
                source_seq, seq, ..
            } => *source_seq <= MAX_SAFE_INTEGER && *seq <= MAX_SAFE_INTEGER,
            Message::Replay { after_seq, .. } => *after_seq <= MAX_SAFE_INTEGER,
            Message::ReplayEnd { last_seq, .. } => *last_seq <= MAX_SAFE_INTEGER,
            Message::History { cursor, .. } => cursor.is_none_or(|c| c <= MAX_SAFE_INTEGER),
            Message::HistoryPage {
                last_seq,
                source_seq,
                items,
                ..
            } => {
                *last_seq <= MAX_SAFE_INTEGER
                    && *source_seq <= MAX_SAFE_INTEGER
                    && items
                        .iter()
                        .all(|i| i.first_seq <= MAX_SAFE_INTEGER && i.last_seq <= MAX_SAFE_INTEGER)
            }
            Message::Prompt {
                expected_revision, ..
            }
            | Message::Builtin {
                expected_revision, ..
            }
            | Message::CloseSession {
                expected_revision, ..
            } => *expected_revision <= MAX_SAFE_INTEGER,
            Message::CommandResult {
                data: Some(data), ..
            } => match data {
                CommandData::Session { info } => {
                    [
                        info.input_tokens,
                        info.output_tokens,
                        info.cache_read_tokens,
                        info.cache_write_tokens,
                    ]
                    .iter()
                    .all(|n| *n <= MAX_SAFE_INTEGER)
                        && info.context_tokens.is_none_or(|n| n <= MAX_SAFE_INTEGER)
                }
                CommandData::Compact { tokens_before, .. } => *tokens_before <= MAX_SAFE_INTEGER,
                _ => true,
            },
            _ => true,
        };
        if !safe {
            return Err("Integer exceeds JSON safe range".into());
        }
        Ok(envelope)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn prompt_roundtrip_preserves_identity_and_unicode() {
        let envelope = Envelope::new(
            "req-1",
            Message::Prompt {
                generation_id: "generation-1".into(),
                session_id: "session-1".into(),
                instance_id: "instance-2".into(),
                expected_revision: 4,
                text: "Continue 🦀".into(),
            },
        );
        let json = serde_json::to_string(&envelope).unwrap();
        assert_eq!(Envelope::decode(&json).unwrap(), envelope);
    }
    #[test]
    fn shared_fixtures_decode() {
        for file in ["list.json", "prompt.json", "register.json"] {
            let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("fixtures")
                .join(file);
            let json = std::fs::read_to_string(path).unwrap();
            assert!(Envelope::decode(&json).is_ok());
        }
    }
    #[test]
    fn rejects_unsafe_json_integer() {
        let e = Envelope::new(
            "r",
            Message::Prompt {
                generation_id: "g".into(),
                session_id: "s".into(),
                instance_id: "i".into(),
                expected_revision: u64::MAX,
                text: "hello".into(),
            },
        );
        assert!(Envelope::decode(&serde_json::to_string(&e).unwrap()).is_err());
    }
    #[test]
    fn rejects_bad_frames() {
        assert!(
            Envelope::decode(r#"{"version":2,"request_id":"r","message":{"type":"list"}}"#)
                .is_err()
        );
        assert!(Envelope::decode(
            r#"{"version":1,"request_id":"r","message":{"type":"list","extra":1}}"#
        )
        .is_err());
    }
}
