# VS-01 WP01 Technical Spike Evidence

Evidence dates: 2026-10-08 UTC (scaffold), 2026-10-09 UTC (service_role SELECT fix, deployed-permission check, live runners)

Verified base: `main` at `3774aefacfb92736c63034c51565aa4e675d3aeb`

Working branch: `claude/vs01-wp01-backend-spike`

## Scope

This is an isolated feasibility spike for account-bound online save authority. It does not connect
to the production game flow, change gameplay, modify Save v14, migrate a Development Save, select a
final provider, or establish a production backend architecture.

## Evidence obtained

| Check | Result | Evidence |
| --- | --- | --- |
| Existing repository baseline | PASS | `npm test`: 508 passed, 0 failed before spike changes |
| Offline authority model | PASS | `node --test test/vs01_supabase_spike.test.mjs`: 7 passed, 0 failed |
| Duplicate command delivery | PASS (model) | Same idempotency key delivered 100 times; one revision and one economic mutation |
| Lost-response retry | PASS (model) | Retry returns the stored receipt without a second mutation |
| Atomic money and inventory mutation | PASS (model) | Invalid command changes neither balance nor inventory |
| One active session | PASS (model) | Superseded session is rejected; the new lease remains authoritative |
| Cross-account access denial | PASS (model) | A second account cannot read or command the first account's state |
| Rapid unique commands | PASS (model) | 50 unique commands produce 50 revisions and the expected balance |
| SQL and client contract scan | PASS | RLS, revoked client writes, service-only functions and non-secret Godot env inputs are asserted |
| service_role SELECT regression | PASS | New assertion fails on the unpatched migration (6/7) and passes with the fix (7/7); it also forbids service_role writes on progress |
| Full JavaScript regression | PASS | `npm test`: 515 passed, 0 failed with the fix applied |
| Godot local automated tests (existing suite) | PASS | Godot 4.7.2 headless, clean workspace and isolated `user://`, on `e3447d8`: 65/65 scripts passed. The fix changes no Godot file |
| Local PostgreSQL 16 permission probe | PASS (local, not Supabase) | Unpatched: service_role SELECT on progress denied. Patched: allowed; every other role/privilege result unchanged; players still read only their own row |
| Deployed Supabase permission check (read-only SQL v3, run by Charlie) | PASS with known platform difference | 39 rows: 29 OK, 6 INFO (all owners `postgres`), 4 MISMATCH (service_role extra privileges, below). Function bodies match the repository (md5), EXECUTE only for service_role, exact `search_path`, RLS on all four tables, single own-row SELECT policy, no PUBLIC grants, no unexpected objects, policies or grantees |
| Live stress runner (`live_stress.mjs`) offline validation | PASS (mock, not Supabase) | Against a local mock built on the authority model: all 8 checks PASS (including `--with-expiry` and cross-account); with a deliberately broken mock that drops receipts it FAILs the duplicate and retry checks; without environment it exits 2 (BLOCKED) |
| Godot live probe (`live_probe.gd`) offline validation | PASS (offline) | Godot 4.7.2 headless: parses and runs; exits 2 (BLOCKED) without environment and refuses a non-HTTPS URL |
| Godot live probe init-timing fix | PASS (offline) | Mac live run on `68d1470` FAILED: `HTTPRequest.request` returned `ERR_UNCONFIGURED` because `SceneTree._initialize` runs before the root enters the tree. Fix: the probe awaits one frame; the client returns `ERR_NOT_IN_TREE` instead of an opaque failure; failed probe steps now print their error code. Reproduced locally against an unreachable HTTPS address: before the fix `ERR_UNCONFIGURED`, after the fix the request reaches the network (`ERR_NETWORK`) |
| Godot spike client regression (`tests/verify_vs01_spike_client.gd`) | PASS | 9/9 checks on the fix; the same test on `68d1470` fails 2/9. No credentials or Supabase access |
| Live-runner regression | PASS | `node --test test/vs01_supabase_spike.test.mjs`: 8 passed; both live runners exit 2 without environment and print no secret |
| Deployed service_role SELECT fix | CONFIRMED | Deployed `spike_player_progress` grants SELECT to service_role, matching this branch |
| Live smoke (`live_smoke.mjs`) | **PASS 4/4 — Charlie's Mac live run (reported)** | auth, session, idempotency and direct-write denial PASS; revision 1. See the provenance note below |
| Live stress run 1 — `stress-1791531259707` (`--with-expiry`, one account) | **Overall PASS: 7 PASS, 1 NOT RUN — Charlie's Mac live run (reported)** | Started 2026-10-09T07:34:19Z (decoded from the run ID). parallel duplicate x20 PASS (20/20 accepted; the runner's PASS requires exactly one mutation); parallel unique x20 PASS (20/20); sequential burst x30 PASS (0 errors, p95 1529 ms); lost-response retry PASS; rejected-command atomic PASS; session takeover refused PASS; **lease-expiry takeover PASS**; cross-account isolation NOT RUN (no second test account) |
| Live stress run 2 — `stress-1791532990918` (second account set, without `--with-expiry`) | **Overall PASS: 7 PASS, 1 NOT RUN — Charlie's Mac live run (reported)** | Started 2026-10-09T08:03:10Z (decoded from the run ID). **cross-account isolation PASS**: `foreignRowsVisible=0` (account B's REST read of account A's progress row returned no rows), `foreignCommand=ERR_SESSION_STALE` (account B's command against A's session was refused); lease-expiry takeover NOT RUN in this run (covered by run 1). Per-check figures for the other six checks were not provided |
| Live stress — combined coverage | **All 8 checks PASS across the two runs** | Lease-expiry takeover from run 1, cross-account isolation from run 2; the other six checks passed in both runs |
| Stress coverage acceptance (GPT, 2026-10-09) | Conditionally accepted for the WP01 disposable spike only | **The formal VS-01 Full Stress has not passed.** Long-running (soak), multi-account concurrency, reconnect and mobile lifecycle (background/foreground, mobile networks) still need verification in later VS-01 work |
| Godot live probe (`live_probe.gd`) | **PASS on `7b51b25` (Mac, live)** | 2026-10-09, Charlie's Mac, clean acceptance checkout `myrial-wp01-acceptance` detached at `7b51b25`, Godot 4.7.2 macOS headless, disposable project `myrial-vs01-spike`: `GODOT_LIVE_PROBE PASS {"auth":"PASS","get_state":"PASS","idempotency":"PASS","revision":56,"session":"PASS"}`. The earlier run on `68d1470` failed with `ERR_UNCONFIGURED` (init timing, fixed above) |

**Evidence boundary of the cross-account check:** it verified exactly two paths. Account B's REST read of
account A's progress row returned no rows (`foreignRowsVisible=0`), and account B's command against
account A's session was refused (`foreignCommand=ERR_SESSION_STALE`). It does **not** show that every
cross-account attack path is closed; for example forged RPC parameters, other Edge Function actions
and tampered JWTs were not specifically tested.

**Provenance of the live smoke and live stress results:** these are Charlie's real runs on the Mac
against the disposable project `myrial-vs01-spike`, as summarised by Charlie on 2026-10-09; the two
stress runs are identified by their run IDs (`stress-<start time in ms>`). The complete raw output
logs were not provided, and the commit of each run was not stated. The runners are byte-identical
from `68d1470` through `9652cfa` (`git diff` is empty), so every commit Charlie could have used ran
the same smoke and stress code; by start time, stress run 1 predates the `7b51b25` commit and run 2
follows `9652cfa`. Claude did not re-run or independently verify these results; the cloud session
has no credentials. The Godot live probe row records the raw PASS line Charlie pasted.

## The service_role SELECT fix

The Edge Function's `get_state` reads `spike_player_progress` through the service-role client. On this
Supabase project, new tables in `public` do not grant SELECT/INSERT/UPDATE/DELETE to `service_role`
by default, so that read was denied. The migration now grants only `SELECT` on that one table to
`service_role`. Writes still go through the two `SECURITY DEFINER` RPCs. No player (`anon`,
`authenticated`) privilege changed.

## Known platform difference / known risk (accepted by Charlie for the disposable spike)

Read-only catalog checks on the Supabase project show:

- `postgres` default privileges for new tables in `public` grant `MAINTAIN, REFERENCES, TRIGGER,
  TRUNCATE` to `service_role` (and to `anon`/`authenticated`, which the migration revokes);
- each spike table carries exactly that direct grant for `service_role`, plus `SELECT` on progress;
- `service_role` is not a member of any other role (no inheritance path);
- `supabase_admin` has a separate, broader set of default privileges.

Therefore `service_role` holds `MAINTAIN/TRUNCATE/REFERENCES/TRIGGER` on the four spike tables. These
are not reachable through the Data API or the Edge Function (no TRUNCATE/DDL endpoint), and no player
role is affected. Someone running SQL as `service_role` could, for example, truncate receipts or the
audit log, but that party already holds a credential that bypasses RLS. Risk for this disposable
spike: low. The spike keeps these privileges; no REVOKE was applied.

The v3 check did not test `MAINTAIN` (a PostgreSQL 17 privilege); its presence comes from the
default-privilege query above.

**Production requirement:** the formal backend schema must re-review least privilege table by table
(including explicit revokes from `service_role` and handling of `supabase_admin` defaults). It must not
inherit the spike's grants.

## Evidence not yet obtained

| Check | Status | Note |
| --- | --- | --- |
| Complete raw logs of the Mac live smoke and live stress runs | NOT PROVIDED | Results above are Charlie's summary; the commit of each run was not stated |
| Rate limiting (Canonical A14) | NOT VERIFIED | The spike implements no rate limiting and platform-level limits were not tested; the overall A14 security requirement must not be claimed as met |
| Lease expiry and cross-account isolation in a single run | NOT RUN | Each passed in a separate run (see the combined-coverage row) |
| Physical iPhone/iPad network and resume test | DEFERRED (Charlie-approved 2026-10-09) | Not waived: acceptance stays owed by the later VS-01 work package that wires the game to the backend, at the latest before VS-14. See `BLUEPRINT.md` §10 |
| PlayFab / Firebase hands-on spike | NOT RUN | Desk comparison only: `PROVIDER_COMPARISON.md` |
| Player experience acceptance | DEFERRED (Charlie-approved 2026-10-09) | Not waived; same responsibility as above. A technical test pass is not a player-experience pass |

The provider decision therefore remains open.
