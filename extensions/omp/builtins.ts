import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import type { Model } from "@oh-my-pi/pi-ai";
import type { BuiltinCommand } from "../../packages/protocol/generated/BuiltinCommand.ts";
import type { CommandData } from "../../packages/protocol/generated/CommandData.ts";
import type { SessionControls } from "../../packages/protocol/generated/SessionControls.ts";
import { BuiltinError } from "../shared/errors.ts";
import { builtinCommands } from "../shared/commands.ts";
export { builtinCommands };

export function modelInfo(model: Model) {
  return {
    provider: model.provider,
    id: model.id,
    name: model.name,
    reasoning: model.reasoning,
    context_window: model.contextWindow ?? 0,
  };
}
export function thinkingLevels(ctx: ExtensionContext): string[] {
  const model = ctx.models.current();
  return model
    ? ["off", ...(model.reasoning ? (model.thinking?.efforts ?? []) : [])]
    : [];
}
export function controls(
  api: ExtensionAPI,
  ctx: ExtensionContext,
  compacting: boolean,
): SessionControls {
  const model = ctx.models.current();
  return {
    model: model ? modelInfo(model) : null,
    thinking_level: api.getThinkingLevel() ?? "off",
    thinking_levels: thinkingLevels(ctx),
    compacting,
  };
}
function sessionInfo(ctx: ExtensionContext) {
  const info = {
    session_id: ctx.sessionManager.getSessionId(),
    name: ctx.sessionManager.getSessionName() ?? null,
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
      ctx.getContextUsage()?.contextWindow ??
      ctx.models.current()?.contextWindow ??
      0,
  };
  let cost = 0;
  for (const entry of ctx.sessionManager.getBranch()) {
    if (entry.type !== "message") continue;
    const message = entry.message;
    info.total_messages++;
    if (message.role === "user") info.user_messages++;
    if (message.role === "toolResult") info.tool_results++;
    if (message.role === "assistant") {
      info.assistant_messages++;
      info.tool_calls += message.content.filter(
        (c) => c.type === "toolCall",
      ).length;
      for (const [source, target] of [
        ["input", "input_tokens"],
        ["output", "output_tokens"],
        ["cacheRead", "cache_read_tokens"],
        ["cacheWrite", "cache_write_tokens"],
      ] as const) {
        const value = message.usage?.[source];
        if (typeof value === "number" && Number.isFinite(value) && value >= 0)
          info[target] = Math.min(
            Number.MAX_SAFE_INTEGER,
            info[target] + Math.floor(value),
          );
      }
      const value = message.usage?.cost?.total;
      if (typeof value === "number" && Number.isFinite(value) && value >= 0)
        cost += value;
    }
  }
  info.cost_usd = cost.toFixed(6);
  return info;
}
export async function executeBuiltin(
  api: ExtensionAPI,
  ctx: ExtensionContext,
  command: BuiltinCommand,
  raw: string,
): Promise<CommandData> {
  const args = raw.trim();
  switch (command) {
    case "model": {
      if (args) {
        // OMP resolves provider IDs, fuzzy names and configured role aliases.
        const model = ctx.models.resolve(args);
        if (!model)
          throw new BuiltinError(
            "MODEL_NOT_FOUND",
            "Model not found. Select one from the list.",
          );
        if (!(await api.setModel(model)))
          throw new BuiltinError(
            "MODEL_AUTH_REQUIRED",
            "Set up authentication for this model on the device first.",
          );
      }
      const current = ctx.models.current();
      return {
        kind: "model",
        current: current ? modelInfo(current) : null,
        models: args
          ? []
          : ctx.models
              .list()
              .filter(
                (m) =>
                  m.kind === undefined ||
                  m.kind === "chat" ||
                  m.kind === "tiny",
              )
              .map(modelInfo),
      };
    }
    case "thinking": {
      if (!ctx.models.current())
        throw new BuiltinError("NO_MODEL", "Select a model first");
      const levels = thinkingLevels(ctx);
      if (args) {
        const level = levels.find((l) => l === args.toLowerCase());
        if (!level)
          throw new BuiltinError(
            "INVALID_THINKING_LEVEL",
            `Supported thinking levels: ${levels.join(", ")}`,
          );
        api.setThinkingLevel(
          level as Parameters<ExtensionAPI["setThinkingLevel"]>[0],
        );
      }
      return {
        kind: "thinking",
        level: api.getThinkingLevel() ?? "off",
        levels,
      };
    }
    case "name":
      if (args) {
        if ([...args].length > 256 || /[\r\n\x00]/.test(args))
          throw new BuiltinError(
            "INVALID_ARGUMENT",
            "Name must be a single line of at most 256 characters",
          );
        await api.setSessionName(args);
      }
      return { kind: "name", name: api.getSessionName() ?? null };
    case "session":
      if (args)
        throw new BuiltinError(
          "INVALID_ARGUMENT",
          "/session does not accept arguments",
        );
      return { kind: "session", info: sessionInfo(ctx) };
    case "compact": {
      if (!ctx.models.current())
        throw new BuiltinError("NO_MODEL", "Select a model first");
      const previous = new Set(ctx.sessionManager.getBranch().map((e) => e.id));
      try {
        let completed: { summary: string; tokensBefore: number } | undefined;
        let failed: Error | undefined;
        await ctx.compact({
          internalGuidance: args || undefined,
          onComplete: (result) => {
            completed = result;
          },
          onError: (error) => {
            failed = error;
          },
        });
        if (failed) throw failed;
        const result =
          completed ??
          ctx.sessionManager
            .getBranch()
            .findLast((e) => e.type === "compaction" && !previous.has(e.id));
        if (!result || !("summary" in result) || !("tokensBefore" in result))
          throw new Error(
            "Compaction did not produce a summary. Check the device terminal.",
          );
        return {
          kind: "compact",
          summary: result.summary.slice(0, 32000),
          tokens_before: result.tokensBefore,
        };
      } catch (error) {
        throw new BuiltinError(
          "COMPACT_FAILED",
          error instanceof Error ? error.message : String(error),
        );
      }
    }
  }
}
