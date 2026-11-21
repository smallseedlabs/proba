# Proba harness build plan

Small Seed Labs · written 21 Nov 2026 · plan only, no code changed.

The harness is the judgment layer around the brain: it learns, checks, plans money, watches live spend and decides when spending is worth it. This plan builds it on top of what already exists. It is not a revamp.

Verified against `main` on 21 Nov 2026: gateway `742fbf5`, hub `25b5020`, ad-domain `369857a`, web `a43d270`, memory `7c215ba`. It builds on the team review Page ("Proba: team review, release plan and idea-size verdict") and on `docs/GEMINI_TAKEOVER_BRIEF.md`.

Team: Staff Product Designer (PD), Staff UI Designer (UI), Staff Engineering Manager (EM), CTO. The CTO reviews every task's PR before it reaches Sangam.

---

## 0. How Gemini should use this

1. **Review first.** Read all of it against the code on `main`. Push back in writing on anything that is wrong, already done, or badly sized. Put your comments on this PR or in a short `docs/HARNESS_BUILD_PLAN_REVIEW.md`. Do not start code until Sangam says go.
2. **Execute in order.** Take the tasks in phase order (P0 → P6), and inside a phase follow the `Deps` column. Each task is **one focused PR to `main`** in the named repo. No stacking: merge the dependency first (Sangam merges).
3. **Each PR description** must include the task ID, the acceptance tests and their results, and a **Spend impact** section ("can this PR cause or increase real spend? how is it bounded?").
4. **No real spend** until the CTO money gate (G1) is green, and no beta until G2 is green. Tests use the scripted HTTP provider (`ad-domain/src/providers/scripted-http.ts`) and fakes. Running the £5 canary needs Sangam's explicit approval.
5. **Never:**
   - disable checks or broaden allowlists;
   - default or prefill a landing URL (the user always enters it);
   - put secrets in a repo, PR or log, or read `.env` or `.state` values;
   - force-push, merge, deploy to prod, or launch on Sangam's behalf.
6. If a task turns out bigger than its size, split it and say so in the PR. Do not grow the PR.

---

## 1. Vision and principles

**Vision.** You put one goal in. Proba researches it, writes the copy and creatives, plans the targeting and budget, launches safely, watches the live metrics, optimises toward the goal across several campaigns and platforms, and reports. You approve guardrail cards in one view. That view aggregates Reddit, Meta and Google per goal, which none of the native UIs do.

**Principles (ordered; a higher one wins a conflict):**
1. **Money safety first.** Hard limits live in locked code (ad-domain and the gateway catalog), never in prompts. The brain can tighten them but never loosen them. Anything that can increase spend needs an explicit human approval.
2. **Never waste, never degrade.** Each paid action (a media generation, an extra research pass, a new test) must state why it is needed. Quality is never cut to save money when the evidence shows quality is the bottleneck.
3. **Brain-led quality.** Judgment comes from self-knowledge (worked cases, learned examples) and research, not from static prompt rules. Code holds only limits and formats.
4. **Learn only the right things.** Nothing enters self-memory without a source, a separate check and a trust score. Our own campaign outcomes outrank web claims. Trust decays.
5. **Two keys.** The brain proposes. A separate checker verifies. Locked code enforces. A human approves anything that increases spend.
6. **Calm operator.** The reviewer picks its own next check (1–72 h). A locked watchdog runs separately every 15 minutes and can only pause.
7. **Token-efficient.** Context is a summarised core plus fetched, relevant detail (top-k cases by state tags). No dumping.
8. **Build on what exists.** We extend the guardrails layers, action-policy, reviewer, research acceptance, self-memory bootstrap, LaunchPreviewCard and GoalsView.

---

## 2. Current state (verified on main)

| Area | Finding (file:line) | Severity |
|---|---|---|
| Auto-approve | `proba-web/src/components/views/GoalsView.tsx:343-368`: in 1-Click mode it auto-responds `approve` to `plan_approval`, `research_review`, `attach_user_page`, and to `ads.create_campaign`/`action_approval` once the goal is in `launchedGoalIds` | P0 |
| Reddit create | `ad-domain/src/providers/reddit/adapter.ts:405,434,460,500`: campaign, ad group and ad are created `ACTIVE`; `objective: 'CLICKS'` is hard-coded (406); `DAILY_SPEND` + `BIDLESS`; no `spend_cap` | P0 |
| Untargeted retry | `adapter.ts:~452-477`: a second ad-group create with no targeting when Reddit refuses the targeting | P0 |
| All platforms | `proba-llm-gateway/src/loop/brief.ts:55-59`: "Launch on ALL connected platforms" | P0 |
| Caps | `ad-domain/src/config.ts:259`: `ADS_MAX_DAILY_BUDGET` is optional (no cap); the check is per command only (`domain/billing.ts`); no goal or account aggregate, no lifetime cap | P0 |
| Meta | `providers/meta/adapter.ts`: created ACTIVE, default budget 10, default geo US+GB | P1 |
| Metrics | `ad-domain/src/config.ts:221,266`: metrics sync is off by default, hourly by default | P0 |
| Reviewer | `proba-hub/src/config.ts:254-266`: cadence 6 h; bounds min 6 h / max 72 h; tighten-only, max 20% auto change (good base) | P1 |
| Guardrails | `proba-llm-gateway/src/guardrails/guardrails.ts`: 4 tighten-only layers (catalog → deployment → file → env); refuses to loosen at start-up (good base). No output checker exists | — |
| Research | `proba-llm-gateway/src/research/*`: web search (Bing RSS), SSRF-guarded URL fetch, page assets, versioned artifacts, acceptance guard (good base). Nothing turns findings into durable knowledge | P1 |
| Self-memory | `proba-memory/bootstrap/proba-self.json`: 16 entries (`key,title,category,tier,tags,content`); `decayedAt` exists in the write pipeline but is unused for trust. memory-api exposes only `POST /v1/memories/search` | P1 |
| Data | Hub migrations up to `016_goal_creative_variants.sql`; ad-domain has only `001_ads_foundation.sql`; no budget ledger, experiments or decisions | P1 |
| Platforms | ad-domain providers: `reddit`, `meta` only. **No Google adapter**; protocol metrics types mention Google | P2 |
| Media | `creative.generate_media` (FAL) is called on brain judgment; the brief text says "prefer og:image", but no locked gate and no reason is logged | P1 |

---

## 3. Product design (PD)

### 3.1 The model changes
- **Before:** goal = one campaign.
- **After:** goal = budget B + success metric + target + end date. It is pursued through **experiments**, and each experiment has 1–n **cells** (campaigns).
- The optimiser works on the goal, not on single campaigns.

### 3.2 Core flow (the one-click view)
1. **Describe the goal.** One sentence plus a **landing URL the user types** (never prefilled). Proba asks only for the total budget B and confirms the success metric it inferred.
2. **Research** (automatic). Sourced findings. The checker validates them; the user sees them only if the checker flags something.
3. **Plan card** (approval 1). Platform mix, cells, learning budget, caps, end date, objective, the brain's reasons, and a **worst-case line**: "You can lose at most £X before Proba stops and asks you."
4. **Creative card(s).** One per cell, editable. Shows the checker's verdict and the spend-gate reason if a new image was generated.
5. **Launch card** (approval 2, the only spend approval). Campaigns are created PAUSED. Approving this activates them after a read-back matches the plan.
6. **Learning** (days 1–3). A quiet view. The watchdog runs silently; the only interruption is a safety pause.
7. **Decision cards.** Stop / refresh creative / swap test / rebalance / scale. Each shows the evidence, the money impact, the checker verdict and one-tap approve. Pauses and decreases auto-apply and notify; increases always need a card.
8. **Reports.** Interim every 3 days and a final one: learned, spent vs plan, next recommendation. The lessons feed the learning pipeline.

**1-Click is redefined** as "one tap per money decision". It never auto-approves a spend ask.

### 3.3 Product decisions (made)
| # | Decision |
|---|---|
| D1 | Remove every browser-side auto-approve of `plan_approval`, `ads.create_campaign` and `action_approval`. Auto-advance stays only for `attach_user_page` (the user already typed the URL) and for `research_review` **only when the checker passed it**. |
| D2 | The first launch of a goal uses **one platform**. A second platform is added only by an experiment card after the first has evidence, or when the planner fits both inside B with each cell above the platform minimum. |
| D3 | Objective follows the conversion signal: verified pixel → conversion objective; otherwise traffic (landing-page views) with a banner explaining why. |
| D4 | Auto-applied actions are limited to pause, stop and decrease. Every increase (budget, new cell, new platform) is a card. |
| D5 | Own ad accounts only for beta and GA. Proba Managed (the Small Seed Labs account) stays off until prepaid wallets exist. |
| D6 | The idea-testing preset: a "Validate an idea" goal type (fake door, B = £60, 5 days, 2 creatives × 1 audience, scorecard). |

---

## 4. UI design (UI)

One visual language for money: a **spend vs cap bar with a pace marker** wherever money appears.

| Screen | Elements | States |
|---|---|---|
| **Goal header** | Goal metric vs target, spend/B bar + pace marker, days left, phase pill, kill switch ("Pause everything") | Planning · Awaiting launch · Learning · Optimising · Paused (safety) · Done |
| **Campaign list** (per goal, all platforms) | Row per cell: platform icon, creative thumbnail, audience, spend/cap bar, CTR, CPC, conversions, CPA, verdict pill | Learning · Winner · Loser (stopped) · Refreshing · Blocked · Paused by watchdog |
| **Aggregated dashboard** (the differentiator) | Per goal and per workspace: blended spend, conversions, CPA, CTR across Reddit/Meta/Google; platform comparison bars; spend over time per platform; "where the next £ goes" | Live · Stale (sync older than 30 min; shows the timestamp) · Missing platform (connect CTA) |
| **Plan card** (extends `LaunchPreviewCard.tsx`) | Budget split (learning/scale/reserve), worst-case line, caps, end date, objective + reason, brain reasons, checker badge | Editable · Approved · Refused by guardrail (why + what to change) |
| **Decision card** | Before → after, evidence numbers vs the minimum evidence, money impact, rule or brain reason, checker verdict, Approve / Change / Dismiss | Pending · Auto-applied (safety) · Approved · Rejected by checker · Expired |
| **Guardrail rejection** | Who refused (locked limit or checker), plain reason, the offending field highlighted, what the brain will do next (repair attempt n of 2, or ask) | Repairing · Needs you · Resolved |
| **Spend-gate log** (inline on cards) | "Generated a new image because: no usable site image (og:image 400×200 < 1080×1080)" with cost | — |
| **Knowledge view** (new tab) | Learned examples: claim, source link or own campaign, trust score + decay, checker verdict, used-in-N-plans; filters (own/web/seed, platform, objective); retire button | Proposed · Approved · Rejected · Retired |
| **Report view** | Learned / spent / next, per-cell table, export | Interim · Final |
| **Safety banner** | Shown when the watchdog paused something; one-tap "review and resume" (a resume is a spend approval) | Only when it happens |
| **Activity timeline** | Each reviewer check, why it picked the next time, checker verdicts | Collapsed by default |

Accessibility: tone is never colour alone (pill text + icon), and the money bars have numeric labels.

---

## 5. Engineering design (EM + CTO)

### 5.1 Components and owners

| Component | Repo / service | New or extend |
|---|---|---|
| Budget ledger + guardrail policy | ad-domain | New (migration 002) |
| Parameter planner (pure function) | ad-domain `src/domain/planner.ts` | New |
| Spend-pace watchdog (pause-only) + kill switch | ad-domain `src/domain/watchdog.ts` | New |
| Metrics sync (15 min in learning) + snapshots | ad-domain `domain/metrics-sync.ts` | Extend |
| Provider safety (PAUSED, spend_cap, lifetime, no fallback, rollback) | ad-domain `providers/reddit`, `providers/meta` | Extend |
| Explicit approval token | hub (verify) + web (send) | New |
| Experiments, decisions, goal budget | hub migrations 017–019 | New |
| Reviewer (calm, own cadence) | hub `src/analytics/reviewer.ts`, `scheduler.ts` | Extend |
| Aggregated metrics API | hub `src/analytics/service.ts` | Extend |
| Guardrails checker agent | gateway `src/checker/` (new), wired in `loop/run-loop.ts` and `limbs/dispatcher.ts` | New |
| Spend-vs-quality gate | gateway `src/spend-gate/` (new), wraps `media/provider.ts` and research | New |
| Learning pipeline (propose → verify → store) | gateway `src/learning/` + memory write route + memory scoring | New |
| Knowledge store + trust decay | proba-memory (migration 0009, `packages/scoring/src/score.ts`) | Extend |
| State-tag retrieval | proba-context `packages/core/src/pipeline/selfDetail.ts` | Extend |
| Contracts (plan, verdict, decision, knowledge) | proba-protocol `src/schemas` | Extend (minor version) |
| UI | proba-web `components/views/*` | Extend |

### 5.2 Guardrail layering (who can stop what)

```
L0  Locked code (ad-domain)  ledger caps, platform minimums, PAUSED create, spend_cap,
                             end_time, geo required, no untargeted, max live per goal,
                             prod boot refusal. Cannot be configured looser.
L1  Locked code (gateway)    verb catalog, requiresApproval, GATEWAY_MAX_*, CREATIVE_LOCKS,
                             banned phrases, REVIEW_LOCKS (existing tighten-only layers).
L2  Deterministic checks     checker part A: schema, policy words, image size/ratio,
                             targeting validity, numbers inside planner bounds, URL = user URL.
L3  Checker agent            checker part B: separate LLM call, separate context, judges
                             source faithfulness, claims, brand safety, goal fit, waste.
L4  Human                    plan card, launch card, any increase. Server-verified token.
L5  Watchdog (runtime)       pause-only, every 15 min, independent of the brain.
```
Each layer can only narrow the one above. A rejection at L0–L3 returns a typed refusal `{layer, code, field, reason, repairHint}`. The brain gets at most **2 repair attempts**, then the system raises a "Needs you" card.

### 5.3 Campaign parameter algorithm (locked planner)

Input: B, currency, duration D (default 7), goal metric + target, conversion signal (verified or not), connected platforms, platform minimums (locked table), benchmarks (self-memory + research, trust-weighted), workspace policy, and the brain's proposal (hypotheses, cells, platform mix, objective).

```
cells       = min(brainCells, policy.maxLearningCells (2), floor(L / (minDaily × 3)))
L (learn)   = clamp(0.4·B, cells·minDaily·3, 0.6·B)
dailyCell   = max(minDaily, L / (cells·3))
Reserve     = 0.2·B   (untouched until a winner meets minimum evidence)
Scale       = B − L − Reserve
lifetimeCap = per-cell allocation → provider spend_cap / lifetime_budget
endAt       = start + D (required)
refuse if B < minDaily·3·1  → suggest the minimum B or a cheaper platform
```
- **Bid/objective table.** Awareness → impressions/reach. Traffic with no signal → clicks/landing-page views, lowest cost; cost cap at 1.2× median CPC after day 3 if CPC is volatile. Leads with a verified pixel → conversions on the upper event. Purchases → upper event below $100/day. Video → viewable/ThruPlay.
- **Pacing.** Expected spend(t) = allocation × elapsed share. Above 1.3× expected → wake the reviewer. Above 1.5×, or daily above 1.2× the cap → the watchdog pauses.
- **Targeting ladder.** 1) the brain's communities + interests + geo, validated before create; 2) drop only the invalid items; 3) interests + geo; 4) stop and ask. **Never untargeted. Geo is always required.**
- **Concurrency.** Max 2 cells in learning and 3 live per goal; first launch on one platform (D2).
- **Stop/scale.**
  - Stop a cell with 0 conversions after spending ≥ 2× the target CPA.
  - Stop a cell with CTR < 0.3× benchmark after 1k impressions.
  - Scale +20% from the reserve, at most once per 48 h, when CPA ≤ 0.8× target with ≥ 10 conversions (or ≥ 100 clicks for traffic goals).
  - Refresh the creative when CTR falls 30% or frequency > 3.
  - Rebalance in proportion to conversions per £; the goal total is unchanged.

The brain may only **tighten**: fewer cells, lower caps, earlier stop. The planner returns `{plan, clamps[]}`, so the card can show "the brain asked £25/day; the cap is £10".

### 5.4 Data models and migrations

**ad-domain `002_budget_ledger.sql`**
- `guardrail_policy(workspace_id pk, max_goal_lifetime, max_account_daily, max_live_per_goal, max_learning_cells, allowed_platforms text[], currency, updated_at)`
- `budget_ledger(id, workspace_id, goal_id, campaign_id null, kind[allocate|commit|release|spend_sync], amount_minor bigint, currency, as_of, source)`; view `goal_budget_state(goal_id, allocated, committed, spent)`
- `ads.campaigns` + `experiment_id, objective, bid_strategy, budget_type, lifetime_cap_minor, start_at, end_at, phase, watchdog_state`
- `metrics_snapshots(campaign_id, ts, spend_minor, impressions, clicks, conversions, source, pk(campaign_id, ts))` (Postgres first; ClickHouse later)
- `watchdog_events(id, campaign_id, ts, rule, observed, expected, action[paused|alerted])`

**hub `017_goal_budget.sql`**: `goals` + `budget_total_minor, currency, success_metric, target_value, ends_at, phase`
**hub `018_experiments_decisions.sql`**
- `experiments(id, goal_id, hypothesis, variable[creative|audience|platform|objective], phase, winner_campaign_id)`
- `decisions(id, goal_id, campaign_id, kind[stop|refresh|swap|rebalance|scale|pause], inputs_snapshot jsonb, rule_fired, brain_rationale, checker_verdict jsonb, change jsonb, approval[auto_safety|card], approved_by, approval_token_id, applied_at, outcome jsonb)`
**hub `019_approval_tokens.sql`**: `approval_tokens(id, ask_id, user_id, gesture_at, nonce, consumed_at)`
**hub `020_paid_actions.sql`**: `paid_actions(id, goal_id, kind[media|research|llm_extra], justification_code, evidence jsonb, est_cost, actual_cost, verdict)`

**memory `0009_knowledge_provenance.sql`** (extends the existing memories table; no new store)
- `source_kind [seed|web|own_outcome]`, `source_url`, `source_quote`, `evidence jsonb` (metrics for own outcomes), `trust real`, `half_life_days int`, `verified_by`, `verified_at`, `status [proposed|approved|rejected|retired]`, `supersedes`

### 5.5 Interfaces (protocol, minor version bump)
- `PlanProposal` (from the brain) → `PlannerResult {plan, clamps[], refusal?}`
- `CheckerRequest {subject: copy|image|targeting|budget_plan|optimiser_action|knowledge, payload, sources[], goalState}` → `CheckerVerdict {verdict: pass|reject|needs_human, reasons[{code, field, text}], layer, checkedAt}`
- `Decision` (as in the table above) and `ApprovalToken` (opaque id; Hub verifies it is single-use, bound to the ask, and fresh: under 10 min)
- `KnowledgeProposal {claim, situation, numbers, decision, outcome, lesson, tags[], source{kind, url, quote}|evidence}` → stored as `proposed`
- `PaidActionRequest {kind, justification_code: no_usable_image|platform_check_failed|creative_bottleneck|user_requested|research_gap, evidence}` → `allow|deny{reason}`
- `AggregatedGoalMetrics {goalId, asOf, perPlatform[], blended{spend, conversions, cpa, ctr}, freshness}`

### 5.6 Learning pipeline (self-learning that learns the right thing)
```
propose   brain (during research, or a reviewer post-mortem) emits KnowledgeProposal
           - web: must carry the url + exact quote from a page fetched this run (SSRF-safe fetch)
           - own_outcome: generated from decisions + metrics_snapshots when a cell ends
verify    checker: (a) quote present at source (deterministic re-fetch / artifact match)
                   (b) claim does not contradict L0 limits or higher-trust knowledge
                   (c) for own_outcome: evidence meets minimum sample (≥1k impr or ≥10 conv)
                   (d) generality: tags + situation specific enough to retrieve correctly
store     memory write route (service-auth, internal only) → status approved | rejected
trust     initial: seed 0.6, web 0.4 (0.5 if ≥2 independent sources), own_outcome 0.7–0.9 by sample
           effective = trust × 0.5^(age_days / half_life)  (web 90d, own 180d, seed 365d)
           reinforced when a plan using it meets target; reduced when it misses
retrieve  context-api: state tags (objective, platform, budget_band, phase, signal) → top 3 cases,
           ranked own_outcome > seed > web at equal relevance; trust < 0.2 never retrieved
retire    user or checker can retire; superseded entries are never edited in place
```
Rule: the brain **never writes memory directly**. Only the pipeline writes, and only after a checker pass.

### 5.7 Spend-vs-quality gate
- Wraps every paid call: `creative.generate_media`, any research pass beyond the first, and LLM calls above the per-goal budget.
- **Media is allowed only if:**
  - no usable site or og image (missing, below the platform's minimum size or ratio, or failing the image probe);
  - a platform policy or check failed on the existing image;
  - metrics show the creative is the bottleneck (CTR < 0.5× benchmark with targeting and landing page healthy, or fatigue);
  - the user asked for it.
- Otherwise it is denied with a reason, and the brain uses the existing asset.
- Every allow writes a `paid_actions` row with its evidence and cost; the card shows the line.
- **Quality floor.** The gate never blocks a regeneration when the checker rejected the current image for quality. Quality failure is a valid justification.
- Per-goal model and media cost is shown on the goal header (target: ≤ £5 per goal-week).

### 5.8 Multi-campaign goals and the second-half optimiser
- The reviewer (brain, calm, picks the next check within 1–72 h) reads the aggregated metrics and recent decisions. It proposes optimiser verbs: `opt.stop_cell`, `opt.refresh_creative`, `opt.swap_test`, `opt.rebalance`, `opt.scale`.
- Every proposal goes through planner bounds → checker → card (or auto-apply if it is a decrease).
- Optimiser verbs are catalog entries with `requiresApproval` (increase) or `safetyDecrease`.
- Reports are built from `decisions` + `metrics_snapshots`. They feed own-outcome proposals into the learning pipeline.

### 5.9 Analytics
- UTM tags on every `click_url`: `utm_source={platform}&utm_campaign={goal}&utm_content={cell}`.
- Pixel and CAPI verification: fire a test event and confirm the platform saw it. The result is stored as `conversion_signal=verified`.
- Metrics sync runs every 15 minutes in learning and hourly after that. Freshness is shown in the UI. Missing metrics are never shown as 0 (an existing rule; keep it).

---

## 6. CTO review

### 6.1 Risks
| Risk | Likelihood | Mitigation |
|---|---|---|
| A runaway spend repeats before P0/P1 land | High if anyone launches | No real spend until G1; pause the existing live Reddit campaigns by hand |
| The checker becomes a rubber stamp (same model, same context) | Medium | Separate prompt and context slice; deterministic part A first; a red-team golden set of 30 bad outputs must be rejected ≥ 95% |
| The learning pipeline absorbs bad web advice | Medium | Quote-at-source check, trust decay, own outcomes outrank web, trust < 0.2 is never retrieved, retire button |
| Thin data at £100 budgets makes the optimiser noisy | High | Minimum-evidence thresholds; "hold" is the default action |
| Cross-repo contract drift (5 repos) | Medium | Protocol schemas first in each phase; contract fixtures tests |
| LLM + media cost per goal exceeds the fee | Medium | Spend gate, cost ledger, prompt caching, the cheap model for the checker |
| Google adapter scope (none exists) | High effort | Read-only metrics first (P5); create later, behind its own gate |
| Meta app review delay | Medium | Start the review now; Reddit is the beta platform |

### 6.2 Release gates (all pass/fail)
**G1, money gate (needed before any real spend, including the canary):**
- [ ] No spend-increasing call is possible without a Hub-verified, single-use approval token (H0-02 test)
- [ ] All creates are PAUSED, with spend_cap/lifetime and end_time; activation happens only after a read-back matches the plan (H0-03, H0-05)
- [ ] No untargeted fallback, default budget or default geo anywhere (grep test + unit tests)
- [ ] The ledger refuses any breach of goal lifetime, goal daily, account daily or max live (H1-02)
- [ ] The watchdog pauses a simulated 3× overspend within one 15-minute tick (H1-04)
- [ ] Prod refuses to boot with no cap or with metrics sync off (H0-07)
- [ ] The kill switch pauses every live campaign in a workspace (H1-05)

**G2, quality gate (needed before the closed beta):**
- [ ] Planner goldens pass for 12 scenarios (H2-01)
- [ ] The checker rejects ≥ 95% of 30 red-team outputs and passes ≥ 90% of 30 good ones (H3-02)
- [ ] The spend gate denies media when a usable site image exists (H3-04)
- [ ] Learning: an unsourced or misquoted claim is never stored; an own outcome outranks web at equal relevance (H4-05, H4-04)
- [ ] Replaying 3 recorded campaigns gives decisions the CTO signs off (H6-01)
- [ ] The £5 lifetime canary on Reddit stays inside its cap, with sync and watchdog seen working (H6-02; Sangam approves the run)

**G3, GA gate:** zero cap breaches in the beta; 3 of 5 partners reach their goal metric; backups and restore tested; secrets in a manager; Managed spend off.

### 6.3 Open decisions (Sangam)
1. **Workspace defaults for guardrail_policy**: proposed max £150 lifetime per goal, max £20/day per account, max 3 live per goal. Confirm or change.
2. **Checker model**: the same cheap DeepSeek flash with a separate context (proposed), or a different provider for independence (more cost and one more key).
3. **Google**: read-only metrics in P5 (proposed), with Google campaign creation after GA; or creation in scope for beta.
4. **research_review auto-advance** when the checker passes (D1). Proposed: yes. Alternative: always show it.
5. **Hub migration numbering**: Gemini may have unmerged work at 017+. Renumber at PR time; never edit a merged migration.

---

## 7. Task list (ordered, phased)

Size: S ≤ ½ day, M ≈ 1 day, L ≈ 2–3 days (split if larger). Every task is one PR to `main` in the named repo. Acceptance tests must be automated unless they are marked *manual*.

### P0 — Stop the bleeding (money safety) · 8 tasks · gate: part of G1

| ID | Repo | Files likely touched | Deps | Acceptance tests (pass/fail) | Size |
|---|---|---|---|---|---|
| H0-01 | proba-web | `src/components/views/GoalsView.tsx` (343-368), `GoalsView.test.tsx` | — | In auto mode, a pending `plan_approval`, `ads.create_campaign` or `action_approval` ask is **not** responded to without a click; `attach_user_page` still auto-advances; existing tests green | S |
| H0-02 | proba-hub | `src/routes/*answer*`, new `src/auth/approval-token.ts`, migration `019_approval_tokens.sql`, integration test | — | An answer to a spend ask with no token, a reused token, a token for another ask or a stale (>10 min) token → 4xx and audit `approval.rejected`; a valid token → accepted once | M |
| H0-02b | proba-web | `AskCard.tsx`, `LaunchPreviewCard.tsx`, api client | H0-02 | The Approve click obtains and sends a token; e2e test with fake hub | S |
| H0-03 | ad-domain | `src/providers/reddit/adapter.ts`, `execute.reddit.test.ts` | — | Scripted HTTP shows campaign/ad group/ad created `PAUSED`; campaign has `spend_cap` = allocation; ad group `LIFETIME_SPEND` + start/end; activation only via `ads.resume_campaign` after a read-back matches; `objective` is taken from the command (CLICKS only as an explicit value) | M |
| H0-04 | ad-domain | `reddit/adapter.ts` (452-491), tests | H0-03 | Targeting refusal → typed refusal `targeting_refused` and **no second create call**; ad group/ad failure → campaign paused and archived, outcome is a refusal (not success) | S |
| H0-05 | ad-domain | `src/providers/meta/adapter.ts`, tests | — | Missing budget or geo → refusal (no default 10, no US+GB); create PAUSED with `lifetime_budget` + `end_time` | S |
| H0-06 | proba-llm-gateway | `src/loop/brief.ts` (55-59), `brief.test.ts` | — | The brief no longer contains "ALL connected platforms"; with 2 platforms connected, the brief says to propose a platform mix for the planner | S |
| H0-07 | ad-domain | `src/config.ts`, `config.test.ts` | — | `NODE_ENV=production` with no `ADS_MAX_DAILY_BUDGET` or with `ADS_METRICS_SYNC_ENABLED=false` → ConfigError at boot; dev is unchanged | S |

### P1 — Ledger, metrics and watchdog · 7 tasks · gate: G1 complete

| ID | Repo | Files likely touched | Deps | Acceptance tests | Size |
|---|---|---|---|---|---|
| H1-01 | proba-protocol | `src/schemas` (`GuardrailPolicy`, `LedgerEntry`, `Refusal` codes) | — | Schema tests + fixtures; minor version bump; no breaking change | S |
| H1-02 | ad-domain | migration `002_budget_ledger.sql`, `src/domain/ledger.ts`, `execute.ts`, `billing.ts` | H1-01, H0-03 | In the same transaction as the create or increase: refuse when it would exceed goal lifetime, goal daily, account daily or max live per goal; two concurrent creates for one goal → exactly one succeeds (integration test) | L |
| H1-03 | ad-domain | `domain/metrics-sync.ts`, `config.ts`, `metrics_snapshots` | H1-02 | The interval is 15 min while any campaign is in learning and hourly otherwise; snapshots are written; missing metrics stay null | M |
| H1-04 | ad-domain | new `src/domain/watchdog.ts`, `runtime.ts`, tests | H1-03 | Scripted 3× pace → paused within one tick, `watchdog_events` row written; 1.3× → hub reviewer woken, no pause; the watchdog cannot call any verb except pause (unit test on its port) | M |
| H1-05 | ad-domain + proba-hub | `routes` kill-switch endpoint (ad-domain), hub proxy + audit | H1-04 | One call pauses all live campaigns in a workspace; it is idempotent; audited; resuming needs approval tokens | M |
| H1-06 | proba-hub | `src/analytics/reviewer.ts`, `scheduler.ts`, `config.ts` | H1-03 | Every live campaign is registered with `review_enabled=true` (no opt-out); `next_check_at` is set at launch; the brain-chosen next check is clamped to [1 h, 72 h]; there is no fixed cadence in brain mode | M |
| H1-07 | proba-web | `GoalStatusPanel.tsx`, `CampaignsView.tsx`, new `SpendCapBar` | H1-02 | Spend/cap bar with a pace marker on the goal and campaign rows; safety banner when the watchdog paused; kill-switch button with confirm | M |

### P2 — Planner, objectives and measurement · 6 tasks · gate: G2 partial

| ID | Repo | Files likely touched | Deps | Acceptance tests | Size |
|---|---|---|---|---|---|
| H2-01 | ad-domain | new `src/domain/planner.ts`, `planner.test.ts`, `planner.golden/*.json` | H1-02 | 12 golden scenarios (£20 refuse, £30/1 cell, £100/2 cells, £300/4 cells, no pixel, verified pixel, purchase <$100/day, video, 2 platforms, brain asks above cap → clamped, brain asks fewer cells → honoured, geo missing → refuse) all match | M |
| H2-02 | proba-protocol | `PlanProposal`, `PlannerResult` schemas | H2-01 | Fixtures round-trip; clamps array is required | S |
| H2-03 | proba-llm-gateway | `limbs/catalog.ts` (`ads.plan` read-only verb), `limbs/plan-sections.ts`, `loop/brief.ts` | H2-02 | The plan card shows planner numbers and clamps; the brain cannot submit `ads.create_campaign` with numbers outside `PlannerResult` (dispatcher refusal test) | M |
| H2-04 | ad-domain | `reddit/adapter.ts`, `meta/adapter.ts` objective mapping | H2-01 | Verified signal → CONVERSIONS / OUTCOME_LEADS; unverified → traffic; the hard-coded `'CLICKS'` (adapter.ts:406) is gone | S |
| H2-05 | ad-domain | `domain/url.ts`, `url.test.ts` | — | Every click_url carries utm_source/campaign/content; the user's URL path and query are preserved; never replaced | S |
| H2-06 | ad-domain + proba-hub | `providers/reddit` (conversions test event), hub goal `conversion_signal` | H2-04 | A test event seen → `verified`; not seen within 10 min → `unverified` with banner; *manual* check on Sangam's site with his approval | M |

### P3 — Guardrails checker and spend gate · 7 tasks · gate: G2 partial

| ID | Repo | Files likely touched | Deps | Acceptance tests | Size |
|---|---|---|---|---|---|
| H3-01 | proba-protocol | `CheckerRequest`, `CheckerVerdict`, `PaidActionRequest` | — | Schema fixtures | S |
| H3-02 | proba-llm-gateway | new `src/checker/{deterministic,agent,index}.ts`, `checker.golden/` (30 bad + 30 good) | H3-01 | Part A (deterministic) catches schema, size, URL ≠ user URL, numbers outside planner bounds, banned phrases; part B runs as a separate call with its own context; red-team ≥ 95% rejected, good ≥ 90% passed; runs on the cheap model with caching | L |
| H3-03 | proba-llm-gateway | `loop/run-loop.ts`, `limbs/dispatcher.ts` | H3-02 | Every copy, image, targeting, budget-plan and optimiser output passes the checker before dispatch; reject → repair (max 2) → `needs_human` ask; audit event per verdict | M |
| H3-04 | proba-llm-gateway | new `src/spend-gate/index.ts`, `media/provider.ts`, `research/gather.ts` | H3-01 | Media denied when a usable site/og image exists; allowed with each of the 4 justifications; every allow logs `paid_actions`; a quality rejection always justifies a regeneration | M |
| H3-05 | proba-hub | migration `020_paid_actions.sql`, verdicts on asks, routes | H3-03, H3-04 | Verdicts and paid actions are persisted and returned with asks; per-goal cost sum endpoint | M |
| H3-06 | proba-web | `AskCard.tsx`, new `GuardrailRejection.tsx`, spend-gate line on `PostCreativeCard.tsx` | H3-05 | Rejection card shows layer, reason, field and repair state; the spend-gate reason and cost are visible on creatives | M |
| H3-07 | proba-llm-gateway | `src/usage/*` per-goal cost cap | H3-04 | Per-goal model + media cost above the cap → further paid actions denied with a reason; the run continues on free paths | S |

### P4 — Self-learning brain · 9 tasks · gate: G2 partial

| ID | Repo | Files likely touched | Deps | Acceptance tests | Size |
|---|---|---|---|---|---|
| H4-01 | proba-memory | `migrations/postgres/0009_knowledge_provenance.sql` + rollback, `packages/core/src/domain/memory.ts` | — | Migration up/down clean; existing entries default to `source_kind=seed, trust=0.6, status=approved` | S |
| H4-02 | proba-memory | `packages/scoring/src/score.ts`, `scoring.test.ts` | H4-01 | Effective trust = trust × 0.5^(age/half-life); trust < 0.2 is never returned; own_outcome outranks web at equal relevance | S |
| H4-03 | proba-memory | `apps/memory-api/src/server.ts` (internal `POST /v1/knowledge/proposals`, `/approve`, `/retire`), write pipeline | H4-01 | Service-auth only (no user token, no public route); approve requires a checker verdict id; entries are superseded, never edited | M |
| H4-04 | proba-context | `packages/core/src/pipeline/selfDetail.ts`, tests | H4-02 | Tags computed from goal state (objective, platform, budget_band, phase, signal); top 3 cases in the memory section; token budget respected (test) | M |
| H4-05 | proba-memory | `bootstrap/proba-self.json` (version bump), `apps/memory-eval/golden/*` | H4-04 | ≥ 12 worked cases (situation → numbers → decision → outcome → lesson) covering targeting, bids, caps, learning budget, stop, scale, refresh, rebalance, refusal, the £13 incident; memory-eval golden retrieval passes | M |
| H4-06 | proba-llm-gateway | new `src/learning/{propose,verify}.ts`, catalog `learn.propose_example` (no execution) | H4-03, H3-02 | A web proposal without an exact quote found in a fetched artifact → rejected; a contradiction of L0 or of higher-trust knowledge → rejected; a valid one → stored `approved` with source and trust | L |
| H4-07 | proba-hub + proba-llm-gateway | hub post-mortem job on cell end; gateway reviewer emits own_outcome proposals | H4-06, H5-01 | A cell that ends with ≥ minimum sample produces a proposal with metrics evidence; below the sample → none | M |
| H4-08 | proba-llm-gateway | `loop/brief.ts` (65-75 CTA/media rules) | H4-05 | The static CTA/Reel rules are removed from the brief and live as self cases; brief tests updated; format limits remain in code | S |
| H4-09 | proba-web | new `KnowledgeView.tsx`, nav | H4-03 | List and filter (own/web/seed), source link, trust + decay, retire action (calls the hub proxy) | M |

### P5 — Multi-campaign goals, optimiser, aggregated view · 9 tasks

| ID | Repo | Files likely touched | Deps | Acceptance tests | Size |
|---|---|---|---|---|---|
| H5-01 | proba-hub | migrations `017_goal_budget.sql`, `018_experiments_decisions.sql`, types | H1-02 | Up/down clean; a goal has n experiments with n cells; the ledger mirror is read-only in hub | M |
| H5-02 | ad-domain | campaigns `experiment_id`, max-live enforcement | H5-01, H1-02 | A 4th live cell for a goal is refused; cells are linked to experiments | S |
| H5-03 | proba-protocol + proba-llm-gateway | `opt.*` verbs in the catalog (`requiresApproval` vs `safetyDecrease`), `limbs/review.ts` | H3-03, H2-03 | Increases always produce an ask; decreases auto-apply within the bounds; all go through planner and checker | L |
| H5-04 | proba-hub | `src/analytics/service.ts`, decisions routes, card emission | H5-03 | A decision row per proposal with inputs, rule, rationale, verdict and outcome; an approval consumes a token | M |
| H5-05 | proba-hub | `src/analytics/service.ts` aggregated endpoint | H1-03 | `AggregatedGoalMetrics` blends Reddit + Meta (+ Google when present) per goal and workspace; freshness field; never sums currencies without conversion (refusal) | M |
| H5-06 | proba-web | `GoalsView.tsx`, `CampaignsView.tsx`, `DecisionInbox.tsx`, `PlatformDeliveryMatrix.tsx` | H5-04, H5-05 | The one-click goal view shows header, cell list, decision cards and timeline; component tests for each state in §4 | L |
| H5-07 | proba-web | `AnalyticsCharts.tsx`, new `AggregatedDashboard.tsx` | H5-05 | Per-platform and blended figures; stale state after 30 min; missing-platform state | M |
| H5-08 | proba-hub + proba-llm-gateway | report builder, interim (3-day) and final | H5-04 | The report lists learned/spent/next with figures from snapshots only (no invented numbers; test) | M |
| H5-09 | ad-domain | new `src/providers/google/` (read-only metrics) | H5-05 | Scripted HTTP: metrics map to the snapshot schema; no create verbs exposed (catalog test) | L |

### P6 — Release and idea loop · 5 tasks

| ID | Repo | Files likely touched | Deps | Acceptance tests | Size |
|---|---|---|---|---|---|
| H6-01 | proba-hub (+ gateway testing) | new replay harness `src/testing/replay/*`, 3 recorded fixtures (anonymised) | H5-04 | Replay produces decisions; CTO signs off on the diff report (*manual sign-off*) | M |
| H6-02 | proba | `docs/CANARY_RUNBOOK.md`, `local/debug` dry-run script | G1 | The dry-run passes against scripted providers; the real £5 canary runs **only with Sangam's approval** (*manual*) | S |
| H6-03 | proba | `docs/DEPLOYMENT.md`, `docs/SECURITY_DEFAULTS.md` | G1 | Prod checklist: secrets manager, backups tested, Managed off, own accounts only; no secrets in docs | S |
| H6-04 | proba-hub + proba-web | "Validate an idea" goal preset + scorecard | H5-08 | The preset creates B = £60, 5 days, 2×1 cells; the scorecard ranks by sign-up cost, landing conversion and CTR | M |
| H6-05 | proba | `docs/IDEA_SIZE_REVIEW.md` after the beta | G3 data | Uses beta numbers: CPA vs target, cost per goal, retention; go or no-go on the venture path | S |

**Totals:** P0 8 (incl. H0-02b) · P1 7 · P2 6 · P3 7 · P4 9 · P5 9 · P6 5 = **51 tasks**. Estimate ≈ 45–55 working days for one agent; P0 + P1 ≈ 8 days.

### Critical path
H0-01 → H0-02 → H0-03 → H0-04 → H1-01 → H1-02 → H1-03 → H1-04 → (G1) → H2-01 → H2-03 → H3-02 → H3-03 → H5-03 → H5-04 → H5-06 → H6-01 → (G2) → beta.
Parallel-safe: H0-05, H0-06, H0-07, H2-05, H4-01…H4-05, H3-01.

---

## 8. Definition of done (every PR)
- Targets `main`, not stacked; CI green; no checks disabled; no allowlist widened.
- Tests for each acceptance criterion; the Spend impact section filled in.
- No secrets; no default or prefilled landing URL; no static prompt rule where a self case belongs.
- The CTO review comment states: gates touched, risks, pass/fail.
