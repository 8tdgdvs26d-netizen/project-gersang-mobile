# VS-01 WP01 Technical Spike Evidence

Evidence date: 2026-10-08 UTC

Verified base: `main` at `3774aefacfb92736c63034c51565aa4e675d3aeb`

Working branch: `claude/vs01-wp01-backend-spike`

## Scope

This is an isolated feasibility spike for account-bound online save authority. It does not connect
to the production game flow, change gameplay, modify Save v14, migrate a Development Save, select a
final provider, or establish a production backend architecture.

## Evidence obtained

| Check | Result | Evidence |
| --- | --- | --- |
| Existing repository baseline | PASS | `npm test`: 508 passed, 0 failed before spike changes |
| Offline authority model | PASS | `node --test test/vs01_supabase_spike.test.mjs`: 7 passed, 0 failed |
| Duplicate command delivery | PASS (model) | Same idempotency key delivered 100 times; one revision and one economic mutation |
| Lost-response retry | PASS (model) | Retry returns the stored receipt without a second mutation |
| Atomic money and inventory mutation | PASS (model) | Invalid command changes neither balance nor inventory |
| One active session | PASS (model) | Superseded session is rejected; the new lease remains authoritative |
| Cross-account access denial | PASS (model) | A second account cannot read or command the first account's state |
| Rapid unique commands | PASS (model) | 50 unique commands produce 50 revisions and the expected balance |
| SQL and client contract scan | PASS | RLS, revoked client writes, service-only functions and non-secret Godot env inputs are asserted |
| Full JavaScript regression | PASS | `npm test`: 515 passed, 0 failed after spike changes |

## Evidence not yet obtained

| Check | Status | Blocker |
| --- | --- | --- |
| Disposable Supabase live smoke | BLOCKED | No spike URL, publishable key, test account or session id is configured |
| Deployed Edge Function and migration | NOT RUN | Requires a disposable Supabase project; no provider has been locked |
| Godot headless validation | NOT RUN | Godot executable is unavailable in this environment |
| Physical iPhone/iPad network and resume test | NOT RUN | Requires live disposable backend plus device build |
| Player experience acceptance | NOT RUN | A technical test pass is not a player-experience pass |

The provider decision therefore remains open. The current evidence validates the proposed authority
contract and test harness only; it does not establish that Supabase has passed the Technical Spike.

## Next evidence step

Create or nominate one disposable Supabase project, apply only the spike migration and Edge Function,
create two disposable test users, and run the live smoke plus cross-account/session-takeover checks.
No production data, gameplay wiring or Save v14 migration is required.
