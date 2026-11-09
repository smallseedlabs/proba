#!/usr/bin/env node
/**
 * Local-only keys for ad platform connections (Marketing section). Existing files are never overwritten.
 *   hub-connections.key            32 random bytes (hex), the Hub's key for encrypting provider refresh tokens
 *   ads-service.private.pem        Ed25519 key Ads signs connection-broker calls with (kid ads-svc-1)
 *   ads-service.public.jwks.json   its public JWKS, read by the Hub
 * Prints file names only, never key material. Never commit the output.
 *
 * Usage: node local/tools/generate-connection-keys.mjs [keys-dir]
 */
import { generateKeyPairSync, randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const keysDir = resolve(process.argv[2] || join(here, '..', 'keys'));
mkdirSync(keysDir, { recursive: true, mode: 0o700 });
const created = [];

const keyPath = join(keysDir, 'hub-connections.key');
if (!existsSync(keyPath)) {
  writeFileSync(keyPath, `${randomBytes(32).toString('hex')}\n`, { mode: 0o600 });
  created.push('hub-connections.key');
}

const pemPath = join(keysDir, 'ads-service.private.pem');
const jwksPath = join(keysDir, 'ads-service.public.jwks.json');
if (!existsSync(pemPath) || !existsSync(jwksPath)) {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  writeFileSync(pemPath, privateKey.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
  const jwks = { keys: [{ ...publicKey.export({ format: 'jwk' }), kid: 'ads-svc-1', alg: 'EdDSA', use: 'sig' }] };
  writeFileSync(jwksPath, `${JSON.stringify(jwks, null, 2)}\n`, { mode: 0o644 });
  created.push('ads-service.private.pem', 'ads-service.public.jwks.json');
}

process.stdout.write(`${JSON.stringify({ keysDir, created })}\n`);
