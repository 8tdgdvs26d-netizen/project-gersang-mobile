# VS-01 WP01-F — Online Progress Resume Mini Slice: Implementation and Evidence Record

- **Repository / branch:** `8tdgdvs26d-netizen/project-gersang-mobile`, branch `wp01-f-cloud-workflow-review`.
- **Base `main`:** `39a2a1fcd330d9c9a7b89f0d564627bbea5e54f0` (reverified 2026-10-22). The branch adds the approved workflow (`5229e35`), this WP's six new files (`6a11724`) and the corrective history below. Commit `4262ac3` also changed one file already on `main`, `godot/tests/verify_vs01_wp01_online_contract.gd`, by adding one allowlist line; the earlier “no existing main file changed” statement was incorrect.
- **Authorization:** Charlie, 2026-10-20 HKT: WP01-F v0.1 Blueprint and its minimal engineering scope (three clarifications; Stress Level **TARGETED**; Gate X / FS-08 not part of this WP); disposable GitHub-hosted runner only, never the Mac `myrialtest` account; workflow approved after GPT and Claude review.
- **Not authorized here:** first run (creating / updating `wp01-f-cloud-execution`), PR, Merge, deployment.
- **Player value:** after closing and opening the app again, the same account gets its money, goods and Hero Level / EXP back from the server, so progress lives on the server and not on the phone.

## Status (kept separate)

| Status | Value |
|---|---|
| Designed | Blueprint v0.1 approved (Charlie) |
| Implemented | WP01-F original Core feature at `e2bb532`; v0.2 Core-only launcher/workflow amendment implemented locally, pending GPT Diff Review |
| Automated Tests Passed | Historical third run contains Core PASS evidence; new v0.2 Core acceptance **NOT RUN** |
| CI Passed | Runs `39462337861`, `39546294113`, `39570895448` are permanently **FAIL**; no v0.2 PASS claim |
| GPT Accepted | **PENDING** (pre-execution review) |
| Mac Accepted | **DEFERRED** to before VS-01 System Gate (Charlie approved); not PASS |
| iPhone / iPad Accepted, Playtested, Player Value Verified | **PENDING**, not part of this run |
| VS-01 System Gate | OPEN |

## Files (whitelist: exactly the six approved new files)

| File | What it is |
|---|---|
| `godot/scenes/online_progress_resume_test_mode.tscn` | isolated Online TEST scene; not the main scene, not an autoload |
| `godot/scripts/online_progress_resume_test_mode.gd` | the screen: one shared `OnlineProgressClient`, the existing `OnlineTradeAdapter` and `OnlineCombatAdapter`; **reads only** (no trade, no claim, no RPC call of its own, no local save) |
| `godot/tests/verify_vs01_wp01f_resume_mode.gd` | fake-client unit test, part of the normal Godot regression |
| `godot/tests/live_vs01_wp01f_online_progress_resume.gd` | live test with phases `probe`, `seed`, `readback`, `stress`, each run as its own Godot process |
| `nakama/scripts/run_wp01f_bounded.mjs` | bounded launcher called by `.github/workflows/wp01f-cloud.yml` |
| `nakama/docs/VS01_WP01F_Online_Progress_Resume.md` | this record |

No new RPC, schema, collection, Save change or migration. The branch adds the separately approved WP01-F workflow and contains the one existing test-allowlist change at `4262ac3` disclosed above; `main.gd` and the normal UI are untouched.

## The two revisions (clarification 1)

Trade progress (`vs01_progress_get`, money / goods) and Hero progression (`vs01e_progression_get`, Level / EXP) are separate server contracts with separate revisions:

- Trade revision: **every `vs01_session_begin` raises it by 1** (server `rpcSessionBegin`), so a read-back after a new session expects `seed + 1`, with money and goods unchanged.
- Hero revision: not moved by a session begin; a read-back expects **the same** revision, Level and EXP.

The screen shows each value with its own revision and never merges them.

## Real fresh runtime (clarification 2)

The launcher runs `seed`, then `readback`, as **separate Godot processes**, one after the other. A phase starts only after the previous process ended and its process group was checked for survivors. Each phase prints a random nonce and its process id; the launcher (not Godot) compares results across processes. The read-back process starts with an empty memory cache, signs in **without creating** the account (`create = false`) and gets every value from Nakama. Credentials come from the environment, never from `user://`, v14 or any local Save.

## v0.2 test plan

Every non-inventory acceptance invocation must state `--scope core` or `--scope full`; missing, empty, duplicate, or unknown scope fails before any test or write. The approved workflow states `--scope core`. `summary.json` records the scope, complete planned stages and transferred cases before `git-head`.

**Order (STOP at the first failure; later steps are NOT RUN):**

1. Preflight: source SHA, clean checkout, run-owned work root and sentinel.
2. Full Normal Regression:
   - Node root project tests (`npm test`); **Node, not Godot**.
   - Nakama build and unit tests (`npm ci`, `npm test`); **Nakama unit (Node), not Godot**.
   - Godot `--import`, then a user-data-folder probe: Godot's own `OS.get_user_data_dir()` and `ProjectSettings.globalize_path("user://")` must be inside the run root, and Godot must be 4.7.2.
   - Every `godot/tests/verify_*.gd` (71 existing + 1 new) as **its own Godot process with its own timeout**, using the `run_tests.sh` pass rules (exit 0, own success line, no parse / script error, no `FAILED:`).
3. One Docker Compose project named after the run (`-p wp01f_<run id>`, its own PostgreSQL volume), only `postgres` + `nakama`.
4. Live Core phases:

| Step | Process | Checks |
|---|---|---|
| seed | Godot #1 | new disposable account; server-confirmed buy (10 x `test_good_01`); server-confirmed Hero EXP from one encounter; nothing pending |
| readback | Godot #2 (fresh) | empty memory before sign-in; same account; both contracts confirmed; then sign-out + sign-in again in the same process |
| restart | docker | `compose restart nakama`, wait healthy |
| readback | Godot #3 (fresh) | same checks after the server restart |

5. Cross-process comparison by the launcher:

| ID | Rule |
|---|---|
| C01 | different process id and nonce for seed / readback / after-restart |
| C02 | the same Nakama user id |
| C03 | money and goods equal (seed vs readback) |
| C04 | Trade revision = seed + 1 |
| C05 | Hero Level, EXP, EXP-to-next equal |
| C06 | Hero revision equal |
| C07 | re-login in the same process: values equal, Trade revision + 1 |
| C08 | after the Nakama restart: values and Hero revision equal, Trade revision + 1 |

6. C01-C08 run immediately after restart readback and before any stress phase. Any comparison failure stops the run.
7. In `core`, T1-T4 are each recorded `NOT RUN / TRANSFERRED TO WP01-G`; the stress phase and second account are not started. In `full`, the targeted stress phase remains available for later separately approved WP01-G use.
8. Acceptance audit runs after PASS or ordinary FAIL: `git status --porcelain` must be empty and every process group created by this run must report no survivor. Audit sends no signal and deletes nothing.

**Transferred targeted stress (T1-T4; not run by v0.2 Core):**

| Case | How | Expected |
|---|---|---|
| T1 read dropped mid-request | local port that accepts the request, then cuts the connection | uncertain; never "confirmed"; last confirmed values kept; correct after reconnect |
| T2 server timeout | local port that accepts and never answers (client timeout 2 s) | same as T1 |
| T3 Session takeover (policy A) between two independent clients | a second `OnlineProgressClient` in the same Godot process signs in to the same account and begins a session | first device told, offered reclaim, shows nothing new; reclaim reads both again; the second device is then the superseded one |
| T4 late answer after sign-out | a read in flight, then sign-out | answer reported stale; never reaches the screen |
| sign-out and re-login | readback phase | values equal, Trade revision + 1 |
| server restart | launcher, between the two read-backs | values persist in PostgreSQL |

T3 proves policy A between two independent clients of one account. It is **not** a real two-device (iPhone + iPad) acceptance. T4 uses a real in-flight request; the deterministic, controlled late SUCCESS answer is covered by unit case R3.

The fake-client unit test additionally covers: nothing confirmed before the server answers, partial reads, an older revision never replacing a newer one, an account switch on one client, and a sign-out while the sign-in is still in flight (R8: the late success is undone, a second sign-in cannot overlap).

## Safety boundaries (clarification 3, F2 class)

- **Where:** refuses to start unless `GITHUB_ACTIONS=true`, `RUNNER_ENVIRONMENT=github-hosted`, Linux and an absolute `RUNNER_TEMP`. It cannot run on a Mac account.
- **Isolation:** Godot gets only `PATH`, `LANG`, `HOME`, `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `XDG_CACHE_HOME` and `TMPDIR`, all inside the run root (plus the account variables for live phases). The run root is re-checked before every Godot process.
- **Timeouts:** every child command has its own timeout and its own process group; a timed-out group gets TERM, then KILL while its leader still runs. Survivors are checked right after each child ends.
- **No secret in logs:** random per-run passwords, passed only through Godot's environment and redacted from every log; synthetic `.invalid` e-mail addresses.
- **No deletion at all (corrective C1):** the launcher deletes nothing: no `rm`, no `fs.rmSync`, no `docker compose down`, no volume removal. After the run (and in the workflow's always-run step, `--inventory-only`) it only LISTS what this run left: its Compose project's containers / volumes (by Compose label) and its recorded work root (identity re-checked). Everything stays on the disposable GitHub-hosted runner, which GitHub discards after the job. Leftovers are reported as PRESERVED, never as cleaned, and this is **not** a Gate X / FS-08 PASS.
- **Path containment fails closed (corrective C2):** a path counts as inside the run root only if the canonical path of the path itself, or of its nearest existing ancestor, is inside; any resolution error is a failure. Before the first Godot process (the import) the launcher proves HOME / XDG_* / TMPDIR are real directories inside the root. The import must still run before the user-data probe, because the probe script needs the class cache the import writes.
- **Not used:** `run_live_tests.sh`, `run_godot_regression_isolated.sh`, `run_tests.sh`, `test_run_godot_regression_isolated.sh`, `runner_selftest.sh`, the lossy proxy, the fixed `myrial-vs01-wp01` Compose project.
- **Known F2-class finding in `main` (not fixed here, out of scope):** `nakama/scripts/test_run_godot_regression_isolated.sh` still builds `repo="$(mktemp -d)/repo"` without checking `mktemp` and later runs `rm -rf "$(dirname "$repo")"` (lines 24 and 62). If `mktemp` failed this becomes `rm -rf /`. This WP never calls it.

## Limitations

- The live run uses Linux Godot 4.7.2 on a GitHub runner, not Mac or iPhone.
- The Hero is seeded through the existing E1 contract with one test-driven Hero-only battle (as the WP01-E live test does), so a seed takes at least 10.5 s (server minimum battle age).
- The survivor check reads the process group right after its leader ended; a process that leaves its group is not seen. The runner is discarded after the job.
- The existing WP01-B / C / E live harnesses are not re-run: they assume the fixed Compose project name.
- The existing Online Combat / Trade TEST modes have the same sign-in-in-flight race fixed here in the Resume mode (R8); not changed (out of scope).

## Evidence and final gate

Every evidence leaf is created by its owning process with `O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW`, mode `0600`, then checked with `fstat`. Append or replacement continues only through that same open file descriptor; before every write, the evidence directory and leaf device/inode are rechecked. No evidence path is reopened for writing, and the workflow does not use `tee` to write evidence.

The workflow writes `environment.txt`, `docker-version.log`, `godot-version.txt`, `wp01f-console.log` and `leftover-inventory.log` through the safe writer. If argument validation, runner guard, initial directory validation, exclusive open, post-open `fstat`, or a later write check fails, evidence-file writing stops but stdin is still drained and forwarded to the job log before exit 2, 3, or 7. This preserves upstream output without allowing the job to pass.

Acceptance owns `launcher.log`, `summary.json`, `run-state.json` and numbered step logs. Inventory always runs when the evidence environment exists, owns `inventory-launcher.log`, numbered inventory logs and `leftover-inventory.json`, and returns its real result rather than swallowing failure.

Finalize reads the acceptance and inventory outcomes, classifies every hidden or non-regular entry as an anomaly without following or reading it, writes those details into `final-audit.json`, and creates `manifest.json` last. The manifest includes every other safely readable ordinary evidence file, including both console logs and `final-audit.json`, with byte size and SHA-256, plus the anomaly names and reasons. Verify is read-only and independently checks directory identity, the exact file set, sizes, hashes and an empty anomaly list. Any anomaly makes Finalize and Verify fail and prevents upload. Only verify exit 0 sets `upload_safe=true`; an ordinary acceptance FAIL with safe, complete evidence can therefore upload failure evidence, while an evidence safety/audit failure cannot upload. The final gate prints and preserves the original acceptance, inventory, finalize, verify and upload outcomes and fails if any required result is not successful.

## Rollback

Before any approved commit or push, discard this three-file local amendment to return the detached workspace exactly to `e2bb532`. After an approved push but before Merge, rollback requires a Charlie-authorized revert commit on the review branch, preserving fast-forward history; do not force-push. Abandoning the whole unmerged branch also removes its separately added workflow, six WP files and the existing test-allowlist change. Deleting only the six WP files is not a complete rollback. No schema, migration or data rollback exists or is needed. Test data lives only in the disposable runner's Compose volume and run root.

## Corrective patch (GPT pre-execution review, 2026-10-20)

| Review item | Change |
|---|---|
| B01 cleanup failure could look like PASS; B02 cleanup ownership | **C1:** all deletion removed. Inventory only; leftovers PRESERVED for runner disposal. Nothing can be reported as "cleaned". |
| B03 limited first run not separated | Not changed: needs Charlie's decision (see the report). |
| H04 `inside()` fail-open; import before probe | **C2:** containment fails closed (nearest existing ancestor); isolation proven before the import; the order import -> probe is required and documented. |
| H05 workflow root lockfile | **C3:** `cache-dependency-path: nakama/package-lock.json` only; the always-run step renamed to the inventory step (`--inventory-only`). Workflow needs a renewed static review. |
| M06 stale / late coverage | **C4:** Resume mode undoes a late sign-in success after a sign-out and blocks overlapping sign-ins; unit case R8. T3 / T4 claims narrowed (above). |

## Corrective history and v0.2 Core-only amendment

| Commit / state | Record |
|---|---|
| `149845f` | Earlier corrective implementation retained for traceability. |
| `4262ac3` | Added one WP01-F allowlist line to the existing online contract verification file; corrects the former “no existing main file changed” claim. |
| `e2bb532` | Current review/execution baseline before this v0.2 amendment; retains in-flight resume adapters and bounded waits. |
| v0.2 Core-only | Explicit scope, C01-C08 before stress, T1-T4 transferred, `PASS_CORE_SCOPE`, safe writer, final audit/manifest/verify, and final job gate. Approval 2 Cloud Run remains separate and is not authorized by this document. |
