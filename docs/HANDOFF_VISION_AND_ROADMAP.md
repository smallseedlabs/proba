# Handoff: Proba vision, architecture and remaining work

This is a self-contained handoff so another agent can continue without the prior chat. Facts below were checked against GitHub and the checkouts on the operator's Mac (`~/Projects/proba`) on **Saturday 14 November 2026, about 10:55 Europe/London (UTC+0)**. Re-check open PRs and `origin/main` before acting; the operator was merging during this snapshot.

Org: [smallseedlabs](https://github.com/smallseedlabs). Operator: Sangam Dubey. Do not scrap the existing backend; extend it to enterprise grade. Product and engineering decisions are made by the agent as staff designer/engineer; the operator only overrides.

---

## 0. Read this first: stacked PRs marked "merged" that are not on `main`

Several stacked PRs were merged on GitHub **into their feature-branch bases**, not into `main`. GitHub shows them as merged; `origin/main` does **not** contain the commits. Confirm with `git merge-base --is-ancestor <head> origin/main` before treating any of them as landed.

| PR | Intended change | GitHub state | Actually on `origin/main`? |
| --- | --- | --- | --- |
| [proba-memory #10](https://github.com/smallseedlabs/proba-memory/pull/10) | Self memory `2026-11-14.4`: brain drafts copy with `creative.draft_post`; operator copy is an override | Merged into `cursor/self-memory-bootstrap` at 10:50:38 UTC | **No.** `origin/main` tip is the squash of [#9](https://github.com/smallseedlabs/proba-memory/pull/9) (`e1e8028`). Seed file is still version `2026-11-14.3` and still says "do not write it yourself." Head to re-PR: `7fd373585bd78cc285441e118ef32dc3fa5ad550` (`cursor/self-memory-creative-draft`). |
| [proba-llm-gateway #16](https://github.com/smallseedlabs/proba-llm-gateway/pull/16) | `GET`/`PUT /v1/admin/guardrails` | Merged into `cursor/self-memory-bootstrap` at 10:51:32 UTC | **No.** `src/http/admin-guardrails.ts` is not on `origin/main`. Commits: `817d98a`, `be4528f`, `79531a1`. |
| [proba-llm-gateway #18](https://github.com/smallseedlabs/proba-llm-gateway/pull/18) | `creative.draft_post` verb + checks | Merged into `cursor/gateway-guardrails-admin` at 10:52:00 UTC | **No.** Head `20597cf` is not an ancestor of `origin/main`. |

**Required follow-up (do this before relying on draft-copy or the Portal Guardrails screen):** open new PRs that target `main` (the old PRs cannot be retargeted; they are already closed). Suggested order:

1. Memory: one commit on top of current memory `main` equivalent to #10 (`bootstrap/proba-self.json` → version `2026-11-14.4`).
2. Gateway: #16's three commits onto current gateway `main` (which already has [#13](https://github.com/smallseedlabs/proba-llm-gateway/pull/13) and [#17](https://github.com/smallseedlabs/proba-llm-gateway/pull/17)).
3. Gateway: #18's `creative.draft_post` commit onto that.
4. Then retarget [gateway #19](https://github.com/smallseedlabs/proba-llm-gateway/pull/19) from `cursor/gateway-creative-draft` to `main`.

Do not force-push the old stack branches. Do not touch in-progress `cursor/*` worktrees for slices 2–6 except to read.

---

## 1. Vision

One goal description in. The brain — the gateway run loop plus Proba's self memory — does the work: research, post copy, targeting, budget, campaign create, and live optimisation toward the goal. The operator only approves guardrail cards and can override anything. Web and the Portal show status and accept overrides or config changes; they are not where the work is done by default.

Enterprise-grade and AI-native. Prompts are built from the self memory (stable prefix first, so DeepSeek's automatic prompt cache can hit). External guardrails may only **tighten** locked code limits; loosening is refused and audited. The brain decides how many iterations to run within those bounds, and returns an answer, a question, an explanation, a proposal or an action. If something is blocked, it says why and what would unblock it. Never a dead end.

**Campaign reviewer.** Not a separate model or rules engine. It is a system-initiated run of the same brain, started by the Hub, not by a chat message. No fixed cadence and no "one change every few days" rule. After each check the brain sets `next_check_at` and a reason. Pressing events (fast spend, a sudden drop in clicks, an ad rejected, budget running out) wake it early; otherwise it leaves changes time to work. Calm, not aggressive. "Keep watching" is a valid and common answer. The only fixed limits are outer safety bounds the operator can set in the Portal: maximum and minimum check interval, the largest change the brain may make on its own, and spend caps.

Small reversible changes run automatically within those limits (for example a modest budget move, or pausing a clearly losing ad). Anything that spends more, launches something new, or exceeds the automatic cap comes as an approval card.

**Checkpoint reports** on day 3, day 7 and at the end: target vs actual, what Proba changed, and a recommendation to continue, adjust or stop.

**One metrics source:** the audited Reddit numbers (the same ones the Portal shows). The brain must not invent landing URLs, metrics, or claims the operator's page does not support. The landing URL is typed by the operator only (`userSuppliedInput.landingPageUrl`); use it exactly or ask for it.

Posts are text-only until the operator approves paid image generation (slice 7). The operator's own post copy, if saved under Campaigns, is an override and is used as written.

---

## 2. Architecture map

Sibling checkouts live under `~/Projects/proba/`. The umbrella repo is [`proba`](https://github.com/smallseedlabs/proba) (local compose, docs, deploy artifacts). All published ports bind to `127.0.0.1`. Canonical port list: [`docs/LOCAL_TESTING.md`](LOCAL_TESTING.md) and `local/.env.example`.

### Repos and local ports

| Repo | Role | Host port | Health |
| --- | --- | --- | --- |
| [proba-web](https://github.com/smallseedlabs/proba-web) | Operator app (Vite) | 5180 | `/` |
| [proba-hub](https://github.com/smallseedlabs/proba-hub) | Commands, goals, approvals, connections, analytics schedule | 3300 (container 3000) | `/health` |
| [proba-llm-gateway](https://github.com/smallseedlabs/proba-llm-gateway) | Brain run loop, verbs, brief, guardrails | 3700 | `/health` |
| [proba-context](https://github.com/smallseedlabs/proba-context) | Context packet for each Hub request | 3500 | `/health` |
| [proba-memory](https://github.com/smallseedlabs/proba-memory) | Memory + self-memory seed | memory-api **3420**, ingestor 3421, jobs 3422 | `/health` |
| [proba-llm](https://github.com/smallseedlabs/proba-llm) | Only service that calls the paid model (DeepSeek) | 3600 | `/health` |
| [proba-portal](https://github.com/smallseedlabs/proba-portal) | Insights / admin (Vite) | 3410 | `/` |
| [ad-domain](https://github.com/smallseedlabs/ad-domain) | Ads service, Reddit adapter, metrics sync | 3800 | `/health` |
| [proba-audit](https://github.com/smallseedlabs/proba-audit) | Audit API 3400, consumer 3401, metrics-ingester 3402, rollup 3403 | — | `/health` |
| [proba-protocol](https://github.com/smallseedlabs/proba-protocol) | Shared protocol (events, cards, actions) | — | — |

Infra (compose project `proba-local`): Hub Postgres `55433`, memory Postgres `55434`, context Postgres `55435`, ads Postgres `55437`, Redis `56380`, ClickHouse HTTP `58125`.

There is **no** `proba-pages` checkout in this workspace. `page.generate_page` exists in the catalog but is **not allowlisted**. Landing pages today are operator-supplied URLs.

### Data flow

1. Operator talks in web (`:5180`). Web posts commands to Hub `POST /v1/commands` (`proba-hub/src/routes/commands.ts` → `src/services/command-processor.ts`).
2. Hub mints an act-as assertion and calls the gateway (`src/brain/`). The gateway runs `src/loop/run-loop.ts`. Since [gateway #15](https://github.com/smallseedlabs/proba-llm-gateway/pull/15) (on `main`), context is built **once per Hub request** and reused on later loops. A reused assertion would 401: context-api treats act-as as single-use (`proba-context` `packages/adapters/src/identity/actAsIdentityResolver.ts`). An approval resume is a new Hub request with a fresh assertion.
3. context-api (`:3500`) builds the packet. When memory-api is configured, self memory is loaded from `GET /v1/self` and placed first in the policy section (`packages/adapters/src/sources/selfMemoryHttpSource.ts`, `packages/adapters/src/policy/selfAwarePolicy.ts`, `packages/adapters/src/sources/selfAwareMemory.ts`, `packages/core/src/pipeline/selfDetail.ts`). Core entries always stay; tagged detail entries are scored in. Self fetch failure is non-fatal (policy statements only). Docs: `proba-context/docs/SELF_MEMORY.md` (on the #11 branch, now on context `main`).
4. The gateway builds a byte-stable system prefix from self memory + the run brief (`src/loop/brief.ts`) so DeepSeek's prompt cache can hit, then calls proba-llm (`:3600`).
5. The model chooses a verb from the fixed catalog (`src/limbs/catalog.ts`). Policy (`src/limbs/policy.ts`) enforces schema, allowlist, and that tool URLs match the operator landing URL. Dispatcher (`src/limbs/dispatcher.ts`) runs the limb. Verbs that spend or launch raise approval cards; Hub stores them and web renders them. Approving resumes the run.
6. Campaign create goes Hub → gateway `ads.create_campaign` → ad-domain (`:3800`) Reddit adapter (`ad-domain/src/providers/reddit/adapter.ts`). Metrics sync (`ad-domain/src/domain/metrics-sync.ts`) is off unless `ADS_METRICS_SYNC_ENABLED=true` (and Reddit is enabled). Code default interval is **3600s**; `local/.env.example` documents `ADS_METRICS_SYNC_INTERVAL_SECONDS=900` (15 minutes) when enabling it. Numbers flow into audit (`proba-audit/packages/core/src/metrics/ads-event-projection.ts`) and the Portal analytics views.

### Key files

**Gateway** (`proba-llm-gateway`; paths on `origin/main` unless noted):

- `src/limbs/catalog.ts` — fixed verbs. Allowlisted on main: `research.gather`, `research.accept` (not offered to the model), `page.attach_user_page`, `ads.create_campaign`, `ads.update_campaign`, `ads.pause_campaign`, `ads.resume_campaign`. **Not** allowlisted: `page.generate_page`, `ads.move_budget`, `analytics.compare_metrics`. `creative.draft_post` is on the #18 branch, not yet on `main`.
- `src/limbs/policy.ts` — schema, allowlist, landing-URL binding, `creative_missing` when no saved copy.
- `src/loop/run-loop.ts` — bounded loop; context once per request (`src/loop/context-once.test.ts`).
- `src/loop/brief.ts` — run brief in the system text.
- `src/guardrails/guardrails.ts` plus `config/guardrails.json` — tighten-only operator ceilings over locked code limits.
- `src/http/admin-guardrails.ts` — admin GET/PUT, **#16 branch only**.
- `src/limbs/creative-draft.ts` — draft checks, **#18 branch only**.
- `src/loop/analytics-review.ts` — existing analytics review path (already builds context once).
- `src/types/llm.ts` — after #17 on main, usage accepts `cacheMissTokens`.

**Hub** (`proba-hub`):

- `src/services/command-processor.ts` — command execution.
- `src/analytics/service.ts` — scheduled/on-demand reviews. Proposals still need owner approval. **Today the review reads gateway review summaries** (`latestCompletedSummary` / `summary.metrics`), not the audited Reddit projection. Scheduler is off unless `ANALYTICS_SCHEDULE_ENABLED` (`src/analytics/scheduler.ts`, `src/app.ts`).
- `src/connections/service.ts` — marketing connections (Reddit first).
- `src/routes/commands.ts`, `src/routes/analytics.ts`.

**Memory** (`proba-memory`):

- `bootstrap/proba-self.json` — versioned public seed. On `main`: `2026-11-14.3`. Reserved workspace `__proba_system__`.
- `packages/core/src/bootstrap/self-memory.ts`, `apps/memory-api/src/self-seed.ts` — idempotent seed on start; new versions supersede, never edit in place.
- `GET /v1/self` — people + `context-reader` role.
- `packages/adapters/src/ratelimit/redis-rate-limiter.ts` — **fails open** if Redis is unreachable (request allowed, error logged). This predates the current work.

**Context** (`proba-context`):

- Self-aware sources as above.
- `config/context.config.yaml` `allowedDownstreamHosts` includes `redis:6379` but **not** `127.0.0.1:56380`. Native debug therefore copies the config and adds that one equivalent host (`local/debug/debug.mjs`); do not broaden the repo allowlist.

**Ads / audit / web / portal:**

- Reddit: `ad-domain/src/providers/reddit/adapter.ts` (plus `client.ts`, `normalize-metrics.ts`). Sync: `src/domain/metrics-sync.ts`, config in `src/config.ts`.
- Audit projection: `proba-audit/packages/core/src/metrics/ads-event-projection.ts`, `apply-projection.ts`.
- Web cards: `proba-web/src/components/registry/cards.tsx`; `components/views/AskCard.tsx`, `ResearchReviewCard.tsx`, `PostCreativeCard.tsx`. Draft/plan cards land in [web #38](https://github.com/smallseedlabs/proba-web/pull/38) / [#40](https://github.com/smallseedlabs/proba-web/pull/40).
- Portal screens on main: `AnalyticsView`, `ExplorerView`, `IntegrityView`, `JobsView`, `MemoryDetailView`, `MemoryExplorerView`, `ProfilesView`, `RetrievalInspectorView`, `TraceView`, `TracesView`. Guardrails screen: `proba-portal/src/components/views/GuardrailsView.tsx` on [portal #9](https://github.com/smallseedlabs/proba-portal/pull/9) (needs gateway #16 actually on main).

---

## 3. Status (verify again before merging)

### On `origin/main` (this snapshot)

- [hub #48](https://github.com/smallseedlabs/proba-hub/pull/48) — approval resume keeps operator scope / closes blocked cards.
- [gateway #14](https://github.com/smallseedlabs/proba-llm-gateway/pull/14) — non-fatal `creative_missing` refusal; saved creative accepted on resume.
- [web #36](https://github.com/smallseedlabs/proba-web/pull/36) — keep a card closed when the Hub expires it (`retryable:false`).
- [gateway #15](https://github.com/smallseedlabs/proba-llm-gateway/pull/15) — context once per Hub request (fixes the multi-loop context-api 401).
- [gateway #13](https://github.com/smallseedlabs/proba-llm-gateway/pull/13) — system prompt from self memory + run brief; tighten-only guardrails.
- [gateway #17](https://github.com/smallseedlabs/proba-llm-gateway/pull/17) — accept and accumulate proba-llm `cacheMissTokens`. Safe to merge [proba-llm #4](https://github.com/smallseedlabs/proba-llm/pull/4) after this (already on main).
- [memory #9](https://github.com/smallseedlabs/proba-memory/pull/9) — self memory bootstrap, `GET /v1/self` (squash `e1e8028`, version `2026-11-14.3`).
- [context #11](https://github.com/smallseedlabs/proba-context/pull/11) — self memory first in the policy section.

### Open PRs and suggested merge order

The operator merges; agents do not. Re-check this list. Dependabot PRs (for example [proba #21](https://github.com/smallseedlabs/proba/pull/21), hub #40, web #32, context #9/#10) are out of scope unless asked.

1. **Re-PR onto `main`:** memory #10, then gateway #16, then gateway #18 (see §0). Until those are on `main`, draft-copy and the Portal Guardrails API are not in the default snapshot `./up.sh` builds.
2. [proba-llm #4](https://github.com/smallseedlabs/proba-llm/pull/4) — bill DeepSeek cache-hit prompt tokens at `PRICE_PROMPT_CACHE_HIT_USD_PER_MILLION` (optional; never defaulted). Gateway #17 is already on main, so the new usage fields will parse.
3. [hub #49](https://github.com/smallseedlabs/proba-hub/pull/49) **with** [web #38](https://github.com/smallseedlabs/proba-web/pull/38) — editable drafted-post card; approving saves `goals.approved_creative`.
4. [hub #50](https://github.com/smallseedlabs/proba-hub/pull/50) **with** [web #39](https://github.com/smallseedlabs/proba-web/pull/39) — map legacy `targeting.subreddits` to Ads `communities` (without this, a campaign with saved subreddits is rejected by ads).
5. [web #37](https://github.com/smallseedlabs/proba-web/pull/37) — compact goal header on short viewports. It includes [#35](https://github.com/smallseedlabs/proba-web/pull/35); merge #37 and close #35, do not merge both.
6. [portal #9](https://github.com/smallseedlabs/proba-portal/pull/9) — after gateway #16 is actually on `main`.
7. [proba #26](https://github.com/smallseedlabs/proba/pull/26) — documents `PRICE_PROMPT_CACHE_HIT_USD_PER_MILLION` in `local/.env.example`. Independent; still needs the operator to set the value in the real local env.
8. **Slice 2 (in progress — check before merging, do not conflict with the other worker):** [gateway #19](https://github.com/smallseedlabs/proba-llm-gateway/pull/19) (base is still `cursor/gateway-creative-draft`; retarget after #18 is on main), [hub #51](https://github.com/smallseedlabs/proba-hub/pull/51) (base `cursor/hub-creative-draft` / #49), [web #40](https://github.com/smallseedlabs/proba-web/pull/40). Merge the slice-2 trio only after #49/#38 (and the re-PRed #18) are on main.

### Known product/engineering gaps (still true on main)

- Operator still has to write post copy unless #10 + #18 + #49 + #38 are really on main and running.
- Hub analytics review does not read audited Reddit numbers; `analytics.compare_metrics` is in the catalog but `allowlisted: false`, so the brain cannot call it.
- A full path "goal → live Reddit campaign → synced metrics → reviewer decision" has not been proven end to end.
- Local ads cap currency is `ADS_MAX_DAILY_BUDGET` / `ADS_MAX_DAILY_BUDGET_CURRENCY` in `local/.env` (do not read or print that file). The operator chose **5 USD**; if the running gateway still says another currency, only the operator should edit `.env`.
- memory-api Redis rate limiter fails open (see §2).
- context-api repo allowlist lacks the published local Redis host (debug.mjs patches a copy only).
- Discord-join conversion is the operator's real success metric and is not trackable on Reddit until the Reddit pixel exists.

---

## 4. Roadmap

Slices 2–6 may already be partly in progress on `cursor/*` branches and worktrees under `~/Projects/proba/wt/` (for example `gw-creative` / `cursor/gateway-plan-card`, `hub-creative` / `cursor/hub-plan-card`, `web-creative` / `cursor/web-plan-card`). **Check open PRs first. Do not edit those branches; another worker owns them.**

- **Slice 1** (draft post copy) — PRs exist (#18, #49, #38, memory #10) but several are not actually on `main` (see §0).
- **Slice 2 — targeting and one plan card.** `creative.draft_post` carries optional targeting + `plan` (metric, platform, duration) with `reasons` = "chose X because Y". One card, one approval, override anything. `ads.create_campaign` keeps its own approval (spend). Ads objective stays `CLICKS` until pixel events exist. Pointers: gateway #19 (`src/limbs/plan-sections.ts` on that branch), hub #51, web #40. There is no separate `targeting.choose` verb in #19; targeting rides on the draft/plan card.
- **Slice 3 — Hub review reads audited metrics.** Wire `proba-hub/src/analytics/service.ts` to the audit Reddit projection (same numbers as the Portal), not gateway summaries. Then allowlist `analytics.compare_metrics` only with a tighten-only guardrail, or feed those numbers into the review packet.
- **Slice 4 — reviewer.** System-initiated Hub runs of the same gateway loop. Brain returns `next_check_at` + reason; pressing events wake it early. Outer bounds only, configurable in the Portal. Automatic vs approval by guardrail. Notes appear under Recent decisions.
- **Slice 5 — `report.checkpoint`.** Day 3, day 7, and end-of-run reports: target vs actual, changes made, continue / adjust / stop.
- **Slice 6 — goal page and Portal settings.** Web goal page sections: Now, Next, Spend vs cap, Progress to goal, Recent decisions. Portal: reviewer bounds and tighten-only thresholds.
- **Slice 7 — images.** TEXT-only until the operator approves spend. Intended: FLUX 3 Klein or Grok Imagine at 2K, hosted on Cloudflare R2, about 2–5 cents per image, roughly **$1/month cap**. Needs the operator's OK and a bucket; do not wire it first.
- **Then:**
  - Reddit pixel and Discord-join conversion tracking (otherwise the reviewer is guessing against the real goal).
  - Fix memory-api Redis rate limiter fail-open (`packages/adapters/src/ratelimit/redis-rate-limiter.ts`).
  - Add `127.0.0.1:56380` to context-api's checked-in allowlist **only as the published equivalent of `redis:6379`**, or keep the debug.mjs 1:1 copy; do not broaden allowlists.
  - Send remaining important events to audit (including `connection.*` if they are still missing from the protocol catalog — check `proba-protocol` and `proba-hub/src/connections/service.ts` before inventing names).
  - Missing Portal screens (Guardrails is #9; reviewer bounds and checkpoint history are not built).
  - `proba-pages` / allowlisted page generation, only when designed; today the URL is always the operator's.

---

## 5. How to run locally

Official flow (committed): [`docs/LOCAL_TESTING.md`](LOCAL_TESTING.md).

```bash
cd ~/Projects/proba/proba/local
./up.sh --portal --memory --context --llm   # also needs the agents profile for gateway + ads; see the doc
./seed.sh
./verify.sh
./status.sh
./down.sh          # keep data
./reset.sh --yes   # wipe local data; do not add --env unless the operator asked
```

`./up.sh` snapshots **`origin/main`** of each sibling repo into `local/.src/` (`git archive`); dirty or checked-out branches do not leak in. To test worktrees as they are on disk: `PROBA_SRC=worktree ./up.sh`. To test a branch: `PROBA_REF=origin/some-branch ./up.sh`. Fetch first if you need latest main. Nothing in `local/` is needed in production. `./up.sh` creates `local/.env` (mode 600, gitignored) with random secrets on first run; **never read or print `.env`**.

### Native debug stack (Mac only, not in git)

`local/debug/` is listed in `proba/.git/info/exclude` and is **not committed**. On this Mac it already exists.

- `local/debug/debug-up.sh [svc…]` / `node local/debug/debug.mjs up [svc…]` — stop app containers, start the same services from the checkouts with `node --inspect`. Infra stays in Docker.
- `local/debug/debug-status.sh`, `debug-down.sh`, `back-to-docker.sh`.
- `local/debug/restore-to-main.sh` — drop `repo-overrides.json` and process-only overrides so services run from `~/Projects/proba/<repo>`; does not push, merge, or delete `wt/combined-*` / `local/combined-20261114`.
- `local/debug/debug.mjs` — service table and ports (hub 3300, gateway 3700, context-api 3500, llm 3600, memory-api 3420, web 5180, portal 3410). Optional `overrides/<svc>.env` (non-secret). Optional `repo-overrides.json` to point a service at a worktree.
- Combined worktrees used for the 14 Nov 2026 local run: `~/Projects/proba/wt/combined-*` on branches `local/combined-20261114`.
- **Live monitor:** `./local/debug/monitor.sh` or `tail -f ~/Projects/proba/proba/local/debug/logs/monitor.log`. Counts also in `local/debug/logs/monitor.summary.txt`. Gateway runs are not in `gateway.log`; the monitor reads `local/debug/data/gateway/runs` and the Hub log. Secrets are redacted.

Web locally: `http://127.0.0.1:5180`. Portal: `http://127.0.0.1:3410`.

### Testing rules

- Do not restart services while the operator is using the app, unless they asked for a clean restart.
- No production deploy. No live campaign create or approval on the operator's behalf.
- Landing URLs are entered only by the operator (including in tests that would attach a real page).
- Live ad spend only within the configured daily cap (`ADS_MAX_DAILY_BUDGET` + currency).
- Never disable CI checks, never broaden allowlists, never skip gitleaks or CodeQL.
- Prefer `npm test` / `test:ci`, typecheck and lint in the repo you changed. Platform checks: `./verify.sh`.
- A made-up e2e user in `proba-web` (`e2e/firebase/mock.ts`, `e2e/support/app.ts`) is test-only; it is not a backdoor into real Firebase.

---

## 6. Standing rules for any agent

- No destructive git, no force-push, no rebasing of already-pushed commits without the operator's confirmation. **The operator merges.** Do not click merge.
- No production deploy. Never approve or launch a campaign on the operator's behalf.
- Landing URLs are only entered by the operator. Never invent or default one. Policy already rejects a tool URL that does not match `userSuppliedInput.landingPageUrl`.
- No secrets: never read or print `.env`, `local/.env`, or key material under `local/keys` or `*/keys`.
- Live ad spend only within the configured daily cap.
- Never disable checks or broaden allowlists.
- Product and technical decisions are made by the agent as staff designer/engineer; the operator only overrides.
- Be token-efficient: exact file and PR pointers, no theory. Do not scrap existing services for a rewrite.
- Do not restart the live local stack unless asked. Do not edit in-progress `cursor/*` slice 2–6 branches owned by another worker.
- If a stacked PR looks merged, verify the commits are ancestors of `origin/main` before announcing them as landed.
