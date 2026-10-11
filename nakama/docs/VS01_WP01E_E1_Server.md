# VS-01 WP01-E — E1 Server (isolated Online TEST): Evidence

- **Repository / branch:** `8tdgdvs26d-netizen/project-gersang-mobile`, branch `claude/vs01-wp01e-combat-exp` (own worktree `myrial-vs01-wp01e`, from `main`).
- **Base `main`:** `43006811111dc3d603c2aa3c339a1a37ca1fd65b`, verified with `git fetch` on 2026-10-11.
- **Authorization:** Charlie, 2026-10-11 HKT, WP01-E E1–E3 implementation (isolated TEST). Schema v1 design approval, including the current-Level EXP correction. ACK-1 conditional; ACK-2 / ACK-3 / ACK-4.
- **Design decisions preserved:**
  - **S-series:** S1 Option A, S2 M1 (TEST only), S3, S4 Hero-only, S5, S6 RAM-only, S7, S8.
  - **R-series:** R-1, R-2, R-3, R-4.
  - **MC-1 Option C** and **MC-2 Q1+F3**.
- **Stage:** E1 (server) only. E2 (Godot TEST scene) and E3 (Full Stress, Mac hands-on) are **not started**. **No PR** (not authorized).
- **Mac:** Godot 4.7.2.stable, Node 24, Docker Desktop, Nakama 3.25.0, PostgreSQL 16 (local only).

## Preflight

| Item | Result |
|---|---|
| `main` | `4300681`, clean |
| CP-008 | closed (Checkpoint Index); unchanged |
| Development Save v8 SHA-256 | `59fcf77a88a98b966166485ce4078c036a6ade747db4c07f7a41b635663531f7` (mtime 1790568901, size 2052) before and after every run |
| Isolation | new worktree; Godot runs with an isolated HOME (`user://`); a **separate, disposable** Docker project `COMPOSE_PROJECT_NAME=myrial-vs01-wp01e` (its own volume `myrial-vs01-wp01e_pgdata`; the WP01–C volume `myrial-vs01-wp01_pgdata` is not touched); disposable `@myrial.test` accounts |

## What E1 adds (server only)

| File | Change |
|---|---|
| `nakama/src/wp01e_rules.ts` | new: the server copy of the **existing** Godot EXP / Level rules (`EXP_PER_KILL`, enemies per group count, group ids, `PartyProgression` Hero-only share, `ProgressionState` curve and cap). Timing values approved in S3 / R-1 / R-4. |
| `nakama/src/wp01e.ts` | new: Schema v1 objects and validators, the 4 RPCs, a combined read, the session guard, MC-1 Option C intents, MC-2 Q1+F3 abandon, R-3 limiters |
| `nakama/src/main.ts` | +4 `registerRpc` lines and a header comment. **Trade v1 code unchanged.** |
| `nakama/tsconfig.json` | +2 source files |
| `nakama/tests/unit/harness.mjs` | opt-in `{ md5: true }` versions (Nakama's md5-of-sorted-JSON); the WP01-E limiter collection is treated like the WP01 limiter. Existing tests are unaffected (43/43). |
| `nakama/tests/unit/wp01e_parity.test.mjs` | new (7 tests): golden-vector parity |
| `nakama/tests/unit/wp01e_commands.test.mjs` | new (27 tests): command behaviour |
| `nakama/tests/live/e1_wp01e.test.mjs` | new (5 tests): live checks incl. ACK-1 on real PostgreSQL |
| `godot/tests/vs01_wp01e_combat_vectors.gd`, `godot/tests/verify_vs01_wp01e_combat_vectors.gd` | new: vectors built from the GDScript rules + a drift check (part of the Godot regression) |
| `nakama/scripts/generate_wp01e_vectors.gd`, `nakama/tests/fixtures/wp01e_vectors.json` | new: generator + golden vectors (required_exp 102, gain 738, settlement 147 rows) |
| `nakama/README.md`, this document | docs |

**Not changed:** Trade v1 contract / RPCs / data; `vs01_combat_reward_claim` (still D4-refused); every `godot/scripts` file; `main.gd`; Save v14; offline rules.

## Schema v1 as implemented

All objects are server-only (`permissionRead 0 / permissionWrite 0`), carry `contract` + `contract_version 1`, are validated with exact keys on every read (fail closed: `wp01e_object_not_trusted`), and grow a `revision` on every write.

| Collection / key | Fields |
|---|---|
| `vs01_wp01e_hero_progression / hero` | `revision, level (1..100), exp` — **current-Level EXP: `< required_exp(level)` at Lv1–99, `0` at Lv100** (Schema v1 correction; no MAX_EXP bound) |
| `vs01_wp01e_encounter_state / state` | `revision, open_ticket_id, group_available_at_ms{}` |
| `vs01_wp01e_tickets / <ticket_id>` | `revision, ticket_id, issued_session_id, issued_at_ms, expires_at_ms (= issued + 900,000), group_ids, enemy_count, status OPEN/CLAIMED/EXPIRED/ABANDONED, intent_recorded, resolved_at_ms` |
| `vs01_wp01e_claim_intents / <ticket_id>` | `revision, ticket_id, idempotency_key, request_hash, claim{outcome, kills, hero_alive}, first_seen_at_ms, first_seen_session_id, state RECORDED/DECIDED/ABANDONED` |
| `vs01_wp01e_ticket_claims / <ticket_id>` | create-only: `ticket_id, idempotency_key, decided_at_ms` |
| `vs01_wp01e_receipts / <idempotency_key>` | create-only: `kind (claim / abandon), request_hash, user_id, gameplay_session_id, ticket_id, status, outcome, kills_claimed, kills_accepted, hero_alive, exp_awarded, level/exp before/after, progression_revision, cooldown_groups, intent_first_seen_at_ms, server_time_ms` |
| `vs01_wp01e_rate_limits / encounter_begin, encounter_claim, receipt_replay` | WP01 sliding-window log `{seq, accepted_ms}`: 6 / 12 / 30 per rolling 60 s, per account (env overrides `MYRIAL_RL_E_*`) |

**RPCs:** `vs01e_encounter_begin`, `vs01e_encounter_claim`, `vs01e_encounter_abandon`, `vs01e_progression_get`. The order of checks and the write sets are as in Contract & Schema Review v1.0 §2 / §4.

**Implementation notes (no contract change):**

- **Refusal payloads:** refusals carry only the reason string. Nakama RPC errors carry a message, not structured data. The client gets ticket timing (`min_claim_at_ms`, `expires_at_ms`) from the begin reply, and the unresolved ticket and cooldowns from `vs01e_progression_get`.
- **Limiter order:** the limiter is charged after the static checks, so refusals that need no decision cost one read and no write. Examples: ticket not found / settled, `invalid_claim`. Every decision, `too_early` and every replay is charged.
- **Claim intent:** recorded (MC-1 C) when a claim is refused as `too_early` or throttled before the deadline. A claim decided at once also writes its intent as `DECIDED`, in the same transaction.

## Test results (2026-10-11; all with isolated `user://`, disposable accounts and the disposable `myrial-vs01-wp01e` stack)

| Suite | Result |
|---|---|
| Nakama unit (`npm test` in `nakama/`) | **77/77** = 43 existing + 7 WP01-E parity + 27 WP01-E command tests (one test was split while fixing two wrong test expectations; see "Findings while testing") |
| Nakama live, **all** suites (`node --test --test-concurrency=1 tests/live/*.test.mjs`, two nodes) | **19/19** = 14 existing trade / limiter / fault / restart / multinode / DB-load + 5 E1 |
| Node/npm (repository root, Node/npm CI scope; **not Godot CI**) | **508/508** |
| Godot Full Normal Regression (`run_godot_regression_isolated.sh`, strict) | **70/70 PASS**, FAIL 0, SCRIPT_ERROR 0, wrapper exit 0 (69 existing + `verify_vs01_wp01e_combat_vectors` 22 checks; core loop 1854 checks) |

### ACK-1 evidence (conditional acceptance, real PostgreSQL)

Live test *"ACK-1 (real PostgreSQL)…"*. The account first trades, so the Trade v1 object holds money, stock and a ms-epoch recovery anchor (> 1e12). The test reads `value::text`, `version` and `update_time` straight from the local test DB:

```
version   ed27fef897cb36c21108aff8432a814f -> ed27fef897cb36c21108aff8432a814f (after begin) -> ed27fef897cb36c21108aff8432a814f (after claim)
update_time (µs) 1791691027640783 -> 1791691027728497 -> 1791691038115798
```

| Check | Result |
|---|---|
| Value stability (JSONB compare, incl. large integers; numeric round trip) | **PASS** |
| Version stability (md5) | **PASS** |
| `update_time` | changes (expected; no WP01 code reads it, `git grep` 0 matches) |
| Trade non-interference | **PASS**: the next trade sees the same money and applies |
| Takeover | **PASS** (unit, and live policy A) |
| Concurrency | **PASS** (unit trade-between-read-and-write; live 10 + 10 parallel claims) |
| Cross-node | **PASS** (claim on node 2, replay on node 1) |
| Fault | **PASS** (unit storage fault → `storage_unavailable`, nothing written; existing live fault suite still 1/1) |

**Full Stress and the guard-removal mutation test remain E3.**

### Behaviour covered by the WP01-E unit tests (names abbreviated)

- **Begin:** one ticket per account (`ticket_unsettled`), malformed groups.
- **Claim:**
  - a VICTORY settles once with server EXP / Level;
  - replay gives an identical receipt after the deadline, no second award, `idempotency_key_reused`;
  - R-1 `too_early` (intent kept, no receipt) then settles once;
  - **MC-1 C:** an intent recorded before the deadline is decided 7 days later; no intent → explicit `ticket_expired`, slot freed; a throttled claim keeps its intent; a superseded session records nothing;
  - **MC-2 Q1+F3:** confirm required; abandon at age 0; no cooldown; replay; `ticket_abandoned`; a settled claim is never revoked; begin + abandon share 6/60 s (3 rerolls, 0 EXP);
  - **R-4:** positive-EXP VICTORY / RETREAT cools down for 10 s; zero EXP does not.
- **Policy A:** superseded claim / read refused; the reclaimed device resends the same key once.
- **ACK-1:** version and value unchanged (md5 mode); a takeover between read and write aborts with nothing written; a trade between read and write → the claim retries and both apply once.
- **Concurrency:** same key → replay; different key → `ticket_already_claimed`; claim vs abandon → exactly one.
- **Failures:** storage fault fails fast with nothing written; lost races retry.
- **R-3 quotas:** 6 / 30 per 60 s and `progression_get` charged to `receipt_replay`, not reset by a new session; 12 claim requests incl. `too_early`.
- **Other:** progression view; account isolation; forged / malformed claims; Lv99 → Lv100 cap with 0 EXP; tampered objects fail closed; no gameplay session.

### Findings while testing (fixed in the tests, not the server)

1. With two different keys racing on one ticket, the loser re-reads after its lost race and sees the ticket settled, so it answers `ticket_already_claimed`. The test had expected `claim_locked`, which only applies while the ticket is still open.
2. Claims against an already-settled ticket are refused **before** the limiter (one read, no write), so they cannot count against the 12/60 claim quota. The quota test now uses `too_early` requests, which are charged.

## Risks / open items

- **M1** cannot prove a victory (approved S2, TEST only).
- **Not yet run (E3):**
  - the Full Stress plan (50× races, reroll bot, DB load of the combined reads);
  - the guard-removal mutation test;
  - lossy-proxy claims;
  - a restart in the middle of a claim.
- **E2 (Godot client / TEST scene) is not started.** The client must keep a claim pending on `too_early` / `rate_limited` (unlike trade's first-attempt rule).
- **No Godot CI.** The Godot results are local.

## Rollback

- Revert the E1 commits on this branch. The changes are additive: the new files, plus 4 `registerRpc` lines and the tsconfig entries.
- The disposable stack can be stopped with `COMPOSE_PROJECT_NAME=myrial-vs01-wp01e docker compose --profile multinode stop`. Never use `down -v`; the volume is kept.
- No Trade v1 data or contract changed, so nothing needs migrating back.
