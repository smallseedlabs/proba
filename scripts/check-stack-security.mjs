#!/usr/bin/env node
/**
 * Static guard for deploy/stacks/*.yml. Does not start Swarm or containers.
 *
 * Fails when a stack:
 *   1. publishes any port (Swarm cannot loopback-bind; data/apps stay overlay-only)
 *   2. uses host networking
 *   3. puts a default on a secret (`${NAME:-...}` / literal)
 *   4. sets a production-refused flag (static tokens, stubs, Reddit, ingress-public, …)
 *   5. probes an HTTP path the sibling process does not register
 *   6. omits restart/update/rollback/resource safeguards on long-running services
 *   7. names a Docker secret that is not external
 *   8. sets a reserved campaign/API destination host (hostname parse, not substring)
 *
 * Warnings (non-zero only with --strict-images): image tags defaulting to `latest`,
 * unpinned ClickHouse/pgvector tags. Those are provenance gaps, not a security clearance.
 */
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import yaml from 'js-yaml';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..');
const STACK_DIR = join(REPO_ROOT, 'deploy', 'stacks');
const CONTRACTS_PATH = join(REPO_ROOT, 'deploy', 'health-contracts.json');

const SECRET_PATTERN = /(PASSWORD|PASSWD|SECRET|HMAC_?KEY|API_?KEY|PRIVATE_?KEY|(^|_)TOKENS?$)/i;
/** Browser/Firebase web config: public identifiers, optional empty default allowed. */
const PUBLIC_NAMES = new Set(['FIREBASE_API_KEY']);
/** Token *counts* / model caps, not bearer secrets. */
const NOT_SECRET_TOKEN_NAME = /(BUDGET|PROMPT|COMPLETION|MAX_|RESPONSE_|RESERVE).*TOKEN/i;

function isSecretName(name) {
  if (!name || PUBLIC_NAMES.has(name) || FORBIDDEN_KEYS.has(name)) return false;
  if (NOT_SECRET_TOKEN_NAME.test(name)) return false;
  return SECRET_PATTERN.test(name);
}
const REQUIRED = /\$\{([A-Za-z_][A-Za-z0-9_]*):\?[^}]*\}/;
const SECRET_FILE = /^\/run\/(secrets|proba\/keys)\//;

const JOB_MODES = new Set(['replicated-job', 'global-job']);
const STATEFUL = /^(postgres|redis|clickhouse|anchor-db|.*-postgres|llm|gateway|ads)$/;

const FORBIDDEN_ENV = [
  { key: 'AUDIT_API_TOKEN_VERIFIER', equals: 'static' },
  { key: 'MEMORY_API_TOKEN_VERIFIER', equals: 'static' },
  { key: 'DEV_LOGIN_ENABLED', equals: 'true' },
  { key: 'INGRESS_PUBLIC', equals: 'true' },
  { key: 'REDDIT_ADS_ENABLED', equals: 'true' },
  { key: 'ALLOW_STUB_CONNECTOR', equals: 'true' },
  { key: 'ALLOW_IN_MEMORY_ADAPTERS', equals: 'true' },
  { key: 'ALLOW_LOCAL_EMBEDDER', equals: 'true' },
  { key: 'ALLOW_SCRIPTED_LLM', equals: 'true' },
  { key: 'ALLOW_DEV_CONTENT_SOURCE', equals: 'true' },
  { key: 'CONTEXT_ALLOW_LOCAL_IDENTITY', equals: 'true' },
  { key: 'ADS_ALLOW_TEST_FAKES', equals: 'true' },
];

const FORBIDDEN_KEYS = new Set(['AUDIT_API_STATIC_TOKENS', 'MEMORY_API_STATIC_TOKENS']);

const HTTP_SERVICES = new Set([
  'hub',
  'web',
  'portal',
  'audit-api',
  'audit-consumer',
  'metrics-ingester',
  'rollup',
  'memory-api',
  'memory-ingestor',
  'memory-jobs',
  'context',
  'llm',
  'gateway',
  'ads',
]);

function loadContracts() {
  return JSON.parse(readFileSync(CONTRACTS_PATH, 'utf8'));
}

/** js-yaml@4 does not apply Compose `<<:` merge keys; docker stack deploy does. */
function expandMerge(node) {
  if (Array.isArray(node)) return node.map(expandMerge);
  if (!node || typeof node !== 'object') return node;
  const out = {};
  if (Object.prototype.hasOwnProperty.call(node, '<<')) {
    const base = expandMerge(node['<<']);
    if (base && typeof base === 'object' && !Array.isArray(base)) Object.assign(out, base);
  }
  for (const [k, v] of Object.entries(node)) {
    if (k === '<<') continue;
    out[k] = expandMerge(v);
  }
  return out;
}

function envMap(service) {
  const env = service.environment;
  if (!env) return {};
  if (Array.isArray(env)) {
    const out = {};
    for (const item of env) {
      const i = String(item).indexOf('=');
      if (i > 0) out[item.slice(0, i)] = item.slice(i + 1);
    }
    return out;
  }
  return { ...env };
}

/** Apex host that must never be a default campaign/API destination. */
const FORBIDDEN_CAMPAIGN_HOST = 'smallseedlabs.com';

/**
 * Hostname of a YAML string if it is a URL or bare host. Compose interpolations
 * and non-URLs return ''. Comparison uses URL.hostname, not substring search.
 */
function hostnameOf(value) {
  const raw = String(value ?? '').trim();
  if (!raw || raw.includes('${')) return '';
  const candidate = /^[a-z][a-z0-9+.-]*:\/\//i.test(raw) ? raw : `https://${raw}`;
  try {
    return new URL(candidate).hostname.replace(/\.$/, '').toLowerCase();
  } catch {
    return '';
  }
}

function isForbiddenCampaignHost(hostname) {
  return hostname === FORBIDDEN_CAMPAIGN_HOST || hostname.endsWith(`.${FORBIDDEN_CAMPAIGN_HOST}`);
}

function flattenStrings(node, path = []) {
  const out = [];
  if (typeof node === 'string') out.push([path.join('.'), node, path[path.length - 1]]);
  else if (Array.isArray(node)) {
    for (const [i, v] of node.entries()) out.push(...flattenStrings(v, [...path, String(i)]));
  } else if (node && typeof node === 'object') {
    for (const [k, v] of Object.entries(node)) out.push(...flattenStrings(v, [...path, k]));
  }
  return out;
}

function healthcheckText(service) {
  const test = service.healthcheck?.test;
  if (!test) return '';
  return Array.isArray(test) ? test.join(' ') : String(test);
}

function extractHttpPath(text) {
  // wget form: http://127.0.0.1:8080/health
  // node -e form: '.../health' concatenated with PORT
  if (/(?:['"/])ready(?:['"/)]|$)/.test(text) && !/readyz/.test(text)) return '/ready';
  if (/(?:['"/])health(?:['"/)]|$)/.test(text) && !/healthz/.test(text)) return '/health';
  if (/(?:['"/])ping(?:['"/)]|$)/.test(text)) return '/ping';
  const m = text.match(/https?:\/\/[^/\s'"]+(\/[A-Za-z0-9._~/-]*)/);
  return m ? m[1].replace(/\/$/, '') || '/' : null;
}

function isJob(service) {
  return JOB_MODES.has(service.deploy?.mode);
}

function normEquals(value) {
  return String(value ?? '')
    .trim()
    .replace(/^["']|["']$/g, '')
    .toLowerCase();
}

/**
 * @param {object} doc parsed compose/stack YAML
 * @param {{ file?: string, contracts?: object }} [opts]
 * @returns {{ violations: string[], warnings: string[] }}
 */
export function checkStackDoc(doc, opts = {}) {
  const violations = [];
  const warnings = [];
  const file = opts.file || 'stack.yml';
  const contracts = opts.contracts || loadContracts();
  const prefix = (msg) => `${file}: ${msg}`;
  doc = expandMerge(doc);

  for (const [, value] of flattenStrings(doc)) {
    if (isForbiddenCampaignHost(hostnameOf(value))) {
      violations.push(prefix('sets a reserved campaign/API destination host; destinations have no default host'));
    }
  }
  for (const absent of contracts.absentOnAllInspectedMains ?? []) {
    const hcHits = Object.values(doc.services ?? {}).some((svc) => healthcheckText(svc).includes(absent));
    if (hcHits) {
      violations.push(prefix(`probes ${absent}, which no inspected process registers`));
    }
  }

  const secrets = doc.secrets ?? {};
  for (const [name, spec] of Object.entries(secrets)) {
    if (!spec || spec.external !== true) {
      violations.push(prefix(`secret ${name} must be external: true (do not commit secret files)`));
    }
  }

  for (const [path, value, key] of flattenStrings(doc)) {
    if (typeof key === 'string' && isSecretName(key)) {
      const v = String(value).trim();
      if (v === '') continue;
      if (SECRET_FILE.test(v)) continue;
      if (REQUIRED.test(v) && v.startsWith('${') && v.endsWith('}')) continue;
      const defaulted = [...v.matchAll(/\$\{([A-Za-z_][A-Za-z0-9_]*)(:?[-+])[^}]*\}/g)];
      for (const m of defaulted) {
        if (SECRET_PATTERN.test(m[1])) {
          violations.push(prefix(`${path}: secret ${m[1]} has a default; use \${${m[1]}:?set ${m[1]}}`));
        }
      }
      if (
        SECRET_PATTERN.test(key) &&
        !REQUIRED.test(v) &&
        !SECRET_FILE.test(v) &&
        !v.includes('${')
      ) {
        violations.push(prefix(`${path}: secret is a literal; use a required variable or /run/secrets/…`));
      }
    }
  }

  for (const [name, service] of Object.entries(doc.services ?? {})) {
    const loc = `${name}`;
    if (service.network_mode === 'host') {
      violations.push(prefix(`${loc}: network_mode host is forbidden`));
    }
    if (service.ports && service.ports.length > 0) {
      violations.push(
        prefix(`${loc}: publishes ${JSON.stringify(service.ports)}; overlay-only (Swarm cannot loopback-bind)`)
      );
    }

    const env = envMap(service);
    for (const key of FORBIDDEN_KEYS) {
      if (key in env && String(env[key] ?? '').trim() !== '') {
        violations.push(prefix(`${loc}: ${key} is local-only and refused in production`));
      }
    }
    for (const rule of FORBIDDEN_ENV) {
      if (rule.key in env && normEquals(env[rule.key]) === rule.equals) {
        violations.push(prefix(`${loc}: ${rule.key}=${rule.equals} is refused for production stacks`));
      }
    }

    const nodeEnv = env.NODE_ENV;
    if (HTTP_SERVICES.has(name) && !isJob(service) && name !== 'web' && name !== 'portal') {
      if (normEquals(nodeEnv) !== 'production') {
        violations.push(prefix(`${loc}: NODE_ENV must be production (got ${nodeEnv || 'missing'})`));
      }
    }

    const image = String(service.image ?? '');
    if (image.includes(':latest') || /\$\{VERSION:-[^}]*latest\}/.test(image)) {
      warnings.push(
        prefix(`${loc}: image tag defaults to latest; operator must pin a built digest (no GHCR publish workflow today)`)
      );
    }
    if (/clickhouse\/clickhouse-server:[^@]+$/.test(image) && !image.includes('@sha256:')) {
      warnings.push(prefix(`${loc}: ClickHouse tag is not digest-pinned (no digest in sibling repos)`));
    }
    if (/pgvector\/pgvector:[^@]+$/.test(image) && !image.includes('@sha256:')) {
      warnings.push(prefix(`${loc}: pgvector tag is not digest-pinned (none on proba-memory main)`));
    }

    const deploy = service.deploy ?? {};
    const job = isJob(service);
    if (!job) {
      if (!deploy.restart_policy) {
        violations.push(prefix(`${loc}: missing deploy.restart_policy`));
      }
      if (!deploy.resources?.limits) {
        violations.push(prefix(`${loc}: missing deploy.resources.limits`));
      }
      if (!deploy.update_config) {
        violations.push(prefix(`${loc}: missing deploy.update_config`));
      } else if (deploy.update_config.failure_action !== 'rollback') {
        violations.push(prefix(`${loc}: update_config.failure_action must be rollback`));
      }
      if (!deploy.rollback_config) {
        violations.push(prefix(`${loc}: missing deploy.rollback_config`));
      }
    } else if (!deploy.restart_policy) {
      violations.push(prefix(`${loc}: job missing deploy.restart_policy`));
    }

    const replicas = deploy.replicas;
    if (STATEFUL.test(name) && replicas !== undefined && Number(replicas) > 1) {
      violations.push(prefix(`${loc}: stateful/single-replica service has replicas=${replicas}`));
    }

    const hc = healthcheckText(service);
    if (HTTP_SERVICES.has(name) && !job) {
      const contract = contracts.services?.[name];
      if (!contract) {
        violations.push(prefix(`${loc}: no health contract in deploy/health-contracts.json (do not invent probes)`));
        continue;
      }
      if (!hc) {
        violations.push(prefix(`${loc}: missing healthcheck`));
        continue;
      }
      const path = extractHttpPath(hc);
      const expected = contract.swarmHealthcheck;
      if (!path) {
        violations.push(prefix(`${loc}: healthcheck does not include an HTTP path`));
      } else if (path !== expected) {
        violations.push(
          prefix(`${loc}: healthcheck probes ${path}, contract swarmHealthcheck is ${expected}`)
        );
      }
      if (contract.ready === null && path === '/ready') {
        violations.push(prefix(`${loc}: process has no GET /ready`));
      }
    }
    if (name === 'clickhouse' && hc && !hc.includes('/ping')) {
      violations.push(prefix(`${loc}: ClickHouse healthcheck must probe GET /ping (image contract)`));
    }
    if ((name === 'postgres' || name.endsWith('-postgres') || name === 'anchor-db') && hc && !hc.includes('pg_isready')) {
      violations.push(prefix(`${loc}: Postgres healthcheck must use pg_isready`));
    }
  }

  return { violations, warnings };
}

export function checkStackFile(file, contracts = loadContracts()) {
  const text = readFileSync(file, 'utf8');
  const doc = yaml.load(text);
  return checkStackDoc(doc, { file, text, contracts });
}

export function checkStackDir(dir = STACK_DIR, contracts = loadContracts()) {
  const files = readdirSync(dir)
    .filter((f) => f.endsWith('.yml') || f.endsWith('.yaml'))
    .sort();
  const violations = [];
  const warnings = [];
  if (files.length === 0) violations.push(`${dir}: no stack files`);
  for (const f of files) {
    const r = checkStackFile(join(dir, f), contracts);
    violations.push(...r.violations);
    warnings.push(...r.warnings);
  }
  return { violations, warnings, files };
}

function main() {
  const strictImages = process.argv.includes('--strict-images');
  const { violations, warnings, files } = checkStackDir();
  for (const w of warnings) console.warn(`warning: ${w}`);
  if (violations.length > 0) {
    console.error(`stack security check FAILED (${files.length} files):`);
    for (const v of violations) console.error(`  - ${v}`);
    process.exit(1);
  }
  if (strictImages && warnings.length > 0) {
    console.error('stack security check FAILED (--strict-images): image provenance warnings treated as errors');
    process.exit(1);
  }
  console.log(
    `stack security check passed: ${files.length} files, overlay-only ports, required secrets, contracted probes, rollback safeguards (${warnings.length} provenance warnings)`
  );
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
