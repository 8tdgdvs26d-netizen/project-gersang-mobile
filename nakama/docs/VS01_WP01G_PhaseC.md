# VS-01 WP01-G Phase C — C1 Engineering Record

Original C1 date: 2026-10-24 HKT

C1-R1 targeted corrective date: 2026-10-25 HKT

Scope: C1 transport fix only

Base: `35932e1a05b95747f46c3b385501dba609795b62`

## Authority and source recovery

Charlie approved C1 Engineering Approval 1 and later selected GPT as temporary
implementer. GPT is therefore not the independent reviewer for this delivery.

The recovered Blueprint v0.2 archive is:

- File: `UPLOAD_THIS_WP01G_PhaseC_Blueprint_v0.2_cd37e98a.zip`
- Verified actual SHA-256:
  `cd37e98ad9f6a4c284af175aecac074767d9f8df8d2416d7c22e24e12bb51a6c`
- Earlier recorded SHA-256:
  `cd37e98a91aa982974ceedf8762f51e93cb52812cd302fe9e237918d783b7ebf`
- Earlier value status: `SUSPECTED RECORDING ERROR`, retained for audit.

Charlie conditionally authorized the actual SHA after read-only verification.
ZIP integrity passed; every member in `FILES_MANIFEST.csv` matched its recorded
size and SHA-256. Blueprint version, exact +9 line client patch, three-file
allowlist, C1 acceptance criteria, and the substantive v0.1→v0.2 changes were
checked with no material conflict. The base client blob is
`804902a3ec10b05be20ead31e9fa62cf39674ce9`; the supplied patch applies cleanly.

## C1 change

Only these repository files are in scope:

1. `godot/scripts/online_progress_client.gd`
2. `godot/tests/verify_vs01_wp01g_transport.gd`
3. `nakama/docs/VS01_WP01G_PhaseC.md`

The production client change is exactly +9 lines and sets the existing Nakama
HTTP adapter's `use_threads` property to `false` before the adapter enters the
scene tree. Timeout, retry count/backoff, payloads, session policy, confirmed
cache, pending commands, idempotency keys, and outcome classification are not
changed.

## Automated test intent

`verify_vs01_wp01g_transport.gd` uses an in-process loopback `TCPServer`. It
accepts connections, reads and records each complete HTTP request (headers plus
the declared Content-Length body), and deliberately never sends a response.
It verifies:

- T-CFG: adapter and each HTTPRequest are non-threaded; timeout and SDK retry
  configuration are unchanged.
- T-READ: three complete attempts, 2.9–5.0 second return, heartbeat gap below
  500 ms, UNCERTAIN outcome, no stale marker, confirmed cache unchanged.
- T-WRITE: three complete attempts and bodies, one pending command, and the
  same idempotency key in every retry body.
- T-AFTER: adapter pending map and HTTPRequest children are cleared within
  three frames; the same adapter can run a subsequent request normally.
- Per-case in-test guard: 15 seconds. The existing runner's external hard
  limit remains separate.

## C1-R1 targeted corrective implementation

Charlie approved C1-R1 after the separated candidate review returned
`CONDITIONAL PASS`. R1 changes only the test and this engineering record; the
production `online_progress_client.gd` remains byte-identical to the reviewed
C1 `+9/-0` candidate.

The two P1 evidence defects are corrected as follows:

- `_poll_until_done()` now measures the final interval after the loop exits.
  A request that completes during the last `process_frame` can therefore no
  longer hide a final main-thread heartbeat gap.
- The loopback fault server records monotonic `accepted_usec` and
  `completed_usec` timestamps for every complete HTTP request. Each case prints
  a three-attempt timeline and independently asserts that attempts 1 and 2 wait
  0.75–1.75 seconds before the next retry is accepted, while attempt 3 waits
  0.75–1.75 seconds before the call returns. This 250 ms early / 750 ms late
  tolerance accounts for frame polling and runner scheduling around a one
  second SDK timeout; the existing independent three-complete-request count
  and overall 2.9–5.0 second bound remain unchanged.

R1 does not change timeout, retry count/backoff, session, cache, pending,
idempotency, payload, SDK, or result classification behavior.

## Evidence status

The delivery package records raw commands, output, and exit codes separately.

- Blueprint/source/blob/diff consistency: STATIC VERIFIED.
- Exact three-file repository allowlist: STATIC VERIFIED.
- Godot binary: official `4.7.2.stable.official.ed1daf0bf`.
- Relevant Test final run: LOCAL TEST PASS, 75 checks, exit 0.
- Godot Full Normal Regression: LOCAL TEST PASS, 73/73 verify scripts,
  exit 0. The new WP01-G test passed again within this full run.
- Runtime isolation: `HOME`, XDG data/config, and temporary paths were directed
  to the delivery workspace. Godot resolved `user://` below that isolated HOME;
  the normal Development Save path was not used.
- Two earlier relevant-test attempts returned exit 1 because the new test
  started its timer after launching the coroutine and expected one HTTPRequest
  node per retry. Existing wrapper summaries for both failures and the second
  attempt's direct raw Godot log are retained. The first attempt's complete
  underlying Godot stdout/stderr was not saved and is explicitly
  `UNAVAILABLE`; it must not be reconstructed or represented as historical raw
  evidence. The correction starts timing before the call and reflects the
  SDK's actual design: one HTTPRequest node is reused while the loopback server
  independently proves three complete HTTP requests. Production code was
  unchanged during these test corrections.
- Node/Nakama tests: not evidence of Godot behavior and not required as a
  substitute for the Godot runs; NOT RUN in this local C1 delivery.
- Cloud, CI, live core, Mac, iPhone, iPad, Playtest, Player Value: NOT RUN / NOT
  AUTHORIZED for this local delivery.
- Independent code review: PENDING.
- VS-01 System Gate: OPEN.

## Risks and rollback

Non-threaded HTTP progresses once per frame. Low frame rate and mobile
background/foreground behavior still require the separately tracked device
acceptance. C1 does not satisfy the separate 10/30-second read-deadline work;
C2-A remains design-blocked and C2-B is not implemented here.

Reverting C1 would reintroduce the known freeze risk. Before merge, stop and do
not merge the review candidate. After a future merge, rollback requires a
separately approved revert PR plus blocking the affected Online TEST screens
from playtest/device demonstration until a replacement fix is reviewed. Never
force-push, rewrite history, delete evidence, or call that rollback a PASS.

Immediate STOP conditions remain: a fourth repository file is needed; timeout,
retry, key, pending, session, or result classification must change; a complete
request count is not three; heartbeat reaches 500 ms; isolation fails; or any
normal Godot regression fails.
