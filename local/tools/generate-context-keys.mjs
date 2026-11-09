#!/usr/bin/env node
/**
 * Generate local-only Ed25519 key pairs for the context bridge, Hub act-as assertions and the agents profile
 * (Hub -> gateway service tokens, gateway -> llm/ads service tokens). Existing files are never overwritten.
 * Writes PEM private keys and public JWKS under local/keys/. Never commit the output.
 *
 * Usage: node local/tools/generate-context-keys.mjs [keys-dir]
 */
import { generateKeyPairSync } from 'node:crypto';
import { mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const keysDir = resolve(process.argv[2] || join(here, '..', 'keys'));

function writePair(name, kid) {
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const pem = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const jwk = publicKey.export({ format: 'jwk' });
  const jwks = { keys: [{ ...jwk, kid, alg: 'EdDSA', use: 'sig' }] };
  const pemPath = join(keysDir, `${name}.private.pem`);
  const jwksPath = join(keysDir, `${name}.public.jwks.json`);
  if (!existsSync(pemPath)) {
    writeFileSync(pemPath, pem, { mode: 0o600 });
  }
  if (!existsSync(jwksPath)) {
    writeFileSync(jwksPath, `${JSON.stringify(jwks, null, 2)}\n`, { mode: 0o644 });
  }
  return { pemPath, jwksPath, kid };
}

mkdirSync(keysDir, { recursive: true, mode: 0o700 });
const hub = writePair('hub-assertion', 'hub-key-1');
const bridge = writePair('context-service', 'bridge-key-1');
const hubGateway = writePair('hub-gateway-service', 'hub-gw-1');
const gatewayLlm = writePair('gateway-llm', 'gateway-llm-1');

process.stdout.write(
  JSON.stringify(
    {
      keysDir,
      HUB_ASSERTION_PRIVATE_KEY_FILE: hub.pemPath,
      HUB_ASSERTION_PUBLIC_KEY_FILE: hub.jwksPath,
      HUB_ASSERTION_KEY_ID: hub.kid,
      CONTEXT_SERVICE_PRIVATE_KEY_FILE: bridge.pemPath,
      CONTEXT_SERVICE_PUBLIC_KEY_FILE: bridge.jwksPath,
      CONTEXT_SERVICE_KEY_ID: bridge.kid,
      // Alias used by verify-context.sh for minting act-as assertions.
      CONTEXT_ASSERTION_PRIVATE_KEY_FILE: hub.pemPath,
      HUB_GATEWAY_PRIVATE_KEY_FILE: hubGateway.pemPath,
      HUB_GATEWAY_KEY_ID: hubGateway.kid,
      GATEWAY_LLM_PRIVATE_KEY_FILE: gatewayLlm.pemPath,
      GATEWAY_LLM_KEY_ID: gatewayLlm.kid,
    },
    null,
    2
  ) + '\n'
);
