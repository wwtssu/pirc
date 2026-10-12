use pirc_protocol::{Envelope, Message, SessionSnapshot, SessionState};
use std::{fs, path::PathBuf};
use ts_rs::TS;
fn main() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("generated");
    fs::create_dir_all(&root).unwrap();
    Envelope::export_all_to(&root).unwrap();
    for entry in fs::read_dir(&root).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_some_and(|extension| extension == "ts") {
            let source = fs::read_to_string(&path).unwrap();
            let normalized = source
                .lines()
                .map(str::trim_end)
                .collect::<Vec<_>>()
                .join("\n");
            fs::write(path, format!("{normalized}\n")).unwrap();
        }
    }
    let mut schema = serde_json::to_value(schemars::schema_for!(Envelope)).unwrap();
    fn constrain(value: &mut serde_json::Value) {
        match value {
            serde_json::Value::Object(fields) => {
                if fields.get("format").and_then(|v| v.as_str()) == Some("uint64") {
                    fields.insert(
                        "maximum".into(),
                        serde_json::json!(9_007_199_254_740_991u64),
                    );
                }
                for child in fields.values_mut() {
                    constrain(child);
                }
            }
            serde_json::Value::Array(items) => {
                for child in items {
                    constrain(child);
                }
            }
            _ => {}
        }
    }
    constrain(&mut schema);
    fs::write(
        root.join("envelope.schema.json"),
        serde_json::to_string_pretty(&schema).unwrap(),
    )
    .unwrap();
    for (name, message) in [
        ("list", Message::List {}),
        (
            "prompt",
            Message::Prompt {
                images: vec![],
                generation_id: "generation-1".into(),
                session_id: "session-1".into(),
                instance_id: "instance-1".into(),
                expected_revision: 3,
                text: "Continue 🦀".into(),
            },
        ),
        (
            "register",
            Message::Register {
                session: SessionSnapshot {
                    agent_id: "pi".into(),
                    capabilities: vec![],
                    ui_prompt: None,
                    session_id: "session-1".into(),
                    instance_id: "instance-1".into(),
                    cwd: "/tmp/Pi café".into(),
                    name: None,
                    state: SessionState::Idle,
                    revision: 0,
                    needs_local_attention: false,
                    slash_commands: None,
                    controls: None,
                    launch_id: None,
                    can_close: None,
                },
            },
        ),
    ] {
        let fixture = Envelope::new(format!("fixture-{name}"), message);
        fs::write(
            root.parent().unwrap().join(format!("fixtures/{name}.json")),
            serde_json::to_string_pretty(&fixture).unwrap(),
        )
        .unwrap();
    }
    println!("Generated protocol types, schema and fixtures.");
}
