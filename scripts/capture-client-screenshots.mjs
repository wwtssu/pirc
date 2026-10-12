import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const destination = resolve(root, 'docs/images');
const names = new Set(['client-sessions-en.png', 'client-conversation-en.png']);
await mkdir(destination, { recursive: true });
const received = new Set();
const server = createServer(async (request, response) => {
  const name = request.url.slice(1);
  if (request.method !== 'POST' || !names.has(name)) {
    response.writeHead(404).end();
    return;
  }
  try {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    await writeFile(resolve(destination, name), Buffer.concat(chunks));
    received.add(name);
    response.writeHead(200).end();
  } catch (error) {
    response.writeHead(500).end(String(error));
  }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
try {
  const { port } = server.address();
  const child = spawn('flutter', [
    'test', '-d', 'macos', 'integration_test/readme_screenshots_test.dart',
    `--dart-define=PIRC_SCREENSHOT_URL=http://127.0.0.1:${port}`,
  ], { cwd: resolve(root, 'apps/client'), stdio: 'inherit' });
  const status = await new Promise((resolve, reject) => {
    child.once('exit', resolve);
    child.once('error', reject);
  });
  if (status !== 0 || received.size !== names.size) throw Error('Screenshot capture failed');
  console.log('English client screenshots saved in docs/images.');
} finally {
  await new Promise(resolve => server.close(resolve));
}
