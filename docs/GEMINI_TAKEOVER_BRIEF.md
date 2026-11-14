# Proba: takeover brief for the next agent (Gemini)

Read this first, then `docs/HANDOFF_VISION_AND_ROADMAP.md` (full vision, repos, PR history, run steps).
Owner: Sangam Dubey (Europe/London). Org: github.com/smallseedlabs. Code on his Mac: `~/Projects/proba/<repo>`.

## 1. What Proba is
Small Seed Labs' AI marketing operator. The user writes ONE goal description (+ landing URL they type themselves + budget).
The brain does everything else: research the page, draft ad copy and creatives, choose Reddit targeting and campaign config,
create the campaign, read live metrics, adjust toward the goal, and report shortfalls with "stop" or specific tweak recommendations.
The user only approves guardrail cards (and may optionally override copy or config). Web and Portal show status and let the
user override config; they are not where work is done.

## 2. Design principles (do not break)
- AI-native: a bootstrap **self memory** (what Proba is, success, right/wrong, its limbs/capabilities) lives in proba-memory and is
  sent as a summarised core in context; prompts are generated from it, not static prompt tricks. Quality (catchy copy, image use,
  targeting) must emerge from the brain researching and reasoning, not hardcoded rules.
- Brain loops as needed within iteration/token caps and returns an answer, question, explanation, proposal, or tool call (approval card).
  When blocked it explains why and what unblocks it. Never dead-ends.
- Hard guardrails only in locked code, tighten-only from outside: spend caps (`ADS_MAX_DAILY_BUDGET=5`, USD), approval for every
  side effect/spend, platform format limits, exact brand names, real URLs/images only from the user's domain, no invented claims/metrics.
- **Reviewer** = system-initiated run on the same brain (same gateway loop, memory, verbs, guardrails), started by Hub. No fixed
  cadence: brain sets `next_check_at` + reason; events can wake it early. Calm human media buyer: learning period, few changes,
  "keep watching" is the usual outcome. Outer bounds only: min/max interval, max auto change (20%), spend caps.
  Small automatic changes are OFF; every suggestion is an approval card.
- Build on existing code; never scrap or revamp. Enterprise quality.

## 3. Architecture (services, local ports)
hub 3300 (Postgres, goals/threads/asks/gateway_runs, migrations 001-013) -> gateway 3700 (brain loop, verbs, policy, run-store)
-> llm 3600 (DeepSeek `deepseek-flash`, cache-hit pricing) ; context 3500 (packets, single-use act-as token, build once per request)
; memory-api 3420 (self memory, scoped reads) ; ads (ad-domain, Reddit adapter, billing/blueprint preflight) ; audit (ClickHouse,
analytics projections) ; web 5180 (operator UI) ; portal 3410 (admin, Guardrails screen).
Verbs include: research.gather/accept, creative.draft_post, ads.create_campaign, analytics.review_campaign, analytics.report_checkpoint.

## 4. Run it locally
- `cd ~/Projects/proba/proba/local/debug && node debug.mjs up` (does NOT run Hub migrations: run hub `migrate-cli` with Hub env).
- `restore-to-main.sh` resets worktree overrides; `overrides/gateway.env` (Firebase/admin keys) is kept; `repo-overrides.json` points a
  service at a worktree; delete it to run from main.
- Monitor: `monitor.sh`/`monitor.py`; `tail -f ~/Projects/proba/proba/local/debug/logs/monitor.log`; summary `logs/monitor.summary.txt`.
  Tags RUN LOOP MODEL CTX ASK APPROVE BLOCK ADS DONE WARN ERROR. Run detail: newest JSON in `local/debug/data/gateway/runs`
  (`events`, `toolTurns`, `snapshot.outputs`, `usage`).
- Known noise: memory-api/audit Redis rate limiter "client offline" fails open (pre-existing bug to fix).

## 5. State on 14 Nov 2026 (all merged to main)
gateway #13-#22, memory #9-#12, hub #48-#54, web #36-#41, portal #9-#10, llm #4, proba #26-#28.
Last live test (run 96babbf0): goal -> research -> brain self-corrected a `creative_invalid` draft -> user approved draft ->
ads.create_campaign approved -> blocked `ads.billing` (Reddit wallet empty, expected). User is now funding the wallet.

## 6. In-flight work (check for open PRs on these branches first; finish, do not duplicate)
A. Blocked UX: final output on preflight block was a `clarify` question repeating the raw reason; must be a proper blocked reply
   ("add funds to your Reddit Ads wallet, then press Retry") with Retry in web. Also investigate `policy.denied ads.blueprint`
   seen just before billing, and fix monitor showing research.gather as "failed" when it is awaiting approval.
B. `docs/DEBUGGING_GUIDE.md`: every env flag (default, values, what it controls, when to use), Docker commands, DB schema with
   mermaid ER + flow, failure codes, monitor usage, debug recipes.
C. Creatives: brain-led copy quality (self memory states the outcome; brain may research current Reddit ad practice via
   research.gather and cite it) + only hard platform limits in code; images taken from the user's landing page (og:image ->
   twitter:image -> hero), validated, shown on the draft card, IMAGE post else TEXT, uploaded via the ad-domain Reddit media path.
   AI image generation (FLUX / Grok Imagine on Cloudflare R2, ~$1/month cap) stays behind a disabled flag until the user OKs cost.
   Review of last copy: brand misnamed "Small Seed Lab" (correct: Small Seed Labs), ~300 words too long, CTA pushed Discord but
   linked the site, weak 120+ char headline, no image.

## 7. Roadmap after that (in order)
1. Live end-to-end Reddit campaign with funded wallet; verify campaign, metrics ingestion, reviewer wake and checkpoint report.
2. Ad-service events wake the reviewer early (endpoint exists in Hub; ads doesn't call it yet).
3. Reddit pixel / conversion tracking.
4. Fix Redis limiter failing open.
5. Images via generation (after cost OK). 6. Automatic small changes only after observing a real campaign.
7. Later: proba-pages (landing pages at <product>.smallseedlabs.com), more ad platforms, vertical apps on the same brain.

## 8. Working rules with Sangam
- Make product decisions as staff product designer and technical decisions as staff engineer without asking.
- Short updates, exact pointers (file:line, PR links), no theory. Be token-efficient.
- Every change = focused PR to main, never stacked; tests/lint/typecheck pass first; he merges. Give a merge order.
- Never: force-push or destructive git without confirming, disable checks, broaden allowlists, put secrets in repos or print `.env`,
  deploy to production, approve/launch on his behalf, default or prefill landing URLs, spend beyond caps.
- Mac shell is zsh (no word-splitting; `===` breaks echo), no `rg` (use grep), `gh` is logged in.
