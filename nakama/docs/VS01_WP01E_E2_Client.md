# VS-01 WP01-E — E2 Godot Client (isolated Online Combat TEST): Evidence

- **Branch:** `claude/vs01-wp01e-combat-exp` (worktree `myrial-vs01-wp01e`).
- **Baseline:** E1 corrective HEAD `7e401865189acd6ec667036972530a78e57966fb`. E1 is GPT ACCEPTED; E2 was released on 2026-10-11.
- **Scope:** E2 only. **E3** (Full Stress and the complete Mac player acceptance) is **not started**. No push, PR, merge or deployment.
- **Preserved design:**
  - **S-series:** S1–S8 (Hero-only; EXP / Level only; Base + Growth; RAM-only pending).
  - **R-series:** R-1 to R-4.
  - **MC-1 Option C** and **MC-2 Q1+F3**.
  - Schema v1.
  - The E1 server (unchanged in E2).

## Preflight

| Item | Result |
|---|---|
| Worktree | clean at `7e40186`; `origin/main` still `4300681` |
| Development Save v8 | `59fcf77a88a98b966166485ce4078c036a6ade747db4c07f7a41b635663531f7` (mtime 1790568901, size 2052) |
| Isolation | Godot runs with an isolated HOME (`user://`); disposable Docker project `COMPOSE_PROJECT_NAME=myrial-vs01-wp01e`; disposable `@myrial.test` accounts |

## What E2 adds

| File | Change |
|---|---|
| `godot/scripts/online_combat_adapter.gd` | new. `OnlineCombatAdapter`: the E1 RPC client side. It holds a mirror of server-confirmed Hero progression (a newer revision wins), keeps the pending claim / abandon with the same key and payload, sorts each answer into CONFIRMED / KEEP / SUPERSEDED / FINAL, and builds Hero Base + Growth stats from the server Level. It never computes or applies EXP. |
| `godot/scripts/online_combat_test_mode.gd`, `godot/scenes/online_combat_test_mode.tscn` | new. The isolated Online Combat TEST scene: sign-in, session, three group choices (enemy groups 1 / 2+3 / all), a Hero-only `CombatBattle` in the existing `CombatView` (**no `progression`**, so no local EXP preview), submit, automatic resend (2 → 4 → 8 → 16 → 30 s), reclaim, explicit two-step abandon, app-kill recovery. |
| `godot/scripts/online_progress_client.gd` | **+1 additive method** `gameplay_rpc()` (22 lines): one command under the active gameplay session with the existing policy A / account-epoch / ambiguous-gRPC handling. No existing trade path changed. |
| `godot/tests/verify_vs01_wp01e_online_combat.gd` | new deterministic test (gated fake server), part of the Godot regression |
| `godot/tests/live_vs01_wp01e_online_combat.gd` | new live test (real server, real scene) |
| `godot/tests/live_vs01_wp01e_combat_stress.gd` | new live targeted stress |
| `godot/tests/verify_vs01_wp01_online_contract.gd` | the isolation exemption list includes the two WP01-E online-layer files; gameplay scripts are also checked for `OnlineCombatAdapter` |
| `nakama/tests/live/tools/lossy_proxy.mjs` | it also drops `vs01e_encounter_claim` replies after the server committed (separate `claim_*` counters; trade counters unchanged) |
| `nakama/scripts/run_live_tests.sh` | runs the two new Godot live checks (strict marker) |
| `nakama/scripts/run_online_combat_ui.sh` | new Mac launcher for the TEST scene (for E3 hands-on) |
| this document | evidence |

**Not changed:**

- the E1 server (`nakama/src`), Trade v1 code / data;
- `main.gd`, `main.tscn`, `CombatBattle`, `CombatView`, `PartyProgression`, `ProgressionState`, `SaveStore`;
- every gameplay rule.

## Answer handling (as implemented and tested)

| Server / network answer | Handling | What the player sees | Pending |
|---|---|---|---|
| receipt (`replayed: false`) | CONFIRMED | 「伺服器已確認：經驗 +N（Lv a → Lv b）」; Level / EXP updated from the server | dropped |
| receipt (`replayed: true`) | CONFIRMED | 「伺服器已確認（之前已入帳）…」; **no second EXP** (same revision) | dropped |
| `too_early` | KEEP | 「戰鬥結束得太快…稍後自動重新提交」 | kept, same key and payload |
| `rate_limited` / `rate_limit_contention` / `conflict_retry_exhausted` | KEEP | 「提交太頻密…稍後自動重新提交」 | kept |
| no answer / timeout / `storage_unavailable` (gRPC 14) / answer after sign-out | KEEP | 「未能確認結果：可能已入帳或未入帳…以原提交核實」 | kept (under its own account) |
| `gameplay_session_superseded` | SUPERSEDED | 「此帳號已在另一裝置開始遊戲…按「重新接管」後會重新提交」; nothing is sent while superseded | kept; resent with the same key from the reclaimed session |
| `ticket_unsettled` (begin) | — | 「上一場遭遇仍未結算…」; the unresolved ticket is read; abandon is offered | — |
| `ticket_expired`, `claim_locked`, `ticket_already_claimed`, `ticket_abandoned`, `ticket_not_found`, `invalid_claim` | FINAL | a clear message; `ticket_already_claimed` re-reads the server progression | dropped |
| `cooldown_active` (begin) | — | 「此敵群剛被擊敗，冷卻中…」 | — |

**App kill (S6):** a new process shows only `vs01e_progression_get` (the server Level / EXP). If an unresolved ticket exists with no result in RAM, it shows 「…只可按「放棄上一場」」 and offers the explicit two-step abandon (MC-2 Q1+F3: it consumes begin quota; no wait, no cooldown).

## Test results (2026-10-11 HKT; isolated `user://`, disposable stack and accounts)

| Suite | Result |
|---|---|
| **E2 deterministic** `verify_vs01_wp01e_online_combat` (gated fake server) | **68 checks PASS** |
| **E2 live** `live_vs01_wp01e_online_combat` (real scene, real server, lossy proxy, takeover, app kill) | **34 checks PASS** |
| **E2 live targeted stress** `live_vs01_wp01e_combat_stress` | **34 checks PASS** |
| `run_live_tests.sh` complete (two nodes, disposable project) | **exit 0**: Node live **21/21**; Godot live WP01 probe 47, WP01-B harness 103, WP01-C UI 23, E2 live 34, E2 stress 34; lossy proxy: trade 24 / claim 39 replies dropped after commit, all resolved |
| Godot Full Normal Regression (strict wrapper) | **71/71 PASS**, FAIL 0, SCRIPT_ERROR 0, wrapper exit 0. Includes `verify_vs01_wp01_online_contract` 134, `verify_vs01_wp01b_s01_client_consistency` 39 (shared client unchanged in behaviour), `verify_vs01_wp01c_online_trade_ui` 65, `verify_m2_09` 524 (TimeSource rule now also scans the new scripts), core loop 1854. |
| Nakama unit (relevant: E1 server unchanged) | **87/87** |
| Node/npm (root; **not Godot CI**) | **508/508** |
| Development Save v8 | `59fcf77a…5531f7`, mtime 1790568901, size 2052, before (05:13:51Z) and after (05:31:29Z) the full run |

### Evidence that confirmed EXP is never credited twice

- **Deterministic:** a replayed receipt leaves revision 1 and Lv 2 unchanged. An older server revision never replaces a newer one.
- **Live:**
  - same key → `replayed: true`, revision still 1;
  - a lost claim reply (the proxy dropped it after the commit) → the retry returns the **original** receipt; a fresh server read shows 40 EXP, not 80;
  - after a takeover and reclaim, the result is confirmed once (40 + 100 = 140).
- **Live stress:** 4 battles × 3 lost replies each. Every battle was confirmed exactly once (revision +1 per battle). The server Level / EXP (500 EXP → Lv 4 / 50) equals the sum of the confirmed receipts. A double tap submits one claim.

### Pending and session recovery

- **Deterministic:** the same key and payload across too_early, rate_limited, rate_limit_contention, conflict_retry_exhausted, uncertain and storage_unavailable. Superseded → nothing sent → reclaim → the same key from the new session → confirmed. Sign-out mid-claim → the answer is not shown to the next account and stays filed under its own account.
- **Live:**
  - a fast win → too_early → the same key is confirmed after 10 s;
  - takeover by a second device → superseded → reclaim → confirmed once;
  - app kill after an intent was recorded → the restarted client shows server progression only → explicit abandon (throttled once by the approved begin quota, kept, then confirmed) → a new battle is allowed.

### Mutation check (deterministic test sensitivity)

Each mutation was applied temporarily and then reverted:

| Mutation | Result |
|---|---|
| `rate_limited` treated as final | test **fails** (4 checks) |
| a new key on every resend | test **fails** (4 checks) |
| EXP preview shown on the battle screen | test **fails** (3 checks) |
| adapter stale-answer guard disabled | test still passes: the shared client already turns an after-sign-out answer into UNCERTAIN/stale (S01 account epoch), so the adapter guard is defense in depth |

## Known risks

- **M1 (approved S2, TEST only):** a modified client can claim a false victory within the bounds. No production anti-cheat claim is made.
- **RAM-only pending (S6):** a result not yet recorded by the server is lost on an app kill. The player is told and can abandon explicitly; confirmed EXP is never lost.
- **SDK retry amplification:** the Nakama Godot SDK automatically retries a failed HTTP request (seen as 3 server requests per client call through the lossy proxy). Each server request is charged by the E1 limiters, so heavy loss can hit `rate_limited` (claim 12 / replay 30 per 60 s). The client keeps the result and resends later (shown in the live stress); it is never dropped.
- **Begin quota shared with abandon** (approved MC-2 Q1): a busy player can see the abandon throttled for up to 60 s; it is kept and resent.
- **Hero-only TEST battle uses Base + Growth** (S8): it differs from the offline Hero with allocation and equipment. This is by design.
- **The TEST launcher** (`run_online_combat_ui.sh`) uses the default compose project unless `COMPOSE_PROJECT_NAME` is set. For E3 hands-on it must be run with `COMPOSE_PROJECT_NAME=myrial-vs01-wp01e` to keep the WP01–C volume untouched.
- **No Godot CI.** Mac player acceptance (E3) is **not done**.

## Rollback

- Revert the E2 commit. All files are new except:
  - the additive `gameplay_rpc()` in `online_progress_client.gd`;
  - the isolation exemption lines;
  - the lossy-proxy claim branch;
  - two `run_live_tests.sh` blocks.
- Nothing in the server, Trade v1, the offline game or the Save changed, so nothing needs migrating back.
- Stop the disposable stack with `COMPOSE_PROJECT_NAME=myrial-vs01-wp01e docker compose --profile multinode stop` (never `down -v`).
