# VS-01 WP01 — Supabase Technical Spike

Status: isolated feasibility scaffold. It is not a production backend and does not lock the provider.

## What this proves offline

- one active session lease per account;
- command idempotency and lost-response retry safety;
- atomic money + inventory mutation in the reference model;
- cross-account state isolation;
- SQL contract with Row Level Security (RLS), no direct client writes, row locks, receipts and audit records;
- an authenticated Edge Function boundary whose service key stays server-side;
- a Godot 4.x raw-HTTPS client that is not connected to gameplay or Save v14.

Run the offline evidence with `npm test` from the repository root.

## Live disposable-project procedure

1. Create a disposable Supabase project and a disposable email/password test account.
2. Apply `supabase/migrations/0001_spike.sql`.
3. Deploy `supabase/functions/command/index.ts` as the `command` Edge Function.
4. Keep `SUPABASE_SERVICE_ROLE_KEY` only in the Edge Function environment. Never put it in Godot,
   source control, logs or screenshots.
5. Export these local-only variables:
   - `MYRIAL_SPIKE_SUPABASE_URL`
   - `MYRIAL_SPIKE_SUPABASE_PUBLISHABLE_KEY`
   - `MYRIAL_SPIKE_EMAIL`
   - `MYRIAL_SPIKE_PASSWORD`
   - `MYRIAL_SPIKE_SESSION_ID` (a fixed UUID so the smoke test can be safely rerun)
6. Run `node spikes/vs01_wp01_supabase/live_smoke.mjs`.

The live run must show authentication, session acquisition, one idempotent command and denial of a
direct progress write. A missing environment exits with code 2 and means **BLOCKED / no evidence**,
not PASS or FAIL.

## Still required before a provider decision

- live Supabase run against a disposable project;
- a second active-session attempt and lease-expiry/takeover observation;
- repeated/parallel remote requests and latency/error capture;
- Godot Local Automated Test with a configured disposable account;
- real-iPhone login, command, reconnect and state-read smoke;
- cost/limits observation and the same acceptance matrix for PlayFab and Firebase.

## Not doing

No production account UI, Save v14 migration, gameplay integration, shared market, formal combat
validation, final reconnect rules, social login, microservices, Docker, CI rewrite or provider lock.
