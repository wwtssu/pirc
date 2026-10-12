import { test } from "node:test";
import assert from "node:assert/strict";
import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import extension from "../../extensions/pi/index.ts";

test("Extension checks actual idle state and launch capability before graceful exit", async (t) => {
  const originalSocket = globalThis.WebSocket;
  const keys = [
    "PIRC_CONFIG",
    "PIRC_URL",
    "PIRC_LAUNCH_ID",
    "PIRC_MANAGED_TERMINAL",
    "PIRC_RESTORE_HISTORY",
  ];
  const previous = keys.map((key) => process.env[key]);
  class Socket extends EventTarget {
    static OPEN = 1;
    static current: Socket;
    readyState = 1;
    bufferedAmount = 0;
    frames: any[] = [];
    constructor() {
      super();
      Socket.current = this;
    }
    send(text: string) {
      this.frames.push(JSON.parse(text));
    }
    close() {
      this.readyState = 3;
    }
    receive(message: object, id = "request") {
      this.dispatchEvent(
        new MessageEvent("message", {
          data: JSON.stringify({ version: 1, request_id: id, message }),
        }),
      );
    }
  }
  globalThis.WebSocket = Socket as unknown as typeof WebSocket;
  try {
    for (const scenario of [
      "manual",
      "unsupported",
      "busy",
      "queued",
      "stale",
      "idle",
    ]) {
      await t.test(scenario, () => {
        process.env.PIRC_CONFIG = "/nonexistent/pirc-exit-test.json";
        process.env.PIRC_URL = "ws://127.0.0.1:43123/extension";
        process.env.PIRC_RESTORE_HISTORY = "0";
        process.env.PIRC_MANAGED_TERMINAL =
          scenario === "unsupported" ? "0" : "1";
        if (scenario === "manual") delete process.env.PIRC_LAUNCH_ID;
        else process.env.PIRC_LAUNCH_ID = "launch";
        const hooks = new Map<string, (...args: any[]) => any>();
        let busy = false,
          queued = false,
          shutdowns = 0,
          aborts = 0;
        const pi = {
          on: (name: string, handler: (...args: any[]) => any) =>
            hooks.set(name, handler),
          getSessionName: () => "test",
          getCommands: () => [],
          getThinkingLevel: () => "off",
        } as unknown as ExtensionAPI;
        const context = {
          cwd: "/tmp",
          sessionManager: {
            getSessionId: () => "session",
            getBranch: () => [],
          },
          isIdle: () => !busy,
          hasPendingMessages: () => queued,
          shutdown: () => shutdowns++,
          abort: () => aborts++,
          ui: { notify: () => {} },
        } as unknown as ExtensionContext;
        extension(pi);
        hooks.get("session_start")!({}, context);
        const socket = Socket.current;
        try {
          socket.receive({ type: "welcome", generation_id: "generation" });
          const registered = socket.frames
            .filter((f) => ["register", "snapshot"].includes(f.message.type))
            .at(-1).message.session;
          busy = scenario === "busy";
          queued = scenario === "queued";
          if (scenario === "stale")
            hooks.get("session_info_changed")!({ name: "changed" });
          const request = {
            type: "close_session",
            generation_id: "generation",
            session_id: "session",
            instance_id: registered.instance_id,
            expected_revision: registered.revision,
          };
          socket.receive(request, "exit");
          const result = socket.frames.find(
            (f) => f.request_id === "exit",
          ).message;
          if (scenario === "idle") {
            assert.equal(result.status, "accepted");
            assert.equal(shutdowns, 1);
            socket.receive(request, "exit");
            socket.receive(request, "another-exit");
            assert.equal(shutdowns, 1);
            assert.equal(
              socket.frames.find((f) => f.request_id === "another-exit").message
                .code,
              "CLOSING",
            );
          } else {
            assert.equal(result.status, "rejected");
            assert.equal(
              result.code,
              scenario === "manual" || scenario === "unsupported"
                ? "UNMANAGED_TERMINAL"
                : scenario === "stale"
                  ? "STALE_STATE"
                  : "BUSY",
            );
            assert.equal(shutdowns, 0);
          }
          assert.equal(aborts, 0);
        } finally {
          hooks.get("session_shutdown")!();
        }
      });
    }
  } finally {
    globalThis.WebSocket = originalSocket;
    keys.forEach((key, i) => {
      if (previous[i] === undefined) delete process.env[key];
      else process.env[key] = previous[i];
    });
  }
});
