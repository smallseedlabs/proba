# Stateful backup, restore, and recovery drill

Prepared procedures for the Swarm data plane in `deploy/stacks/10-data.yml` (and optional sibling Postgres volumes). This is **not** a distributed snapshot. Postgres, Redis AOF, and ClickHouse can diverge if writers keep running.

## What is stateful

| Store | Volume (stack-local name) | Why it must be consistent |
|-------|---------------------------|---------------------------|
| Hub Postgres | `postgres_data` | Hub rows + outbox |
| Redis | `redis_data` | `proba.audit.events` stream + Hub pub/sub. AOF `everysec` |
| ClickHouse | `clickhouse_data` | Hash-chained `audit_events` (system of record for the trail) |
| Anchor Postgres | `anchor_data` | Signed chain heads; separate from ClickHouse on purpose |
| Context Postgres | `context_postgres_data` | Packet manifests only (no item text) |
| Memory Postgres | `memory_postgres_data` | Optional |
| Ads Postgres | `ads_postgres_data` | Optional, schema `ads` only |
| llm / gateway local volumes | `llm_turn_data`, `gateway_run_data` | **Not shared.** A restore onto another node can replay a paid/idempotent call. Prefer remaining on the labeled node. |

The audit stream is a buffer; ClickHouse (and anchors) are the trail. Restoring Redis without ClickHouse, or the reverse, can duplicate or drop consumer offsets.

## Quiesce order (operator)

Do this on the operator cluster, not from this agent, and not against the laptop `proba-local` project.

1. Stop writers: scale Hub, audit-consumer, metrics-ingester, rollup, memory-ingestor, ads, llm, gateway to 0 (named services only).
2. Wait until `pg_isready`, Redis PING, ClickHouse `/ping` succeed and there are no in-flight migrate jobs.
3. `deploy/scripts/backup.sh --filter label=proba.backup.role=postgres --output /var/backups/proba/…`
4. Repeat `--role redis` and `--role clickhouse`.
5. Scale writers back.

`backup.sh` refuses to run without a `proba.*` label filter. It does not `prune`, `system prune`, or `down -v`.

Postgres dump is `pg_dump --format=custom`. Redis copies `dump.rdb` / `appendonly.aof` (best-effort BGSAVE). ClickHouse in this script only inventories databases; a real `BACKUP DATABASE proba_audit TO Disk('…')` needs an operator-configured backup disk or S3 — not invented here.

## Restore drill (safe)

Restore **into new containers**, never onto a live volume:

```bash
./deploy/scripts/restore.sh \
  --backup /path/to/backup \
  --into-label label=proba.isolated-drill-id=… \
  --name-prefix proba-restore-yyyymmdd
```

The isolated proof used in CI / this workspace:

```bash
./deploy/scripts/isolated-backup-drill.sh
```

That starts a uniquely labeled Postgres on `127.0.0.1` with a random host port, writes a marker row, dumps, restores into a second labeled container, checks the marker, and deletes **only** those labeled containers. It will not match `proba-local_*` volumes.

## Recovery notes

- After a Hub Postgres restore, run `hub-migrate` before Hub replicas (idempotent migrations, advisory lock on Hub).
- After ClickHouse restore, run `audit-migrate` before consumers (role users + schema).
- Do not replay Redis stream entries into Ads or Hub command handlers; the stream is audit transport. Ads README: replay must never execute commands.
- Anchors and events belong together. Restoring events without anchors, or anchors without events, makes `GET /v1/chain/verify` lie or fail. Treat them as one restore group.
- llm/gateway file outboxes: if you must move nodes, treat in-flight idempotency keys as **unsafe to retry** until an operator inspects `TURN_STORE_DIR` / `RUN_STORE_DIR`.

## What this PR did not test

- ClickHouse `BACKUP DATABASE` to object storage
- Redis AOF restore into a running ACL server
- Concurrent writers during backup
- Restoring onto an existing Swarm volume
- Any existing local `proba-local_*` data
