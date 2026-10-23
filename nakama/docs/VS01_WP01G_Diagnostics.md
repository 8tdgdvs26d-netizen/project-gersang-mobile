# VS-01 WP01-G Phase B — Diagnostic Record (D1–D5)

- **Repository / branch:** `8tdgdvs26d-netizen/project-gersang-mobile`, branch `wp01-g-diag-review`, created from `main` `35932e1a05b95747f46c3b385501dba609795b62` (tree `4acee86eb9425654c3449e1f817315127a60dd25`).
- **Design source:** WP01-G Phase B Diagnostic Engineering Approval 1 Proposal **r2.1** (zip SHA-256 `3a43af3dec3ec4525cbf6886f92cf4a582a4b55cb8c5ee73c225a268fcb66057`), built on the GPT-accepted Phase A RCA r2 and the Charlie-approved WP01-G v0.1 Blueprint.
- **Authorization:** Charlie, Approval 1 (implementation of exactly the four new files below, local checks A1–A8; one commit fast-forward pushed to `wp01-g-diag-review` only after a GPT Diff Review PASS). Phase B uses the narrower diagnostic test scope approved for Phase B only.
- **Not authorized here:** creating or updating `wp01-g-diag-execution` (that is Charlie Approval 2 for one exact commit SHA), any Cloud Run, PR, Merge, change to `main`, change to any existing file.
- **What this is NOT:** acceptance. A diagnostic result is never a T1–T4, Deadline-late or WP01-G PASS and does not lower any formal WP acceptance requirement. Full Normal Regression is done in Phase C.

## Purpose and player value

The live T2 case (server accepts the connection but never answers) did not return in run `39570895448`. Phase A (static RCA r2) found a STRONGLY SUPPORTED mechanism: with `use_threads = true`, the timeout path may wait for the HTTP worker thread on the main thread (H6). Phase B measures this at runtime on a disposable runner so that Phase C changes the shared client only with runtime evidence.

Player value comes later: in Phase C the game must stop waiting and show "not connected" instead of freezing, and must never show an old value as new.

## Status (kept separate)

| Status | Value |
|---|---|
| Designed | Proposal r2.1 GPT DOCUMENT REVIEW ACCEPTED; Approval 1 Charlie approved |
| Implemented | four new files on the local review branch; rev5 after GPT Diff Review rounds 1 (B1, B2, B3, R1), 2 (S1, D1, D2), 3 (S1-A, S1-B) and 4 (S2); pending GPT Diff Review round 5 |
| Local checks A1–A8 | see the Diff Review delivery (not a Godot, Docker or Nakama run) |
| Diagnostic Cloud Run | **NOT RUN** (needs Charlie Approval 2) |
| T1–T4, Deadline-late ①②, WP01-G | **NOT RUN** (not part of Phase B) |
| Mac / iPhone / iPad / Playtest / Player Value | DEFERRED / PENDING |
| VS-01 System Gate | OPEN |

## Files (exactly four new files; no existing file changed)

| File | What it is |
|---|---|
| `godot/tests/diag_wp01g_http_modes.gd` | diagnostic harness (`extends SceneTree`), one case per process (`--case`), prints heartbeat / events / one result line; never writes a file or prints a secret |
| `nakama/scripts/run_wp01g_diag.mjs` | diagnostic runner: runner guard, run root, evidence identity, external fault server, 60 s hard cap, watchdog, read-only `/proc` snapshots, ownership-checked termination, redaction, secret scan, judgement, inventory, finalize, verify, `--selftest` |
| `.github/workflows/wp01g-diag.yml` | runs only on a push to `wp01-g-diag-execution`; `contents: read`; no secrets; 45 min job timeout |
| `nakama/docs/VS01_WP01G_Diagnostics.md` | this record |

Not changed: `godot/scripts/**` (including `online_progress_client.gd`), the Nakama SDK, `nakama/src/**`, `nakama/config/**`, `nakama/docker-compose.yml`, WP01-F launcher and workflow, `test.yml`, `nakama-server.yml`, `main`, Save, backups.

## The 11 cases (Proposal r2.1 §2.2)

Common: timeout 2 s (as T2); heartbeat `HB <seq> <ticks_ms>` every 250 ms on the main thread; a 2 s baseline before the request; the harness observes up to 45 s after the request (ends before the 60 s hard cap) and settles 4 s after the last completion.

| Case | Layer | `use_threads` | Fault | What it shows |
|---|---|---|---|---|
| D1-R | native `HTTPRequest` | true | stall | does the main thread stop at the timeout? |
| D1-S | SDK adapter created by `OnlineProgressClient` | true | stall | the same through the real client / adapter |
| D2-R | native | false | stall | does non-thread mode return `RESULT_TIMEOUT`? |
| D2-S | SDK adapter | false | stall | 3 attempts of about 2 s, timeout read-back (H4) |
| D3-R / D3-S | native / SDK | true | drop | fast failure (like T1) |
| D4-R-T | native | true | delay 3 s | about 1 s stall, then recovery; client completions |
| D4-R-F | native | false | delay 3 s | timeout at 2 s; no second completion |
| D4-S-F | SDK adapter | false | delay 3 s | 3 timeouts; a late reply is never taken as success |
| D5-F | client + Trade / Combat adapters, disposable Nakama | false | none | sign-in, session begin, Trade read, 1 buy, read again, Hero read |
| D5-T | same | true (current) | none | comparison |

S layer follows the T2 order: the client creates its adapter (as sign-in did), then `timeout_sec = 2` and `configure()` again, then `_get_client()`; the harness reads back `client._adapter.timeout` and the in-flight `HTTPRequest.timeout`. Internal members used, only in the harness: `_adapter`, `_get_client()`, `logger._level` (fail closed if missing). D5 sets `client._adapter.use_threads = false` only in the harness (D5-F); D5-T does not change it.

**Completion listener timing (R1).** The completion listener is attached before the request starts. R layer: `request_completed` is connected before `HTTPRequest.request()`. S layer: the harness connects the adapter's `child_entered_tree` before calling `send_async()`. Inside `send_async()` the SDK creates the `HTTPRequest`, sets `timeout` / `use_threads` and calls `add_child(req)` (`NakamaHTTPAdapter.gd` L146–L177); only afterwards does it run `_send_async()` → `make_request()` → `request.request()` (L179, L197, L71). Godot emits `child_entered_tree` synchronously inside `add_child()` (`node.cpp` L1711 → L1701 → `_propagate_enter_tree` L341 → L371). `HTTPRequest.request_raw()` also refuses a node that is not in the tree (`http_request.cpp` L125). At runtime the `listener_ready` event records the HTTP client status (must be `STATUS_DISCONNECTED`) and its event number (must precede the first `attempt_started`). If either check fails, the case is INCONCLUSIVE.

**Attempt timeline (B3).** An attempt start is the moment the SDK's `HTTPRequest` leaves `STATUS_DISCONNECTED`; the harness polls this once per frame on the main thread. For every attempt the runner records the actual attempt time (start → completion) separately from the retry backoff before it (previous completion → start), plus the time the request reached the server. If any start or completion is missing, the timeline is incomplete.

**Fault-server request evidence (B1).** A D1–D4 case counts only if the external fault server recorded a connection whose request line is that case's own URL (`POST /wp01g/diag/<case>`). Drop mode now cuts the connection only after the request head has arrived (fallback: 1 s after the first byte). A heartbeat stall alone never decides H1, H3, H5 or H6. The request must have reached the server before the stall began, and in stall mode the connection must still be open with no reply ("connected, no reply"). Missing evidence → INCONCLUSIVE.

D4 rule: a server `write()` succeeding does not mean the client accepted the late reply. Every D4 conclusion uses the client's completion events, the SDK return value and state; server records only align times.

## Watchdog: two separate mechanisms (Proposal r2.1 §4.1)

1. **Gap record (short stalls):** for every heartbeat the runner computes the gap on the Godot clock (`ticks_ms[i] − ticks_ms[i−1]`) and on its own receive clock. Every gap ≥ 500 ms (two heartbeat intervals) is recorded in `<case>-hb-gaps.json` with start, end, length and source (`godot` / `runner` / `both`); nothing is filtered or smoothed. A missing `seq` is recorded. A gap still open at termination is recorded as open. The gap length uses the Godot clock. **B2:** every recorded gap also carries the nearest client event before its start and after its end: event number `n`, name, Godot time, time difference, and identifying fields such as attempt, step or result. It also lists any client events inside the gap. Where no event can be associated (for example after an open gap), the field is `UNKNOWN`.
2. **Long-stall alert (unchanged threshold):** more than 1.5 s without a heartbeat (runner clock) starts a long stall; read-only `/proc` snapshots are taken 3 s and 6 s after the last heartbeat; the stall ends when a heartbeat arrives.

Baseline check: before the request the two clocks must agree within 100 ms; otherwise the alert and snapshot timing of that case is UNKNOWN (`flush_stdout_on_print` could not be verified statically) and gap lengths still use the Godot clock. A D4-R-T stall of about 1 s is below the 1.5 s alert, so D4-R-T has no `/proc` snapshot by design; thread evidence comes from D1.

## Judgement (Proposal r2.1 §2.4)

Only three levels: **STRONGLY SUPPORTED** (consistent, no other reasonable explanation found; not proof of the root cause), **NOT SUPPORTED** (inconsistent; not exclusion), **INCONCLUSIVE**. No CONFIRMED, REFUTED or VERIFIED. "About X" = X ± 0.5 s. H5 can never be STRONGLY SUPPORTED in Phase B. H6 is capped at STRONGLY SUPPORTED (no stack trace). The runner writes `judgement.json`; raw readings (read-backs, attempt counts, codes, times) are recorded as observed on this Linux runner only.

H1, H3, H5, H6 (D1): these use heartbeat stall timing, so each case they rely on must have a two-clock baseline of `OK`; `MISMATCH` or `UNKNOWN` → INCONCLUSIVE. The D4-R-T supporting observation is likewise `UNKNOWN` without an OK baseline.

H2 (D2): only direct evidence of a 4th attempt gives STRONGLY SUPPORTED — more than 3 requests with the case URL at the external fault server, or more than 3 attempt starts. An S-layer case that does not return while its R-layer case returns is not, by itself, evidence about retry / backoff → INCONCLUSIVE. NOT SUPPORTED needs D2-S and D3-S to return after exactly 3 server requests and 3 client completions.

H4 (B3): the timeout read-backs decide, never timing alone.

- STRONGLY SUPPORTED only if a complete read-back shows `client._adapter.timeout` ≠ 2, or an in-flight `HTTPRequest.timeout` different from it.
- If a read-back is missing → INCONCLUSIVE, whatever the timing.
- NOT SUPPORTED needs both read-backs = 2 and a complete 3-attempt timeline in which each attempt (start → completion, backoff excluded) took about 2 s.
- Read-backs = 2 with an incomplete timeline or non-matching durations → INCONCLUSIVE.

## Safety

- Runner guard: `GITHUB_ACTIONS=true`, `RUNNER_ENVIRONMENT=github-hosted`, Linux, absolute `RUNNER_TEMP`; otherwise exit 3. Bad arguments: exit 2.
- Evidence: `$RUNNER_TEMP/wp01g-evidence` with recorded device/inode; exclusive no-follow writes; manifest and independent verify.
- Godot sees only `PATH`, `LANG`, `HOME`, `XDG_*`, `TMPDIR` inside the run root (the Proposal r2.1 allowlist; the rev3 ownership token was withdrawn in rev4); the probe proves `user://` is inside it.
- Termination (Proposal §4.2; conservative design after Diff Review round 3). Every process is spawned detached (`setsid`), so its process group = session = its pid. `realSignal()` is the only `process.kill` call.
  - **Who gets a signal:** only the spawned leader pid itself (a positive pid > 1) — never a process group, never `-pgid`, 0, -1 or 1.
  - **When:** before each SIGTERM / SIGKILL the leader is proven from `/proc`: not reaped (no `exit` event, so its pid cannot have been reused), same pid, process group = session = pid, same start time, same executable (the verified Godot binary for Godot cases), and the runner's real and effective uid. Not proven → no signal, Safety FAIL → STOP. The pid is re-checked before SIGKILL too, so a reused pid is never signalled.
  - **Survivors:** a process still in the leader's process group after the leader exited, or a leader still running after the bounded wait, is **never signalled**. Its inventory (pid, start time, group, session, uid / euid, state, exe, comm, reason) is recorded and the run takes Safety FAIL → STOP. Survivors are never reported as a normal completion: the step fails, and survivors at the end of the run are also a Safety STOP.
  - **Testing:** the decision flow (`terminateFlow()`, `checkSurvivors()`) takes its effects as parameters, so A8 runs it with fakes; `process.kill` is trapped during the selftest.
- Safety STOP propagation (S2). A shared guard (`safetyGate()`) runs at every step boundary: before and after every preparation / test step (`makeStep()`), before the work root, the probe, every fault-server case, the D5 preparation, the Nakama port and health checks, and every D5 case. After any Safety / Isolation FAIL it raises `SafetyStop`, so no further ordinary diagnostic, preparation or test step starts. Only the audit, the inventory and the evidence finalization still run. The top result is decided by `decideTopResult()`: any Safety FAIL (or an unclean final secret scan) gives `DIAG_STOPPED_SAFETY` and never `DIAG_COMPLETE`.
- Secrets (Proposal §6.1): one rule set for redaction and scanning — S1 this run's passwords, S2 JWT shape, S3 `Authorization` followed by `:` / `=` and a value, S4 `Bearer` + token, S5 `Basic` + base64. A bare header name (the fault server stores header names as a JSON string array) is not a hit. Every child line is assembled whole, redacted, and only then written to evidence and to the console (job log); no `inherit`, no `tee`. Any hit (in the stream or in the final scan) is a Safety FAIL; the artifact is not uploaded.
- The SDK logger is forced to ERROR and asserted before any SDK request; the harness prints only codes, timings, counts and numeric progress fields; no container log is collected.
- Nothing is deleted: no Compose `down`, no volume removal, no run-root cleanup; the inventory only lists leftovers. The disposable runner is discarded by GitHub; that is not a cleanup PASS.

## Evidence files (per run)

`environment.txt`, `runner.log`, `summary.json`, `run-state.json`, `NNN-<step>.log`, and per case `<case>-godot.log`, `-heartbeat.json`, `-hb-gaps.json`, `-client-events.json`, `-server-events.json` (D1–D4), `-proc.json`, `-exit.json`; `judgement.json`, `secret-scan.json`, `inventory-runner.log`, `leftover-inventory.json`, `final-audit.json`, `manifest.json`. Top-level result: `DIAG_COMPLETE`, `DIAG_INCOMPLETE` or `DIAG_STOPPED_SAFETY` (never PASS).

## Limits

- Linux GitHub runner only; iOS / macOS behaviour may differ (Mac and device acceptance remain DEFERRED / PENDING).
- `/proc` snapshots are indirect evidence; `wchan` / `syscall` may be unreadable (UNKNOWN).
- The new runner re-implements the WP01-F launcher safety design (duplicated code; reviewed separately).
- A8 (`--selftest`, synthetic data only) covers the secret rules, the gap computation, the gap ↔ client event correlation, the termination decision flow (leader refusal paths, leader-pid-only signal targets, pid reuse between SIGTERM and SIGKILL, survivors never signalled, survivors never a normal completion; process.kill trapped), the Safety STOP propagation (a step after a Safety FAIL is never called; top result STOPPED_SAFETY) and the judgement guards (baseline gate, H2 direct-evidence rule, kept B1 / B3 rules) on synthetic case facts. The live `/proc` reading, termination timing, fault server and full judgement on real runs are checked by Diff Review and against the raw evidence.
- Attempt starts are seen at frame resolution; an attempt that starts and ends inside one frame leaves the timeline incomplete (H4 → INCONCLUSIVE).

## Results

Pending: filled in only after a Charlie-approved diagnostic run (Approval 2).

## Rollback

The four files exist only on `wp01-g-diag-review`; `main` is unchanged. Rollback = do not use the branch (or revert its single commit). Whether the diagnostic tools are ever merged into `main` is a separate decision.
