import { approveFixtureClients } from './approval-fixture.mjs';
import { appSecretFixture } from './app-secret-fixture.mjs';
import { fixturePublicKey } from './crypto-fixture.mjs';
import { spawn, spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  mkdirSync,
  writeFileSync,
  appendFileSync,
  readFileSync,
  existsSync,
} from "node:fs";
import { createServer } from "node:http";
import { createServer as tcpServer } from "node:net";
import { delimiter, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import assert from "node:assert/strict";

const root = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const run = join(
  root,
  "work/e2e",
  `creation-${new Date().toISOString().replaceAll(":", "-")}`,
);
const cwd = join(run, "project Unicode 'quote");
const agent = join(run, "agent");
const sessions = join(agent, "sessions", "fixture");
for (const path of [cwd, agent, sessions]) mkdirSync(path, { recursive: true });
writeFileSync(
  join(agent, "settings.json"),
  JSON.stringify({
    quietStartup: true,
    compaction: { enabled: false },
    retry: { enabled: false },
  }),
);
const saved = SessionManager.create(cwd, sessions);
saved.appendMessage({
  role: "user",
  content: [{ type: "text", text: "Historical user message" }],
  timestamp: Date.now(),
});
const usage = {
  input: 0,
  output: 0,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
};
const assistant = {
  role: "assistant",
  api: "openai-completions",
  provider: "pirc-test",
  model: "controlled",
  usage,
  timestamp: Date.now(),
};
saved.appendMessage({
  ...assistant,
  content: [
    { type: "thinking", thinking: "Historical thinking" },
    {
      type: "toolCall",
      id: "saved-tool",
      name: "bash",
      arguments: { command: "echo history" },
    },
  ],
  stopReason: "toolUse",
});
saved.appendMessage({
  role: "toolResult",
  toolCallId: "saved-tool",
  toolName: "bash",
  content: [{ type: "text", text: "Historical tool output" }],
  isError: false,
  timestamp: Date.now(),
});
saved.appendMessage({
  ...assistant,
  content: [{ type: "text", text: "Answer after restoration" }],
  stopReason: "stop",
});
saved.appendSessionInfo("Restoration check");
const pi = spawnSync("command -v pi", {
  shell: true,
  encoding: "utf8",
}).stdout.trim();
assert(pi, "Pi is required");
const quote = (s) => `'${s.replaceAll("'", "'\\''")}'`;
const nativeTerminal = process.env.PIRC_TEST_NATIVE_TERMINAL === "1";
const piPids = join(run, "pi-pids");
const wrapper = join(run, "pi");
writeFileSync(
  wrapper,
  `#!/bin/sh\nprintf '%s\\n' "$$" >> ${quote(piPids)}\nexec ${quote(pi)} --no-extensions --extension ${quote(join(root, "tests/e2e/provider.ts"))} --provider pirc-test --model controlled --no-skills --no-prompt-templates --no-context-files --offline --tui-mode regular "$@"\n`,
  { mode: 0o700 },
);
const socket = `pirc-creation-${randomUUID()}`;
const launches = join(run, "launches.jsonl");
const terminal = join(run, nativeTerminal ? "unused-terminal-fixture" : process.platform === "darwin" ? "open" : "x-terminal-emulator");
writeFileSync(
  terminal,
  `#!${process.execPath}\nimport {spawnSync} from 'node:child_process';\nimport {appendFileSync} from 'node:fs';\nimport {randomUUID} from 'node:crypto';\nconst name='launch-'+randomUUID();\nconst result=spawnSync('tmux',['-L',${JSON.stringify(socket)},'new-session','-d','-s',name,'-x','160','-y','48',process.argv.at(-1).replace(/\\.terminal$/,'.command')],{encoding:'utf8'});\nif(result.status===0)appendFileSync(${JSON.stringify(launches)},JSON.stringify({name})+'\\n');\nprocess.exit(result.status??1);\n`,
  { mode: 0o700 },
);
// Extension-less file is an ESM program because this repository has type=module.
const tcp = tcpServer();
await new Promise((r) => tcp.listen(0, "127.0.0.1", r));
const port = tcp.address().port;
await new Promise((r) => tcp.close(r));
let service, flutter;
let passed = false;
const logs = [];
function stopTestPi(pid) {
  const info = spawnSync(
    "lsof",
    ["-a", "-p", String(pid), "-d", "cwd", "-Fn"],
    { encoding: "utf8" },
  ).stdout;
  if (!info.includes("n" + cwd + "\n")) return;
  process.kill(pid, "SIGTERM");
}
const admin = createServer(async (req, res) => {
  try {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = JSON.parse(Buffer.concat(chunks).toString() || "{}");
    if (req.url === "/assert-alive") {
      const pid = Number(
        readFileSync(piPids, "utf8").trim().split("\n")[body.index],
      );
      process.kill(pid, 0);
      if (!nativeTerminal) {
        const launched = JSON.parse(
          readFileSync(launches, "utf8").trim().split("\n")[body.index],
        );
        assert.equal(
          spawnSync("tmux", ["-L", socket, "has-session", "-t", launched.name])
            .status,
          0,
          "Leaving mobile must keep the terminal alive",
        );
      }
    } else if (req.url === "/assert-closed") {
      const pid = Number(
        readFileSync(piPids, "utf8").trim().split("\n")[body.index],
      );
      const until = Date.now() + 10000;
      let exists = true;
      while (exists && Date.now() < until) {
        try {
          process.kill(pid, 0);
        } catch (error) {
          assert.equal(error.code, "ESRCH");
          exists = false;
        }
        if (exists) await new Promise((r) => setTimeout(r, 50));
      }
      assert.equal(
        exists,
        false,
        "Pi exits after the explicit management confirmation",
      );
      if (!nativeTerminal) {
        const launched = JSON.parse(
          readFileSync(launches, "utf8").trim().split("\n")[body.index],
        );
        assert.notEqual(
          spawnSync("tmux", ["-L", socket, "has-session", "-t", launched.name])
            .status,
          0,
          "Terminal exits with Pi",
        );
      }
    } else if (req.url === "/report")
      writeFileSync(join(run, "checks.json"), JSON.stringify(body, null, 2));
    else throw Error("Unknown action");
    res.writeHead(200);
    res.end("{}");
  } catch (error) {
    res.writeHead(500);
    res.end(String(error));
  }
});
let appSecrets;
try {
  appSecrets = appSecretFixture();
  service = spawn(join(root, "target/debug/pirc"), ["server", "--port", String(port)], {
    env: {
      ...process.env,

      HOME: run,
      PATH: `${run}${delimiter}${process.env.PATH}`,
      PI_CODING_AGENT_DIR: agent,
      PI_TELEMETRY: "0",
      PI_OFFLINE: "1",
      ...(process.platform === "linux" ? { DISPLAY: "pirc-test" } : {}),
    },
  });
  approveFixtureClients(service, root, {...process.env, HOME: run});
  service.stdout.on("data", (b) => logs.push(String(b)));
  service.stderr.on("data", (b) => logs.push(String(b)));
  const deadline = Date.now() + 10000;
  while (true) {
    try {
      if ((await fetch(`http://127.0.0.1:${port}/health`)).ok) break;
    } catch {}
    if (Date.now() > deadline) throw Error("Server did not start");
    await new Promise((r) => setTimeout(r, 50));
  }
  const ws = new WebSocket(`ws://127.0.0.1:${port}/control`);
  const frames = [];
  ws.addEventListener("open", () =>
    ws.send(
      JSON.stringify({
        version: 1,
        request_id: "auth",
        message: { type: "auth" },
      }),
    ),
  );
  ws.addEventListener("message", (e) => frames.push(JSON.parse(e.data)));
  async function wait(predicate) {
    const until = Date.now() + 20000;
    while (!predicate()) {
      if (Date.now() > until) throw Error("Protocol timed out");
      await new Promise((r) => setTimeout(r, 25));
    }
    return predicate();
  }
  const welcome = await wait(() =>
    frames.find((f) => f.message.type === "welcome"),
  );
  async function request(message) {
    const id = randomUUID();
    ws.send(JSON.stringify({ version: 1, request_id: id, message }));
    return (await wait(() => frames.find((f) => f.request_id === id))).message;
  }
  const catalog = await request({ type: "saved_sessions" });
  assert.equal(catalog.type, "saved_session_list", JSON.stringify(catalog));
  assert.equal(catalog.sessions[0].name, "Restoration check");
  assert.equal(catalog.sessions[0].session_id, saved.getSessionId());
  assert.equal(
    (
      await request({
        type: "launch_session",
        generation_id: "old",
        cwd,
        session_id: null,
      })
    ).code,
    "STALE_GENERATION",
  );
  assert.equal(
    (
      await request({
        type: "launch_session",
        generation_id: welcome.message.generation_id,
        cwd: join(run, "missing"),
        session_id: null,
      })
    ).type,
    "error",
  );
  assert.equal(
    existsSync(launches),
    false,
    "Invalid requests never launch a terminal",
  );
  ws.send(
    JSON.stringify({
      version: 1,
      request_id: "legacy-close",
      message: {
        type: "close_session",
        generation_id: welcome.message.generation_id,
        session_id: saved.getSessionId(),
        instance_id: "legacy",
        expected_revision: 0,
      },
    }),
  );
  assert.equal(
    (await wait(() => frames.find((f) => f.message.code === "STALE_INSTANCE")))
      .message.code,
    "STALE_INSTANCE",
    "Exit cannot target a missing or stale Pi instance",
  );
  ws.close();
  await new Promise((r) => ws.addEventListener("close", r, { once: true }));
  await new Promise((r) => admin.listen(0, "127.0.0.1", r));
  flutter = spawn(
    "flutter",
    [
      "test",
      "integration_test/creation_test.dart",
      "-d",
      "macos",
      "--dart-define=PIRC_SECRET_STORE=file",
      `--dart-define=PIRC_SECRET_FILE=${appSecrets.path}`,
      `--dart-define=PIRC_TEST_URL=http://127.0.0.1:${port}`,
      `--dart-define=PIRC_TEST_SERVER_KEY=${fixturePublicKey(join(run,".pirc/server-key"))}`,
      `--dart-define=PIRC_TEST_ADMIN=http://127.0.0.1:${admin.address().port}`,
      `--dart-define=PIRC_TEST_CWD=${cwd}`,
      `--dart-define=PIRC_TEST_SAVED=${saved.getSessionId()}`,
    ],
    { cwd: join(root, "apps/client"), stdio: ["ignore", "pipe", "pipe"] },
  );
  flutter.stdout.on("data", (b) => {
    process.stdout.write(b);
    logs.push(String(b));
  });
  flutter.stderr.on("data", (b) => {
    process.stderr.write(b);
    logs.push(String(b));
  });
  assert.equal(
    await new Promise((r) => flutter.once("exit", r)),
    0,
    "Native creation flow failed",
  );
  assert(logs.join("").includes("All tests passed!"));
  assert.equal(
    readFileSync(nativeTerminal ? piPids : launches, "utf8")
      .trim()
      .split("\n").length,
    2,
    "Restore and create each open exactly one terminal",
  );
  passed = true;
} finally {
  appSecrets?.cleanup();
  if (service && service.exitCode === null) {
    const done = new Promise((r) => service.once("exit", r));
    service.kill("SIGTERM");
    await done;
  }
  spawnSync("tmux", ["-L", socket, "kill-server"]);
  if (nativeTerminal && existsSync(piPids)) {
    for (const pid of readFileSync(piPids, "utf8")
      .trim()
      .split("\n")
      .map(Number))
      stopTestPi(pid);
  }
  admin.close();
  writeFileSync(join(run, "test.log"), logs.join(""));
  writeFileSync(
    join(run, "report.json"),
    JSON.stringify(
      {
        passed,
        isolated: true,
        platform: "macOS",
        pi: "1.1.0",
        terminal: nativeTerminal ? "Terminal.app" : "tmux",
      },
      null,
      2,
    ),
  );
  console.log(`Creation report: ${run}`);
}
