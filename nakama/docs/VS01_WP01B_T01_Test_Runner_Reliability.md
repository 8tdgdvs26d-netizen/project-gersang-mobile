# VS-01 WP01-B-T01 — Godot Test Runner Reliability: Evidence

- Repository: `8tdgdvs26d-netizen/project-gersang-mobile`
- Branch: `claude/vs01-wp01b-t01-test-runner` (own worktree, from `main`; not
  mixed into PR #133)
- Base `main`: `1321ca3590e7e019d450571583932439b31b72ef` (CP-008)
- Code commits: `e7d632b` (runner + self-test) and `cdbf957` (self-test also
  checks the wrapper). The commit after them adds only this document.
- Approval: Charlie approved the T01 Blueprint and the T01-only bounded
  implementation on 2026-10-10 (Current Status). S01 is NOT authorized and
  was not touched.
- Mac: Godot 4.7.2.stable. Recorded 2026-10-10.

## Root cause

`godot/tests/run_tests.sh` decided PASS / FAIL from Godot's exit code alone.
On Godot 4.7.2 that code is not proof:

| Situation | Godot's behaviour (measured) | Old runner |
|---|---|---|
| The test script fails to parse | exits **0**, the test never runs | **PASS** |
| Script error inside an awaited coroutine | the coroutine stops, the caller continues, prints its success line, exits 0 | **PASS** |
| Test exits 0 without any success line | exit 0 | **PASS** |
| Test prints `FAILED:` but exits 0 (buggy test) | exit 0 | **PASS** |
| Runtime error / failed `assert` in a SYNCHRONOUS function | the function stops before `quit()`; **Godot never exits** (hangs) | hangs, never reports (see the risks section) |

## Existing success contract (audited before changing anything)

A full-output audit of all 66 `verify_*.gd` on unmodified `main` (each
test's complete output, isolated `user://`):
- every test prints exactly one success line containing `verification passed`;
- 62 print it inside `if _failures == 0:`. The 4 assert-based tests
  (`m1_03`–`m1_06`) print it as the last step after their asserts;
- failures are reported as `push_error("FAILED: …")` (62 files, shown as
  `ERROR: FAILED: …`) or `print("FAILED: …")`;
- no normal output contains `SCRIPT ERROR`, `Parse Error` or a line starting
  with `FAILED:`;
- **but** `verify_s10_p01_recovery` legitimately prints the reason code
  `ERR_SAVE_FAILED` in its stress summary. A naive "any FAILED text" rule
  would break a passing test, so the rule is anchored to line start.

No existing test needed a change. The acceptance standard is not lowered:
the rules only refuse more.

## Fix (`godot/tests/run_tests.sh`)

A script passes only if ALL hold:
1. it exits 0;
2. it prints its own success line, a line containing `verification passed`
   that is not itself a failure line;
3. no line contains `SCRIPT ERROR` or `Parse Error`;
4. no line starts with `FAILED:` or `ERROR: FAILED:`.

Otherwise the result is `FAIL <name> (<reason>) | <summary>`, with reason
`exit N`, `exit 0; script or parse error`, `exit 0; test reported FAILED` or
`exit 0; no success line`. Unchanged: the import step, test discovery
(`tests/verify_*.gd`, or names as arguments), the `PASS <name> | <summary>`
line format, the final lines and the exit codes (0 all pass, 1 any failure,
2 import problem).

New: `godot/tests/runner_selftest.sh`. It builds a throw-away Godot project in
a temporary folder with fixture tests (never in this project, so it cannot
affect the regression or an export), runs a given runner and wrapper against
them with an isolated `HOME`, and checks every verdict and exit code.

## Before / after reproduction (`runner_selftest.sh`)

| Fixture | Expected | Old runner (`1321ca3`) | New runner |
|---|---|---|---|
| A normal test | PASS | PASS | **PASS** |
| B parse error | FAIL | **PASS** (false) | **FAIL** |
| C script error in a coroutine (still prints success, exit 0) | FAIL | **PASS** (false) | **FAIL** |
| D exit 0, no success line | FAIL | **PASS** (false) | **FAIL** |
| E1 `FAILED:` + exit 1 | FAIL | FAIL | **FAIL** |
| E2 `FAILED:` + exit 0 | FAIL | **PASS** (false) | **FAIL** |
| E3 `FAILED:` + success line + exit 0 | FAIL | **PASS** (false) | **FAIL** |
| E4 success words only inside a `FAILED:` line | FAIL | **PASS** (false) | **FAIL** |
| Runner exit, all pass | 0 | 0 | **0** |
| Runner exit, a batch with B | 1 | **0** (false) | **1** |

Old runner: 7 mismatches. New runner: 0. Command:
`GODOT=… sh godot/tests/runner_selftest.sh [runner] [wrapper]`.

## Results

| # | Test | Command | Result |
|---|---|---|---|
| A–E | Fixture verdicts + runner exit codes | `GODOT=… sh godot/tests/runner_selftest.sh` at `cdbf957` | **PASS**: 8 / 8 fixtures, 2 / 2 runner exit codes |
| F | Godot full normal regression (new runner, isolated `user://`) | `GODOT=… sh nakama/scripts/run_godot_regression_isolated.sh` at `e7d632b` | **PASS 66 / 66**, FAIL 0, exit 0; 66 / 66 lines carry `verification passed` |
| G | WP01 wrapper compatibility (`main`'s `run_godot_regression_isolated.sh`) | same self-test, wrapper section | **PASS 5 / 5**: exit 0 when all pass; exit 1 with each of B, C, D, E2 |

`run_tests.sh` is identical in `e7d632b` and `cdbf957`. The full regression
ran once on `e7d632b`; `cdbf957` changes only the self-test, and its final
run is the A–E and G evidence. No Godot CI exists; these are local Mac tests.
GitHub CI (`test` = Node / npm CI; `nakama-server-unit-tests` = Node) does not
run Godot. No Node, Nakama, gameplay or save file changed in T01.

## Finding outside T01: PR #133's strict wrapper masks failures

The strict wrapper in PR #133 (`claude/vs01-wp01b-online-trade`, not on
`main`) runs `run_tests.sh … | tee "$OUT"` and then reads `STATUS=$?`. In
POSIX `sh` that is **tee's** exit code. Measured:
- with the OLD runner, one ordinary failing test (`FAILED:` + exit 1):
  the wrapper prints "1 test script(s) failed" and **exits 0**;
- with the NEW runner, the broken fixtures B, C, D and E2 become FAIL lines
  and that wrapper **exits 0** (4 self-test mismatches). With the old runner
  it caught them only because they appeared as PASS lines.

PR #133's recorded results are still valid: they were read from the PASS /
FAIL lines (67 / 0), not from that wrapper's exit code. But the wrapper's exit
code is unreliable, and merging T01 and PR #133 as they are would let that
wrapper report success for failing runs. **Not changed here** (no mixing
into PR #133): needs a GPT / Charlie decision, for example a one-line fix in
PR #133 that keeps the runner's exit status.

## Development Save

| | SHA-256 | mtime | size | version |
|---|---|---|---|---|
| Before (preflight and before the final runs) | `59fcf77a88a98b966166485ce4078c036a6ade747db4c07f7a41b635663531f7` | 1790568901 | 2052 | 8 |
| After all runs | `59fcf77a88a98b966166485ce4078c036a6ade747db4c07f7a41b635663531f7` | 1790568901 | 2052 | 8 |

Every Godot run used a temporary `HOME` (the wrapper's `mktemp -d`, the
self-test's own temporary folder, or the audit's scratch folder), so the
normal user data folder was never `user://`.

## Known risks

1. **Hang, not false PASS:** a runtime error or failed `assert` in a
   synchronous test function stops it before `quit()`, and Godot never exits.
   The runner then waits forever. This is not a false PASS (nothing is
   reported), but the runner has no time limit. A per-test timeout would need
   a value choice and a portable timer on macOS (no `timeout` command), so it
   was left out of T01 scope. Option for a later decision.
2. The success contract is the text `verification passed`. A NEW test must
   print it (all 66 existing tests do), or it will FAIL with
   "no success line". This is intended fail-closed behaviour; it should be
   written into the test conventions.
3. Failure lines are recognised at line start (`FAILED:` /
   `ERROR: FAILED:`), matching the current conventions. A test reporting
   failures in another format and still exiting 0 would only be caught if it
   also lacked its success line.
4. PR #133's wrapper exit-code defect (above) is open.

## Rollback

- Before merge: close the PR; `main` is unaffected.
- After a merge (only with Charlie's approval): `git revert` the merge commit,
  or `cdbf957` / `e7d632b`. Reverting `e7d632b` restores the exit-code-only
  runner and its false PASSes. No data, save or test content is involved.
