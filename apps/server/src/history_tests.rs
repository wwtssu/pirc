use super::*;
async fn fixture() -> (App, Sender) {
    let (events, _) = broadcast::channel(1024);
    let app = App {
        inner: Arc::new(Mutex::new(Registry::default())),
        events,
        server_id: "test-server".into(),
        crypto_key: Arc::new(pirc_crypto::generate_key().unwrap()),
        generation: "g".into(),
        launcher: Arc::new(launcher::Launcher::new(43123)),
        approval: Arc::new(
            approval::Approval::open(
                std::env::temp_dir().join(format!("pirc-history-access-{}", Uuid::new_v4())),
            )
            .unwrap(),
        ),
        handshakes: Arc::new(tokio::sync::Semaphore::new(64)),
    };
    let (tx, _) = mpsc::channel(8);
    let session = SessionSnapshot {
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
    };
    from_extension(&app, "owner", &tx, packet(Message::Register { session })).await;
    (app, tx)
}
async fn event(app: &App, tx: &Sender, seq: u64, kind: EventKind, text: &str, index: Option<u32>) {
    from_extension(
        app,
        "owner",
        tx,
        packet(Message::Event {
            session_id: "s".into(),
            instance_id: "i".into(),
            source_seq: seq,
            seq: 0,
            event: EventData {
                kind: kind.clone(),
                message_id: Some("m".into()),
                content_index: index,
                text: Some(text.into()),
                tool_call_id: if matches!(
                    kind,
                    EventKind::ToolCallStart
                        | EventKind::ToolCallDelta
                        | EventKind::ToolCallEnd
                        | EventKind::ToolStart
                        | EventKind::ToolUpdate
                        | EventKind::ToolEnd
                ) {
                    Some("call".into())
                } else {
                    None
                },
                tool_name: Some("bash".into()),
                is_error: false,
                truncated: false,
            },
        }),
    )
    .await;
}
async fn page(app: &App, direction: HistoryDirection, cursor: Option<u64>, limit: u32) -> Message {
    from_control(
        app,
        Envelope::new(
            "history",
            Message::History {
                session_id: "s".into(),
                instance_id: "i".into(),
                direction,
                cursor,
                limit,
            },
        ),
    )
    .await
    .pop()
    .unwrap()
    .message
}
fn seqs(page: Message) -> (Vec<u64>, bool, bool) {
    match page {
        Message::HistoryPage {
            items,
            has_before,
            has_after,
            ..
        } => (
            items.iter().map(|i| i.first_seq).collect(),
            has_before,
            has_after,
        ),
        _ => panic!("not a page"),
    }
}
#[tokio::test]
async fn latest_before_after_and_around_use_stable_exclusive_cursors() {
    let (app, tx) = fixture().await;
    for seq in 1..=10 {
        event(&app, &tx, seq, EventKind::UserMessage, "message", None).await;
    }
    assert_eq!(
        seqs(page(&app, HistoryDirection::Latest, None, 3).await),
        (vec![8, 9, 10], true, false)
    );
    assert_eq!(
        seqs(page(&app, HistoryDirection::Before, Some(8), 3).await),
        (vec![5, 6, 7], true, true)
    );
    assert_eq!(
        seqs(page(&app, HistoryDirection::Around, Some(5), 4).await),
        (vec![3, 4, 5, 6], true, true)
    );
    assert_eq!(
        seqs(page(&app, HistoryDirection::After, Some(6), 4).await),
        (vec![7, 8, 9, 10], true, false)
    );
    assert_eq!(
        seqs(page(&app, HistoryDirection::Before, Some(1), 4).await),
        (vec![], false, true)
    );
    assert!(
        matches!(page(&app,HistoryDirection::Around,Some(90),4).await,Message::Error{code,..} if code=="HISTORY_NOT_FOUND")
    );
    assert!(
        matches!(page(&app,HistoryDirection::Latest,None,0).await,Message::Error{code,..} if code=="INVALID_HISTORY")
    );
}
#[tokio::test]
async fn pages_keep_entire_thinking_tool_arguments_and_results_after_event_retention() {
    let (app, tx) = fixture().await;
    event(&app, &tx, 1, EventKind::ThinkingStart, "", Some(0)).await;
    event(&app, &tx, 2, EventKind::ThinkingDelta, "first ", Some(0)).await;
    event(&app, &tx, 3, EventKind::ThinkingDelta, "second", Some(0)).await;
    event(&app, &tx, 4, EventKind::ToolCallStart, "", Some(1)).await;
    event(&app, &tx, 5, EventKind::ToolCallDelta, "partial", Some(1)).await;
    event(
        &app,
        &tx,
        6,
        EventKind::ToolCallEnd,
        "{\"command\":\"pwd\"}",
        Some(1),
    )
    .await;
    event(&app, &tx, 7, EventKind::ToolStart, "", None).await;
    event(&app, &tx, 8, EventKind::ToolEnd, "/tmp", None).await;
    app.inner
        .lock()
        .await
        .sessions
        .get_mut("i")
        .unwrap()
        .history
        .clear();
    let Message::HistoryPage {
        items, last_seq, ..
    } = page(&app, HistoryDirection::Latest, None, 2).await
    else {
        panic!()
    };
    assert_eq!(last_seq, 8);
    assert_eq!(items.len(), 2);
    assert_eq!(items[0].text, "first second");
    assert!(items[0].complete);
    assert_eq!(items[1].arguments.as_deref(), Some("{\"command\":\"pwd\"}"));
    assert_eq!(items[1].text, "/tmp");
    assert!(items[1].complete);
    assert_eq!(items[1].first_seq, 4);
    assert_eq!(items[1].last_seq, 8);
}
#[tokio::test]
async fn large_pages_fit_frame_limit_and_keep_around_target() {
    let (app, tx) = fixture().await;
    for seq in 1..=20 {
        event(
            &app,
            &tx,
            seq,
            EventKind::UserMessage,
            &"€".repeat(21845),
            None,
        )
        .await;
    }
    for (direction, cursor) in [
        (HistoryDirection::Latest, None),
        (HistoryDirection::Before, Some(20)),
        (HistoryDirection::After, Some(1)),
        (HistoryDirection::Around, Some(10)),
    ] {
        let page = page(&app, direction.clone(), cursor, 20).await;
        assert!(
            serde_json::to_vec(&Envelope::new("h", page.clone()))
                .unwrap()
                .len()
                < 1024 * 1024
        );
        let Message::HistoryPage { items, .. } = page else {
            panic!()
        };
        assert!(items.len() < 20);
        if direction == HistoryDirection::Around {
            assert!(items.iter().any(|i| i.first_seq == 10));
        }
    }
}
