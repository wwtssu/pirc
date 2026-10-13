import type { SlashCommand } from "../../packages/protocol/generated/SlashCommand.ts";

export const builtinCommands: SlashCommand[] = [
  {
    name: "model",
    description: "Select the model for this session",
    source: "builtin",
  },
  {
    name: "thinking",
    description: "Adjust the thinking level",
    source: "builtin",
  },
  { name: "name", description: "Rename the session", source: "builtin" },
  {
    name: "session",
    description: "View session information and usage",
    source: "builtin",
  },
  {
    name: "compact",
    description: "Compact context with optional instructions",
    source: "builtin",
  },
];
