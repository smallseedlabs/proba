# Testing the whole platform locally

One command brings up the Hub, the web app, the audit pipeline, the audit API and the metrics pipeline (with **stub** ad-platform data) on your machine.
Another one checks that what runs matches the design. Everything lives in [`local/`](../local); nothing in it is needed in production.

```bash
cd local
./up.sh        # build from your sibling checkouts' main branches and start everything (a cold first build takes several minutes, later runs seconds)
./seed.sh      # drive the Hub like the web app does: goals, approvals, kill switch, denied calls...
./verify.sh    # ~1 min of PASS/FAIL checks against the design
./down.sh      # stop (data kept)   |   ./reset.sh --yes   # stop and delete all local data
```

## Prerequisites

| Need | Notes |
|------|-------|
| Docker with Compose v2 | Docker Desktop or Colima; about 4 GB RAM for the containers |
| `curl`, `jq`, `git`, `openssl` | standard on macOS (`brew install jq` if missing) |
| bash 3.2+ | the macOS system bash is fine |
| Sibling checkouts | `proba-hub`, `proba-web`, `proba-audit` next to this repo (`~/Projects/proba/{proba-hub,...}`). Override with `PROBA_*_DIR` in `local/.env` |

`up.sh` builds from a snapshot of `origin/main` of each checkout (`git archive` into `local/.src/`), so whatever branch or uncommitted work you have in those
checkouts never leaks in, and it never touches them. To test a branch instead: `PROBA_REF=origin/some-branch ./up.sh`, or `PROBA_SRC=worktree ./up.sh` to build the
working trees as they are on disk. Run `git fetch` in a checkout first if you want its latest main.

No secrets are stored in the repository. On the first run `up.sh` creates `local/.env` (gitignored, mode 600) and fills `JWT_SECRET`, the database passwords
and the audit API's local token with random values that only exist on your machine.

## URLs and ports

All ports are bound to `127.0.0.1`. They are deliberately unusual so they do not clash with other projects. Change any of them in `local/.env`.

| Service | URL | Notes |
|---------|-----|-------|
| Web | http://localhost:5180 | sign-in needs the Firebase settings below |
| Hub API | http://localhost:3300 | `/health`; `POST /v1/commands`, `GET /v1/events`; `POST /dev/login` (development only) |
| Audit API | http://localhost:3400 | `/health`, `/ready`, `/v1/...` (read-only). Bearer token: `AUDIT_API_LOCAL_TOKEN` in `local/.env` |
| audit-consumer / metrics-ingester / rollup | :3401 / :3402 / :3403 | `/health` |
| ClickHouse (HTTP) | http://localhost:58125 | user `proba`, password in `local/.env`; `./sql.sh "..."` is the easy way |
| Postgres (Hub) | localhost:55433 | db `proba_hub`, user `proba` |
| Redis | localhost:56380 | one Redis for the Hub's pub/sub and the audit stream; AOF on |
| Portal (profile `portal`) | http://localhost:3410 | see "Portal profile" |

The compose project is `proba-local` and every container is called `proba-local-*`, so it runs next to other stacks (for example a `proba-audit-*` development
stack). Data is in the named volumes `proba-local_*_data`.

## The scripts

| Script | What it does |
|--------|--------------|
| `up.sh [--portal] [--no-build] [--no-wait]` | checks the ports, snapshots the sources, builds, **applies the ClickHouse migrations** (including 0008, the table for raw text), starts, waits until everything is healthy |
| `status.sh [--quiet]` | one line per service (container health plus its HTTP `/health`); non-zero exit when anything is down |
| `seed.sh` | ~40 commands through `POST /v1/commands` (exactly what the web app sends): see below |
| `verify.sh [--quick] [--trace ID]` | the automated checks; `--quick` skips the slow ones; `--trace` prints one trace's spans |
| `sql.sh "SELECT ..."` | run SQL in ClickHouse and print a table |
| `tamper-demo.sh` | the hash-chain tamper demonstration in a throwaway database |
| `down.sh` | stop and remove the containers; volumes are kept |
| `reset.sh [--yes] [--env] [--images]` | stop and delete the volumes and snapshots; `--env` also deletes `local/.env`; `--images` the built images |

`seed.sh` signs in through the Hub's development login (`POST /dev/login`, only registered when the Hub does not run in production), as a fresh user
`seed-<timestamp>@proba.local`, then runs three goal journeys (approve the plan and an action, decline an action, reject the plan), messages, an explanation,
pause / resume / **kill**, and the unhappy paths: a foreign thread, an invalid payload, a duplicate `clientMsgId`, an SSE connect and disconnect, a call without a token
and a second session that signs out. It also sends messages with **raw text**, one of them with a password that gets masked (see "Raw text of events"). It prints a table of the audit actions it produced and of the raw texts stored, and writes the traceIds to `local/.state/seed-traces.tsv`.

## What to look at

* **Services**: `./status.sh`.
* **A trace**: `./verify.sh --trace <traceId>` (take one from `local/.state/seed-traces.tsv`). Or in the API:
  `set -a; . local/.env; set +a; curl -s -H "authorization: Bearer $AUDIT_API_LOCAL_TOKEN" http://localhost:3400/v1/traces/<traceId> | jq`.
* **Everything the Hub audited**: `./sql.sh "SELECT toString(category) c, action, count() n FROM audit_events WHERE service='hub' GROUP BY c, action ORDER BY c, action"`.
* **Metrics**: `./sql.sh "SELECT platform, account_id, timezone, bucket_date, clicks, spend, currency FROM metric_rollups_daily FINAL ORDER BY bucket_date DESC LIMIT 12"`.
* **Logs**: `docker compose -p proba-local --env-file .env -f docker-compose.yml logs -f hub audit-consumer metrics-ingester` (from `local/`).

## Expectation checklist: each design promise and how to see it

`./verify.sh` automates the ones marked **auto**. Each PASS line names what it proved.

| # | Design promise | How to observe | |
|---|----------------|----------------|--|
| 1 | **One traceId end to end.** The root trace id is the web command's `clientMsgId`; every span has a parent pointer. | `verify.sh` step 2 posts `create_goal`, then asserts one root `command.received`, no orphan parents, one service, the `X-Trace-Id` header equal to the `clientMsgId`, and the same tree through `GET /v1/traces/{id}` on the audit API (step 3). By hand: `./verify.sh --trace <id>`. | auto |
| 2 | **Specific action names, never the generic or alias ones** (protocol 0.3.1 catalog). | step 5 reads `AUDIT_ACTION_INFO` from the Hub image and checks stored actions and their categories. The Hub line passes. See "Known results" for the audit API. | auto |
| 3 | **Append-only audit.** Single writer (the consumer), the API is read-only, rows are never updated by the services. | There is no write route in the audit API (`POST` answers 404), the consumer is the only writer. **Caveat**: the ClickHouse user can `ALTER ... UPDATE/DELETE` (see "Known results"), so append-only is by construction and by detection (promise 4), not enforced by database privileges. | by hand |
| 4 | **Hash chain with tamper detection.** Each event carries `prev_hash` and `hash` per workspace. | step 4 runs proba-audit's own `verifyChain` on the live chain, and `GET /v1/chain/verify` (admin) in step 3. `./tamper-demo.sh` (also step 9) copies 300 events into the throwaway database `proba_audit_tamper`, shows an intact verification, edits one event (-> `hash_mismatch`), deletes one (-> `broken_link`), then drops the database. The real chain is never touched. | auto |
| 5 | **No sensitive data in the trail.** Message text, emails and tokens are never in the audit events (only a digest of the raw text is, so the chain can cover it). | step 6 searches every stored text field of `audit_events` for email shapes, bearer tokens, JWTs, the canary and password text `seed.sh` sent and this run's session token. | auto |
| 5b | **Raw text is separate, masked, admin-only and covered by the chain** (protocol 0.3.3; on locally by default). | step 12: a message with an email and a password goes through the Hub; the text is in `audit_event_content` with the password masked and the email kept; an admin reads it, a viewer gets 403 and never sees text or digest; the digest recomputed here equals the one in the chain; the content reads are audited; the chain verifies. See "Raw text of events". | auto |
| 6 | **Nothing is lost.** At-least-once delivery with idempotent storage; failures go to a dead-letter stream. | step 7: the DLQ and the quarantine table are empty. step 8 stops the consumer, sends commands, shows 0 stored, restarts it, and counts the same number stored exactly once with an intact chain. | auto |
| 7 | **Metrics restatements.** Ad platforms revise numbers after the fact; the newest revision wins and totals follow. | step 10 takes the rollup totals of two closed hours, waits for the stub to restate them (every minute locally), and asserts the totals changed and equal the sum of the latest observation revisions. By hand: `./sql.sh "SELECT revision, count() FROM metric_observations GROUP BY revision ORDER BY revision LIMIT 10"` and `metrics.restated` events. | auto |
| 8 | **Days are per-account timezone days.** A daily bucket is the account's local day, DST included. | step 10: three accounts per platform in London, New York and Sydney; `bucket_date = toDate(bucket_start, timezone)`; a Sydney day starts at 13:00 UTC (11:00 offset), New York at 04:00, London at 23:00 UTC in British summer time and 00:00 after the clocks change. Money stays per currency (GBP, USD, AUD, never added up). | auto |
| 9 | **Swap a connector by configuration.** | The ingester runs `PLATFORM_CONNECTORS=meta:stub,google:stub` with `ALLOW_STUB_CONNECTOR=true` (the stub is refused unless allowed). Step 11 starts a throwaway ingester with `meta:not-a-library` and shows it refuses to start and lists the available adapters. A real connector later is a new adapter and a changed value here. | auto |
| 10 | **Swap an interface by configuration.** | Step 11 starts a throwaway ingester with `EVENT_BUS=memory AUDIT_STORE=memory METRICS_STORE=memory CHECKPOINT_STORE=memory QUARANTINE_STORE=memory`: same code, in-memory adapters. To run the real services that way, set the variables in `x-audit-env` in `docker-compose.yml`. | auto |
| 11 | **Read API enforces who sees what.** Workspace comes from configuration, roles are viewer and admin, reads are audited. | step 3: no token is 401, a `workspaceId` parameter is 400, the local token is admin of `seedbed`, and the API's own reads appear as `audit.*` / `analytics.*` events. | auto |
| 12 | **Hub safety paths are audited.** Denials, kill switch, sign-out. | `seed.sh` then `./sql.sh "SELECT action, outcome, count() FROM audit_events WHERE service='hub' AND (outcome != 'success' OR action LIKE 'control.%' OR action LIKE 'auth.%') GROUP BY action, outcome"`. | by hand |

### Known results

`verify.sh` reports these honestly; they are findings about the code under test, not about the local setup:

* **Step 5 "other services store generic/alias actions"**: earlier audit-api builds wrote `data_access.read` (a *generic* catalog name). Since protocol 0.3.2 the catalog has
  `audit.searched`, `audit.event_viewed`, `audit.trace_viewed`, `audit.integrity_checked`, `analytics.queried`, `analytics.compared`, and audit-api uses them. If this step still
  fails, the audit images were built from a version older than that change: rebuild them (`PROBA_REF` / `AUDIT_SRC`) and `reset.sh`, since old events stay in ClickHouse.
* **ClickHouse privileges**: the `proba` user created by the images can `ALTER TABLE audit_events UPDATE/DELETE` (the tamper demo uses exactly that on a copy). In production the
  consumer's user should have `INSERT` and `SELECT` only, and the API's `SELECT` only.

## Signing in

* **Scripts (`seed.sh`, `verify.sh`)** need no Firebase: they use the Hub's development login. If you set `DEV_LOGIN_ENABLED=false` in `local/.env`, put a Hub session token in `HUB_SESSION_TOKEN`
  (the token the Hub returns from `POST /v1/auth/session` after a Firebase sign-in; it is in the web app's network tab and local storage). Never commit it.
* **Audit API**: the default is the `static` token verifier (local automated use only, refused in production): `Authorization: Bearer $AUDIT_API_LOCAL_TOKEN`, an admin
  `local-admin@proba.local`; `AUDIT_API_LOCAL_VIEWER_TOKEN` is a second static identity, a viewer `local-viewer@proba.local`, so scripts can prove what viewers do not get. To use real Firebase ID tokens set `AUDIT_API_TOKEN_VERIFIER=firebase`, `FIREBASE_PROJECT_ID` and `AUDIT_API_ADMIN_EMAILS` / `AUDIT_API_ALLOWED_EMAILS`; the audit-api checks
  in `verify.sh` are then skipped because they cannot get a token by themselves.
* **The web app with your real Firebase project**: copy the public web config (Firebase console > Project settings > Your apps) into `local/.env` as `FIREBASE_PROJECT_ID`, `FIREBASE_API_KEY`, `FIREBASE_AUTH_DOMAIN`,
  `FIREBASE_APP_ID`, optionally `AUTH_ALLOWED_EMAIL_DOMAINS=yourdomain.com`, then `./up.sh` again (the web container reads them at start; the Hub verifies tokens against the same project).
  In the Firebase console, add `localhost` under Authentication > Settings > Authorized domains. These are public identifiers, but keep them out of git anyway.
  Then open http://localhost:5180, sign in, and send a goal; its trace appears in ClickHouse within seconds: `./sql.sh "SELECT service, action FROM audit_events WHERE user_id != '' ORDER BY occurred_at DESC LIMIT 20"`.

## Portal profile

`./up.sh --portal` also builds and starts **Proba Insights** (`proba-portal`: Audit Explorer, Trace View, Integrity, Analytics) and serves it on http://localhost:3410
(`PORTAL_HOST_PORT`). It is a read-only client of the audit API, which already allows its origin through `AUDIT_API_CORS_ORIGINS`.

The portal signs in with **Firebase** and sends the ID token to the audit API, so it needs the same two things as the "web app with your real Firebase project" above:

1. The Firebase web config in `local/.env` (`FIREBASE_API_KEY`, `FIREBASE_AUTH_DOMAIN`, `FIREBASE_PROJECT_ID`, `FIREBASE_APP_ID`, shared with the web app). Without them the portal opens
   and says that sign-in has not been set up. Add `localhost` to the Firebase authorized domains.
2. The audit API on Firebase tokens: `AUDIT_API_TOKEN_VERIFIER=firebase` and your email in `AUDIT_API_ADMIN_EMAILS` (administrator: sees Integrity) or `AUDIT_API_ALLOWED_EMAILS`
   (read access). The static local token is for scripts only and cannot sign anyone in to a browser. `up.sh --portal` warns if either is missing.

`PORTAL_MEMORY_URL` (optional) turns on the Memory entry in the portal's navigation; leave it empty for no entry. `PORTAL_LOG_LEVEL` sets its browser log level.
After `./seed.sh` there is audit history and analytics data to look at. `./status.sh` reports the portal's health when its container exists.

By default the portal is built from a snapshot of `origin/main` of your `proba-portal` checkout. To try an unmerged branch use `PROBA_SRC=worktree ./up.sh --portal`, or `PROBA_REF=origin/<branch> ./up.sh --portal` (repositories without that branch fall back to `main`).
The portal's **Raw text** panel (administrators only) is described in "Raw text of events" below, with the step-by-step sign-in.

## Raw text of events

Since protocol 0.3.3 an audit event can carry the raw text of what was said: the person's message, the Hub's reply, an explanation, a clarifying question (`content`). It is
**admin-only**, **secrets are masked** by the Hub before it leaves (passwords, tokens, API keys, card numbers become `[REDACTED...]` and are counted; names, emails and plans stay), and it
is **kept apart from the hash chain**: `audit_events` holds only `content_digest` (SHA-256 of the text), the text is in its own ClickHouse table `audit_event_content` (migration 0008).
Changing the text no longer matches the digest; deleting it (retention) leaves the chain valid.

Locally it is **on by default**: `local/.env` gets `AUDIT_CONTENT_ENABLED=true` and `AUDIT_CONTENT_STORE=clickhouse` (`up.sh` adds them to an existing `local/.env` too and never changes a value that is
there). One flag drives the Hub (writes the text), the audit-consumer (stores it) and the audit API (serves it to administrators). Set it to `false` to see production's default: the text is never
stored, events say nothing about it and the portal shows no panel. `up.sh` runs the ClickHouse migrations itself before the consumer starts, so a `local/.env` and volumes from before 0008 are upgraded by `./up.sh`.

### How to see and test it

1. **Start and seed** (from `local/`):
   ```bash
   ./up.sh            # migrations incl. 0008 run first; raw text is on
   ./seed.sh          # ends with a table of the texts stored: user_message, brain_reply, brain_clarification (and how many secrets were masked)
   ```
2. **Run the automated checks**: `./verify.sh` (or `--quick`). Step 12 is the raw-text step; every line says what it proved (stored apart, masked, admin gets the text, digest recomputed outside the API, viewer gets nothing, reads audited, chain intact).
3. **Look at it in the database** (what is stored, and what is not):
   ```bash
   ./sql.sh "SELECT kind, count() texts, sum(redactions) masked, max(original_length) longest FROM audit_event_content FINAL GROUP BY kind"
   ./sql.sh "SELECT event_id, kind, redactions, text FROM audit_event_content FINAL WHERE redactions > 0"        # the password is [REDACTED]
   ./sql.sh "SELECT action, content_digest FROM audit_events WHERE content_digest IS NOT NULL LIMIT 5"           # the chain holds only the digest
   ```
4. **Look at it through the API, as an admin and as a viewer** (the two static tokens exist for scripts only; they are refused in production):
   ```bash
   set -a; . .env; set +a
   EV=$(. ./lib.sh; load_env; ch "SELECT toString(event_id) FROM audit_events WHERE action='thread.message_received' AND content_digest IS NOT NULL ORDER BY occurred_at DESC LIMIT 1")   # plain id, no table
   curl -s -H "authorization: Bearer $AUDIT_API_LOCAL_TOKEN"        http://localhost:3400/v1/events/$EV/content | jq    # admin: text, kind, redactions, contentDigest, verified
   curl -s -H "authorization: Bearer $AUDIT_API_LOCAL_TOKEN"        http://localhost:3400/v1/events/$EV | jq            # admin: hasContent + contentDigest, never the text
   curl -s -H "authorization: Bearer $AUDIT_API_LOCAL_VIEWER_TOKEN" http://localhost:3400/v1/events/$EV | jq            # viewer: hasContent only
   curl -s -H "authorization: Bearer $AUDIT_API_LOCAL_VIEWER_TOKEN" http://localhost:3400/v1/events/$EV/content | jq     # viewer: 403
   ./sql.sh "SELECT action, details FROM audit_events WHERE service='audit-api' AND position(details,'contentIncluded') > 0 ORDER BY occurred_at DESC LIMIT 3"   # each text read is itself audited, without the text
   ```
5. **See it in the portal** (Proba Insights): needs a real Firebase sign-in, see below.

### Sign in to the portal locally (the Firebase-config route)

The portal accepts **only Firebase sign-in**. There is no access key, token field or development login in it, and none is added for local use: you sign in with a real account of a Firebase project, the
audit API verifies that account's ID token itself and decides the role from `local/.env`. (The static tokens above belong to the audit API's script access and cannot sign anyone in to the portal.)

1. **Firebase project.** Use the one of `proba-web` / `proba-hub`, or any project of yours. In the Firebase console: *Authentication > Sign-in method*: enable *Email/Password* and/or *Google*; *Authentication > Users*: add the accounts
   (one for the administrator, optionally a second for a viewer); *Authentication > Settings > Authorized domains*: make sure `localhost` is listed.
   The audit API only accepts a **verified** email: a Google account is verified; an Email/Password account becomes verified when it opens the verification email (*Users > ⋮ > Send verification email*).
2. **Firebase web config into `local/.env`** (public identifiers from *Project settings > Your apps > Web app*; keep them out of git): `FIREBASE_API_KEY`, `FIREBASE_AUTH_DOMAIN`, `FIREBASE_PROJECT_ID`, `FIREBASE_APP_ID`.
3. **Make the audit API verify those tokens and name the people**, in `local/.env`:
   ```
   AUDIT_API_TOKEN_VERIFIER=firebase
   AUDIT_API_ADMIN_EMAILS=you@yourcompany.com          # administrator: sees Integrity and the Raw text panel
   AUDIT_API_ALLOWED_EMAILS=colleague@yourcompany.com   # viewer: no Integrity, no raw text (an empty list allows nobody)
   ```
   While the verifier is `firebase`, the static tokens do not work, so `verify.sh` skips the audit-API checks (including step 12): switch back to `static` to run them.
4. **Start with the portal**: `./up.sh --portal` (re-run it after editing `local/.env`; containers read it at start). The portal is built from a snapshot of `origin/main` of your `proba-portal` checkout; until the
   Raw text panel is merged there, build it from its branch: `PROBA_REF=origin/feat/content-panel ./up.sh --portal` (the other checkouts fall back to their `main`).
5. `./seed.sh` if you have not yet (data from before the flag was on has no text), then open **http://localhost:3410** and sign in as the administrator.
6. **What you should see**
   * *Traces*: pick a trace from the seed (for example the one printed for "send_message with a password (masked)"; `local/.state/seed-traces.tsv` lists them, and `http://localhost:3410/#/traces/<traceId>` opens one).
     Below the step list there is a **Raw text** panel: each text with its kind ("Message from a person", "Reply", "Clarifying question"), the text, its length, **Secrets masked: 1** where the password was, a green "Matches the audit trail record", and **Copy text**.
   * Click **Open step** (or a step in the list): the event record shows the same text under **Raw text**, above the raw JSON.
   * Sign out and sign in as the viewer: the same trace has **no** Raw text panel and no heading for it; the address bar and the browser console never contain the text.
   * As the administrator, `./sql.sh "SELECT action, details FROM audit_events WHERE service='audit-api' AND position(details,'contentIncluded') > 0 ORDER BY occurred_at DESC LIMIT 3"` shows that opening the panel was itself audited.
   * With `AUDIT_CONTENT_ENABLED=false` in `local/.env` and `./up.sh --portal` again, the panel is gone for everyone (the API answers `content_disabled`; the portal shows nothing).

## Troubleshooting

* **"port ... is already in use"**: `up.sh` lists which port and which service. Change it in `local/.env` (for example `HUB_HOST_PORT=3301`) and run `./up.sh` again. Ports owned by this stack's own containers are not a clash.
* **A service is `unhealthy`**: `docker compose -p proba-local --env-file .env -f docker-compose.yml logs <service>` from `local/`. The audit services wait for ClickHouse and Redis, the Hub for Postgres.
* **Build is slow or fails**: a cold first build downloads base images and installs dependencies (several minutes; with a warm Docker cache it took about 30 s). Re-run `./up.sh`; the layers are cached. `./reset.sh --images` forces a rebuild.
* **You want newer code from a sibling repo**: `git fetch` there (main is snapshotted from `origin/main`), then `./up.sh` (it rebuilds when the snapshot's commit changed).
* **No Raw text panel / `hasContent` never appears**: check that `AUDIT_CONTENT_ENABLED=true` in `local/.env` (Hub, consumer and API share it), that the Hub, consumer and API were restarted after changing it (`./up.sh`), and that the 0008 migration ran (`./sql.sh "SHOW TABLES"` lists `audit_event_content`; `./up.sh` runs it). Events recorded while the flag was off have no text.
* **The portal says "You don't have access"**: your Firebase email must be verified and listed in `AUDIT_API_ADMIN_EMAILS` or `AUDIT_API_ALLOWED_EMAILS`, and `AUDIT_API_TOKEN_VERIFIER=firebase`, `FIREBASE_PROJECT_ID` must match the project you signed in to.
* **Start from nothing**: `./reset.sh --yes` (add `--env` to regenerate the secrets). Existing sessions and audit history are lost with the volumes.
* **`verify.sh` step 10 fails right after the first start**: the ingester needs a minute to fetch the first observations and for the rollup to run. Wait and re-run.
* **Docker memory**: if ClickHouse is killed (exit 137), give Docker more memory.
* **The web app's container shows unhealthy upstream**: `proba-web`'s own healthcheck uses `localhost`, which resolves to IPv6 in the Alpine image while nginx listens on IPv4. `local/docker-compose.yml` overrides it with `127.0.0.1`.
* **Other `proba-audit-*` containers** (a proba-audit development stack) are never touched by these scripts; they only see `proba-local-*`.
