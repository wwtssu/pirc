import { readFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { randomUUID } from "node:crypto";

const [action = "list", instanceId, ...words] = process.argv.slice(2);
if (
  !["list", "watch", "stop", "prompt"].includes(action) ||
  (["stop", "prompt"].includes(action) && !instanceId)
) {
  console.error(
    "Usage: node scripts/control.mjs list|watch|stop <instanceId>|prompt <instanceId> <text>",
  );
  process.exit(2);
}
const path = process.env.PIRC_CONFIG ?? `${homedir()}/.pirc/extension.json`;
const config = existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : {};
const url = new URL(
  process.env.PIRC_URL ?? config.url ?? "ws://127.0.0.1:43123/extension",
);
if (
  url.protocol !== "ws:" ||
  !["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)
) {
  console.error("Local control requires loopback WebSocket");
  process.exit(2);
}
url.pathname = "/control";
let generation;
let commandId;
let finished = false;
const ws = new WebSocket(url);
function send(message, id = randomUUID()) {
  ws.send(JSON.stringify({ version: 1, request_id: id, message }));
  return id;
}
function done(code = 0) {
  if (finished) return;
  finished = true;
  process.exitCode = code;
  clearTimeout(timeout);
  ws.close();
}
const timeout =
  action === "watch"
    ? undefined
    : setTimeout(() => {
        console.error(
          "Operation not confirmed. Result is unknown; do not automatically resend.",
        );
        done(1);
      }, 15000);
ws.addEventListener("open", () => send({ type: "auth" }));
ws.addEventListener("message", (e) => {
  const frame = JSON.parse(e.data);
  const m = frame.message;
  if (m.type === "error") {
    console.error(JSON.stringify(frame));
    done(1);
    return;
  }
  if (m.type === "welcome") {
    generation = m.generation_id;
    return;
  }
  if (action === "watch") {
    console.log(JSON.stringify(frame));
    return;
  }
  if (m.type === "sessions" && !commandId) {
    if (action === "list") {
      console.log(JSON.stringify(m.sessions, null, 2));
      done();
      return;
    }
    const s = m.sessions.find(
      (s) => s.instance_id === instanceId && s.state !== "offline",
    );
    if (!s) {
      console.error("Online instance not found");
      done(1);
      return;
    }
    const target = {
      generation_id: generation,
      session_id: s.session_id,
      instance_id: s.instance_id,
    };
    commandId = send(
      action === "stop"
        ? { type: "stop", ...target }
        : {
            type: "prompt",
            ...target,
            expected_revision: s.revision,
            text: words.join(" "),
          },
    );
  }
  if (m.type === "command_result" && frame.request_id === commandId) {
    console.log(JSON.stringify(frame));
    if (m.status === "rejected") done(1);
    else if (action === "prompt" || m.status === "completed") done();
  }
});
ws.addEventListener("error", () => {
  console.error("Cannot connect to PiRC Server");
  done(1);
});
ws.addEventListener("close", () => {
  if (!finished) {
    console.error("Connection closed before confirmation");
    done(1);
  }
});
process.on("SIGINT", () => done());
