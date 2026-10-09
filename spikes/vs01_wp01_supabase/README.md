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

Then, with the same environment:

7. `node spikes/vs01_wp01_supabase/live_stress.mjs --with-expiry` — parallel duplicate and unique
   commands, a rapid burst with latency capture, lost-response retry, atomic rejection, refused
   session takeover and (with `--with-expiry`, about 100 s) lease-expiry takeover. Set
   `MYRIAL_SPIKE_EMAIL_B` / `MYRIAL_SPIKE_PASSWORD_B` for a second disposable account to add the
   cross-account check. After a lease-expiry run the fixed session is stale for up to 90 s, so wait
   before rerunning the smoke test.
8. `godot/tests/run_tests.sh verify_tc_font` once (imports the project), then
   `<Godot> --headless --path godot --script res://spikes/vs01_wp01_supabase/live_probe.gd` —
   the Godot client signs in, acquires the session, reads state and checks one idempotent command.

Both print only PASS/FAIL results and non-secret numbers, and exit 2 (BLOCKED) without the
environment.

## Still required before a provider decision

- live Supabase runs of steps 6–8 against the disposable project;
- real-iPhone login, command, reconnect and state-read smoke;
- cost/limits observation and the same acceptance matrix for PlayFab and Firebase.

## Not doing

No production account UI, Save v14 migration, gameplay integration, shared market, formal combat
validation, final reconnect rules, social login, microservices, Docker, CI rewrite or provider lock.
