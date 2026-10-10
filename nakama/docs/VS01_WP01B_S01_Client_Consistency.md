# VS-01 WP01-B-S01 — Shared OnlineProgressClient Progress Consistency: Evidence

- Repository: `8tdgdvs26d-netizen/project-gersang-mobile`
- Branch: `claude/vs01-wp01b-s01-client-consistency` (own worktree, from `main`)
- Base `main`: `6ed1f5a725c050e917443e71678442e4dd7a1157` (PR #134 T01 and
  PR #133 WP01-B merged; its tree equals the tree validated before the PR #133
  merge)
- **Code under test:** `50188e48cb09103af8edc1f98fd69e9fe7ab2470`. The commit
  after it adds only this document.
- Approval: Charlie approved the S01 Blueprint and the bounded implementation
  on 2026-10-10 (Blueprint addendum).
- Mac: Godot 4.7.2.stable, Node 24.21.0, Docker Desktop, Nakama 3.25.0,
  PostgreSQL 16 (local only). Recorded 2026-10-10.

## Audit: every `_confirmed` write / read and the session lifecycle (before)

| Where | Behaviour before | Problem |
|---|---|---|
| `begin_gameplay_session` | `_confirmed = answer`; `_gameplay_session_id = answer` | an older answer overwrites newer data; an older begin answering late brings back a superseded session id |
| `refresh_progress` | `_confirmed = answer` | older revision / older quotes win if they answer last |
| `_trade` | `_confirmed = answer` | same; and answers after sign-out / account switch still write |
| `sign_out_local` | clears the cache | an in-flight request completing afterwards refilled it |
| `_accept_session` (sign-in) | resets only the gameplay session id | a DIFFERENT account kept the old account's cache, pending commands and superseded flag; `recover_pending()` could resend the old account's orders under the new account |
| `_note_superseded` | any "superseded" refusal marks the client | a late refusal for an OLDER local session marked the current, reclaimed session |
| `recover_pending` | iterates `_pending` | after an account switch it would iterate the old account's orders |
| `get_confirmed_progress` | deep copy of `_confirmed` (the only read) | inherits all of the above |

## Fix (`godot/scripts/online_progress_client.gd` only)

- **Monotonic cache:** `_confirmed` is now written only by `_offer()` (and
  reset). A view is accepted only if its server revision is higher than the
  cached one, or, at the same revision, if it answers a LATER-issued request.
  **Same-revision semantics (confirmed from the existing server, not
  changed):** each applied trade and each session begin raises the revision,
  so the same revision means the same money, goods and stored market. Only
  quotes can differ, because `vs01_progress_get` projects market recovery to
  the time of the read, while a receipt replay returns the stored state. The
  later-issued request is the fresher read. This is a client ordering rule,
  identical to `OnlineTradeAdapter` (reviewed in PR #133); no server rule was
  added.
- **Account epoch:** `+1` on `sign_out_local()` and on signing in a
  DIFFERENT account. An answer to a request sent under an older epoch never
  touches the cache, the session id, the superseded flag or the current
  account's pending list. It is returned as `uncertain`, with reason
  `answer_after_sign_out_or_account_change` and `stale: true` (no `data`, so
  no consumer can read the old view). The same account signing in again
  keeps its cache and pending list, as before.
- **Pending commands per account:** the current account's list stays in
  `_pending` (same API: `get_pending_commands`, `import_pending_commands`,
  `recover_pending`). Other accounts' lists are parked by user id and come
  back when that account signs in again. Recovery stops if the account
  changes mid-way. Pending commands are still RAM-only (no disk persistence).
- **Session policy A unchanged:** a "superseded" answer still marks the
  session and raises the signal once, but only if the request was sent under
  the gameplay session that is current now. The session id follows the
  newest begun session (highest begin revision; two begins never share one).

Unchanged: Session Policy A, the server and its contract, idempotency keys and
recovery by key, `OnlineTradeAdapter` (it still reads each answer's own
`data.progress`), gameplay, UI, `main.gd`, Save / schema.

## Before / after reproduction

`godot/tests/verify_vs01_wp01b_s01_client_consistency.gd`. A gated test
client holds each answer until the test releases it, fixing the completion
order:

| Case | Scenario | Previous client (`6ed1f5a`) | Fixed client |
|---|---|---|---|
| A | revision 3 answers before revision 2 | FAIL: back to rev 2, money 9916, goods 1, quote 85 | PASS: stays rev 3 |
| B | same revision, quote answers reversed | FAIL: stale quote 90 wins | PASS: later-issued 88 |
| C | sign-out, then an old request answers | FAIL: cache refilled (rev 2, 9160, 10 goods); answer reported ok; pending not kept for the account | PASS |
| D | another account signs in, then the old account's request answers | FAIL: new account starts with the old cache and pending order; old money 5000 / 60 goods leak into the new account | PASS: new account sees only its own data; old order not resent; back on the old account its order is pending again |
| E | takeover by another device; a late "superseded" for an OLD local session after this device reclaimed | FAIL: the reclaimed session is marked superseded | PASS (policy A takeover itself still marks + signals once) |
| F | late answer of the old session after reclaiming | FAIL: rev 2 replaced the reclaimed rev 3 | PASS |
| F2 | two begins in flight, the newer answers first | (added after a mutation check) | PASS: session id stays the newest |
| G | network loss, retry with the same key overlapping a new trade | FAIL: retry answered last rolled back to rev 2 | PASS; same key reused |
| H | pending recovery (2 retries) running concurrently with a new trade answering last | FAIL: ended at rev 3 instead of 4 | PASS |

The previous client fails **16** of the 30 checks; the fixed one passes 30 / 30.

Mutation check: removing each fix point in turn makes the test fail:
- monotonic filter: 6 failures;
- equal-revision tie-break: 1;
- epoch check in trade: 5;
- old-session superseded guard: 1;
- per-account pending switch: 4;
- newest-begin session guard: 1 (F2 was added because this one first went
  undetected).

## Results on `50188e4`

| # | Suite | Command | Result |
|---|---|---|---|
| 1 | Relevant: S01 client consistency (offline) | in the regression | **PASS 30 / 30 checks** |
| 1 | Relevant: WP01 contract / WP01-B adapter (offline, compatibility) | in the regression | **PASS 134 / 134**, **51 / 51** |
| 2 | Godot full normal regression (T01 runner, fixed wrapper, isolated `user://`) | `GODOT=… sh nakama/scripts/run_godot_regression_isolated.sh` | **PASS 68 / 68**, FAIL 0, 0 script errors, strict check passed, wrapper exit 0 |
| 3 | Node / npm suite | `npm test` (repo root) | **PASS 508 / 508** |
| 4 | Nakama server unit tests | `cd nakama && npm ci && npm test` | **PASS 43 / 43** |
| 5 | WP01 Godot SDK probe | `nakama/scripts/run_live_tests.sh` | **PASS 47 / 47** |
| 6 | WP01-B online trade harness | same | **PASS 103 / 103** (was 87; +S2 shared-cache check, +S9) |
| 7 | Full live stress | same | **PASS 14 / 14** |

Live additions:
- **S2:** after 12 concurrent trades, without any refresh, the SHARED client
  cache is at the newest receipt's revision (13), like the adapter's mirror.
- **S9 (one client, two accounts, real server):** account 1 has an order
  with a lost answer (lossy proxy).
  - After sign-out, no cache or pending order is exposed.
  - Account 2 signs in: it does not see account 1's order, its recovery
    resends nothing (proxy counter unchanged), and its cache holds only its
    own server state (10000 / 0).
  - Account 1 signs back in: its order is pending again and recovers once
    (replayed; 10 + 1 = 11). Its mirror equals a fresh server read.

Live stress kept its earlier numbers:
- rate limit 30 / 15; two nodes 30 / 15; bursts 30, 0, 0, 0;
- fault injection: 503 with 1 attempt;
- restarts: exactly once.

Lossy proxy: 21 dropped answers, all later resolved exactly once.

GitHub CI on the PR will run `test` (Node / npm CI) and
`nakama-server-unit-tests` (Node). **No Godot CI exists.** All Godot results
above are local Mac tests.

## Development Save

| | SHA-256 | mtime | size | version |
|---|---|---|---|---|
| Before (preflight and before the final runs) | `59fcf77a88a98b966166485ce4078c036a6ade747db4c07f7a41b635663531f7` | 1790568901 | 2052 | 8 |
| After all runs | `59fcf77a88a98b966166485ce4078c036a6ade747db4c07f7a41b635663531f7` | 1790568901 | 2052 | 8 |

Every Godot run used a temporary `HOME` (isolated `user://`). Only Docker
got the real HOME. Test accounts are disposable local email accounts.

## Known risks

1. **Stale answers are reported as `uncertain`.** A caller that issued a
   request before signing out / switching accounts gets `uncertain` (reason
   `answer_after_sign_out_or_account_change`), even if the server applied
   it. The order stays pending for its own account, and recovery after that
   account signs in again resolves it by key.
2. **Pending commands are still RAM-only.** Parked lists of other accounts
   are lost on app kill, like before (app-kill recovery remains PENDING,
   not changed here).
3. **The same-revision tie-break uses local request issue order.** It only
   affects time-dependent quotes; money and goods cannot differ at the same
   revision.
4. **The account boundary is the Nakama user id.** The same account signing
   in again (for example a token refresh) keeps its cache and pending list
   by design.
5. Risks from WP01 / WP01-B / T01 still apply:
   - device / Apple sign-in / UI PENDING;
   - no Godot CI;
   - no runner timeout for hangs.

## Rollback

- Before merge: close the PR; `main` is unaffected.
- After a merge (only with Charlie's approval): `git revert` the merge
  commit, or `50188e4`. That restores the previous shared-client behaviour
  (and its rollback / contamination cases). No data, save or server contract
  is involved.
