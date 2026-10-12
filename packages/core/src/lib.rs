use pirc_protocol::{Envelope, Message, SessionState, PROTOCOL_VERSION};

pub mod client;
pub mod projection;
mod transport;

pub fn protocol_version() -> u32 {
    PROTOCOL_VERSION
}

pub fn can_send_prompt(state: &SessionState) -> bool {
    matches!(state, SessionState::Idle)
}

pub fn encode_prompt(
    request_id: String,
    generation_id: String,
    session_id: String,
    instance_id: String,
    expected_revision: u64,
    text: String,
    state: SessionState,
) -> Result<String, String> {
    if !can_send_prompt(&state) {
        return Err("Prompt requires confirmed IDLE state".into());
    }
    if [
        request_id.as_str(),
        generation_id.as_str(),
        session_id.as_str(),
        instance_id.as_str(),
        text.as_str(),
    ]
    .iter()
    .any(|value| value.trim().is_empty())
    {
        return Err("Request, generation, session, instance and prompt must be non-empty".into());
    }
    serde_json::to_string(&Envelope {
        version: PROTOCOL_VERSION,
        request_id,
        message: Message::Prompt {
            generation_id,
            expected_revision,
            session_id,
            instance_id,
            text,
        },
    })
    .map_err(|e| e.to_string())
}

pub fn generate_crypto_key() -> Result<String, String> {
    pirc_crypto::generate_key()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prompt_requires_confirmed_idle() {
        for state in [
            SessionState::Running,
            SessionState::Stopping,
            SessionState::Offline,
        ] {
            assert!(encode_prompt(
                "r".into(),
                "g".into(),
                "s".into(),
                "i".into(),
                3,
                "hello".into(),
                state
            )
            .is_err());
        }
        assert!(encode_prompt(
            "r".into(),
            "g".into(),
            "s".into(),
            "i".into(),
            3,
            "hello".into(),
            SessionState::Idle
        )
        .is_ok());
    }
}
