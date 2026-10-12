import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createServer } from 'node:net';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { SessionManager } from '@earendil-works/pi-coding-agent';

assert.equal(process.platform, 'linux', 'Run this fixture on a headless Linux device');
const root = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const run = mkdtempSync(join(tmpdir(), 'pirc-headless-e2e-'));
const cwd = join(run, "project 'quoted");
const agent = join(run, 'agent');
const sessions = join(agent, 'sessions', 'fixture');
for (const path of [cwd, agent, sessions]) mkdirSync(path, {recursive:true});
writeFileSync(join(agent, 'settings.json'), JSON.stringify({ quietStartup: true, compaction: { enabled: false }, retry: { enabled: false } }));
const saved = SessionManager.create(cwd, sessions);
saved.appendMessage({ role: 'user', content: [{ type: 'text', text: 'Headless restore fixture' }], timestamp: Date.now() });
saved.appendMessage({ role: 'assistant', api: 'openai-completions', provider: 'pirc-test', model: 'controlled', content: [{ type: 'text', text: 'Saved response' }], stopReason: 'stop', timestamp: Date.now(), usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } });
saved.appendSessionInfo('Headless restore fixture');
const reservation = createServer();
await new Promise(r => reservation.listen(0, '127.0.0.1', r));
const port = reservation.address().port;
await new Promise(r => reservation.close(r));
const env = { ...process.env, DISPLAY: '', WAYLAND_DISPLAY: '', HOME: run, TMUX_TMPDIR: run, PI_CODING_AGENT_DIR: agent, PI_OFFLINE: '1' };
delete env.PI_CODING_AGENT_SESSION_DIR;
const server = spawn(process.env.PIRC_TEST_BINARY || join(root, 'target/release/pirc'), ['server', '--port', String(port)], { cwd: root, env, stdio: ['ignore', 'pipe', 'pipe'] });
let log = '';
server.stdout.on('data', b => { log += b; });
server.stderr.on('data', b => { log += b; });
let ws;
const frames = [];
async function wait(predicate, timeout = 30000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value) return value;
    assert.equal(server.exitCode, null, log);
    await new Promise(r => setTimeout(r, 30));
  }
  throw new Error(`Timed out. Server log:\n${log}\nRecent packets:\n${JSON.stringify(frames.slice(-10))}`);
}
async function request(message) {
  const request_id = randomUUID();
  ws.send(JSON.stringify({ version: 1, request_id, message }));
  return (await wait(() => frames.find(f => f.request_id === request_id))).message;
}
const tmux = (...args) => spawnSync('tmux', ['-L', 'pirc', ...args], { env, encoding: 'utf8' });
try {
  await wait(() => log.includes('PiRC Server listening on'));
  ws = new WebSocket(`ws://127.0.0.1:${port}/control`);
  ws.addEventListener('message', e => frames.push(JSON.parse(e.data)));
  await new Promise((resolve, reject) => { ws.addEventListener('open', resolve, { once: true }); ws.addEventListener('error', reject, { once: true }); });
  ws.send(JSON.stringify({ version: 1, request_id: randomUUID(), message: { type: 'auth' } }));
  const generation_id = (await wait(() => frames.find(f => f.message.type === 'welcome'))).message.generation_id;
  async function launch(session_id, name) {
    const result = await request({ type: 'launch_session', agent_id: 'pi', generation_id, cwd, session_id, name });
    assert.equal(result.type, 'session_launched', JSON.stringify(result));
    const session = (await wait(() => frames.find(f => f.message.type === 'snapshot' && f.message.session.launch_id === result.launch_id && f.message.session.state === 'idle'))).message.session;
    assert.equal(session.can_close, true);
    assert.equal(session.cwd, cwd);
    assert.equal(tmux('list-sessions', '-F', '#{session_name}').stdout.trim().split('\n').length, 1);
    return session;
  }
  async function close(session) {
    const snapshots = frames.filter(f => f.message.type === 'snapshot' && f.message.session.instance_id === session.instance_id);
    const latest = snapshots.at(-1)?.message.session || session;
    const result = await request({ type: 'close_session', generation_id, session_id: session.session_id, instance_id: session.instance_id, expected_revision: latest.revision });
    assert.equal(result.type, 'command_result', JSON.stringify(result));
    assert.equal(result.status, 'accepted', JSON.stringify(result));
    await wait(() => tmux('has-session').status !== 0);
  }
  const created = await launch(null, 'Headless create fixture');
  assert.equal(created.name, 'Headless create fixture');
  await close(created);
  console.log('PASS headless create, registration and graceful exit');
  const catalog = await request({ type: 'saved_sessions' });
  assert.equal(catalog.type, 'saved_session_list', JSON.stringify(catalog));
  assert(catalog.sessions.some(s => s.session_id === saved.getSessionId()));
  const restored = await launch(saved.getSessionId(), null);
  assert.equal(restored.session_id, saved.getSessionId());
  assert.equal(restored.name, 'Headless restore fixture');
  const history = await request({ type: 'history', session_id: restored.session_id, instance_id: restored.instance_id, direction: 'latest', cursor: null, limit: 20 });
  assert.equal(history.type, 'history_page', JSON.stringify(history));
  assert(JSON.stringify(history.items).includes('Saved response'));
  await close(restored);
  console.log('PASS headless restore, history and graceful exit');
} finally {
  ws?.close();
  tmux('kill-server');
  server.kill('SIGINT');
  await new Promise(r => server.exitCode !== null ? r() : server.once('exit', r));
  writeFileSync(join(run, 'server.log'), log);
  console.log(`Fixture files: ${run}`);
}
