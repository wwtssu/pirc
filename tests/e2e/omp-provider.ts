import { Effort } from "@oh-my-pi/pi-catalog/effort";
import { createAssistantMessageEventStream } from "@oh-my-pi/pi-ai/utils/event-stream";
import { readFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import {
  type AssistantMessage,
  type Model,
  type Api,
  type Context,
  type SimpleStreamOptions,
} from "@oh-my-pi/pi-ai";
import { setTimeout as pause } from "node:timers/promises";

function stream(
  model: Model<Api>,
  context: Context,
  options?: SimpleStreamOptions,
) {
  const s = createAssistantMessageEventStream();
  const output: AssistantMessage = {
    role: "assistant",
    content: [],
    api: model.api,
    provider: model.provider,
    model: model.id,
    stopReason: "stop",
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
      const prompt = (
        last?.role === "user"
          ? typeof last.content === "string"
            ? last.content
            : last.content
                .filter((c) => c.type === "text")
                .map((c) => c.text)
                .join("\n")
          : ""
      )
        .replace(/<system-reminder>[\s\S]*?<\/system-reminder>\s*/g, "")
        .trim();
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
      } else if (prompt === "ASK" || prompt === "ASK_LOCAL") {
        const call = {
          type: "toolCall" as const,
          id: randomUUID(),
          name: "ask",
          arguments: {
            questions: [
              {
                id: "color",
                question: "Choose a color",
                options: [
                  { label: "Red" },
                  { label: "Blue", description: "Calm" },
                ],
                recommended: 1,
              },
              {
                id: "features",
                question: "Select features",
                multi: true,
                options: [{ label: "Ask" }, { label: "Todo" }],
              },
            ],
          },
        };
        if (prompt === "ASK_LOCAL")
          call.arguments.questions = call.arguments.questions.slice(0, 1);
        output.content.push(call);
        output.stopReason = "toolUse";
        s.push({ type: "toolcall_start", contentIndex: 0, partial: output });
        s.push({
          type: "toolcall_end",
          contentIndex: 0,
          toolCall: call,
          partial: output,
        });
      } else if (
        prompt === "TODOTREE" ||
        (last?.role === "toolResult" &&
          last.toolName === "todo" &&
          (last.details as any)?.phases?.[0]?.name === "Design" &&
          (last.details as any)?.op === "init")
      ) {
        const call = {
          type: "toolCall" as const,
          id: randomUUID(),
          name: "todo",
          arguments:
            prompt === "TODOTREE"
              ? {
                  op: "init",
                  list: [
                    {
                      phase: "Design",
                      items: [
                        "Review existing interactions",
                        "Polish tree layout",
                      ],
                    },
                    {
                      phase: "Validation",
                      items: [
                        "Verify OMP integration",
                        "Check history restoration",
                      ],
                    },
                  ],
                }
              : { op: "done", task: "Review existing interactions" },
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
      } else if (
        prompt === "TODO" ||
        (last?.role === "toolResult" &&
          last.toolName === "todo" &&
          (last.details as { op?: string } | undefined)?.op !== "done")
      ) {
        const call = {
          type: "toolCall" as const,
          id: randomUUID(),
          name: "todo",
          arguments:
            prompt === "TODO"
              ? { op: "init", items: ["Verify OMP integration"] }
              : { op: "done", task: "Verify OMP integration" },
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
      } else if (prompt.startsWith("FILE")) {
        const match = prompt.match(/Attached file:\s*("[^\n]+")/);
        if (!match) throw new Error("Missing uploaded file path");
        const call = {
          type: "toolCall" as const,
          id: randomUUID(),
          name: "e2e_file",
          arguments: { path: JSON.parse(match[1]) },
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
      } else if (prompt === "IMAGE") {
        if (
          last?.role !== "user" ||
          !Array.isArray(last.content) ||
          !last.content.some((c) => c.type === "image")
        )
          throw new Error("Image attachment did not reach the provider");
        const call = {
          type: "toolCall" as const,
          id: randomUUID(),
          name: "e2e_image",
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
        const count =
          prompt.startsWith("SLOW") ||
          (last?.role === "toolResult" &&
            last.toolName === "todo" &&
            (last.details as any)?.phases?.[0]?.name === "Design")
            ? 3000
            : 2;
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
  const Type = pi.typebox.Type;
  pi.registerProvider("pirc-test", {
    baseUrl: "http://127.0.0.1",
    apiKey: "test-only",
    api: "pirc-test-api",
    models: [
      {
        id: "controlled",
        name: "pirc controlled test",
        reasoning: false,
        input: ["text", "image"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 1000000,
        maxTokens: 1000,
      },
      {
        id: "fixture-large",
        name: "pirc reasoning test",
        reasoning: true,
        thinking: {
          mode: "budget",
          efforts: [Effort.Low, Effort.High, Effort.Max],
        },
        input: ["text", "image"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 1000000,
        maxTokens: 1000,
      },
    ],
    streamSimple: stream,
  });
  pi.registerProvider("pirc-test-image", {
    baseUrl: "http://127.0.0.1",
    apiKey: "test-only",
    api: "openai-images",
    models: [
      {
        id: "fixture-image",
        name: "Image fixture",
        kind: "image",
        reasoning: false,
        input: ["text", "image"],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: 1000,
        maxTokens: 1000,
      },
    ],
  });
  pi.registerTool({
    name: "e2e_file",
    label: "File fixture",
    description: "Read an uploaded fixture",
    parameters: Type.Object({ path: Type.String() }),
    async execute(_id, args) {
      return {
        content: [{ type: "text", text: await readFile(args.path, "utf8") }],
        details: {},
      };
    },
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
  pi.registerTool({
    name: "e2e_image",
    label: "E2E image",
    description: "Image transport fixture",
    parameters: Type.Object({}),
    async execute() {
      return {
        content: [
          {
            type: "image" as const,
            mimeType: "image/png",
            data: "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAYAAACp8Z5+AAAAEklEQVR4nGP4XzDhPzJmIF0AAFteL+Hl/kTRAAAAAElFTkSuQmCC",
          },
        ],
        details: {},
      };
    },
  });
  pi.registerCommand("test-dialog", {
    description: "Local UI fixture",
    async handler(_args, ctx) {
      await ctx.ui.confirm("Confirm fixture", "Confirm locally");
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
      await ctx.branch(entry.id);
    },
  });
}
