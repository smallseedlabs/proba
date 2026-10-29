#!/usr/bin/env node
/**
 * Mint a Hub act-as assertion JWT (EdDSA) for local verify-context.sh.
 *
 * Usage:
 *   node mint-assertion.mjs --user <userId> --workspace <workspaceId> --goal <goalId> [--thread <id>] [--scopes context:build]
 *
 * Reads CONTEXT_ASSERTION_PRIVATE_KEY_FILE or HUB_ASSERTION_PRIVATE_KEY_FILE (PKCS#8 PEM).
 * Optional HUB_ASSERTION_KEY_ID (default hub-key-1).
 */
import { createPrivateKey, randomUUID, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  if (i >= 0 && process.argv[i + 1]) return process.argv[i + 1];
  return fallback;
}

function b64url(input) {
  const buf = Buffer.isBuffer(input) ? input : Buffer.from(input);
  return buf.toString('base64url');
}

const pemPath =
  process.env.CONTEXT_ASSERTION_PRIVATE_KEY_FILE ||
  process.env.HUB_ASSERTION_PRIVATE_KEY_FILE ||
  '';
if (!pemPath) {
  console.error('set CONTEXT_ASSERTION_PRIVATE_KEY_FILE or HUB_ASSERTION_PRIVATE_KEY_FILE');
  process.exit(2);
}

const userId = arg('user');
const workspaceId = arg('workspace', 'seedbed');
const goalId = arg('goal');
const threadId = arg('thread', goalId);
const scopes = (arg('scopes', 'context:build') || '').split(',').map((s) => s.trim()).filter(Boolean);
const ttl = Number(arg('ttl', '240'));
const kid = process.env.HUB_ASSERTION_KEY_ID || 'hub-key-1';

if (!userId || !goalId) {
  console.error('usage: mint-assertion.mjs --user USER --goal GOAL [--workspace seedbed] [--thread THREAD]');
  process.exit(2);
}

const pem = readFileSync(pemPath, 'utf8');
const key = createPrivateKey(pem);
if (key.asymmetricKeyType !== 'ed25519') {
  console.error('assertion private key must be Ed25519');
  process.exit(2);
}

const iat = Math.floor(Date.now() / 1000);
const header = { alg: 'EdDSA', typ: 'JWT', kid };
const payload = {
  iss: 'proba-hub',
  aud: ['proba-context', 'proba-audit', 'proba-memory', 'proba-hub'],
  sub: userId,
  workspaceId,
  goalId,
  threadId,
  scopes,
  iat,
  exp: iat + Math.min(Math.max(1, ttl), 300),
  jti: randomUUID(),
};

const data = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
const sig = sign(null, Buffer.from(data), key);
process.stdout.write(`${data}.${b64url(sig)}\n`);
