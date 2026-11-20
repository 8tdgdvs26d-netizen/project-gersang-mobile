# VS-01 WP01-H E3 — isolated live / stress execution (E3-Prep Phase 1)

Blueprint: WP01-H E3-Prep v0.1r2 (GPT accepted; Phase 1 authorized by Charlie).
**Phase 1 prepares the code only.** Running it (Phase 2) needs a separate
Charlie approval: creating and pushing `wp01-h-e3-cloud-execution`. Every
case below is **NOT RUN** until then.

## How it runs (Phase 2 only)
- `.github/workflows/wp01h-e3-cloud.yml` runs on a push to `wp01-h-e3-cloud-execution`
  only. It has four matrix jobs, each on its own disposable GitHub-hosted runner:
  - `j1`: AC cases plus the code-revert stage;
  - `j1r`: AC-09 regression;
  - `j2`: FS-K1..K9;
  - `j3`: FS-K10 and AC-16, on the real 15-minute TTL with a single node.
- `nakama/scripts/run_wp01h_e3_bounded.mjs` runs the gates in this order. Any failure is a STOP before any test runs.
  - **G1:**
    - R-01: path-restricted diff hashes, 23 blob ids, allow-list, merge-base;
    - runner identity;
    - docker env, context, socket and daemon (empty daemon required);
    - real IPv4/IPv6 bind probe plus `ss`;
    - run root;
    - Godot import and probe;
    - static scan;
    - child env whitelist;
    - workflow static check.
  - **G1-10:** `compose up` within 5 s of the probe. Any failure: STOP, no retry, no port change.
  - **G2:**
    - container labels;
    - `PortBindings` = 127.0.0.1;
    - external IP refused;
    - IPv6 probe;
    - health and the `vs01_trade_resolve` RPC;
    - module hash;
    - fresh database;
    - storage columns.
- Every docker call uses `-p <run project>`. Child processes get `COMPOSE_PROJECT_NAME`, so the unmodified older live tests reach the run's own project too.
- Nothing is deleted. The launcher only takes a leftover inventory, writes a `manifest.json`, and uploads evidence only after `--verify-manifest`.

## Files
| File | Purpose |
|---|---|
| `nakama/tests/live/h1_wp01h_trade_resolve.test.mjs` | AC-01/02/03/10/12/14/15/19/20 (server layer); `pre_revert` / `post_revert` phases |
| `nakama/tests/live/h2_wp01h_combat_intent.test.mjs` | AC-07, AC-08 (a)(b); AC-08 (c) not coverable under R-04 |
| `nakama/tests/live/h3_wp01h_full_stress.test.mjs` | FS-K2 (client side), K3, K4, K7, K9 ledger; FS-K10 + AC-16 (TTL job) |
| `nakama/tests/live/tools/wp01h_db.mjs` | read-only SELECTs in the run project, snapshots (AC-05a S0/S1), ledger |
| `nakama/tests/live/tools/wp01h_seed.mjs` | R-04 seed: INSERT only, run accounts only, manifest, read-back |
| `nakama/tests/live/tools/wp01h_clock.mjs` | FS-K10 verdict from server times only (TTL-1..6, bins, IC-1..5) |
| `godot/tests/live_vs01_wp01h_recovery.gd` | client layer, one phase per process: AC-04/05a/05b/06/13/17/18, FS-K1/K2/K5/K6/K8 |
| `nakama/tests/live/tools/wp01h_lossy_proxy.mjs` | r1 FS-K2: seeded random lossy proxy, 127.0.0.1 only; the shared `lossy_proxy.mjs` is unchanged |
| `nakama/tests/unit/wp01h_e3_launcher.test.mjs` | offline unit tests of the gates, the verdicts, the skip guard and the r1 fixes |

## Targeted Revision r1 (offline)
- **B-1:** the workflow no longer runs `npm ci` at the repository root (there is no lockfile there); `nakama` keeps `npm ci`.
- **B-2:** G1-10 does things in this order: images are pulled first, then `ss`, then the bind probe, then `compose up`.
  - The window is measured from the end of the last probe to the start of compose; it must be at most 5 s.
  - Evidence (probe and compose timestamps, plus container `StartedAt`) is written only after compose has started.
  - G1-10 is written once.
- **B-3:** G2-3 is a functional probe. A synthetic run account calls `vs01_trade_resolve` with `{}`, and the answer is classified as one of:
  - `registered` (400 `unexpected_fields`);
  - `not_registered` (404 / not found);
  - `rate_limited`;
  - `unknown`.
  Only `registered` passes.
- **G2-5:** before any test, no user other than the system user may exist. At the end of the job, every non-system user must be a `@myrial.test` account created during the run.
- **FS-K1:** j2 has a final restart stage. The launcher restarts `nakama` (run project only) during an h3 burst of trade, resolve and claim requests; every key and the ticket must then settle exactly once, the ledger must be clean, and the module hash must be unchanged.
- **FS-K2:** the random lossy proxy runs on 17380 (j2 only, seed derived from the run id). It is used by h3 FS-K2 and by the Godot phase `k2_random`.
- **FS-K6:** Godot phases `k6j_*`, variants `j` / `h` / `hf`. The real server answers `resolve_command_invalid`, and the mark journal (`j`), journal + live file (`h`), or also the HOLD marker (`hf`) cannot be written; a fresh process then checks the result.
- **FS-K9 live mutation** and **AC-08(c) synthetic UPDATE** exist as proposals only. Nothing is implemented, pending a separate approval.

The E3 live tests skip everything unless the launcher sets `MYRIAL_WP01H_E3_RUN_ID`. The old `run_live_tests.sh`, which has no `-p` and only isolates HOME, is **not** used for E3.

## Corrective r2 (offline): FS-K1 restart timing and strict verdict

- **Timing evidence.** h3 records every burst request (key, rpc, client `sent_at` / `done_at`, status, outcome) and writes `cases/FS-K1-restart-round.json` (per-key receipts with `server_time_ms`, claim settlements, ledger problems) **before** asserting. The launcher writes `cases/FS-K1-restart-timing.json`: nakama container `State.StartedAt` before and after, `State.FinishedAt` of the stopped process, the restart command window (`cmd_start` / `cmd_end`), its exit code, and when `/healthcheck` answered again.
- **Verdict** (`restartVerdict`, pure, unit-tested; FAIL > INCONCLUSIVE > PASS):
  - **FAIL:** the h3 test failed, a key does not have exactly one receipt, the claim did not settle exactly once, or the ledger has problems.
  - **INCONCLUSIVE:** no timing or round file; restart exit ≠ 0; `StartedAt` unchanged; unparsable / missing times; times out of order (`cmd_start ≤ stop ≤ start ≤ cmd_end / health`, 1 s margin); a receipt committed inside the down window (contradictory clock evidence); no commit before the stop; no request in flight at the stop; no client error during the restart; no burst commit after the new start (settle-phase commits do not count). "The burst never became ready" is now INCONCLUSIVE (was FAIL): no restart was attempted.
  - **PASS:** none of the above, i.e. direct evidence that the burst crossed the restart and exactly-once held. *(Superseded by r3: that is only in-flight coverage; the case now stays INCONCLUSIVE until there is commit-level evidence.)*
- The client-side "some request failed" check moved from an h3 hard assert to the verdict's coverage rule (INCONCLUSIVE, not FAIL).
- Kept unchanged: the G1 / G2 isolation checks, `recheckG2` before and after the restart, the module-hash STOP, run-project-only restart.
- Assumption (Inference, not proven): docker timestamps, the launcher clock and nakama `server_time_ms` share one host clock (single-host run).

## Corrective r3 (offline): no false PASS for FS-K1

- **Process exit.** `restartVerdict` also gets the h3 process result (`code`, `signal`, `timedOut`). Any non-zero exit, signal or timeout is **FAIL**, even when TAP shows `ok`.
- **Never ready.** This path now runs the same verdict, so a failure the child already proved (TAP `not ok`, an abnormal exit, an invariant break in the round file) is **FAIL**. Only a clean child that never became ready is INCONCLUSIVE.
- **Same-key correlation.** After the settle, h3 retries every key once (`phase: "verify"`). A 200 retry must be `replayed`; anything else is FAIL. A non-200 retry (for example a rate limit) just gives no evidence. `restartKeyEvidence` classifies each key using only that key's own requests, receipt and retry:
  - `response_lost_after_commit`: the key's request was in flight across the stop and got no 200; its single receipt is from before the stop; the same-key retry was replayed.
  - `lost_then_committed_after_restart`: the same, except the single receipt is from after the new start.
  - not coverage: `answered_in_flight`, `no_replayed_retry`, `ambiguous_near_stop` (within 1 s of the stop), `no_single_receipt`, `contradictory`, `not_in_flight`.
- **Evidence levels** (reported in the case as `levels`):
  - `inflight_restart`: COVERED when at least one key is in either of the first two classes.
  - `response_lost_after_commit`: COVERED when at least one key is in the first class.
  - `commit_level`: **PENDING**. A crash inside the commit itself cannot be shown by black-box timing; it needs a server-side hook, which is outside this scope (no E1 or server contract change).
- **Case verdict.** The original FS-K1 requirement ("restart around commit") is kept, so without commit-level evidence FS-K1-restart is **INCONCLUSIVE at best, never PASS**. PASS needs `commitLevel: { verdict: "PASS" }`, which nothing in this phase supplies.
- Unit tests include deliberate false-PASS cases: TAP ok with exit 1, SIGKILL or timeout; evidence spread across different keys; a request in flight but answered; no retry; a retry that was not 200; a receipt near the stop. A mutation check (`09_mutation_check.log`) shows each guard is load-bearing.

## Labels
- FS-K IDs follow the order in which Blueprint v0.1r3 §9 lists the topics (D-P6 (a), Charlie, 2026-11-21).
- AC-14 is tested against the code-derived receipt contract (D-P7a (a), Charlie, 2026-11-21). It reports "Code-derived / CV-01..07 PENDING", never "CV verified"; D-P7b (restoring CV-01..07) is still open.
- `verify_vs01_wp01g_read_deadline` is a known flake. It is always reported separately; one PASS is not formal acceptance.
