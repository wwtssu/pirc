use super::*;
fn snapshot() -> SessionSnapshot {
    SessionSnapshot {
        agent_id: "pi".into(),
        capabilities: vec![],
        ui_prompt: None,
        session_id: "s".into(),
        instance_id: "i".into(),
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
fn item(seq: u64, text: &str) -> Item {
    Item {
        images: vec![],
        id: format!("user:{seq}"),
        role: "user".into(),
        text: text.into(),
        first_seq: seq,
        last_seq: seq,
        title: None,
        arguments: None,
        phase: None,
        complete: true,
        is_error: false,
        truncated: false,
        message_id: None,
        content_index: None,
        tool_call_id: None,
    }
}
fn start() -> Projection {
    let mut p = Projection::default();
    p.receive(packet(Message::Welcome {
        server_id: None,
        generation_id: "g".into(),
        history_paging: true,
    }));
    assert!(p
        .receive(packet(Message::Sessions {
            sessions: vec![snapshot()]
        }))
        .is_empty());
    p
}
fn page(
    p: &mut Projection,
    id: &str,
    items: Vec<Item>,
    before: bool,
    after: bool,
    seq: u64,
) -> Vec<Envelope> {
    p.receive(Envelope::new(
        id,
        Message::HistoryPage {
            session_id: "s".into(),
            instance_id: "i".into(),
            items,
            has_before: before,
            has_after: after,
            last_seq: seq,
            source_seq: seq,
            history_truncated: false,
        },
    ))
}
fn event(p: &mut Projection, seq: u64, text: &str) -> Vec<Envelope> {
    p.receive(packet(Message::Event {
        session_id: "s".into(),
        instance_id: "i".into(),
        seq,
        source_seq: seq,
        event: EventData {
            images: vec![],
            kind: EventKind::UserMessage,
            message_id: None,
            content_index: None,
            text: Some(text.into()),
            tool_call_id: None,
            tool_name: None,
            is_error: false,
            truncated: false,
        },
    }))
}
#[test]
fn initial_page_buffers_live_events_and_deduplicates_watermark() {
    let mut p = start();
    let query = p.select("i".into()).remove(0);
    event(&mut p, 100, "covered by page");
    event(&mut p, 101, "arrived during page");
    assert!(page(
        &mut p,
        &query.request_id,
        vec![item(99, "older"), item(100, "latest")],
        true,
        false,
        100
    )
    .is_empty());
    let s = &p.view.sessions[0];
    assert!(s.ready);
    assert_eq!(
        s.items.iter().map(|i| i.first_seq).collect::<Vec<_>>(),
        vec![99, 100, 101]
    );
    assert_eq!(s.last_seq, 101);
    assert!(s.gaps.is_empty());
    event(&mut p, 101, "duplicate");
    assert_eq!(p.view.sessions[0].items.len(), 3);
}
#[test]
fn old_pages_merge_once_and_latest_supersedes_stale_requests() {
    let mut p = start();
    let latest = p.select("i".into()).remove(0);
    page(
        &mut p,
        &latest.request_id,
        vec![item(8, "eight"), item(9, "nine")],
        true,
        false,
        9,
    );
    let before = p.history("i", HistoryDirection::Before, Some(8)).unwrap();
    let replacement = p.history("i", HistoryDirection::Latest, None).unwrap();
    page(
        &mut p,
        &before.request_id,
        vec![item(1, "stale")],
        false,
        true,
        9,
    );
    assert_eq!(p.view.sessions[0].items.len(), 2);
    page(
        &mut p,
        &replacement.request_id,
        vec![item(9, "nine")],
        true,
        false,
        9,
    );
    let before = p.history("i", HistoryDirection::Before, Some(9)).unwrap();
    page(
        &mut p,
        &before.request_id,
        vec![item(8, "eight"), item(9, "overlap")],
        true,
        true,
        9,
    );
    assert_eq!(p.view.sessions[0].items.len(), 2);
    assert!(!p.view.sessions[0].history.has_after);
    assert_eq!(p.view.sessions[0].history.revision, 2);
}
#[test]
fn historical_window_keeps_new_events_out_until_latest_is_requested() {
    let mut p = start();
    let latest = p.select("i".into()).remove(0);
    page(
        &mut p,
        &latest.request_id,
        vec![item(10, "ten")],
        true,
        false,
        10,
    );
    let around = p.history("i", HistoryDirection::Around, Some(4)).unwrap();
    page(
        &mut p,
        &around.request_id,
        vec![item(3, "three"), item(4, "four"), item(5, "five")],
        true,
        true,
        10,
    );
    event(&mut p, 11, "new outside window");
    assert_eq!(p.view.sessions[0].items.len(), 3);
    assert_eq!(p.view.sessions[0].history.anchor, Some(4));
    let after = p.history("i", HistoryDirection::After, Some(5)).unwrap();
    page(
        &mut p,
        &after.request_id,
        (6..=11).map(|n| item(n, "next")).collect(),
        true,
        false,
        11,
    );
    event(&mut p, 12, "new in live window");
    assert_eq!(p.view.sessions[0].items.last().unwrap().first_seq, 12);
    let latest = p.history("i", HistoryDirection::Latest, None).unwrap();
    page(
        &mut p,
        &latest.request_id,
        vec![item(12, "twelve")],
        true,
        false,
        12,
    );
    assert_eq!(p.view.sessions[0].items.len(), 1);
    assert_eq!(p.view.sessions[0].history.anchor, None);
}
#[test]
fn timeout_and_disconnect_allow_retry_without_destroying_existing_history() {
    let mut p = start();
    let latest = p.select("i".into()).remove(0);
    page(
        &mut p,
        &latest.request_id,
        vec![item(10, "ten")],
        true,
        false,
        10,
    );
    let request = p.history("i", HistoryDirection::Before, Some(10)).unwrap();
    p.history_requests
        .get_mut(&request.request_id)
        .unwrap()
        .started = std::time::Instant::now() - std::time::Duration::from_secs(11);
    assert!(p.expire_history());
    assert!(p.view.sessions[0].history.loading.is_none());
    assert!(p.view.sessions[0].history.error.is_some());
    assert_eq!(p.view.sessions[0].items.len(), 1);
    let retry = p.history("i", HistoryDirection::Before, Some(10)).unwrap();
    p.disconnected(None);
    assert!(p.view.sessions[0].history.loading.is_none());
    assert!(p.history_requests.is_empty());
    page(
        &mut p,
        &retry.request_id,
        vec![item(1, "late page")],
        false,
        true,
        10,
    );
    assert_eq!(p.view.sessions[0].items[0].first_seq, 10);
}

#[test]
fn page_versions_do_not_duplicate_live_deltas_still_queued_on_socket() {
    let mut p = start();
    let latest = p.select("i".into()).remove(0);
    let mut block = item(1, "A");
    block.id = "assistant:m:0".into();
    block.role = "assistant".into();
    block.message_id = Some("m".into());
    block.content_index = Some(0);
    block.complete = false;
    page(
        &mut p,
        &latest.request_id,
        vec![block.clone()],
        true,
        false,
        1,
    );
    let older = p.history("i", HistoryDirection::Before, Some(1)).unwrap();
    block.text = "ABC".into();
    block.last_seq = 3;
    page(&mut p, &older.request_id, vec![block], false, false, 3);
    for (seq, text) in [(2, "B"), (3, "C"), (4, "D")] {
        p.receive(packet(Message::Event {
            session_id: "s".into(),
            instance_id: "i".into(),
            seq,
            source_seq: seq,
            event: EventData {
                images: vec![],
                kind: EventKind::MessageDelta,
                message_id: Some("m".into()),
                content_index: Some(0),
                text: Some(text.into()),
                tool_call_id: None,
                tool_name: None,
                is_error: false,
                truncated: false,
            },
        }));
    }
    assert_eq!(p.view.sessions[0].items[0].text, "ABCD");
    assert_eq!(p.view.sessions[0].last_seq, 4);
}

#[test]
fn reconnect_replays_incrementally_without_replacing_the_historical_window() {
    let mut p = start();
    let latest = p.select("i".into()).remove(0);
    page(
        &mut p,
        &latest.request_id,
        vec![item(10, "ten")],
        true,
        false,
        10,
    );
    let around = p.history("i", HistoryDirection::Around, Some(4)).unwrap();
    page(
        &mut p,
        &around.request_id,
        vec![item(4, "historical")],
        true,
        true,
        10,
    );
    let revision = p.view.sessions[0].history.revision;
    p.disconnected(None);
    p.receive(packet(Message::Welcome {
        server_id: None,
        generation_id: "g".into(),
        history_paging: true,
    }));
    let outgoing = p.receive(packet(Message::Sessions {
        sessions: vec![snapshot()],
    }));
    assert!(matches!(
        outgoing[0].message,
        Message::Replay { after_seq: 10, .. }
    ));
    p.receive(Envelope::new(
        &outgoing[0].request_id,
        Message::ReplayEnd {
            session_id: "s".into(),
            instance_id: "i".into(),
            last_seq: 10,
        },
    ));
    assert!(p.view.sessions[0].ready);
    assert_eq!(p.view.sessions[0].items[0].first_seq, 4);
    assert_eq!(p.view.sessions[0].history.anchor, Some(4));
    assert_eq!(p.view.sessions[0].history.revision, revision);
}
