import type { ExtensionAPI, ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import type { CommandData } from "../../packages/protocol/generated/CommandData.ts";
import { BuiltinError } from "../shared/errors.ts";
import { modelInfo } from "./builtins.ts";

async function native(api: ExtensionAPI) {
  // Use the running host's singleton, including compiled OMP distributions.
  const settings = api.pi?.Settings.instance;
  if (!settings) return undefined;
  const roles = await import("@oh-my-pi/pi-coding-agent/config/model-roles");
  const { cfgModelRoleStorage } =
    await import("@oh-my-pi/pi-coding-agent/config/model-settings");
  const { resolveModelRoleValue } =
    await import("@oh-my-pi/pi-coding-agent/config/model-resolver");
  return {
    settings,
    ...roles,
    resolveModelRoleValue,
    storage: cfgModelRoleStorage.get(settings),
  };
}
export async function modelRoles(api: ExtensionAPI, ctx: ExtensionContext) {
  const host = await native(api);
  if (!host) return undefined;
  return host.getKnownRoleIds(host.settings).map((id) => {
    const info = host.getRoleInfo(id, host.settings);
    const resolved = host.resolveModelRoleValue(
      `@${id}`,
      host.roleCandidatePool(id, host.settings, ctx.modelRegistry),
      { settings: host.settings },
    ).model;
    return {
      id,
      category: info?.section ?? "chat",
      selector: host.settings.getModelRole(id) ?? null,
      resolved: resolved ? modelInfo(resolved) : null,
      source: host.settings.getModelRoleSource(id),
    };
  });
}
export async function executeRole(
  api: ExtensionAPI,
  ctx: ExtensionContext,
  raw: string,
): Promise<CommandData> {
  let request: { op: string; role: string; selector?: string };
  try {
    request = JSON.parse(raw);
  } catch {
    throw new BuiltinError("INVALID_ARGUMENT", "Invalid model role request");
  }
  const host = await native(api);
  if (
    !host ||
    !["role_models", "set_role", "clear_role"].includes(request?.op) ||
    typeof request.role !== "string" ||
    !host.getKnownRoleIds(host.settings).includes(request.role)
  )
    throw new BuiltinError(
      "INVALID_ARGUMENT",
      "Unknown model role or operation",
    );
  const candidates = host.roleCandidatePool(
    request.role,
    host.settings,
    ctx.modelRegistry,
  );
  if (request.op === "set_role") {
    if (typeof request.selector !== "string")
      throw new BuiltinError("INVALID_ARGUMENT", "Select a model first");
    const model = candidates.find(
      (m) => `${m.provider}/${m.id}` === request.selector,
    );
    if (!model)
      throw new BuiltinError(
        "MODEL_NOT_FOUND",
        "Model not found. Select one from the list.",
      );
    if (request.role === "default" && !(await api.setModel(model)))
      throw new BuiltinError(
        "MODEL_AUTH_REQUIRED",
        "Set up authentication for this model on the device first.",
      );
    if (host.storage === "project")
      host.settings.setProjectModelRole(request.role, request.selector);
    else host.settings.setModelRole(request.role, request.selector);
    await host.settings.flush();
  } else if (request.op === "clear_role") {
    if (host.storage === "project")
      host.settings.clearProjectModelRole(request.role);
    else host.settings.setModelRole(request.role, undefined);
    await host.settings.flush();
  }
  const current = ctx.models.current();
  return {
    kind: "model",
    current: current ? modelInfo(current) : null,
    models: candidates.map(modelInfo),
    roles: await modelRoles(api, ctx),
  };
}
