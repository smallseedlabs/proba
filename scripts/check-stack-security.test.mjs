import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import assert from 'node:assert/strict';
import yaml from 'js-yaml';
import { checkStackDoc, checkStackDir } from './check-stack-security.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');

function load(rel) {
  const file = join(ROOT, rel);
  const text = readFileSync(file, 'utf8');
  return { file: rel, text, doc: yaml.load(text) };
}

function clone(rel) {
  const { file, text, doc } = load(rel);
  return { file, text, doc: JSON.parse(JSON.stringify(doc)) };
}

test('committed stacks pass the static hardening check', () => {
  const { violations } = checkStackDir(join(ROOT, 'deploy/stacks'));
  assert.deepEqual(violations, []);
});

test('negative: published ports are rejected', () => {
  const { file, text, doc } = clone('deploy/stacks/50-portal.yml');
  doc.services.portal.ports = ['8080:8080'];
  const { violations } = checkStackDoc(doc, { file, text });
  assert.ok(violations.some((v) => v.includes('publishes')));
});

test('negative: host networking is rejected', () => {
  const { file, text, doc } = clone('deploy/stacks/50-portal.yml');
  doc.services.portal.network_mode = 'host';
  const { violations } = checkStackDoc(doc, { file, text });
  assert.ok(violations.some((v) => v.includes('network_mode host')));
});

test('negative: defaulted secret is rejected', () => {
  const { file, text, doc } = clone('deploy/stacks/10-data.yml');
  doc.services.clickhouse.environment.CLICKHOUSE_PASSWORD = '${CLICKHOUSE_PASSWORD:-proba}';
  const { violations } = checkStackDoc(doc, { file, text });
  assert.ok(violations.some((v) => v.includes('CLICKHOUSE_PASSWORD') && v.includes('default')));
});

test('negative: literal secret is rejected', () => {
  const { file, text, doc } = clone('deploy/stacks/10-data.yml');
  doc.services.clickhouse.environment.CLICKHOUSE_PASSWORD = 'please-change-me';
  const { violations } = checkStackDoc(doc, { file, text });
  assert.ok(violations.some((v) => v.includes('literal')));
});

test('negative: static audit verifier is rejected', () => {
  const { file, text, doc } = clone('deploy/stacks/30-audit.yml');
  doc.services['audit-api'].environment.AUDIT_API_TOKEN_VERIFIER = 'static';
  const { violations } = checkStackDoc(doc, { file, text });
  assert.ok(violations.some((v) => v.includes('AUDIT_API_TOKEN_VERIFIER=static')));
});

test('negative: stub connector is rejected', () => {
  const { file, text, doc } = clone('deploy/stacks/30-audit.yml');
  doc.services['metrics-ingester'].environment.ALLOW_STUB_CONNECTOR = 'true';
  const { violations } = checkStackDoc(doc, { file, text });
  assert.ok(violations.some((v) => v.includes('ALLOW_STUB_CONNECTOR')));
});

test('negative: Reddit enablement is rejected', () => {
  const { file, text, doc } = clone('deploy/stacks/80-ads.yml');
  doc.services.ads.environment.REDDIT_ADS_ENABLED = 'true';
  const { violations } = checkStackDoc(doc, { file, text });
  assert.ok(violations.some((v) => v.includes('REDDIT_ADS_ENABLED')));
});

test('negative: invented /readyz probe is rejected', () => {
  const { file, text, doc } = clone('deploy/stacks/50-portal.yml');
  doc.services.portal.healthcheck.test = ['CMD', 'wget', '--spider', 'http://127.0.0.1:8080/readyz'];
  const { violations } = checkStackDoc(doc, { file, text });
  assert.ok(violations.some((v) => v.includes('/readyz')));
});

test('negative: reserved campaign destination host is rejected', () => {
  const { file, text, doc } = clone('deploy/stacks/20-app.yml');
  doc.services.web.environment.API_BASE_URL = 'https://smallseedlabs.com/offer';
  const { violations } = checkStackDoc(doc, { file, text });
  assert.ok(violations.some((v) => v.includes('reserved campaign/API destination host')));
});

test('query-string mention of the reserved host is not a destination', () => {
  const { file, text, doc } = clone('deploy/stacks/20-app.yml');
  doc.services.web.environment.API_BASE_URL = 'https://example.test/offer?ref=smallseedlabs.com';
  const { violations } = checkStackDoc(doc, { file, text });
  assert.equal(
    violations.filter((v) => v.includes('reserved campaign/API destination host')).length,
    0
  );
});

test('comments that forbid the reserved host are not violations', () => {
  const { violations } = checkStackDir(join(ROOT, 'deploy/stacks'));
  assert.equal(
    violations.filter((v) => v.includes('reserved campaign/API destination host')).length,
    0
  );
});

test('negative: probing /ready on web is rejected', () => {
  const { file, text, doc } = clone('deploy/stacks/20-app.yml');
  doc.services.web.healthcheck.test = [
    'CMD',
    'wget',
    '--spider',
    'http://127.0.0.1:8080/ready',
  ];
  const { violations } = checkStackDoc(doc, { file, text });
  assert.ok(violations.some((v) => v.includes('/ready')));
});

test('negative: missing rollback safeguards are rejected', () => {
  const { file, text, doc } = clone('deploy/stacks/50-portal.yml');
  delete doc.services.portal.deploy.update_config;
  delete doc.services.portal.deploy.rollback_config;
  const { violations } = checkStackDoc(doc, { file, text });
  assert.ok(violations.some((v) => v.includes('update_config')));
  assert.ok(violations.some((v) => v.includes('rollback_config')));
});

test('negative: non-external docker secret is rejected', () => {
  const { file, text, doc } = clone('deploy/stacks/10-data.yml');
  doc.secrets.postgres_password = { file: './postgres_password.txt' };
  const { violations } = checkStackDoc(doc, { file, text });
  assert.ok(violations.some((v) => v.includes('external')));
});

test('negative: extra postgres replica is rejected', () => {
  const { file, text, doc } = clone('deploy/stacks/10-data.yml');
  doc.services.postgres.deploy.replicas = 2;
  const { violations } = checkStackDoc(doc, { file, text });
  assert.ok(violations.some((v) => v.includes('replicas=2')));
});

test('web has no /ready in the contract file', () => {
  const contracts = JSON.parse(readFileSync(join(ROOT, 'deploy/health-contracts.json'), 'utf8'));
  assert.equal(contracts.services.web.ready, null);
  assert.equal(contracts.services.portal.ready, null);
  assert.equal(contracts.services['audit-consumer'].ready, null);
  assert.equal(contracts.services.hub.ready.path, '/ready');
  assert.ok(contracts.services.hub.ready.doesNotCheck.includes('Redis'));
});
