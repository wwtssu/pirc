import { accessSync, constants, openSync, readSync, closeSync } from "node:fs";
import assert from "node:assert/strict";
import { appSecretFixture } from "./app-secret-fixture.mjs";
import { fixturePublicKey } from "./crypto-fixture.mjs";
import { approveFixtureClients } from "./approval-fixture.mjs";
import { decode } from "../../extensions/shared/protocol.ts";
import { spawn, spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { createServer } from "node:net";

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const run = join(root, "work/e2e", `omp-${Date.now()}`);
const cwd = join(run, "project"),
  agent = join(run, "agent"),
  bin = join(run, "bin");
for (const path of [
  run,
  cwd,
  agent,
  bin,
  join(run, "tmp"),
  join(agent, "sessions/fixture"),
])
  mkdirSync(path, { recursive: true });
const socket = `pirc-omp-test-${randomUUID()}`;
const q = (s) => `'${s.replaceAll("'", "'\\''")}'`;
function tmux(...args) {
  const r = spawnSync("tmux", ["-L", socket, ...args], { encoding: "utf8" });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout;
}
const findExecutable = (name) =>
  (process.env.PATH ?? "")
    .split(process.platform === "win32" ? ";" : ":")
    .map((dir) => join(dir, name))
    .find((path) => {
      try {
        accessSync(path, constants.X_OK);
        const fd = openSync(path, "r"),
          prefix = Buffer.alloc(256);
        try {
          readSync(fd, prefix, 0, prefix.length, 0);
        } finally {
          closeSync(fd);
        }
        if (
          /^#!.*\benv\s+bun\b/.test(prefix.toString("utf8")) &&
          !findExecutable("bun")
        )
          return false;
        return true;
      } catch {
        return false;
      }
    });
const omp = findExecutable("omp");
assert(omp, "OMP with an available runtime is required");
const wrapper = join(bin, "omp");
// A macOS login shell can reset HOME; keep the launched agent in the isolated fixture.
writeFileSync(
  wrapper,
  `#!/bin/sh\ncase " $* " in *" --resume "*) model_args='' ;; *) model_args='--model pirc-test/controlled' ;; esac\nexec env HOME=${q(run)} ${q(omp)} --no-extensions -e ${q(join(root, "tests/e2e/omp-provider.ts"))} --no-skills --no-rules --no-lsp --no-title --approval-mode yolo $model_args --slow pirc-test/fixture-large --session-dir ${q(join(agent, "sessions/fixture"))} "$@"\n`,
  { mode: 0o700 },
);
// Let the real server's macOS launcher run in an isolated test tmux terminal.
writeFileSync(
  join(bin, "open"),
  `#!${process.execPath}\nimport {spawnSync} from 'node:child_process';\nconst script=process.argv.at(-1).replace(/\\.terminal$/,'.command');\nconst r=spawnSync('tmux',['-L',${JSON.stringify(socket)},'new-session','-d','-s','managed-'+Date.now(),'-x','160','-y','48',script]);\nprocess.exit(r.status??1);\n`,
  { mode: 0o700 },
);
writeFileSync(
  join(agent, "config.yml"),
  "startup:\n  setupWizard: false\n  checkUpdate: false\ncompaction:\n  enabled: false\n  methodOrder: [soft]\n  keepRecentTokens: 100\n  reserveTokens: 100\nretry:\n  enabled: false\n",
);
const reservation = createServer();
await new Promise((r) => reservation.listen(0, "127.0.0.1", r));
const port = reservation.address().port;
await new Promise((r) => reservation.close(r));
const env = {
  ...process.env,
  HOME: run,
  PATH: `${bin}:${process.env.PATH}`,
  PI_CODING_AGENT_DIR: agent,
  OMP_PROFILE: "",
  PI_PROFILE: "",
  PI_NO_PTY: "1",
};
let server, ws, appSecrets;
const frames = [],
  snapshots = new Map(),
  checks = [];
let generation;
async function wait(check, label, ms = 30000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const result = await check();
    if (result) return result;
    await new Promise((r) => setTimeout(r, 25));
  }
  throw new Error(`Timeout: ${label}`);
}
function note(label) {
  checks.push(label);
  console.log("PASS", label);
}
function send(message, id = randomUUID()) {
  const frame = JSON.stringify({ version: 1, request_id: id, message });
  assert(decode(frame), `Invalid fixture frame: ${message.type}`);
  ws.send(frame);
  return id;
}
async function request(message) {
  const id = send(message);
  return (
    await wait(() => frames.find((f) => f.request_id === id), message.type)
  ).message;
}
async function connect() {
  generation = undefined;
  ws = new WebSocket(`ws://127.0.0.1:${port}/control`);
  ws.addEventListener("open", () => send({ type: "auth" }));
  ws.addEventListener("message", (e) => {
    const f = JSON.parse(e.data);
    frames.push(f);
    if (f.message.type === "welcome") generation = f.message.generation_id;
    if (f.message.type === "sessions")
      for (const s of f.message.sessions) snapshots.set(s.instance_id, s);
    if (f.message.type === "snapshot")
      snapshots.set(f.message.session.instance_id, f.message.session);
  });
  await wait(() => ws.readyState === 1 && generation, "control connection");
}
function base(s) {
  return {
    generation_id: generation,
    session_id: s.session_id,
    instance_id: s.instance_id,
    expected_revision: s.revision,
  };
}
async function idle(id) {
  return wait(() => {
    const s = snapshots.get(id);
    return s?.state === "idle" && !s.needs_local_attention && s;
  }, "idle");
}
async function builtin(s, command, args = "", status = "completed") {
  const id = send({ type: "builtin", ...base(s), command, args });
  return (
    await wait(
      () =>
        frames.find(
          (f) =>
            f.request_id === id &&
            f.message.type === "command_result" &&
            f.message.status === status,
        ),
      `builtin ${command}`,
      60000,
    )
  ).message;
}
async function prompt(s, text, images = []) {
  const at = frames.length,
    id = send({ type: "prompt", ...base(s), text, images });
  const accepted = await wait(
    () =>
      frames
        .slice(at)
        .find(
          (f) => f.request_id === id && f.message.type === "command_result",
        ),
    "prompt ack",
  );
  assert.equal(
    accepted.message.status,
    "accepted",
    JSON.stringify(accepted.message),
  );
  return at;
}
function events(at) {
  return frames
    .slice(at)
    .filter((f) => f.message.type === "event")
    .map((f) => f.message.event);
}
function start() {
  server = spawn(
    join(root, "target/debug/pirc"),
    ["server", "--port", String(port)],
    { cwd: root, env, stdio: ["ignore", "pipe", "pipe"] },
  );
  approveFixtureClients(server, root, env);
  server.stdout.on("data", (b) =>
    writeFileSync(join(run, "server.log"), b, { flag: "a" }),
  );
  server.stderr.on("data", (b) =>
    writeFileSync(join(run, "server.log"), b, { flag: "a" }),
  );
}
try {
  tmux("new-session", "-d", "-s", "fixture-host", "sleep 600");
  tmux("set-option", "-g", "remain-on-exit", "on");
  start();
  await wait(async () => {
    try {
      return (await fetch(`http://127.0.0.1:${port}/health`)).ok;
    } catch {
      return false;
    }
  }, "server");
  // An async predicate needs an explicit readiness loop.
  await wait(() => server.exitCode === null, "server running");
  await connect();
  const homeLaunch = await request({
    type: "launch_session",
    agent_id: "omp",
    generation_id: generation,
    cwd: "~",
    session_id: null,
    name: "Home directory fixture",
    create_cwd: false,
  });
  assert.equal(homeLaunch.type, "session_launched", JSON.stringify(homeLaunch));
  const homeSession = await wait(
    () =>
      [...snapshots.values()].find(
        (s) =>
          s.launch_id === homeLaunch.launch_id &&
          s.state === "idle" &&
          !s.needs_local_attention,
      ),
    "OMP home directory registration",
  );
  assert.equal(
    homeSession.cwd,
    run,
    "OMP must preserve the explicitly selected home directory",
  );
  const homeClose = send({ type: "close_session", ...base(homeSession) });
  await wait(
    () =>
      frames.find(
        (f) => f.request_id === homeClose && f.message.status === "completed",
      ),
    "home directory session exit",
  );
  await wait(
    () => snapshots.get(homeSession.instance_id)?.state === "offline",
    "home directory session offline",
  );
  note("OMP preserves an explicitly selected home directory");
  const launched = await request({
    type: "launch_session",
    agent_id: "omp",
    generation_id: generation,
    cwd,
    session_id: null,
    name: "OMP fixture",
    create_cwd: false,
  });
  assert.equal(launched.type, "session_launched", JSON.stringify(launched));
  let s = await wait(
    () =>
      [...snapshots.values()].find(
        (s) =>
          s.agent_id === "omp" &&
          s.launch_id === launched.launch_id &&
          s.state === "idle" &&
          !s.needs_local_attention,
      ),
    "OMP registration",
  );
  assert.equal(s.name, "OMP fixture");
  assert.equal(s.cwd, cwd, "OMP must preserve the selected project directory");
  note("server creates and registers a named OMP TUI");
  const iid = s.instance_id;
  let result = await builtin(s, "model");
  assert(result.data.models.some((m) => m.id === "fixture-large"));
  note("model catalog and current model");
  assert(result.data.roles.some((r) => r.id === "default"));
  assert(result.data.roles.some((r) => r.id === "task"));
  assert(
    result.data.roles.some((r) => r.id === "image" && r.category === "kind"),
  );
  s = await idle(iid);
  const currentBeforeRoleEdit = s.controls.model.id;
  result = await builtin(
    s,
    "model",
    JSON.stringify({ op: "role_models", role: "image" }),
  );
  assert(
    result.data.models.some(
      (m) => m.provider === "pirc-test-image" && m.id === "fixture-image",
    ),
  );
  assert(!result.data.models.some((m) => m.id === "controlled"));
  s = await idle(iid);
  result = await builtin(
    s,
    "model",
    JSON.stringify({
      op: "set_role",
      role: "image",
      selector: "pirc-test-image/fixture-image",
    }),
  );
  assert.equal(
    result.data.roles.find((r) => r.id === "image").resolved.id,
    "fixture-image",
  );
  s = await idle(iid);
  assert.equal(s.controls.model.id, currentBeforeRoleEdit);
  await builtin(
    s,
    "model",
    JSON.stringify({ op: "clear_role", role: "image" }),
  );
  s = await idle(iid);

  result = await builtin(
    s,
    "model",
    JSON.stringify({ op: "role_models", role: "task" }),
  );
  assert(result.data.models.some((m) => m.id === "fixture-large"));
  s = await idle(iid);
  result = await builtin(
    s,
    "model",
    JSON.stringify({
      op: "set_role",
      role: "task",
      selector: "pirc-test/fixture-large",
    }),
  );
  assert.equal(result.status, "completed");
  assert.equal(
    result.data.roles.find((r) => r.id === "task").selector,
    "pirc-test/fixture-large",
  );
  s = await idle(iid);
  assert.equal(s.controls.model.id, currentBeforeRoleEdit);
  assert(
    readFileSync(join(agent, "config.yml"), "utf8").includes(
      "pirc-test/fixture-large",
    ),
  );
  result = await builtin(
    s,
    "model",
    JSON.stringify({
      op: "set_role",
      role: "image",
      selector: "pirc-test/fixture-large",
    }),
    "rejected",
  );
  assert.equal(result.status, "rejected");
  s = await idle(iid);
  result = await builtin(
    s,
    "model",
    JSON.stringify({ op: "clear_role", role: "task" }),
  );
  assert.equal(result.status, "completed");
  assert.equal(result.data.roles.find((r) => r.id === "task").selector, null);
  note(
    "native model roles list, assignment, type validation and reset without switching current model",
  );

  s = await idle(iid);
  await builtin(s, "model", "@slow");
  s = await idle(iid);
  result = await builtin(s, "thinking");
  assert.deepEqual(result.data.levels, ["off", "low", "high", "max"]);
  await builtin(s, "thinking", "high");
  s = await idle(iid);
  assert.equal(s.controls.thinking_level, "high");
  note("model-specific reasoning levels and selection");
  await builtin(s, "name", "Renamed OMP");
  s = await wait(() => {
    const v = snapshots.get(iid);
    return v?.name === "Renamed OMP" && v;
  }, "name synchronization");
  result = await builtin(s, "session");
  const savedPath = result.data.info.session_file;
  assert(savedPath);
  note("async name and session information");
  s = await idle(iid);
  let at = await prompt(s, "STREAM");
  await wait(
    () => events(at).some((e) => e.kind === "tool_update"),
    "streaming tool",
  );
  await idle(iid);
  let emitted = events(at);
  assert(emitted.some((e) => e.kind === "thinking_delta"));
  assert(emitted.some((e) => e.kind === "tool_call_end"));
  assert(emitted.some((e) => e.kind === "tool_end"));
  assert(emitted.some((e) => e.kind === "message_delta"));
  note("thinking, tool-call arguments, tool output and answer streaming");
  s = await idle(iid);
  at = await prompt(s, "SLOW");
  await wait(
    () => events(at).some((e) => e.kind === "message_delta"),
    "slow reply",
  );
  s = snapshots.get(iid);
  const stopped = send({
    type: "stop",
    generation_id: generation,
    session_id: s.session_id,
    instance_id: s.instance_id,
  });
  await wait(
    () =>
      frames.find(
        (f) => f.request_id === stopped && f.message.status === "completed",
      ),
    "stop completion",
  );
  await idle(iid);
  note("stop confirms idle before another prompt");
  s = await idle(iid);
  at = await prompt(s, "TODO");
  await wait(
    () =>
      events(at).some((e) => e.kind === "tool_end" && e.tool_name === "todo"),
    "native Todo output",
  );
  await idle(iid);
  assert(
    events(at).some((e) =>
      e.todo?.some((p) => p.tasks.some((t) => t.status === "in_progress")),
    ),
  );
  assert(
    events(at).some((e) =>
      e.todo?.some((p) => p.tasks.some((t) => t.status === "completed")),
    ),
  );
  note("native Todo emits structured phases and task states");
  s = await idle(iid);
  at = await prompt(s, "ASK");
  s = await wait(() => {
    const v = snapshots.get(iid);
    return v?.ui_prompt?.ask && v;
  }, "native Ask dialog");
  const askRequest = s.ui_prompt.ask;
  assert.equal(askRequest.questions.length, 2);
  const invalidAnswer = await request({
    type: "answer_ask",
    generation_id: generation,
    session_id: s.session_id,
    instance_id: iid,
    prompt_id: askRequest.id,
    answers: [],
  });
  assert.equal(invalidAnswer.status, "rejected");
  const answer = await request({
    type: "answer_ask",
    generation_id: generation,
    session_id: s.session_id,
    instance_id: iid,
    prompt_id: askRequest.id,
    answers: [
      { id: "color", selected: [1], text: null, note: "From App" },
      {
        id: "features",
        selected: [0, 1],
        text: "Also support custom text",
        note: null,
      },
    ],
  });
  assert.equal(answer.status, "completed");
  await idle(iid);
  assert(
    events(at).some(
      (e) =>
        e.kind === "tool_end" &&
        e.tool_name === "ask" &&
        e.text.includes("Blue") &&
        e.text.includes("Also support custom text"),
    ),
  );
  const stale = await request({
    type: "answer_ask",
    generation_id: generation,
    session_id: s.session_id,
    instance_id: iid,
    prompt_id: askRequest.id,
    answers: [],
  });
  assert.equal(stale.code, "STALE_PROMPT");
  note(
    "native Ask accepts single/multiple/custom answers and rejects stale replies",
  );
  s = await idle(iid);
  at = await prompt(s, "ASK_LOCAL");
  await wait(() => snapshots.get(iid)?.ui_prompt?.ask, "local Ask dialog");
  const nativeTerminal = await wait(
    () =>
      tmux("list-panes", "-a", "-F", "#{pane_id}")
        .trim()
        .split("\n")
        .find((pane) =>
          tmux("capture-pane", "-p", "-t", pane).includes("Choose a color"),
        ),
    "native Ask visible in terminal",
  );
  tmux("send-keys", "-t", nativeTerminal, "Enter");
  await idle(iid);
  assert(!snapshots.get(iid).ui_prompt?.ask);
  assert(
    events(at).some(
      (e) =>
        e.kind === "tool_end" &&
        e.tool_name === "ask" &&
        e.text.includes("Blue"),
    ),
  );
  note("answering native terminal Ask dismisses the remote request");
  s = await idle(iid);
  await prompt(s, "ASK");
  await wait(() => snapshots.get(iid)?.ui_prompt?.ask, "Ask to stop");
  const askStop = send({
    type: "stop",
    generation_id: generation,
    session_id: s.session_id,
    instance_id: iid,
  });
  await wait(
    () =>
      frames.some(
        (f) => f.request_id === askStop && f.message.status === "completed",
      ),
    "Stop pending Ask",
  );
  await idle(iid);
  assert(!snapshots.get(iid).ui_prompt?.ask);
  note("Stop cancels both Ask surfaces and confirms idle");
  s = await idle(iid);
  at = await prompt(s, "IMAGE", [
    {
      mime_type: "image/png",
      data: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGP4XzDhPzJmIF0AAFteL+Hl/kTRAAAAAElFTkSuQmCC",
    },
  ]);
  await wait(
    () => events(at).some((e) => e.kind === "tool_end" && e.images?.length),
    "tool image",
  );
  await idle(iid);
  const image = events(at).find(
    (e) => e.kind === "tool_end" && e.images?.length,
  ).images[0];
  const chunk = await request({
    type: "read_image",
    generation_id: generation,
    session_id: s.session_id,
    instance_id: iid,
    image_id: image.id,
    offset: 0,
  });
  assert.equal(chunk.status, "completed");
  assert(chunk.data.data);
  note("image picker input and TUI tool image retrieval");
  s = await idle(iid);
  const upload = await request({
    type: "upload_file_chunk",
    generation_id: generation,
    session_id: s.session_id,
    instance_id: iid,
    upload_id: randomUUID(),
    name: "fixture.txt",
    offset: 0,
    total: 12,
    data: Buffer.from("OMP file OK\n").toString("base64"),
  });
  assert.equal(upload.type, "file_chunk_stored", JSON.stringify(upload));
  at = await prompt(s, `FILE\n\nAttached file: ${JSON.stringify(upload.path)}`);
  await wait(
    () =>
      events(at).some(
        (e) => e.kind === "tool_end" && e.text?.includes("OMP file OK"),
      ),
    "uploaded file read",
  );
  await idle(iid);
  note("file upload reaches the OMP tool in the same prompt");
  s = await idle(iid);
  const catalog = await request({ type: "saved_sessions" });
  assert(catalog.agents.some((a) => a.id === "omp"));
  assert(
    !catalog.sessions.some(
      (x) => x.agent_id === "omp" && x.session_id === s.session_id,
    ),
  );
  note("installed-agent discovery and online history filtering");
  const close = send({ type: "close_session", ...base(s) });
  await wait(
    () =>
      frames.find(
        (f) => f.request_id === close && f.message.status === "completed",
      ),
    "managed exit",
  );
  await wait(() => snapshots.get(iid)?.state === "offline", "offline");
  const historyCatalog = await request({ type: "saved_sessions" });
  const saved = historyCatalog.sessions.find(
    (x) => x.agent_id === "omp" && x.session_id === s.session_id,
  );
  assert.equal(saved?.name, "Renamed OMP");
  note("OMP title-slot history listing after exit");
  const restored = await request({
    type: "launch_session",
    agent_id: "omp",
    generation_id: generation,
    cwd,
    session_id: s.session_id,
    name: null,
    create_cwd: false,
  });
  assert.equal(restored.type, "session_launched");
  s = await wait(
    () =>
      [...snapshots.values()].find(
        (x) =>
          x.agent_id === "omp" &&
          x.session_id === saved.session_id &&
          x.instance_id !== iid &&
          x.state === "idle" &&
          !x.needs_local_attention,
      ),
    "restore",
  );
  assert.equal(s.name, "Renamed OMP");
  assert.equal(
    s.cwd,
    cwd,
    "Restoring OMP must preserve the recorded project directory",
  );
  assert.equal(s.controls.model.id, "fixture-large");
  assert.equal(s.controls.thinking_level, "high");
  const page = await request({
    type: "history",
    session_id: s.session_id,
    instance_id: s.instance_id,
    direction: "latest",
    cursor: null,
    limit: 100,
  });
  assert.equal(page.type, "history_page", JSON.stringify(page));
  assert(page.items.some((i) => i.images?.length));
  assert.equal(page.items.filter((i) => i.todo).length, 1);
  assert(page.items.find((i) => i.todo).id.startsWith("todo:"));
  assert(
    page.items.some((i) =>
      i.todo?.some((p) => p.tasks.some((t) => t.status === "completed")),
    ),
  );
  note("resume restores history, name, images and structured Todo blocks");
  result = await builtin(s, "compact", "Preserve the fixture result");
  assert.equal(result.status, "completed");
  assert(result.data.summary.length > 0);
  await idle(s.instance_id);
  note("manual context compaction confirms a summary and returns to idle");
  s = await idle(s.instance_id);
  at = await prompt(s, "SLOW");
  await wait(
    () => events(at).some((e) => e.kind === "message_delta"),
    "stream before restart",
  );
  const previousGeneration = generation;
  const peerClosed = new Promise((r) =>
    ws.addEventListener("close", r, { once: true }),
  );
  ws.close();
  await peerClosed;
  const stoppedServer = new Promise((r) => server.once("exit", r));
  server.kill("SIGTERM");
  await stoppedServer;
  snapshots.clear();
  start();
  await wait(async () => {
    try {
      return (await fetch(`http://127.0.0.1:${port}/health`)).ok;
    } catch {
      return false;
    }
  }, "restarted server");
  await connect();
  assert.notEqual(generation, previousGeneration);
  s = await wait(() => {
    const current = snapshots.get(s.instance_id);
    return current && !current.needs_local_attention && current;
  }, "OMP reconnect after server restart");
  const rebuilt = await request({
    type: "history",
    session_id: s.session_id,
    instance_id: s.instance_id,
    direction: "latest",
    cursor: null,
    limit: 100,
  });
  assert.equal(rebuilt.type, "history_page");
  assert(rebuilt.items.some((i) => i.text?.includes("SLOW")));
  const stopAfterRestart = send({
    type: "stop",
    generation_id: generation,
    session_id: s.session_id,
    instance_id: s.instance_id,
  });
  await wait(
    () =>
      frames.find(
        (f) =>
          f.request_id === stopAfterRestart && f.message.status === "completed",
      ),
    "stop after restart",
  );
  await idle(s.instance_id);
  note("server restart rebuilds OMP history and preserves the running agent");
  if (process.env.PIRC_OMP_FLUTTER === "1") {
    const closed = new Promise((r) =>
      ws.addEventListener("close", r, { once: true }),
    );
    ws.close();
    await closed;
    appSecrets = appSecretFixture();
    const flutter = spawn(
      "flutter",
      [
        "test",
        "integration_test/omp_test.dart",
        "-d",
        "macos",
        "--dart-define=PIRC_SECRET_STORE=file",
        `--dart-define=PIRC_SECRET_FILE=${appSecrets.path}`,
        `--dart-define=PIRC_TEST_URL=http://127.0.0.1:${port}`,
        `--dart-define=PIRC_TEST_SERVER_KEY=${fixturePublicKey(join(run, ".pirc/server-key"))}`,
      ],
      { cwd: join(root, "apps/client"), stdio: ["ignore", "pipe", "pipe"] },
    );
    flutter.stdout.on("data", (b) => process.stdout.write(b));
    flutter.stderr.on("data", (b) => process.stderr.write(b));
    assert.equal(
      await new Promise((r) => flutter.once("exit", r)),
      0,
      "OMP App integration",
    );
    note("native App model/effort pickers and streamed OMP reply");
  }
  console.log(`OMP checks passed: ${checks.length}`);
} catch (error) {
  try {
    writeFileSync(
      join(run, "terminal.txt"),
      tmux("list-panes", "-a", "-F", "#{pane_id}")
        .trim()
        .split("\n")
        .map((p) => tmux("capture-pane", "-p", "-t", p, "-S", "-200"))
        .join("\n"),
    );
  } catch {}
  throw error;
} finally {
  appSecrets?.cleanup();
  ws?.close();
  server?.kill("SIGTERM");
  spawnSync("tmux", ["-L", socket, "kill-server"]);
  writeFileSync(
    join(run, "report.json"),
    JSON.stringify({ checks, frames }, null, 2),
  );
  console.log("Report:", run);
}
