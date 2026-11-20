// VS-01 WP01-H E3-Prep (Phase 1, offline): unit tests of the isolation gates,
// verdict rules and tools used by nakama/scripts/run_wp01h_e3_bounded.mjs and
// the E3 live tests. No docker, no Nakama, no network: pure functions, fakes,
// one real loopback bind probe on an ephemeral port, and a skip-guard check.
import test from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import * as L from "../../scripts/run_wp01h_e3_bounded.mjs";
import * as K from "../live/tools/wp01h_clock.mjs";
import * as D from "../live/tools/wp01h_db.mjs";
import { seedKey } from "../live/tools/wp01h_seed.mjs";

const NAKAMA = fileURLToPath(new URL("../..", import.meta.url));
const GOOD_ENV = { GITHUB_ACTIONS: "true", RUNNER_ENVIRONMENT: "github-hosted", RUNNER_OS: "Linux", ImageOS: "ubuntu24",
  GITHUB_REPOSITORY: L.EXPECTED_REPOSITORY, GITHUB_REF: `refs/heads/${L.EXECUTION_BRANCH}`, GITHUB_EVENT_NAME: "push",
  GITHUB_SHA: "a".repeat(40), RUNNER_TEMP: "/home/runner/work/_temp" };
const GOOD_FACTS = { uname: "Linux", osRelease: "NAME=\"Ubuntu\"\nID=ubuntu\n", headSha: "a".repeat(40) };

test("parseArgs: strict flags, run id, absolute paths", () => {
  const ok = L.parseArgs(["--job", "j2", "--run-id", "wp01h_e3_1_1", "--evidence-dir", "/tmp/e", "--godot", "/opt/godot"]);
  assert.equal(ok.job, "j2");
  assert.throws(() => L.parseArgs(["--job", "j9", "--run-id", "wp01h_e3_1", "--evidence-dir", "/e", "--godot", "/g"]));
  assert.throws(() => L.parseArgs(["--job", "j1", "--run-id", "myrial-vs01-wp01", "--evidence-dir", "/e", "--godot", "/g"]), /run-id/);
  assert.throws(() => L.parseArgs(["--job", "j1", "--run-id", "wp01h_e3_1", "--evidence-dir", "rel", "--godot", "/g"]));
  assert.throws(() => L.parseArgs(["--job", "j1", "--job", "j2"]), /repeated/);
  assert.throws(() => L.parseArgs(["--nope"]), /unknown/);
});

test("G1-2 runner identity: every field must hold", () => {
  assert.deepEqual(L.checkRunnerIdentity(GOOD_ENV, GOOD_FACTS), []);
  for (const [k, v] of [["RUNNER_ENVIRONMENT", "self-hosted"], ["GITHUB_REF", "refs/heads/main"], ["GITHUB_EVENT_NAME", "pull_request"],
    ["GITHUB_REPOSITORY", "someone/fork"], ["ImageOS", ""], ["GITHUB_SHA", "b".repeat(40)], ["GITHUB_ACTIONS", undefined]]) {
    assert.ok(L.checkRunnerIdentity({ ...GOOD_ENV, [k]: v }, GOOD_FACTS).length >= 1, `${k}=${v} must be refused`);
  }
  assert.ok(L.checkRunnerIdentity(GOOD_ENV, { ...GOOD_FACTS, uname: "Darwin" }).length);
  assert.ok(L.checkRunnerIdentity(GOOD_ENV, { ...GOOD_FACTS, osRelease: "ID=debian" }).length);
});

test("G1-4 docker env / context / socket / daemon / empty daemon", () => {
  assert.deepEqual(L.checkDockerEnv({}, "/r"), []);
  for (const k of ["DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CERT_PATH", "DOCKER_TLS_VERIFY"]) assert.equal(L.checkDockerEnv({ [k]: "x" }, "/r").length, 1);
  assert.equal(L.checkDockerEnv({ DOCKER_CONFIG: "/home/u/.docker" }, "/r").length, 1);
  assert.deepEqual(L.checkDockerEnv({ DOCKER_CONFIG: "/r/docker" }, "/r"), []);
  const def = JSON.stringify({ Name: "default", Current: true, DockerEndpoint: "unix:///var/run/docker.sock" });
  assert.deepEqual(L.checkContexts(def + "\n"), []);
  assert.ok(L.checkContexts(def + "\n" + JSON.stringify({ Name: "remote", Current: false, DockerEndpoint: "tcp://10.0.0.1:2376" })).length);
  assert.ok(L.checkContexts(JSON.stringify({ Name: "default", Current: true, DockerEndpoint: "tcp://h:2375" })).length);
  assert.deepEqual(L.checkSocketStat({ isSocket: true, isSymbolicLink: false }), []);
  assert.ok(L.checkSocketStat({ isSocket: false, isSymbolicLink: true }).length);
  assert.ok(L.checkSocketStat(null).length);
  assert.deepEqual(L.checkDockerInfo({ Name: "fv-az1", ID: "x", Swarm: { LocalNodeState: "inactive" } }, "fv-az1"), []);
  assert.ok(L.checkDockerInfo({ Name: "other", ID: "x" }, "fv-az1").length);
  assert.ok(L.checkDockerInfo({ Name: "h", ID: "x", Swarm: { LocalNodeState: "active" } }, "h").length);
  assert.deepEqual(L.checkEmptyDocker({ containers: [], volumes: [], networks: ["bridge", "host", "none"] }), []);
  assert.equal(L.checkEmptyDocker({ containers: ["abc"], volumes: ["v"], networks: ["bridge", "myrial-vs01-wp01_default"] }).length, 3);
});

test("G1-5 bind probe: classification and a real loopback probe", async () => {
  assert.equal(L.classifyBind("127.0.0.1", null), "free");
  assert.equal(L.classifyBind("0.0.0.0", { code: "EADDRINUSE" }), "in_use");
  assert.equal(L.classifyBind("::1", { code: "EADDRNOTAVAIL" }), "ipv6_unavailable");
  assert.equal(L.classifyBind("127.0.0.1", { code: "EADDRNOTAVAIL" }), "error");
  assert.deepEqual(L.checkProbeResults([{ host: "::", port: 1, result: "ipv6_unavailable", code: "EAFNOSUPPORT" }, { host: "127.0.0.1", port: 1, result: "free" }]), []);
  assert.equal(L.checkProbeResults([{ host: "127.0.0.1", port: 17350, result: "in_use", code: "EADDRINUSE" }]).length, 1);
  // A real listener on an ephemeral loopback port must be found "in_use".
  const srv = net.createServer();
  await new Promise((r) => srv.listen({ host: "127.0.0.1", port: 0 }, r));
  const port = srv.address().port;
  const busy = await L.probeBind("127.0.0.1", port, false);
  assert.equal(busy.result, "in_use");
  await new Promise((r) => srv.close(r));
  const free = await L.probeBind("127.0.0.1", port, false);
  assert.equal(free.result, "free");
  assert.deepEqual(L.ssListeners("LISTEN 0 4096 127.0.0.1:17350 0.0.0.0:*\nLISTEN 0 5 0.0.0.0:22 0.0.0.0:*", [17350]), ["127.0.0.1:17350"]);
});

test("G1-10 probe-to-compose window and compose failures are STOP", () => {
  assert.deepEqual(L.checkComposeUp({ exitCode: 0, output: "Container x Healthy", msSinceProbe: 10 }), []);
  assert.ok(L.checkComposeUp({ exitCode: 0, output: "", msSinceProbe: 5001 }).length);
  assert.ok(L.checkComposeUp({ exitCode: 1, output: "", msSinceProbe: 1 }).length);
  assert.ok(L.checkComposeUp({ exitCode: 0, output: "Bind for 127.0.0.1:17350 failed: port is already allocated", msSinceProbe: 1 }).length);
});

test("G2-1 / G2-2 labels and PortBindings", () => {
  assert.deepEqual(L.checkLabels("wp01h_e3_1\nwp01h_e3_1\n", "wp01h_e3_1"), []);
  assert.ok(L.checkLabels("wp01h_e3_1\nmyrial-vs01-wp01\n", "wp01h_e3_1").length);
  assert.ok(L.checkLabels("", "wp01h_e3_1").length);
  const c = (ip, proj = "wp01h_e3_1") => ({ Name: "/n", Config: { Labels: { "com.docker.compose.project": proj } }, HostConfig: { PortBindings: { "7350/tcp": [{ HostIp: ip, HostPort: "17350" }] } } });
  assert.deepEqual(L.checkPortBindings([c("127.0.0.1")], "wp01h_e3_1"), []);
  assert.ok(L.checkPortBindings([c("0.0.0.0")], "wp01h_e3_1").length);
  assert.ok(L.checkPortBindings([c("")], "wp01h_e3_1").length);
  assert.ok(L.checkPortBindings([c("127.0.0.1", "other")], "wp01h_e3_1").length);
});

test("G1-9 workflow static check (the real workflow file passes; unsafe variants fail)", async () => {
  const fs = await import("node:fs");
  const real = fs.readFileSync(new URL("../../../.github/workflows/wp01h-e3-cloud.yml", import.meta.url), "utf8");
  assert.deepEqual(L.checkWorkflowStatic(real), []);
  assert.ok(L.checkWorkflowStatic(real.replace(/runs-on: ubuntu-24.04/g, "runs-on: self-hosted")).length);
  assert.ok(L.checkWorkflowStatic(real.replace("permissions:\n  contents: read", "permissions:\n  contents: write")).length);
  assert.ok(L.checkWorkflowStatic(real.replace("on:\n  push:", "on:\n  workflow_dispatch:\n  push:")).length);
  assert.ok(L.checkWorkflowStatic(real.replace("persist-credentials: false", "persist-credentials: true")).length);
});

test("R-01 judgement: hashes, blobs, allow-list, merge-base", () => {
  const good = { e1Sha: L.E1_SHA256, e2Sha: L.E2_SHA256, blobs: { ...L.BLOBS }, changed: [...L.E1_FILES, ...L.E2_FILES, "nakama/docs/VS01_WP01H_E3.md"], mergeBase: L.BASELINE };
  assert.deepEqual(L.checkR01(good), []);
  assert.equal(Object.keys(L.BLOBS).length, 23);
  assert.ok(L.checkR01({ ...good, e1Sha: "0".repeat(64) }).length);
  assert.ok(L.checkR01({ ...good, blobs: { ...L.BLOBS, "nakama/src/main.ts": "0".repeat(40) } }).length);
  assert.ok(L.checkR01({ ...good, changed: [...good.changed, "nakama/docker-compose.yml"] }).length, "compose is outside the allow-list");
  assert.ok(L.checkR01({ ...good, changed: [...good.changed, "godot/tests/live_vs01_wp01c_online_trade_ui.gd"] }).length, "conditional files are not allowed");
  assert.ok(L.checkR01({ ...good, mergeBase: "f".repeat(40) }).length);
});

test("G1-7 static scan and G1-8 child env", () => {
  assert.deepEqual(L.staticScan({ ok: 'execFileSync("docker", ["compose", "-p", project, "exec"])' }), []);
  assert.ok(L.staticScan({ bad: 'execFileSync("docker", ["compose", "exec", "-T"])' }).length);
  assert.ok(L.staticScan({ bad: "const p = 'myrial_save.json'" }).length);
  assert.ok(L.staticScan({ bad: 'sql("DELETE FROM storage WHERE 1")' }).length);
  assert.ok(L.staticScan({ bad: "psql -c 'TRUNCATE storage'" }).length);
  assert.deepEqual(L.staticScan({ ok: "/\\b(INSERT|DELETE|TRUNCATE)\\b/ guard list" }), []);
  const env = { HOME: "/r/env/x/home", XDG_DATA_HOME: "/r/d", XDG_CONFIG_HOME: "/r/c", XDG_CACHE_HOME: "/r/k", TMPDIR: "/r/t", COMPOSE_PROJECT_NAME: "wp01h_e3_1", PATH: "/usr/bin" };
  assert.deepEqual(L.checkChildEnv(env, "/r", "wp01h_e3_1"), []);
  assert.ok(L.checkChildEnv({ ...env, HOME: "/home/runner" }, "/r", "wp01h_e3_1").length);
  assert.ok(L.checkChildEnv({ ...env, GITHUB_TOKEN: "x" }, "/r", "wp01h_e3_1").length);
  assert.ok(L.checkChildEnv({ ...env, COMPOSE_PROJECT_NAME: "myrial-vs01-wp01" }, "/r", "wp01h_e3_1").length);
  assert.equal(L.inside("/r", "/r"), false);
  assert.equal(L.inside("/r", "/r/../x"), false);
  // The real E3 test files pass the static scan.
  return import("node:fs").then((fs) => {
    const files = Object.fromEntries(L.E3_TEST_FILES.map((f) => [f, fs.readFileSync(new URL(`../../../${f}`, import.meta.url), "utf8")]));
    assert.deepEqual(L.staticScan(files), []);
  });
});

test("Godot phase verdict: SAFETY before FUNCTIONAL; kill phases need SIGKILL", () => {
  const res = (o) => `WP01H_RESULT ${JSON.stringify({ phase: "k_prep", user_data_dir: "/r/env/x/data/godot/app_userdata/M", killed: true, ...o })}`;
  const base = { runRoot: "/r" };
  assert.equal(L.godotPhaseVerdict(`${res()}\nKILL-POINT`, "k_prep", { ...base, expectKill: true, signal: "SIGKILL" }).functional, "");
  assert.equal(L.godotPhaseVerdict(`${res()}`, "k_prep", { ...base, expectKill: true, exitCode: 0 }).functional, "phase was not killed");
  assert.match(L.godotPhaseVerdict(`FAILED: No local save file was created or changed\n${res()}`, "k_prep", { ...base, exitCode: 1 }).safety, /Godot reported/);
  assert.match(L.godotPhaseVerdict(res({ user_data_dir: "/home/u/.local/share/godot" }), "k_prep", { ...base, exitCode: 0 }).safety, /outside/);
  assert.match(L.godotPhaseVerdict(`${res()}\n"password": "abcdefgh"`, "k_prep", { ...base, exitCode: 0 }).safety, /sensitive/);
  const pass = `${res({ phase: "ac04", killed: false })}\nVS-01 WP01-H live ac04 passed (3 checks)`;
  assert.equal(L.godotPhaseVerdict(pass, "ac04", { ...base, exitCode: 0 }).functional, "");
  assert.match(L.godotPhaseVerdict(`FAILED: b\n${pass}`, "ac04", { ...base, exitCode: 1 }).functional, /FAILED/);
});

test("TAP summary and sensitive findings", () => {
  const tap = "TAP version 13\nok 1 - AC-01 applied\nnot ok 2 - AC-02 rejected\n  ---\nok 3 - FS-K10 round # SKIP set MYRIAL_WP01H_E3_TTL=1\n";
  assert.deepEqual(L.tapSummary(tap), { passed: ["AC-01 applied"], failed: ["AC-02 rejected"], skipped: ["FS-K10 round"] });
  assert.deepEqual(L.sensitiveFindings("ordinary log line"), []);
  assert.ok(L.sensitiveFindings("Authorization: Bearer abcdefghijklmnopqrstu").length);
  assert.ok(L.sensitiveFindings("localtest-1a2b3c4d").includes("test_password"));
});

// ---- FS-K10 verdict rules (Blueprint v0.1r2 REV-01 / F-01) ------------------------

const EXP = 1_000_900_000, ISS = EXP - K.TTL_MS;
const tk = (o) => ({ ticket_id: "t".repeat(32), issued_at_ms: ISS, expires_at_ms: EXP, status: "OPEN", intent_recorded: false, resolved_at_ms: -1,
  intent: null, claim_receipts: [], abandon_receipts: [], hero: null, critical_key: "k1", critical_was_first: true, design_bin: "A", lossy: false, ...o });
const claimR = (o) => ({ idempotency_key: "k1", ticket_id: "t".repeat(32), kind: "claim", status: "applied", server_time_ms: EXP - 100,
  intent_first_seen_at_ms: -1, level_after: 2, exp_after: 0, exp_awarded: 100, ...o });
const abandonR = (o) => ({ idempotency_key: "k1", ticket_id: "t".repeat(32), kind: "abandon", status: "applied", server_time_ms: EXP - 100,
  intent_first_seen_at_ms: -1, exp_awarded: 0, ...o });
const intentOf = (o) => ({ ticket_id: "t".repeat(32), first_seen_at_ms: ISS + 1000, state: "RECORDED", ...o });

test("TTL-1..5 FAIL cases", () => {
  assert.deepEqual(K.ticketChecks(tk({ status: "CLAIMED", claim_receipts: [claimR()], hero: { level: 2, exp: 0 } })).fail, []);
  assert.match(K.ticketChecks(tk({ issued_at_ms: ISS + 1 })).fail.join(), /TTL-1/);
  assert.match(K.ticketChecks(tk({ status: "CLAIMED", claim_receipts: [claimR({ server_time_ms: EXP })] })).fail.join(), /TTL-2/);
  assert.deepEqual(K.ticketChecks(tk({ status: "CLAIMED", intent_recorded: true, intent: intentOf(), claim_receipts: [claimR({ server_time_ms: EXP + 50, intent_first_seen_at_ms: ISS + 1000 })] })).fail, []);
  assert.match(K.ticketChecks(tk({ status: "CLAIMED", intent: intentOf({ first_seen_at_ms: EXP }), claim_receipts: [claimR({ server_time_ms: EXP + 50, intent_first_seen_at_ms: EXP })] })).fail.join(), /TTL-2/);
  assert.match(K.ticketChecks(tk({ status: "EXPIRED", resolved_at_ms: EXP - 1 })).fail.join(), /TTL-3/);
  assert.match(K.ticketChecks(tk({ status: "EXPIRED", resolved_at_ms: EXP, intent_recorded: true })).fail.join(), /TTL-3/);
  assert.deepEqual(K.ticketChecks(tk({ status: "EXPIRED", resolved_at_ms: EXP })).fail, []);
  assert.match(K.ticketChecks(tk({ status: "CLAIMED", claim_receipts: [claimR(), claimR({ idempotency_key: "k2" })] })).fail.join(), /TTL-5/);
  assert.match(K.ticketChecks(tk({ status: "EXPIRED", resolved_at_ms: EXP, claim_receipts: [claimR()] })).fail.join(), /TTL-5/);
  assert.match(K.ticketChecks(tk({ status: "CLAIMED", claim_receipts: [claimR()], hero: { level: 3, exp: 0 } })).fail.join(), /hero/);
});

test("TTL-4 (F-01): an intent alone never makes a late abandon legal", () => {
  const before = tk({ status: "ABANDONED", resolved_at_ms: EXP - 100, abandon_receipts: [abandonR()] });
  assert.deepEqual(K.ticketChecks(before).fail, [], "(i) before the deadline");
  const lateOk = tk({ status: "ABANDONED", intent_recorded: true, resolved_at_ms: EXP + 100, intent: intentOf({ state: "ABANDONED" }),
    abandon_receipts: [abandonR({ server_time_ms: EXP + 100, intent_first_seen_at_ms: ISS + 1000 })] });
  assert.deepEqual(K.ticketChecks(lateOk).fail, [], "(ii) a-f all hold");
  const variants = {
    a_receipt_saw_no_intent: { abandon_receipts: [abandonR({ server_time_ms: EXP + 100, intent_first_seen_at_ms: -1 })] },
    b_first_seen_differs: { abandon_receipts: [abandonR({ server_time_ms: EXP + 100, intent_first_seen_at_ms: ISS + 999 })] },
    c_intent_after_deadline: { intent: intentOf({ state: "ABANDONED", first_seen_at_ms: EXP }), abandon_receipts: [abandonR({ server_time_ms: EXP + 100, intent_first_seen_at_ms: EXP })] },
    e_intent_state_recorded: { intent: intentOf({ state: "RECORDED" }) },
    e_intent_other_ticket: { intent: intentOf({ state: "ABANDONED", ticket_id: "u".repeat(32) }) },
    f_flag_false: { intent_recorded: false },
    f_resolved_differs: { resolved_at_ms: EXP + 101 },
    row_only_no_receipt_link: { intent: intentOf({ state: "ABANDONED" }), abandon_receipts: [abandonR({ server_time_ms: EXP + 100 })] },
  };
  for (const [name, o] of Object.entries(variants)) {
    const t = { ...lateOk, ...o };
    assert.match(K.ticketChecks(t).fail.join(), /TTL-4/, name);
  }
  // (d) is implied by (c) on a late abandon (first_seen < expires <= server_time); positive cases:
  const d = { ...lateOk, intent: intentOf({ state: "ABANDONED", first_seen_at_ms: EXP - 1 }),
    abandon_receipts: [abandonR({ server_time_ms: EXP + 100, intent_first_seen_at_ms: EXP - 1 })] };
  assert.deepEqual(K.ticketChecks(d).fail, [], "intent before expiry and before the abandon: legal");
  const d2 = { ...lateOk, intent: intentOf({ state: "ABANDONED", first_seen_at_ms: EXP - 1 }), resolved_at_ms: EXP + 100,
    abandon_receipts: [abandonR({ server_time_ms: EXP + 100, intent_first_seen_at_ms: EXP - 1 })] };
  assert.deepEqual(K.ticketChecks(d2).fail, []);
  const flagOnly = tk({ status: "ABANDONED", intent_recorded: true, resolved_at_ms: EXP + 100, intent: null, abandon_receipts: [abandonR({ server_time_ms: EXP + 100 })] });
  assert.match(K.ticketChecks(flagOnly).fail.join(), /TTL-4/, "ticket flag without an intent row (RR-16) is FAIL");
});

test("bins, IC-1..5 and the round verdict", () => {
  const A = tk({ status: "CLAIMED", claim_receipts: [claimR({ server_time_ms: EXP - 200 })], hero: { level: 2, exp: 0 } });
  const B = tk({ status: "EXPIRED", resolved_at_ms: EXP + 200, design_bin: "B" });
  const C = tk({ status: "CLAIMED", design_bin: "C", critical_was_first: false, intent_recorded: true, intent: intentOf({ state: "SETTLED" }),
    claim_receipts: [claimR({ server_time_ms: EXP + 200, intent_first_seen_at_ms: ISS + 1000 })], hero: { level: 2, exp: 0 } });
  const Dt = tk({ status: "ABANDONED", design_bin: "D", resolved_at_ms: EXP - 100, abandon_receipts: [abandonR()] });
  assert.equal(K.serverBin(A), "A"); assert.equal(K.serverBin(B), "B"); assert.equal(K.serverBin(C), "C"); assert.equal(K.serverBin(Dt), "D");
  assert.equal(K.serverBin(tk({ status: "CLAIMED", claim_receipts: [claimR({ server_time_ms: EXP - 5000 })] })), "outside");
  const full = [A, A, B, B, C, C, Dt, Dt];
  assert.equal(K.roundVerdict(full).verdict, "PASS");
  assert.equal(K.roundVerdict([A, B, B, C, C, Dt, Dt]).verdict, "INCONCLUSIVE", "IC-2 bin A < 2");
  const noEvidence = tk({ status: "EXPIRED", resolved_at_ms: EXP + 100, design_bin: "B", critical_was_first: false });
  assert.match(K.roundVerdict([...full, noEvidence]).inconclusive.join(), /IC-1/);
  assert.match(K.roundVerdict(full, { serverTimeRegress: true }).inconclusive.join(), /IC-3/);
  assert.match(K.roundVerdict(full, { containerRestarted: true }).inconclusive.join(), /IC-4/);
  assert.match(K.roundVerdict([...full, { ...A, lossy: true }]).inconclusive.join(), /IC-5/);
  const bad = tk({ status: "EXPIRED", resolved_at_ms: EXP - 1, design_bin: "B" });
  assert.equal(K.roundVerdict([...full, bad], { containerRestarted: true }).verdict, "FAIL", "FAIL wins over INCONCLUSIVE");
  assert.equal(L.fsK10Verdict({ verdict: "PASS", fails: [], inconclusive: [] }, { containerRestarted: true }).verdict, "INCONCLUSIVE");
  assert.equal(L.fsK10Verdict(null, { containerRestarted: false }).verdict, "INCONCLUSIVE");
  const est = K.estimateOffset([{ send: 100, recv: 140, server: 1120 }, { send: 200, recv: 210, server: 1206 }]);
  assert.equal(est.rtt, 10); assert.equal(est.offset, 1001);
  assert.equal(K.serverTimeRegressed([{ server: 5 }, { server: 4 }]), true);
});

// ---- DB / seed tools (pure parts) ----------------------------------------------------

test("wp01h_db: SELECT only, run project only, snapshot delta, trade ledger", () => {
  assert.throws(() => D.runProject({ COMPOSE_PROJECT_NAME: "myrial-vs01-wp01" }), /wp01h_e3/);
  assert.throws(() => D.runProject({ COMPOSE_PROJECT_NAME: "wp01h_e3_1", DOCKER_HOST: "tcp://x" }), /DOCKER_HOST/);
  assert.equal(D.runProject({ COMPOSE_PROJECT_NAME: "wp01h_e3_1" }), "wp01h_e3_1");
  assert.throws(() => D.assertSelect("DELETE FROM storage"));
  assert.throws(() => D.assertSelect("SELECT 1; DROP TABLE storage"));
  assert.throws(() => D.assertSelect("SELECT * FROM x WHERE 1=1 UPDATE"));
  assert.equal(D.assertSelect(" SELECT count(*) FROM users "), "SELECT count(*) FROM users");
  const s0 = { user_id: "u", progress: { money: 1, backpack: {}, revision: 2 }, trade_receipts: { k: "h" }, combat_receipts: {}, tickets: {}, intents: {} };
  assert.deepEqual(D.snapshotDelta(s0, structuredClone(s0)), []);
  assert.equal(D.snapshotDelta(s0, { ...s0, trade_receipts: { k: "h", k2: "x" } }).length, 1);
  assert.equal(D.snapshotDelta(s0, { ...s0, trade_receipts: { k: "h2" } }).length, 1);
  assert.equal(D.snapshotDelta(s0, { ...s0, progress: { ...s0.progress, revision: 3 } }).length, 1);
  const buy = { idempotency_key: "a", status: "applied", action: "buy", good_id: "g", quantity: 10, total: 840, money_before: 10000, money_after: 9160, carried_before: 0, carried_after: 10 };
  const voided = { idempotency_key: "b", status: "voided", action: "buy", good_id: "g", quantity: 1, total: 0, money_before: 9160, money_after: 9160, carried_before: 10, carried_after: 10 };
  assert.deepEqual(D.tradeLedger({ money: 9160, backpack: { g: 10 } }, [buy, voided]).problems, []);
  assert.ok(D.tradeLedger({ money: 8320, backpack: { g: 20 } }, [buy, voided]).problems.length, "a charge without a receipt");
  assert.ok(D.tradeLedger({ money: 9160, backpack: { g: 10 } }, [buy, { ...buy }]).problems.length, "duplicate key");
  assert.ok(D.tradeLedger({ money: 9160, backpack: { g: 10 } }, [buy, { ...voided, money_after: 9000 }]).problems.length, "a voided receipt that moved money");
  assert.equal(D.sha({ b: 1, a: 2 }), D.sha({ a: 2, b: 1 }));
  assert.match(seedKey("ac15_bad_hash"), /^[0-9a-f]{32}$/);
  assert.throws(() => seedKey("Bad Label"));
});

test("E3 live tests skip entirely without the launcher's run id (old run_live_tests.sh can never run them)", () => {
  for (const f of ["tests/live/h1_wp01h_trade_resolve.test.mjs", "tests/live/h2_wp01h_combat_intent.test.mjs", "tests/live/h3_wp01h_full_stress.test.mjs"]) {
    const env = { PATH: process.env.PATH, MYRIAL_NAKAMA_URL: "http://127.0.0.1:9" }; // nothing listens: any real request would fail
    const r = spawnSync(process.execPath, ["--test", "--test-reporter=tap", f], { cwd: NAKAMA, env, encoding: "utf8", timeout: 60000 });
    assert.equal(r.status, 0, `${f}: ${r.stdout}${r.stderr}`);
    const s = L.tapSummary(r.stdout);
    assert.equal(s.passed.length + s.failed.length, 0, `${f}: no test may run`);
    assert.ok(s.skipped.length >= 2, `${f}: skipped ${s.skipped.length}`);
  }
});
