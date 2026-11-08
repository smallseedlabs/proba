# Image and version provenance

Recorded **2026-11-08** from public `main` clones. This is an inventory, not a signed SBOM and not proof that GHCR contains these bits.

## Sibling git SHAs (source of the process contracts)

| Repo | `origin/main` SHA | Notes |
|------|-------------------|--------|
| proba-hub | `b98f2c40c63d42d90205f01f2ab8b8311bf15a61` | Swarm stack exists; production requires `CONTEXT_BRIDGE_URL` |
| proba-web | `573bb9904d3437f901678f38900c83c095a7f1f7` | GET `/health` only |
| proba-audit | `15b49bbb54b7722c8655ce5c6858dca50748fc5b` | No sibling Swarm stack; compose `apps` profile is the production-like contract |
| proba-portal | `a8e3f55867b8290804aa627f8c02244c44886f00` | GET `/health` only |
| proba-memory | `e9d50b4a35e7fa3bff1e6661e9c6810c76313bc8` | No sibling Swarm stack |
| proba-context | `7f04e403d76467f01f8bc3b4af9993208db5e37d` | Digest-pinned Node base; last Dockerfile stage is `migrate` |
| proba-llm | `e486bf7090c552766b19b595c0a3c59e93b7887c` | Sibling stack replicas=1 |
| proba-llm-gateway | `b66ae7d9223fd31219402722ba5f1cc5c0dd4391` | PR6 evaluator; no extra HTTP routes |
| ad-domain | `2fbdcff2f636ff802d3e1e75b2c9f4cbd8640106` | PR7; no sibling stack; compose does not run the Ads process |
| proba-protocol | package **0.6.0** tag `v0.6.0` = `4ac21825570703b0ae5849a5fc6ed930c3694b0c` | Ads consumes 0.6.0; Hub/LLM/Gateway still pin **v0.4.0** on those mains |

No inspected sibling repo publishes to GHCR (`push: false` in CI). Stack image names `${REGISTRY:-ghcr.io/smallseedlabs}/…:${VERSION:-latest}` are **placeholders**. Operators must `docker build` from the SHA above, tag, and optionally pin a digest. `latest` is a gap, not a release.

## Suggested build tags (operator)

```bash
# Hub / web / llm / gateway / portal (single default runtime stage)
docker build -t "$REGISTRY/proba-hub:$VERSION" .
docker build -t "$REGISTRY/proba-web:$VERSION" .
docker build -t "$REGISTRY/proba-llm:$VERSION" .
docker build -t "$REGISTRY/proba-llm-gateway:$VERSION" .
docker build -t "$REGISTRY/proba-portal:$VERSION" .
docker build -t "$REGISTRY/ad-domain:$VERSION" .

# Multi-target (the default stage is not always the API)
docker build --target context-api -t "$REGISTRY/proba-context:$VERSION" .
docker build --target migrate -t "$REGISTRY/proba-context-migrate:$VERSION" .
docker build --target migrate -t "$REGISTRY/proba-audit-migrate:$VERSION" .
docker build --target audit-consumer -t "$REGISTRY/proba-audit-consumer:$VERSION" .
docker build --target audit-api -t "$REGISTRY/proba-audit-api:$VERSION" .
docker build --target metrics-ingester -t "$REGISTRY/proba-metrics-ingester:$VERSION" .
docker build --target rollup -t "$REGISTRY/proba-rollup:$VERSION" .
docker build --target migrate -t "$REGISTRY/proba-memory-migrate:$VERSION" .
docker build --target memory-api -t "$REGISTRY/proba-memory-api:$VERSION" .
docker build --target memory-ingestor -t "$REGISTRY/proba-memory-ingestor:$VERSION" .
docker build --target memory-jobs -t "$REGISTRY/proba-memory-jobs:$VERSION" .
```

## Infrastructure images

| Image | Pin | Source |
|-------|-----|--------|
| `postgres:16-alpine` | `sha256:0cefaabd882e42bcb2a2f3dc56d3ce4770560ba62fd7f197f1a2e008fd5731ab` | proba-context compose |
| `redis:7-alpine` | `sha256:bb186d083732f669da90be8b0f975a37812b15e913465bb14d845db72a4e3e08` | proba-context / llm compose |
| `clickhouse/clickhouse-server:24.12-alpine` | **tag only** | this umbrella `local/docker-compose.yml` (audit’s own compose still says 24.8-alpine) |
| `pgvector/pgvector:pg16` | **tag only** | proba-memory compose |
| `node:20-alpine` (app bases) | context/llm/gateway digest `sha256:fb4cd12c85ee03686f6af5362a0b0d56d50c58a04632e6c0fb8363f609372293`; hub/web/audit **unpinned** | sibling Dockerfiles |
| `node:22-alpine` (Ads) | `sha256:0e1754758c2df4cfa3e68d59e2e1b7374bb7fd9ea6328eaaacf15cc934af8202` | ad-domain Dockerfile |
| `nginx:1.31-alpine` (web) / `nginx:1.25-alpine` (portal) | **tag only** | sibling Dockerfiles |

## Integration that is **not** on these mains

- Hub has no `GATEWAY_URL` / `GATEWAY_ENABLED`.
- Gateway and LLM pin protocol v0.4.0; Ads pins v0.6.0.
- Ads compose does not start the Ads process; Reddit stays off unless the operator sets flags this stack file does not set.
- Page creation and gVisor sandbox are deferred (gateway docs: not in PR6).
- Landing page URL is never defaulted (web + Ads + protocol). Do not use smallseedlabs.com as a fallback.
