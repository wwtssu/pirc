use pirc_protocol::SessionState;

#[flutter_rust_bridge::frb(sync)]
pub fn protocol_version() -> u32 {
    pirc_core::protocol_version()
}

pub enum ExecutionState {
    Idle,
    Running,
    Stopping,
    Offline,
}

pub fn encode_prompt(
    request_id: String,
    generation_id: String,
    session_id: String,
    instance_id: String,
    expected_revision: u32,
    text: String,
    state: ExecutionState,
) -> Result<String, String> {
    let state = match state {
        ExecutionState::Idle => SessionState::Idle,
        ExecutionState::Running => SessionState::Running,
        ExecutionState::Stopping => SessionState::Stopping,
        ExecutionState::Offline => SessionState::Offline,
    };
    pirc_core::encode_prompt(
        request_id,
        generation_id,
        session_id,
        instance_id,
        expected_revision.into(),
        text,
        state,
    )
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
