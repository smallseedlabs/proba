# Security defaults and operator-required inputs

Hardening in `deploy/` follows the **process contracts** on sibling mains (2026-11-08). This file is not a pentest report and not a clearance.

## Defaults encoded in the stacks

- Overlay-only: **no published ports**. Swarm cannot bind to `127.0.0.1`; publishing would expose every node address (the failure mode called out in `proba-hub` README).
- `NODE_ENV=production` on Hub, audit, memory, context, llm, gateway, ads.
- No `DEV_LOGIN_ENABLED`, no `AUDIT_API_TOKEN_VERIFIER=static`, no `MEMORY_API_TOKEN_VERIFIER=static`, no `ALLOW_STUB_CONNECTOR`, no in-memory adapter flags, no `INGRESS_PUBLIC`, no `REDDIT_ADS_ENABLED`.
- Redis: ACL user, `default` off, `@dangerous` denied, AOF on, password from Docker secret (not argv).
- ClickHouse: admin password only on `audit-migrate`; runtime uses `proba_consumer` / `proba_api`.
- Audit anchors live in **anchor-db**, not ClickHouse (matches proba-audit `apps` profile).
- Hub `BRAIN_PROVIDER=mock`. Paid DeepSeek stays on optional `proba-llm`, not in Hub.
- Gateway `ADS_DOMAIN_URL` empty (fail closed). `RESEARCH_HTTP_FETCH=false`. `GATEWAY_MAX_COST_USD` unset (not `$2`).
- Ads UnconfiguredProvider. `landingPageUrl` is a request field; **no default**, including no `smallseedlabs.com`.
- `update_config.failure_action: rollback` and resource limits on long-running services.
- Context cache is Redis (`deploy/config/context.production.yaml`).

CI: `scripts/check-stack-security.mjs` plus negative tests. The local-compose job is unchanged (loopback + no default passwords on `local/docker-compose.yml`).

## Operator-required inputs (no useful default)

| Input | Why |
|-------|-----|
| `POSTGRES_PASSWORD` and secret `postgres_password` (same value) | Hub image has no `DATABASE_URL_FILE` |
| `REDIS_PASSWORD` and secret `redis_password` | Hub/audit/memory/context interpolate `REDIS_URL` |
| `CLICKHOUSE_*_PASSWORD`, `ANCHOR_HMAC_KEY` (≥32 chars), `ANCHOR_DB_PASSWORD` | Audit production guards |
| `jwt_secret` | Hub refuses missing/dev JWT in production |
| `FIREBASE_PROJECT_ID`, `AUDIT_API_ADMIN_EMAILS` | Sign-in / audit reads; empty allow-lists allow nobody |
| `PUBLIC_HUB_URL`, `CORS_ORIGIN` | Browser calls; must be the operator TLS URL |
| `PROBA_KEYS_DIR` PEMs mode 0600 | Hub assertion private key; gateway LLM private key |
| Public JWKS secrets | Hub/context/audit/memory/gateway verify |
| Node labels `proba.keys` (and llm/gateway if used) | Bind mounts and local volumes are node-local |
| Memory embedder/LLM keys | Optional stack; production refuses hash/scripted |
| llm `LLM_API_KEY` secret | Optional paid path only |

Do not put customer deployment files, tokens, or private keys in this public repository.

## Known residual risks (do not overclaim)

- Deploy-time env interpolation still appears in `docker inspect` for Hub/audit Redis and DB URLs.
- ClickHouse official image takes the admin password as env.
- Docker secrets for JWKS are world-readable (0444); processes only require `go-w` on public material.
- Hub `/ready` does not prove Redis.
- llm/gateway `/ready` as Swarm healthcheck will restart the task if Redis or (for llm) provider **allowlist** ping fails — that ping does not call DeepSeek, but it is stricter than `/health`.
- Mock Hub brain plus optional gateway is **not** an integrated E2E control plane.
- `VERSION=latest` and unpublished GHCR tags.
- No claim that npm audit, gitleaks, or this checker equals exploitability review.

## Campaign / page URLs

User-entered campaign destination URLs stay request data. Stacks and examples do not default them to smallseedlabs.com or any other host. Future page URLs must be provider-neutral. Page generation and gVisor brain/limb sandbox are **out of this PR**.
