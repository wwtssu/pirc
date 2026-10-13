import { readdir, open } from "node:fs/promises";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

// OMP's fixed-width title slot and session header live at the start of its
// JSONL files. Read metadata only; listing never launches the agent or opens UI.
export function sessionsRoot(
  env = process.env,
  home = homedir(),
  platform = process.platform,
) {
  const selected = (env.OMP_PROFILE ?? env.PI_PROFILE ?? "").trim();
  const profile = selected === "default" ? "" : selected;
  if (profile && !/^[a-z0-9][a-z0-9._-]{0,63}$/.test(profile))
    throw new Error("Invalid OMP profile");
  const root = join(home, ".omp", ...(profile ? ["profiles", profile] : []));
  const agent =
    !profile && env.PI_CODING_AGENT_DIR
      ? resolve(env.PI_CODING_AGENT_DIR)
      : join(root, "agent");
  if (
    (platform === "linux" || platform === "darwin") &&
    agent === join(root, "agent") &&
    env.XDG_DATA_HOME
  ) {
    const xdg = join(
      env.XDG_DATA_HOME,
      "omp",
      ...(profile ? ["profiles", profile] : []),
    );
    if (existsSync(xdg)) return join(xdg, "sessions");
  }
  return join(agent, "sessions");
}
export async function readSavedSession(path) {
  let file;
  try {
    file = await open(path, "r");
    const buffer = Buffer.alloc(64 * 1024);
    const { bytesRead } = await file.read(buffer, 0, buffer.length, 0);
    const records = [];
    for (const line of buffer
      .subarray(0, bytesRead)
      .toString("utf8")
      .split("\n")) {
      try {
        records.push(JSON.parse(line));
      } catch {}
    }
    const header = records.find((e) => e.type === "session");
    if (
      typeof header?.id !== "string" ||
      !header.id ||
      typeof header.cwd !== "string" ||
      !header.cwd
    )
      return null;
    const slot = records[0]?.type === "title" ? records[0] : undefined;
    const title = slot ? slot.title : header.title;
    const metadata = await file.stat();
    return {
      agent_id: "omp",
      session_id: header.id,
      cwd: header.cwd,
      name: typeof title === "string" && title.trim() ? title.trim() : null,
      modified_ms: Math.floor(metadata.mtimeMs),
      path,
    };
  } catch (error) {
    if (["ENOENT", "ENOTDIR", "EACCES", "EPERM"].includes(error.code))
      return null;
    throw error;
  } finally {
    await file?.close();
  }
}
export async function listSavedSessions(root = sessionsRoot()) {
  let folders;
  try {
    folders = await readdir(root, { withFileTypes: true });
  } catch (error) {
    if (error.code === "ENOENT" || error.code === "ENOTDIR") return [];
    throw error;
  }
  const result = [];
  const seen = new Set();
  for (const folder of folders) {
    if (!folder.isDirectory()) continue;
    let files;
    try {
      files = await readdir(join(root, folder.name), { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of files) {
      if (!entry.isFile() || !entry.name.endsWith(".jsonl")) continue;
      const saved = await readSavedSession(join(root, folder.name, entry.name));
      if (saved) result.push(saved);
    }
  }
  result.sort((a, b) => b.modified_ms - a.modified_ms);
  return result
    .filter((s) => {
      if (seen.has(s.session_id)) return false;
      seen.add(s.session_id);
      return true;
    })
    .slice(0, 1000);
}
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
) {
  process.stdout.write(JSON.stringify(await listSavedSessions()));
}
