import { test } from "node:test";
import assert from "node:assert/strict";
import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import {
  builtinCommands,
  controls,
  executeBuiltin,
  sessionInfo,
} from "../../extensions/pi/builtins.ts";
import { decode } from "../../extensions/pi/protocol.ts";

function fixture() {
  let name: string | undefined;
  let level = "off";
  let selected = {
    provider: "fixture",
    id: "reasoning",
    name: "Reasoning",
    reasoning: true,
    contextWindow: 100000,
  };
  let compact: Parameters<ExtensionContext["compact"]>[0];
  const plain = { ...selected, id: "plain", reasoning: false };
  const pi = {
    getThinkingLevel: () => level,
    setThinkingLevel: (value: string) => {
      level = value;
    },
    getSessionName: () => name,
    setSessionName: (value: string) => {
      name = value;
    },
    setModel: async (model: typeof selected) => {
      selected = model;
      return true;
    },
  } as unknown as ExtensionAPI;
  const ctx = {
    get model() {
      return selected;
    },
    cwd: "/tmp/fixture",
    modelRegistry: {
      getAvailable: () => [selected, plain],
      find: (provider: string, id: string) =>
        provider === "fixture"
          ? [selected, plain].find((m) => m.id === id)
          : undefined,
    },
    sessionManager: {
      getSessionId: () => "s",
      getSessionFile: () => undefined,
      getEntries: () => [
        { type: "message", message: { role: "user" } },
        {
          type: "message",
          message: {
            role: "assistant",
            content: [{ type: "toolCall" }],
            usage: {
              input: 10,
              output: 2,
              cacheRead: 3,
              cacheWrite: 4,
              cost: { total: 0.01 },
            },
          },
        },
        {
          type: "message",
          message: {
            role: "toolResult",
            usage: { input: 1, cost: { total: 0.02 } },
          },
        },
        { type: "compaction", usage: { output: 5, cost: { total: 0.03 } } },
      ],
    },
    getContextUsage: () => ({
      tokens: null,
      contextWindow: 100000,
      percent: null,
    }),
    compact: (options: typeof compact) => {
      compact = options;
    },
  } as unknown as ExtensionContext;
  return {
    pi,
    ctx,
    finish: () =>
      compact?.onComplete?.({
        summary: "summary",
        tokensBefore: 2000,
        firstKeptEntryId: "e",
      }),
    fail: () => compact?.onError?.(new Error("Nothing to compact")),
  };
}

test("only the five selected builtins are advertised and accepted by the protocol", () => {
  assert.deepEqual(
    builtinCommands.map((c) => c.name),
    ["model", "thinking", "name", "session", "compact"],
  );
  const envelope = {
    version: 1,
    request_id: "r",
    message: {
      type: "builtin",
      generation_id: "g",
      session_id: "s",
      instance_id: "i",
      expected_revision: 0,
      command: "model",
      args: "",
    },
  };
  assert.ok(decode(JSON.stringify(envelope)));
  assert.equal(
    decode(
      JSON.stringify({
        ...envelope,
        message: { ...envelope.message, command: "reload" },
      }),
    ),
    null,
  );
});
test("model lookup, model-specific thinking levels and rename use Pi controls", async () => {
  const { pi, ctx } = fixture();
  const menu = await executeBuiltin(pi, ctx, "model", "");
  assert.equal(menu.kind, "model");
  await executeBuiltin(pi, ctx, "thinking", "high");
  assert.equal(controls(pi, ctx, false).thinking_level, "high");
  await executeBuiltin(pi, ctx, "model", "fixture/plain");
  assert.deepEqual(controls(pi, ctx, false).thinking_levels, ["off"]);
  await assert.rejects(
    executeBuiltin(pi, ctx, "thinking", "high"),
    /Supported thinking levels/,
  );
  await assert.rejects(
    executeBuiltin(pi, ctx, "model", "missing/model"),
    /Model not found/,
  );
  assert.deepEqual(await executeBuiltin(pi, ctx, "name", "Unicode session"), {
    kind: "name",
    name: "Unicode session",
  });
  await assert.rejects(executeBuiltin(pi, ctx, "name", "a\nb"), /single line/);
});
test("session totals include tool and compaction usage and preserve unknown context size", () => {
  const { pi, ctx } = fixture();
  const info = sessionInfo(pi, ctx);
  assert.equal(info.total_messages, 3);
  assert.equal(info.tool_calls, 1);
  assert.equal(info.input_tokens, 11);
  assert.equal(info.output_tokens, 7);
  assert.equal(info.cache_read_tokens, 3);
  assert.equal(info.cache_write_tokens, 4);
  assert.equal(info.cost_usd, "0.060000");
  assert.equal(info.context_tokens, null);
});
test("Pi's unavailable placeholder is not exposed or accepted as a selected model", async () => {
  const { pi, ctx } = fixture();
  Object.defineProperty(ctx, "model", {
    value: {
      provider: "unknown",
      id: "unknown",
      name: "unknown",
      api: "unknown",
    },
  });
  assert.equal(controls(pi, ctx, false).model, null);
  assert.deepEqual(controls(pi, ctx, false).thinking_levels, []);
  const menu = await executeBuiltin(pi, ctx, "model", "");
  assert.equal(menu.kind, "model");
  if (menu.kind === "model") assert.equal(menu.current, null);
  for (const command of ["thinking", "compact"] as const) {
    await assert.rejects(executeBuiltin(pi, ctx, command, ""), {
      code: "NO_MODEL",
    });
  }
});
test("compaction completes only on Pi's callback and propagates failure", async () => {
  const f = fixture();
  let completed = false;
  const operation = executeBuiltin(f.pi, f.ctx, "compact", "Keep the task requirements").then(
    (data) => {
      completed = true;
      return data;
    },
  );
  await Promise.resolve();
  assert.equal(completed, false);
  f.finish();
  assert.equal((await operation).kind, "compact");
  const failed = executeBuiltin(f.pi, f.ctx, "compact", "");
  f.fail();
  await assert.rejects(failed, /Nothing to compact/);
});
