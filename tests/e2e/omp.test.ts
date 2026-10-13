import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setTimeout as pause } from "node:timers/promises";
import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import extension from "../../extensions/omp/index.ts";
import {
  executeBuiltin,
  thinkingLevels,
  controls,
} from "../../extensions/omp/builtins.ts";
import {
  listSavedSessions,
  sessionsRoot,
} from "../../extensions/omp/sessions.mjs";

test("OMP history reads its title slot without parsing large message bodies", async () => {
  const folder = await mkdtemp(join(tmpdir(), "pirc-omp-history-"));
  try {
    await mkdir(join(folder, "project"));
    const file = join(folder, "project", "saved.jsonl");
    await writeFile(
      file,
      [
        { type: "title", title: "Current name", pad: "" },
        {
          type: "session",
          id: "omp-history",
          cwd: "/workspace",
          title: "Old name",
        },
      ]
        .map((e) => JSON.stringify(e))
        .join("\n") +
        "\n" +
        JSON.stringify({ type: "message", text: "x".repeat(100000) }),
    );
    const saved = await listSavedSessions(folder);
    assert.equal(saved.length, 1);
    assert.equal(saved[0].agent_id, "omp");
    assert.equal(saved[0].name, "Current name");
    assert.equal(saved[0].path, file);
    await writeFile(
      file,
      [
        { type: "title", title: "", pad: "" },
        {
          type: "session",
          id: "omp-history",
          cwd: "/workspace",
          title: "Old name",
        },
      ]
        .map((e) => JSON.stringify(e))
        .join("\n"),
    );
    assert.equal((await listSavedSessions(folder))[0].name, null);
    assert.equal(
      sessionsRoot({ OMP_PROFILE: "work" }, "/example", "win32"),
      join("/example", ".omp/profiles/work/agent/sessions"),
    );
    assert.equal(
      sessionsRoot({ PI_CODING_AGENT_DIR: folder }, "/example", "linux"),
      join(folder, "sessions"),
    );
    assert.throws(() => sessionsRoot({ OMP_PROFILE: "../escape" }, "/example"));
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
});

test("OMP controls use its native resolver, model effort metadata and async naming", async () => {
  let name = "Before",
    level: string | undefined;
  const reasoning: any = {
    provider: "test",
    id: "model",
    name: "Model",
    reasoning: true,
    thinking: { efforts: ["high", "max"] },
    input: ["text", "image"],
    contextWindow: null,
    kind: "chat",
  };
  let model = reasoning;
  const ctx = {
    cwd: "/workspace",
    models: {
      current: () => model,
      list: () => [
        model,
        { ...model, id: "tiny", kind: "tiny" },
        { ...model, id: "image-only", kind: "image" },
      ],
      resolve: (spec: string) => (spec === "@slow" ? reasoning : undefined),
    },
    getContextUsage: () => undefined,
    sessionManager: {
      getSessionId: () => "s",
      getSessionName: () => name,
      getSessionFile: () => "/session.jsonl",
      getBranch: () => [],
    },
    compact: async () => {
      throw Error("fixture compaction failed");
    },
  } as unknown as ExtensionContext;
  const api = {
    getThinkingLevel: () => level,
    setThinkingLevel: (value: string) => (level = value),
    setModel: async (value: any) => {
      model = value;
      return true;
    },
    getSessionName: () => name,
    setSessionName: async (value: string) => {
      await pause(1);
      name = value;
    },
  } as unknown as ExtensionAPI;
  assert.deepEqual(thinkingLevels(ctx), ["off", "high", "max"]);
  const models = await executeBuiltin(api, ctx, "model", "");
  assert.equal(models.kind, "model");
  if (models.kind === "model") {
    assert.equal(models.models.length, 2);
    assert.equal(models.current?.context_window, 0);
  }
  await executeBuiltin(api, ctx, "model", "@slow");
  await executeBuiltin(api, ctx, "thinking", "max");
  assert.equal(controls(api, ctx, false).thinking_level, "max");
  await assert.rejects(
    executeBuiltin(api, ctx, "thinking", "low"),
    /Supported thinking levels/,
  );
  const renamed = await executeBuiltin(api, ctx, "name", "After");
  assert.deepEqual(renamed, { kind: "name", name: "After" });
  await assert.rejects(
    executeBuiltin(api, ctx, "compact", ""),
    /fixture compaction failed/,
  );
  ctx.compact = async (options) => {
    if (options && typeof options === "object")
      options.onError?.(new Error("Nothing to compact"));
  };
  await assert.rejects(
    executeBuiltin(api, ctx, "compact", ""),
    /Nothing to compact/,
  );
  ctx.compact = async () => {};
  await assert.rejects(
    executeBuiltin(api, ctx, "compact", ""),
    /did not produce a summary/,
  );
});

test("OMP normalizes terminal settle, approvals, session switches and subagent isolation", async () => {
  const previous = globalThis.WebSocket;
  const previousURL = process.env.PIRC_URL;
  process.env.PIRC_URL = "ws://127.0.0.1:43123/extension";
  class Socket extends EventTarget {
    static OPEN = 1;
    static current: Socket;
    static all: Socket[] = [];
    readyState = 1;
    bufferedAmount = 0;
    frames: any[] = [];
    constructor() {
      super();
      Socket.current = this;
      Socket.all.push(this);
    }
    send(raw: string) {
      this.frames.push(JSON.parse(raw));
    }
    close() {
      this.readyState = 3;
    }
    receive(message: any, id = "request") {
      this.dispatchEvent(
        new MessageEvent("message", {
          data: JSON.stringify({ version: 1, request_id: id, message }),
        }),
      );
    }
  }
  globalThis.WebSocket = Socket as unknown as typeof WebSocket;
  const handlers = new Map<string, ((e: any, ctx: any) => any)[]>();
  let sid = "first",
    name = "First";
  const model: any = {
    provider: "test",
    id: "m",
    name: "M",
    reasoning: false,
    input: ["text"],
    contextWindow: 10000,
  };
  const ctx: any = {
    agent: { kind: "main" },
    cwd: "/workspace",
    model,
    models: { current: () => model, list: () => [model] },
    sessionManager: {
      getSessionId: () => sid,
      getSessionName: () => name,
      getBranch: () => [],
    },
    isIdle: () => true,
    hasPendingMessages: () => false,
    getContextUsage: () => undefined,
    ui: { notify() {} },
  };
  const api = {
    on: (name: string, h: any) =>
      handlers.set(name, [...(handlers.get(name) ?? []), h]),
    getCommands: () => [],
    getSessionName: () => name,
    setSessionName: async (v: string) => {
      name = v;
    },
    getThinkingLevel: () => undefined,
    sendUserMessage() {},
  } as unknown as ExtensionAPI;
  const emit = async (name: string, e: any = {}, context: any = ctx) => {
    for (const h of handlers.get(name) ?? []) await h(e, context);
  };
  const latest = (socket: Socket) =>
    socket.frames.findLast((f) =>
      ["register", "snapshot", "heartbeat"].includes(f.message.type),
    )?.message.session;
  try {
    extension(api);
    await emit("session_start", {}, { ...ctx, agent: { kind: "sub" } });
    assert.equal(Socket.all.length, 0);
    await emit("session_start");
    const first = Socket.current;
    first.receive({ type: "welcome", generation_id: "g" });
    await pause(1);
    assert.equal(latest(first).agent_id, "omp");
    await emit("agent_start");
    await emit("agent_end", { willContinue: true });
    assert.equal(latest(first).state, "running");
    await emit("agent_end", { willContinue: false });
    await pause(1);
    assert.equal(latest(first).state, "idle");
    await emit("tool_approval_requested", {
      toolCallId: "a",
      toolName: "bash",
    });
    await emit("tool_approval_requested", {
      toolCallId: "b",
      toolName: "write",
    });
    assert.equal(latest(first).needs_local_attention, true);
    await emit("tool_approval_resolved", { toolCallId: "a" });
    assert.equal(latest(first).needs_local_attention, true);
    await emit("tool_approval_resolved", { toolCallId: "b" });
    assert.equal(latest(first).needs_local_attention, false);
    sid = "second";
    await emit("session_switch");
    const second = Socket.current;
    second.receive({ type: "welcome", generation_id: "g" });
    await pause(1);
    assert.notEqual(latest(first).instance_id, latest(second).instance_id);
    assert.equal(latest(second).session_id, "second");
  } finally {
    await emit("session_shutdown");
    globalThis.WebSocket = previous;
    if (previousURL === undefined) delete process.env.PIRC_URL;
    else process.env.PIRC_URL = previousURL;
  }
});
