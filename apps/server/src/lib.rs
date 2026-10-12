use axum::{
    extract::{
        ws::{Message as WsMessage, WebSocket, WebSocketUpgrade},
        ConnectInfo, State,
    },
    response::Response,
    routing::get,
    Router,
};
use pirc_protocol::*;
use std::{
    collections::{HashMap, VecDeque},
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::{broadcast, mpsc, Mutex};
use uuid::Uuid;
mod agents;
mod approval;
mod attachments;
mod directories;
mod identity;
mod launcher;
mod secure;
mod state;

type Sender = mpsc::Sender<Envelope>;
#[derive(Clone)]
struct App {
    inner: Arc<Mutex<Registry>>,
    events: broadcast::Sender<Envelope>,
    generation: String,
    server_id: String,
    crypto_key: Arc<String>,
    launcher: Arc<launcher::Launcher>,
    approval: Arc<approval::Approval>,
    handshakes: Arc<tokio::sync::Semaphore>,
}
struct Live {
    snapshot: SessionSnapshot,
    owner: String,
    tx: Sender,
    seen: Instant,
    retired: bool,
    source_seq: u64,
    seq: u64,
    history: VecDeque<Envelope>,
    bytes: usize,
    source_gap: bool,
    transcript: pirc_core::projection::SessionView,
    history_truncated: bool,
}
struct Command {
    original: Envelope,
    result: Envelope,
    created: Instant,
}
#[derive(Default)]
struct Registry {
    sessions: HashMap<String, Live>,
    commands: HashMap<String, Command>,
    controller: Option<String>,
}
fn packet(message: Message) -> Envelope {
    Envelope::new(Uuid::new_v4().to_string(), message)
}
fn error(id: &str, code: &str, detail: &str) -> Envelope {
    Envelope::new(
        id,
        Message::Error {
            code: code.into(),
            detail: detail.into(),
        },
    )
}
fn reject(id: &str, sid: &str, iid: &str, code: &str) -> Envelope {
    Envelope::new(
        id,
        Message::CommandResult {
            session_id: sid.into(),
            instance_id: iid.into(),
            status: CommandStatus::Rejected,
            code: Some(code.into()),
            detail: None,
            data: None,
        },
    )
}
impl App {
    async fn sessions(&self) -> Envelope {
        packet(Message::Sessions {
            sessions: self
                .inner
                .lock()
                .await
                .sessions
                .values()
                .map(|s| s.snapshot.clone())
                .collect(),
        })
    }
    fn publish(&self, e: Envelope) {
        let _ = self.events.send(e);
    }
}
async fn info(State(app): State<App>) -> axum::Json<serde_json::Value> {
    axum::Json(
        serde_json::json!({"server_id": app.server_id, "protocol_version": PROTOCOL_VERSION, "encryption": pirc_crypto::SUBPROTOCOL}),
    )
}
async fn extension(
    State(app): State<App>,
    ConnectInfo(peer): ConnectInfo<std::net::SocketAddr>,
    ws: WebSocketUpgrade,
) -> Response {
    use axum::response::IntoResponse;
    if !peer.ip().is_loopback() {
        return axum::http::StatusCode::FORBIDDEN.into_response();
    }
    ws.max_message_size(secure::WIRE_LIMIT)
        .max_frame_size(secure::WIRE_LIMIT)
        .on_upgrade(move |ws| connection(app, ws, true, false))
}
async fn control(
    State(app): State<App>,
    ConnectInfo(peer): ConnectInfo<std::net::SocketAddr>,
    ws: WebSocketUpgrade,
) -> Response {
    use axum::response::IntoResponse;
    let ws = ws.protocols([pirc_crypto::SUBPROTOCOL]);
    let encrypted = ws.selected_protocol().is_some();
    if !encrypted && !peer.ip().is_loopback() {
        return axum::http::StatusCode::FORBIDDEN.into_response();
    }
    ws.max_message_size(secure::WIRE_LIMIT)
        .max_frame_size(secure::WIRE_LIMIT)
        .on_upgrade(move |ws| connection(app, ws, false, encrypted))
}
async fn send(ws: &mut secure::Socket, e: Envelope) -> bool {
    matches!(
        tokio::time::timeout(
            Duration::from_secs(5),
            ws.send(WsMessage::Text(serde_json::to_string(&e).unwrap().into())),
        )
        .await,
        Ok(Ok(()))
    )
}
async fn connection(app: App, ws: WebSocket, is_extension: bool, encrypted: bool) {
    let permit = if encrypted {
        match app.handshakes.clone().try_acquire_owned() {
            Ok(permit) => Some(permit),
            Err(_) => return,
        }
    } else {
        None
    };
    let Ok(Ok(mut ws)) = tokio::time::timeout(
        Duration::from_secs(5),
        secure::Socket::start(ws, &app.crypto_key, &app.server_id, encrypted),
    )
    .await
    else {
        return;
    };
    let first = tokio::time::timeout(Duration::from_secs(5), receive_packet(&mut ws))
        .await
        .ok()
        .flatten();
    let Some(first) = first else {
        return;
    };
    if !(matches!(first.message, Message::Auth { .. })
        || encrypted && matches!(first.message, Message::PairingRequest {}))
    {
        return;
    }
    let requires_approval = encrypted
        && (matches!(first.message, Message::PairingRequest {})
            || !app
                .approval
                .allowed(ws.client_key.as_deref().unwrap())
                .await);
    let auth = if requires_approval {
        if !await_approval(&app, &mut ws).await {
            return;
        }
        tokio::time::timeout(Duration::from_secs(5), receive_packet(&mut ws))
            .await
            .ok()
            .flatten()
    } else {
        Some(first)
    };
    drop(permit);
    let valid = auth.is_some_and(|e| matches!(e.message, Message::Auth {}));
    if !valid {
        send(
            &mut ws,
            error("auth", "UNAUTHORIZED", "Authentication failed"),
        )
        .await;
        return;
    }
    let owner = Uuid::new_v4().to_string();
    if !is_extension {
        let mut r = app.inner.lock().await;
        if r.controller.is_some() {
            drop(r);
            send(
                &mut ws,
                error("auth", "SERVER_BUSY", "A client is already connected"),
            )
            .await;
            return;
        }
        r.controller = Some(owner.clone());
    }
    // Subscribe before the initial snapshot so changes during authentication
    // are covered by replay or the live stream.
    let mut events = app.events.subscribe();
    send(
        &mut ws,
        packet(Message::Welcome {
            server_id: if is_extension {
                None
            } else {
                Some(app.server_id.clone())
            },
            generation_id: app.generation.clone(),
            history_paging: !is_extension,
        }),
    )
    .await;
    if !is_extension {
        send(&mut ws, app.sessions().await).await;
    }
    let (tx, mut outgoing) = mpsc::channel(256);
    let mut reads = tokio::task::JoinSet::new();
    let mut heartbeat = tokio::time::interval(Duration::from_secs(5));
    heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut last_received = Instant::now();
    loop {
        tokio::select! {
            _ = heartbeat.tick() => {
                if last_received.elapsed() >= Duration::from_secs(20) {
                    eprintln!("WebSocket heartbeat timed out; releasing connection");
                    break;
                }
                if !matches!(tokio::time::timeout(Duration::from_secs(5), ws.send(WsMessage::Ping(vec![].into()))).await, Ok(Ok(()))) {
                    break;
                }
            },
            incoming = ws.recv() => {
                if incoming.as_ref().is_some_and(Result::is_ok) {
                    last_received = Instant::now();
                }
                match incoming {
                    Some(Ok(WsMessage::Text(text))) => match Envelope::decode(&text) {
                        Ok(e) => {
                            // Filesystem/consent waits must not block event delivery,
                            // controller commands or WebSocket ping/pong processing.
                            if !is_extension && matches!(&e.message, Message::BrowseDirectories { .. } | Message::CreateDirectory { .. } | Message::SavedSessions {} | Message::UploadFileChunk { .. }) {
                                if reads.len() >= 8 {
                                    if !send(&mut ws, error(&e.request_id, "READ_BUSY", "Device is reading data. Try again later.")).await { break; }
                                } else {
                                    let app = app.clone();
                                    reads.spawn(async move { from_control(&app, e).await });
                                }
                                continue;
                            }
                            let replies = if is_extension { from_extension(&app, &owner, &tx, e).await } else { from_control(&app, e).await };
                            let mut failed = false;
                            for reply in replies { if !send(&mut ws, reply).await { failed = true; break; } }
                            if failed { break; }
                        },
                        Err(_) => { if !send(&mut ws, error("decode", "INVALID_FRAME", "Invalid protocol frame")).await { break; } }
                    },
                    Some(Ok(WsMessage::Ping(data))) => { if ws.send(WsMessage::Pong(data)).await.is_err() { break; } },
                    Some(Ok(WsMessage::Close(_))) | Some(Err(_)) | None => break,
                    _ => {},
                }
            },
            Some(e) = outgoing.recv() => { if !send(&mut ws, e).await { break; } },
            Some(result) = reads.join_next(), if !reads.is_empty() => {
                if let Ok(replies) = result {
                    let mut failed = false;
                    for reply in replies { if !send(&mut ws, reply).await { failed = true; break; } }
                    if failed { break; }
                }
            },
            e = events.recv(), if !is_extension => {
                match e {
                    Ok(e) => { if !send(&mut ws, e).await { break; } },
                    Err(broadcast::error::RecvError::Lagged(_)) => {
                        if !send(&mut ws, error("events", "EVENT_GAP", "Client fell behind; refresh state")).await { break; }
                        if !send(&mut ws, app.sessions().await).await { break; }
                    },
                    Err(_) => break,
                }
            }
        }
    }
    // Dropping the tasks also drops/kills their child processes on disconnect.
    reads.abort_all();
    let mut r = app.inner.lock().await;
    if is_extension {
        for live in r.sessions.values_mut().filter(|s| s.owner == owner) {
            live.snapshot.state = SessionState::Offline;
            app.publish(packet(Message::Snapshot {
                session: live.snapshot.clone(),
            }));
        }
    } else if r.controller.as_ref() == Some(&owner) {
        r.controller = None;
    }
}

async fn receive_packet(ws: &mut secure::Socket) -> Option<Envelope> {
    loop {
        match ws.recv().await? {
            Ok(WsMessage::Text(text)) => return Envelope::decode(&text).ok(),
            Ok(WsMessage::Ping(bytes)) => {
                ws.send(WsMessage::Pong(bytes)).await.ok()?;
            }
            Ok(WsMessage::Pong(_)) => {}
            _ => return None,
        }
    }
}

async fn await_approval(app: &App, ws: &mut secure::Socket) -> bool {
    let code = ws.pairing_code.clone().unwrap();
    let key = ws.client_key.clone().unwrap();
    let mut approved = match app.approval.request(key, code.clone()).await {
        Ok(receiver) => receiver,
        Err(detail) => {
            send(ws, error("pairing", "PAIRING_BUSY", &detail)).await;
            return false;
        }
    };
    if !send(
        ws,
        packet(Message::PairingRequired {
            code: code.clone(),
            expires_in: approval::TTL,
        }),
    )
    .await
    {
        app.approval.cancel(&code).await;
        return false;
    }
    println!("New client awaiting approval: pirc allow {code} (expires in 5 minutes)");
    let timeout = tokio::time::sleep(Duration::from_secs(approval::TTL.into()));
    tokio::pin!(timeout);
    let mut ping = tokio::time::interval(Duration::from_secs(5));
    let accepted = loop {
        tokio::select! {
            reply = &mut approved => break reply.is_ok(),
            _ = &mut timeout => { send(ws, error("pairing", "PAIRING_EXPIRED", "Pairing code expired. Reconnect to retry.")).await; break false; },
            _ = ping.tick() => { if ws.send(WsMessage::Ping(vec![].into())).await.is_err() { break false; } },
            incoming = ws.recv() => match incoming {
                Some(Ok(WsMessage::Ping(bytes))) => { if ws.send(WsMessage::Pong(bytes)).await.is_err() { break false; } },
                Some(Ok(WsMessage::Pong(_))) => {},
                _ => { send(ws, error("pairing", "PAIRING_REQUIRED", "Approve this client on the server first")).await; break false; }
            }
        }
    };
    app.approval.cancel(&code).await;
    accepted && send(ws, packet(Message::PairingApproved {})).await
}
async fn from_extension(app: &App, owner: &str, tx: &Sender, e: Envelope) -> Vec<Envelope> {
    let mut r = app.inner.lock().await;
    match &e.message {
        Message::Register { session } => {
            if session.agent_id.is_empty()
                || session.session_id.is_empty()
                || session.instance_id.is_empty()
                || session.state == SessionState::Offline
            {
                return vec![error(
                    &e.request_id,
                    "INVALID_REGISTER",
                    "Registration requires active identity",
                )];
            }
            if let Some(live) = r.sessions.get_mut(&session.instance_id) {
                if live.retired {
                    return vec![error(
                        &e.request_id,
                        "STALE_INSTANCE",
                        "Instance has been retired",
                    )];
                }
                if live.snapshot.session_id != session.session_id
                    || live.snapshot.agent_id != session.agent_id
                {
                    return vec![error(
                        &e.request_id,
                        "IDENTITY_MISMATCH",
                        "Instance belongs to another Session",
                    )];
                }
                live.snapshot = session.clone();
                live.owner = owner.into();
                live.tx = tx.clone();
                live.seen = Instant::now();
            } else {
                if r.sessions.len() >= 128 {
                    if let Some(key) = r
                        .sessions
                        .iter()
                        .filter(|(_, s)| s.snapshot.state == SessionState::Offline)
                        .min_by_key(|(_, s)| s.seen)
                        .map(|(k, _)| k.clone())
                    {
                        r.sessions.remove(&key);
                    } else {
                        return vec![error(&e.request_id, "REGISTRY_FULL", "Too many instances")];
                    }
                }
                r.sessions.insert(
                    session.instance_id.clone(),
                    Live {
                        snapshot: session.clone(),
                        owner: owner.into(),
                        tx: tx.clone(),
                        seen: Instant::now(),
                        retired: false,
                        source_seq: 0,
                        seq: 0,
                        history: VecDeque::new(),
                        bytes: 0,
                        source_gap: false,
                        transcript: pirc_core::projection::SessionView::new(session.clone()),
                        history_truncated: false,
                    },
                );
            }
            app.publish(packet(Message::Snapshot {
                session: session.clone(),
            }));
            if let Some(id) = &session.launch_id {
                app.launcher.registered(id).await;
            }
        }
        Message::Snapshot { session } | Message::Heartbeat { session, .. } => {
            if let Some(live) = r.sessions.get_mut(&session.instance_id).filter(|s| {
                s.owner == owner
                    && !s.retired
                    && s.snapshot.agent_id == session.agent_id
                    && s.snapshot.session_id == session.session_id
            }) {
                if let Message::Heartbeat { source_seq, .. } = e.message {
                    if source_seq > live.source_seq {
                        live.source_gap = true;
                        app.publish(packet(Message::Gap {
                            session_id: session.session_id.clone(),
                            instance_id: session.instance_id.clone(),
                            reason: "Extension event gap".into(),
                        }));
                        live.source_seq = source_seq;
                    }
                }
                let changed = live.snapshot != *session;
                live.snapshot = session.clone();
                live.seen = Instant::now();
                if changed {
                    app.publish(packet(Message::Snapshot {
                        session: session.clone(),
                    }));
                }
            }
        }
        Message::Unregister {
            session_id,
            instance_id,
        } => {
            if let Some(live) = r
                .sessions
                .get_mut(instance_id)
                .filter(|s| s.owner == owner && s.snapshot.session_id == *session_id)
            {
                live.snapshot.state = SessionState::Offline;
                live.retired = true;
                app.publish(packet(Message::Snapshot {
                    session: live.snapshot.clone(),
                }));
                for (id, command) in &mut r.commands {
                    if matches!(&command.original.message, Message::CloseSession { session_id: s, instance_id: i, .. } if s == session_id && i == instance_id)
                        && matches!(
                            &command.result.message,
                            Message::CommandResult {
                                status: CommandStatus::Accepted,
                                ..
                            }
                        )
                    {
                        command.result = Envelope::new(
                            id.clone(),
                            Message::CommandResult {
                                session_id: session_id.clone(),
                                instance_id: instance_id.clone(),
                                status: CommandStatus::Completed,
                                code: None,
                                detail: None,
                                data: None,
                            },
                        );
                        app.publish(command.result.clone());
                    }
                }
            }
        }
        Message::Event {
            session_id,
            instance_id,
            source_seq,
            event,
            ..
        } => {
            if let Some(live) = r.sessions.get_mut(instance_id).filter(|s| {
                s.owner == owner
                    && !s.retired
                    && s.snapshot.session_id == *session_id
                    && s.snapshot.state != SessionState::Offline
            }) {
                if *source_seq <= live.source_seq {
                    return vec![];
                }
                if *source_seq != live.source_seq + 1 {
                    live.source_gap = true;
                    app.publish(packet(Message::Gap {
                        session_id: session_id.clone(),
                        instance_id: instance_id.clone(),
                        reason: "Extension event gap".into(),
                    }));
                }
                live.source_seq = *source_seq;
                live.seq += 1;
                live.transcript.event(live.seq, *source_seq, event.clone());
                // Retain whole blocks, independently of the shorter event replay log.
                while live.transcript.items.len() > 4000
                    || live
                        .transcript
                        .items
                        .iter()
                        .map(|i| i.text.len() + i.arguments.as_ref().map_or(0, String::len))
                        .sum::<usize>()
                        > 32 * 1024 * 1024
                {
                    if let Some(index) = live.transcript.items.iter().position(|i| i.complete) {
                        live.transcript.items.remove(index);
                        live.history_truncated = true;
                    } else {
                        break;
                    }
                }
                live.seen = Instant::now();
                let event = Envelope::new(
                    e.request_id.clone(),
                    Message::Event {
                        session_id: session_id.clone(),
                        instance_id: instance_id.clone(),
                        source_seq: *source_seq,
                        seq: live.seq,
                        event: event.clone(),
                    },
                );
                live.bytes += serde_json::to_vec(&event).unwrap().len();
                live.history.push_back(event.clone());
                while live.history.len() > 10000 || live.bytes > 32 * 1024 * 1024 {
                    if let Some(old) = live.history.pop_front() {
                        live.bytes -= serde_json::to_vec(&old).unwrap().len();
                    } else {
                        break;
                    }
                }
                app.publish(event);
            }
        }
        Message::CommandResult {
            session_id,
            instance_id,
            ..
        } => {
            let valid = r
                .sessions
                .get(instance_id)
                .is_some_and(|s| s.owner == owner && s.snapshot.session_id == *session_id);
            if valid {
                if let Some(cmd) = r.commands.get_mut(&e.request_id) {
                    let expected = match &cmd.original.message {
                        Message::Stop {
                            session_id: s,
                            instance_id: i,
                            ..
                        }
                        | Message::Prompt {
                            session_id: s,
                            instance_id: i,
                            ..
                        }
                        | Message::ReadImage {
                            session_id: s,
                            instance_id: i,
                            ..
                        }
                        | Message::CloseSession {
                            session_id: s,
                            instance_id: i,
                            ..
                        }
                        | Message::Builtin {
                            session_id: s,
                            instance_id: i,
                            ..
                        } => s == session_id && i == instance_id,
                        _ => false,
                    };
                    if expected {
                        let image_read = matches!(cmd.original.message, Message::ReadImage { .. });
                        cmd.result = e.clone();
                        app.publish(e.clone());
                        if image_read {
                            r.commands.remove(&e.request_id);
                        }
                    }
                }
            }
        }
        _ => {
            return vec![error(
                &e.request_id,
                "INVALID_DIRECTION",
                "Message is not allowed from an Extension",
            )]
        }
    }
    vec![]
}
fn history_page(
    live: &Live,
    direction: &HistoryDirection,
    cursor: Option<u64>,
    limit: u32,
) -> Result<Message, &'static str> {
    if limit == 0 || limit > 100 {
        return Err("INVALID_HISTORY");
    }
    let items = &live.transcript.items;
    let n = items.len();
    let limit = limit as usize;
    let (mut start, mut end) = match direction {
        HistoryDirection::Latest => (n.saturating_sub(limit), n),
        HistoryDirection::Before => {
            let cursor = cursor.ok_or("INVALID_HISTORY")?;
            let end = items.partition_point(|i| i.first_seq < cursor);
            (end.saturating_sub(limit), end)
        }
        HistoryDirection::After => {
            let cursor = cursor.ok_or("INVALID_HISTORY")?;
            let start = items.partition_point(|i| i.first_seq <= cursor);
            (start, (start + limit).min(n))
        }
        HistoryDirection::Around => {
            let cursor = cursor.ok_or("INVALID_HISTORY")?;
            let index = items
                .iter()
                .position(|i| i.first_seq == cursor)
                .ok_or("HISTORY_NOT_FOUND")?;
            let start = index.saturating_sub(limit / 2).min(n.saturating_sub(limit));
            (start, (start + limit).min(n))
        }
    };
    // One frame must stay below the shared transport limit, even for large tools.
    while end - start > 1 && serde_json::to_vec(&items[start..end]).unwrap().len() > 700 * 1024 {
        match direction {
            HistoryDirection::Latest | HistoryDirection::Before => start += 1,
            HistoryDirection::After => end -= 1,
            HistoryDirection::Around => {
                let target = cursor.unwrap();
                if items[start].first_seq != target
                    && (items[end - 1].first_seq == target
                        || end - start > 2
                            && target - items[start].first_seq > items[end - 1].first_seq - target)
                {
                    start += 1;
                } else {
                    end -= 1;
                }
            }
        }
    }
    Ok(Message::HistoryPage {
        session_id: live.snapshot.session_id.clone(),
        instance_id: live.snapshot.instance_id.clone(),
        items: items[start..end].to_vec(),
        has_before: start > 0,
        has_after: end < n,
        last_seq: live.seq,
        source_seq: live.source_seq,
        history_truncated: live.history_truncated,
    })
}
async fn from_control(app: &App, e: Envelope) -> Vec<Envelope> {
    if let Message::UploadFileChunk {
        generation_id,
        session_id,
        instance_id,
        ..
    } = &e.message
    {
        let valid = generation_id == &app.generation
            && app
                .inner
                .lock()
                .await
                .sessions
                .get(instance_id)
                .is_some_and(|s| {
                    s.snapshot.session_id == *session_id
                        && s.snapshot.state != SessionState::Offline
                        && s.seen.elapsed() < Duration::from_secs(15)
                });
        if !valid {
            return vec![error(
                &e.request_id,
                "STALE_INSTANCE",
                "Session is no longer available",
            )];
        }
        let message = e.message.clone();
        let result = tokio::task::spawn_blocking(move || attachments::store(&message)).await;
        return vec![match result {
            Ok(Ok(message)) => Envelope::new(e.request_id, message),
            Ok(Err(detail)) => error(&e.request_id, "FILE_UPLOAD_FAILED", &detail),
            Err(_) => error(&e.request_id, "FILE_UPLOAD_FAILED", "Unable to upload file"),
        }];
    }
    if let Message::CreateDirectory { parent, name } = &e.message {
        let message = app.launcher.directories.create(parent, name).await;
        return vec![Envelope::new(e.request_id, message)];
    }
    if let Message::BrowseDirectories {
        path,
        cursor,
        show_hidden,
    } = &e.message
    {
        let message = app
            .launcher
            .directories
            .browse(path.as_deref(), cursor.as_deref(), *show_hidden)
            .await;
        return vec![Envelope::new(e.request_id, message)];
    }
    if matches!(
        &e.message,
        Message::SavedSessions {} | Message::LaunchSession { .. }
    ) {
        let online = app
            .inner
            .lock()
            .await
            .sessions
            .values()
            .filter(|s| s.snapshot.state != SessionState::Offline)
            .map(|s| s.snapshot.clone())
            .collect::<Vec<_>>();
        let result = match &e.message {
            Message::SavedSessions {} => {
                app.launcher
                    .catalog(
                        &online
                            .iter()
                            .map(|s| (s.agent_id.clone(), s.session_id.clone()))
                            .collect::<Vec<_>>(),
                    )
                    .await
            }
            Message::LaunchSession {
                agent_id,
                generation_id,
                session_id,
                ..
            } => {
                if generation_id != &app.generation {
                    return vec![error(
                        &e.request_id,
                        "STALE_GENERATION",
                        "Device server restarted. Wait for reconnection.",
                    )];
                }
                if let Some(session) = online
                    .iter()
                    .find(|s| &s.agent_id == agent_id && session_id.as_ref() == Some(&s.session_id))
                {
                    Ok(Message::SessionLaunched {
                        launch_id: e.request_id.clone(),
                        instance_id: Some(session.instance_id.clone()),
                    })
                } else {
                    app.launcher.launch(&e.request_id, &e.message).await
                }
            }
            _ => unreachable!(),
        };
        return vec![match result {
            Ok(message) => Envelope::new(e.request_id, message),
            Err(detail) => error(&e.request_id, "SESSION_LAUNCH_ERROR", &detail),
        }];
    }
    let mut r = app.inner.lock().await;
    match &e.message {
        Message::History {
            session_id,
            instance_id,
            direction,
            cursor,
            limit,
        } => {
            let Some(live) = r
                .sessions
                .get(instance_id)
                .filter(|s| s.snapshot.session_id == *session_id)
            else {
                return vec![error(&e.request_id, "NOT_FOUND", "Session not found")];
            };
            match history_page(live, direction, *cursor, *limit) {
                Ok(message) => {
                    let mut replies = vec![packet(Message::Snapshot {
                        session: live.snapshot.clone(),
                    })];
                    if live.source_gap {
                        replies.push(packet(Message::Gap {
                            session_id: session_id.clone(),
                            instance_id: instance_id.clone(),
                            reason: "Extension event gap".into(),
                        }));
                    }
                    replies.push(Envelope::new(e.request_id, message));
                    replies
                }
                Err(code) => vec![error(
                    &e.request_id,
                    code,
                    "Invalid history cursor or page size",
                )],
            }
        }
        Message::List {} => vec![Envelope::new(
            e.request_id,
            Message::Sessions {
                sessions: r.sessions.values().map(|s| s.snapshot.clone()).collect(),
            },
        )],
        Message::Replay {
            session_id,
            instance_id,
            after_seq,
        } => {
            if let Some(live) = r
                .sessions
                .get(instance_id)
                .filter(|s| s.snapshot.session_id == *session_id)
            {
                let mut reply = vec![packet(Message::Snapshot {
                    session: live.snapshot.clone(),
                })];
                let earliest = live
                    .history
                    .front()
                    .and_then(|e| match e.message {
                        Message::Event { seq, .. } => Some(seq),
                        _ => None,
                    })
                    .unwrap_or(live.seq + 1);
                if *after_seq > live.seq || after_seq.saturating_add(1) < earliest {
                    reply.push(packet(Message::Gap {
                        session_id: session_id.clone(),
                        instance_id: instance_id.clone(),
                        reason: "Events are outside retained range".into(),
                    }));
                }
                if live.source_gap {
                    reply.push(packet(Message::Gap {
                        session_id: session_id.clone(),
                        instance_id: instance_id.clone(),
                        reason: "Extension event gap".into(),
                    }));
                }
                reply.extend(
                    live.history
                        .iter()
                        .filter(|e| matches!(e.message,Message::Event{seq,..} if seq>*after_seq))
                        .cloned(),
                );
                reply.push(Envelope::new(
                    e.request_id.clone(),
                    Message::ReplayEnd {
                        session_id: session_id.clone(),
                        instance_id: instance_id.clone(),
                        last_seq: live.seq,
                    },
                ));
                reply
            } else {
                vec![error(&e.request_id, "NOT_FOUND", "Session not found")]
            }
        }
        Message::GetResult { command_id } => vec![r
            .commands
            .get(command_id)
            .map(|c| Envelope::new(e.request_id.clone(), c.result.message.clone()))
            .unwrap_or_else(|| {
                error(&e.request_id, "RESULT_UNKNOWN", "Command result is unknown")
            })],
        Message::Stop {
            generation_id,
            session_id,
            instance_id,
        }
        | Message::Prompt {
            generation_id,
            session_id,
            instance_id,
            ..
        }
        | Message::Builtin {
            generation_id,
            session_id,
            instance_id,
            ..
        }
        | Message::ReadImage {
            generation_id,
            session_id,
            instance_id,
            ..
        }
        | Message::CloseSession {
            generation_id,
            session_id,
            instance_id,
            ..
        } => {
            if generation_id != &app.generation {
                return vec![reject(
                    &e.request_id,
                    session_id,
                    instance_id,
                    "STALE_GENERATION",
                )];
            }
            if let Some(cmd) = r.commands.get(&e.request_id) {
                return vec![if cmd.original == e {
                    cmd.result.clone()
                } else {
                    error(
                        &e.request_id,
                        "REQUEST_ID_REUSED",
                        "Request ID has different payload",
                    )
                }];
            }
            if r.commands.len() >= 10000 {
                return vec![error(
                    &e.request_id,
                    "COMMAND_CAPACITY",
                    "Command cache is full",
                )];
            }
            let target = r.sessions.get(instance_id).filter(|s| {
                s.snapshot.session_id == *session_id
                    && s.snapshot.state != SessionState::Offline
                    && s.seen.elapsed() < Duration::from_secs(15)
            });
            let Some(target) = target else {
                return vec![reject(
                    &e.request_id,
                    session_id,
                    instance_id,
                    "STALE_INSTANCE",
                )];
            };
            if r.commands.values().any(|c| {
                matches!(&c.original.message, Message::CloseSession { instance_id: i, .. } if i == instance_id)
                    && (matches!(&c.result.message, Message::CommandResult { status: CommandStatus::Accepted, .. }) || matches!(&c.result.message, Message::Error { code, .. } if code == "PENDING"))
            }) {
                return vec![reject(&e.request_id, session_id, instance_id, "CLOSING")];
            }
            if let Message::CloseSession {
                expected_revision, ..
            } = &e.message
            {
                let code = if target.snapshot.can_close != Some(true)
                    || target
                        .snapshot
                        .launch_id
                        .as_ref()
                        .is_none_or(|id| id.is_empty())
                {
                    Some("UNMANAGED_TERMINAL")
                } else if target.snapshot.state != SessionState::Idle
                    || target.snapshot.needs_local_attention
                {
                    Some("BUSY")
                } else if *expected_revision != target.snapshot.revision {
                    Some("STALE_STATE")
                } else {
                    None
                };
                if let Some(code) = code {
                    return vec![reject(&e.request_id, session_id, instance_id, code)];
                }
            }
            if let Message::Prompt { text, images, .. } = &e.message {
                if images.len() > 4
                    || images.iter().map(|i| i.data.len()).sum::<usize>() > 600 * 1024
                    || (!images.is_empty() && text.trim_start().starts_with('/'))
                {
                    return vec![reject(
                        &e.request_id,
                        session_id,
                        instance_id,
                        "INVALID_ARGUMENT",
                    )];
                }
                if let Some(name) = text
                    .trim_start()
                    .strip_prefix('/')
                    .and_then(|s| s.split_whitespace().next())
                {
                    let command = target
                        .snapshot
                        .slash_commands
                        .as_ref()
                        .and_then(|commands| commands.iter().find(|c| c.name == name));
                    if !command.is_some_and(|c| c.source == "prompt" || c.source == "skill") {
                        return vec![reject(
                            &e.request_id,
                            session_id,
                            instance_id,
                            "LOCAL_COMMAND_REQUIRED",
                        )];
                    }
                }
            }
            if let Message::Builtin { command, args, .. } = &e.message {
                let supported = target
                    .snapshot
                    .slash_commands
                    .as_ref()
                    .is_some_and(|commands| {
                        commands
                            .iter()
                            .any(|c| c.name == command.name() && c.source == "builtin")
                    });
                if !supported || args.len() > 64 * 1024 {
                    return vec![reject(
                        &e.request_id,
                        session_id,
                        instance_id,
                        if supported {
                            "INVALID_ARGUMENT"
                        } else {
                            "LOCAL_COMMAND_REQUIRED"
                        },
                    )];
                }
            }
            if let Message::ReadImage {
                image_id, offset, ..
            } = &e.message
            {
                if image_id.len() != 64
                    || !image_id.bytes().all(|b| b.is_ascii_hexdigit())
                    || offset % 4 != 0
                    || *offset > 28 * 1024 * 1024
                {
                    return vec![reject(
                        &e.request_id,
                        session_id,
                        instance_id,
                        "INVALID_ARGUMENT",
                    )];
                }
            }
            if target.tx.try_send(e.clone()).is_err() {
                return vec![error(
                    &e.request_id,
                    "UNAVAILABLE",
                    "Extension queue unavailable",
                )];
            }
            let result = error(
                &e.request_id,
                "PENDING",
                "Command forwarded; completion not confirmed",
            );
            r.commands.insert(
                e.request_id.clone(),
                Command {
                    original: e,
                    result,
                    created: Instant::now(),
                },
            );
            vec![]
        }
        _ => vec![error(
            &e.request_id,
            "INVALID_DIRECTION",
            "Message is not allowed from a client",
        )],
    }
}
pub async fn allow(code: &str) -> Result<(), String> {
    approval::cli_allow(code).await
}
pub async fn waitlist() -> Result<(), String> {
    approval::cli_waitlist().await
}

pub async fn run() {
    run_with_port(None).await;
}

pub async fn run_with_port(port: Option<u16>) {
    let port = port.unwrap_or(43123);
    let listener = match tokio::net::TcpListener::bind(("0.0.0.0", port)).await {
        Ok(listener) => listener,
        Err(error) => {
            if error.kind() == std::io::ErrorKind::AddrInUse {
                eprintln!("Port {port} is already in use.");
            } else {
                eprintln!("Cannot listen on port {port}: {error}");
            }
            std::process::exit(1);
        }
    };
    let (events, _) = broadcast::channel(1024);
    let app = App {
        inner: Arc::new(Mutex::new(Registry::default())),
        events,
        generation: Uuid::new_v4().to_string(),
        server_id: identity::load().expect("Cannot load server identity"),
        crypto_key: Arc::new(secure::load_key().expect("Cannot load encryption identity")),
        launcher: Arc::new(launcher::Launcher::new(port)),
        approval: Arc::new(
            approval::Approval::open(approval::directory()).expect("Cannot load client approvals"),
        ),
        handshakes: Arc::new(tokio::sync::Semaphore::new(64)),
    };
    if let Err(error) = app.approval.listen().await {
        eprintln!("Cannot start PiRC Server: {error}");
        std::process::exit(1);
    }
    println!(
        "PiRC encryption fingerprint:\n{}",
        pirc_crypto::fingerprint(&pirc_crypto::public_key(&app.crypto_key).unwrap()).unwrap()
    );
    let monitor = app.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(1));
        loop {
            tick.tick().await;
            let mut r = monitor.inner.lock().await;
            for live in r.sessions.values_mut() {
                if live.snapshot.state != SessionState::Offline
                    && live.seen.elapsed() > Duration::from_secs(15)
                {
                    live.snapshot.state = SessionState::Offline;
                    monitor.publish(packet(Message::Snapshot {
                        session: live.snapshot.clone(),
                    }));
                }
            }
            r.commands
                .retain(|_, c| c.created.elapsed() < Duration::from_secs(600));
        }
    });
    let router = Router::new()
        .route("/extension", get(extension))
        .route("/control", get(control))
        .route("/pirc/info", get(info))
        .route("/health", get(|| async { "ok" }))
        .with_state(app);
    println!(
        "PiRC Server listening on {}",
        listener.local_addr().unwrap()
    );
    axum::serve(
        listener,
        router.into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .with_graceful_shutdown(async {
        let _ = tokio::signal::ctrl_c().await;
    })
    .await
    .unwrap();
}

#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn file_upload_requires_current_generation_and_online_session() {
        let app = app();
        let (tx, _) = mpsc::channel(8);
        from_extension(
            &app,
            "owner",
            &tx,
            packet(Message::Register { session: session() }),
        )
        .await;
        for (generation, session_id, instance) in [
            ("old", "s", "i"),
            ("g", "other", "i"),
            ("g", "s", "missing"),
        ] {
            let replies = from_control(
                &app,
                Envelope::new(
                    "upload",
                    Message::UploadFileChunk {
                        generation_id: generation.into(),
                        session_id: session_id.into(),
                        instance_id: instance.into(),
                        upload_id: Uuid::new_v4().to_string(),
                        name: "note.txt".into(),
                        offset: 0,
                        total: 1,
                        data: "YQ==".into(),
                    },
                ),
            )
            .await;
            assert!(
                matches!(&replies[0].message, Message::Error { code, .. } if code == "STALE_INSTANCE")
            );
        }
    }

    #[tokio::test]
    async fn image_reads_are_scoped_available_while_running_and_not_cached() {
        let app = app();
        let (tx, mut rx) = mpsc::channel(8);
        let mut running = session();
        running.state = SessionState::Running;
        from_extension(
            &app,
            "owner",
            &tx,
            packet(Message::Register { session: running }),
        )
        .await;
        let request = Envelope::new(
            "image",
            Message::ReadImage {
                generation_id: "g".into(),
                session_id: "s".into(),
                instance_id: "i".into(),
                image_id: "a".repeat(64),
                offset: 0,
            },
        );
        assert!(from_control(&app, request.clone()).await.is_empty());
        assert_eq!(rx.try_recv().unwrap(), request);
        let response = Envelope::new(
            "image",
            Message::CommandResult {
                session_id: "s".into(),
                instance_id: "i".into(),
                status: CommandStatus::Completed,
                code: None,
                detail: None,
                data: Some(CommandData::ImageChunk {
                    data: "AAAA".into(),
                    mime_type: "image/png".into(),
                    offset: 0,
                    total: 4,
                }),
            },
        );
        from_extension(&app, "wrong-owner", &tx, response.clone()).await;
        assert!(app.inner.lock().await.commands.contains_key("image"));
        from_extension(&app, "owner", &tx, response).await;
        assert!(!app.inner.lock().await.commands.contains_key("image"));
        let bad = Envelope::new(
            "bad",
            Message::ReadImage {
                generation_id: "g".into(),
                session_id: "s".into(),
                instance_id: "i".into(),
                image_id: "a".repeat(64),
                offset: 1,
            },
        );
        let rejected = from_control(&app, bad).await;
        assert!(
            matches!(&rejected[0].message, Message::CommandResult { status: CommandStatus::Rejected, code: Some(code), .. } if code == "INVALID_ARGUMENT")
        );
        assert!(rx.try_recv().is_err());
    }

    use super::*;
    #[tokio::test]
    async fn builtin_routing_requires_advertised_capability_and_preserves_output() {
        let app = app();
        let (tx, mut rx) = mpsc::channel(8);
        from_extension(
            &app,
            "owner",
            &tx,
            packet(Message::Register { session: session() }),
        )
        .await;
        let request = packet(Message::Builtin {
            generation_id: "g".into(),
            session_id: "s".into(),
            instance_id: "i".into(),
            expected_revision: 0,
            command: BuiltinCommand::Name,
            args: "new name".into(),
        });
        assert!(matches!(
            from_control(&app, request.clone()).await[0].message,
            Message::CommandResult {
                status: CommandStatus::Rejected,
                ..
            }
        ));
        let mut updated = session();
        updated.slash_commands = Some(vec![SlashCommand {
            name: "name".into(),
            description: None,
            source: "builtin".into(),
        }]);
        from_extension(
            &app,
            "owner",
            &tx,
            packet(Message::Snapshot { session: updated }),
        )
        .await;
        assert!(from_control(&app, request.clone()).await.is_empty());
        assert_eq!(rx.try_recv().unwrap(), request);
        let result = Envelope::new(
            &request.request_id,
            Message::CommandResult {
                session_id: "s".into(),
                instance_id: "i".into(),
                status: CommandStatus::Completed,
                code: None,
                detail: None,
                data: Some(CommandData::Name {
                    name: Some("new name".into()),
                }),
            },
        );
        from_extension(&app, "owner", &tx, result.clone()).await;
        assert_eq!(from_control(&app, request).await, vec![result]);
        assert!(rx.try_recv().is_err());
    }
    #[tokio::test]
    async fn exit_requires_managed_idle_revision_and_only_completes_on_unregister() {
        let app = app();
        let (tx, mut rx) = mpsc::channel(8);
        let mut s = session();
        from_extension(
            &app,
            "owner",
            &tx,
            packet(Message::Register { session: s.clone() }),
        )
        .await;
        let request = |revision| {
            packet(Message::CloseSession {
                generation_id: "g".into(),
                session_id: "s".into(),
                instance_id: "i".into(),
                expected_revision: revision,
            })
        };
        let assert_rejected = |replies: Vec<Envelope>, code: &str| {
            assert!(
                matches!(&replies[0].message, Message::CommandResult { status: CommandStatus::Rejected, code: Some(c), .. } if c == code)
            );
        };
        assert_rejected(from_control(&app, request(0)).await, "UNMANAGED_TERMINAL");
        assert!(rx.try_recv().is_err());
        s.launch_id = Some("launch".into());
        s.can_close = Some(true);
        s.state = SessionState::Running;
        s.revision = 3;
        from_extension(
            &app,
            "owner",
            &tx,
            packet(Message::Snapshot { session: s.clone() }),
        )
        .await;
        assert_rejected(from_control(&app, request(3)).await, "BUSY");
        s.state = SessionState::Idle;
        from_extension(
            &app,
            "owner",
            &tx,
            packet(Message::Snapshot { session: s.clone() }),
        )
        .await;
        assert_rejected(from_control(&app, request(2)).await, "STALE_STATE");
        s.needs_local_attention = true;
        from_extension(
            &app,
            "owner",
            &tx,
            packet(Message::Snapshot { session: s.clone() }),
        )
        .await;
        assert_rejected(from_control(&app, request(3)).await, "BUSY");
        s.needs_local_attention = false;
        from_extension(&app, "owner", &tx, packet(Message::Snapshot { session: s })).await;
        let close = request(3);
        assert!(from_control(&app, close.clone()).await.is_empty());
        assert_eq!(rx.try_recv().unwrap(), close);
        let accepted = Envelope::new(
            &close.request_id,
            Message::CommandResult {
                session_id: "s".into(),
                instance_id: "i".into(),
                status: CommandStatus::Accepted,
                code: None,
                detail: None,
                data: None,
            },
        );
        from_extension(&app, "owner", &tx, accepted.clone()).await;
        assert_eq!(from_control(&app, close.clone()).await, vec![accepted]);
        assert_rejected(from_control(&app, request(3)).await, "CLOSING");
        assert!(rx.try_recv().is_err());
        from_extension(
            &app,
            "wrong-owner",
            &tx,
            packet(Message::Unregister {
                session_id: "s".into(),
                instance_id: "i".into(),
            }),
        )
        .await;
        assert!(matches!(
            &app.inner.lock().await.commands[&close.request_id]
                .result
                .message,
            Message::CommandResult {
                status: CommandStatus::Accepted,
                ..
            }
        ));
        from_extension(
            &app,
            "owner",
            &tx,
            packet(Message::Unregister {
                session_id: "s".into(),
                instance_id: "i".into(),
            }),
        )
        .await;
        assert!(matches!(
            &app.inner.lock().await.commands[&close.request_id]
                .result
                .message,
            Message::CommandResult {
                status: CommandStatus::Completed,
                ..
            }
        ));
        assert_eq!(
            app.inner.lock().await.sessions["i"].snapshot.state,
            SessionState::Offline
        );
    }
    fn app() -> App {
        let (events, _) = broadcast::channel(16);
        App {
            inner: Arc::new(Mutex::new(Registry::default())),
            events,
            generation: "g".into(),
            server_id: "test-server".into(),
            crypto_key: Arc::new(pirc_crypto::generate_key().unwrap()),
            launcher: Arc::new(launcher::Launcher::new(43123)),
            approval: Arc::new(
                approval::Approval::open(
                    std::env::temp_dir().join(format!("pirc-approval-test-{}", Uuid::new_v4())),
                )
                .unwrap(),
            ),
            handshakes: Arc::new(tokio::sync::Semaphore::new(64)),
        }
    }
    fn session() -> SessionSnapshot {
        SessionSnapshot {
            agent_id: "pi".into(),
            capabilities: vec![],
            ui_prompt: None,
            session_id: "s".into(),
            instance_id: "i".into(),
            cwd: "/tmp".into(),
            name: None,
            state: SessionState::Idle,
            revision: 0,
            needs_local_attention: false,
            slash_commands: None,
            controls: None,
            launch_id: None,
            can_close: None,
        }
    }
    #[tokio::test]
    async fn restoring_another_agent_cannot_reuse_an_online_session_id() {
        let app = app();
        let (tx, _rx) = mpsc::channel(8);
        from_extension(
            &app,
            "owner",
            &tx,
            packet(Message::Register { session: session() }),
        )
        .await;
        let request = |agent: &str| {
            packet(Message::LaunchSession {
                agent_id: agent.into(),
                generation_id: "g".into(),
                cwd: "/tmp".into(),
                session_id: Some("s".into()),
                name: None,
                create_cwd: false,
            })
        };
        let existing = from_control(&app, request("pi")).await;
        assert!(
            matches!(&existing[0].message, Message::SessionLaunched { instance_id: Some(id), .. } if id == "i")
        );
        let unrelated = from_control(&app, request("other")).await;
        assert!(
            matches!(&unrelated[0].message, Message::Error { code, .. } if code == "SESSION_LAUNCH_ERROR")
        );
    }

    #[tokio::test]
    async fn instance_cannot_change_agent_identity() {
        let app = app();
        let (tx, _rx) = mpsc::channel(8);
        let mut snapshot = session();
        from_extension(
            &app,
            "owner",
            &tx,
            packet(Message::Register {
                session: snapshot.clone(),
            }),
        )
        .await;
        snapshot.agent_id = "another-agent".into();
        let result = from_extension(
            &app,
            "owner",
            &tx,
            packet(Message::Register {
                session: snapshot.clone(),
            }),
        )
        .await;
        assert!(
            matches!(&result[0].message, Message::Error { code, .. } if code == "IDENTITY_MISMATCH")
        );
        from_extension(
            &app,
            "owner",
            &tx,
            packet(Message::Heartbeat {
                session: snapshot,
                source_seq: 0,
            }),
        )
        .await;
        assert_eq!(app.inner.lock().await.sessions["i"].snapshot.agent_id, "pi");
    }

    #[tokio::test]
    async fn retired_instance_cannot_return_online() {
        let app = app();
        let (tx, _rx) = mpsc::channel(8);
        let s = session();
        assert!(from_extension(
            &app,
            "owner",
            &tx,
            packet(Message::Register { session: s.clone() })
        )
        .await
        .is_empty());
        from_extension(
            &app,
            "owner",
            &tx,
            packet(Message::Unregister {
                session_id: "s".into(),
                instance_id: "i".into(),
            }),
        )
        .await;
        from_extension(
            &app,
            "owner",
            &tx,
            packet(Message::Heartbeat {
                session: s.clone(),
                source_seq: 0,
            }),
        )
        .await;
        let reply = from_extension(
            &app,
            "new-owner",
            &tx,
            packet(Message::Register { session: s }),
        )
        .await;
        assert!(matches!(reply[0].message,Message::Error{ref code,..} if code=="STALE_INSTANCE"));
        assert_eq!(
            app.inner.lock().await.sessions["i"].snapshot.state,
            SessionState::Offline
        );
    }
    #[tokio::test]
    async fn duplicate_request_routes_once_and_result_owner_is_checked() {
        let app = app();
        let (tx, mut rx) = mpsc::channel(8);
        from_extension(
            &app,
            "owner",
            &tx,
            packet(Message::Register { session: session() }),
        )
        .await;
        let cmd = Envelope::new(
            "cmd",
            Message::Stop {
                generation_id: "g".into(),
                session_id: "s".into(),
                instance_id: "i".into(),
            },
        );
        assert!(from_control(&app, cmd.clone()).await.is_empty());
        assert_eq!(rx.recv().await.unwrap(), cmd);
        assert!(!from_control(&app, cmd).await.is_empty());
        assert!(rx.try_recv().is_err());
        let complete = Envelope::new(
            "cmd",
            Message::CommandResult {
                session_id: "s".into(),
                instance_id: "i".into(),
                status: CommandStatus::Completed,
                code: None,
                detail: None,
                data: None,
            },
        );
        from_extension(&app, "wrong-owner", &tx, complete.clone()).await;
        assert!(matches!(
            app.inner.lock().await.commands["cmd"].result.message,
            Message::Error { .. }
        ));
        from_extension(&app, "owner", &tx, complete).await;
        assert!(matches!(
            app.inner.lock().await.commands["cmd"].result.message,
            Message::CommandResult {
                status: CommandStatus::Completed,
                ..
            }
        ));
    }
    #[tokio::test]
    async fn invalid_generation_never_reaches_extension() {
        let app = app();
        let (tx, mut rx) = mpsc::channel(8);
        from_extension(
            &app,
            "owner",
            &tx,
            packet(Message::Register { session: session() }),
        )
        .await;
        let reply = from_control(
            &app,
            Envelope::new(
                "cmd",
                Message::Stop {
                    generation_id: "old".into(),
                    session_id: "s".into(),
                    instance_id: "i".into(),
                },
            ),
        )
        .await;
        assert!(matches!(
            reply[0].message,
            Message::CommandResult {
                status: CommandStatus::Rejected,
                ..
            }
        ));
        assert!(rx.try_recv().is_err());
    }
    #[tokio::test]
    async fn replay_reports_retention_and_source_gaps_before_completion() {
        let app = app();
        let (tx, _rx) = mpsc::channel(8);
        from_extension(
            &app,
            "owner",
            &tx,
            packet(Message::Register { session: session() }),
        )
        .await;
        from_extension(
            &app,
            "owner",
            &tx,
            packet(Message::Event {
                session_id: "s".into(),
                instance_id: "i".into(),
                seq: 0,
                source_seq: 3,
                event: EventData {
                    images: vec![],
                    kind: EventKind::UserMessage,
                    message_id: None,
                    content_index: None,
                    text: Some("hello".into()),
                    tool_call_id: None,
                    tool_name: None,
                    is_error: false,
                    truncated: false,
                },
            }),
        )
        .await;
        // Simulate the oldest event being evicted by the production buffer limit.
        {
            let mut r = app.inner.lock().await;
            let s = r.sessions.get_mut("i").unwrap();
            s.history.clear();
            s.bytes = 0;
        }
        let reply = from_control(
            &app,
            Envelope::new(
                "replay",
                Message::Replay {
                    session_id: "s".into(),
                    instance_id: "i".into(),
                    after_seq: 0,
                },
            ),
        )
        .await;
        assert_eq!(
            reply
                .iter()
                .filter(|e| matches!(e.message, Message::Gap { .. }))
                .count(),
            2
        );
        assert!(matches!(
            reply.last().unwrap().message,
            Message::ReplayEnd { last_seq: 1, .. }
        ));
        assert_eq!(reply.last().unwrap().request_id, "replay");
    }
}

#[cfg(test)]
#[path = "history_tests.rs"]
mod history_tests;
