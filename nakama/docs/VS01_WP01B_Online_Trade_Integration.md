# VS-01 WP01-B — Godot × Nakama Online Trade Integration: Evidence

- Repository: `8tdgdvs26d-netizen/project-gersang-mobile`
- Branch: `claude/vs01-wp01b-online-trade` (own worktree, not rebased, no force push)
- Base `main`: `1321ca3590e7e019d450571583932439b31b72ef` (CP-008)
- **Code under test:** `dd4e7e6d863044b1b7dde592147969478a1819a4`. This is the
  PR #133 review-round-1 fix, on top of `9bb30a4`. The commit after it changes
  only this document.
- Approval: Charlie approved the WP01-B Blueprint and the bounded
  implementation on 2026-10-10 (Blueprint and Current Status addenda).
- Mac: Godot 4.7.2.stable, Node 24.21.0, Docker Desktop, Nakama 3.25.0,
  PostgreSQL 16 (local only). Recorded 2026-10-10.

## What changed (8 files vs `main`: 7 code / test / tool files + this document; no gameplay, UI, save, scene or server code)

The earlier "7 files" count left out this document. GitHub's PR diff counts
8. The proxy is one file under `nakama/tests/live/tools/`.

| File | Change |
|---|---|
| `godot/scripts/online_trade_adapter.gd` | **New.** `OnlineTradeAdapter`: reuses the WP01 `OnlineProgressClient` for ONE representative good (`test_good_01`). Results use TradeService's shape and reason codes. The Godot `Wallet` / `CharacterInventory` are a mirror rebuilt **only** from server-confirmed progress (null before the first confirmation), never the game's or the save's. Since `dd4e7e6` the view is **monotonic** (see the review section). Other goods are refused locally. |
| `godot/tests/verify_vs01_wp01b_online_trade_adapter.gd` | **New**, offline, part of the normal Godot regression (51 checks). |
| `godot/tests/live_vs01_wp01b_online_trade.gd` | **New** live harness, run by `run_live_tests.sh` (87 checks). |
| `nakama/docs/VS01_WP01B_Online_Trade_Integration.md` | **New**, this document. |
| `nakama/tests/live/tools/lossy_proxy.mjs` | **New** local test proxy. It forwards everything, but drops the server's answer to trade RPCs AFTER the server decided ("response lost after commit"). |
| `godot/tests/verify_vs01_wp01_online_contract.gd` | The WP01 isolation check treats the adapter as part of the online layer (it still forbids any GAMEPLAY script from using the online layer). |
| `nakama/scripts/run_live_tests.sh` | Starts the proxy, runs the WP01-B harness, and requires each Godot run's own "passed" line. |
| `nakama/scripts/run_godot_regression_isolated.sh` | Strict re-check (see the finding below). `godot/tests/run_tests.sh` is unchanged. |

Not changed: `main.gd`, scenes, buttons, `save_store.gd` / Save v14, the
Nakama server module, pricing, rules, `OnlineProgressClient`. There is no
second account or trade system.

## Results on `dd4e7e6`

| Suite | Command | Result |
|---|---|---|
| Godot full normal regression, isolated `user://`, strict | `GODOT=… nakama/scripts/run_godot_regression_isolated.sh` | **PASS 67 / 67** (65 existing + WP01 contract 134 checks + WP01-B adapter 51 checks), 0 script errors, strict check passed |
| Node / npm suite (repo root) | `npm test` | **PASS 508 / 508** |
| Nakama server unit tests | `cd nakama && npm ci && npm test` | **PASS 43 / 43** |
| Live Node stress (WP01 regression) | `nakama/scripts/run_live_tests.sh` | **PASS 14 / 14** |
| Live Godot SDK probe, WP01 (regression) | same script | **PASS 47 / 47 checks** |
| **Live Godot online trade harness, WP01-B** | same script | **PASS 87 / 87 checks** |

First delivery (`9bb30a4`): Godot 67 / 67 (adapter 44 checks), Node 508,
server unit 43, live 14, WP01 probe 47, WP01-B harness 85. All PASS.

## PR #133 review round 1: out-of-order answers could roll the mirror back (fixed in `dd4e7e6`)

**Finding (GPT):** `_rebuild_mirror()` rebuilt from
`OnlineProgressClient.get_confirmed_progress()`. The shared client keeps
whichever answer completes LAST. If trade B (revision 3) answers before trade
A (revision 2), A's older view overwrote the newer one, rolling back money,
goods and quotes (`get_quote()` read the same cache). The live S2's final
`refresh()` hid it.

**Reproduced (deterministic, offline):** a gated test client releases the
answers in reverse order. Against the PREVIOUS adapter, the new checks fail
exactly as described: revision 3 → 2, money 9831 → 9916, goods 2 → 1, quote
86 → 85, and the change signal fires [3, 2]. The equal-revision tie-break
also fails (the stale quote 90 wins over 88).

**Fix (adapter only):** the adapter takes the progress view from EACH answer
(the client already returns it in `data.progress`) and accepts it only if its
server revision is higher than the held one, or, at the same revision (same
money and goods by definition), if it answers a LATER-issued request (fresher,
time-dependent quotes). Money, goods and quotes come only from that accepted
view. The adapter no longer reads the client's shared cache.
`OnlineProgressClient`, the server and Session Policy A are unchanged, so no
STOP condition applies.

**Proof:**
- Offline: 7 new checks (reverse order, quotes, signal once, equal-revision
  tie-break) pass; they fail on the previous adapter.
- Live S2 now checks BEFORE any refresh: after 12 concurrent buys, the mirror
  sits at the newest receipt's revision (13) with its exact money / goods
  (8956 / 12).

The Godot results are LOCAL Mac tests. **No Godot CI exists.** GitHub CI on
the PR runs `test` (Node / npm CI) and `nakama-server-unit-tests` (Node). Both
are Node, not Godot.

## WP01-B live harness (`live_vs01_wp01b_online_trade.gd`), per scenario

Each scenario uses its own disposable local email test account.

| # | Scenario | Evidence |
|---|---|---|
| S1 | Buy / sell confirmed by the server; mirror; scope | No mirror before confirmation. Buy A ×10 at 84 → 9160 / 10; sell B ×10 at 114 → 10300 / 0. Server rule rejection gives `insufficient_cargo` (TradeService code). `test_good_02` refused locally. Mirror equals a fresh server read. |
| S2 | 12 concurrent buys from one Godot client | All 12 applied with 12 distinct keys. BEFORE any refresh, the mirror is at the newest receipt's revision with its money / goods. Server state = sum of the 12 receipts; mirror equals the server. |
| S3 | Response lost AFTER commit (lossy proxy), 3 orders | Each order reached the server 3 times through the SDK's own automatic retries (same key). The client saw no answer: uncertain and pending, mirror unchanged. Recovery returned the ORIGINAL receipt (`replayed`); money and goods moved exactly once each. |
| S4 | Network down BEFORE the server (closed port) | Uncertain and pending, mirror unchanged. Recovery applied it the first time, exactly once; nothing left pending. |
| S5 | Session takeover between two devices (policy A) | Device A has an order with a lost answer. B takes over and sees it (11). A is refused, gets the signal once, cannot read, and cannot recover while superseded (the order stays pending). B trades. A takes back and its pending order resolves to its original receipt. 10 + 1 + 1 = 12: nothing doubled or lost. B is now superseded. |
| S6 | Server restart with an uncertain order | `docker compose restart nakama`, healthy again after ~1.1 s. Same session; confirmed state kept (10 + 1). Recovery replays; nothing applied twice. |
| S7 | **App kill (LIMITATION)** | See the next section. |
| S8 | Rate limit through the adapter | 36 concurrent buys → 30 applied, 6 `rate_limited` (definite, not pending); server = accepted orders only. |

Lossy-proxy counters for the run: 18 trade requests forwarded, 18 server
answers dropped, all upstream HTTP 200. Each was later resolved exactly once.

## App kill: tested LIMITATION (not changed in WP01-B)

Pending commands live only in the running app's memory (WP01 design;
disk persistence needs a separate Charlie decision).

| Case | Result |
|---|---|
| Killed AFTER the server committed (answer lost) | The restarted app has **no pending command** and cannot match the killed order to its receipt. The **server state is correct**: the order applied once and nothing was lost. If the player re-issues the order, it is a **second, separate trade** (new key): +10, then +10 again = 20. |
| Killed BEFORE the order reached the server | That order never applied; the server state is unchanged; nothing is pending. |

**Not claimed:** app-kill / cross-restart recovery of uncertain trades. Only
in-process recovery is proven: lost answer, network loss, session takeover
and server restart while the app keeps running.

## Finding: Godot exits 0 when a test script fails to parse

Reproduced on Godot 4.7.2: `--script` with a parse error exits **0**.
`godot/tests/run_tests.sh` decides PASS by exit code alone, so a script that
fails to compile would be listed as PASS. A run showed
`PASS … | SCRIPT ERROR: Parse Error …`.

- Past results are NOT affected. Every PASS line in the six recorded
  regression logs (baseline, WP01 rounds, post-merge) carries its script's own
  "passed" message, with 0 errors.
- Mitigation inside WP01 tooling only: `run_godot_regression_isolated.sh`
  now fails unless every PASS line carries its "passed" message and no parse /
  script error (verified: an injected parse error gives exit 1; a clean run
  gives exit 0). `run_live_tests.sh` requires each Godot run's passed line.
- **Not changed:** `godot/tests/run_tests.sh`, which is outside WP01-B scope.
  Recommendation for GPT / Charlie: fix it in a separately approved change.

## Development Save and isolated user://

| | SHA-256 | mtime | size | version |
|---|---|---|---|---|
| Before (preflight and before the `9bb30a4` runs) | `59fcf77a88a98b966166485ce4078c036a6ade747db4c07f7a41b635663531f7` | 1790568901 | 2052 | 8 |
| After the `9bb30a4` runs | `59fcf77a88a98b966166485ce4078c036a6ade747db4c07f7a41b635663531f7` | 1790568901 | 2052 | 8 |
| Before the `dd4e7e6` runs | `59fcf77a88a98b966166485ce4078c036a6ade747db4c07f7a41b635663531f7` | 1790568901 | 2052 | 8 |
| After the `dd4e7e6` runs | `59fcf77a88a98b966166485ce4078c036a6ade747db4c07f7a41b635663531f7` | 1790568901 | 2052 | 8 |

Every Godot run used a temporary `HOME`. The tests print their `user://`
folder; for example, the WP01-B harness during development printed
`…/scratchpad/wp01b/home/Library/Application Support/Godot/app_userdata/Myrial- Unwritten`
and reported the Development Save fingerprint inside it as `absent`. The
normal user data folder was never the active `user://`. Docker alone got the
real HOME, through `env`, to find its own config.

## Acceptance criteria NOT met / not claimed (PENDING)

- App-kill durability of uncertain trades (RAM-only pending commands; tested
  limitation above).
- Live game wiring: `main.gd` buttons, market / city UI, all goods and cities.
- Sign in with Apple (D1 formal method) on device; only local email test
  accounts used.
- iPhone / iPad device acceptance; GPT Accepted, Mac Accepted, Playtested,
  Player Value Verified.
- Godot CI (none exists).
- Save migration (assessment only, D6).

## Known risks / remaining gaps

1. App kill after commit: the player cannot be told the outcome of the killed
   order, and re-issuing it makes a second trade (possible unintended double
   purchase). Needs the separate pending-persistence decision.
2. The Godot regression runner (`run_tests.sh`) can report a parse-failed
   script as PASS. Mitigated only in the WP01 wrapper; the runner fix is
   pending approval.
3. The SDK retries a failed request automatically (3 extra attempts, very
   short backoff). This is safe because the key is the same and the server
   replays it, but it multiplies requests during outages and counts toward the
   rate limit (30 / 10 s).
4. The mirror shows only server-confirmed state. While an order is uncertain,
   the UI (later WP) must show "pending" rather than the old values as final.
5. Only `test_good_01` is integrated; other goods are blocked locally by design.
6. The harness restarts the LOCAL Nakama container through Docker (test-only;
   it needs the real HOME for Docker).
7. The SHARED `OnlineProgressClient.get_confirmed_progress()` can still go
   back to an older revision under concurrent answers (last answer wins). The
   adapter no longer uses it, but any OTHER caller of that client method
   would see the regression. Changing the shared client was out of scope
   (STOP rule), so it needs a GPT / Charlie decision (see the PR reply).
8. The adapter's monotonic view covers the answers it received itself. An
   adapter is meant for one signed-in account. Signing a different account
   into the same client needs a new adapter (no reset API in WP01-B).
9. At the same revision, the tie-break uses local request issue order. That
   is an approximation of server time for time-dependent quotes only; money
   and goods cannot differ at the same revision.
10. Risks carried from WP01 / CP-008 still apply (SDK v3.4.0 age, Nakama
   error-text dependency, single-database multi-node proof, v8 Development
   Save would be upgraded if the game ran on the normal user data folder).

## Rollback

- **Before merge:** close the PR. `main` (`1321ca3`) is unaffected.
- **After a merge (only with Charlie's approval):** `git revert` the merge
  commit, or the individual commits:
  - `dd4e7e6` monotonic view fix (reverting it brings back the review
    finding: the mirror and quotes could roll back under concurrent answers.
    Not recommended.)
  - `90ab07f` adapter + offline test (removing it also returns the isolation
    check to its WP01 form)
  - `f477198` live harness + proxy + `run_live_tests.sh`
  - `9bb30a4` strict regression wrapper (revert only together with an
    approved `run_tests.sh` fix, or the false-PASS gap returns)
  - the docs commit
- No data to roll back: no save, schema or server data contract changed.
  Local test accounts live only in the disposable Docker volume
  `myrial-vs01-wp01_pgdata`.
- Full source restore if ever needed: CP-008 package (Drive folder
  `CURRENT SOURCE — 2026-10-10 — 1321ca3…`; bundle restore steps in its
  checkpoint record).
