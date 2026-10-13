import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import type { ExtensionContext as CompatibleContext } from "@earendil-works/pi-coding-agent";
import { createCompanion, type CompanionHost } from "../shared/companion.ts";
import { builtinCommands, controls, executeBuiltin } from "./builtins.ts";
import { AskBridge, todoData } from "./interaction.ts";

export default function pirc(api: ExtensionAPI) {
  // OMP rebinds extensions for subagents too. Only the main TUI is remotely
  // controlled; task-tool output flows through its normal tool blocks.
  const approvals = new Set<string>();
  const ask = new AskBridge((request) => companion.setAsk(request));
  api.on("session_start", (_e, ctx) => ask.install(ctx));
  api.on("session_switch", (_e, ctx) => {
    if (ctx.agent.kind === "main") ask.cancel();
    ask.install(ctx);
  });
  api.on("session_shutdown", (_e, ctx) => {
    if (ctx.agent.kind === "main") ask.cancel();
  });
  type Handler = (event: any, ctx: ExtensionContext) => any;
  // Overloaded host events are normalized at this adapter boundary.
  const subscribe = api.on.bind(api) as (
    event: string,
    handler: Handler,
  ) => void;
  const host: CompanionHost = {
    getCommands: () => api.getCommands(),
    getSessionName: () => api.getSessionName(),
    setSessionName: (name) => api.setSessionName(name),
    sendUserMessage: (content) => api.sendUserMessage(content),
    on: ((
      event: string,
      handler: (event: any, ctx: CompatibleContext) => any,
    ) => {
      const forward: Handler = (e, ctx) => {
        if (ctx.agent.kind !== "main") return;
        // Message/tool fields and branch records share the compatible contract.
        // Model and settings operations use OMP's native API below.
        return handler(e, ctx as unknown as CompatibleContext);
      };
      switch (event) {
        case "session_start":
          subscribe("session_start", (e, ctx) => {
            if (ctx.agent.kind === "main") approvals.clear();
            return forward(e, ctx);
          });
          subscribe("session_switch", (e, ctx) => {
            if (ctx.agent.kind === "main") approvals.clear();
            return forward(e, ctx);
          });
          break;
        case "session_info_changed":
        case "model_select":
        case "thinking_level_select":
          // Heartbeats query live name/model/thinking values.
          break;
        case "agent_settled":
          subscribe("agent_end", (e, ctx) => {
            if (!e.willContinue) return forward(e, ctx);
          });
          break;
        case "session_compact_failed":
          subscribe("auto_compaction_end", forward);
          break;
        case "ui_prompt_start":
          subscribe("tool_approval_requested", (e, ctx) => {
            if (ctx.agent.kind !== "main") return;
            approvals.add(e.toolCallId);
            return forward({ kind: "tool_approval", title: e.toolName }, ctx);
          });
          break;
        case "ui_prompt_end":
          subscribe("tool_approval_resolved", (e, ctx) => {
            if (ctx.agent.kind !== "main") return;
            approvals.delete(e.toolCallId);
            if (!approvals.size) return forward(e, ctx);
          });
          subscribe("tool_execution_end", (e, ctx) => {
            if (ctx.agent.kind !== "main") return;
            if (approvals.delete(e.toolCallId) && !approvals.size)
              return forward(e, ctx);
          });
          break;
        default:
          subscribe(event, forward);
      }
    }) as CompanionHost["on"],
  };
  const companion = createCompanion(host, {
    agentId: "omp",
    promptCommands: false,
    capabilities: [
      "image_read",
      "image_prompt",
      "local_ui_state",
      "ask",
      "todo",
    ],
    answerAsk: (id, answers) => ask.answer(id, answers),
    toolData: todoData,
    builtinCommands,
    controls: (ctx, compacting) =>
      controls(api, ctx as unknown as ExtensionContext, compacting),
    execute: (ctx, command, args) =>
      executeBuiltin(api, ctx as unknown as ExtensionContext, command, args),
  });
}
