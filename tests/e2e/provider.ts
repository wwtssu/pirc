import { randomUUID } from "node:crypto";
import { Type } from "typebox";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  createAssistantMessageEventStream,
  type AssistantMessage,
  type Model,
  type Api,
  type TranscriptContext,
  type SimpleStreamOptions,
} from "@earendil-works/pi-ai";
import { setTimeout as pause } from "node:timers/promises";

function stream(
  model: Model<Api>,
  context: TranscriptContext,
  options?: SimpleStreamOptions,
) {
  const s = createAssistantMessageEventStream();
  const output: AssistantMessage = {
    role: "assistant",
    content: [],
    api: model.api,
    provider: model.provider,
    model: model.id,
    stopReason: "pending",
    timestamp: Date.now(),
    usage: {
      input: 10,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 10,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
    },
  };
  void (async () => {
    try {
      const last = context.messages.at(-1);
      const prompt =
        last?.role === "user"
          ? typeof last.content === "string"
            ? last.content
            : last.content
                .filter((c) => c.type === "text")
                .map((c) => c.text)
                .join("\n")
          : "";
      s.push({ type: "start", partial: output });
      if (prompt.startsWith("STREAM")) {
        await pause(400, undefined, { signal: options?.signal });
        const thinking = { type: "thinking" as const, thinking: "" };
        output.content.push(thinking);
        s.push({ type: "thinking_start", contentIndex: 0, partial: output });
        for (const delta of ["Check first", "Streaming tool output"]) {
          await pause(350, undefined, { signal: options?.signal });
          thinking.thinking += delta;
          s.push({
            type: "thinking_delta",
            contentIndex: 0,
            delta,
            partial: output,
          });
        }
        // Deliberately omit thinking_end: answering must finish its indicator
        // even when a provider only finalizes thinking at message_end.
        const before = { type: "text" as const, text: "Starting tool" };
        output.content.push(before);
        s.push({ type: "text_start", contentIndex: 1, partial: output });
        s.push({
          type: "text_delta",
          contentIndex: 1,
          delta: before.text,
          partial: output,
        });
        await pause(500, undefined, { signal: options?.signal });
        s.push({
          type: "text_end",
          contentIndex: 1,
          content: before.text,
          partial: output,
        });
        const call = {
          type: "toolCall" as const,
          id: randomUUID(),
          name: "e2e_stream",
          arguments: {},
        };
        output.content.push(call);
        s.push({ type: "toolcall_start", contentIndex: 2, partial: output });
        for (const delta of ['{"label":', '"live"}']) {
          await pause(350, undefined, { signal: options?.signal });
          s.push({
            type: "toolcall_delta",
            contentIndex: 2,
            delta,
            partial: output,
          });
        }
        call.arguments = { label: "live" };
        s.push({
          type: "toolcall_end",
          contentIndex: 2,
          toolCall: call,
          partial: output,
        });
        const after = { type: "text" as const, text: "Arguments ready" };
        output.content.push(after);
        s.push({ type: "text_start", contentIndex: 3, partial: output });
        s.push({
          type: "text_delta",
          contentIndex: 3,
          delta: after.text,
          partial: output,
        });
        s.push({
          type: "text_end",
          contentIndex: 3,
          content: after.text,
          partial: output,
        });
        output.stopReason = "toolUse";
      } else if (prompt.startsWith("TOOL")) {
        const call = {
          type: "toolCall" as const,
          id: randomUUID(),
          name: "e2e_wait",
          arguments: {},
        };
        output.content.push(call);
        output.stopReason = "toolUse";
        s.push({ type: "toolcall_start", contentIndex: 0, partial: output });
        s.push({
          type: "toolcall_end",
          contentIndex: 0,
          toolCall: call,
          partial: output,
        });
      } else {
        const block = { type: "text" as const, text: "" };
        output.content.push(block);
        s.push({ type: "text_start", contentIndex: 0, partial: output });
        const count = prompt.startsWith("SLOW") ? 300 : 2;
        for (let i = 0; i < count; i++) {
          await pause(50, undefined, { signal: options?.signal });
          const delta = i === 0 ? `reply:${prompt || "tool finished"} ` : ".";
          block.text += delta;
          s.push({
            type: "text_delta",
            contentIndex: 0,
            delta,
            partial: output,
          });
        }
        s.push({
          type: "text_end",
          contentIndex: 0,
          content: block.text,
          partial: output,
        });
        output.stopReason = "stop";
      }
      output.usage.output = 1;
      output.usage.totalTokens = 11;
      s.push({
        type: "done",
        reason: output.stopReason as "stop" | "toolUse",
        message: output,
      });
      s.end();
    } catch (err) {
      output.stopReason = options?.signal?.aborted ? "aborted" : "error";
      output.errorMessage = String(err);
      s.push({ type: "error", reason: output.stopReason, error: output });
      s.end();
    }
  })();
  return s;
}
export default function (pi: ExtensionAPI) {
  pi.registerProvider("pirc-test", {
    baseUrl: "http://127.0.0.1",
    apiKey: "test-only",
    api: "pirc-test-api",
    models: [
      {
        id: "controlled",
        name: "pirc controlled test",
        reasoning: false,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 1000000,
        maxTokens: 1000,
      },
      {
        id: "controlled-reasoning",
        name: "pirc reasoning test",
        reasoning: true,
        input: ["text"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 1000000,
        maxTokens: 1000,
      },
    ],
    streamSimple: stream,
  });
  pi.registerTool({
    name: "e2e_stream",
    label: "E2E streaming",
    description: "Streaming output test tool",
    parameters: Type.Object({ label: Type.String() }),
    async execute(_id, _args, signal, onUpdate) {
      let text = "";
      for (let i = 1; i <= 3; i++) {
        await pause(400, undefined, { signal });
        text += `${i === 1 ? "" : "\n"}Tool output ${i}`;
        onUpdate?.({ content: [{ type: "text", text }], details: {} });
      }
      await pause(400, undefined, { signal });
      return { content: [{ type: "text", text }], details: {} };
    },
  });
  pi.registerTool({
    name: "e2e_wait",
    label: "E2E wait",
    description: "Cancellable test tool",
    parameters: Type.Object({}),
    async execute(_id, _args, signal) {
      await pause(30000, undefined, { signal });
      return {
        content: [{ type: "text", text: "wait completed" }],
        details: {},
      };
    },
  });
  pi.registerCommand("test-resume", {
    description: "Resume fixture session",
    async handler(path, ctx) {
      await ctx.switchSession(path);
    },
  });
  pi.registerCommand("test-fork", {
    description: "Fork fixture session",
    async handler(_args, ctx) {
      const entry = ctx.sessionManager
        .getEntries()
        .find((e) => e.type === "message" && e.message.role === "user");
      if (!entry) throw new Error("No user entry");
      await ctx.fork(entry.id);
    },
  });
}
