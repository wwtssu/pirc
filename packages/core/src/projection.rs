use pirc_protocol::*;
use serde::Serialize;
use std::collections::{BTreeMap, HashMap};
use uuid::Uuid;

#[derive(Clone, Serialize, Default)]
pub struct View {
    pub server_key: Option<String>,
    pub pairing: Option<Pairing>,
    pub connection: String,
    pub error: Option<String>,
    pub generation: Option<String>,
    pub server_id: Option<String>,
    pub current_address: Option<String>,
    pub attempt_index: usize,
    pub sessions: Vec<SessionView>,
    pub commands: Vec<CommandView>,
}
#[derive(Clone, Serialize)]
pub struct Pairing {
    pub server_id: String,
    pub public_key: String,
    pub code: String,
    pub expires_in: u32,
}
#[derive(Clone, Serialize)]
pub struct SessionView {
    pub snapshot: SessionSnapshot,
    pub ready: bool,
    pub last_seq: u64,
    pub items: Vec<Item>,
    pub gaps: Vec<String>,
    pub history: HistoryView,
    #[serde(skip)]
    source_seq: u64,
    #[serde(skip)]
    buffer: BTreeMap<u64, (u64, EventData)>,
    #[serde(skip)]
    buffer_bytes: usize,
}
#[derive(Clone, Serialize, Default)]
pub struct HistoryView {
    pub enabled: bool,
    pub initialized: bool,
    pub loading: Option<String>,
    pub error: Option<String>,
    pub has_before: bool,
    pub has_after: bool,
    pub truncated: bool,
    pub revision: u64,
    pub anchor: Option<u64>,
}
struct HistoryRequest {
    instance: String,
    direction: HistoryDirection,
    bootstrap: bool,
    started: std::time::Instant,
    cursor: Option<u64>,
}
pub type Item = TranscriptItem;
#[derive(Clone, Serialize)]
pub struct CommandView {
    pub request_id: String,
    pub instance_id: String,
    pub kind: String,
    pub text: String,
    pub status: String,
    pub code: Option<String>,
    pub detail: Option<String>,
    pub data: Option<CommandData>,
    pub after_seq: u64,
    #[serde(skip)]
    pub generation: String,
}
pub struct Projection {
    pub view: View,
    pub selected: Option<String>,
    replays: HashMap<String, String>,
    queries: HashMap<String, String>,
    history_requests: HashMap<String, HistoryRequest>,
    history_paging: bool,
}
impl Default for Projection {
    fn default() -> Self {
        Self {
            view: View {
                connection: "connecting".into(),
                ..View::default()
            },
            replays: HashMap::new(),
            queries: HashMap::new(),
            selected: None,
            history_requests: HashMap::new(),
            history_paging: false,
        }
    }
}
pub fn packet(message: Message) -> Envelope {
    Envelope::new(Uuid::new_v4().to_string(), message)
}
impl Projection {
    pub fn select(&mut self, instance: String) -> Vec<Envelope> {
        self.selected = Some(instance.clone());
        if self.history_paging && self.view.connection == "connected" {
            self.history(&instance, HistoryDirection::Latest, None)
                .into_iter()
                .collect()
        } else {
            vec![]
        }
    }
    pub fn history(
        &mut self,
        instance: &str,
        direction: HistoryDirection,
        cursor: Option<u64>,
    ) -> Result<Envelope, String> {
        if !self.history_paging {
            return Err("Update the device server to load history".into());
        }
        if self.view.connection != "connected" {
            return Err("Wait for the connection to recover, then retry.".into());
        }
        let s = self
            .view
            .sessions
            .iter_mut()
            .find(|s| s.snapshot.instance_id == instance)
            .ok_or("Session not found")?;
        if s.history.loading.is_some() && direction != HistoryDirection::Latest {
            return Err("Messages are loading".into());
        }
        if matches!(
            direction,
            HistoryDirection::Latest | HistoryDirection::Around
        ) {
            self.history_requests.retain(|_, r| r.instance != instance);
        }
        let e = packet(Message::History {
            session_id: s.snapshot.session_id.clone(),
            instance_id: instance.into(),
            direction: direction.clone(),
            cursor,
            limit: 40,
        });
        let bootstrap = !s.ready || direction == HistoryDirection::Latest;
        if bootstrap {
            s.ready = false;
        }
        s.history.loading = Some(
            match direction {
                HistoryDirection::Latest => "latest",
                HistoryDirection::Before => "before",
                HistoryDirection::After => "after",
                HistoryDirection::Around => "around",
            }
            .into(),
        );
        s.history.error = None;
        self.history_requests.insert(
            e.request_id.clone(),
            HistoryRequest {
                instance: instance.into(),
                direction,
                bootstrap,
                started: std::time::Instant::now(),
                cursor,
            },
        );
        Ok(e)
    }
    pub fn expire_history(&mut self) -> bool {
        let expired: Vec<_> = self
            .history_requests
            .iter()
            .filter(|(_, r)| r.started.elapsed() > std::time::Duration::from_secs(10))
            .map(|(id, _)| id.clone())
            .collect();
        for id in &expired {
            if let Some(r) = self.history_requests.remove(id) {
                if let Some(s) = self
                    .view
                    .sessions
                    .iter_mut()
                    .find(|s| s.snapshot.instance_id == r.instance)
                {
                    s.history.loading = None;
                    s.history.error = Some("Loading timed out. Try again.".into());
                }
            }
        }
        !expired.is_empty()
    }
    pub fn disconnected(&mut self, error: Option<String>) {
        self.view.connection = "reconnecting".into();
        self.view.error = error;
        self.replays.clear();
        self.queries.clear();
        self.history_requests.clear();
        for session in &mut self.view.sessions {
            session.ready = false;
            if session.history.loading.take().is_some() {
                session.history.error = Some("Retry after the connection recovers".into());
            }
            session.buffer.clear();
            session.buffer_bytes = 0;
        }
        for command in &mut self.view.commands {
            if command.status == "pending"
                || (command.kind != "prompt" && command.status == "accepted")
            {
                command.status = "unknown".into();
            }
        }
    }
    fn snapshot(&mut self, snapshot: SessionSnapshot, outgoing: &mut Vec<Envelope>) {
        let instance = snapshot.instance_id.clone();
        if let Some(s) = self
            .view
            .sessions
            .iter_mut()
            .find(|s| s.snapshot.instance_id == snapshot.instance_id)
        {
            if snapshot.revision >= s.snapshot.revision {
                s.snapshot = snapshot;
            }
        } else {
            self.view.sessions.push(SessionView {
                snapshot,
                ready: false,
                last_seq: 0,
                source_seq: 0,
                items: vec![],
                gaps: vec![],
                history: HistoryView {
                    enabled: self.history_paging,
                    ..HistoryView::default()
                },
                buffer: BTreeMap::new(),
                buffer_bytes: 0,
            });
        }
        if self.history_paging {
            if self.selected.as_ref() == Some(&instance) {
                if let Some(s) = self
                    .view
                    .sessions
                    .iter()
                    .find(|s| s.snapshot.instance_id == instance)
                {
                    if !s.ready && s.history.loading.is_none() {
                        if s.history.initialized {
                            if !self.replays.values().any(|id| id == &instance) {
                                let e = packet(Message::Replay {
                                    session_id: s.snapshot.session_id.clone(),
                                    instance_id: instance.clone(),
                                    after_seq: s.last_seq,
                                });
                                self.replays.insert(e.request_id.clone(), instance.clone());
                                outgoing.push(e);
                            }
                        } else if let Ok(e) =
                            self.history(&instance, HistoryDirection::Latest, None)
                        {
                            outgoing.push(e);
                        }
                    }
                }
            }
            return;
        }
        for s in &self.view.sessions {
            if s.snapshot.instance_id == instance
                && !s.ready
                && !self
                    .replays
                    .values()
                    .any(|id| *id == s.snapshot.instance_id)
            {
                let e = packet(Message::Replay {
                    session_id: s.snapshot.session_id.clone(),
                    instance_id: s.snapshot.instance_id.clone(),
                    after_seq: s.last_seq,
                });
                self.replays
                    .insert(e.request_id.clone(), s.snapshot.instance_id.clone());
                outgoing.push(e);
            }
        }
    }
    pub fn receive(&mut self, envelope: Envelope) -> Vec<Envelope> {
        let mut outgoing = vec![];
        let request_id = envelope.request_id;
        match envelope.message {
            Message::Welcome {
                server_id: _,
                generation_id,
                history_paging,
            } => {
                self.history_paging = history_paging;
                for s in &mut self.view.sessions {
                    s.history.enabled = history_paging;
                }
                if self
                    .view
                    .generation
                    .as_ref()
                    .is_some_and(|g| *g != generation_id)
                {
                    self.replays.clear();
                    self.queries.clear();
                    self.history_requests.clear();
                    for s in &mut self.view.sessions {
                        let snapshot = s.snapshot.clone();
                        *s = SessionView::new(snapshot);
                        s.ready = false;
                        s.history.enabled = history_paging;
                    }
                    for c in &mut self.view.commands {
                        if c.status == "pending"
                            || c.status == "unknown"
                            || (c.kind != "prompt" && c.status == "accepted")
                        {
                            c.status = "unknown".into();
                            c.code = Some("SERVICE_RESTARTED".into());
                        }
                    }
                }
                self.view.generation = Some(generation_id);
                self.view.connection = "syncing".into();
                self.view.error = None;
            }
            Message::Sessions { sessions } => {
                let ids: Vec<_> = sessions.iter().map(|s| s.instance_id.clone()).collect();
                for s in &mut self.view.sessions {
                    if !ids.contains(&s.snapshot.instance_id) {
                        s.snapshot.state = SessionState::Offline;
                        s.ready = false;
                    }
                }
                self.view.connection = "connected".into();
                for s in sessions {
                    self.snapshot(s, &mut outgoing);
                }
                self.view.connection = "connected".into();
                for c in &self.view.commands {
                    if c.status == "unknown" && Some(&c.generation) == self.view.generation.as_ref()
                    {
                        let query = packet(Message::GetResult {
                            command_id: c.request_id.clone(),
                        });
                        self.queries
                            .insert(query.request_id.clone(), c.request_id.clone());
                        outgoing.push(query);
                    }
                }
            }
            Message::Snapshot { session } => self.snapshot(session, &mut outgoing),
            Message::HistoryPage {
                session_id,
                instance_id,
                items,
                has_before,
                has_after,
                last_seq,
                source_seq,
                history_truncated,
            } => {
                if let Some(request) = self
                    .history_requests
                    .remove(&request_id)
                    .filter(|r| r.instance == instance_id)
                {
                    if let Some(s) = self.view.sessions.iter_mut().find(|s| {
                        s.snapshot.instance_id == instance_id && s.snapshot.session_id == session_id
                    }) {
                        let replace = matches!(
                            request.direction,
                            HistoryDirection::Latest | HistoryDirection::Around
                        );
                        if replace {
                            s.items = items;
                            s.history.revision += 1;
                            s.history.anchor = if request.direction == HistoryDirection::Around {
                                request.cursor
                            } else {
                                None
                            };
                            s.history.has_before = has_before;
                            s.history.has_after = has_after;
                        } else {
                            for item in items {
                                if let Some(old) = s.items.iter_mut().find(|i| i.id == item.id) {
                                    if item.last_seq >= old.last_seq {
                                        *old = item;
                                    }
                                } else {
                                    s.items.push(item);
                                }
                            }
                            s.items.sort_by_key(|i| i.first_seq);
                            if request.direction == HistoryDirection::Before {
                                s.history.has_before = has_before;
                            } else {
                                s.history.has_after = has_after;
                            }
                        }
                        s.history.loading = None;
                        s.history.error = None;
                        s.history.initialized = true;
                        s.history.truncated = history_truncated;
                        if request.bootstrap {
                            s.last_seq = last_seq;
                            s.source_seq = source_seq;
                            s.ready = true;
                            let buffered = std::mem::take(&mut s.buffer);
                            s.buffer_bytes = 0;
                            for (seq, (source, event)) in buffered {
                                if seq > s.last_seq {
                                    if seq == s.last_seq + 1 {
                                        s.event(seq, source, event);
                                    } else {
                                        s.ready = false;
                                        s.buffer.insert(seq, (source, event));
                                    }
                                }
                            }
                            if !s.ready {
                                let e = packet(Message::Replay {
                                    session_id,
                                    instance_id: instance_id.clone(),
                                    after_seq: s.last_seq,
                                });
                                self.replays.insert(e.request_id.clone(), instance_id);
                                outgoing.push(e);
                            }
                        }
                    }
                }
            }
            Message::Event {
                session_id,
                instance_id,
                source_seq,
                seq,
                event,
            } => {
                if let Some(s) = self.view.sessions.iter_mut().find(|s| {
                    s.snapshot.instance_id == instance_id && s.snapshot.session_id == session_id
                }) {
                    if s.history.enabled
                        && !s.history.initialized
                        && s.history.loading.is_none()
                        && self.selected.as_ref() != Some(&instance_id)
                    {
                        s.last_seq = seq;
                        s.source_seq = source_seq;
                        return outgoing;
                    }
                    if s.ready && seq > s.last_seq + 1 {
                        s.ready = false;
                        let replay = packet(Message::Replay {
                            session_id: session_id.clone(),
                            instance_id: instance_id.clone(),
                            after_seq: s.last_seq,
                        });
                        self.replays
                            .insert(replay.request_id.clone(), instance_id.clone());
                        outgoing.push(replay);
                    }
                    if s.ready {
                        s.event(seq, source_seq, event);
                    } else if !s.buffer.contains_key(&seq) && seq > s.last_seq {
                        let bytes = event.text.as_ref().map_or(0, String::len) + 512;
                        if s.buffer.len() < 10000 && s.buffer_bytes + bytes <= 32 * 1024 * 1024 {
                            s.buffer_bytes += bytes;
                            s.buffer.insert(seq, (source_seq, event));
                        } else {
                            s.gap("Sync buffer is full. Some events are missing.");
                        }
                    }
                }
            }
            Message::ReplayEnd {
                session_id,
                instance_id,
                last_seq,
            } => {
                if self.replays.remove(&request_id).as_ref() == Some(&instance_id) {
                    if let Some(s) = self.view.sessions.iter_mut().find(|s| {
                        s.snapshot.instance_id == instance_id && s.snapshot.session_id == session_id
                    }) {
                        let mut buffered = std::mem::take(&mut s.buffer);
                        let live = buffered.split_off(&last_seq.saturating_add(1));
                        for (seq, (source, event)) in buffered {
                            s.event(seq, source, event);
                        }
                        s.last_seq = s.last_seq.max(last_seq);
                        s.buffer_bytes = 0;
                        s.ready = true;
                        for (seq, (source, event)) in live {
                            if s.ready && seq <= s.last_seq + 1 {
                                s.event(seq, source, event);
                            } else {
                                s.ready = false;
                                s.buffer_bytes += event.text.as_ref().map_or(0, String::len) + 512;
                                s.buffer.insert(seq, (source, event));
                            }
                        }
                        if !s.ready {
                            let replay = packet(Message::Replay {
                                session_id: session_id.clone(),
                                instance_id: instance_id.clone(),
                                after_seq: s.last_seq,
                            });
                            self.replays
                                .insert(replay.request_id.clone(), instance_id.clone());
                            outgoing.push(replay);
                        }
                    }
                }
            }
            Message::Gap {
                instance_id,
                reason,
                ..
            } => {
                if let Some(s) = self
                    .view
                    .sessions
                    .iter_mut()
                    .find(|s| s.snapshot.instance_id == instance_id)
                {
                    s.gap(&reason);
                }
            }
            Message::CommandResult {
                instance_id,
                status,
                code,
                detail,
                data,
                ..
            } => {
                let id = self.queries.remove(&request_id).unwrap_or(request_id);
                if let Some(c) = self
                    .view
                    .commands
                    .iter_mut()
                    .find(|c| c.request_id == id && c.instance_id == instance_id)
                {
                    c.status = match status {
                        CommandStatus::Accepted => "accepted",
                        CommandStatus::Completed => "completed",
                        CommandStatus::Rejected => "rejected",
                    }
                    .into();
                    c.code = code;
                    c.detail = detail;
                    c.data = data;
                }
            }
            Message::Error { code, detail } => {
                if let Some(request) = self.history_requests.remove(&request_id) {
                    if let Some(s) = self
                        .view
                        .sessions
                        .iter_mut()
                        .find(|s| s.snapshot.instance_id == request.instance)
                    {
                        s.history.loading = None;
                        s.history.error = Some(
                            if code == "HISTORY_NOT_FOUND" {
                                "This message is no longer retained"
                            } else {
                                "Unable to load messages. Try again."
                            }
                            .into(),
                        );
                    }
                    return outgoing;
                }
                let id = self
                    .queries
                    .remove(&request_id)
                    .unwrap_or(request_id.clone());
                if let Some(c) = self.view.commands.iter_mut().find(|c| c.request_id == id) {
                    c.status = if code == "PENDING" || code == "RESULT_UNKNOWN" {
                        "unknown"
                    } else {
                        "rejected"
                    }
                    .into();
                    c.code = Some(code.clone());
                } else if let Some(instance) = self.replays.remove(&request_id) {
                    if let Some(s) = self
                        .view
                        .sessions
                        .iter_mut()
                        .find(|s| s.snapshot.instance_id == instance)
                    {
                        s.gap("Unable to sync this session. Reconnect.");
                    }
                }
                if code == "EVENT_GAP" {
                    for s in &mut self.view.sessions {
                        s.ready = false;
                        s.buffer.clear();
                        s.buffer_bytes = 0;
                    }
                    outgoing.push(packet(Message::List {}));
                } else if code != "PENDING" && code != "RESULT_UNKNOWN" {
                    self.view.error = Some(format!("{code}: {detail}"));
                }
            }
            _ => {}
        }
        outgoing
    }
    pub fn command(&mut self, instance: &str, text: Option<String>) -> Result<Envelope, String> {
        self.session_action(instance, text, false)
    }
    pub fn close_session(&mut self, instance: &str) -> Result<Envelope, String> {
        self.session_action(instance, None, true)
    }
    fn session_action(
        &mut self,
        instance: &str,
        text: Option<String>,
        closing: bool,
    ) -> Result<Envelope, String> {
        if self.view.connection != "connected" {
            return Err("Connection has not recovered. Controls are unavailable.".into());
        }
        let s = self
            .view
            .sessions
            .iter()
            .find(|s| s.snapshot.instance_id == instance)
            .ok_or("Session not found")?;
        if !s.ready || s.snapshot.needs_local_attention || s.snapshot.state == SessionState::Offline
        {
            return Err("Session state is unconfirmed or needs attention in the terminal".into());
        }
        if self.view.commands.iter().any(|c| {
            c.instance_id == instance
                && (c.status == "pending"
                    || c.status == "unknown"
                    || (c.kind != "prompt" && c.status == "accepted"))
        }) {
            return Err("The previous operation is unconfirmed. Check the terminal first.".into());
        }
        let generation = self
            .view
            .generation
            .clone()
            .ok_or("Connection identity is unconfirmed")?;
        let message = if closing {
            if s.snapshot.can_close != Some(true)
                || s.snapshot.launch_id.as_ref().is_none_or(|id| id.is_empty())
            {
                return Err(
                    "This session was started on the device. Exit it on the device.".into(),
                );
            }
            if s.snapshot.state != SessionState::Idle {
                return Err("A task is running. Stop it before exiting.".into());
            }
            Message::CloseSession {
                generation_id: generation.clone(),
                session_id: s.snapshot.session_id.clone(),
                instance_id: instance.into(),
                expected_revision: s.snapshot.revision,
            }
        } else if let Some(text) = &text {
            if s.snapshot.state != SessionState::Idle {
                return Err("Wait for confirmed idle state before sending".into());
            }
            if text.trim().is_empty() || text.len() > 64 * 1024 {
                return Err("Enter a message of at most 64 KiB".into());
            }
            let slash = text.trim().strip_prefix('/').map(|value| {
                let mut parts = value.splitn(2, char::is_whitespace);
                (
                    parts.next().unwrap_or_default(),
                    parts.next().unwrap_or_default().trim(),
                )
            });
            if let Some((name, args)) =
                slash.filter(|(name, _)| BuiltinCommand::parse(name).is_some())
            {
                if !s.snapshot.slash_commands.as_ref().is_some_and(|commands| {
                    commands
                        .iter()
                        .any(|c| c.name == name && c.source == "builtin")
                }) {
                    return Err("Built-in command support is unavailable. Reload the adapter on the device.".into());
                }
                Message::Builtin {
                    generation_id: generation.clone(),
                    session_id: s.snapshot.session_id.clone(),
                    instance_id: instance.into(),
                    expected_revision: s.snapshot.revision,
                    command: BuiltinCommand::parse(name).unwrap(),
                    args: args.into(),
                }
            } else {
                Message::Prompt {
                    generation_id: generation.clone(),
                    session_id: s.snapshot.session_id.clone(),
                    instance_id: instance.into(),
                    expected_revision: s.snapshot.revision,
                    text: text.clone(),
                }
            }
        } else {
            Message::Stop {
                generation_id: generation.clone(),
                session_id: s.snapshot.session_id.clone(),
                instance_id: instance.into(),
            }
        };
        let kind = match &message {
            Message::Builtin { command, .. } => command.name(),
            Message::Prompt { .. } => "prompt",
            Message::CloseSession { .. } => "close",
            _ => "stop",
        }
        .to_string();
        let e = packet(message);
        if self.view.commands.len() == 100 {
            self.view.commands.remove(0);
        }
        self.view.commands.push(CommandView {
            request_id: e.request_id.clone(),
            instance_id: instance.into(),
            kind,
            text: text.unwrap_or_default(),
            status: "pending".into(),
            code: None,
            detail: None,
            data: None,
            after_seq: s.last_seq,
            generation,
        });
        Ok(e)
    }
}

impl SessionView {
    pub fn new(snapshot: SessionSnapshot) -> Self {
        Self {
            snapshot,
            ready: true,
            last_seq: 0,
            items: vec![],
            gaps: vec![],
            history: HistoryView {
                enabled: true,
                ..HistoryView::default()
            },
            source_seq: 0,
            buffer: BTreeMap::new(),
            buffer_bytes: 0,
        }
    }
    pub fn display(&self, include_items: bool) -> Self {
        Self {
            snapshot: self.snapshot.clone(),
            ready: self.ready,
            last_seq: self.last_seq,
            items: if include_items {
                self.items.clone()
            } else {
                vec![]
            },
            gaps: self.gaps.clone(),
            history: self.history.clone(),
            source_seq: 0,
            buffer: BTreeMap::new(),
            buffer_bytes: 0,
        }
    }
    fn gap(&mut self, reason: &str) {
        if !self.gaps.iter().any(|r| r == reason) {
            self.gaps.push(reason.into());
        }
        if self.gaps.len() > 8 {
            self.gaps.remove(0);
        }
    }
    pub fn event(&mut self, seq: u64, source: u64, event: EventData) {
        if seq <= self.last_seq {
            return;
        }
        if seq != self.last_seq + 1 || source != self.source_seq + 1 {
            self.gap("Some events are missing. History may be incomplete.");
        }
        self.last_seq = seq;
        self.source_seq = source;
        if self.history.enabled && self.history.has_after {
            return;
        }
        if event.kind == EventKind::AgentSettled {
            for item in &mut self.items {
                if !item.complete && item.last_seq < seq {
                    item.complete = true;
                    item.last_seq = seq;
                    if item.role == "tool" {
                        item.phase = Some("cancelled".into());
                    }
                }
            }
            self.items
                .retain(|i| !(i.role == "assistant" && i.text.is_empty() && i.images.is_empty()));
            return;
        }
        let message_id = event.message_id.as_deref().unwrap_or("unknown");
        if matches!(
            event.kind,
            EventKind::TextStart
                | EventKind::MessageDelta
                | EventKind::TextEnd
                | EventKind::ToolCallStart
                | EventKind::ToolCallDelta
                | EventKind::ToolCallEnd
        ) {
            // Providers may delay thinking_end until the whole message ends.
            // Moving to a later answer/tool block already ends that phase.
            for item in &mut self.items {
                if item.role == "thinking"
                    && item.last_seq < seq
                    && item.message_id.as_deref() == Some(message_id)
                    && event.content_index.is_none_or(|next| {
                        item.content_index.is_none_or(|previous| previous <= next)
                    })
                {
                    item.complete = true;
                    item.last_seq = seq;
                }
            }
        }
        if event.kind == EventKind::MessageEnd && event.text.is_none() {
            // The final assistant event closes its blocks; it must never merge
            // text across a tool call or move an existing transcript item.
            for item in &mut self.items {
                if item.message_id.as_deref() == Some(message_id) && item.last_seq < seq {
                    if item.role != "tool" {
                        item.complete = true;
                        item.last_seq = seq;
                        item.is_error |= event.is_error;
                    } else if item.phase.as_deref() == Some("generating")
                        || (event.is_error && item.phase.as_deref() == Some("waiting"))
                    {
                        item.phase = Some("cancelled".into());
                        item.complete = true;
                        item.last_seq = seq;
                    }
                }
            }
            self.items.retain(|i| {
                !(i.message_id.as_deref() == Some(message_id)
                    && i.role == "assistant"
                    && i.text.is_empty()
                    && i.images.is_empty())
            });
            return;
        }
        if event.content_index.is_some() {
            let placeholder = format!("assistant:{message_id}");
            self.items
                .retain(|i| i.id != placeholder || !i.text.is_empty());
        }
        let block_id = format!("{message_id}:{}", event.content_index.unwrap_or(0));
        let (role, id, complete) = match event.kind {
            EventKind::UserMessage => ("user", format!("user:{seq}"), true),
            EventKind::MessageStart | EventKind::MessageEnd => (
                "assistant",
                format!("assistant:{message_id}"),
                matches!(event.kind, EventKind::MessageEnd),
            ),
            EventKind::TextStart | EventKind::MessageDelta | EventKind::TextEnd => (
                "assistant",
                if event.content_index.is_some() {
                    format!("assistant:{block_id}")
                } else {
                    format!("assistant:{message_id}")
                },
                matches!(event.kind, EventKind::TextEnd),
            ),
            EventKind::ThinkingStart | EventKind::ThinkingDelta | EventKind::ThinkingEnd => (
                "thinking",
                format!("thinking:{block_id}"),
                matches!(event.kind, EventKind::ThinkingEnd),
            ),
            EventKind::ToolCallStart | EventKind::ToolCallDelta | EventKind::ToolCallEnd => {
                ("tool", format!("tool-call:{block_id}"), false)
            }
            EventKind::ToolStart | EventKind::ToolUpdate | EventKind::ToolEnd => (
                "tool",
                self.items
                    .iter()
                    .find(|i| {
                        i.role == "tool"
                            && event.tool_call_id.is_some()
                            && i.tool_call_id.as_ref() == event.tool_call_id.as_ref()
                    })
                    .map(|i| i.id.clone())
                    .unwrap_or_else(|| {
                        format!(
                            "tool:{}",
                            event.tool_call_id.as_deref().unwrap_or("unknown")
                        )
                    }),
                matches!(event.kind, EventKind::ToolEnd),
            ),
            EventKind::Error => ("error", format!("error:{seq}"), true),
            _ => return,
        };
        let index = self
            .items
            .iter()
            .position(|i| i.id == id)
            .unwrap_or_else(|| {
                self.items.push(Item {
                    images: vec![],
                    id: id.clone(),
                    first_seq: seq,
                    last_seq: 0,
                    role: role.into(),
                    text: String::new(),
                    title: None,
                    arguments: None,
                    phase: None,
                    complete: false,
                    is_error: false,
                    truncated: false,
                    message_id: event.message_id.clone(),
                    content_index: event.content_index,
                    tool_call_id: event.tool_call_id.clone(),
                });
                self.items.len() - 1
            });
        let item = &mut self.items[index];
        // A historical page can contain a newer version than live events still
        // queued on the socket. Advance the event cursor, but do not apply twice.
        if item.last_seq >= seq {
            return;
        }
        item.last_seq = seq;
        let text = event.text.unwrap_or_default();
        if event.tool_call_id.as_ref().is_some_and(|id| !id.is_empty()) {
            item.tool_call_id = event.tool_call_id;
        }
        if event
            .tool_name
            .as_ref()
            .is_some_and(|name| !name.is_empty())
        {
            item.title = event.tool_name;
        }
        match event.kind {
            EventKind::MessageDelta | EventKind::ThinkingDelta => item.text.push_str(&text),
            EventKind::ToolCallStart => {
                item.arguments.get_or_insert_with(String::new);
                item.phase.get_or_insert_with(|| "generating".into());
            }
            EventKind::ToolCallDelta => {
                item.arguments
                    .get_or_insert_with(String::new)
                    .push_str(&text);
                item.phase.get_or_insert_with(|| "generating".into());
            }
            EventKind::ToolCallEnd => {
                item.arguments = Some(text);
                if !item.complete && !matches!(item.phase.as_deref(), Some("running" | "cancelled"))
                {
                    item.phase = Some("waiting".into());
                }
            }
            EventKind::ToolStart => {
                if !text.is_empty() {
                    item.arguments = Some(text);
                }
                item.phase = Some("running".into());
            }
            EventKind::ToolUpdate => {
                item.text = text;
                item.phase = Some("running".into());
            }
            EventKind::ToolEnd => {
                item.text = text;
                item.phase = Some(
                    if event.is_error {
                        "failed"
                    } else {
                        "completed"
                    }
                    .into(),
                );
            }
            EventKind::MessageStart | EventKind::TextStart => {}
            _ => item.text = text,
        }
        item.complete |= complete;
        item.is_error |= event.is_error;
        item.truncated |= event.truncated;
        if !event.images.is_empty() {
            item.images = event.images;
        }
        for value in std::iter::once(&mut item.text).chain(item.arguments.iter_mut()) {
            if value.len() > 64 * 1024 {
                let mut end = 64 * 1024;
                while !value.is_char_boundary(end) {
                    end -= 1;
                }
                value.truncate(end);
                item.truncated = true;
            }
        }
        while !self.history.enabled
            && (self.items.len() > 600
                || self
                    .items
                    .iter()
                    .map(|i| i.text.len() + i.arguments.as_ref().map_or(0, String::len))
                    .sum::<usize>()
                    > 4 * 1024 * 1024)
        {
            self.items.remove(0);
            self.gap("Older local messages have been released");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn image_only_blocks_survive_completion() {
        let mut session = SessionView::new(snapshot("i"));
        let image = ImageRef {
            id: "a".repeat(64),
            mime_type: "image/png".into(),
            size: 68,
        };
        let event = EventData {
            images: vec![image.clone()],
            kind: EventKind::TextEnd,
            message_id: Some("m".into()),
            content_index: Some(0),
            text: Some("".into()),
            tool_call_id: None,
            tool_name: None,
            is_error: false,
            truncated: false,
        };
        session.event(1, 1, event.clone());
        session.event(
            2,
            2,
            EventData {
                images: vec![],
                kind: EventKind::MessageEnd,
                text: None,
                ..event.clone()
            },
        );
        session.event(
            3,
            3,
            EventData {
                images: vec![],
                kind: EventKind::AgentSettled,
                text: None,
                ..event
            },
        );
        assert_eq!(session.items.len(), 1);
        assert_eq!(session.items[0].images, vec![image]);
    }
    #[test]
    fn exit_is_explicit_managed_idle_and_cannot_be_repeated_or_resent() {
        let mut p = Projection::default();
        let replay = start(&mut p, "i");
        end(&mut p, &replay, "i", 0);
        assert!(p.close_session("i").is_err());
        p.view.sessions[0].snapshot.launch_id = Some("launch".into());
        assert!(p.close_session("i").is_err());
        p.view.sessions[0].snapshot.can_close = Some(true);
        p.view.sessions[0].snapshot.state = SessionState::Running;
        assert!(p.close_session("i").is_err());
        p.view.sessions[0].snapshot.state = SessionState::Idle;
        let close = p.close_session("i").unwrap();
        assert!(
            matches!(&close.message, Message::CloseSession { expected_revision: 1, instance_id, .. } if instance_id == "i")
        );
        assert!(p.close_session("i").is_err());
        assert!(p.command("i", Some("next".into())).is_err());
        assert!(p.view.sessions[0].items.is_empty());
        p.disconnected(None);
        assert_eq!(p.view.commands[0].status, "unknown");
        assert!(p.close_session("i").is_err());
    }
    #[test]
    fn builtins_are_typed_and_wait_for_completion_without_creating_prompt_items() {
        let mut p = Projection::default();
        let replay = start(&mut p, "i");
        end(&mut p, &replay, "i", 0);
        p.view.sessions[0].snapshot.slash_commands = Some(vec![SlashCommand {
            name: "compact".into(),
            description: None,
            source: "builtin".into(),
        }]);
        let request = p
            .command("i", Some("/compact Keep the task".into()))
            .unwrap();
        assert!(
            matches!(request.message, Message::Builtin { command: BuiltinCommand::Compact, ref args, .. } if args == "Keep the task")
        );
        assert_eq!(p.view.commands[0].kind, "compact");
        p.receive(Envelope::new(
            &request.request_id,
            Message::CommandResult {
                session_id: "s-i".into(),
                instance_id: "i".into(),
                status: CommandStatus::Accepted,
                code: None,
                detail: None,
                data: None,
            },
        ));
        assert!(p.command("i", Some("next".into())).is_err());
        assert!(p.view.sessions[0].items.is_empty());
        p.disconnected(None);
        p.receive(packet(Message::Welcome {
            server_id: None,
            generation_id: "g".into(),
            history_paging: false,
        }));
        let queries = p.receive(packet(Message::Sessions {
            sessions: vec![snapshot("i")],
        }));
        let query = queries
            .iter()
            .find(|e| matches!(e.message, Message::GetResult { .. }))
            .unwrap();
        let data = CommandData::Compact {
            summary: "done".into(),
            tokens_before: 100,
        };
        p.receive(Envelope::new(
            &query.request_id,
            Message::CommandResult {
                session_id: "s-i".into(),
                instance_id: "i".into(),
                status: CommandStatus::Completed,
                code: None,
                detail: None,
                data: Some(data.clone()),
            },
        ));
        assert_eq!(p.view.commands[0].data, Some(data));
        assert_eq!(p.view.commands[0].status, "completed");
    }
    #[test]
    fn builtin_request_requires_current_extension_capability() {
        let mut p = Projection::default();
        let replay = start(&mut p, "i");
        end(&mut p, &replay, "i", 0);
        assert!(p
            .command("i", Some("/model".into()))
            .unwrap_err()
            .contains("Built-in command support"));
        assert!(p.view.commands.is_empty());
    }
    fn snapshot(instance: &str) -> SessionSnapshot {
        SessionSnapshot {
            capabilities: vec![],
            ui_prompt: None,
            session_id: format!("s-{instance}"),
            instance_id: instance.into(),
            cwd: "/tmp".into(),
            name: None,
            state: SessionState::Idle,
            revision: 1,
            needs_local_attention: false,
            slash_commands: None,
            controls: None,
            launch_id: None,
            can_close: None,
        }
    }
    fn start(p: &mut Projection, instance: &str) -> String {
        p.receive(packet(Message::Welcome {
            server_id: None,
            generation_id: "g".into(),
            history_paging: false,
        }));
        p.receive(packet(Message::Sessions {
            sessions: vec![snapshot(instance)],
        }))[0]
            .request_id
            .clone()
    }
    fn end(p: &mut Projection, id: &str, instance: &str, last: u64) {
        p.receive(Envelope::new(
            id,
            Message::ReplayEnd {
                session_id: format!("s-{instance}"),
                instance_id: instance.into(),
                last_seq: last,
            },
        ));
    }
    fn event(p: &mut Projection, instance: &str, seq: u64, kind: EventKind, text: &str) {
        p.receive(packet(Message::Event {
            session_id: format!("s-{instance}"),
            instance_id: instance.into(),
            source_seq: seq,
            seq,
            event: EventData {
                images: vec![],
                kind,
                message_id: Some("m".into()),
                content_index: None,
                text: Some(text.into()),
                tool_call_id: None,
                tool_name: None,
                is_error: false,
                truncated: false,
            },
        }));
    }
    fn block(
        p: &mut Projection,
        seq: u64,
        kind: EventKind,
        index: Option<u32>,
        text: Option<&str>,
        call: Option<&str>,
    ) {
        p.receive(packet(Message::Event {
            session_id: "s-i".into(),
            instance_id: "i".into(),
            source_seq: seq,
            seq,
            event: EventData {
                images: vec![],
                kind,
                message_id: Some("m".into()),
                content_index: index,
                text: text.map(String::from),
                tool_call_id: call.map(String::from),
                tool_name: call.map(|_| "bash".into()),
                is_error: false,
                truncated: false,
            },
        }));
    }
    #[test]
    fn answer_or_tool_block_finishes_thinking_without_waiting_for_thinking_end() {
        for (kind, index) in [
            (EventKind::TextStart, Some(1)),
            (EventKind::MessageDelta, Some(1)),
            (EventKind::MessageDelta, None),
            (EventKind::ToolCallStart, Some(1)),
        ] {
            let mut p = Projection::default();
            let replay = start(&mut p, "i");
            end(&mut p, &replay, "i", 0);
            block(
                &mut p,
                1,
                EventKind::ThinkingDelta,
                Some(0),
                Some("Thinking"),
                None,
            );
            assert!(!p.view.sessions[0].items[0].complete);
            block(&mut p, 2, kind, index, Some("Answer"), None);
            let thinking = &p.view.sessions[0].items[0];
            assert!(thinking.complete);
            assert_eq!(thinking.text, "Thinking");
            // A delayed final thinking update repairs text, without reopening loading.
            block(
                &mut p,
                3,
                EventKind::ThinkingDelta,
                Some(0),
                Some(" continued"),
                None,
            );
            assert!(p.view.sessions[0].items[0].complete);
            block(
                &mut p,
                4,
                EventKind::ThinkingEnd,
                Some(0),
                Some("Complete thinking"),
                None,
            );
            assert_eq!(p.view.sessions[0].items[0].text, "Complete thinking");
            assert!(p.view.sessions[0].items[0].complete);
        }
    }
    #[test]
    fn earlier_text_finalization_does_not_finish_later_thinking() {
        let mut p = Projection::default();
        let replay = start(&mut p, "i");
        end(&mut p, &replay, "i", 0);
        block(
            &mut p,
            1,
            EventKind::MessageDelta,
            Some(0),
            Some("Answer"),
            None,
        );
        block(
            &mut p,
            2,
            EventKind::ThinkingDelta,
            Some(1),
            Some("Thinking again"),
            None,
        );
        block(&mut p, 3, EventKind::TextEnd, Some(0), Some("Answer"), None);
        assert!(!p.view.sessions[0].items[1].complete);
    }
    #[test]
    fn thinking_arguments_and_output_stream_without_merging_across_tools() {
        let mut p = Projection::default();
        let replay = start(&mut p, "i");
        end(&mut p, &replay, "i", 0);
        event(&mut p, "i", 1, EventKind::UserMessage, "run");
        block(&mut p, 2, EventKind::MessageStart, None, None, None);
        assert!(!p.view.sessions[0].items[1].complete);
        block(&mut p, 3, EventKind::ThinkingStart, Some(0), None, None);
        block(
            &mut p,
            4,
            EventKind::ThinkingDelta,
            Some(0),
            Some("Check first"),
            None,
        );
        assert_eq!(p.view.sessions[0].items[1].text, "Check first");
        assert!(!p.view.sessions[0].items[1].complete);
        block(
            &mut p,
            5,
            EventKind::ThinkingEnd,
            Some(0),
            Some("Check the tool first"),
            None,
        );
        block(
            &mut p,
            6,
            EventKind::MessageDelta,
            Some(1),
            Some("before"),
            None,
        );
        // Some providers only supply a tool ID after toolcall_start.
        block(&mut p, 7, EventKind::ToolCallStart, Some(2), None, None);
        block(
            &mut p,
            8,
            EventKind::ToolCallDelta,
            Some(2),
            Some("{\"command\":"),
            Some("c"),
        );
        assert_eq!(
            p.view.sessions[0].items[3].arguments.as_deref(),
            Some("{\"command\":")
        );
        block(
            &mut p,
            9,
            EventKind::ToolCallDelta,
            Some(2),
            Some("\"echo hi\"}"),
            Some("c"),
        );
        block(
            &mut p,
            10,
            EventKind::ToolCallEnd,
            Some(2),
            Some("{\"command\":\"echo hi\"}"),
            Some("c"),
        );
        block(
            &mut p,
            11,
            EventKind::MessageDelta,
            Some(3),
            Some("after"),
            None,
        );
        block(&mut p, 12, EventKind::MessageEnd, None, None, None);
        let ids: Vec<_> = p.view.sessions[0]
            .items
            .iter()
            .map(|i| i.id.clone())
            .collect();
        block(&mut p, 13, EventKind::ToolStart, None, None, Some("c"));
        block(
            &mut p,
            14,
            EventKind::ToolUpdate,
            None,
            Some("one"),
            Some("c"),
        );
        assert_eq!(p.view.sessions[0].items[3].text, "one");
        assert!(!p.view.sessions[0].items[3].complete);
        block(
            &mut p,
            15,
            EventKind::ToolUpdate,
            None,
            Some("one\ntwo"),
            Some("c"),
        );
        assert_eq!(p.view.sessions[0].items[3].text, "one\ntwo");
        block(
            &mut p,
            16,
            EventKind::ToolEnd,
            None,
            Some("final"),
            Some("c"),
        );
        let items = &p.view.sessions[0].items;
        assert_eq!(items.iter().map(|i| i.id.clone()).collect::<Vec<_>>(), ids);
        assert_eq!(
            items.iter().map(|i| i.role.as_str()).collect::<Vec<_>>(),
            ["user", "thinking", "assistant", "tool", "assistant"]
        );
        assert_eq!(items[2].text, "before");
        assert_eq!(items[4].text, "after");
        assert_eq!(
            items[3].arguments.as_deref(),
            Some("{\"command\":\"echo hi\"}")
        );
        assert!(items.iter().all(|i| i.complete));
    }
    #[test]
    fn parallel_tool_results_keep_call_order_across_replay() {
        let mut p = Projection::default();
        let replay = start(&mut p, "i");
        // Live completion can arrive before the replayed call starts.
        block(
            &mut p,
            6,
            EventKind::ToolEnd,
            None,
            Some("second finished"),
            Some("second"),
        );
        block(
            &mut p,
            1,
            EventKind::ToolCallEnd,
            Some(0),
            Some("{}"),
            Some("first"),
        );
        block(
            &mut p,
            2,
            EventKind::ToolCallEnd,
            Some(1),
            Some("{}"),
            Some("second"),
        );
        block(&mut p, 3, EventKind::MessageEnd, None, None, None);
        block(&mut p, 4, EventKind::ToolStart, None, None, Some("first"));
        block(&mut p, 5, EventKind::ToolStart, None, None, Some("second"));
        block(
            &mut p,
            6,
            EventKind::ToolEnd,
            None,
            Some("second finished"),
            Some("second"),
        );
        block(
            &mut p,
            7,
            EventKind::ToolEnd,
            None,
            Some("first finished"),
            Some("first"),
        );
        end(&mut p, &replay, "i", 7);
        let items = &p.view.sessions[0].items;
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].tool_call_id.as_deref(), Some("first"));
        assert_eq!(items[1].tool_call_id.as_deref(), Some("second"));
        assert_eq!(items[0].text, "first finished");
        assert_eq!(items[1].text, "second finished");
        assert!(items.iter().all(|i| i.complete));
        assert!(p.view.sessions[0].gaps.is_empty());
    }
    #[test]
    fn settled_agent_closes_interrupted_blocks_and_removes_empty_loading() {
        let mut p = Projection::default();
        let replay = start(&mut p, "i");
        end(&mut p, &replay, "i", 0);
        block(&mut p, 1, EventKind::MessageStart, None, None, None);
        block(
            &mut p,
            2,
            EventKind::ThinkingDelta,
            Some(0),
            Some("partial"),
            None,
        );
        block(
            &mut p,
            3,
            EventKind::ToolCallDelta,
            Some(1),
            Some("{"),
            Some("c"),
        );
        block(&mut p, 4, EventKind::AgentSettled, None, None, None);
        let items = &p.view.sessions[0].items;
        assert_eq!(items.len(), 2);
        assert!(items.iter().all(|i| i.complete));
        assert_eq!(items[1].phase.as_deref(), Some("cancelled"));
    }
    #[test]
    fn live_sequence_hole_requests_incremental_replay_without_skipping_or_duplicates() {
        let mut p = Projection::default();
        let replay = start(&mut p, "i");
        end(&mut p, &replay, "i", 0);
        event(&mut p, "i", 1, EventKind::UserMessage, "hello");
        let late = packet(Message::Event {
            session_id: "s-i".into(),
            instance_id: "i".into(),
            source_seq: 3,
            seq: 3,
            event: EventData {
                images: vec![],
                kind: EventKind::MessageDelta,
                message_id: Some("m".into()),
                content_index: None,
                text: Some("B".into()),
                tool_call_id: None,
                tool_name: None,
                is_error: false,
                truncated: false,
            },
        });
        let outgoing = p.receive(late.clone());
        assert_eq!(outgoing.len(), 1);
        assert!(matches!(
            outgoing[0].message,
            Message::Replay { after_seq: 1, .. }
        ));
        assert_eq!(p.view.sessions[0].last_seq, 1);
        assert!(!p.view.sessions[0].ready);
        assert!(p.receive(late).is_empty());
        event(&mut p, "i", 2, EventKind::MessageDelta, "A");
        event(&mut p, "i", 3, EventKind::MessageDelta, "B");
        end(&mut p, &outgoing[0].request_id, "i", 3);
        let session = &p.view.sessions[0];
        assert!(session.ready);
        assert!(session.gaps.is_empty());
        assert_eq!(session.last_seq, 3);
        assert_eq!(session.items[1].text, "AB");
    }

    #[test]
    fn live_hole_beyond_replay_watermark_is_fetched_in_the_next_increment() {
        let mut p = Projection::default();
        let replay = start(&mut p, "i");
        event(&mut p, "i", 1, EventKind::UserMessage, "hello");
        event(&mut p, "i", 3, EventKind::MessageDelta, "B");
        let outgoing = p.receive(Envelope::new(
            &replay,
            Message::ReplayEnd {
                session_id: "s-i".into(),
                instance_id: "i".into(),
                last_seq: 1,
            },
        ));
        assert_eq!(outgoing.len(), 1);
        assert!(matches!(
            outgoing[0].message,
            Message::Replay { after_seq: 1, .. }
        ));
        assert_eq!(p.view.sessions[0].last_seq, 1);
        assert!(p.view.sessions[0].gaps.is_empty());
        event(&mut p, "i", 2, EventKind::MessageDelta, "A");
        end(&mut p, &outgoing[0].request_id, "i", 3);
        assert!(p.view.sessions[0].ready);
        assert_eq!(p.view.sessions[0].items[1].text, "AB");
        assert!(p.view.sessions[0].gaps.is_empty());
    }

    #[test]
    fn live_replay_interleave_is_ordered_and_deduplicated() {
        let mut p = Projection::default();
        let replay = start(&mut p, "i");
        assert!(p.command("i", Some("hello".into())).is_err());
        event(&mut p, "i", 3, EventKind::MessageDelta, "B");
        event(&mut p, "i", 1, EventKind::UserMessage, "hello");
        event(&mut p, "i", 2, EventKind::MessageDelta, "A");
        event(&mut p, "i", 3, EventKind::MessageDelta, "B");
        end(&mut p, &replay, "i", 3);
        assert!(p.view.sessions[0].ready);
        assert!(p.view.sessions[0].gaps.is_empty());
        assert_eq!(p.view.sessions[0].items.len(), 2);
        assert_eq!(p.view.sessions[0].items[1].text, "AB");
        event(&mut p, "i", 3, EventKind::MessageDelta, "B");
        event(&mut p, "i", 4, EventKind::MessageEnd, "Complete reply");
        assert_eq!(p.view.sessions[0].items[1].text, "Complete reply");
    }
    #[test]
    fn reconnect_queries_unknown_command_without_resending_prompt() {
        let mut p = Projection::default();
        let replay = start(&mut p, "i");
        end(&mut p, &replay, "i", 0);
        let sent = p.command("i", Some("hello".into())).unwrap();
        p.disconnected(None);
        assert_eq!(p.view.commands[0].status, "unknown");
        assert!(p.command("i", Some("again".into())).is_err());
        p.receive(packet(Message::Welcome {
            server_id: None,
            generation_id: "g".into(),
            history_paging: false,
        }));
        let outgoing = p.receive(packet(Message::Sessions {
            sessions: vec![snapshot("i")],
        }));
        assert!(outgoing.iter().all(|e| matches!(
            e.message,
            Message::Replay { .. } | Message::GetResult { .. }
        )));
        let query = outgoing
            .iter()
            .find(|e| matches!(e.message, Message::GetResult { .. }))
            .unwrap();
        p.receive(Envelope::new(
            &query.request_id,
            Message::CommandResult {
                session_id: "s-i".into(),
                instance_id: "i".into(),
                status: CommandStatus::Accepted,
                code: None,
                detail: None,
                data: None,
            },
        ));
        assert_eq!(p.view.commands[0].request_id, sent.request_id);
        assert_eq!(p.view.commands[0].status, "accepted");
    }
    #[test]
    fn service_restart_does_not_query_old_generation_or_reuse_cursor() {
        let mut p = Projection::default();
        let replay = start(&mut p, "i");
        end(&mut p, &replay, "i", 0);
        event(&mut p, "i", 1, EventKind::UserMessage, "before");
        p.command("i", Some("unknown".into())).unwrap();
        p.disconnected(None);
        p.receive(packet(Message::Welcome {
            server_id: None,
            generation_id: "new".into(),
            history_paging: false,
        }));
        let outgoing = p.receive(packet(Message::Sessions {
            sessions: vec![snapshot("i")],
        }));
        assert_eq!(outgoing.len(), 1);
        assert!(matches!(
            outgoing[0].message,
            Message::Replay { after_seq: 0, .. }
        ));
        assert!(p.view.sessions[0].gaps.is_empty());
        assert!(p.view.sessions[0].items.is_empty());
        assert_eq!(p.view.commands[0].status, "unknown");
        event(&mut p, "i", 1, EventKind::UserMessage, "rebuilt");
        end(&mut p, &outgoing[0].request_id, "i", 1);
        assert_eq!(p.view.sessions[0].items[0].text, "rebuilt");
        assert!(p.view.sessions[0].gaps.is_empty());
    }
    #[test]
    fn sessions_and_execution_gates_remain_independent() {
        let mut p = Projection::default();
        let replay = start(&mut p, "i");
        end(&mut p, &replay, "i", 0);
        let outgoing = p.receive(packet(Message::Snapshot {
            session: snapshot("j"),
        }));
        end(&mut p, &outgoing[0].request_id, "j", 0);
        event(&mut p, "i", 1, EventKind::UserMessage, "one");
        event(&mut p, "j", 1, EventKind::UserMessage, "two");
        assert_eq!(p.view.sessions[0].items[0].text, "one");
        assert_eq!(p.view.sessions[1].items[0].text, "two");
        let mut stopping = snapshot("i");
        stopping.revision = 2;
        stopping.state = SessionState::Stopping;
        p.receive(packet(Message::Snapshot { session: stopping }));
        assert!(p.command("i", Some("blocked".into())).is_err());
        assert!(p.command("j", Some("allowed".into())).is_ok());
    }
    #[test]
    fn missing_and_bounded_history_are_visible() {
        let mut p = Projection::default();
        let replay = start(&mut p, "i");
        event(&mut p, "i", 5, EventKind::MessageDelta, "partial");
        end(&mut p, &replay, "i", 5);
        assert!(!p.view.sessions[0].gaps.is_empty());
        for seq in 6..=610 {
            event(&mut p, "i", seq, EventKind::UserMessage, "message");
        }
        assert_eq!(p.view.sessions[0].items.len(), 600);
        assert!(p.view.sessions[0]
            .gaps
            .iter()
            .any(|s| s.contains("released")));
    }
}

#[cfg(test)]
#[path = "history_tests.rs"]
mod history_tests;
