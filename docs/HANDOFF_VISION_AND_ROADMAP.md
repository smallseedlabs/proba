# Handoff: Proba vision, architecture and remaining work

This is a self-contained handoff so another agent (including a Gemini-backed bot) can continue with no prior chat. Facts were checked against GitHub and the operator's Mac checkouts under `~/Projects/proba` on **Saturday 14 November 2026, about 12:00 Europe/London (UTC+0)**. Re-check open PRs and `origin/main` before acting if more time has passed.

Org: [smallseedlabs](https://github.com/smallseedlabs). Operator: Sangam Dubey (Europe/London). Do not scrap the existing backend; extend it to enterprise grade. Product and engineering decisions are made by the agent as staff designer/engineer; the operator only overrides. Give exact file and PR pointers, keep updates short, and do not ask for decisions the agent can make.

---

## 1. Vision

One goal description in. The brain — the gateway run loop plus Proba's self memory — does the work: research, post copy, image creatives (once the operator approves cost), Reddit targeting, campaign config, and live updates driven by metrics toward the goal. When results fall short it reports that, with a recommendation to stop or tweak. The operator only approves guardrail cards and can override anything. Web and the Portal show status and accept overrides or config changes; they are not where the work is done by default.

Enterprise-grade and AI-native. Prompts are built from the self memory (stable prefix first, so DeepSeek's automatic prompt cache can hit). External guardrails may only **tighten** locked code limits; loosening is refused and audited. The brain decides how many iterations to run within those bounds, and returns an answer, a question, an explanation, a proposal or an action. If something is blocked, it says why and what would unblock it. Never a dead end.

The landing URL is typed by the operator only (`userSuppliedInput.landingPageUrl`); use it exactly or ask for it. Never invent or default a URL. The brain must not invent metrics or claims the operator's page does not support.

Posts are text-only until the operator approves paid image generation. The operator's own post copy, if saved under Campaigns, is an override and is used as written.

### Campaign reviewer

Not a separate model or rules engine. It is a system-initiated run of the **same** brain (same gateway loop, self memory, context, verbs and tighten-only guardrails), started by the Hub, not by a chat message. No fixed cadence and no "one change every few days" rule. After each check the brain sets `next_check_at` and a reason. Pressing events (fast spend, a sudden drop in clicks, an ad rejected, budget running out) should wake it early; otherwise it leaves changes time to work. Calm, not aggressive. "Keep watching" is a valid and common answer. The only fixed limits are outer safety bounds the operator can set in the Portal: maximum and minimum check interval, the largest change the brain may make on its own, and spend caps.

**Current product decision (keep until a real campaign has been watched):** reviewer suggestions still need the operator's approval. It can suggest a pause or a budget cut; nothing applies automatically yet, even small changes within the 20% automatic-change bound. Scheduled reviews stay off by default; when turned on, the brain decides the next check. Reviews already read the audited Reddit numbers, so there is no second metrics path.

**Checkpoint reports** on day 3, day 7 and at the end: target vs actual, what Proba changed, and a recommendation to continue, adjust or stop. The verb exists; UI polish is still outstanding.

---

## 2. Architecture map

Sibling checkouts live under `~/Projects/proba/`. The umbrella repo is [`proba`](https://github.com/smallseedlabs/proba) (local compose, docs, deploy artifacts). All published ports bind to `127.0.0.1`. Canonical port list: [`docs/LOCAL_TESTING.md`](LOCAL_TESTING.md) and `local/.env.example`.

### Repos and local ports

| Repo | Role | Host port | Health |
| --- | --- | --- | --- |
| [proba-web](https://github.com/smallseedlabs/proba-web) | Operator app (Vite) | 5180 | `/` |
| [proba-hub](https://github.com/smallseedlabs/proba-hub) | Commands, goals, approvals, connections, reviewer schedule | 3300 (container 3000) | `/health` |
| [proba-llm-gateway](https://github.com/smallseedlabs/proba-llm-gateway) | Brain run loop, verbs, brief, guardrails, reviewer verbs | 3700 | `/health` |
| [proba-context](https://github.com/smallseedlabs/proba-context) | Context packet for each Hub request | 3500 | `/health` |
| [proba-memory](https://github.com/smallseedlabs/proba-memory) | Memory + self-memory seed | memory-api **3420**, ingestor 3421, jobs 3422 | `/health` |
| [proba-llm](https://github.com/smallseedlabs/proba-llm) | Only service that calls the paid model (DeepSeek) | 3600 | `/health` |
| [proba-portal](https://github.com/smallseedlabs/proba-portal) | Insights / admin (Vite), Guardrails, reviewer bounds | 3410 | `/` |
| [ad-domain](https://github.com/smallseedlabs/ad-domain) | Ads service, Reddit adapter, metrics sync | 3800 | `/health` |
| [proba-audit](https://github.com/smallseedlabs/proba-audit) | Audit API 3400, consumer 3401, metrics-ingester 3402, rollup 3403 | — | `/health` |
| [proba-protocol](https://github.com/smallseedlabs/proba-protocol) | Shared protocol (events, cards, actions) | — | — |

Infra (compose project `proba-local`): Hub Postgres `55433`, memory Postgres `55434`, context Postgres `55435`, ads Postgres `55437`, Redis `56380`, ClickHouse HTTP `58125`.

There is **no** `proba-pages` checkout. Landing pages today are operator-supplied URLs.

### Data flow

1. Operator talks in web (`:5180`). Web posts commands to Hub `POST /v1/commands` (`proba-hub/src/routes/commands.ts` → `src/services/command-processor.ts`).
2. Hub mints an act-as assertion and calls the gateway (`src/brain/`). The gateway runs `src/loop/run-loop.ts`. Context is built **once per Hub request** and reused on later loops. A reused assertion would 401: context-api treats act-as as single-use. An approval resume is a new Hub request with a fresh assertion.
3. context-api (`:3500`) builds the packet, including self memory from `GET /v1/self` when memory-api is configured (stable prefix first).
4. The gateway calls proba-llm (`:3600`). The model chooses a verb from the fixed catalog (`src/limbs/catalog.ts`). Policy enforces schema, allowlist, and that tool URLs match the operator landing URL. Verbs that spend or launch raise approval cards.
5. Campaign create goes Hub → gateway `ads.create_campaign` → ad-domain (`:3800`) Reddit adapter. Metrics sync is off unless `ADS_METRICS_SYNC_ENABLED=true`. Numbers flow into audit and the Portal analytics views; the reviewer reads those same audited numbers.

DeepSeek prompt cache is DeepSeek's own automatic feature. Off-peak `deepseek-flash` rates (USD per million tokens): cache hit 0.003, miss 0.15, output 0.60. Peak: 0.006, 0.30, 1.20. `PRICE_PROMPT_CACHE_HIT_USD_PER_MILLION` is optional and never defaulted; see `local/.env.example` (do not read or print `local/.env`).

---

## 3. What is on `main` (14 Nov 2026)

All of the following were merged to **`main`** (some earlier PRs were first merged into a stacked feature base; land PRs [gateway #20](https://github.com/smallseedlabs/proba-llm-gateway/pull/20) and [memory #11](https://github.com/smallseedlabs/proba-memory/pull/11) put that work onto `main`). **Do not open stacked PRs.** Every new branch is based on current `origin/main`. The operator merges; do not merge, approve, launch or deploy.

| Repo | Merged to main |
| --- | --- |
| [proba-llm-gateway](https://github.com/smallseedlabs/proba-llm-gateway) | [#13](https://github.com/smallseedlabs/proba-llm-gateway/pull/13)–[#21](https://github.com/smallseedlabs/proba-llm-gateway/pull/21) (self-memory prompt, guardrails admin API, cache-miss usage, `creative.draft_post`, plan card, reviewer on the brain loop). #16 and #18 reached main via #20. |
| [proba-memory](https://github.com/smallseedlabs/proba-memory) | [#9](https://github.com/smallseedlabs/proba-memory/pull/9)–[#12](https://github.com/smallseedlabs/proba-memory/pull/12) (self memory, draft-copy guidance, reviewer guidance). #10 reached main via #11. |
| [proba-hub](https://github.com/smallseedlabs/proba-hub) | [#48](https://github.com/smallseedlabs/proba-hub/pull/48)–[#53](https://github.com/smallseedlabs/proba-hub/pull/53) (creative/plan cards, targeting map, reviewer, CI hang fix). Hub migrations **011–013** came in with #51/#52. |
| [proba-web](https://github.com/smallseedlabs/proba-web) | [#36](https://github.com/smallseedlabs/proba-web/pull/36)–[#41](https://github.com/smallseedlabs/proba-web/pull/41) (cards, compact header, plan card, goal page Now/Next/Spend/Progress/Recent decisions). #35 was closed unmerged; #37 already included it. |
| [proba-portal](https://github.com/smallseedlabs/proba-portal) | [#9](https://github.com/smallseedlabs/proba-portal/pull/9)–[#10](https://github.com/smallseedlabs/proba-portal/pull/10) (Guardrails screen and reviewer bounds editor). |
| [proba-llm](https://github.com/smallseedlabs/proba-llm) | [#4](https://github.com/smallseedlabs/proba-llm/pull/4) (cache-hit price). |
| [proba](https://github.com/smallseedlabs/proba) | [#26](https://github.com/smallseedlabs/proba/pull/26)–[#27](https://github.com/smallseedlabs/proba/pull/27) (local cache-hit env docs, original handoff). This document supersedes #27. |

**Fix PRs opened after the clean-slate test on 14 Nov (merge these next, still targeting `main`, no stacking):**

- [gateway #22](https://github.com/smallseedlabs/proba-llm-gateway/pull/22): truncated model replies (`finishReason: length`) must not complete with an empty card; retry once with the remaining completion budget and a concise-continue nudge; default `GATEWAY_MAX_COMPLETION_TOKENS=4000`. The 512 `responseTokenReserve` is a **context** reserve only; it was wrongly used as a per-call output cap and cut off `creative.draft_post` in gateway run `2a478a37` (request budget was already 1500, but `maxTokens` sent to the model was 512).
- [hub #54](https://github.com/smallseedlabs/proba-hub/pull/54): default `BRAIN_MAX_OUTPUT_TOKENS` raised from 1500 to 4000 (tighten-only; this is the run budget Hub sends the gateway for planning/drafting).
- [proba #28](https://github.com/smallseedlabs/proba/pull/28): compose now passes `FIREBASE_PROJECT_ID`, `GATEWAY_ADMIN_EMAILS`, `GATEWAY_CORS_ORIGINS` into the gateway so Portal Guardrails is configured without a secret in git; this handoff is refreshed.

These were open, not merged, at the time of writing.

---

## 4. How to run locally

Official Docker flow: [`docs/LOCAL_TESTING.md`](LOCAL_TESTING.md).

```bash
cd ~/Projects/proba/proba/local
./up.sh --portal --memory --context --llm   # also needs the agents profile for gateway + ads; see the doc
./seed.sh
./verify.sh
```

`./up.sh` snapshots **`origin/main`** of each sibling repo into `local/.src/`. To test a worktree as it sits on disk: `PROBA_SRC=worktree ./up.sh`. **Never read or print `local/.env` or `local/keys`.** No production deploy.

### Native debug stack (what the operator is using)

`local/debug/` is listed in `proba/.git/info/exclude` and is **not committed**, but it already exists on this Mac.

- `node ~/Projects/proba/proba/local/debug/debug.mjs up [svc…]` — stop the app containers, start the same services from the checkouts with `node --inspect`. Infra stays in Docker. Ports: hub 3300, gateway 3700, context-api 3500, llm 3600, memory-api 3420, ads 3800, audit-api 3400, web 5180, portal 3410.
- `node …/debug.mjs down [svc…]`, `debug-status.sh`, `back-to-docker.sh`.
- `restore-to-main.sh` — drop `repo-overrides.json` and process-only overrides (for example the off-peak cache-hit price file) so services run from `~/Projects/proba/<repo>`. It must **keep** `overrides/gateway.env` (Firebase project id + admin emails + Portal CORS) so the Guardrails screen keeps working. It does not push, merge, or delete worktrees.
- Optional `overrides/<svc>.env` (non-secret key=value). Optional `repo-overrides.json` maps a repo name to a worktree path.
- **Live monitor:** `./local/debug/monitor.sh` or `tail -f ~/Projects/proba/proba/local/debug/logs/monitor.log`. Gateway runs are not in `gateway.log`; the monitor reads `local/debug/data/gateway/runs` and the Hub log. Secrets are redacted.

Web: `http://127.0.0.1:5180`. Portal: `http://127.0.0.1:3410`.

`debug.mjs up` does **not** apply SQL migrations. After pulling new Hub (or memory/context/ads/audit) migrations, run that repo's `migrate-cli` against the same database URL the debug process uses (from the stopped compose container, rewritten to the published `127.0.0.1` port — for Hub Postgres that is `127.0.0.1:55433`). In `proba-hub`: `npm run migrate` (`src/db/migrate-cli.ts`) or `node dist/db/migrate-cli.js`. Same pattern: memory, context, ads, audit each have a `migrate` script. Do not print the URL.

Restart one service after a code change: `npm run build` in its repo (or worktree), then `node debug.mjs down <svc> && node debug.mjs up <svc>`.

### Testing rules

- Landing URLs are entered only by the operator (including in tests that would attach a real page).
- Live ad spend only within `ADS_MAX_DAILY_BUDGET=5` **USD**. If a running env still has another currency, only the operator should edit that one line in `local/.env`.
- No live campaign create, approval, or production deploy on the operator's behalf.
- Never disable CI checks, never broaden allowlists, never skip gitleaks or CodeQL.
- Prefer `npm test` (and `lint`, `typecheck`) in the repo you changed.

---

## 5. Standing rules for any agent

- No destructive git, no force-push, no rebasing of already-pushed commits without the operator's confirmation. **The operator merges.**
- **No stacked PRs.** Base every branch on current `origin/main`.
- No production deploy. Never approve or launch a campaign on the operator's behalf.
- Landing URLs are only entered by the operator. Never invent or default one.
- No secrets: never read or print `.env`, `local/.env`, or key material under `local/keys` or `*/keys`.
- Live ads capped at `ADS_MAX_DAILY_BUDGET=5` USD.
- Never disable checks or broaden allowlists.
- Product and technical decisions are made by the agent as staff designer/engineer; the operator only overrides.
- Be token-efficient: exact pointers, short updates, at most two workstreams, no side tasks.
- The Mac shell is zsh: it does not word-split unquoted vars, `===` breaks inside `echo` (use `echo '---'`), and there is no `rg` (use `grep`). `gh` is logged in. If the Mac goes offline, stop safely.
- Do not edit an uncommitted `proba-context/docs/DESIGN.md` change that is not yours. A stray two-blank-line edit in `proba-hub/src/routes/commands.ts` was discarded on 14 Nov with the operator's approval.

---

## 6. Known issues

- **Truncation on planning/drafting (being fixed).** Gateway run `2a478a37` (`create_goal` / `plan_goal`) completed with an empty reply after the second LLM call returned `finishReason: "length"` mid-`creative.draft_post` (invalid JSON, 512 completion tokens). Root cause: `nextCompletionTokenCap` took `min(responseTokenReserve=512, remaining budget)`. Until the gateway/hub fix PRs are merged and the services rebuilt, a long draft can still finish as an empty card. After the fix, a second truncation must end **blocked** with a clear message, not `completed`.
- **Portal Guardrails 503 `admin_unconfigured`.** `restore-to-main.sh` used to delete `local/debug/overrides/gateway.env`, which supplied `FIREBASE_PROJECT_ID`, `GATEWAY_ADMIN_EMAILS` and `GATEWAY_CORS_ORIGINS`. Compose did not pass those into the gateway container, so native debug (which copies container env) had no admin config. The local override has been restored (values taken from `local/.env`, never printed). The umbrella PR adds the same keys to compose; debug.mjs also fills them from `local/.env` when the container env is missing; restore no longer deletes `overrides/gateway.env`. After merge, recreate or restart gateway so it reloads env. A request without a token should be **401**, not 503. The Portal at `http://127.0.0.1:3410` can then load Guardrails for an allow-listed Firebase user.
- **Ad-service event wake is not wired.** The reviewer cannot yet be woken early when, for example, Reddit disapproves an ad. Hub can schedule `next_check_at` and the operator can trigger a review; ads events do not yet start one.
- **Small automatic changes are off.** Keep approval-required until a real campaign has been observed.
- **memory-api / audit Redis rate limiter fails open** (`packages/adapters/src/ratelimit/redis-rate-limiter.ts` in those repos).
- **Images are not built.** Needs the operator's cost OK (FLUX / Grok Imagine on R2, roughly a $1/month cap).
- **`report.checkpoint` UI** still needs polish (day 3 / day 7 / end reports).
- context-api's checked-in Redis allowlist does not include `127.0.0.1:56380`; `debug.mjs` patches a copy only. Do not broaden allowlists.

---

## 7. Remaining roadmap (do in this order)

1. **Verify the truncation fix** on a real `create_goal` after the gateway (and hub cap) PRs are merged and those services are rebuilt from main. The operator should see a plan/draft card, or a blocked message that says the completion cap was hit — never a silent empty card.
2. **End-to-end live Reddit campaign** once the operator funds the Reddit ads wallet. Stay inside the $5 USD daily cap. Do not create, approve or launch on their behalf.
3. **Images** — FLUX 3 Klein or Grok Imagine at 2K, hosted on Cloudflare R2, about 2–5 cents per image, roughly **$1/month cap**. Needs the operator's OK and a bucket; do not wire it first.
4. **Reddit pixel and conversion tracking** (Discord-join is the real success metric; without the pixel the reviewer is guessing).
5. **Ad-service wake events** so pressing ads events start a reviewer run before `next_check_at`.
6. **Automatic small changes** only after watching a real campaign, still within tighten-only Portal bounds.
7. **Fix the Redis rate limiter** fail-open in memory-api and audit.
8. **`report.checkpoint` UI polish** on the goal page (day 3, day 7, end-of-run: target vs actual, changes, continue / adjust / stop).

---

## 8. Working style

Exact file and PR pointers, not theory. Short status updates. Staff product and engineering decisions are made without asking; the operator overrides if needed. Two workstreams at most. No side tasks. If a PR looks merged, confirm the commits are ancestors of `origin/main` before treating them as landed (this already bit us with stacked PRs #16/#18/#10).
