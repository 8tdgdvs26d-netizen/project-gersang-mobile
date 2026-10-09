# VS-01 WP01 — Test Evidence and Rollback Plan

Branch `claude/vs01-wp01-nakama`, from `main` `3774aefacfb92736c63034c51565aa4e675d3aeb`.
Evidence recorded on the Mac (Docker Desktop 29.8.2, Godot 4.7.2.stable,
Node 24.21.0) on 2026-10-10. The final live run used commit `d40b82b`.
The evidence commit adds documentation only.

## Status labels

| Label | State |
|---|---|
| Designed | Approved Blueprint + D1–D6 (Charlie, 2026-10-10) |
| Implemented | Yes, on this branch (not merged) |
| Automated Tests Passed | Yes, local (see below) |
| CI Passed | See the PR checks. The `test` workflow is Node / npm CI; `nakama-server-unit-tests` is Node server unit tests. **No Godot CI exists.** |
| GPT Accepted / Mac Accepted / iPhone Accepted / iPad Accepted / Playtested / Player Value Verified | **PENDING** |
| Sign in with Apple on device | **PENDING** (needs native plugin + Apple Developer setup; rejection paths only) |

## Results

| Suite | Command | Result |
|---|---|---|
| Godot full normal regression, **baseline** `main` 3774aef (isolated `user://`) | `HOME=$(mktemp -d) godot/tests/run_tests.sh` | 65 / 65 scripts PASS |
| Godot full normal regression, **branch** (isolated `user://`) | `nakama/scripts/run_godot_regression_isolated.sh` | 66 / 66 scripts PASS (65 existing + `verify_vs01_wp01_online_contract`, 111 checks) |
| Node / npm CI suite (existing) | `npm test` (repo root) | 508 / 508 PASS |
| Nakama server unit tests | `cd nakama && npm ci && npm test` | 26 / 26 PASS |
| Live stress + restart (local Nakama 3.25.0 + PostgreSQL 16) | `nakama/scripts/run_live_tests.sh` | 9 / 9 PASS |
| Live Godot SDK probe (Nakama Godot SDK v3.4.0) | same script | 34 / 34 checks PASS |

Unit-suite strength check: deliberately breaking each rule (spread %, market
stock limit, cargo limit, receipt create-only, session check, rate limit,
receipt-only rejection) makes at least one test fail.

Live stress covers:
- 20 concurrent distinct orders: all applied, ledger exact.
- 20 concurrent identical keys: 1 original + 19 replays, applied once.
- 8 racing session takeovers: exactly one writer.
- 10 accounts in parallel: isolated, each ledger exact.
- 300-command soak with 20 % duplicate retries: one receipt per key, ledger exact.
- Requests aborted client-side: retries resolve exactly once.
- Forged price / money / action / quantity: refused. Guest (device / custom)
  auth: refused. Reading or listing another account's data: empty. Client
  storage writes: refused. Combat reward claims: refused.
- Rate limit, 45-request burst: 11–14 throttled, 31–34 applied (limit 30,
  approximate; documented).
- Server restart with a command in flight: confirmed state kept, the
  uncertain command applied exactly once after retry, and the session still
  usable (no forced reset or death).

"Ledger exact" means the final server money and goods equal a re-computation
from all receipts with the TypeScript rules, receipts chain with no gaps, and
every applied price matches the rules.

## Protection checks

- Development Save `user://myrial_save.json`: v8, SHA-256
  `59fcf77a88a98b966166485ce4078c036a6ade747db4c07f7a41b635663531f7`, mtime
  unchanged before and after all runs.
- All Godot runs used an isolated `HOME`, so `user://` was never the normal
  user data folder.
- `main` still `3774aef`; PR #131 head still `a1165aa` (Draft, not touched).
  Both local stashes are kept. The Nakama spike source in
  `/tmp/myrial-nakama-spike-20261009` and its stopped containers and volume
  are untouched.
- No existing tracked file is modified by this branch (additions only).

## Rollback plan

1. **Before merge:** close the PR. `main` is unaffected.
2. **After a merge (only with Charlie's approval):** `git revert` the merge
   commit, or the individual commits. Every commit is additive, so a revert
   removes files and changes no existing behaviour.
   - Docs only: `VS-01 WP01: document ...`
   - Live tests / scripts: `VS-01 WP01: add live stress, restart and Godot SDK probes`
   - Godot client + offline test: `VS-01 WP01: add the isolated Godot online progress client`
   - SDK: `VS-01 WP01: vendor the Nakama Godot SDK v3.4.0`
   - Server tests + workflow: `VS-01 WP01: add server unit tests and GDScript golden vectors`
   - Server: `VS-01 WP01: add Nakama TypeScript server for the trade authority path`
3. **Local data:** `cd nakama && docker compose stop` keeps the data.
   `docker compose down -v` in `nakama/` removes **only** this project's
   volume `myrial-vs01-wp01_pgdata` (disposable test accounts).
4. Nothing to roll back on the Save or the Development Save: neither is
   changed.
