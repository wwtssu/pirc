# OMP session adapter

An adapter for Oh My Pi (OMP), tested with version 18.10.2. It uses OMP's
Extension API inside the existing terminal runtime and shares PiRC's transport,
event replay, image catalog, request deduplication, and history projection.

## Loading

From the repository root:

```sh
npm ci
extension_path="$PWD/extensions/omp/index.ts"
cd /path/to/project
omp --extension "$extension_path"
```

The server detects `omp` on PATH and offers it when creating sessions. It starts
OMP in the device terminal and restores saved sessions with `--resume`.
Connection configuration follows the same loopback settings as the Pi adapter.

## Existing client features

- Session creation, naming, restoration, and managed terminal exit.
- Text, thinking, tool-call arguments, and cumulative tool-result streaming.
- Stop confirmation and subsequent prompts in the same session.
- Model selection through OMP's native model resolver, including role aliases
  that resolve to the selected primary model. Separate role configuration is not
  exposed by the client.
- Thinking levels taken from the current model's declared effort metadata.
- `/name`, `/session`, and `/compact`, including asynchronous naming and
  confirmed compaction results or errors.
- Image prompts, tool-result images, historical image retrieval, and uploaded
  file paths included with the prompt.
- History pagination, reconnect, and reconstruction after server restarts.

OMP's native Todo results use the existing tool blocks. Tool approvals and Ask
prompts report that local attention is required; they remain interactive in the
terminal. Other custom TUI components retain their textual output. The adapter
registers only the main session, preventing task subagents from appearing as
independent remotely controlled sessions.

The five normalized controls execute through the public Extension API. Other
slash commands require the device terminal: OMP's public `sendUserMessage`
method deliberately skips command and template expansion.

History discovery reads the title slot and session header from OMP JSONL files
without starting OMP. It follows the server's active profile, agent directory,
and migrated XDG data location. Only metadata is read, with a bounded prefix per
file; session bodies are loaded by the running agent after restoration.

## Validation

```sh
npm run typecheck
npm run test:protocol
npm run test:omp:e2e
npm run test:flutter:omp
```

The end-to-end fixture uses an isolated server, OMP profile, terminal socket,
and deterministic provider. It does not use configured model credentials.
