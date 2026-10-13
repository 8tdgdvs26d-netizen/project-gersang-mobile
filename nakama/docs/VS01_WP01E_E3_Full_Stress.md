# VS-01 WP01-E — E3 Full Stress, Mutation, Regression & Acceptance Preparation: Evidence

- **Branch:** `claude/vs01-wp01e-combat-exp` (worktree `myrial-vs01-wp01e`).
- **Baseline:** E2 HEAD `2e4abe1dc0aa407a7737d08a218a4321fd612217`. E1 and E2 are GPT ACCEPTED; E3 was released on 2026-10-11.
- **E3 changes tests, scripts and docs only.** No production code changed: `nakama/src` and `godot/scripts` are untouched in E3.
- No push, PR, merge or deployment. The **Mac player acceptance is PREPARED, NOT PERFORMED.**

## Preflight (2026-10-11)

| Item | Result |
|---|---|
| Current Canonical / Status / WP01 Blueprint | read. Latest records: E1 and E2 GPT ACCEPTED, E3 released; S1–S8, R-1–R-4, MC-1 C, MC-2 Q1+F3, Schema v1, ACK-1 conditional |
| GitHub `main` | `43006811111dc3d603c2aa3c339a1a37ca1fd65b` (unchanged) |
| Checkpoint | CP-008 closed; unchanged |
| Worktree | clean at `2e4abe1` |
| Development Save v8 | `59fcf77a88a98b966166485ce4078c036a6ade747db4c07f7a41b635663531f7` (mtime 1790568901, size 2052) |
| Isolation | Docker project `COMPOSE_PROJECT_NAME=myrial-vs01-wp01e` (its own volume; the WP01–C volume is untouched); two Nakama nodes on one PostgreSQL; isolated HOME / `user://` for Godot; disposable accounts |

## E3 files

| File | Purpose |
|---|---|
| `nakama/tests/unit/wp01e_guards.test.mjs` | 7 tests: W1–W7 each proven alone (a single-object competing writer between read and write) |
| `nakama/scripts/run_wp01e_mutations.sh` | the mutation runner (temporary copy only) |
| `nakama/tests/live/e3_wp01e_full_stress.test.mjs` | Full Stress FS-1 to FS-10 (live, two nodes) |
| `nakama/tests/live/e3z_wp01e_expiry.test.mjs` | the real 15-minute deadline race (opt-in `MYRIAL_E3_EXPIRY=1`) |
| `nakama/docs/VS01_WP01E_Mac_Acceptance_Instructions.md` | Mac player steps (for Charlie) |
| this document | evidence, Risk Register, rollback |

## 1. Full Stress (live; two Nakama nodes on one PostgreSQL; requests alternate between the nodes)

Run 1 is the standalone file; run 2 is inside the complete `run_live_tests.sh`.

| ID | Scenario | Result (run 1 / run 2) | Invariant verified in the DB |
|---|---|---|---|
| FS-1 | 50 concurrent **same-key** claims | PASS / PASS: 1 applied, 41 replayed, 8 `rate_limited`; the 8 resent after the window → 8 replayed | 1 receipt, 1 ticket-claim marker, Hero revision 1; every replay's receipt deep-equals the original |
| FS-2 | 50 **different keys** on one ticket | PASS / PASS: 1 applied, 49 `ticket_already_claimed` | 1 marker, 1 intent, EXP 100 |
| FS-3 | 50 concurrent **begins** | PASS / PASS: 1 issued, 5 `ticket_unsettled`, 44 `rate_limited` | exactly 1 ticket; ≤ 6 limiter-accepted (R-3) |
| FS-4 | 50 **claim ⟷ abandon** races (50 accounts) | PASS / PASS: 22 claimed + 28 abandoned / 28 + 22 | one terminal outcome per ticket; abandoned → no EXP; claimed → abandon gets `ticket_already_claimed` |
| FS-5 | **5-minute abandon / begin bot** | PASS / PASS: 30 limiter-accepted in 300 s; **max 6 in any 58 s window**; 889 + 174 throttled | Hero EXP **0** (no free reroll, MC-2 Q1+F3) |
| FS-6 | **Trade v1 + Online EXP** written concurrently (10 accounts × (1 claim + 10 trades)) | PASS / PASS: 10 claims, 100 trades applied | per account: 10 trade receipts, backpack 10, money = 10000 − Σ receipts; Hero revision 1 |
| FS-7 | **Server restart** with claims in flight (6) | PASS / PASS: during the restart 6 × no answer; after it, 6 × applied | 1 receipt, Hero revision 1 each. In both runs the requests had not committed before the restart (nor was their arrival proven); **the commit boundary is closed by RW-1..3, section 6**. |
| FS-8 | **Lost replies** (client aborts after send) | PASS / PASS: retries 6 applied + 4 replayed / 10 applied | exactly once each |
| FS-9 | **Session takeover** racing claims (20 accounts) | PASS / PASS: 12 + 8 / 13 + 7 (applied / superseded) | superseded → no write; after reclaim the same key settles once |
| FS-10 | **DB load** per settled claim (evidence) | 5 inserts, 3 updates, 4.0 / 5.1 scans | (first-time objects included) |

## 2. Safety / Recovery

| Scenario | Evidence | Result |
|---|---|---|
| Restart during a claim | FS-7 (×2), `z_restart` (Trade); **RW-1..3 (×2): restart before and after the settlement commit, section 6** | PASS |
| Network loss / lost confirmation | FS-8 (×2); E2 live and stress through the lossy proxy (claim replies dropped after commit: 39 in the full run) | PASS: the original receipt, EXP once |
| Session takeover and recovery | FS-9 (×2); E2 live takeover → reclaim | PASS |
| **Ticket deadline races** (real 15 min) | `e3z_wp01e_expiry.test.mjs`, run v1 (6 accounts, node 1) and **v2 (8 accounts, node 2)**: intent accounts settle once before or after the deadline; no-intent accounts settle once if a request precedes the deadline (later ones replay); **account 6 (no intent, only +50 / +300 ms) → `ticket_expired` ×2, ticket EXPIRED, no EXP**; account 7 (intent, only after) → applied + replayed | PASS ×2 |
| EXP / receipt settled exactly once | every FS, the expiry races, E1 / E2 live | PASS |
| SDK auto-retry vs rate limits | E2 stress: one client call = 3 server requests under loss (SDK retries); FS-1: throttled requests are transient and replay later | Measured; accepted (R7) |

## 3. Mutation tests (W1–W7)

`nakama/scripts/run_wp01e_mutations.sh`, temporary copy only (**the real source is never edited**; `git diff -- nakama/src godot/scripts` is empty).

- Each guard of the claim settlement transaction gets two mutants:
  - **noversion:** the version check is removed, i.e. last write wins;
  - **removed:** the write is removed from the transaction.
- After each mutant, the WP01-E unit tests are run.
- Baseline (no mutation): 51/51 pass.

| Guard | noversion | removed |
|---|---|---|
| W1 receipt (create-only) | **KILLED** (W1 isolation test) | **KILLED** (replay / quota / intent tests) |
| W2 ticket-claim marker (create-only) | **KILLED** | **KILLED** |
| W3 ticket (version) | **KILLED** | **KILLED** |
| W4 encounter state (version) | **KILLED** | **KILLED** |
| W5 Hero progression (version) | **KILLED** | **KILLED** |
| W6 session guard, Trade v1 identical rewrite (version) | **KILLED** | **KILLED** |
| W7 claim intent (create-only / version) | **KILLED** | **KILLED** |

**Mutants survived: 0 of 14** (two runs, identical). The original code was restored, and the full suites pass on it.

## 4. Regression

| Suite | Result |
|---|---|
| Nakama unit | **94/94** (87 + 7 guard tests) |
| `run_live_tests.sh` complete (disposable project, two nodes) | **exit 0**: Node live **31 pass + 1 skipped** (the opt-in expiry test; run separately ×2); Godot live WP01 47, **WP01-B Trade 103**, **WP01-C Trade UI 23**, E2 live 34, E2 stress 34 |
| Trade v1 regression | the WP01 Node trade suites (stress, fault, restart, multinode, DB load) + WP01-B / WP01-C Godot live: all PASS; FS-6 trade + EXP concurrent: exact |
| Godot Full Normal Regression | **71/71**, SCRIPT_ERROR 0, wrapper exit 0 |
| Node/npm (root; **not Godot CI**) | **508/508** |
| Development Save v8 | `59fcf77a…5531f7` (mtime 1790568901, size 2052) at the E3 preflight, at 05:57:26Z (before unit / npm / mutation / Godot) and at 06:29:58Z (after every E3 run incl. both expiry races) |

## 5. Mac player acceptance — preparation only

| Item | Result |
|---|---|
| TEST scene launches as a window | `godot --path godot res://scenes/online_combat_test_mode.tscn` with an isolated HOME: exit 0, no error, no save file in the isolated `user://` |
| Correct Docker project | the launcher must run with `COMPOSE_PROJECT_NAME=myrial-vs01-wp01e` (written into the instructions) |
| Steps | `nakama/docs/VS01_WP01E_Mac_Acceptance_Instructions.md` |
| Status | **PREPARED, NOT PERFORMED.** No automated result is presented as Mac acceptance. |

## 6. E3 corrective: the restart window of a claim (RW-1..3)

GPT E3 review: FS-7 restarted the server right after sending, so it did not
prove that a request had reached the server, nor what happens when the restart
falls on either side of the settlement commit. New test
`nakama/tests/live/e3r_wp01e_restart_window.test.mjs` (disposable project
`myrial-vs01-wp01e`, test-only; no production code changed). Each case uses its
own fresh account, waits the 10 s minimum age, then:

| Case | Boundary control and observation | Restart | Before the resend | Same key resent | Final DB |
|---|---|---|---|---|---|
| **RW-1** | A psql session holds the ticket row (`SELECT … FOR UPDATE`). The claim enters the server, opens the settlement transaction and blocks: **observed** in `pg_stat_activity` as one `active` backend waiting on `Lock`, blocked by the psql pid, running `WITH upd AS (UPDATE storage …`. Uncommitted writes are invisible (0 receipts). | **SIGKILL** (`docker compose kill`) while the transaction is open | client: no answer (socket closed). Lock released → the open transaction is rolled back: ticket OPEN, 0 receipts, no Hero, 0 claim markers, 0 idle-in-transaction backends | applied, replayed | ticket CLAIMED; 1 receipt (+100); Hero revision 1, Lv 2, 0 EXP; 1 marker |
| **RW-2** | same as RW-1 | **SIGTERM** (`docker compose restart`, graceful shutdown) while the transaction is open | same as RW-1 | applied, replayed | same as RW-1 |
| **RW-3** | The claim goes through an in-test proxy that waits for the server's full answer (**observed**: HTTP 200, `replayed:false`, `exp_awarded 100`) and drops it. The **commit is observed** in PostgreSQL: CLAIMED, 1 receipt, Hero revision 1, Lv 2. | **SIGKILL** after the commit | client: no answer. DB after the restart **identical** to before it (committed EXP not lost) | replayed (node 1), replayed (node 2); the replay returns the original receipt (same `exp_awarded` 100, `server_time_ms`) | unchanged: 1 receipt, Hero revision 1, EXP not added again |

Runs: run 1 = RW-1 and RW-2 PASS, RW-3 failed **in the test harness** (the
proxy's copy of the reply was gzip-encoded and could not be parsed; the DB
checks before the failure already held). Fixed in the test only (gunzip), then
**run 2 and run 3: 3/3 PASS each**. Raw logs, the Nakama server log of the
restarts and the Development Save record are in the evidence package.

The test restarts node 1 and is run on its own (like the expiry race); it is
not part of `run_live_tests.sh`.

## Risk Register

| # | Risk | Likelihood / impact | Status / mitigation | Evidence |
|---|---|---|---|---|
| R1 | Fabricated victory within the M1 bounds | possible / bounded (≤ 200 EXP per ticket, paced by S3 + R-3) | **Accepted** for isolated TEST (S2). Not production anti-cheat. | Design; FS-5 pacing |
| R2 | Duplicate EXP | — | **Mitigated:** W1–W7 in one transaction; 0/14 mutants survive; concurrency stress | FS-1/2/4/6/7/8/9, mutations, E2 stress |
| R3 | Lost confirmed EXP (lost reply / restart / takeover) | — | **Mitigated:** the receipt replay precedes ticket checks; the same key resolves once | FS-7/8/9, RW-1..3, E2 live, expiry race |
| R4 | A legitimate result lost on app kill before the server recorded it | possible / one battle's EXP | **Accepted (S6 RAM-only):** told to the player; explicit abandon; MC-1 C protects anything already recorded | E2 live app-kill |
| R5 | Unconfirmed result shown as earned | — | **Mitigated:** no EXP preview; only server views shown | E2 deterministic + mutation M3 |
| R6 | Trade v1 interference from the ACK-1 identical-value guard | — | **Mitigated:** value and md5 version unchanged (real PostgreSQL); trades retry or succeed; `update_time` touched (unused) | E1 ACK-1, FS-6, Trade live suites |
| R7 | SDK auto-retry amplification consumes quotas (≈ 3 server requests per client call under loss) | likely under bad networks / delay only | **Monitored:** the client keeps the result and resends (`rate_limited` is transient) | E2 stress (3 per call), FS-1 throttled → replayed |
| R8 | Abandon throttled by the shared begin quota | occasional / up to 60 s delay | **Accepted (MC-2 Q1):** the result is kept and resent | E2 live, FS-5 |
| R9 | Per-claim DB cost | low at TEST scale | **Measured:** 5 inserts + 3 updates per settled claim (first-time objects included); the limiter per request | FS-10, WP01 x_db_load |
| R10 | A ticket expires with no recorded intent | rare / that battle's EXP | **Explicit** `ticket_expired`, never silent (MC-1 C) | expiry race v2 account 6; unit |
| R11 | Hero-only Base + Growth stats differ from offline | by design (S8) | **Accepted** for TEST | — |
| R12 | Launcher on the wrong Docker project could touch the WP01–C volume | operator error | **Mitigated** by instructions: always `COMPOSE_PROJECT_NAME=myrial-vs01-wp01e` | Mac instructions |
| R13 | No Godot CI; Mac / iPhone / iPad / Playtest not performed | — | **Open:** Mac acceptance prepared (instructions); devices NOT TESTED | — |

## Rollback evidence

- **Rehearsal** (temporary detached worktree, no branch created; removed afterwards): `git revert` of `2e4abe1`, `7e40186` and `1e18853` → **tree identical to `main` `4300681`**, and the Nakama unit tests on the reverted tree pass **43/43**.
- After the E3 commit, the rollback is the same `git revert` of the four WP01-E commits (the E3 commit adds only tests, scripts and docs).
- **Clarification (documentation-only, 2026-10-13):** the branch now has **six** WP01-E commits on `main` `4300681`: `1e18853` (E1), `7e40186` (E1 corrective), `2e4abe1` (E2), `d62ce8f` (E3), `d613ce9` (E3 corrective, FS-7 restart window: test + docs) and `a12e771` (Mac acceptance record: docs only).
  - The rehearsal above **actually reverted only `2e4abe1`, `7e40186` and `1e18853`** (tree = `main` `4300681`, unit 43/43). It ran before `d62ce8f`, `d613ce9` and `a12e771` existed.
  - **No new rollback rehearsal has been run for the six commits.** That reverting all six restores `main` is an expectation (the last three add or change only tests, scripts and docs), not a rehearsed result.
  - The original rehearsal record above is kept unchanged.
- **Data:** WP01-E writes only to the new `vs01_wp01e_*` collections. They become inert when the RPCs are unregistered.
  - Trade v1 data is never changed; the guard rewrites it with an identical value.
  - The Development Save is never read or written.
  - Volumes are kept; never `down -v`.
- **Stop** the disposable stack with `COMPOSE_PROJECT_NAME=myrial-vs01-wp01e docker compose --profile multinode stop`.
