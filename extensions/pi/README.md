# Pi session adapter

A TypeScript adapter built on the Pi Extension API. It registers sessions with the local PiRC server, forwards streaming events, and handles remote control requests.

## Loading

Install dependencies and set the adapter path from the repository root:

```sh
npm ci
extension_path="$PWD/extensions/pi/index.ts"
cd /path/to/project
pi --extension "$extension_path"
```

Run `/reload` in the Pi terminal after updating code or configuration.

## Configuration

Configuration is resolved in this order: the `PIRC_URL` environment variable, the JSON file specified by `PIRC_CONFIG`, then `~/.pirc/extension.json`.

The default connection address is `ws://127.0.0.1:43123/extension`; only loopback addresses are accepted. See the [example](../../config/extension.example.json) for the configuration format.

## Controls

Supports Stop, regular prompts, and `/model`, `/thinking`, `/name`, `/session`, and `/compact`. Built-in commands execute through the Extension API. Model and thinking settings apply to the current session.

Commands validate the session identity and state revision. After stopping, new prompts are accepted only once the agent is confirmed idle. A prompt is acknowledged when Pi emits its user message event. Reconnection synchronizes snapshots and reports event gaps. Server restarts automatically rebuild history from the agent session and unfinished streams.

## Session lifecycle and local UI

Local session changes and branch navigation register a fresh adapter instance and rebuild the selected branch's history. Visible extension messages and local shell output are included in the transcript. Remote prompt acknowledgement uses the text that Pi actually submits after preprocessing.

Blocking extension UI prompts expose their kind and title through session state. They remain interactive in the terminal: Pi's public UI events do not expose selectable options or a remote response callback. Custom TUI components and plugin renderers use their textual tool output remotely.

## Images

User and tool-result images are preserved in the transcript. The client loads PNG, JPEG, WebP, and GIF content in bounded chunks over the encrypted connection; historical images are read from the active agent session. Images larger than 20 MiB are excluded. Downloads do not require the agent to be idle.
