# Agent adapters

PiRC uses a shared session protocol and agent-specific adapters. The server does
not own the agent runtime: it opens a terminal, and the agent's session adapter
registers with the local server.

## Identity

`SessionSnapshot`, `SavedSession`, and `LaunchSession` carry an `agent_id`.
A saved session is identified by `(agent_id, session_id)`. Online control and
history requests additionally target a unique `instance_id`; generation and
revision checks continue to protect against stale requests. An instance cannot
change its agent identity after registration.

`SavedSessionList` includes the server's supported agents. The client chooses an
agent when creating a session and uses the saved session's agent when restoring
one. Drafts are isolated by device, agent, and session.

## Server boundary

`apps/server/src/agents` contains the built-in adapter registry and the
`AgentAdapter` contract. Each implementation supplies agent metadata, saved
session discovery, executable arguments, and environment keys inherited from
the server. The Pi implementation uses `extensions/pi/sessions.mjs` to read Pi
history and `extensions/pi/index.ts` for live registration and control.

The common launcher handles working directories, terminal selection, headless
terminals, request deduplication, and registration tracking. Agent-specific
paths, session formats, and command-line flags belong in the adapter.

## Session capabilities

The live adapter translates its agent's events into shared transcript blocks:
user and assistant text, reasoning, tools, and images. Stable content IDs and
sequence numbers remain part of the shared protocol.

`slash_commands` advertises supported normalized controls. `model`, `thinking`,
`name`, `session`, and `compact` describe PiRC operations; an adapter maps them
to its agent's API. Model catalogs and reasoning options come from the adapter.
The client hides controls that the adapter does not advertise.

`capabilities` advertises additional features such as `image_prompt`,
`image_read`, and `local_ui_state`. The client exposes image selection only when
`image_prompt` is present. Unsupported agent-specific widgets require a textual
representation until a shared content type is introduced.

Only the Pi adapter is currently implemented. Additional adapters must preserve
the shared identity, acknowledgement, replay, and history semantics.
