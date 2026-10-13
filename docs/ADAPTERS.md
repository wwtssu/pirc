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

`ui_prompt.ask` carries a pending question request with a unique ID. The client
replies with `AnswerAsk`, targeting the current generation, instance, and prompt.
Adapters validate question IDs and selections; completed or cancelled requests
reject late answers. A question can remain answerable in the device terminal.

Tool events can include `todo` phases with task status and blocker metadata.
For adapters advertising `todo`, materialized history coalesces operations into
one stable `todo:<instance_id>` block. Its first sequence and position remain
fixed; later operations replace its structured state and textual result. The
client renders phases and tasks in a persistent, read-only panel above the
composer. History pages include `current_todo` independently of the requested
range; live task updates continue while older messages are visible.

Pi and OMP adapters are implemented. See [OMP adapter](../extensions/omp/README.md) for its API mapping and validation. Additional adapters must preserve
the shared identity, acknowledgement, replay, and history semantics.

Model catalogs may include `roles`: native role IDs, model-kind categories,
configured selectors, resolved models, and configuration sources. The `model`
control accepts structured `role_models`, `set_role`, and `clear_role` operations
for these adapters. Candidate filtering and persistence belong to the adapter;
clients must not infer a model role from its display name. Adapters without roles
continue to provide a flat catalog.
