import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createCompanion } from "../shared/companion.ts";
import { builtinCommands, controls, executeBuiltin } from "./builtins.ts";

export default function pirc(pi: ExtensionAPI) {
  createCompanion(pi, {
    agentId: "pi",
    capabilities: ["image_read", "image_prompt", "local_ui_state"],
    builtinCommands,
    controls: (ctx, compacting) => controls(pi, ctx, compacting),
    execute: (ctx, command, args) => executeBuiltin(pi, ctx, command, args),
  });
}
