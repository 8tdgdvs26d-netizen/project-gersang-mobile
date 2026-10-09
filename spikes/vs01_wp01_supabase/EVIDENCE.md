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
| Live stress runner (`live_stress.mjs`) | READY, not run live | Against a local mock built on the authority model: all 8 checks PASS (including `--with-expiry` and cross-account); with a deliberately broken mock that drops receipts it FAILs the duplicate and retry checks; without environment it exits 2 (BLOCKED) |
| Godot live probe (`live_probe.gd`) | READY, not run live | Godot 4.7.2 headless: parses and runs; exits 2 (BLOCKED) without environment and refuses a non-HTTPS URL |
| Godot live probe init-timing fix | PASS (offline) | Mac live run on `68d1470` FAILED: `HTTPRequest.request` returned `ERR_UNCONFIGURED` because `SceneTree._initialize` runs before the root enters the tree. Fix: the probe awaits one frame; the client returns `ERR_NOT_IN_TREE` instead of an opaque failure; failed probe steps now print their error code. Reproduced locally against an unreachable HTTPS address: before the fix `ERR_UNCONFIGURED`, after the fix the request reaches the network (`ERR_NETWORK`) |
| Godot spike client regression (`tests/verify_vs01_spike_client.gd`) | PASS | 9/9 checks on the fix; the same test on `68d1470` fails 2/9. No credentials or Supabase access |
| Live-runner regression | PASS | `node --test test/vs01_supabase_spike.test.mjs`: 8 passed; both live runners exit 2 without environment and print no secret |
| Deployed service_role SELECT fix | CONFIRMED | Deployed `spike_player_progress` grants SELECT to service_role, matching this branch |

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
| Live smoke (`live_smoke.mjs`) | BLOCKED (cloud session) | Reported 4/4 PASS in the Mac session handoff; no run output is recorded here. 2026-10-09: no disposable-project credentials in the cloud session, runner exited 2 |
| Live stress (`live_stress.mjs --with-expiry`) | BLOCKED | Same: no credentials in the cloud session. Runner is ready |
| Godot live probe (`live_probe.gd`) | **PASS on `7b51b25` (Mac, live)** | 2026-10-09, Charlie's Mac, clean acceptance checkout `myrial-wp01-acceptance` detached at `7b51b25`, Godot 4.7.2 macOS headless, disposable project `myrial-vs01-spike`: `GODOT_LIVE_PROBE PASS {"auth":"PASS","get_state":"PASS","idempotency":"PASS","revision":56,"session":"PASS"}`. The earlier run on `68d1470` failed with `ERR_UNCONFIGURED` (init timing, fixed above) |
| Physical iPhone/iPad network and resume test | NOT RUN | Requires live backend plus device build |
| PlayFab / Firebase comparison | NOT RUN | |
| Player experience acceptance | NOT RUN | A technical test pass is not a player-experience pass |

The provider decision therefore remains open.
