import { ImageCatalog } from "./images.ts";
import { randomUUID } from "node:crypto";
import { readFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import type { Envelope } from "../../packages/protocol/generated/Envelope.ts";
import type { Message } from "../../packages/protocol/generated/Message.ts";
import type { SessionSnapshot } from "../../packages/protocol/generated/SessionSnapshot.ts";
import type { EventData } from "../../packages/protocol/generated/EventData.ts";
import { decode } from "./protocol.ts";
import {
  builtinCommands,
  BuiltinError,
  controls,
  executeBuiltin,
} from "./builtins.ts";
import type { CommandData } from "../../packages/protocol/generated/CommandData.ts";

type RecordEntry = { original: string; result: Envelope; created: number };
const MAX_RECORDS = 10000;
export default function pirc(pi: ExtensionAPI) {
  let instanceId = randomUUID();
  const images = new ImageCatalog();
  let ctx: ExtensionContext | undefined;
  let session: SessionSnapshot;
  let socket: WebSocket | undefined;
  let active = false;
  let closing = false;
  let settled = true;
  let sourceSeq = 0;
  let generation = "";
  let attention = false;
  let reconnect: ReturnType<typeof setTimeout> | undefined;
  let heartbeat: ReturnType<typeof setInterval> | undefined;
  let stopRequests = new Set<string>();
  let pendingPrompt:
    { id: string; text: string; started: number; ackText?: string } | undefined;
  let pendingBuiltin: { id: string; command: string } | undefined;
  let localCompacting = false;
  let localPreflight = false;
  let localPreflightStarted = 0;
  let syncedGeneration = "";
  let syncingHistory = true;
  let historyQueue: EventData[] = [];
  let historyCursor = 0;
  let assistantEvents: EventData[] = [];
  const runningTools = new Map<string, EventData[]>();
  const records = new Map<string, RecordEntry>();
  let assistantMessageId = randomUUID();
  let config: { url: string };

  function packet(
    message: Message,
    requestId: string = randomUUID(),
  ): Envelope {
    return { version: 1, request_id: requestId, message };
  }
  function send(e: Envelope) {
    if (socket?.readyState !== WebSocket.OPEN) return;
    if (socket.bufferedAmount > 1024 * 1024) {
      socket.close(1013, "Backpressure");
      return;
    }
    socket.send(JSON.stringify(e));
  }
  function snapshot() {
    send(packet({ type: "snapshot", session: { ...session } }));
  }
  function state(next: SessionSnapshot["state"]) {
    if (
      session.state !== next ||
      session.needs_local_attention !== (attention || syncingHistory)
    ) {
      session.state = next;
      session.needs_local_attention = attention || syncingHistory;
      session.revision++;
      snapshot();
    }
  }
  function idle(): boolean {
    return (
      !!ctx &&
      !closing &&
      settled &&
      !attention &&
      !syncingHistory &&
      !pendingPrompt &&
      !pendingBuiltin &&
      !localCompacting &&
      !localPreflight &&
      ctx.isIdle() &&
      !ctx.hasPendingMessages()
    );
  }
  function confirmIdle() {
    if (!active || !idle()) return;
    state("idle");
    for (const id of stopRequests) result(id, "completed");
    stopRequests.clear();
  }
  function result(
    id: string,
    status: "accepted" | "completed" | "rejected",
    code: string | null = null,
    detail: string | null = null,
    data?: CommandData,
  ) {
    const e = packet(
      {
        type: "command_result",
        session_id: session.session_id,
        instance_id: instanceId,
        status,
        code,
        detail,
        ...(data ? { data } : {}),
      },
      id,
    );
    const record = records.get(id);
    if (record) record.result = e;
    send(e);
  }
  function eventData(
    kind: EventData["kind"],
    values: Partial<EventData> = {},
  ): EventData {
    const value = values.text;
    if (value && Buffer.byteLength(value) > 65536)
      values = {
        ...values,
        text: Buffer.from(value).subarray(0, 65536).toString("utf8"),
        truncated: true,
      };
    return {
      kind,
      message_id: null,
      content_index: null,
      text: null,
      tool_call_id: null,
      tool_name: null,
      is_error: false,
      truncated: false,
      ...values,
    };
  }
  function emitEvent(event: EventData) {
    sourceSeq++;
    send(
      packet({
        type: "event",
        session_id: session.session_id,
        instance_id: instanceId,
        source_seq: sourceSeq,
        seq: 0,
        event,
      }),
    );
  }
  function event(kind: EventData["kind"], values: Partial<EventData> = {}) {
    const data = eventData(kind, values);
    // Completed messages live in the agent's session file. Retain only the
    // unfinished assistant and cumulative tool output for restart recovery.
    if (kind === "message_start") assistantEvents = [data];
    else if (data.message_id === assistantMessageId && assistantEvents.length)
      assistantEvents.push(data);
    if (kind === "message_end") assistantEvents = [];
    if (data.tool_call_id) {
      if (kind === "tool_start") runningTools.set(data.tool_call_id, [data]);
      else if (kind === "tool_update") {
        const start = runningTools.get(data.tool_call_id)?.[0];
        if (start) runningTools.set(data.tool_call_id, [start, data]);
      } else if (kind === "tool_end") runningTools.delete(data.tool_call_id);
    }
    if (syncingHistory) historyQueue.push(data);
    else emitEvent(data);
  }
  function dispatch(e: Envelope) {
    const m = e.message;
    if (
      !active ||
      !ctx ||
      !["stop", "prompt", "builtin", "close_session", "read_image"].includes(
        m.type,
      )
    )
      return;
    if (
      m.type !== "stop" &&
      m.type !== "prompt" &&
      m.type !== "builtin" &&
      m.type !== "close_session" &&
      m.type !== "read_image"
    )
      return;
    if (m.type === "read_image") {
      if (
        m.generation_id !== generation ||
        m.session_id !== session.session_id ||
        m.instance_id !== instanceId
      ) {
        result(e.request_id, "rejected", "STALE_INSTANCE");
        return;
      }
      try {
        let chunk = images.read(m.image_id, m.offset);
        if (!chunk) {
          for (const entry of ctx.sessionManager.getBranch()) {
            if (entry.type === "message" && "content" in entry.message)
              images.collect(entry.message.content);
            chunk = images.read(m.image_id, m.offset);
            if (chunk) break;
          }
        }
        if (!chunk)
          result(
            e.request_id,
            "rejected",
            "IMAGE_UNAVAILABLE",
            "Image is no longer available. Reload the session and retry.",
          );
        else result(e.request_id, "completed", null, null, chunk);
      } catch (error) {
        result(e.request_id, "rejected", "INVALID_ARGUMENT", String(error));
      }
      return;
    }
    const original = JSON.stringify(e.message);
    const cached = records.get(e.request_id);
    if (cached) {
      if (cached.original === original) send(cached.result);
      else
        send(
          packet(
            {
              type: "error",
              code: "REQUEST_ID_REUSED",
              detail: "Request ID has different payload",
            },
            e.request_id,
          ),
        );
      return;
    }
    if (records.size >= MAX_RECORDS) {
      send(
        packet(
          {
            type: "error",
            code: "COMMAND_CAPACITY",
            detail: "Command cache is full",
          },
          e.request_id,
        ),
      );
      return;
    }
    records.set(e.request_id, {
      original,
      result: packet(
        {
          type: "error",
          code: "PENDING",
          detail: "Execution is not confirmed",
        },
        e.request_id,
      ),
      created: Date.now(),
    });
    if (m.generation_id !== generation) {
      result(e.request_id, "rejected", "STALE_GENERATION");
      return;
    }
    if (m.session_id !== session.session_id || m.instance_id !== instanceId) {
      result(e.request_id, "rejected", "STALE_INSTANCE");
      return;
    }
    if (closing) {
      result(e.request_id, "rejected", "CLOSING");
      return;
    }
    if (
      m.type === "close_session" &&
      (!session.launch_id || session.can_close !== true)
    ) {
      result(e.request_id, "rejected", "UNMANAGED_TERMINAL");
      return;
    }
    if (m.type === "stop") {
      if (idle()) {
        result(e.request_id, "completed");
        return;
      }
      if ((pendingPrompt || localPreflight) && ctx.isIdle()) {
        result(e.request_id, "rejected", "STARTING");
        return;
      }
      stopRequests.add(e.request_id);
      state("stopping");
      result(e.request_id, "accepted");
      ctx.abort();
      return;
    }
    if (!idle()) {
      result(
        e.request_id,
        "rejected",
        attention ? "NEEDS_LOCAL_ATTENTION" : "BUSY",
      );
      return;
    }
    if (m.expected_revision !== session.revision) {
      result(e.request_id, "rejected", "STALE_STATE");
      return;
    }
    if (m.type === "close_session") {
      closing = true;
      result(e.request_id, "accepted");
      try {
        ctx.shutdown();
      } catch (error) {
        closing = false;
        result(e.request_id, "rejected", "PI_ERROR", String(error));
      }
      return;
    }
    if (m.type === "builtin") {
      if (Buffer.byteLength(m.args) > 64 * 1024) {
        result(e.request_id, "rejected", "INVALID_ARGUMENT");
        return;
      }
      if (!builtinCommands.some((c) => c.name === m.command)) {
        result(e.request_id, "rejected", "LOCAL_COMMAND_REQUIRED");
        return;
      }
      const operation = { id: e.request_id, command: m.command };
      pendingBuiltin = operation;
      refreshControls();
      if (m.command === "compact") state("running");
      result(e.request_id, "accepted");
      void executeBuiltin(pi, ctx, m.command, m.args)
        .then(
          (data) => {
            if (active && pendingBuiltin === operation)
              result(e.request_id, "completed", null, null, data);
          },
          (error) => {
            if (active && pendingBuiltin === operation)
              result(
                e.request_id,
                "rejected",
                error instanceof BuiltinError ? error.code : "PI_ERROR",
                String(error.message ?? error),
              );
          },
        )
        .finally(() => {
          if (!active || pendingBuiltin !== operation) return;
          pendingBuiltin = undefined;
          refreshControls();
          confirmIdle();
        });
      return;
    }
    if (!m.text.trim() || Buffer.byteLength(m.text) > 64 * 1024) {
      result(e.request_id, "rejected", "INVALID_PROMPT");
      return;
    }
    if (!ctx.model) {
      result(e.request_id, "rejected", "NO_MODEL");
      return;
    }
    if (m.text.trimStart().startsWith("/")) {
      const name = m.text.trimStart().slice(1).split(/\s/)[0];
      const command = pi.getCommands().find((c) => c.name === name);
      if (!command || command.source === "extension") {
        result(e.request_id, "rejected", "LOCAL_COMMAND_REQUIRED");
        return;
      }
    }
    pendingPrompt = { id: e.request_id, text: m.text, started: Date.now() };
    settled = false;
    state("running");
    try {
      pi.sendUserMessage(m.text, {
        expandPromptTemplates: m.text.trimStart().startsWith("/"),
      });
    } catch (err) {
      pendingPrompt = undefined;
      settled = true;
      result(e.request_id, "rejected", "PI_ERROR", String(err));
      confirmIdle();
    }
  }
  function commands() {
    return [
      ...builtinCommands,
      ...pi
        .getCommands()
        .filter((c) => !builtinCommands.some((b) => b.name === c.name))
        .map(({ name, description, source }) => ({
          name,
          description: description ?? null,
          source,
        })),
    ];
  }
  function refreshControls() {
    if (!active || !ctx) return;
    const value = controls(
      pi,
      ctx,
      localCompacting || pendingBuiltin?.command === "compact",
    );
    if (JSON.stringify(value) !== JSON.stringify(session.controls)) {
      session.controls = value;
      session.revision++;
      snapshot();
    }
  }
  function connect() {
    if (!active) return;
    const ws = new WebSocket(config.url);
    socket = ws;
    ws.addEventListener("open", () => send(packet({ type: "auth" })));
    ws.addEventListener("message", (incoming) => {
      const e =
        typeof incoming.data === "string" ? decode(incoming.data) : null;
      if (!e || socket !== ws || !active) return;
      if (e.message.type === "welcome") {
        const changed = generation !== e.message.generation_id;
        if (generation && changed) {
          // Old results cannot authorize commands on a newly started server.
          records.clear();
        }
        generation = e.message.generation_id;
        if (changed) {
          sourceSeq = 0;
          syncingHistory = true;
          // Capture durable history and unfinished streams in one JS turn;
          // subsequent live events queue behind this snapshot.
          historyQueue = historyEvents();
          historyCursor = 0;
          session.needs_local_attention = true;
          session.revision++;
        }
        send(packet({ type: "register", session: { ...session } }));
        if (syncedGeneration !== generation) void restoreHistory(ws);
        send(
          packet({
            type: "heartbeat",
            session: { ...session },
            source_seq: sourceSeq,
          }),
        );
      } else if (e.message.type === "error") {
        if (e.message.code === "UNAUTHORIZED") {
          active = false;
          ws.close();
          ctx?.ui.notify("PiRC authentication failed", "error");
        }
      } else dispatch(e);
    });
    ws.addEventListener("error", () => {});
    ws.addEventListener("close", () => {
      if (active && socket === ws) reconnect = setTimeout(connect, 500);
    });
  }
  function startSession(context: ExtensionContext) {
    if (active)
      send(
        packet({
          type: "unregister",
          session_id: session.session_id,
          instance_id: instanceId,
        }),
      );
    active = false;
    clearTimeout(reconnect);
    clearInterval(heartbeat);
    const previous = socket;
    socket = undefined;
    previous?.close();
    instanceId = randomUUID();
    generation = "";
    syncedGeneration = "";
    sourceSeq = 0;
    assistantEvents = [];
    assistantMessageId = randomUUID();
    historyQueue = [];
    historyCursor = 0;
    runningTools.clear();
    records.clear();
    stopRequests.clear();
    pendingPrompt = undefined;
    pendingBuiltin = undefined;
    localPreflight = false;
    ctx = context;
    const initialName = process.env.PIRC_INITIAL_NAME?.trim();
    delete process.env.PIRC_INITIAL_NAME;
    if (
      process.env.PIRC_LAUNCH_ID &&
      process.env.PIRC_RESTORE_HISTORY !== "1" &&
      initialName
    ) {
      pi.setSessionName(initialName);
    }
    const path = process.env.PIRC_CONFIG ?? `${homedir()}/.pirc/extension.json`;
    const file = existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : {};
    config = {
      url: process.env.PIRC_URL ?? file.url ?? "ws://127.0.0.1:43123/extension",
    };
    const url = new URL(config.url);
    if (
      url.protocol !== "ws:" ||
      !["127.0.0.1", "localhost", "[::1]"].includes(url.hostname)
    )
      throw new Error("Extension requires loopback WebSocket");
    images.clear();
    active = true;
    closing = false;
    settled = context.isIdle();
    attention = false;
    syncingHistory = true;
    localCompacting = false;
    session = {
      capabilities: ["image_read", "local_ui_state"],
      session_id: context.sessionManager.getSessionId(),
      instance_id: instanceId,
      cwd: context.cwd,
      name: pi.getSessionName() ?? null,
      state: settled ? "idle" : "running",
      revision: 0,
      needs_local_attention: attention || syncingHistory,
      slash_commands: commands(),
      controls: controls(pi, context, false),
      can_close:
        !!process.env.PIRC_LAUNCH_ID &&
        process.env.PIRC_MANAGED_TERMINAL === "1",
      ...(process.env.PIRC_LAUNCH_ID
        ? { launch_id: process.env.PIRC_LAUNCH_ID }
        : {}),
    };
    connect();
    heartbeat = setInterval(() => {
      if (!active) return;
      confirmIdle();
      refreshControls();
      const available = commands();
      if (
        JSON.stringify(available) !== JSON.stringify(session.slash_commands)
      ) {
        session.slash_commands = available;
        session.revision++;
        snapshot();
      }
      send(
        packet({
          type: "heartbeat",
          session: { ...session },
          source_seq: sourceSeq,
        }),
      );
      for (const [id, record] of records)
        if (
          Date.now() - record.created > 600000 &&
          !stopRequests.has(id) &&
          pendingPrompt?.id !== id &&
          pendingBuiltin?.id !== id
        )
          records.delete(id);
      if (
        ((pendingPrompt && Date.now() - pendingPrompt.started > 10000) ||
          (localPreflight && Date.now() - localPreflightStarted > 10000)) &&
        !attention
      ) {
        attention = true;
        state(session.state);
        ctx?.ui.notify(
          "PiRC prompt has not started; check model or authentication. Result remains unknown; reload the session adapter after correcting the configuration.",
          "warning",
        );
      }
    }, 1000);
  }
  pi.on("session_start", (_event, context) => startSession(context));
  pi.on("session_tree", (_event, context) => startSession(context));
  pi.on("session_shutdown", () => {
    if (!active && !heartbeat) return;
    send(
      packet({
        type: "unregister",
        session_id: session.session_id,
        instance_id: instanceId,
      }),
    );
    active = false;
    ctx = undefined;
    clearTimeout(reconnect);
    clearInterval(heartbeat);
    socket?.close();
    records.clear();
    stopRequests.clear();
    pendingBuiltin = undefined;
  });
  pi.on("session_info_changed", (e) => {
    if (active) {
      session.name = e.name ?? null;
      session.revision++;
      snapshot();
    }
  });
  pi.on("model_select", () => refreshControls());
  pi.on("thinking_level_select", () => refreshControls());
  pi.on("input", (e, context) => {
    if (active && closing && e.source === "interactive")
      return { action: "handled" };
    if (
      !active ||
      e.source !== "interactive" ||
      e.text.startsWith("/") ||
      e.text.startsWith("!")
    )
      return;
    if (pendingPrompt && context.isIdle()) {
      context.ui.setEditorText(e.text);
      context.ui.notify(
        "PiRC prompt is starting; draft kept in editor",
        "warning",
      );
      return { action: "handled" };
    }
    if (context.isIdle()) {
      localPreflight = true;
      localPreflightStarted = Date.now();
      settled = false;
      state("running");
    }
  });
  pi.on("before_agent_start", (e) => {
    if (active) {
      if (pendingPrompt) pendingPrompt.ackText = e.prompt;
      if (pendingPrompt?.text.trimStart().startsWith("/")) {
        result(pendingPrompt.id, "accepted");
        pendingPrompt = undefined;
      }
      localPreflight = false;
      settled = false;
      state("running");
    }
  });
  pi.on("agent_start", () => {
    if (active) {
      settled = false;
      event("agent_start");
      state("running");
    }
  });
  pi.on("agent_settled", () => {
    if (active) {
      event("agent_settled");
      settled = true;
      setImmediate(confirmIdle);
    }
  });
  pi.on("ui_prompt_start", (e) => {
    if (active) {
      attention = true;
      session.ui_prompt = { kind: e.kind, title: e.title ?? null };
      state(session.state);
    }
  });
  pi.on("ui_prompt_end", () => {
    if (active) {
      attention = false;
      session.ui_prompt = undefined;
      state(session.state);
      setImmediate(confirmIdle);
    }
  });
  pi.on("session_before_compact", () => {
    if (!active) return;
    localCompacting = true;
    refreshControls();
    state("running");
  });
  const compactionEnded = () => {
    if (!active) return;
    localCompacting = false;
    refreshControls();
    setImmediate(confirmIdle);
  };
  pi.on("session_compact", compactionEnded);
  pi.on("session_compact_failed", compactionEnded);
  function text(content: unknown): string {
    if (typeof content === "string") return content;
    if (!Array.isArray(content)) return "";
    return content
      .filter((c) => c?.type === "text")
      .map((c) => c.text)
      .join("\n");
  }
  function historyEvents(): EventData[] {
    const events: EventData[] = [];
    if (!ctx) return events;
    const append = (kind: EventData["kind"], values: Partial<EventData> = {}) =>
      events.push(eventData(kind, values));
    for (const entry of ctx.sessionManager.getBranch()) {
      if (entry.type !== "message") continue;
      const message = entry.message;
      if (message.role === "user") {
        append("user_message", {
          message_id: entry.id,
          text: text(message.content),
          images: images.collect(message.content),
        });
      } else if (message.role === "assistant") {
        for (const [content_index, block] of message.content.entries()) {
          const values = { message_id: entry.id, content_index };
          if (block.type === "text")
            append("text_end", { ...values, text: block.text });
          else if (block.type === "thinking")
            append("thinking_end", { ...values, text: block.thinking });
          else if (block.type === "toolCall")
            append("tool_call_end", {
              ...values,
              tool_call_id: block.id,
              tool_name: block.name,
              text: JSON.stringify(block.arguments),
            });
        }
        append("message_end", {
          message_id: entry.id,
          is_error:
            message.stopReason === "error" || message.stopReason === "aborted",
        });
        if (message.errorMessage)
          append("error", { text: message.errorMessage, is_error: true });
      } else if (message.role === "custom" && message.display) {
        append("text_end", {
          message_id: entry.id,
          content_index: 0,
          text: text(message.content),
          images: images.collect(message.content),
        });
      } else if (message.role === "bashExecution") {
        append("tool_start", {
          tool_call_id: entry.id,
          tool_name: "bash",
          text: JSON.stringify({ command: message.command }),
        });
        append("tool_end", {
          tool_call_id: entry.id,
          tool_name: "bash",
          text: message.output,
          is_error:
            message.cancelled ||
            (message.exitCode !== undefined && message.exitCode !== 0),
          truncated: message.truncated,
        });
      } else if (message.role === "toolResult")
        append("tool_end", {
          tool_call_id: message.toolCallId,
          tool_name: message.toolName,
          text: text(message.content),
          images: images.collect(message.content),
          is_error: message.isError,
        });
    }
    append(settled ? "agent_settled" : "agent_start");
    events.push(...assistantEvents, ...[...runningTools.values()].flat());
    return events;
  }
  async function restoreHistory(ws: WebSocket) {
    while (socket === ws && active && ws.readyState === WebSocket.OPEN) {
      if (ws.bufferedAmount > 131072) {
        await new Promise((resolve) => setTimeout(resolve, 10));
        continue;
      }
      const next = historyQueue[historyCursor];
      if (!next) {
        historyQueue = [];
        historyCursor = 0;
        syncedGeneration = generation;
        syncingHistory = false;
        state(session.state);
        confirmIdle();
        return;
      }
      historyCursor++;
      emitEvent(next);
      if (historyCursor % 128 === 0)
        await new Promise((resolve) => setTimeout(resolve, 0));
    }
  }
  pi.on("message_start", (e) => {
    if (!active) return;
    if (e.message.role === "user") {
      event("user_message", {
        message_id: randomUUID(),
        text: text(e.message.content),
        images: images.collect(e.message.content),
      });
      if (
        pendingPrompt &&
        text(e.message.content) ===
          (pendingPrompt.ackText ?? pendingPrompt.text)
      ) {
        result(pendingPrompt.id, "accepted");
        pendingPrompt = undefined;
      }
    } else if (e.message.role === "assistant") {
      assistantMessageId = randomUUID();
      event("message_start", { message_id: assistantMessageId });
    }
  });
  pi.on("message_update", (e) => {
    if (!active) return;
    const update = e.assistantMessageEvent;
    if (!("contentIndex" in update)) return;
    const block = update.partial.content[update.contentIndex];
    const values: Partial<EventData> = {
      message_id: assistantMessageId,
      content_index: update.contentIndex,
    };
    switch (update.type) {
      case "text_start":
        event("text_start", values);
        break;
      case "text_delta":
        event("message_delta", { ...values, text: update.delta });
        break;
      case "text_end":
        event("text_end", { ...values, text: update.content });
        break;
      case "thinking_start":
        event("thinking_start", {
          ...values,
          text: block?.type === "thinking" ? block.thinking : "",
        });
        break;
      case "thinking_delta":
        event("thinking_delta", { ...values, text: update.delta });
        break;
      case "thinking_end":
        event("thinking_end", { ...values, text: update.content });
        break;
      case "toolcall_start":
      case "toolcall_delta":
      case "toolcall_end": {
        const call = update.type === "toolcall_end" ? update.toolCall : block;
        if (call?.type !== "toolCall") break;
        event(
          update.type === "toolcall_start"
            ? "tool_call_start"
            : update.type === "toolcall_delta"
              ? "tool_call_delta"
              : "tool_call_end",
          {
            ...values,
            tool_call_id: call.id || null,
            tool_name: call.name || null,
            // Deltas are raw JSON fragments; the end event is authoritative.
            text:
              update.type === "toolcall_delta"
                ? update.delta
                : update.type === "toolcall_end"
                  ? JSON.stringify(call.arguments)
                  : "",
          },
        );
        break;
      }
    }
  });
  pi.on("message_end", (e) => {
    if (!active) return;
    if (e.message.role === "custom" && e.message.display) {
      event("text_end", {
        message_id: randomUUID(),
        content_index: 0,
        text: text(e.message.content),
        images: images.collect(e.message.content),
      });
      return;
    }
    if (e.message.role === "bashExecution") {
      const id = randomUUID();
      event("tool_start", {
        tool_call_id: id,
        tool_name: "bash",
        text: JSON.stringify({ command: e.message.command }),
      });
      event("tool_end", {
        tool_call_id: id,
        tool_name: "bash",
        text: e.message.output,
        is_error:
          e.message.cancelled ||
          (e.message.exitCode !== undefined && e.message.exitCode !== 0),
        truncated: e.message.truncated,
      });
      return;
    }
    if (e.message.role !== "assistant") return;
    // Final blocks also repair providers that omit a block's end event on abort.
    e.message.content.forEach((block, content_index) => {
      const values = { message_id: assistantMessageId, content_index };
      if (block.type === "text")
        event("text_end", { ...values, text: block.text });
      else if (block.type === "thinking")
        event("thinking_end", { ...values, text: block.thinking });
      else if (block.type === "toolCall")
        event("tool_call_end", {
          ...values,
          tool_call_id: block.id,
          tool_name: block.name,
          text: JSON.stringify(block.arguments),
        });
    });
    event("message_end", {
      message_id: assistantMessageId,
      is_error:
        e.message.stopReason === "error" || e.message.stopReason === "aborted",
    });
    if (e.message.errorMessage)
      event("error", { text: e.message.errorMessage, is_error: true });
  });
  pi.on("tool_execution_start", (e) => {
    if (active)
      event("tool_start", {
        tool_call_id: e.toolCallId,
        tool_name: e.toolName,
        text: JSON.stringify(e.args),
      });
  });
  pi.on("tool_execution_update", (e) => {
    if (active)
      event("tool_update", {
        tool_call_id: e.toolCallId,
        tool_name: e.toolName,
        // Pi partial results contain cumulative output, not append-only chunks.
        text: text(e.partialResult?.content),
        images: images.collect(e.partialResult?.content),
      });
  });
  pi.on("tool_execution_end", (e) => {
    if (active)
      event("tool_end", {
        tool_call_id: e.toolCallId,
        tool_name: e.toolName,
        text: text(e.result?.content),
        images: images.collect(e.result?.content),
        is_error: e.isError,
      });
  });
}
