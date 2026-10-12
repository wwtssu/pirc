import { test } from "node:test";
import assert from "node:assert/strict";
import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import extension from "../../extensions/pi/index.ts";

test("new server generations rebuild durable history and unfinished streams without replaying on ordinary reconnect", async () => {
  const original = globalThis.WebSocket;
  const keys = ["PIRC_CONFIG", "PIRC_URL"];
  const saved = keys.map((key) => process.env[key]);
  class Socket extends EventTarget {
    static OPEN = 1;
    static current: Socket;
    readyState = 1;
    bufferedAmount = 0;
    frames: any[] = [];
    constructor() {
      super();
      Socket.current = this;
    }
    send(value: string) {
      this.frames.push(JSON.parse(value));
    }
    close() {
      this.readyState = 3;
    }
    welcome(generation: string) {
      this.dispatchEvent(
        new MessageEvent("message", {
          data: JSON.stringify({
            version: 1,
            request_id: "welcome",
            message: { type: "welcome", generation_id: generation },
          }),
        }),
      );
    }
    events() {
      return this.frames
        .filter((f) => f.message.type === "event")
        .map((f) => f.message);
    }
  }
  globalThis.WebSocket = Socket as unknown as typeof WebSocket;
  const hooks = new Map<string, (...args: any[]) => any>();
  const branch: any[] = [
    {
      type: "message",
      id: "user-saved",
      message: { role: "user", content: "saved prompt" },
    },
    {
      type: "message",
      id: "answer-saved",
      message: {
        role: "assistant",
        stopReason: "stop",
        content: [
          { type: "thinking", thinking: "saved thinking" },
          { type: "text", text: "saved answer" },
          {
            type: "toolCall",
            id: "saved-tool",
            name: "bash",
            arguments: { command: "echo saved" },
          },
        ],
      },
    },
    {
      type: "message",
      id: "result-saved",
      message: {
        role: "toolResult",
        toolCallId: "saved-tool",
        toolName: "bash",
        content: [{ type: "text", text: "saved output" }],
        isError: false,
      },
    },
  ];
  branch.push(
    {
      type: "message",
      id: "plugin-visible",
      message: {
        role: "custom",
        customType: "fixture",
        content: "Visible plugin message",
        display: true,
      },
    },
    {
      type: "message",
      id: "plugin-hidden",
      message: {
        role: "custom",
        customType: "fixture",
        content: "Hidden plugin message",
        display: false,
      },
    },
    {
      type: "message",
      id: "shell-local",
      message: {
        role: "bashExecution",
        command: "printf fixture",
        output: "fixture shell output",
        exitCode: 0,
        cancelled: false,
        truncated: false,
      },
    },
  );
  let busy = false;
  const pi = {
    on: (key: string, handler: (...args: any[]) => any) =>
      hooks.set(key, handler),
    getSessionName: () => null,
    getCommands: () => [],
    getThinkingLevel: () => "off",
  } as unknown as ExtensionAPI;
  const ctx = {
    cwd: "/tmp",
    sessionManager: { getSessionId: () => "session", getBranch: () => branch },
    isIdle: () => !busy,
    hasPendingMessages: () => false,
    ui: { notify: () => {} },
  } as unknown as ExtensionContext;
  try {
    process.env.PIRC_CONFIG = "/nonexistent/pirc-history-test.json";
    process.env.PIRC_URL = "ws://127.0.0.1:43123/extension";
    extension(pi);
    hooks.get("session_start")!({}, ctx);
    const ws = Socket.current;
    ws.welcome("first");
    const initialInstance = ws.frames.find((f) => f.message.type === "register")
      .message.session.instance_id;
    assert.equal(
      ws.events().filter((e) => e.event.text === "saved answer").length,
      1,
    );
    assert(ws.events().some((e) => e.event.text === "saved thinking"));
    assert(ws.events().some((e) => e.event.text === "Visible plugin message"));
    assert(!ws.events().some((e) => e.event.text === "Hidden plugin message"));
    assert(
      ws
        .events()
        .some(
          (e) =>
            e.event.tool_name === "bash" &&
            e.event.text === "fixture shell output",
        ),
    );

    hooks.get("ui_prompt_start")!({ kind: "confirm", title: "Allow action?" });
    assert.deepEqual(
      ws.frames.filter((f) => f.message.type === "snapshot").at(-1).message
        .session.ui_prompt,
      { kind: "confirm", title: "Allow action?" },
    );
    hooks.get("ui_prompt_end")!({ kind: "confirm" });
    assert.equal(
      ws.frames.filter((f) => f.message.type === "snapshot").at(-1).message
        .session.ui_prompt,
      undefined,
    );
    assert(ws.events().some((e) => e.event.text === "saved output"));
    const before = ws.events().length;
    ws.welcome("first");
    assert.equal(ws.events().length, before);
    busy = true;
    hooks.get("agent_start")!();
    hooks.get("message_start")!({ message: { role: "assistant" } });
    hooks.get("message_update")!({
      assistantMessageEvent: {
        type: "thinking_delta",
        contentIndex: 0,
        delta: "unfinished thought",
        partial: { content: [] },
      },
    });
    hooks.get("message_update")!({
      assistantMessageEvent: {
        type: "text_delta",
        contentIndex: 1,
        delta: "unfinished answer",
        partial: { content: [] },
      },
    });
    hooks.get("tool_execution_start")!({
      toolCallId: "running-tool",
      toolName: "bash",
      args: { command: "sleep 5" },
    });
    hooks.get("tool_execution_update")!({
      toolCallId: "running-tool",
      toolName: "bash",
      partialResult: { content: [{ type: "text", text: "partial output" }] },
    });
    const mark = ws.frames.length;
    ws.welcome("second");
    const replay = ws.frames
      .slice(mark)
      .filter((f) => f.message.type === "event")
      .map((f) => f.message);
    assert.equal(replay[0].source_seq, 1);
    assert.deepEqual(
      replay.map((e) => e.source_seq),
      replay.map((_, i) => i + 1),
    );
    for (const value of [
      "saved prompt",
      "saved thinking",
      "saved answer",
      "saved output",
      "unfinished thought",
      "unfinished answer",
      "partial output",
    ])
      assert.equal(
        replay.filter((e) => e.event.text === value).length,
        1,
        value,
      );
    assert(!replay.some((e) => e.event.kind === "agent_settled"));
    assert.equal(
      ws.frames.filter((f) => f.message.type === "snapshot").at(-1).message
        .session.state,
      "running",
    );
    // New deltas remain live after reconstruction and continue its sequence.
    hooks.get("message_update")!({
      assistantMessageEvent: {
        type: "text_delta",
        contentIndex: 1,
        delta: " continues",
        partial: { content: [] },
      },
    });
    assert.equal(ws.events().at(-1).source_seq, replay.length + 1);
    assert.equal(ws.events().at(-1).event.text, " continues");
    // Backpressure yields; live updates queue after the captured historical tail.
    ws.bufferedAmount = 200000;
    const start = ws.frames.length;
    ws.welcome("third");
    hooks.get("message_update")!({
      assistantMessageEvent: {
        type: "text_delta",
        contentIndex: 1,
        delta: " queued",
        partial: { content: [] },
      },
    });
    ws.bufferedAmount = 0;
    await new Promise((resolve) => setTimeout(resolve, 30));
    const resumed = ws.frames
      .slice(start)
      .filter((f) => f.message.type === "event")
      .map((f) => f.message);
    assert.equal(resumed.filter((e) => e.event.text === " queued").length, 1);
    assert.equal(resumed.at(-1).event.text, " queued");
    assert.deepEqual(
      resumed.map((e) => e.source_seq),
      resumed.map((_, i) => i + 1),
    );
    // Completed messages use the session file and no longer replay transient deltas.
    branch.push({
      type: "message",
      id: "finished",
      message: {
        role: "assistant",
        stopReason: "stop",
        content: [{ type: "text", text: "complete answer" }],
      },
    });
    hooks.get("message_end")!({ message: branch.at(-1).message });
    hooks.get("tool_execution_end")!({
      toolCallId: "running-tool",
      toolName: "bash",
      result: { content: [] },
      isError: false,
    });
    busy = false;
    hooks.get("agent_settled")!();
    const finished = ws.frames.length;
    ws.welcome("fourth");
    const final = ws.frames
      .slice(finished)
      .filter((f) => f.message.type === "event")
      .map((f) => f.message.event);
    assert.equal(final.filter((e) => e.text === "complete answer").length, 1);
    assert(!final.some((e) => e.text === "unfinished answer"));
    assert(final.some((e) => e.kind === "agent_settled"));
    hooks.get("session_start")!(
      { reason: "new" },
      {
        ...ctx,
        sessionManager: {
          getSessionId: () => "next-session",
          getBranch: () => [],
        },
      },
    );
    const nextSocket = Socket.current;
    nextSocket.welcome("fourth");
    const next = nextSocket.frames.find((f) => f.message.type === "register")
      .message.session;
    assert.equal(next.session_id, "next-session");
    assert.notEqual(next.instance_id, initialInstance);
    assert(
      ws.frames.some(
        (f) =>
          f.message.type === "unregister" &&
          f.message.instance_id === initialInstance,
      ),
    );
  } finally {
    hooks.get("session_shutdown")?.();
    globalThis.WebSocket = original;
    keys.forEach((key, i) => {
      if (saved[i] === undefined) delete process.env[key];
      else process.env[key] = saved[i];
    });
  }
});
