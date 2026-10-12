import { appSecretFixture } from './app-secret-fixture.mjs';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { createServer } from 'node:net';
const root = resolve(import.meta.dirname, '../..');
const children = [];
const device = process.env.PIRC_TEST_DEVICE || 'macos';
const android = process.env.PIRC_TEST_PLATFORM === 'android';
const reversedPorts = [];
const release = process.env.PIRC_TEST_BUILD_MODE === 'release';
if (release && !android) throw Error('Release integration tests require an Android AVD');
const dir = await mkdtemp(`${tmpdir()}/pirc-encrypted-test-`);
async function port() {
  const s = createServer(); await new Promise(r => s.listen(0, '127.0.0.1', r));
  const value = s.address().port; await new Promise(r => s.close(r)); return value;
}
function watchOutput(child, onLine = () => {}) {
  let buffered = '';
  child.stdout.on('data', chunk => {
    process.stdout.write(chunk); buffered += chunk;
    let end;
    while ((end = buffered.indexOf('\n')) >= 0) {
      const line = buffered.slice(0, end); buffered = buffered.slice(end + 1);
      const request = line.match(/PIRC_TEST_ALLOW ([AB]) ([A-Z0-9]{4}-[A-Z0-9]{4})/);
      if (request) {
        const approval = spawnSync(`${root}/target/debug/pirc`, ['allow', request[2]], {env: {...process.env, HOME: `${dir}/${request[1]}`}, encoding:'utf8'});
        if (approval.status !== 0) { process.stderr.write(approval.stderr); child.kill('SIGTERM'); }
      }
      onLine(line);
    }
  });
}
async function run(command, args, cwd = root) {
  const child = spawn(command, args, {cwd, stdio: ['ignore', 'pipe', 'inherit']});
  watchOutput(child);
  const code = await new Promise((resolve, reject) => {
    child.once('exit', resolve); child.once('error', reject);
  });
  if (code !== 0) throw Error(`${command} exited ${code}`);
}
async function androidRelease(defines) {
  await run('flutter', ['build','apk','--release','--target-platform','android-arm64','--target','integration_test/multi_computer_test.dart',...defines,'--dart-define=PIRC_TEST_REPORT_COMPLETION=true','--dart-define=INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false'], `${root}/apps/client`);
  await run('adb', ['-s',device,'install','-r',`${root}/apps/client/build/app/outputs/flutter-apk/app-release.apk`]);
  let logger;
  let timer;
  try {
    await run('adb', ['-s',device,'logcat','-c']);
    logger = spawn('adb', ['-s',device,'logcat','-v','brief','flutter:I','AndroidRuntime:E','*:S'], {stdio:['ignore','pipe','inherit']});
    children.push(logger);
    const result = new Promise((resolve, reject) => {
      timer = setTimeout(() => reject(Error('Android Release integration test timed out')), 120000);
      logger.once('error', reject);
      logger.once('exit', code => reject(Error(`Android log reader exited ${code} before a test result`)));
      watchOutput(logger, line => {
        if (line.includes('PIRC_TEST_RESULT PASS')) resolve();
        if (line.includes('PIRC_TEST_RESULT FAIL')) reject(Error('Android Release integration test failed'));
      });
    });
    await Promise.all([
      result,
      run('adb', ['-s',device,'shell','am','start','-W','-n','io.github.wwtssu.pirc/.MainActivity']),
    ]);
  } finally {
    clearTimeout(timer);
    logger?.kill('SIGINT');
    spawnSync('adb', ['-s',device,'shell','am','force-stop','io.github.wwtssu.pirc']);
    spawnSync('adb', ['-s',device,'uninstall','io.github.wwtssu.pirc']);
  }
}
async function server(name) {
  const p = await port(); let output = '';
  const child = spawn(`${root}/target/debug/pirc`, ["server", "--port", `${p}`], {cwd: root, env: {...env, HOME: `${dir}/${name}`}, stdio: ['ignore','pipe','pipe']});
  children.push(child); child.stdout.on('data', x => output += x); child.stderr.on('data', x => output += x);
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw Error(`Fixture failed: ${output}`);
    const fingerprint = output.match(/PiRC encryption fingerprint:\s*([A-F0-9]{8}(?: [A-F0-9]{8}){7})/);
    if (fingerprint && output.includes('listening')) return {url: `http://127.0.0.1:${p}`, fingerprint: fingerprint[1]};
    await new Promise(r => setTimeout(r, 50));
  }
  throw Error(`Fixture timed out: ${output}`);
}
let appSecrets;
try {
  appSecrets = android
    ? {path: `/data/user/0/io.github.wwtssu.pirc/files/pirc-test-${Date.now()}.json`, cleanup() {}}
    : appSecretFixture();
  await run('cargo', ['build','-p','pirc-server']);
  const a = await server('A'); const b = await server('B');
  let addressA = a.url, addressB = b.url;
  const extra = [];
  if (android) {
    const portB = new URL(b.url).port;
    for (const [devicePort, hostPort] of [['43123', new URL(a.url).port], [portB, portB]]) {
      await run('adb', ['-s', device, 'reverse', `tcp:${devicePort}`, `tcp:${hostPort}`]);
      reversedPorts.push(devicePort);
    }
    addressA = 'http://127.0.0.1'; // Exercise the omitted service-default port.
    addressB = `http://10.0.2.2:${portB}`; // Android emulator's host-network alias.
    extra.push(`--dart-define=PIRC_TEST_AGENT_SERVER_B=${b.url}`);
  }
  const secretArgs = android && release
    ? [] // Exercise Android's production secure storage in Release.
    : ['--dart-define=PIRC_SECRET_STORE=file', `--dart-define=PIRC_SECRET_FILE=${appSecrets.path}`];
  const defines = [...secretArgs,`--dart-define=PIRC_TEST_SERVER_A=${addressA}`,`--dart-define=PIRC_TEST_SERVER_B=${addressB}`,...extra];
  if (release) await androidRelease(defines);
  else await run('flutter', ['test','integration_test/multi_computer_test.dart','-d',device,...defines], `${root}/apps/client`);
} finally {
  appSecrets?.cleanup();
  for (const port of reversedPorts) spawnSync('adb', ['-s', device, 'reverse', '--remove', `tcp:${port}`]);
  for (const child of children) child.kill('SIGINT');
  await Promise.all(children.map(child => child.exitCode !== null || child.signalCode !== null ? Promise.resolve() : new Promise(r => child.once('exit',r))));
  await rm(dir, {recursive:true, force:true});
}
