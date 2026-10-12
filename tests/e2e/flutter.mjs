import { approveFixtureClients } from './approval-fixture.mjs';
import { appSecretFixture } from './app-secret-fixture.mjs';
import { fixturePublicKey } from './crypto-fixture.mjs';
import { spawn, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { createServer as tcpServer } from 'node:net';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const root = resolve(fileURLToPath(new URL('../..', import.meta.url)));
const run = join(root, 'work/e2e', `flutter-${new Date().toISOString().replaceAll(':', '-')}`);
mkdirSync(run, {recursive: true});
const socket = `pirc-flutter-${randomUUID()}`;
const pi = spawnSync('command -v pi', {shell: true, encoding:'utf8'}).stdout.trim();
assert(pi, 'pi required');
const tcp = tcpServer(); await new Promise(r => tcp.listen(0, '127.0.0.1', r));
const port = tcp.address().port; await new Promise(r => tcp.close(r));
let service, fixture, heartbeat, flutter;
let passed = false;
const logs = [];
const quote = s => `'${s.replaceAll("'", "'\\''")}'`;
function tmux(...args) {
  const r = spawnSync('tmux', ['-L', socket, ...args], {encoding:'utf8'});
  assert.equal(r.status, 0, r.stderr); return r.stdout;
}
function input(pane, text) {
  assert(['pi-one','pi-two'].includes(pane));
  tmux('send-keys','-t',pane,'C-u'); tmux('send-keys','-t',pane,'-l',text); tmux('send-keys','-t',pane,'Enter');
}
async function start() {
  const env = {...process.env,HOME:run};
  service = spawn(join(root, 'target/debug/pirc'), ['server','--port',String(port)], {env});
  approveFixtureClients(service, root, env);
  service.stdout.on('data', b => logs.push(String(b))); service.stderr.on('data', b => logs.push(String(b)));
  const deadline = Date.now()+10000;
  while (Date.now()<deadline) {
    try { if ((await fetch(`http://127.0.0.1:${port}/health`)).ok) return; } catch {}
    await new Promise(r=>setTimeout(r,50));
  }
  throw Error('daemon not ready');
}
async function stop() {
  if (service && service.exitCode === null) {
    const done = new Promise(r => service.once('exit',r)); service.kill('SIGTERM'); await done;
  }
}
function launch(name) {
  const folder = join(run,name); mkdirSync(join(folder,'agent'),{recursive:true});
  writeFileSync(join(folder,'agent/settings.json'),JSON.stringify({quietStartup:true,compaction:{enabled:false,keepRecentTokens:100,reserveTokens:100},retry:{enabled:false}}));
  const config=join(folder,'pirc.json');
  writeFileSync(config,JSON.stringify({url:`ws://127.0.0.1:${port}/extension`}),{mode:0o600});
  const command = `exec env PI_CODING_AGENT_DIR=${quote(join(folder,'agent'))} PIRC_CONFIG=${quote(config)} PI_OFFLINE=1 PI_TELEMETRY=0 ${quote(pi)} --no-extensions --extension ${quote(join(root,'tests/e2e/provider.ts'))} --extension ${quote(join(root,'extensions/pi/index.ts'))} --provider pirc-test --model controlled --no-skills --no-prompt-templates --no-context-files --offline --tui-mode regular`;
  tmux('new-session','-d','-s',name,'-x','160','-y','48','-c',folder,command);
}
async function retainedFixture() {
  fixture = new WebSocket(`ws://127.0.0.1:${port}/extension`);
  const send = message => fixture.send(JSON.stringify({version:1,request_id:randomUUID(),message}));
  await new Promise((resolve,reject)=> {
    fixture.addEventListener('open',()=>send({type:'auth'}));
    fixture.addEventListener('error',reject,{once:true});
    fixture.addEventListener('message', e=> { if (JSON.parse(e.data).message.type==='welcome') resolve(); },{once:true});
  });
  const session={session_id:'retained-fixture',instance_id:'retained-fixture',cwd:'/retention-fixture',name:'Retention check',state:'idle',revision:1,needs_local_attention:false};
  send({type:'register',session});
  for (let seq=1;seq<=10002;seq++) {
    send({type:'event',session_id:session.session_id,instance_id:session.instance_id,source_seq:seq,seq:0,event:{kind:seq===10002?'user_message':'agent_start',message_id:null,text:seq===10002?'Message after retention limit':null,tool_call_id:null,tool_name:null,is_error:false,truncated:false}});
    if (seq%100===0) await new Promise(r=>setTimeout(r,2));
  }
  heartbeat=setInterval(()=>{if(fixture.readyState===WebSocket.OPEN)send({type:'heartbeat',session,source_seq:10002});},1000);
}
const admin=createServer(async(req,res)=> {
  try {
    const chunks=[]; for await(const chunk of req) chunks.push(chunk);
    const body=JSON.parse(Buffer.concat(chunks).toString() || '{}');
    if(req.url==='/input') input(body.pane,body.text);
    else if(req.url==='/restart') { await stop(); input('pi-one','QUICK lost while offline'); await new Promise(r=>setTimeout(r,500)); await start(); }
    else if(req.url==='/screenshot') writeFileSync(join(run,'local-alpha.png'),Buffer.from(body.png,'base64'));
    else if(req.url==='/report') writeFileSync(join(run,'checks.json'),JSON.stringify(body,null,2));
    else throw Error('Unknown test action');
    res.writeHead(200,{'content-type':'application/json'});res.end('{}');
  }catch(error){res.writeHead(500);res.end(String(error));}
});
let appSecrets;
try {
  appSecrets = appSecretFixture();
  await start(); launch('pi-one'); launch('pi-two'); await retainedFixture();
  await new Promise(resolve => admin.listen(0, '127.0.0.1', resolve));
  const adminPort = admin.address().port;

  flutter=spawn('flutter',['test','integration_test/local_alpha_test.dart','-d','macos','--dart-define=PIRC_SECRET_STORE=file',`--dart-define=PIRC_SECRET_FILE=${appSecrets.path}`,`--dart-define=PIRC_TEST_URL=http://127.0.0.1:${port}`,`--dart-define=PIRC_TEST_SERVER_KEY=${fixturePublicKey(join(run,'.pirc/server-key'))}`,`--dart-define=PIRC_TEST_ADMIN=http://127.0.0.1:${adminPort}`],{cwd:join(root,'apps/client'),stdio:['ignore','pipe','pipe']});
  flutter.stdout.on('data',b=>{process.stdout.write(b);logs.push(String(b));});
  flutter.stderr.on('data',b=>{process.stderr.write(b);logs.push(String(b));});
  const code=await new Promise(r=>flutter.once('exit',r)); assert.equal(code,0,'Flutter native integration failed'); assert(logs.join('').includes('All tests passed!'), 'Flutter did not finish its checks'); passed=true;
}finally{
  appSecrets?.cleanup();
  clearInterval(heartbeat);fixture?.close();await stop();
  for(const pane of ['pi-one','pi-two']) { try{writeFileSync(join(run,`${pane}.txt`),tmux('capture-pane','-p','-t',pane));}catch{} }
  spawnSync('tmux',['-L',socket,'kill-server']);admin.close();
  writeFileSync(join(run,'test.log'),logs.join(''));
  writeFileSync(join(run,'report.json'),JSON.stringify({passed,pi:'1.1.0',platform:'macOS',authentication:'server-approval',retentionFixtureEvents:10002},null,2));
  console.log(`Flutter report: ${run}`);
}
