# Swarm rollout and rollback (prepared artifacts)

Independent **configuration hardening**, not a production deployment. Nothing in this repository inits Swarm, joins a node, changes DNS, or talks to a live model, ads provider, or paid resource.

Local compose in [`local/`](../local) is unchanged and is **not** this production overlay.

## Prepared vs runtime-tested

| Artifact | Status in this PR |
|----------|-------------------|
| `deploy/stacks/*.yml`, health contracts, secret/probe/rollback guards | **Prepared.** Statically validated (`deploy/scripts/validate.sh`). |
| Image builds / GHCR tags | **Not produced here.** Sibling CI is `push: false`. See [IMAGE_PROVENANCE.md](../deploy/IMAGE_PROVENANCE.md). |
| `docker stack deploy` / `service rollback` | **Not run.** `rollout.sh` / `rollback.sh` default to dry-run and refuse `--apply` in this environment. |
| Live `/ready` of Hub/audit/context/… | **Not run.** Requires images + secrets + overlay. |
| Isolated Postgres backup→restore | **Runtime-tested only when Docker is available**, on uniquely labeled disposable containers. Never against existing volumes. |

Static lint is not a security clearance and not “production-ready”.

## Operator prerequisites

1. A dedicated Swarm the operator already owns. Do **not** `docker swarm init/join` on a shared workstation that runs the local platform.
2. Node labels: `proba.keys=true` (Hub/context bind-mounted PEMs), and if using the optional paid path `proba.llm=true` / `proba.gateway=true` (exactly one node each).
3. External Docker secrets listed in `deploy/scripts/create-secrets.example.sh` (dry-run by default).
4. Private PEMs at `${PROBA_KEYS_DIR}` with **mode 0600**, owner uid **1001**. Docker secrets mount 0444; Hub and Gateway refuse group/other-readable private keys (`proba-hub` `src/auth/assertions/private-key.ts`, `proba-llm-gateway` `src/auth/private-key.ts`).
5. Images built from the SHAs in [IMAGE_PROVENANCE.md](../deploy/IMAGE_PROVENANCE.md) and tagged to match the stack files.
6. TLS reverse proxy **outside** these stacks. Stacks publish **no ports** (Swarm cannot loopback-bind). `PUBLIC_HUB_URL` / `CORS_ORIGIN` are the browser URLs, not `http://hub:3000`.
7. Firebase project id and allow-listed admin emails. Empty `FIREBASE_PROJECT_ID` makes Hub sign-in 503; audit-api/memory-api refuse `static` verifiers in production.
8. Context production config overlay (`deploy/config/context.production.yaml`) sets `cacheStore.backend: redis` because the image’s shipped YAML uses in-process cache with `allowMemoryInProduction: false`.

## What each stack is

Deploy as **separate stack names** (`proba-data`, `proba-app`, …). A second `docker stack deploy -c one-file.yml proba` would replace the whole stack.

| Alias | File | Required? | Live traffic |
|-------|------|-----------|--------------|
| data | `10-data.yml` | yes | none published |
| app | `20-app.yml` | yes for Hub | Hub mock brain; context required by Hub production guards |
| audit | `30-audit.yml` | for the trail | ingester idle (`PLATFORM_CONNECTORS` empty) |
| memory | `40-memory.yml` | no | will not start without real embedder/LLM keys |
| portal | `50-portal.yml` | no | static UI |
| llm | `60-llm.yml` | no | paid DeepSeek if deployed; **do not** from CI |
| gateway | `70-gateway.yml` | no | Hub does not call it on current hub main; `ADS_DOMAIN_URL` empty |
| ads | `80-ads.yml` | no | UnconfiguredProvider; Reddit off; no landing URL default |

Suggested order: data → app → audit → (memory, portal) → (llm, gateway, ads). Run migrate jobs and wait for them before relying on the API.

```bash
./deploy/scripts/validate.sh
./deploy/scripts/rollout.sh --stacks data,app,audit
# operator cluster only, after review:
# PROBA_I_ACCEPT_LIVE_STACK_UPDATE=1 ./deploy/scripts/rollout.sh --stacks data,app,audit --apply
```

## Update and rollback

Long-running services set `update_config.failure_action: rollback`, parallelism 1, and a matching `rollback_config`. Stateful services (Postgres, Redis, ClickHouse, llm, gateway, ads) use `order: stop-first`. Hub/web use `start-first`.

Hub replicas default to **1** (sibling hub stack uses 3). Known sibling limits if you raise replicas: in-process mock brain, per-replica rate limits, multiple audit relays unordered.

```bash
./deploy/scripts/rollback.sh --service proba-app_hub
```

`docker service rollback` does **not** undo a Postgres/ClickHouse schema migration. Restore from [BACKUP_RESTORE.md](BACKUP_RESTORE.md) if the migrate job already applied a forward migration.

## Health vs readiness

Swarm `healthcheck` follows [deploy/health-contracts.json](../deploy/health-contracts.json): `/health` except llm/gateway (`/ready`, copied from those sibling stacks).

Operator `/ready` (not used as Swarm liveness except llm/gateway):

- Hub: Postgres `SELECT 1` only — **not Redis**
- audit-api / memory-api / context / ads: as in the contract file
- web, portal, audit-consumer, metrics-ingester, rollup, memory-ingestor, memory-jobs: **no `/ready`**
- No process inspected here serves `/live`, `/livez`, `/readyz`, or `/healthz`

```bash
./deploy/scripts/readiness-check.sh --hub-url https://hub.example --web-url https://app.example
```

## Outstanding blockers (not claimed done)

- Images are not published; `VERSION=latest` is a placeholder.
- ClickHouse and pgvector tags have no digest in-repo.
- Hub `DATABASE_URL` / Redis URLs for Hub/audit/memory/context still interpolate passwords at deploy time (those processes have no `DATABASE_URL_FILE` / `REDIS_URL_FILE` except llm/gateway/ads).
- ClickHouse admin password cannot use `*_FILE` in the official image; it is env interpolation.
- Private key 0600 vs Docker secret 0444 (bind mounts).
- Hub is mock-brain; gateway/LLM/Ads are optional and **not** E2E-integrated on current mains (protocol 0.4.0 vs 0.6.0).
- Context memory/audit sources need those stacks healthy; `/ready` does not check them.
- No edge TLS proxy, DNS, or cert automation in this PR.
- Page creation and gVisor sandbox are deferred.

## Related

- [SECURITY_DEFAULTS.md](SECURITY_DEFAULTS.md)
- [BACKUP_RESTORE.md](BACKUP_RESTORE.md)
- [LOCAL_TESTING.md](LOCAL_TESTING.md) — laptop compose, not Swarm
