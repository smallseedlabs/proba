# Production-oriented Swarm artifacts

Prepared configuration for a dedicated Docker Swarm. **Not deployed from this repository.** `rollout.sh` is dry-run unless an operator on their own cluster opts in.

| Path | What it is |
|------|------------|
| `stacks/` | Overlay stacks (no published ports) |
| `config/context.production.yaml` | Context cache = Redis (image default would refuse production) |
| `health-contracts.json` | Real `/health` and `/ready` from sibling mains |
| `IMAGE_PROVENANCE.md` | SHAs, tags, missing GHCR publish |
| `operator.example.env` | Placeholder names only |
| `scripts/validate.sh` | Static checks + negative tests |
| `scripts/isolated-backup-drill.sh` | Disposable labeled Postgres dump/restore |

Read [docs/DEPLOYMENT.md](../docs/DEPLOYMENT.md), [docs/SECURITY_DEFAULTS.md](../docs/SECURITY_DEFAULTS.md), [docs/BACKUP_RESTORE.md](../docs/BACKUP_RESTORE.md).

Do not edit Ads, Gateway, Hub, or LLM **source** from this repo. Optional stacks wrap published **image contracts** only. Hub/LLM/Ads/Gateway are not assumed E2E-integrated.
