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
| `nakama/tests/unit/wp01h_e3_launcher.test.mjs` | offline unit tests of the gates, the verdicts and the skip guard |

The E3 live tests skip everything unless the launcher sets `MYRIAL_WP01H_E3_RUN_ID`. The old `run_live_tests.sh`, which has no `-p` and only isolates HOME, is **not** used for E3.

## Labels
- FS-K IDs are provisional until D-P6 is decided.
- AC-14 reports "Code-derived / CV-01..07 PENDING", never "CV verified" (D-P7a).
- `verify_vs01_wp01g_read_deadline` is a known flake. It is always reported separately; one PASS is not formal acceptance.
