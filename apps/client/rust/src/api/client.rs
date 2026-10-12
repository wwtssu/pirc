use crate::frb_generated::StreamSink;
use pirc_core::client::Client;

#[flutter_rust_bridge::frb(opaque)]
pub struct PircClient {
    inner: Client,
}

pub fn create_client(url: String) -> Result<PircClient, String> {
    Ok(PircClient {
        inner: Client::new(url)?,
    })
}
pub fn create_computer_client(
    addresses: Vec<String>,
    server_id: Option<String>,
    other_server_ids: Vec<String>,
    secret: String,
    server_key: Option<String>,
) -> Result<PircClient, String> {
    Ok(PircClient {
        inner: Client::with_security(addresses, server_id, other_server_ids, secret, server_key)?,
    })
}
pub async fn watch_client(client: &PircClient, sink: StreamSink<String>) {
    let mut changes = client.inner.subscribe();
    loop {
        if sink
            .add(serde_json::to_string(&client.inner.view()).unwrap())
            .is_err()
        {
            break;
        }
        if changes.changed().await.is_err() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
}
pub async fn send_prompt(
    client: &PircClient,
    instance_id: String,
    text: String,
) -> Result<String, String> {
    client.inner.send(instance_id, Some(text)).await
}
pub async fn saved_sessions(client: &PircClient) -> Result<String, String> {
    serde_json::to_string(&client.inner.saved_sessions().await?).map_err(|e| e.to_string())
}
pub async fn browse_directories(
    client: &PircClient,
    path: Option<String>,
    cursor: Option<String>,
    show_hidden: bool,
) -> Result<String, String> {
    serde_json::to_string(
        &client
            .inner
            .browse_directories(path, cursor, show_hidden)
            .await?,
    )
    .map_err(|e| e.to_string())
}
pub async fn launch_session(
    client: &PircClient,
    cwd: String,
    session_id: Option<String>,
    name: Option<String>,
    create_cwd: bool,
) -> Result<String, String> {
    serde_json::to_string(
        &client
            .inner
            .launch_session(cwd, session_id, name, create_cwd)
            .await?,
    )
    .map_err(|e| e.to_string())
}
pub async fn read_image(
    client: &PircClient,
    instance_id: String,
    image_id: String,
    offset: u32,
) -> Result<String, String> {
    serde_json::to_string(
        &client
            .inner
            .read_image(instance_id, image_id, offset)
            .await?,
    )
    .map_err(|e| e.to_string())
}
pub async fn create_directory(
    client: &PircClient,
    parent: String,
    name: String,
) -> Result<String, String> {
    serde_json::to_string(&client.inner.create_directory(parent, name).await?)
        .map_err(|e| e.to_string())
}
pub async fn stop_session(client: &PircClient, instance_id: String) -> Result<String, String> {
    client.inner.send(instance_id, None).await
}
pub async fn close_session(client: &PircClient, instance_id: String) -> Result<String, String> {
    client.inner.close_session(instance_id).await
}
pub fn set_computer_addresses(client: &PircClient, addresses: Vec<String>) -> Result<(), String> {
    client.inner.set_addresses(addresses)
}
pub fn reconnect_client(client: &PircClient) {
    client.inner.reconnect();
}
pub fn close_client(client: &PircClient) {
    client.inner.close();
}
pub fn confirm_unknown(client: &PircClient, request_id: String) {
    client.inner.confirm(request_id);
}
pub fn select_session_view(client: &PircClient, instance_id: String) {
    client.inner.select(instance_id);
}

pub async fn load_history(
    client: &PircClient,
    instance_id: String,
    direction: String,
    cursor: Option<u64>,
) -> Result<(), String> {
    let direction = match direction.as_str() {
        "latest" => pirc_protocol::HistoryDirection::Latest,
        "before" => pirc_protocol::HistoryDirection::Before,
        "after" => pirc_protocol::HistoryDirection::After,
        "around" => pirc_protocol::HistoryDirection::Around,
        _ => return Err("Unknown history direction".into()),
    };
    client.inner.history(instance_id, direction, cursor).await
}

pub fn generate_crypto_key() -> Result<String, String> {
    pirc_core::generate_crypto_key()
}
