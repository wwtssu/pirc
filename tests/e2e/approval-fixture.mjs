import { spawnSync } from 'node:child_process';
// Test fixtures only: never attach this helper to a user's running server.
export function approveFixtureClients(server, root, env) {
  let buffered = '';
  server.stdout.on('data', chunk => {
    buffered += chunk;
    let end;
    while ((end = buffered.indexOf('\n')) >= 0) {
      const line = buffered.slice(0, end); buffered = buffered.slice(end + 1);
      const match = line.match(/New client awaiting approval: pirc allow ([A-Z0-9]{4}-[A-Z0-9]{4})/);
      if (!match) continue;
      const result = spawnSync(`${root}/target/debug/pirc`, ['allow', match[1]], {env, encoding:'utf8'});
      if (result.status !== 0) throw Error(`Fixture approval failed: ${result.stderr}`);
    }
  });
}
