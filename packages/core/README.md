# pirc-core

A platform-independent Rust client core depending on `pirc-protocol` and `pirc-crypto`. Flutter accesses this package through `apps/client/rust`.

## Modules

| Module | Contents |
| --- | --- |
| `client` | Connection lifecycle, requests, and event handling |
| `transport` | Service discovery, WebSocket, and encrypted transport |
| `projection` | Session state, streaming content, and history projection |

Supports address fallback, device identity verification, event deduplication, command result tracking, and paginated history. Commands carry the server generation, session identity, and observed revision. The device adapter performs the final execution state validation.

## Tests

```sh
cargo test -p pirc-core
```
