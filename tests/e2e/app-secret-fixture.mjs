import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

// Native macOS tests retain the app sandbox. Give each run an isolated file
// inside its writable container, rather than granting access to host temp dirs.
export function appSecretFixture() {
  const base = join(homedir(), 'Library/Containers/io.github.wwtssu.pirc/Data/Library/Application Support');
  mkdirSync(base, { recursive: true });
  const directory = mkdtempSync(join(base, 'pirc-test-secrets-'));
  return {
    path: join(directory, 'secrets.json'),
    cleanup: () => rmSync(directory, { recursive: true, force: true }),
  };
}
