import { readFileSync } from 'node:fs';
import { createPrivateKey, createPublicKey } from 'node:crypto';
// Pin generated test identities out of band; never print or pass private keys.
export function fixturePublicKey(path) {
  const secret = Buffer.from(readFileSync(path, 'utf8').trim(), 'hex');
  const privateKey = createPrivateKey({key: Buffer.concat([Buffer.from('302e020100300506032b656e04220420','hex'), secret]), format:'der', type:'pkcs8'});
  const publicKey = createPublicKey(privateKey).export({format:'der',type:'spki'}).subarray(-32).toString('hex');
  secret.fill(0); return publicKey;
}
