import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import {
  getSupportedThinkingLevels,
  type Api,
  type Model,
} from "@earendil-works/pi-ai";
import type { BuiltinCommand } from "../../packages/protocol/generated/BuiltinCommand.ts";
import type { CommandData } from "../../packages/protocol/generated/CommandData.ts";
import type { SessionControls } from "../../packages/protocol/generated/SessionControls.ts";
import type { SessionInfo } from "../../packages/protocol/generated/SessionInfo.ts";
import type { SlashCommand } from "../../packages/protocol/generated/SlashCommand.ts";

export const builtinCommands: SlashCommand[] = [
  { name: "model", description: "Select the model for this session", source: "builtin" },
  { name: "thinking", description: "Adjust the thinking level", source: "builtin" },
  { name: "name", description: "Rename the session", source: "builtin" },
  { name: "session", description: "View session information and usage", source: "builtin" },
  {
    name: "compact",
    description: "Compact context with optional instructions",
    source: "builtin",
  },
];
export class BuiltinError extends Error {
  readonly code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}
export function modelInfo(model: Model<Api>) {
  return {
    provider: model.provider,
    id: model.id,
    name: model.name,
    reasoning: model.reasoning,
    context_window: model.contextWindow,
  };
}
function selectedModel(ctx: ExtensionContext): Model<Api> | undefined {
  const model = ctx.model;
  return model?.provider === "unknown" &&
    model.id === "unknown" &&
    String(model.api) === "unknown"
    ? undefined
    : model;
}
export function controls(
  pi: ExtensionAPI,
  ctx: ExtensionContext,
  compacting: boolean,
): SessionControls {
  const model = selectedModel(ctx);
  return {
    model: model ? modelInfo(model) : null,
    thinking_level: pi.getThinkingLevel(),
    thinking_levels: model ? getSupportedThinkingLevels(model) : [],
    compacting,
  };
}

export function sessionInfo(
  pi: ExtensionAPI,
  ctx: ExtensionContext,
): SessionInfo {
  const info: SessionInfo = {
    session_id: ctx.sessionManager.getSessionId(),
    name: pi.getSessionName() ?? null,
    cwd: ctx.cwd,
    session_file: ctx.sessionManager.getSessionFile() ?? null,
    user_messages: 0,
    assistant_messages: 0,
    tool_calls: 0,
    tool_results: 0,
    total_messages: 0,
    input_tokens: 0,
    output_tokens: 0,
    cache_read_tokens: 0,
    cache_write_tokens: 0,
    cost_usd: "0",
    context_tokens: ctx.getContextUsage()?.tokens ?? null,
    context_window:
      ctx.getContextUsage()?.contextWindow ?? ctx.model?.contextWindow ?? 0,
  };
  let cost = 0;
  const addUsage = (value: unknown) => {
    if (!value || typeof value !== "object") return;
    const usage = value as Record<string, unknown>;
    for (const [from, to] of [
      ["input", "input_tokens"],
      ["output", "output_tokens"],
      ["cacheRead", "cache_read_tokens"],
      ["cacheWrite", "cache_write_tokens"],
    ] as const) {
      const n = usage[from];
      if (typeof n === "number" && Number.isFinite(n) && n >= 0)
        info[to] = Math.min(Number.MAX_SAFE_INTEGER, info[to] + Math.floor(n));
    }
    const total = (usage.cost as { total?: unknown } | undefined)?.total;
    if (typeof total === "number" && Number.isFinite(total) && total >= 0)
      cost += total;
  };
  // Match Pi's session totals: include side branches and compaction/tool usage.
  for (const entry of ctx.sessionManager.getEntries()) {
    if (
      entry.type === "usage" ||
      entry.type === "compaction" ||
      entry.type === "branch_summary"
    )
      addUsage(entry.usage);
    if (entry.type !== "message") continue;
    info.total_messages++;
    const message = entry.message;
    if (message.role === "user") info.user_messages++;
    if (message.role === "toolResult") {
      info.tool_results++;
      addUsage(message.usage);
    }
    if (message.role === "assistant") {
      info.assistant_messages++;
      info.tool_calls += message.content.filter(
        (c) => c.type === "toolCall",
      ).length;
      addUsage(message.usage);
    }
  }
  info.cost_usd = cost.toFixed(6);
  return info;
}

export async function executeBuiltin(
  pi: ExtensionAPI,
  ctx: ExtensionContext,
  command: BuiltinCommand,
  rawArgs: string,
): Promise<CommandData> {
  const args = rawArgs.trim();
  switch (command) {
    case "model": {
      if (args) {
        const separator = args.indexOf("/");
        const model =
          separator > 0
            ? ctx.modelRegistry.find(
                args.slice(0, separator),
                args.slice(separator + 1),
              )
            : undefined;
        if (!model)
          throw new BuiltinError(
            "MODEL_NOT_FOUND",
            "Model not found. Select one from the list.",
          );
        if (!(await pi.setModel(model)))
          throw new BuiltinError(
            "MODEL_AUTH_REQUIRED",
            "Set up authentication for this model on the device first.",
          );
      }
      const model = selectedModel(ctx);
      return {
        kind: "model",
        current: model ? modelInfo(model) : null,
        models: args ? [] : ctx.modelRegistry.getAvailable().map(modelInfo),
      };
    }
    case "thinking": {
      const model = selectedModel(ctx);
      if (!model) throw new BuiltinError("NO_MODEL", "Select a model first");
      const levels = getSupportedThinkingLevels(model);
      if (args) {
        const level = levels.find((l) => l === args.toLowerCase());
        if (!level)
          throw new BuiltinError(
            "INVALID_THINKING_LEVEL",
            `Supported thinking levels: ${levels.join(", ")}`,
          );
        pi.setThinkingLevel(level);
      }
      return { kind: "thinking", level: pi.getThinkingLevel(), levels };
    }
    case "name":
      if (args) {
        if (args.length > 256 || /[\r\n\x00]/.test(args))
          throw new BuiltinError(
            "INVALID_ARGUMENT",
            "Name must be a single line of at most 256 characters",
          );
        pi.setSessionName(args);
      }
      return { kind: "name", name: pi.getSessionName() ?? null };
    case "session":
      if (args)
        throw new BuiltinError("INVALID_ARGUMENT", "/session does not accept arguments");
      return { kind: "session", info: sessionInfo(pi, ctx) };
    case "compact": {
      if (!selectedModel(ctx))
        throw new BuiltinError("NO_MODEL", "Select a model first");
      return new Promise((resolve, reject) =>
        ctx.compact({
          customInstructions: args || undefined,
          onComplete: (result) =>
            resolve({
              kind: "compact",
              summary: result.summary.slice(0, 32000),
              tokens_before: result.tokensBefore,
            }),
          onError: (error) =>
            reject(new BuiltinError("COMPACT_FAILED", error.message)),
        }),
      );
    }
  }
}
