# VS-01 WP01 — Test Evidence and Rollback Plan

- Repository: `8tdgdvs26d-netizen/project-gersang-mobile`
- Branch: `claude/vs01-wp01-nakama` (not rebased, no force push)
- Base `main`: `3774aefacfb92736c63034c51565aa4e675d3aeb`
- **Code under test:** `4c80863ab72a3f0e8ae1cb2cfeb6f74d5cd062f3`. This is
  session policy A, on top of review fix `bb3e556` and A14 fix `fc87435`. The
  commit after it adds only this document and README text.
- Mac: Docker Desktop 29.8.2, Godot 4.7.2.stable, Node 24.21.0, Nakama 3.25.0,
  PostgreSQL 16 (local Docker only). Recorded 2026-10-10.

## Status labels

| Label | State |
|---|---|
| Designed | Approved Blueprint + D1–D6 (Charlie, 2026-10-10) |
| Implemented | Yes, on this branch (not merged) |
| Automated Tests Passed | Yes, local (below) |
| CI Passed | See the PR checks. `test` = Node / npm CI. `nakama-server-unit-tests` = Node server unit tests. **No Godot CI exists.** |
| GPT Accepted / Mac Accepted / iPhone Accepted / iPad Accepted / Playtested / Player Value Verified | **PENDING** |
| Sign in with Apple on device | **PENDING** (needs native plugin + Apple Developer setup; only rejection paths tested) |

## Results on `4c80863`

| Suite | Command | Result |
|---|---|---|
| Godot full normal regression, **baseline** `main` 3774aef (isolated `user://`) | `HOME=$(mktemp -d) godot/tests/run_tests.sh` | 65 / 65 PASS |
| Godot full normal regression, **branch** (isolated `user://`) | `nakama/scripts/run_godot_regression_isolated.sh` | 66 / 66 PASS (65 existing + `verify_vs01_wp01_online_contract`, 134 checks), 0 script errors |
| Node / npm CI suite (existing) | `npm test` (repo root) | 508 / 508 PASS |
| Nakama server unit tests (clean `npm ci`) | `cd nakama && npm ci && npm test` | 43 / 43 PASS |
| Live stress, fault injection, DB load, multi-node, restart | `nakama/scripts/run_live_tests.sh` | 14 / 14 PASS |
| Live Godot SDK probe (Nakama Godot SDK v3.4.0) | same script | 47 / 47 checks PASS |

The A14 numbers below were first recorded on `fc87435`. They were re-run on
`bb3e556` and on `4c80863` with the same results: 30 / 15, two nodes 30 / 15,
bursts 30, 0, 0, 0. The fault-injection test was re-run on `4c80863`: 503 in
20–23 ms, 1 attempt each.

## Session policy A (`4c80863`)

Approved by Charlie on 2026-10-10:
1. One active gameplay session per character.
2. After a takeover, the old session can neither act on the character nor read
   its latest progress.
3. The old device is told.
4. The player may take the character back.
5. Switching devices never kills the character, loses confirmed progress or
   doubles a reward.

| Rule | Implementation | Evidence |
|---|---|---|
| 1, 2 act | Trade checks the session first (`bb3e556`). | Unit + live: stale writes and stale receipt replays refused (409). |
| 2 read | `vs01_progress_get` takes `{gameplay_session_id}` and refuses a superseded one. | Unit: old session refused; after taking back, the other device is refused; malformed / other-account ids refused. Live: 8 racing takeovers leave exactly one session that can write AND read. Godot probe: server refuses the old device's read. |
| 2 read (bypass found while testing) | Progress and receipts were `permissionRead: 1`, so any token of the account could read them through Nakama's generic storage API, bypassing the session check. They are now server-only (`permissionRead: 0`). | Live: the owner token's generic reads and lists return nothing. Godot probe: the old device's SDK `read_storage_objects` returns nothing. Unit: permissions asserted. |
| 2 race | Trade reads progress and the receipt in ONE `storageRead`. Nakama v3.25.0 serves this with a single SELECT (`StorageReadObjects`), one snapshot under READ COMMITTED. | Unit: exactly one combined read per trade (fails on the previous code). This closes former known risk 11. |
| 3 | Godot client raises `gameplay_session_superseded` once, sets `is_gameplay_session_superseded()`, and refuses reads and actions locally (nothing sent). | Godot offline: 1 signal for many calls; no network call after it is known. Godot probe: signal on the old device. |
| 4 | `vs01_session_begin` takes the character back; the client clears the state. | Godot probe: the old device takes it back, the other device then gets the signal, and the other device takes it back again. |
| 5 | Idempotent keys + pending recovery after taking back. No death logic in WP01. | Unit: 6 orders with a device switch after each, then replays: each applied once, money exact. Godot probe: progress identical across 3 switches; the pending key replays its original receipt after taking back, with no second charge. |

Test strength: run against the previous server code (`d4ea241`), the new unit
tests fail (policy-A read checks; the one-snapshot check).

Not in WP01 (UI scope): the visible prompt itself. The client provides the
signal and state a later UI WP needs.

Unit-suite strength check: deliberately breaking a rule makes at least one test
fail. The rules checked were the spread %, market stock limit, cargo limit,
receipt create-only, session check, receipt-only rejection, and, for the
limiter, the compare-and-swap, window comparison, fail-closed path, monotonic
time and seq bump.

## PR #132 review round 1: findings, reproduction, fix (`bb3e556`)

| # | Finding | Reproduced on `fc9853d` (before the fix) | After `bb3e556` |
|---|---|---|---|
| 1 | `rpcTrade` replayed an existing receipt before the gameplay-session check | **Yes.** After a takeover, the old session sending its old key got `200`, `replayed: true`, the receipt and the current money (9160). | Old session gets `409 gameplay_session_superseded` with no receipt and no progress. The new session retrying the same key still replays once (legitimate recovery kept). |
| 2 | The rate limiter's `storageWrite` treated every exception as a version conflict | **Yes.** A non-conflict database fault (PostgreSQL trigger) was retried 64 times, then reported as `429 rate_limit_contention`. | `503 storage_unavailable` in ~22 ms, 1 write attempt. Version conflicts are still retried. |
| 3 | Same in `multiUpdate` (trade) and in session begin | **Yes.** A trade with a fault on the receipt write was retried 32 times, then reported as `409 conflict_retry_exhausted`. | `503 storage_unavailable` in ~25 ms, 1 attempt, nothing applied. The same key retried after recovery applies exactly once. |
| 3b | Found while reproducing: the Godot client dropped a pending command on ANY server error code, although a storage error can leave the commit outcome unknown | Code review | Only a receipt resolves a pending command. gRPC 2 / 4 / 13 / 14 and refused retries keep it pending. A new command refused before any decision is dropped. |

How conflicts are told apart: Nakama v3.25.0 reports a failed version check,
including a lost create-only race, as `runtime.ErrStorageRejectedVersion`,
text `Storage write rejected - version check failed.`, wrapped by the JS
runtime as `failed to write storage objects: …` or `error running multi
update: …` (sources: `server/core_storage.go`, `server/core_multi.go`,
`server/runtime_javascript_nakama.go`, nakama-common `runtime/runtime.go`).
Only that text is retried. The unit-test storage double throws these exact
texts, and the live fault test proves the split on a real database.

Test strength: the new unit tests fail against the old code (4 failures on
`fc9853d` sources) and pass with the fix. The live fault test uses a
PostgreSQL trigger and an attempt counter (a sequence) on the disposable local
database, and removes them afterwards. A check after the run found 0
triggers, functions, sequences or database settings left behind.

Design note: the open question about reads was decided by Charlie (session
policy A) and is implemented in `4c80863`. See above.

## A14 rate limit: finding, cause, fix, proof

**Finding (GPT review):** the limit was set to 30 per 10 s, but live
45-request bursts let 31–34 through. **Not acceptable as an A14 PASS.**

**Cause:**
1. The counter in Nakama's node-local cache was read, increased and written
   back with no atomic increment, so concurrent requests lost updates.
2. A fixed window allows up to 2x at a boundary.
3. The count was per node.

**Verification before the fix:** read in Nakama v3.25.0
`server/core_storage.go`, `server/core_multi.go` and `server/db.go`.
- A version-checked write is `UPDATE storage ... WHERE ... AND version = $8`.
  The first write is a plain `INSERT` (a unique key rejects a second one).
- Both run in a transaction at PostgreSQL READ COMMITTED (checked live:
  `default_transaction_isolation = read committed`). A concurrent UPDATE waits
  for the row lock and re-checks `WHERE` against the newest row, so exactly
  one of two writers from the same read succeeds: an atomic compare-and-swap.
- `multiUpdate` runs all of its writes in one transaction and rolls back on
  any version error.
- Nakama retries only PostgreSQL serialization errors (40xxx) on its own.
  Version conflicts come back to the module, which retries itself.
- **Caveat:** `version = md5(value)`. A value that returns to an earlier
  content would accept an old version (ABA). The progress object's `revision`
  and the rate log's `seq` grow on every write, so no stored value repeats.

**Fix (`fc87435`, same Nakama + PostgreSQL, no new component):**
- A sliding-window log of accepted request times per user and limiter, in a
  server-only storage object, accepted only through the compare-and-swap above.
- A lost race re-reads and re-checks. When retries run out (64 attempts), the
  request is refused (`rate_limit_contention`, fail closed).
- Time never steps back (`max(now, last)`), so a clock jump can only make the
  window stricter.

**Proof (strict, at most 30 in every continuous 10 s window):**

| Check | Result |
|---|---|
| 45 concurrent requests, one node | 30 accepted, 15 throttled |
| 45 concurrent requests split over **two Nakama nodes** sharing one database | 30 accepted, 15 throttled |
| 4 bursts of 30 within 7.8 s (covers every fixed-window boundary) | 30, 0, 0, 0 accepted |
| After the window passes | accepted again |
| Server restart right after 30 accepted | next 5 all throttled; accepted again after 10 s |
| Unit: window edge at exactly 10 000 ms; 30 just before and 30 just after a boundary; 2 000 randomised requests (every 31st accepted is ≥ 10 s after the 1st) | PASS |
| Unit: competing writer between read and write; exhausted retries; clock step back; tampered or client-made state | PASS (refused or fail closed) |

**Extra database load** (`pg_stat_user_tables`, `storage` table):

| Workload | Per request |
|---|---|
| Accepted trade (sequential) | 1.03 inserts, 1.97 updates, 5.1 index scans. The limiter adds +1 update and +1 read; the first request for an account is an insert. |
| Throttled request | 0 inserts, 0 updates, ~1 index scan |
| 30 concurrent trades on one account | 2.8 inserts (including create-only attempts that lost the race and rolled back), 1.97 updates, ~29 scans. This is retry cost under contention, which one player in normal play does not generate. |

## Other live coverage

- 20 concurrent distinct orders: all applied, ledger exact.
- 20 concurrent identical keys: 1 original + 19 replays, applied once.
- 8 racing session takeovers: exactly one writer.
- 10 accounts in parallel: isolated, each ledger exact.
- 300-command soak with 20 % duplicate retries: one receipt per key, ledger exact.
- Requests aborted client-side: retries resolve exactly once.
- Security:
  - Forged price, money, action or quantity: refused (400).
  - Guest (device / custom) sign-in: refused (403).
  - Another account's data: empty.
  - Client storage writes: refused (403).
  - Combat reward claim: refused (403).
  - No auth: 401.
- Server restart with a command in flight: confirmed state kept, the uncertain
  command applied exactly once after retry, and the session still usable (no
  forced reset or death).
- Godot SDK probe:
  - Two accounts.
  - Server prices.
  - Takeover on a second device: the old session can't write.
  - Network loss: the order stays uncertain, then applies once.
  - App restart: the same key returns the original receipt.
  - Account isolation; forged price and combat reward refused.

"Ledger exact" means the final server money and goods equal a re-computation
from all receipts with the TypeScript rules, receipts chain with no gaps, and
every applied price matches the rules.

## Development Save protection

| | SHA-256 | mtime | size | version |
|---|---|---|---|---|
| Before the A14 runs (`fc87435`) | `59fcf77a88a98b966166485ce4078c036a6ade747db4c07f7a41b635663531f7` | 1790568901 | 2052 | 8 |
| After the A14 runs | `59fcf77a88a98b966166485ce4078c036a6ade747db4c07f7a41b635663531f7` | 1790568901 | 2052 | 8 |
| Before the review-fix runs (`bb3e556`) | `59fcf77a88a98b966166485ce4078c036a6ade747db4c07f7a41b635663531f7` | 1790568901 | 2052 | 8 |
| After the review-fix runs | `59fcf77a88a98b966166485ce4078c036a6ade747db4c07f7a41b635663531f7` | 1790568901 | 2052 | 8 |
| Before the policy-A runs (`4c80863`) | `59fcf77a88a98b966166485ce4078c036a6ade747db4c07f7a41b635663531f7` | 1790568901 | 2052 | 8 |
| After the policy-A runs | `59fcf77a88a98b966166485ce4078c036a6ade747db4c07f7a41b635663531f7` | 1790568901 | 2052 | 8 |

- Every Godot run used an isolated `HOME`, so `user://` was a temporary folder.
- `main` is still `3774aef` and PR #131 is still `a1165aa` (Draft).
- Both stashes are kept. The Nakama spike source and its stopped containers and
  volume are kept.
- No existing tracked file is modified (all 52 files are additions).

## Known risks

1. Sign in with Apple is not device-tested: it needs the iOS native plugin and
   Apple Developer setup (Charlie). PENDING.
2. The rate limiter costs +1 read and +1 update per accepted request, and
   contention on one account multiplies reads. This is acceptable at WP01
   scale but needs a load review before launch.
3. Multi-node proof uses two Nakama OSS processes on one database (Nakama OSS
   does not cluster). The production topology is not chosen yet.
4. Not wired into gameplay or UI. The game still runs offline on Save v14.
5. Pending commands are kept in memory only. Saving them to disk needs an
   approved local-storage decision.
6. Opening the game with the normal user data folder rewrites the v8
   Development Save as v14 at the next save. Use an isolated `user://` for any
   Mac acceptance.
7. The server holds a representative character only (no growth, equipment,
   Mercenaries, warehouse or shared economy).
8. Nakama Godot SDK v3.4.0 (2024) is older than Godot 4.7.2. It works here,
   but carries maintenance risk.
9. Godot `--script` runs print GDScript class leak warnings at exit. This is
   cosmetic; exit codes are correct.
10. Telling a conflict from other errors depends on Nakama's error text. A
    Nakama upgrade must re-run the unit tests and the live fault-injection
    test; if the text changes, conflicts would fail fast as
    `storage_unavailable` (safe, but less available).
11. (Closed in `4c80863`) The former millisecond read window between the
    session check and the receipt read is gone: both come from one snapshot.
12. Taking the character back is not rate-limited beyond session begin's
    10 per 60 s. Two devices swapping control quickly will start refusing
    each other's session begins after that limit. This is intended
    protection; the UX for it belongs to the UI WP.
13. Existing progress / receipt rows written before `4c80863` in a local test
    database keep `permissionRead: 1` until they are next written. This
    affects disposable local test data only; there are no production data.

## Rollback plan

1. **Before merge:** close the PR. `main` is unaffected.
2. **After a merge (only with Charlie's approval):** `git revert` the merge
   commit, or the individual commits. All 52 files are additions, so a revert
   changes no existing behaviour.
   - To undo only the review fixes, revert `bb3e556`. This is not
     recommended: it restores the stale-session replay and the retry storm.
   - To undo only session policy A, revert `4c80863`. That restores
     same-account reads by a superseded session and owner-readable storage.
   - To undo only the A14 fix, revert `fc87435`. This is not recommended: it
     restores the inexact limiter.
3. **Local data:** in `nakama/`, `docker compose --profile multinode stop`
   keeps the data. `docker compose down -v` in `nakama/` removes **only**
   `myrial-vs01-wp01_pgdata` (disposable test accounts).
4. There is nothing to roll back on the Save or the Development Save: neither
   is changed.
