# Encrypted connections and first-time pairing

The app and server use the `pirc.noise.v1` WebSocket subprotocol, based on the standard `Noise_XX_25519_ChaChaPoly_SHA256` protocol implemented by the Rust `snow` crate. The first handshake exchanges public keys. Each connection generates fresh ephemeral keys and establishes a bidirectional encrypted channel. See the [Noise specification](https://noiseprotocol.org/noise.html).

The server approves the first connection. The app displays `pirc allow XXXX-XXXX`, which the user runs on the device hosting the server. The app has no "Trust and connect" confirmation button. The pairing code uses uppercase letters and digits, is derived from the completed Noise handshake hash, and is verified independently by both peers. It binds the client public key, server public key, and current ephemeral handshake. A mismatch stops the connection; a code from another connection cannot be substituted. This uses Noise [channel binding](https://noiseprotocol.org/noise.html#channel-binding).

Before approval, a new client receives no sessions, history, or directories, and cannot perform operations. Pairing codes expire after 5 minutes, are bound to the waiting connection, and are single-use. Disconnecting invalidates them immediately. Up to 32 pending requests are retained, with only one per client identity. Connections that have not completed the handshake or pairing are also limited. The approval command connects only to the local Unix socket owned by the same user; it cannot be invoked through the public network endpoint.

After approval, the server persists the client's long-term public key in `~/.pirc/access/clients.json` with mode 0600 and a parent directory mode of 0700. The app automatically completes encrypted authentication and saves the server public key. Subsequent connections verify the remembered identities without further approval. Changing the client key requires approval again; changing the server key still stops the connection. The Unix socket resides in a private `/tmp/pirc-admin-*` directory determined by a hash of the state path, with directory mode 0700 and socket mode 0600, avoiding macOS socket path length limits.

Build and install the CLI:

```sh
cargo build --release -p pirc-server
mkdir -p ~/.local/bin
cp target/release/pirc ~/.local/bin/pirc
# Start the server in the foreground:
pirc server
# After the app displays a pairing code, run these commands on the server device
# in another terminal:
pirc waitlist
pirc allow XXXX-XXXX
```

`pirc waitlist` lists pending pairing codes and their remaining validity, ordered by request time. Approved, expired, and disconnected requests are omitted. Listing requests does not approve them. The list is read only through the private local authorization interface; there is no remote query endpoint. Verify the pairing code in the app before approval.

`~/.local/bin` must be on the terminal's PATH. The server and approval command must run under the same user. Authorization is rejected if saving approval fails, the authorization file is corrupt, or its permissions are too broad. The server never falls back to allowing all clients.

The server's long-term private key is stored in `~/.pirc/server-key` with mode `0600`. A corrupt file or overly broad permissions prevent startup; the server does not silently replace its identity. In production builds, the app's long-term private key and confirmed device public keys reside in the system secure store, separate from ordinary connection configuration. Development builds can use `PIRC_SECRET_STORE=file` and optionally `PIRC_SECRET_FILE` to select an isolated debug file and bypass the keychain. Debug builds enable file storage by default; production Release builds still default to the system secure store. To replace a server key, explicitly re-pair in connection settings and approve the new pairing on the server.

HTTP service discovery returns only the protocol version, device ID, and encryption protocol version, without private keys or session data. HTTP Upgrade carries no authentication header. Authentication, sessions, prompts, Stop requests, history, directory reads, and command results are sent through the encrypted channel. Tampered, replayed, reordered, or truncated frames, or unencrypted application frames, stop the connection. The app never falls back to unencrypted communication. Large messages are fragmented using increasing nonces on the same Noise channel. The complete message length is included in authenticated ciphertext; the message limit is 1 MiB.

The local extension and diagnostic CLI continue to use loopback endpoints. The server rejects non-loopback access to unencrypted control and extension endpoints. Reverse proxies or tunnels must forward only `/control` connections using `pirc.noise.v1`. They must not proxy `/extension` or unencrypted control requests, or expose the local diagnostic channel. The app always requires encryption, even with an `http://` address. This encryption layer does not hide HTTP addresses, public service discovery data, traffic sizes, or timing. HTTPS endpoints remain supported.

The encrypted channel verifies the server-approved client public key. The extension and local diagnostic channels remain loopback-only and must not be forwarded by reverse proxies.

Validation commands: `cargo test --workspace`, `flutter test`, and `npm run test:flutter:encrypted`. The last command starts two isolated real servers and simulated local adapters to test server approval, encrypted connections, device switching, and independent message routing in the native macOS client. It does not operate the user's agent processes.
