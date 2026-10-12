import { SessionManager } from "@earendil-works/pi-coding-agent";

const sessions = await SessionManager.listAll();
const seen = new Set();
const result = [];
for (const session of sessions) {
  if (!session.cwd || seen.has(session.id)) continue;
  seen.add(session.id);
  result.push({
    agent_id: "pi",
    session_id: session.id,
    cwd: session.cwd,
    name: session.name ?? null,
    modified_ms: session.modified.getTime(),
    path: session.path,
  });
}
process.stdout.write(JSON.stringify(result));
