import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  rmSync,
  symlinkSync,
  chmodSync,
  statSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:net";
import { once } from "node:events";
import { pathToFileURL } from "node:url";
import { decode } from "../../extensions/pi/protocol.ts";

const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(predicate: () => boolean, ms = 3000) {
  const end = Date.now() + ms;
  while (!predicate()) {
    assert(Date.now() < end, "Timed out waiting for condition");
    await delay(20);
  }
}

test(
  "remote browsing is paged, permission-aware and cannot block the controller",
  { timeout: 20000 },
  async () => {
    const root = mkdtempSync(join(tmpdir(), "pirc-directory-test-"));
    const pids = join(root, "pids");
    writeFileSync(pids, "");
    const home = join(root, "Device home");
    mkdirSync(home);
    for (let i = 0; i < 205; i++)
      mkdirSync(join(home, `project-${String(i).padStart(3, "0")}`));
    mkdirSync(join(home, ".hidden"));
    mkdirSync(join(home, "café 'quote $(touch nope)"));
    writeFileSync(join(home, "regular-file"), "content");
    // Merely listing the parent must not traverse a potentially protected link.
    symlinkSync("/pirc-test-inaccessible", join(home, "protected-link"));
    const helper = join(root, "helper.mjs");
    writeFileSync(
      helper,
      `
    import { appendFileSync } from 'node:fs';
    const requested = process.argv[3];
    if (requested === '/pirc-test-hang' || requested === '/pirc-test-create-hang') {
      appendFileSync(${JSON.stringify(pids)}, process.pid + '\\n');
      setInterval(() => {}, 1000);
    } else if (requested === '/pirc-test-denied') {
      process.stdout.write(JSON.stringify({type:'error', code:'DIRECTORY_PERMISSION_DENIED', detail:'Device denied directory access. Grant permission or choose another directory.'}));
    } else { await import(${JSON.stringify(pathToFileURL(join(process.cwd(), "scripts/list-directories.mjs")).href)}); }
  `,
    );
    const quote = (value: string) => `'${value.replaceAll("'", "'\\''")}'`;
    writeFileSync(join(root, "node"), `#!/bin/sh\nshift\nexec ${quote(process.execPath)} ${quote(helper)} "$@"\n`, { mode: 0o700 });
    const listener = createServer();
    listener.listen(0, "127.0.0.1");
    await once(listener, "listening");
    const port = (listener.address() as { port: number }).port;
    await new Promise<void>((resolve) => listener.close(() => resolve()));
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      HOME: home,

      PATH: `${root}:${process.env.PATH}`,
    };
    const server = spawn("./target/debug/pirc", ["server", "--port", String(port)], {
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let output = "";
    server.stdout.on("data", (chunk) => (output += chunk));
    server.stderr.on("data", (chunk) => (output += chunk));
    const sockets: WebSocket[] = [];
    let id = 0;
    const connect = async () => {
      const ws = new WebSocket(`ws://127.0.0.1:${port}/control`);
      sockets.push(ws);
      const replies = new Map<string, any>();
      ws.addEventListener("message", (event) => {
        const decoded = decode(String(event.data));
        assert(decoded, `Invalid directory protocol response: ${event.data}`);
        replies.set(decoded.request_id, decoded.message);
      });
      await new Promise<void>((resolve, reject) => {
        ws.addEventListener("open", () => resolve(), { once: true });
        ws.addEventListener("error", reject, { once: true });
      });
      ws.send(
        JSON.stringify({
          version: 1,
          request_id: "auth",
          message: { type: "auth" },
        }),
      );
      await until(() =>
        [...replies.values()].some((r) => r.type === "welcome"),
      );
      return {
        ws,
        request: async (message: object) => {
          const request_id = `directory-test-${++id}`;
          ws.send(JSON.stringify({ version: 1, request_id, message }));
          await until(() => replies.has(request_id), 7000);
          return replies.get(request_id);
        },
      };
    };
    const browse = (
      path: string | null = null,
      cursor: string | null = null,
      show_hidden = false,
    ) => ({ type: "browse_directories", path, cursor, show_hidden });
    const create = (parent: string, name: string) => ({
      type: "create_directory",
      parent,
      name,
    });
    const alive = (pid: number) => {
      try {
        process.kill(pid, 0);
        return true;
      } catch {
        return false;
      }
    };
    try {
      await until(() => output.includes("PiRC Server listening"));
      const client = await connect();
      const first = await client.request(browse());
      assert.equal(first.path, home);
      assert.equal(first.parent, root);
      assert.equal(first.directories.length, 200);
      assert(
        !first.directories.some((d: any) =>
          [".hidden", "protected-link", "regular-file"].includes(d.name),
        ),
      );
      const next = await client.request(browse(home, first.next_cursor));
      assert.equal(next.directories.length, 6);
      assert.equal(next.next_cursor, null);
      const all = [...first.directories, ...next.directories];
      assert.equal(new Set(all.map((d) => d.path)).size, 206);
      const special = all.find((d) => d.name.startsWith("café"));
      assert(special);
      assert.equal(
        (await client.request(browse(special.path))).directories.length,
        0,
      );
      const hidden = await client.request(browse("~", null, true));
      assert(hidden.directories.some((d: any) => d.name === ".hidden"));
      const createdName = "New project café '$(touch nope)";
      const created = await client.request(create(home, createdName));
      assert.deepEqual(created, {
        type: "directory_created",
        path: join(home, createdName),
      });
      assert(statSync(created.path).isDirectory());
      assert.equal(
        (await client.request(browse(created.path))).directories.length,
        0,
      );
      assert.equal(
        (await client.request(create(home, createdName))).code,
        "DIRECTORY_EXISTS",
      );
      assert.equal(
        (await client.request(create(home, "regular-file"))).code,
        "DIRECTORY_EXISTS",
      );
      assert.equal(readFileSync(join(home, "regular-file"), "utf8"), "content");
      for (const name of [
        "",
        " ",
        ".",
        "..",
        "../escape",
        "/absolute",
        "nested/folder",
        "nested\\folder",
        "\0",
        "€".repeat(86),
      ]) {
        assert.equal(
          (await client.request(create(home, name))).code,
          "INVALID_DIRECTORY_NAME",
        );
      }
      assert.equal(
        (await client.request(create("relative", "new"))).code,
        "INVALID_DIRECTORY",
      );
      assert.equal(
        (await client.request(create(join(home, "missing-parent"), "new")))
          .code,
        "DIRECTORY_NOT_FOUND",
      );
      const raced = await Promise.all([
        client.request(create(home, "raced")),
        client.request(create(home, "raced")),
      ]);
      assert.deepEqual(
        raced
          .map((result) =>
            result.type === "error" ? result.code : result.type,
          )
          .sort(),
        ["DIRECTORY_EXISTS", "directory_created"],
      );
      assert.equal(
        (await client.request(browse("relative/path"))).code,
        "INVALID_DIRECTORY",
      );
      assert.equal(
        (await client.request(browse(join(home, "missing")))).code,
        "DIRECTORY_NOT_FOUND",
      );
      assert.equal(
        (await client.request(browse("/pirc-test-denied"))).code,
        "DIRECTORY_PERMISSION_DENIED",
      );
      const denied = join(root, "permission-denied");
      mkdirSync(denied);
      try {
        chmodSync(denied, 0);
        assert.equal(
          (await client.request(browse(denied))).code,
          "DIRECTORY_PERMISSION_DENIED",
        );
        assert.equal(
          (await client.request(create(denied, "new"))).code,
          "DIRECTORY_PERMISSION_DENIED",
        );
      } finally {
        chmodSync(denied, 0o700);
      }
      const started = Date.now();
      const hanging = client.request(browse("/pirc-test-hang"));
      await until(() => readFileSync(pids, "utf8").trim().length > 0);
      assert.equal((await client.request({ type: "list" })).type, "sessions");
      assert(
        Date.now() - started < 1500,
        "Directory reads blocked ordinary controller requests",
      );
      assert.equal((await hanging).code, "DIRECTORY_TIMEOUT");
      assert(Date.now() - started < 6500);
      const pid = Number(readFileSync(pids, "utf8").trim().split("\n")[0]);
      await until(() => !alive(pid));
      assert.equal(
        (await client.request(browse(home))).type,
        "directory_list",
        "Timeout must release the read slot",
      );

      // Disconnect aborts the read and its process, rather than orphaning a consent wait.
      client.ws.send(
        JSON.stringify({
          version: 1,
          request_id: "cancelled",
          message: browse("/pirc-test-hang"),
        }),
      );
      await until(
        () => readFileSync(pids, "utf8").trim().split("\n").length === 2,
      );
      const cancelledPid = Number(
        readFileSync(pids, "utf8").trim().split("\n")[1],
      );
      client.ws.close();
      await until(() => !alive(cancelledPid));
      const reconnected = await connect();
      assert.equal(
        (await reconnected.request(browse(home))).type,
        "directory_list",
      );
      for (const request_id of ["busy-one", "busy-two"]) {
        reconnected.ws.send(
          JSON.stringify({
            version: 1,
            request_id,
            message: browse("/pirc-test-hang"),
          }),
        );
      }
      await until(
        () => readFileSync(pids, "utf8").trim().split("\n").length === 4,
      );
      assert.equal(
        (await reconnected.request(browse(home))).code,
        "DIRECTORY_BUSY",
      );
      assert.equal(
        (await reconnected.request({ type: "list" })).type,
        "sessions",
      );
      const concurrentPids = readFileSync(pids, "utf8")
        .trim()
        .split("\n")
        .slice(2)
        .map(Number);
      reconnected.ws.close();
      await until(() => concurrentPids.every((pid) => !alive(pid)));
      const writer = await connect();
      const createStarted = Date.now();
      const pendingCreate = writer.request(
        create("/pirc-test-create-hang", "new"),
      );
      await until(
        () => readFileSync(pids, "utf8").trim().split("\n").length === 5,
      );
      assert.equal((await writer.request({ type: "list" })).type, "sessions");
      assert(
        Date.now() - createStarted < 1500,
        "Folder creation blocked ordinary controller requests",
      );
      const expiredCreate = await pendingCreate;
      assert.equal(expiredCreate.code, "DIRECTORY_TIMEOUT");
      assert(expiredCreate.detail.includes("unconfirmed"));
      const createPid = Number(
        readFileSync(pids, "utf8").trim().split("\n")[4],
      );
      await until(() => !alive(createPid));
    } finally {
      for (const ws of sockets) ws.close();
      if (server.exitCode === null && server.signalCode === null) {
        const exited = once(server, "exit");
        server.kill("SIGTERM");
        await exited;
      }
      for (const pid of readFileSync(pids, "utf8")
        .trim()
        .split("\n")
        .map(Number)
        .filter(Boolean)) {
        if (alive(pid)) process.kill(pid, "SIGKILL");
      }
      rmSync(root, { recursive: true, force: true });
    }
  },
);
