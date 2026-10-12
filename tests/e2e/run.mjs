import { spawn, spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  mkdirSync,
  writeFileSync,
  readFileSync,
  readdirSync,
  existsSync,
  copyFileSync,
  chmodSync,
  unlinkSync,
} from "node:fs";
import { fileURLToPath } from "node:url";
import { resolve, join } from "node:path";
import { createServer } from "node:net";
import assert from "node:assert/strict";

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const run = join(
  root,
  "work/e2e",
  new Date().toISOString().replaceAll(":", "-"),
);
mkdirSync(run, { recursive: true });
const socket = `pirc-${randomUUID()}`;
const check = spawnSync("command -v pi", { shell: true, encoding: "utf8" });
const pi = check.stdout.trim();
assert(pi, "pi is required");
const listener = createServer();
await new Promise((r) => listener.listen(0, "127.0.0.1", r));
const port = listener.address().port;
await new Promise((r) => listener.close(r));
const timeline = [];
const checks = [];
const peers = [];
let service;
let controller;
let generation;
const quote = (s) => `'${s.replaceAll("'", "'\\''")}'`;
function tmux(...args) {
  const r = spawnSync("tmux", ["-L", socket, ...args], { encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout;
}
function input(pane, text) {
  tmux("send-keys", "-t", pane, "C-u");
  tmux("send-keys", "-t", pane, "-l", text);
  tmux("send-keys", "-t", pane, "Enter");
}
function note(name) {
  checks.push(name);
  console.log(`PASS ${name}`);
}
async function ready() {
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    try {
      if ((await fetch(`http://127.0.0.1:${port}/health`)).ok) return;
    } catch {}
    await new Promise((r) => setTimeout(r, 50));
  }
  throw Error("PiRC Server did not start");
}
function startService() {
  service = spawn(
    join(root, "target/debug/pirc"),
    ["server", "--port", String(port)],
    {
      env: {
        ...process.env,

        HOME: run,
      },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  service.stdout.on("data", (b) => writeLog("service.log", b));
  service.stderr.on("data", (b) => writeLog("service.log", b));
}
const logs = new Map();
function writeLog(file, data) {
  logs.set(file, (logs.get(file) ?? "") + String(data));
}
class Peer {
  messages = [];
  sessions = new Map();
  listeners = new Set();
  closed = false;
  constructor(role) {
    this.ws = new WebSocket(`ws://127.0.0.1:${port}/${role}`);
    this.ws.addEventListener("open", () => this.send({ type: "auth" }));
    this.ws.addEventListener("message", (e) => {
      const frame = JSON.parse(e.data);
      this.messages.push(frame);
      timeline.push({ at: Date.now(), direction: "incoming", frame });
      if (frame.message.type === "snapshot")
        this.sessions.set(
          frame.message.session.instance_id,
          frame.message.session,
        );
      if (frame.message.type === "sessions")
        for (const s of frame.message.sessions)
          this.sessions.set(s.instance_id, s);
      for (const notify of [...this.listeners]) notify();
    });
    this.ws.addEventListener("close", () => {
      this.closed = true;
      for (const notify of [...this.listeners]) notify();
    });
    this.ws.addEventListener("error", () => {});
    peers.push(this);
  }
  send(message, id = randomUUID()) {
    const frame = { version: 1, request_id: id, message };
    this.ws.send(JSON.stringify(frame));
    if (message.type !== "auth")
      timeline.push({ at: Date.now(), direction: "outgoing", frame });
    return id;
  }
  wait(predicate, description, timeout = 15000) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.listeners.delete(check);
        reject(Error(`Timeout: ${description}`));
      }, timeout);
      const check = () => {
        const value = predicate();
        if (value) {
          clearTimeout(timer);
          this.listeners.delete(check);
          resolve(value);
        }
      };
      this.listeners.add(check);
      check();
    });
  }
  frame(predicate, after = 0) {
    return this.messages.slice(after).find(predicate);
  }
  result(id, status, after = 0) {
    return this.wait(
      () =>
        this.frame(
          (e) =>
            e.request_id === id &&
            e.message.type === "command_result" &&
            (!status || e.message.status === status),
          after,
        ),
      `result ${id} ${status ?? ""}`,
    );
  }
  state(iid, state) {
    return this.wait(() => {
      const s = this.sessions.get(iid);
      return s?.state === state ? s : null;
    }, `state ${iid} ${state}`);
  }
  close() {
    this.ws.close();
  }
}
async function connect() {
  controller = new Peer("control");
  const welcome = await controller.wait(
    () => controller.frame((e) => e.message.type === "welcome"),
    "welcome",
  );
  generation = welcome.message.generation_id;
  await controller.wait(
    () => controller.frame((e) => e.message.type === "sessions"),
    "list",
  );
  return controller;
}
function active(iid) {
  return controller.sessions.get(iid);
}
function base(s) {
  return {
    generation_id: generation,
    session_id: s.session_id,
    instance_id: s.instance_id,
  };
}
async function stop(s) {
  const id = controller.send({ type: "stop", ...base(s) });
  const result = await controller.result(id, "completed");
  await controller.state(s.instance_id, "idle");
  return result;
}
async function prompt(s, text, id = randomUUID()) {
  controller.send(
    { type: "prompt", ...base(s), expected_revision: s.revision, text },
    id,
  );
  await controller.result(id, "accepted");
  return id;
}
async function builtin(
  s,
  command,
  args = "",
  status = "completed",
  id = randomUUID(),
) {
  controller.send(
    {
      type: "builtin",
      ...base(s),
      expected_revision: s.revision,
      command,
      args,
    },
    id,
  );
  return controller.result(id, status);
}
function launch(name) {
  const folder = join(run, name);
  mkdirSync(folder, { recursive: true });
  mkdirSync(join(folder, "agent"), { recursive: true });
  writeFileSync(
    join(folder, "agent/settings.json"),
    JSON.stringify({
      quietStartup: true,
      compaction: { enabled: false, keepRecentTokens: 100, reserveTokens: 100 },
      retry: { enabled: false },
    }),
  );
  const config = join(folder, "pirc.json");
  writeFileSync(
    config,
    JSON.stringify({ url: `ws://127.0.0.1:${port}/extension` }),
    { mode: 0o600 },
  );
  const useReal = name === "pi-real";
  let modelArgs = "--provider pirc-test --model controlled";
  if (useReal) {
    const dir =
      process.env.PI_CODING_AGENT_DIR ?? join(process.env.HOME, ".pi/agent");
    const settings = JSON.parse(
      readFileSync(join(dir, "settings.json"), "utf8"),
    );
    assert(
      settings.defaultProvider && settings.defaultModel,
      "Configure Pi default provider and model for smoke",
    );
    modelArgs = `--provider ${quote(settings.defaultProvider)} --model ${quote(settings.defaultModel)}`;
    for (const name of ["models.json", "auth.json"])
      if (existsSync(join(dir, name))) {
        copyFileSync(join(dir, name), join(folder, "agent", name));
        chmodSync(join(folder, "agent", name), 0o600);
      }
  }
  const provider = useReal
    ? ""
    : `--extension ${quote(join(root, "tests/e2e/provider.ts"))}`;
  const cmd = `exec env PI_CODING_AGENT_DIR=${quote(join(folder, "agent"))} PIRC_CONFIG=${quote(config)} PI_OFFLINE=1 PI_TELEMETRY=0 ${quote(pi)} --no-extensions ${provider} --extension ${quote(join(root, "extensions/pi/index.ts"))} ${modelArgs} --no-skills --no-prompt-templates --no-context-files --offline --tui-mode regular`;
  const args = [
    "new-session",
    "-d",
    "-s",
    name,
    "-x",
    "160",
    "-y",
    "48",
    "-c",
    folder,
    cmd,
  ];
  tmux(...args);
  return { pane: `${name}:0.0`, folder };
}
async function registration(folder, exclude = new Set()) {
  return controller.wait(
    () =>
      [...controller.sessions.values()].find(
        (s) =>
          s.cwd === folder &&
          s.state !== "offline" &&
          !s.needs_local_attention &&
          !exclude.has(s.instance_id),
      ),
    "Pi registration",
  );
}
async function history(s) {
  const id = controller.send({
    type: "history",
    session_id: s.session_id,
    instance_id: s.instance_id,
    direction: "latest",
    cursor: null,
    limit: 40,
  });
  const frame = await controller.wait(
    () =>
      controller.frame(
        (e) => e.request_id === id && e.message.type === "history_page",
      ),
    "history page",
  );
  return frame.message;
}
const content = (page) =>
  page.items
    .filter((item) => !["loading", "error"].includes(item.role))
    .map((item) => ({
      role: item.role,
      text: item.text,
      arguments: item.arguments,
    }));
function eventFrame(kind, iid, after = 0) {
  return controller.frame(
    (e) =>
      e.message.type === "event" &&
      e.message.instance_id === iid &&
      e.message.event.kind === kind,
    after,
  );
}
async function replacement(pane, folder, command, old) {
  input(pane, command);
  const s = await registration(
    folder,
    new Set([...controller.sessions.keys()]),
  );
  assert.notEqual(s.instance_id, old.instance_id);
  await controller.state(old.instance_id, "offline");
  const id = controller.send({ type: "stop", ...base(old) });
  assert.equal(
    (await controller.result(id, "rejected")).message.code,
    "STALE_INSTANCE",
  );
  return s;
}
let first, second;
try {
  startService();
  await ready();
  const cli = spawnSync(
    process.execPath,
    [join(root, "scripts/control.mjs"), "list"],
    {
      encoding: "utf8",
      timeout: 20000,
      env: {
        ...process.env,
        HOME: run,
        PIRC_URL: `ws://127.0.0.1:${port}/extension`,
      },
    },
  );
  assert.equal(cli.status, 0, cli.stderr);
  assert.deepEqual(JSON.parse(cli.stdout), []);
  note("standalone control CLI lists sessions");
  await connect();
  const extra = new Peer("control");
  await extra.wait(
    () =>
      extra.frame(
        (e) => e.message.type === "error" && e.message.code === "SERVER_BUSY",
      ),
    "second controller",
  );
  extra.close();
  note("connection setup and single client");
  first = launch("pi-one");
  let s = await registration(first.folder);
  const originalSession = s.session_id;
  note("real Pi TUI registration");
  assert.deepEqual(
    s.slash_commands.filter((c) => c.source === "builtin").map((c) => c.name),
    ["model", "thinking", "name", "session", "compact"],
  );
  const initialModel = await builtin(active(s.instance_id), "model");
  assert.equal(initialModel.message.data.current.id, "controlled");
  assert(
    initialModel.message.data.models.some(
      (m) => m.id === "controlled-reasoning",
    ),
  );
  await builtin(
    active(s.instance_id),
    "model",
    "pirc-test/controlled-reasoning",
  );
  await controller.wait(
    () => active(s.instance_id).controls?.model?.id === "controlled-reasoning",
    "model snapshot",
  );
  await builtin(active(s.instance_id), "thinking", "high");
  await controller.wait(
    () => active(s.instance_id).controls?.thinking_level === "high",
    "thinking snapshot",
  );
  const invalidThinking = await builtin(
    active(s.instance_id),
    "thinking",
    "invented",
    "rejected",
  );
  assert.equal(invalidThinking.message.code, "INVALID_THINKING_LEVEL");
  const nameId = randomUUID();
  await builtin(
    active(s.instance_id),
    "name",
    "Built-in command test",
    "completed",
    nameId,
  );
  await controller.wait(
    () => active(s.instance_id).name === "Built-in command test",
    "name snapshot",
  );
  const info = await builtin(active(s.instance_id), "session");
  assert.equal(info.message.data.info.name, "Built-in command test");
  assert.equal(info.message.data.info.user_messages, 0);
  const duplicateStart = controller.messages.length;
  // Reusing the original request returns the completed output without changing Pi again.
  const originalNameRequest = timeline.find(
    (t) => t.direction === "outgoing" && t.frame.request_id === nameId,
  )?.frame;
  assert(originalNameRequest);
  controller.send(originalNameRequest.message, nameId);
  assert.deepEqual(
    (await controller.result(nameId, "completed", duplicateStart)).message.data,
    { kind: "name", name: "Built-in command test" },
  );
  const tooSmall = await builtin(
    active(s.instance_id),
    "compact",
    "",
    "rejected",
  );
  assert.equal(tooSmall.message.code, "COMPACT_FAILED");
  await controller.state(s.instance_id, "idle");
  await controller.wait(
    () => !active(s.instance_id).controls?.compacting,
    "failed compaction clears flag",
  );
  const padding = "Keep the current task and results.".repeat(600);
  await prompt(active(s.instance_id), padding);
  await controller.state(s.instance_id, "idle");
  const compacted = await builtin(
    active(s.instance_id),
    "compact",
    "Keep the task requirements",
  );
  assert.equal(compacted.message.data.kind, "compact");
  assert(compacted.message.data.summary.length > 0);
  await controller.state(s.instance_id, "idle");
  await controller.wait(
    () => !active(s.instance_id).controls?.compacting,
    "completed compaction clears flag",
  );
  const afterCompact = await builtin(active(s.instance_id), "session");
  assert.equal(afterCompact.message.data.info.user_messages, 1);
  assert.equal(afterCompact.message.data.info.context_tokens, null);
  assert(
    !controller.messages.some(
      (e) =>
        e.message.type === "event" &&
        e.message.event.kind === "user_message" &&
        e.message.event.text?.startsWith("/"),
    ),
  );
  await builtin(active(s.instance_id), "model", "pirc-test/controlled");
  await controller.wait(
    () => active(s.instance_id).controls?.model?.id === "controlled",
    "restore test model",
  );
  note(
    "five builtins: model, thinking, name, session, compaction, failures and deduplication",
  );
  const localStart = controller.messages.length;
  input(first.pane, "SLOW local");
  await controller.wait(
    () => eventFrame("message_delta", s.instance_id, localStart),
    "local text stream",
  );
  await controller.state(s.instance_id, "running");
  note("terminal input and structured text events");
  for (let i = 0; i < 20; i++) {
    await stop(active(s.instance_id));
    assert.equal(active(s.instance_id).session_id, originalSession);
    const mark = controller.messages.length;
    await prompt(active(s.instance_id), `SLOW remote-${i}`);
    await controller.wait(
      () => eventFrame("message_delta", s.instance_id, mark),
      "remote text stream",
    );
    assert.equal(active(s.instance_id).session_id, originalSession);
  }
  await stop(active(s.instance_id));
  note("20 Stop -> IDLE -> Prompt cycles in same Session");
  const badVersion = randomUUID();
  controller.ws.send(
    JSON.stringify({
      version: 2,
      request_id: badVersion,
      message: { type: "list" },
    }),
  );
  await controller.wait(
    () =>
      controller.frame(
        (e) => e.message.type === "error" && e.message.code === "INVALID_FRAME",
      ),
    "version rejected",
  );
  note("protocol version rejection");
  let id = controller.send({
    type: "prompt",
    ...base(active(s.instance_id)),
    expected_revision: 0,
    text: "stale",
  });
  assert.equal(
    (await controller.result(id, "rejected")).message.code,
    "STALE_STATE",
  );
  const oldGeneration = controller.send({
    type: "stop",
    ...base(s),
    generation_id: "old",
  });
  assert.equal(
    (await controller.result(oldGeneration, "rejected")).message.code,
    "STALE_GENERATION",
  );
  note("stale revision and generation rejection");
  let mark = controller.messages.length;
  const dupPayload = {
    type: "prompt",
    ...base(active(s.instance_id)),
    expected_revision: active(s.instance_id).revision,
    text: "QUICK duplicate",
  };
  id = controller.send(dupPayload);
  await controller.result(id, "accepted");
  await controller.state(s.instance_id, "idle");
  const dupMark = controller.messages.length;
  controller.send(dupPayload, id);
  await controller.result(id, "accepted", dupMark);
  assert.equal(
    controller.messages
      .slice(mark)
      .filter(
        (e) =>
          e.message.type === "event" &&
          e.message.event.kind === "user_message" &&
          e.message.event.text === "QUICK duplicate",
      ).length,
    1,
  );
  const reused = controller.messages.length;
  controller.send({ ...dupPayload, text: "different" }, id);
  await controller.wait(
    () =>
      controller.frame(
        (e) =>
          e.request_id === id &&
          e.message.type === "error" &&
          e.message.code === "REQUEST_ID_REUSED",
        reused,
      ),
    "ID conflict",
  );
  note("duplicate prompt executes once and ID conflict rejected");
  mark = controller.messages.length;
  await prompt(active(s.instance_id), "TOOL wait");
  await controller.wait(
    () => eventFrame("tool_start", s.instance_id, mark),
    "tool begins",
  );
  const stopId = controller.send({ type: "stop", ...base(s) });
  await controller.result(stopId, "completed");
  await controller.state(s.instance_id, "idle");
  const frames = controller.messages.slice(mark);
  assert(
    frames.findIndex(
      (e) => e.message.type === "event" && e.message.event.kind === "tool_end",
    ) <
      frames.findIndex(
        (e) =>
          e.request_id === stopId &&
          e.message.type === "command_result" &&
          e.message.status === "completed",
      ),
  );
  note("tool cancellation completes before Stop confirmation");
  const idleSnapshot = { ...active(s.instance_id) };
  mark = controller.messages.length;
  input(first.pane, "SLOW terminal-race");
  await controller.wait(
    () => eventFrame("message_delta", s.instance_id, mark),
    "terminal race stream",
  );
  id = controller.send({
    type: "prompt",
    ...base(idleSnapshot),
    expected_revision: idleSnapshot.revision,
    text: "must not queue",
  });
  assert.equal((await controller.result(id, "rejected")).message.code, "BUSY");
  await stop(active(s.instance_id));
  note("terminal task rejects stale remote prompt without steering");
  const beforeReload = { ...active(s.instance_id) };
  s = await replacement(first.pane, first.folder, "/reload", beforeReload);
  note("reload replaces instance and invalidates old controls");
  mark = controller.messages.length;
  await prompt(active(s.instance_id), "QUICK for fork");
  await controller.state(s.instance_id, "idle");
  s = await replacement(first.pane, first.folder, "/test-fork", s);
  note("fork replaces runtime registration");
  await prompt(active(s.instance_id), "QUICK persist fork");
  await controller.state(s.instance_id, "idle");
  const sessionFiles = () => {
    const base = join(first.folder, "agent/sessions");
    const out = [];
    function walk(p) {
      for (const item of readdirSync(p, { withFileTypes: true })) {
        const f = join(p, item.name);
        if (item.isDirectory()) walk(f);
        else if (f.endsWith(".jsonl")) out.push(f);
      }
    }
    walk(base);
    return out;
  };
  const resumeFile = sessionFiles().find(
    (f) =>
      JSON.parse(readFileSync(f, "utf8").split("\n")[0]).id === s.session_id,
  );
  assert(resumeFile, "persisted fork Session");
  const forkSession = s.session_id;
  s = await replacement(first.pane, first.folder, "/new", s);
  assert.notEqual(s.session_id, forkSession);
  note("new Session updates registry");
  s = await replacement(
    first.pane,
    first.folder,
    `/test-resume ${resumeFile}`,
    s,
  );
  assert.equal(s.session_id, forkSession);
  note("resume updates identity and rejects old instance");
  second = launch("pi-two");
  const s2 = await registration(second.folder);
  const firstState = { ...active(s.instance_id) };
  mark = controller.messages.length;
  await prompt(active(s2.instance_id), "SLOW second");
  await controller.wait(
    () => eventFrame("message_delta", s2.instance_id, mark),
    "second stream",
  );
  assert.equal(active(s.instance_id).state, firstState.state);
  await stop(active(s2.instance_id));
  assert.equal(active(s.instance_id).state, "idle");
  note("two Pi processes route independently");
  const replayMark = controller.messages.length;
  controller.send({
    type: "replay",
    session_id: s2.session_id,
    instance_id: s2.instance_id,
    after_seq: 0,
  });
  await controller.wait(
    () => eventFrame("user_message", s2.instance_id, replayMark),
    "replay events",
  );
  const replayed = controller.messages
    .slice(replayMark)
    .filter((e) => e.message.type === "event");
  assert(replayed.length > 0);
  assert.equal(
    new Set(replayed.map((e) => e.message.seq)).size,
    replayed.length,
  );
  note("retained event replay preserves sequence");
  const queryId = controller.send({
    type: "get_result",
    command_id: "does-not-exist",
  });
  await controller.wait(
    () =>
      controller.frame(
        (e) =>
          e.request_id === queryId &&
          e.message.type === "error" &&
          e.message.code === "RESULT_UNKNOWN",
      ),
    "unknown result",
  );
  const idleHistory = content(await history(active(s2.instance_id)));
  assert(idleHistory.some((item) => item.text.includes("SLOW second")));
  mark = controller.messages.length;
  await prompt(active(s.instance_id), "SLOW restart recovery");
  await controller.wait(
    () => eventFrame("message_delta", s.instance_id, mark),
    "stream before restart",
  );
  const partialHistory = content(await history(active(s.instance_id)));
  const oldGen = generation;
  const exited = new Promise((r) => service.once("exit", r));
  service.kill("SIGTERM");
  await controller.wait(() => controller.closed, "server closes connection");
  await exited;
  startService();
  await ready();
  await connect();
  s = await registration(first.folder);
  assert.notEqual(generation, oldGen);
  await controller.wait(
    () =>
      active(s.instance_id)?.needs_local_attention === false &&
      active(s2.instance_id)?.needs_local_attention === false,
    "both histories rebuilt",
  );
  const restoredIdle = await history(active(s2.instance_id));
  assert.deepEqual(content(restoredIdle), idleHistory);
  assert(
    restoredIdle.items.some((item) => item.role === "error" && item.is_error),
  );
  const rebuilt = await history(active(s.instance_id));
  assert.equal(rebuilt.last_seq, rebuilt.source_seq);
  for (const item of partialHistory)
    assert(
      content(rebuilt).some(
        (next) => next.role === item.role && next.text.startsWith(item.text),
      ),
      `Recovered ${item.role}: ${item.text}`,
    );
  mark = controller.messages.length;
  await controller.wait(
    () => eventFrame("message_delta", s.instance_id, mark),
    "stream continues after server restart",
  );
  await stop(active(s.instance_id));
  note(
    "server restart restores idle and unfinished history while Pi keeps running",
  );
  id = controller.send({ type: "stop", ...base(s), generation_id: oldGen });
  assert.equal(
    (await controller.result(id, "rejected")).message.code,
    "STALE_GENERATION",
  );
  note("service restart resynchronizes and rejects old generation");
  tmux("kill-pane", "-t", second.pane);
  await controller.state(s2.instance_id, "offline");
  assert.notEqual(active(s.instance_id).state, "offline");
  note("terminal exit marks only its instance offline");
  mark = controller.messages.length;
  input(first.pane, "QUICK terminal still works");
  await controller.wait(
    () => eventFrame("message_end", s.instance_id, mark),
    "terminal after remote controls",
  );
  await controller.state(s.instance_id, "idle");

  const imageMark = controller.messages.length;
  const imageData =
    "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGP4XzDhPzJmIF0AAFteL+Hl/kTRAAAAAElFTkSuQmCC";
  const imageSession = active(s.instance_id);
  await prompt(imageSession, "IMAGE");
  await controller.wait(
    () =>
      controller.frame(
        (e) =>
          e.message.type === "event" &&
          e.message.instance_id === s.instance_id &&
          e.message.event.kind === "tool_end" &&
          e.message.event.images?.length,
        imageMark,
      ),
    "image tool result",
  );
  await controller.state(s.instance_id, "idle");
  const imageEvent = controller.frame(
    (e) =>
      e.message.type === "event" &&
      e.message.instance_id === s.instance_id &&
      e.message.event.kind === "tool_end" &&
      e.message.event.images?.length,
    imageMark,
  ).message.event;
  const imageRead = controller.send({
    type: "read_image",
    ...base(active(s.instance_id)),
    image_id: imageEvent.images[0].id,
    offset: 0,
  });
  const imageResult = (await controller.result(imageRead, "completed")).message
    .data;
  assert.equal(imageResult.kind, "image_chunk");
  assert.equal(imageResult.data, imageData);
  const imageHistory = await history(active(s.instance_id));
  assert(
    imageHistory.items.some(
      (item) =>
        item.role === "tool" &&
        item.images?.some((image) => image.id === imageEvent.images[0].id),
    ),
  );
  note(
    "tool images survive history with scoped chunk reads",
  );
  input(first.pane, "/test-dialog");
  await controller.wait(
    () => active(s.instance_id)?.ui_prompt?.title === "Confirm fixture",
    "blocking UI title",
  );
  tmux("send-keys", "-t", first.pane, "Escape");
  await controller.wait(
    () => !active(s.instance_id)?.needs_local_attention,
    "local UI settled",
  );
  note(
    "blocking extension UI exposes its title and remains locally interactive",
  );
  note("terminal remains usable after remote controls and lifecycle changes");
  checks.push("Controlled-provider acceptance passed");
  if (process.env.PIRC_REAL_MODEL_SMOKE === "1") {
    const real = launch("pi-real");
    const rs = await registration(real.folder);
    const mark = controller.messages.length;
    await prompt(
      active(rs.instance_id),
      "Reply only PIRC_SMOKE_OK. Do not use tools.",
    );
    await controller.wait(
      () => eventFrame("message_delta", rs.instance_id, mark),
      "actual model streaming",
      60000,
    );
    await controller.state(rs.instance_id, "idle");
    const final = eventFrame("message_end", rs.instance_id, mark);
    assert(final && !final.message.event.is_error, "Actual model completion");
    note("configured actual model prompt and output smoke");
  }
} catch (err) {
  writeLog("failure.txt", err.stack);
  console.error(err.stack);
  process.exitCode = 1;
} finally {
  for (const name of ["pi-one", "pi-two", "pi-real"]) {
    const r = spawnSync(
      "tmux",
      ["-L", socket, "capture-pane", "-p", "-S", "-500", "-t", `${name}:0.0`],
      { encoding: "utf8" },
    );
    if (r.status === 0) writeLog(`${name}.txt`, r.stdout);
  }
  for (const file of ["auth.json", "models.json"]) {
    const path = join(run, "pi-real/agent", file);
    if (existsSync(path)) unlinkSync(path);
  }
  for (const peer of peers) peer.close();
  service?.kill("SIGTERM");
  spawnSync("tmux", ["-L", socket, "kill-server"], { stdio: "ignore" });
  for (const [file, data] of logs) writeFileSync(join(run, file), data);
  writeFileSync(join(run, "timeline.json"), JSON.stringify(timeline, null, 2));
  writeFileSync(
    join(run, "report.json"),
    JSON.stringify(
      {
        passed: !process.exitCode,
        checks,
        pi: spawnSync(pi, ["--version"], { encoding: "utf8" }).stdout.trim(),
        run,
      },
      null,
      2,
    ),
  );
  console.log(`Report: ${run}`);
}
