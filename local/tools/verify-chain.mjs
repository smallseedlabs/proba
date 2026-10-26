// Runs INSIDE a proba-audit image (mounted at /app/tools by verify.sh and tamper-demo.sh).
// Verifies the hash chain of one workspace with proba-audit's own verifyChain and prints one JSON line:
//   {"ok":true,"checked":1234,"problems":[],...}
// Exit code 0 when the chain is intact, 2 when verifyChain found problems, 1 on errors.
import { createLogger, loadConfigFromEnvironment, verifyChain } from '@smallseedlabs/proba-audit-core';
import { createRuntime } from '@smallseedlabs/proba-audit-adapters';

const workspaceId = process.argv[2] || process.env.INGEST_WORKSPACE_ID || 'seedbed';
const config = loadConfigFromEnvironment({ serviceName: 'verify-chain', defaultPort: 0 });
const logger = createLogger({ service: 'verify-chain', level: 'error', env: config.env });
const runtime = await createRuntime(config, { logger });
let code = 0;
try {
  const result = await verifyChain(runtime.auditStore, workspaceId, {}, { pageSize: 1000, maxProblems: 10 });
  console.log(JSON.stringify({ database: config.clickhouse.database, ...result }));
  code = result.ok ? 0 : 2;
} catch (err) {
  console.log(JSON.stringify({ ok: false, error: String(err && err.message ? err.message : err) }));
  code = 1;
} finally {
  await runtime.close();
}
process.exit(code);
