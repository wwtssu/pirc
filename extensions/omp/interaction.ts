import { randomUUID } from "node:crypto";
import type {
  ExtensionContext,
  ExtensionAskDialogResult,
  ExtensionAskDialogSubmitResult,
} from "@oh-my-pi/pi-coding-agent";
import type { AskAnswer } from "../../packages/protocol/generated/AskAnswer.ts";
import type { AskRequest } from "../../packages/protocol/generated/AskRequest.ts";
import type { TodoPhase } from "../../packages/protocol/generated/TodoPhase.ts";
import { BuiltinError } from "../shared/errors.ts";

// Preserve OMP's own dialog, cancellation and timeout behavior. Either surface
// can answer; the winning result closes the other surface before tools resume.
export class AskBridge {
  private installed = new WeakSet<object>();
  private pending?: {
    request: AskRequest;
    resolve(result: ExtensionAskDialogResult | undefined): void;
    controller: AbortController;
    settled: boolean;
  };
  private publish: (request: AskRequest | undefined) => void;
  constructor(publish: (request: AskRequest | undefined) => void) {
    this.publish = publish;
  }

  install(ctx: ExtensionContext) {
    const ui = ctx.ui;
    if (ctx.agent.kind !== "main" || !ui.askDialog || this.installed.has(ui))
      return;
    this.installed.add(ui);
    const original = ui.askDialog.bind(ui);
    ui.askDialog = async (questions, options) => {
      if (
        this.pending ||
        questions.length > 32 ||
        questions.some((q) => q.options.length > 64)
      )
        return original(questions, options);
      const request: AskRequest = {
        id: randomUUID(),
        questions: questions.map((q) => ({
          id: q.id,
          question: q.question,
          header: q.header ?? null,
          options: q.options.map((o) => ({
            label: o.label,
            description: o.description ?? null,
            preview: o.preview ?? null,
          })),
          multi: q.multi ?? false,
          recommended: q.recommended ?? null,
        })),
      };
      const controller = new AbortController();
      const signal = options?.signal
        ? AbortSignal.any([options.signal, controller.signal])
        : controller.signal;
      let resolve!: (value: ExtensionAskDialogResult | undefined) => void;
      const remote = new Promise<ExtensionAskDialogResult | undefined>((r) => {
        resolve = r;
      });
      const pending = { request, resolve, controller, settled: false };
      this.pending = pending;
      this.publish(request);
      try {
        const local = original(questions, { ...options, signal }).then(
          (value) => {
            if (!pending.settled) pending.settled = true;
            return value;
          },
        );
        return await Promise.race([remote, local]);
      } finally {
        pending.settled = true;
        controller.abort();
        if (this.pending === pending) {
          this.pending = undefined;
          this.publish(undefined);
        }
      }
    };
  }
  answer(id: string, answers: AskAnswer[]) {
    const pending = this.pending;
    if (!pending || pending.settled || pending.request.id !== id)
      throw new BuiltinError(
        "STALE_PROMPT",
        "This question is no longer waiting for an answer.",
      );
    if (
      answers.length !== pending.request.questions.length ||
      new Set(answers.map((a) => a.id)).size !== answers.length
    )
      throw new BuiltinError("INVALID_ARGUMENT", "Answer every question once.");
    const results: ExtensionAskDialogSubmitResult["results"] =
      pending.request.questions.map((q) => {
        const a = answers.find((a) => a.id === q.id);
        if (
          !a ||
          new Set(a.selected).size !== a.selected.length ||
          a.selected.some(
            (i) => !Number.isInteger(i) || i < 0 || i >= q.options.length,
          ) ||
          (!q.multi && a.selected.length > 1) ||
          (!q.multi && !a.selected.length && !a.text?.trim()) ||
          (a.text?.length ?? 0) > 64 * 1024 ||
          (a.note?.length ?? 0) > 64 * 1024
        )
          throw new BuiltinError(
            "INVALID_ARGUMENT",
            "Choose an option or enter an answer for each question.",
          );
        return {
          id: q.id,
          question: q.question,
          options: q.options.map((o) => o.label),
          multi: q.multi,
          selectedOptions: a.selected.map((i) => q.options[i]!.label),
          customInput: a.text?.trim() || undefined,
          note: a.note?.trim() || undefined,
          timedOut: false,
        };
      });
    pending.settled = true;
    pending.resolve({ kind: "submit", results });
  }
  cancel() {
    if (!this.pending) return;
    this.pending.settled = true;
    this.pending.resolve(undefined);
    this.pending.controller.abort();
    this.pending = undefined;
    this.publish(undefined);
  }
}

export function todoData(
  name: string,
  result: unknown,
): { todo?: TodoPhase[] } {
  if (name !== "todo" || !result || typeof result !== "object") return {};
  const phases = (result as { details?: { phases?: unknown } }).details?.phases;
  if (!Array.isArray(phases)) return {};
  const statuses = new Set([
    "pending",
    "in_progress",
    "completed",
    "abandoned",
    "blocked",
  ]);
  if (
    !phases.every(
      (p) =>
        typeof p?.name === "string" &&
        Array.isArray(p.tasks) &&
        p.tasks.every(
          (t: any) =>
            typeof t?.content === "string" &&
            statuses.has(t.status) &&
            (t.blocker === undefined || typeof t.blocker === "string"),
        ),
    )
  )
    return {};
  return {
    todo: phases.map((p) => ({
      name: p.name,
      tasks: p.tasks.map((t: any) => ({
        content: t.content,
        status: t.status,
        blocker: t.blocker ?? null,
      })),
    })),
  };
}
