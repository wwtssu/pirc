# pirc-protocol

Shared PiRC message models, providing Rust types, TypeScript types, and JSON Schema.

## Generation

Run from the repository root:

```sh
npm run protocol:generate
```

- `src/lib.rs`: Rust message definitions.
- `generated/*.ts`: Generated TypeScript types.
- `generated/envelope.schema.json`: JSON Schema.
- `fixtures/*.json`: Cross-language validation fixtures.

## Message format

Messages use a versioned JSON envelope:

```json
{"version":1,"request_id":"req-1","message":{"type":"stop","generation_id":"current-server-generation","session_id":"session-1","instance_id":"instance-1"}}
```

Messages cover authentication, session registration and state, streaming events, event replay, control commands, history pagination, and remote directory operations. Session states are `idle`, `running`, `stopping`, and `offline`.

Online and saved sessions carry an `agent_id`. Creation and restoration select an agent explicitly; saved-session identity is `(agent_id, session_id)`. The saved-session catalog also lists supported agents.

Control requests identify and validate their target using the server generation, session ID, instance ID, and state revision. Request IDs support deduplication and result queries. Events carry the server `seq` and adapter `source_seq`.

`History` supports `latest`, `before`, `after`, and `around`, using a content block's `first_seq` as the anchor. Pages include the retained range, previous/next page flags, and an event watermark. `TranscriptItem` provides stable block IDs and accumulated content.

The frame limit is 1 MiB; request IDs are limited to 128 UTF-8 bytes. Integers must be within the JavaScript safe integer range. Rust and TypeScript validation reject unsupported versions, extra fields, and invalid data.

## Tests

```sh
cargo test -p pirc-protocol
npm run test:protocol
```
