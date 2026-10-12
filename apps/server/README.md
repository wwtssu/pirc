# PiRC Server

A Rust server running on the device, providing session registration, event forwarding, history queries, directory operations, and agent terminal launching.

## Startup and pairing

Build the CLI from the repository root:

```sh
cargo build --release -p pirc-server
./target/release/pirc server
```

After installing `target/release/pirc` on PATH, run:

```sh
pirc server
pirc waitlist
pirc allow XXXX-XXXX
```

`server` runs in the foreground; press Ctrl+C to stop it. Run `waitlist` and `allow` in another terminal under the same system user as the server. Verify the pairing code shown in the app before approving the first connection. See [Encryption and authorization](../../docs/ENCRYPTION.md).

To use a different port, run `pirc server --port <port>`.

The server listens on `0.0.0.0`. The client uses the device address; the extension uses a local loopback WebSocket address. The Pi adapter finds Node and Pi on PATH. The server selects the system terminal automatically, and stores its device identity, encryption key, and client approvals in `~/.pirc`.

## Endpoints and connections

| Endpoint | Purpose |
| --- | --- |
| `/pirc/info` | Service discovery |
| `/control` | Client controls and event subscriptions |
| `/extension` | Local adapter registration |
| `/health` | Readiness probe |

Each server accepts one client control connection at a time. It sends a WebSocket Ping every 5 seconds and releases the connection after approximately 20 seconds without a response. Sends have a 5-second deadline. Unencrypted control and extension endpoints are accessible only over loopback.

Local diagnostics support `npm run control -- list`, `watch`, `stop <instanceId>`, and `prompt <instanceId> <text>`. A diagnostic connection also occupies the client connection slot.

## Terminals and directories

macOS uses Terminal; graphical Linux uses `x-terminal-emulator`. Linux uses tmux when both `DISPLAY` and `WAYLAND_DISPLAY` are empty, with a socket named `pirc`.

```sh
tmux -L pirc list-sessions
tmux -L pirc attach-session -t <session-name>
```

Press Ctrl+B, then D to detach from tmux. The agent continues running on the device when the client returns to the session list or loses its connection. Sessions created or restored by the server can be exited through session management; the adapter checks the execution state.

Remote directory operations run in a separate Node process with a 5-second deadline. System permissions must be granted on the device. Creating a directory never overwrites an existing file or directory with the same name.

For systemd deployments, set `KillMode=process` in the server unit to keep headless agent sessions running when the server is restarted.

## File attachments

Authorized clients can upload files of up to 20 MiB in bounded chunks. Uploads require a current server generation and an online session. Files are stored under `~/.pirc/attachments` with separate directories for each session instance and upload. Filenames cannot contain path separators; existing uploads are never overwritten.

See [Agent adapters](../../docs/ADAPTERS.md) for the shared protocol and adapter boundary.
