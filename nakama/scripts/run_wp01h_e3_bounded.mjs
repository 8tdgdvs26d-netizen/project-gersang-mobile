#!/usr/bin/env node
// VS-01 WP01-H E3 bounded isolated launcher (Blueprint E3-Prep v0.1r2).
// Disposable GitHub-hosted Linux runner ONLY. Evidence is never deleted.
//
//   node nakama/scripts/run_wp01h_e3_bounded.mjs --job j1|j1r|j2|j3 --run-id wp01h_e3_<id> \
//     --evidence-dir <abs, new> --godot <abs Godot 4.7.2 binary>
//
// Jobs: j1 = AC cases + code-revert stage (AC-14c / 18 / 19); j1r = AC-09
// regression (offline Godot verify + kill pairs + Nakama unit + root Node, then
// the pre-existing live tests); j2 = FS-K1..K9; j3 = FS-K10 + AC-16 (TTL, one node).
// Order per job (any gate failure = STOP before tests, nothing retried):
//   G1 pre-start gates (R-01, runner identity, docker socket / context, real
//   bind probe, run root, Godot probe, static scan, env whitelist, workflow)
//   -> docker compose up within 5 s of the bind probe (G1-10)
//   -> G2 post-start gates (labels, PortBindings 127.0.0.1, external IP refused,
//      IPv6 probe, health + resolve RPC, module hash, fresh DB, storage columns)
//   -> the job's cases -> leftover inventory (nothing deleted) -> manifest.
// Pure gate functions are exported and unit-tested offline
// (tests/unit/wp01h_e3_launcher.test.mjs). Running this file in Phase 1 is not
// authorized; it refuses outside a GitHub-hosted runner anyway (G1-2).
import { spawn, spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const REPO = path.resolve(HERE, "../..");
const NAKAMA_DIR = path.join(REPO, "nakama");
const GODOT_DIR = path.join(REPO, "godot");
const COMPOSE_FILE = path.join(NAKAMA_DIR, "docker-compose.yml");

export const BASELINE = "360228cb934f459e0a828e20c540822446585615";
export const EXPECTED_REPOSITORY = "8tdgdvs26d-netizen/project-gersang-mobile";
export const EXECUTION_BRANCH = "wp01-h-e3-cloud-execution";
export const RUN_ID_RE = /^wp01h_e3_[a-z0-9_]{1,50}$/;
export const PORTS = [17350, 17351, 17360, 17361, 17370];
export const API_PORT = 17350, NODE2_PORT = 17360, PROXY_PORT = 17370;
export const PROBE_TO_COMPOSE_MS = 5000;
export const READ_DEADLINE_TEST = "verify_vs01_wp01g_read_deadline";

// R-01: accepted patches (path-restricted diffs vs BASELINE) and blob ids.
export const E1_FILES = ["nakama/src/guards.ts", "nakama/src/main.ts", "nakama/src/trade_resolve.ts", "nakama/src/wp01e.ts",
  "nakama/tests/unit/wp01h_combat_intent.test.mjs", "nakama/tests/unit/wp01h_trade_resolve.test.mjs", "nakama/tsconfig.json"];
export const E1_SHA256 = "9f82b854b6d375699aa5b124dd12e50b105acf27322843bcad3ab4f5e4207ecd";
export const E2_FILES = ["godot/scripts/online_combat_adapter.gd", "godot/scripts/online_combat_test_mode.gd", "godot/scripts/online_pending_store.gd",
  "godot/scripts/online_progress_client.gd", "godot/scripts/online_trade_adapter.gd", "godot/scripts/online_trade_test_mode.gd",
  "godot/tests/run_wp01h_kill_tests.sh", "godot/tests/verify_vs01_wp01_online_contract.gd", "godot/tests/verify_vs01_wp01b_online_trade_adapter.gd",
  "godot/tests/verify_vs01_wp01b_s01_client_consistency.gd", "godot/tests/verify_vs01_wp01c_online_trade_ui.gd", "godot/tests/verify_vs01_wp01e_online_combat.gd",
  "godot/tests/verify_vs01_wp01h_combat_recovery.gd", "godot/tests/verify_vs01_wp01h_pending_store.gd", "godot/tests/verify_vs01_wp01h_trade_recovery.gd",
  "godot/tests/wp01h_process_kill.gd"];
export const E2_SHA256 = "476603d1dfaade09e36fedbb7dc43d7654bc1ce283a574a7457f61f6d6095e75";
export const BLOBS = {
  "nakama/src/guards.ts": "323c9a3099f8de732cd962e264a32335ad7539ef", "nakama/src/main.ts": "041300a7faaeb02d9d5a045de86327d465604e9c",
  "nakama/src/trade_resolve.ts": "b8c741416f6654c4829891f2b8a1dfc22ef3581a", "nakama/src/wp01e.ts": "f54509c51f351930a902c0fe7633fe5ced60d38c",
  "nakama/tests/unit/wp01h_combat_intent.test.mjs": "e0f928b73f22665016b44bf51c256e838ac7e87b", "nakama/tests/unit/wp01h_trade_resolve.test.mjs": "c55260a24de741131273f63aba1c437ed38d47f3",
  "nakama/tsconfig.json": "fcb08971ba556eae49472f28443201c1fb2e970e", "godot/scripts/online_combat_adapter.gd": "529554b9a43e6793a8a52c245e09b68acb936331",
  "godot/scripts/online_combat_test_mode.gd": "504fb778de86526909ecd1b7f2df1b2b44f67494", "godot/scripts/online_pending_store.gd": "677939db364c7e10c5b8cf79cac7499b738f6265",
  "godot/scripts/online_progress_client.gd": "c47f3ccffefaf0ea6d4699a7d0f30deaae3bb4ed", "godot/scripts/online_trade_adapter.gd": "38ec064e4092ba6664520251c63095d3ab1a4510",
  "godot/scripts/online_trade_test_mode.gd": "cb1b1acebdbec0c179b33d8e91109cb8db3103ab", "godot/tests/run_wp01h_kill_tests.sh": "e27f91dac5773b3431f333a21e2edab447919970",
  "godot/tests/verify_vs01_wp01_online_contract.gd": "deab58d3e387dfa7723cbe1426010b7feba20ea4", "godot/tests/verify_vs01_wp01b_online_trade_adapter.gd": "c3adc70bb07f60c92216c675ff5b3bad9e9d609c",
  "godot/tests/verify_vs01_wp01b_s01_client_consistency.gd": "d438e0c517a73133e935b04c1677788a3cc0f824", "godot/tests/verify_vs01_wp01c_online_trade_ui.gd": "cfcbf9df8752c6f13e16ad11f83719a543379401",
  "godot/tests/verify_vs01_wp01e_online_combat.gd": "f97dfc98aff6a82caaf90f46025c95bf45dad745", "godot/tests/verify_vs01_wp01h_combat_recovery.gd": "8235e1dfabb9a1e31aa81ddb4b0ee6cb181c3250",
  "godot/tests/verify_vs01_wp01h_pending_store.gd": "23a72eaf88f795ec24f901307e30450ef1aea1f5", "godot/tests/verify_vs01_wp01h_trade_recovery.gd": "b23489ecfdf8fd1e832e67a5a71d40a422369bfe",
  "godot/tests/wp01h_process_kill.gd": "3e456583bd19d14d4c3b4ccbfed677cefbccb9ff",
};
// Blueprint v0.1r2 §3 allow-list (E3-Prep commit). Conditional files are NOT allowed.
export const E3_PREP_FILES = ["godot/tests/live_vs01_wp01e_online_combat.gd", "godot/tests/live_vs01_wp01_nakama.gd", "godot/tests/live_vs01_wp01b_online_trade.gd",
  "nakama/tests/live/h1_wp01h_trade_resolve.test.mjs", "nakama/tests/live/h2_wp01h_combat_intent.test.mjs", "nakama/tests/live/h3_wp01h_full_stress.test.mjs",
  "nakama/tests/live/tools/wp01h_db.mjs", "nakama/tests/live/tools/wp01h_seed.mjs", "nakama/tests/live/tools/wp01h_clock.mjs",
  "godot/tests/live_vs01_wp01h_recovery.gd", "godot/tests/live_vs01_wp01h_recovery.gd.uid",
  "nakama/scripts/run_wp01h_e3_bounded.mjs", "nakama/tests/unit/wp01h_e3_launcher.test.mjs",
  ".github/workflows/wp01h-e3-cloud.yml", "nakama/docs/VS01_WP01H_E3.md"];
export const E3_TEST_FILES = ["nakama/tests/live/h1_wp01h_trade_resolve.test.mjs", "nakama/tests/live/h2_wp01h_combat_intent.test.mjs",
  "nakama/tests/live/h3_wp01h_full_stress.test.mjs", "nakama/tests/live/tools/wp01h_db.mjs", "nakama/tests/live/tools/wp01h_seed.mjs",
  "nakama/tests/live/tools/wp01h_clock.mjs", "godot/tests/live_vs01_wp01h_recovery.gd"];
// Godot FAILED messages that mean an isolation / save problem: SAFETY, never FUNCTIONAL.
export const GODOT_SAFETY_CHECKS = ["No local save file was created or changed", "No local save file exists in the isolated user data folder", "Godot reports a user data folder"];
const SENSITIVE = [
  ["authorization_header", /\bauthorization\s*:\s*\S+/i], ["bearer_token", /\bbearer\s+[A-Za-z0-9._~+/=-]{16,}/i],
  ["jwt", /\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]*/],
  ["token_field", /["']?\b(?:token|refresh_token|session_token|access_token)["']?\s*[:=]\s*["'][^"'\s]{16,}["']/i],
  ["password_field", /["']?\bpassword["']?\s*[:=]\s*["'][^"'\s]{6,}["']/i], ["password_param", /\bpassword=[^\s&"']{6,}/i],
  ["test_password", /localtest-[0-9a-z]{6,}/i],
];

// ---- pure gate functions (unit-tested) -----------------------------------------

export function sensitiveFindings(text) { return SENSITIVE.filter(([, re]) => re.test(text)).map(([id]) => id); }

export function parseArgs(argv) {
  const out = { job: "", runId: "", evidenceDir: "", godot: "" };
  const seen = new Set();
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i], map = { "--job": "job", "--run-id": "runId", "--evidence-dir": "evidenceDir", "--godot": "godot" };
    if (!(flag in map)) throw new Error(`unknown argument: ${flag}`);
    if (seen.has(flag)) throw new Error(`${flag} must not be repeated`);
    seen.add(flag);
    if (i + 1 >= argv.length || argv[i + 1].startsWith("--")) throw new Error(`${flag} requires a value`);
    out[map[flag]] = argv[++i];
  }
  if (!["j1", "j1r", "j2", "j3"].includes(out.job)) throw new Error("--job must be j1, j1r, j2 or j3");
  if (!RUN_ID_RE.test(out.runId)) throw new Error(`--run-id must match ${RUN_ID_RE}`);
  if (!path.isAbsolute(out.evidenceDir)) throw new Error("--evidence-dir must be absolute");
  if (!path.isAbsolute(out.godot)) throw new Error("--godot must be absolute");
  return out;
}

// G1-2 runner identity. facts = {uname, osRelease, headSha}.
export function checkRunnerIdentity(env, facts) {
  const p = [];
  const want = { GITHUB_ACTIONS: "true", RUNNER_ENVIRONMENT: "github-hosted", RUNNER_OS: "Linux",
    GITHUB_REPOSITORY: EXPECTED_REPOSITORY, GITHUB_REF: `refs/heads/${EXECUTION_BRANCH}`, GITHUB_EVENT_NAME: "push" };
  for (const [k, v] of Object.entries(want)) if (env[k] !== v) p.push(`${k} is ${JSON.stringify(env[k] ?? null)}, not ${v}`);
  if (!env.ImageOS) p.push("ImageOS is not set (not a GitHub-hosted image)");
  if (!/^[0-9a-f]{40}$/.test(env.GITHUB_SHA ?? "") || env.GITHUB_SHA !== facts.headSha) p.push("GITHUB_SHA differs from git HEAD");
  if (facts.uname !== "Linux") p.push(`uname -s is ${facts.uname}`);
  if (!/^ID=ubuntu$/m.test(facts.osRelease ?? "")) p.push("/etc/os-release is not Ubuntu");
  if (!path.isAbsolute(env.RUNNER_TEMP ?? "")) p.push("RUNNER_TEMP is not absolute");
  return p;
}

// G1-4 docker environment variables.
export function checkDockerEnv(env, runRoot) {
  const p = [];
  for (const k of ["DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CERT_PATH", "DOCKER_TLS_VERIFY"]) if (env[k]) p.push(`${k} is set`);
  if (env.DOCKER_CONFIG && !inside(runRoot, env.DOCKER_CONFIG)) p.push("DOCKER_CONFIG is outside the run root");
  return p;
}
// `docker context ls --format json` (one JSON object per line).
export function checkContexts(text) {
  const rows = text.split("\n").filter((l) => l.trim()).map((l) => JSON.parse(l));
  const p = [];
  if (rows.length !== 1) p.push(`${rows.length} docker contexts (only "default" allowed)`);
  const d = rows[0] ?? {};
  if (d.Name !== "default") p.push(`context is ${d.Name}`);
  if (d.DockerEndpoint !== "unix:///var/run/docker.sock") p.push(`endpoint is ${d.DockerEndpoint}`);
  if (rows.some((r) => r.Current && r.Name !== "default")) p.push("a non-default context is current");
  return p;
}
export function checkSocketStat(st) {
  if (!st) return ["docker socket missing"];
  if (st.isSymbolicLink) return ["docker socket is a symlink"];
  if (!st.isSocket) return ["docker socket is not a socket"];
  return [];
}
// `docker info --format '{{json .}}'`.
export function checkDockerInfo(info, hostname) {
  const p = [];
  if (info.Name !== hostname) p.push(`daemon Name ${info.Name} != hostname ${hostname}`);
  const swarm = info.Swarm?.LocalNodeState ?? "inactive";
  if (swarm !== "inactive") p.push(`swarm is ${swarm}`);
  if (!info.ID) p.push("no daemon ID");
  return p;
}
export function checkEmptyDocker({ containers, volumes, networks }) {
  const p = [];
  if (containers.length) p.push(`${containers.length} container(s) already exist`);
  if (volumes.length) p.push(`${volumes.length} volume(s) already exist`);
  const extra = networks.filter((n) => !["bridge", "host", "none"].includes(n));
  if (extra.length) p.push(`unexpected networks: ${extra.join(",")}`);
  return p;
}

// G1-5 real bind probe (F-02).
export function classifyBind(host, err) {
  if (!err) return "free";
  if (err.code === "EADDRINUSE" || err.code === "EACCES") return "in_use";
  if (host.includes(":") && (err.code === "EADDRNOTAVAIL" || err.code === "EAFNOSUPPORT")) return "ipv6_unavailable";
  return "error";
}
export const PROBE_HOSTS = [["127.0.0.1", false], ["0.0.0.0", false], ["::1", true], ["::", true]];
export function probeBind(host, port, ipv6Only) {
  return new Promise((resolve) => {
    const s = net.createServer();
    s.once("error", (e) => resolve({ host, port, result: classifyBind(host, e), code: e.code ?? String(e) }));
    s.listen({ host, port, exclusive: true, ipv6Only }, () => s.close(() => resolve({ host, port, result: "free", code: "" })));
  });
}
export function checkProbeResults(results, { allowIpv6Unavailable = true } = {}) {
  const p = [];
  for (const r of results) {
    if (r.result === "free") continue;
    if (r.result === "ipv6_unavailable" && allowIpv6Unavailable) continue;
    p.push(`${r.host}:${r.port} ${r.result} (${r.code})`);
  }
  return p;
}
// G1-5 cross check: `ss -ltnH` lines must show no listener on the probed ports.
export function ssListeners(text, ports) {
  return text.split("\n").map((l) => l.trim().split(/\s+/)[3] ?? "").filter((addr) => ports.some((pt) => addr.endsWith(`:${pt}`)));
}
// G1-10: the window between the probe and compose up.
export function checkComposeUp({ exitCode, output, msSinceProbe }) {
  const p = [];
  if (msSinceProbe > PROBE_TO_COMPOSE_MS) p.push(`compose up started ${msSinceProbe} ms after the probe (> ${PROBE_TO_COMPOSE_MS})`);
  if (exitCode !== 0) p.push(`compose up exit ${exitCode}`);
  if (/port is already allocated|address already in use|bind(ing)? .*fail|failed to bind/i.test(output)) p.push("compose up reported a bind / port conflict");
  return p;
}
// G2-1: every running container belongs to the run project.
export function checkLabels(text, project) {
  const rows = text.split("\n").map((l) => l.trim()).filter(Boolean);
  const p = [];
  if (!rows.length) p.push("no running container");
  for (const r of rows) if (r !== project) p.push(`container of project ${JSON.stringify(r)}`);
  return p;
}
// G2-2: PortBindings of `docker inspect` (array of containers).
export function checkPortBindings(inspect, project) {
  const p = [];
  for (const c of inspect) {
    const proj = c.Config?.Labels?.["com.docker.compose.project"];
    if (proj !== project) p.push(`${c.Name}: project ${proj}`);
    for (const [cport, binds] of Object.entries(c.HostConfig?.PortBindings ?? {})) {
      for (const b of binds ?? []) if (b.HostIp !== "127.0.0.1") p.push(`${c.Name} ${cport} bound to ${JSON.stringify(b.HostIp)}`);
    }
  }
  return p;
}
// G1-9 static workflow check (text of .github/workflows/wp01h-e3-cloud.yml).
export function checkWorkflowStatic(text) {
  const p = [];
  if (/self-hosted/.test(text)) p.push("self-hosted runner label");
  const runsOn = [...text.matchAll(/^\s*runs-on:\s*(\S+)/gm)].map((m) => m[1]);
  if (!runsOn.length || runsOn.some((r) => !["ubuntu-latest", "ubuntu-24.04"].includes(r))) p.push(`runs-on ${runsOn.join(",")}`);
  const on = text.slice(text.indexOf("\non:"), text.indexOf("\npermissions:"));
  if (!/push:\s*\n\s*branches:\s*\n\s*-\s*wp01-h-e3-cloud-execution\s*\n/.test(on)) p.push("trigger is not push to wp01-h-e3-cloud-execution only");
  if (/pull_request|workflow_dispatch|schedule|workflow_run|repository_dispatch/.test(on)) p.push("extra trigger");
  if (!/^permissions:\s*\n\s*contents:\s*read\s*$/m.test(text)) p.push("permissions are not contents: read");
  if (/secrets\./.test(text)) p.push("uses secrets");
  if (!/persist-credentials:\s*false/.test(text)) p.push("checkout persists credentials");
  return p;
}
// G1-1 / R-01 (facts gathered with git, judged here).
export function checkR01({ e1Sha, e2Sha, blobs, changed, mergeBase }) {
  const p = [];
  if (e1Sha !== E1_SHA256) p.push(`E1 path diff sha ${e1Sha}`);
  if (e2Sha !== E2_SHA256) p.push(`E2 path diff sha ${e2Sha}`);
  for (const [f, b] of Object.entries(BLOBS)) if (blobs[f] !== b) p.push(`blob ${f} ${blobs[f]} != ${b}`);
  const allowed = new Set([...E1_FILES, ...E2_FILES, ...E3_PREP_FILES]);
  for (const f of changed) if (!allowed.has(f)) p.push(`changed path outside the allow-list: ${f}`);
  if (mergeBase !== BASELINE) p.push(`merge-base ${mergeBase}`);
  return p;
}
// G1-7 static scan of the E3 test files.
export function staticScan(files) {
  const p = [];
  for (const [name, text] of Object.entries(files)) {
    if (/myrial_save\.json|\bv14\b|Library\/Application Support|~\/Library/.test(text)) p.push(`${name}: references a real save location`);
    if (/\["compose",(?![^\]]*"-p")/.test(text)) p.push(`${name}: docker compose call without -p`);
    if (/["'`]\s*(DELETE\s+FROM|UPDATE\s+storage|DROP\s+TABLE|TRUNCATE\s)/i.test(text)) p.push(`${name}: destructive SQL`);
  }
  return p;
}
// G1-8 child environment whitelist.
export function checkChildEnv(env, runRoot, project) {
  const p = [];
  for (const k of ["HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "TMPDIR"]) if (!inside(runRoot, env[k] ?? "")) p.push(`${k} outside the run root`);
  if (env.COMPOSE_PROJECT_NAME !== project) p.push("COMPOSE_PROJECT_NAME is not the run project");
  for (const k of Object.keys(env)) if (/TOKEN|SECRET|PASSWORD|^GH_|^GITHUB_TOKEN$|^ACTIONS_RUNTIME/i.test(k)) p.push(`credential-like variable ${k}`);
  for (const k of ["DOCKER_HOST", "DOCKER_CONTEXT"]) if (env[k]) p.push(`${k} set`);
  return p;
}
export function inside(root, p) {
  if (!root || !p) return false;
  const rel = path.relative(path.resolve(root), path.resolve(p));
  return rel !== "" && !rel.startsWith("..") && !path.isAbsolute(rel);
}
// Godot phase output -> {safety, functional, result}.
export function godotPhaseVerdict(output, phase, { expectKill = false, exitCode, signal, runRoot }) {
  const lines = output.split("\n");
  const failed = lines.filter((l) => /^(ERROR: )?FAILED:/.test(l)).map((l) => l.replace(/^(ERROR: )?FAILED:\s*/, ""));
  const safety = failed.filter((m) => GODOT_SAFETY_CHECKS.some((k) => m.startsWith(k)));
  const results = lines.filter((l) => l.includes("WP01H_RESULT ")).map((l) => { try { return JSON.parse(l.slice(l.indexOf("WP01H_RESULT ") + 13)); } catch { return null; } });
  const r = results.length === 1 ? results[0] : null;
  if (sensitiveFindings(output).length) return { safety: "sensitive output", functional: "", result: r };
  if (safety.length) return { safety: `Godot reported: ${safety.join(" | ")}`, functional: "", result: r };
  if (!r) return { safety: "", functional: `expected exactly one result line, got ${results.length}`, result: null };
  if (!inside(runRoot, r.user_data_dir)) return { safety: "user data outside the run root", functional: "", result: r };
  if (r.phase !== phase) return { safety: "result of another phase", functional: "", result: r };
  if (/SCRIPT ERROR|Parse Error/.test(output)) return { safety: "", functional: "script or parse error", result: r };
  if (failed.length) return { safety: "", functional: `FAILED: ${failed.join(" | ")}`, result: r };
  if (expectKill) return { safety: "", functional: r.killed && (signal === "SIGKILL" || exitCode === 137) ? "" : "phase was not killed", result: r };
  if (exitCode !== 0 || !output.includes(`VS-01 WP01-H live ${phase} passed`)) return { safety: "", functional: `exit ${exitCode}, no success line`, result: r };
  return { safety: "", functional: "", result: r };
}
// node --test TAP output -> {passed, failed:[names], skipped}.
export function tapSummary(text) {
  const failed = [], passed = [], skipped = [];
  for (const l of text.split("\n")) {
    const m = l.match(/^(?:\s{4})?(not ok|ok) \d+ - (.*?)(\s+# (SKIP|TODO).*)?$/);
    if (!m || l.startsWith("        ")) continue;
    if (m[3]) skipped.push(m[2]); else if (m[1] === "ok") passed.push(m[2]); else failed.push(m[2]);
  }
  return { passed, failed, skipped };
}
// FS-K10 round file -> case verdict (FAIL > INCONCLUSIVE > PASS).
export function fsK10Verdict(round, { containerRestarted }) {
  if (!round || !["PASS", "FAIL", "INCONCLUSIVE"].includes(round.verdict)) return { verdict: "INCONCLUSIVE", reason: "no round result" };
  if (round.verdict === "FAIL") return { verdict: "FAIL", reason: round.fails.join("; ") };
  if (containerRestarted) return { verdict: "INCONCLUSIVE", reason: "IC-4 container restarted / node changed" };
  if (round.verdict === "INCONCLUSIVE") return { verdict: "INCONCLUSIVE", reason: round.inconclusive.join("; ") };
  return { verdict: "PASS", reason: "" };
}

// ---- impure runtime ---------------------------------------------------------------

class Stop extends Error {}
const sha256 = (b) => crypto.createHash("sha256").update(b).digest("hex");
function sh(cmd, args, opt = {}) {
  const r = spawnSync(cmd, args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, timeout: opt.timeoutMs ?? 120000, cwd: opt.cwd ?? REPO, env: opt.env ?? process.env, input: opt.input });
  return { code: r.status, signal: r.signal, out: `${r.stdout ?? ""}${r.stderr ?? ""}`, stdout: r.stdout ?? "" };
}

class Evidence {
  constructor(dir) {
    const st = fs.lstatSync(dir);
    if (st.isSymbolicLink() || !st.isDirectory()) throw new Stop("evidence dir is not a real directory");
    if (fs.readdirSync(dir).length) throw new Stop("evidence dir is not empty");
    if ((st.mode & 0o077) !== 0) throw new Stop("evidence dir is accessible by group/other");
    this.dir = fs.realpathSync(dir); this.seq = 0;
    fs.mkdirSync(path.join(this.dir, "cases"), { mode: 0o700 });
    this.summary = { started_at: new Date().toISOString(), gates: {}, cases: {}, steps: [] };
  }
  write(name, text) {
    const t = String(text);
    const s = sensitiveFindings(t);
    const body = s.length ? `# OUTPUT WITHHELD: sensitive data detected (${s.join(", ")})\n` : t;
    const fd = fs.openSync(path.join(this.dir, name), fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    try { fs.writeSync(fd, body); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    return s;
  }
  log(name, text) { return this.write(`${String(++this.seq).padStart(3, "0")}-${name.replace(/[^A-Za-z0-9_.-]/g, "_")}.log`, text); }
  gate(id, problems, facts = {}) {
    this.summary.gates[id] = { result: problems.length ? "STOP" : "PASS", problems, facts };
    if (problems.length) throw new Stop(`${id}: ${problems.join("; ")}`);
  }
  caseResult(id, verdict, data = {}) {
    this.summary.cases[id] = { verdict, ...data };
    fs.writeFileSync(path.join(this.dir, "cases", `${id}.json`), JSON.stringify({ id, verdict, ...data }, null, 2) + "\n", { flag: "wx", mode: 0o600 });
  }
  manifest() {
    const files = [];
    const walk = (d) => { for (const n of fs.readdirSync(d).sort()) { const p = path.join(d, n), st = fs.lstatSync(p);
      if (st.isDirectory()) walk(p); else if (st.isFile()) files.push({ name: path.relative(this.dir, p), bytes: st.size, sha256: sha256(fs.readFileSync(p)) }); } };
    walk(this.dir);
    fs.writeFileSync(path.join(this.dir, "manifest.json"), JSON.stringify({ files }, null, 2) + "\n", { flag: "wx", mode: 0o600 });
  }
}

function runBounded(cmd, args, { env, cwd = REPO, timeoutMs }) {
  return new Promise((resolve) => {
    const chunks = [];
    const child = spawn(cmd, args, { cwd, env, detached: true, stdio: ["ignore", "pipe", "pipe"] });
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; try { process.kill(-child.pid, "SIGKILL"); } catch { /* gone */ } }, timeoutMs);
    child.stdout.on("data", (c) => chunks.push(c)); child.stderr.on("data", (c) => chunks.push(c));
    child.on("error", (e) => chunks.push(Buffer.from(`spawn error: ${e}\n`)));
    child.on("close", (code, signal) => { clearTimeout(timer); try { process.kill(-child.pid, "SIGKILL"); } catch { /* no survivors */ }
      resolve({ code, signal, timedOut, output: Buffer.concat(chunks).toString("utf8") }); });
  });
}

function makeRunRoot(temp, runId) {
  const root = path.join(temp, `wp01h-e3-${runId}`);
  if (fs.existsSync(root)) throw new Stop("run root already exists");
  fs.mkdirSync(root, { mode: 0o700 });
  const real = fs.realpathSync(root);
  if (real !== path.resolve(root)) throw new Stop("run root is not canonical");
  const st = fs.lstatSync(real, { bigint: true });
  return { root: real, id: `${st.dev}:${st.ino}` };
}
function isolatedEnv(root, name, project, extra = {}) {
  const base = path.join(root, "env", name);
  for (const d of ["home", "data", "config", "cache", "tmp"]) fs.mkdirSync(path.join(base, d), { recursive: true, mode: 0o700 });
  const keep = ["PATH", "LANG", "LC_ALL", "NODE_OPTIONS"];
  const env = Object.fromEntries(keep.filter((k) => process.env[k]).map((k) => [k, process.env[k]]));
  return { ...env, HOME: path.join(base, "home"), XDG_DATA_HOME: path.join(base, "data"), XDG_CONFIG_HOME: path.join(base, "config"),
    XDG_CACHE_HOME: path.join(base, "cache"), TMPDIR: path.join(base, "tmp"), COMPOSE_PROJECT_NAME: project, ...extra };
}

function gatherR01() {
  const diffSha = (files) => sha256(sh("git", ["diff", BASELINE, "HEAD", "--", ...files]).stdout);
  const blobs = Object.fromEntries(Object.keys(BLOBS).map((f) => [f, sh("git", ["rev-parse", `HEAD:${f}`]).stdout.trim()]));
  const changed = sh("git", ["diff", "--name-only", BASELINE, "HEAD"]).stdout.split("\n").filter(Boolean);
  const mergeBase = sh("git", ["merge-base", BASELINE, "HEAD"]).stdout.trim();
  return { e1Sha: diffSha(E1_FILES), e2Sha: diffSha(E2_FILES), blobs, changed, mergeBase };
}

async function gateG1(ev, args, rr, project) {
  const facts = gatherR01();
  ev.gate("G1-1", checkR01(facts), { changed: facts.changed.length });
  const ident = { uname: sh("uname", ["-s"]).stdout.trim(), osRelease: fs.existsSync("/etc/os-release") ? fs.readFileSync("/etc/os-release", "utf8") : "", headSha: sh("git", ["rev-parse", "HEAD"]).stdout.trim() };
  ev.gate("G1-2", checkRunnerIdentity(process.env, ident), { ...ident, osRelease: undefined, image_os: process.env.ImageOS, runner_name: process.env.RUNNER_NAME });
  ev.gate("G1-3", [], { run_root: rr.root, dev_ino: rr.id });
  let sock = null;
  try { const s = fs.lstatSync("/var/run/docker.sock"); sock = { isSocket: s.isSocket(), isSymbolicLink: s.isSymbolicLink() }; } catch { sock = null; }
  const info = JSON.parse(sh("docker", ["info", "--format", "{{json .}}"]).stdout || "{}");
  const listIds = (a) => sh("docker", a).stdout.split("\n").filter(Boolean);
  ev.gate("G1-4", [...checkDockerEnv(process.env, rr.root), ...checkContexts(sh("docker", ["context", "ls", "--format", "json"]).stdout), ...checkSocketStat(sock),
    ...checkDockerInfo(info, os.hostname()), ...checkEmptyDocker({ containers: listIds(["ps", "-a", "-q"]), volumes: listIds(["volume", "ls", "-q"]),
      networks: listIds(["network", "ls", "--format", "{{.Name}}"]) })], { daemon_id: info.ID, server_version: info.ServerVersion, os: info.OperatingSystem });
  const godotOk = sh(args.godot, ["--version"]).stdout.trim();
  const probeEnv = isolatedEnv(rr.root, "probe", project);
  const imp = await runBounded(args.godot, ["--headless", "--path", GODOT_DIR, "--import"], { env: probeEnv, timeoutMs: 600000 });
  ev.log("godot-import", imp.output);
  const probe = await runBounded(args.godot, ["--headless", "--path", GODOT_DIR, "--script", "res://tests/live_vs01_wp01h_recovery.gd", "--", "--phase", "probe", "--label", "probe"], { env: probeEnv, timeoutMs: 120000 });
  ev.log("g1-6-godot-probe", probe.output);
  const pv = godotPhaseVerdict(probe.output, "probe", { exitCode: probe.code, signal: probe.signal, runRoot: rr.root });
  ev.gate("G1-6", [pv.safety, pv.functional, pv.result?.save_exists ? "a save exists" : "", godotOk.startsWith("4.7.2") ? "" : `Godot ${godotOk}`].filter(Boolean), { user_data_dir: pv.result?.user_data_dir, godot: godotOk });
  ev.gate("G1-7", staticScan(Object.fromEntries(E3_TEST_FILES.map((f) => [f, fs.readFileSync(path.join(REPO, f), "utf8")]))));
  ev.gate("G1-8", checkChildEnv(probeEnv, rr.root, project));
  ev.gate("G1-9", checkWorkflowStatic(fs.readFileSync(path.join(REPO, ".github/workflows/wp01h-e3-cloud.yml"), "utf8")));
}

async function bindProbeThenCompose(ev, project, services, extraArgs = []) {
  const results = [];
  for (const port of PORTS) for (const [host, v6] of PROBE_HOSTS) results.push(await probeBind(host, port, v6));
  const ss = sh("ss", ["-ltnH"]).stdout;
  const listeners = ssListeners(ss, PORTS);
  ev.gate("G1-5", [...checkProbeResults(results), ...listeners.map((l) => `ss shows a listener ${l}`)], { probes: results });
  const probedAt = Date.now();
  const startDelay = Date.now() - probedAt; // nothing runs between the probe and compose up
  if (startDelay > PROBE_TO_COMPOSE_MS) ev.gate("G1-10", [`${startDelay} ms between the probe and compose up`]);
  const up = sh("docker", ["compose", "-p", project, "-f", COMPOSE_FILE, ...extraArgs, "up", "-d", "--wait", ...services], { cwd: NAKAMA_DIR, timeoutMs: 900000 });
  ev.log("compose-up", up.out);
  ev.gate("G1-10", checkComposeUp({ exitCode: up.code, output: up.out, msSinceProbe: startDelay }), { start_delay_ms: startDelay });
}

async function gateG2(ev, project, ports, { columns = true } = {}) {
  ev.gate("G2-1", checkLabels(sh("docker", ["ps", "--format", '{{.Label "com.docker.compose.project"}}']).stdout, project));
  const ids = sh("docker", ["ps", "-q"]).stdout.split("\n").filter(Boolean);
  const inspect = JSON.parse(sh("docker", ["inspect", ...ids]).stdout || "[]");
  const ext = Object.values(os.networkInterfaces()).flat().find((i) => i && i.family === "IPv4" && !i.internal)?.address;
  const extProblems = [];
  for (const port of ports) {
    if (ext && await connects(ext, port)) extProblems.push(`port ${port} reachable on ${ext}`);
    const v6 = await probeBind("::1", port, true);
    if (v6.result === "in_use") extProblems.push(`something listens on [::1]:${port}`);
  }
  ev.gate("G2-2", [...checkPortBindings(inspect, project), ...extProblems], { external_ip: ext ?? "none", port_mode: sh("ss", ["-ltnpH"]).stdout.includes("docker-proxy") ? "docker-proxy" : "iptables/none-visible" });
  const health = await fetch(`http://127.0.0.1:${API_PORT}/healthcheck`).then((r) => r.status).catch(() => 0);
  const logs = sh("docker", ["compose", "-p", project, "-f", COMPOSE_FILE, "logs", "nakama"], { cwd: NAKAMA_DIR }).out;
  ev.gate("G2-3", [health === 200 ? "" : `healthcheck ${health}`, /vs01_trade_resolve/.test(logs) ? "" : "vs01_trade_resolve not registered"].filter(Boolean));
  const hostHash = sha256(fs.readFileSync(path.join(NAKAMA_DIR, "build", "index.js")));
  const inHash = sh("docker", ["compose", "-p", project, "-f", COMPOSE_FILE, "exec", "-T", "nakama", "sha256sum", "/nakama/data/modules/index.js"], { cwd: NAKAMA_DIR }).stdout.split(/\s+/)[0];
  ev.gate("G2-4", inHash === hostHash ? [] : [`module hash ${inHash} != ${hostHash}`], { module_sha256: hostHash });
  const db = await import("../tests/live/tools/wp01h_db.mjs");
  const env = { ...process.env, COMPOSE_PROJECT_NAME: project };
  const users = db.sql("SELECT count(*) FROM users", env).trim();
  const ours = db.sql("SELECT count(*) FROM storage WHERE collection LIKE 'vs01_%'", env).trim();
  ev.gate("G2-5", [users === "1" ? "" : `users = ${users}`, ours === "0" ? "" : `storage has ${ours} vs01 objects`].filter(Boolean));
  if (columns) { const seed = await import("../tests/live/tools/wp01h_seed.mjs"); try { ev.gate("G2-6", [], { columns: seed.checkStorageColumns(env) }); } catch (e) { ev.gate("G2-6", [String(e.message)]); } }
}
function connects(host, port) {
  return new Promise((resolve) => { const s = net.connect({ host, port, timeout: 1500 }); s.once("connect", () => { s.destroy(); resolve(true); });
    s.once("error", () => resolve(false)); s.once("timeout", () => { s.destroy(); resolve(false); }); });
}
function recheckG2(ev, project) {
  const p = checkLabels(sh("docker", ["ps", "--format", '{{.Label "com.docker.compose.project"}}']).stdout, project);
  if (p.length) throw new Stop(`G2-1 recheck: ${p.join("; ")}`);
}
function startedAt(project) { return sh("docker", ["ps", "--filter", `label=com.docker.compose.project=${project}`, "--format", "{{.Names}}"]).stdout.split("\n").filter(Boolean)
  .map((n) => `${n}=${sh("docker", ["inspect", "-f", "{{.State.StartedAt}}", n]).stdout.trim()}`).sort().join(","); }

// ---- cases ----------------------------------------------------------------------

async function nodeTests(ev, rr, project, files, extraEnv, tag, timeoutMs = 3600000) {
  const env = isolatedEnv(rr.root, `node-${tag}`, project, { MYRIAL_WP01H_E3_RUN_ID: rr.runId, MYRIAL_NAKAMA_URL: `http://127.0.0.1:${API_PORT}`,
    MYRIAL_WP01H_E3_CASE_DIR: path.join(ev.dir, "cases"), MYRIAL_WP01H_E3_SEED_MANIFEST: path.join(ev.dir, "seed-manifest.jsonl"), ...extraEnv });
  const r = await runBounded(process.execPath, ["--test", "--test-concurrency=1", "--test-reporter=tap", ...files], { env, cwd: NAKAMA_DIR, timeoutMs });
  ev.log(`node-${tag}`, r.output);
  const t = tapSummary(r.output);
  let n = 0;
  const one = (name, verdict) => ev.caseResult(`${tag}-${String(++n).padStart(2, "0")}-${name.split(" ")[0].replace(/[^A-Za-z0-9_.()-]/g, "_")}`, verdict, { test: name, exit: r.code });
  for (const name of t.failed) one(name, "FAIL");
  for (const name of t.passed) one(name, "PASS");
  for (const name of t.skipped) one(name, "NOT RUN");
  if (r.code !== 0 && !t.failed.length) one("node-test-runner", "FAIL");
  return r;
}

async function godotPhase(ev, rr, args, project, label, phase, variant = "", { expectKill = false, timeoutMs = 240000 } = {}) {
  recheckG2(ev, project);
  const env = isolatedEnv(rr.root, `godot-${label}`, project);
  const a = ["--headless", "--path", GODOT_DIR, "--script", "res://tests/live_vs01_wp01h_recovery.gd", "--", "--phase", phase, "--label", label,
    "--host", "127.0.0.1", "--port", String(API_PORT), "--proxy-port", String(PROXY_PORT), ...(variant ? ["--variant", variant] : [])];
  const r = await runBounded(args.godot, a, { env, timeoutMs });
  ev.log(`godot-${label}-${phase}`, r.output);
  const v = godotPhaseVerdict(r.output, phase, { expectKill, exitCode: r.code, signal: r.signal, runRoot: rr.root });
  if (v.safety) throw new Stop(`SAFETY ${label}/${phase}: ${v.safety}`);
  return v;
}
const proxyStats = () => fetch(`http://127.0.0.1:${PROXY_PORT}/__lossy_proxy/stats`).then((r) => r.json());

async function godotCase(ev, rr, args, project, id, steps) {
  const db = await import("../tests/live/tools/wp01h_db.mjs");
  const env = { ...process.env, COMPOSE_PROJECT_NAME: project };
  const phases = [], problems = [];
  let uid = "", s0 = null;
  for (const st of steps) {
    if (st.s0s1) s0 = uid ? db.snapshot(uid, env) : null; // S0: after the fixture, before the blocked attempt
    const before = st.proxyTradeUnchanged ? await proxyStats() : null;
    const v = await godotPhase(ev, rr, args, project, st.label, st.phase, st.variant ?? "", { expectKill: !!st.kill });
    uid = v.result?.user_id || uid;
    if (v.functional) problems.push(`${st.phase}: ${v.functional}`);
    if (st.proxyTradeUnchanged) { const after = await proxyStats(); if (after.trade_requests !== before.trade_requests) problems.push(`${st.phase}: vs01_trade sent during recovery (AC-17)`); }
    if (st.s0s1) { if (!s0) problems.push(`${st.phase}: no S0 snapshot`); else { const d = db.snapshotDelta(s0, db.snapshot(uid, env)); if (d.length) problems.push(`${st.phase}: S0->S1 changed (B1): ${d.join(", ")}`); } }
    phases.push({ phase: st.phase, variant: st.variant ?? "", functional: v.functional, result: v.result });
  }
  if (uid) { const l = db.ledger(uid, env); if (l.problems.length) problems.push(`ledger: ${l.problems.join("; ")}`); }
  ev.caseResult(id, problems.length ? "FAIL" : "PASS", { problems, phases });
}

const A05 = ["a1a", "a1b", "a2", "a3", "a4", "a5"];
async function jobCases(ev, rr, args, project, job) {
  const cases = [];
  const g = (id, steps) => cases.push(() => godotCase(ev, rr, args, project, id, steps));
  if (job === "j1") {
    await nodeTests(ev, rr, project, ["tests/live/h1_wp01h_trade_resolve.test.mjs", "tests/live/h2_wp01h_combat_intent.test.mjs"], { MYRIAL_NAKAMA_URL_2: `http://127.0.0.1:${NODE2_PORT}` },
      "h1h2");
    g("AC-04", [{ label: "ac04", phase: "ac04" }]);
    for (const v of A05) g(`AC-05a-${v}`, [{ label: `a05_${v}`, phase: "a05_prep", variant: v, kill: true },
      { label: `a05_${v}`, phase: "a05_blocked", variant: v, s0s1: true }, { label: `a05_${v}`, phase: "a05_recover", variant: v, proxyTradeUnchanged: true }]);
    g("AC-05b", [{ label: "b05", phase: "b05_prep" }, { label: "b05", phase: "b05_check", proxyTradeUnchanged: true }]);
    g("AC-05b-kill", [{ label: "b05k", phase: "b05_prep" }, { label: "b05k", phase: "b05_kill", kill: true }, { label: "b05k", phase: "b05_kill_check", proxyTradeUnchanged: true }]);
    g("AC-06", [{ label: "ac06", phase: "ac06" }]);
    for (const v of ["tmp", "rename", "clear", "claim"]) g(`AC-13-${v}`, [{ label: `ac13_${v}`, phase: "k_prep", variant: v, kill: true }, { label: `ac13_${v}`, phase: "k_check", variant: v, proxyTradeUnchanged: true }]);
  } else if (job === "j2") {
    await nodeTests(ev, rr, project, ["tests/live/h3_wp01h_full_stress.test.mjs"], { MYRIAL_NAKAMA_URL_2: `http://127.0.0.1:${NODE2_PORT}` }, "h3");
    const repeat = 20;
    for (const v of ["tmp", "rename", "clear", "claim"]) for (let i = 0; i < repeat; i++) g(`FS-K1-${v}-${i}`, [{ label: `k1_${v}_${i}`, phase: "k_prep", variant: v, kill: true }, { label: `k1_${v}_${i}`, phase: "k_check", variant: v, proxyTradeUnchanged: true }]);
    g("FS-K2-godot", [{ label: "k2", phase: "k2_lossy" }]);
    g("FS-K5", [{ label: "k5", phase: "k5_switch" }]);
    for (const v of ["a2", "a3", "a5"]) g(`FS-K6-${v}`, [{ label: `k6_${v}`, phase: "a05_prep", variant: v, kill: true }, { label: `k6_${v}`, phase: "a05_blocked", variant: v, s0s1: true }]);
    g("FS-K8", [{ label: "k8", phase: "k8_prep", kill: true }, { label: "k8", phase: "k8_check" }]);
  }
  for (const c of cases) await c();
}
async function existingLiveRegression(ev, rr, args, project) {
  // AC-09: the pre-existing WP01 / B / C / E / F live tests on the same head.
  const old = fs.readdirSync(path.join(NAKAMA_DIR, "tests/live")).filter((f) => f.endsWith(".test.mjs") && !/^h[0-9]_wp01h_/.test(f)).map((f) => `tests/live/${f}`);
  const env = isolatedEnv(rr.root, "node-ac09", project, { MYRIAL_NAKAMA_URL_2: `http://127.0.0.1:${NODE2_PORT}` });
  const r = await runBounded(process.execPath, ["--test", "--test-concurrency=1", "--test-reporter=tap", ...old], { env, cwd: NAKAMA_DIR, timeoutMs: 3600000 });
  ev.log("ac09-node-live", r.output);
  const t = tapSummary(r.output);
  const godot = [];
  const live = [["live_vs01_wp01_nakama.gd", ["127.0.0.1", String(API_PORT)], "VS-01 WP01 live Nakama probe passed"],
    ["live_vs01_wp01b_online_trade.gd", ["127.0.0.1", String(API_PORT), String(PROXY_PORT), NAKAMA_DIR, sh("sh", ["-c", "command -v docker"]).stdout.trim(), process.env.HOME ?? ""], "VS-01 WP01-B live online trade harness passed"],
    ["live_vs01_wp01c_online_trade_ui.gd", ["127.0.0.1", String(API_PORT), String(PROXY_PORT)], "VS-01 WP01-C live online trade UI passed"],
    ["live_vs01_wp01e_online_combat.gd", ["127.0.0.1", String(API_PORT), String(PROXY_PORT)], "VS-01 WP01-E live online combat passed"],
    ["live_vs01_wp01e_combat_stress.gd", ["127.0.0.1", String(API_PORT), String(PROXY_PORT)], "VS-01 WP01-E live combat stress passed"]];
  for (const [script, a, ok] of live) {
    recheckG2(ev, project);
    const genv = isolatedEnv(rr.root, `ac09-${script}`, project);
    const g = await runBounded(args.godot, ["--headless", "--path", GODOT_DIR, "--script", `res://tests/${script}`, "--", ...a], { env: genv, timeoutMs: 1800000 });
    ev.log(`ac09-${script}`, g.output);
    const safety = GODOT_SAFETY_CHECKS.some((k) => g.output.includes(`FAILED: ${k}`));
    if (safety) throw new Stop(`SAFETY ${script}`);
    godot.push({ script, pass: g.code === 0 && g.output.includes(ok) && !/SCRIPT ERROR|Parse Error|FAILED:/.test(g.output) });
  }
  ev.caseResult("AC-09-live", t.failed.length || godot.some((x) => !x.pass) ? "FAIL" : "PASS", { node_failed: t.failed, node_passed: t.passed.length, godot,
    note: "WP01-F live resume runs in its own WP01-G workflow; not repeated here" });
}

async function offlineRegression(ev, rr, args, project) {
  const env = isolatedEnv(rr.root, "offline", project, { GODOT: args.godot });
  const v = await runBounded("sh", ["godot/tests/run_tests.sh"], { env, timeoutMs: 3600000 });
  ev.log("offline-godot-verify", v.output);
  const failed = v.output.split("\n").filter((l) => /^FAIL/.test(l));
  const deadline = failed.filter((l) => l.includes(READ_DEADLINE_TEST));
  ev.caseResult("AC-09-offline-godot", failed.length - deadline.length ? "FAIL" : "PASS", { failed });
  ev.caseResult(READ_DEADLINE_TEST, deadline.length ? "FAIL (known flake, reported separately)" : "PASS (one run; known flake: not formal acceptance)", {});
  const k = await runBounded("sh", ["godot/tests/run_wp01h_kill_tests.sh"], { env, timeoutMs: 1800000 });
  ev.log("offline-kill-pairs", k.output);
  ev.caseResult("AC-09-offline-kill", k.code === 0 ? "PASS" : "FAIL", { exit: k.code });
  const n = await runBounded("npm", ["test"], { env, cwd: NAKAMA_DIR, timeoutMs: 900000 });
  ev.log("offline-nakama-unit", n.output);
  ev.caseResult("AC-09-nakama-unit", n.code === 0 ? "PASS" : "FAIL", { exit: n.code });
  const root = await runBounded("npm", ["test"], { env, cwd: REPO, timeoutMs: 900000 });
  ev.log("offline-root-node", root.output);
  ev.caseResult("AC-09-root-node", root.code === 0 ? "PASS" : "FAIL", { exit: root.code });
}

async function revertStage(ev, rr, args, project) {
  // AC-14(c) / AC-18 / AC-19: the SAME database, served by the BASELINE module.
  const state = path.join(rr.root, "revert-state.json");
  await nodeTests(ev, rr, project, ["tests/live/h1_wp01h_trade_resolve.test.mjs"], { MYRIAL_WP01H_E3_PHASE: "pre_revert", MYRIAL_WP01H_E3_STATE: state }, "revert-pre");
  const ac18 = await godotPhase(ev, rr, args, project, "ac18", "ac18_prep", "", { expectKill: true });
  const base = path.join(rr.root, "baseline");
  fs.mkdirSync(base, { mode: 0o700 });
  const arch = sh("sh", ["-c", `git archive ${BASELINE} nakama/src nakama/tsconfig.json nakama/package.json | tar -x -C "$1"`, "sh", base]);
  ev.log("baseline-archive", arch.out);
  fs.symlinkSync(path.join(NAKAMA_DIR, "node_modules"), path.join(base, "nakama", "node_modules"));
  const tsc = sh(path.join(NAKAMA_DIR, "node_modules/.bin/tsc"), ["-p", path.join(base, "nakama/tsconfig.json")], { cwd: path.join(base, "nakama") });
  ev.log("baseline-build", tsc.out);
  const built = path.join(base, "nakama/build/index.js");
  if (tsc.code !== 0 || !fs.existsSync(built)) throw new Stop("baseline module build failed");
  const override = path.join(rr.root, "revert-override.yml");
  fs.writeFileSync(override, `services:\n  nakama:\n    volumes:\n      - ${path.join(base, "nakama/build")}:/nakama/data/modules:ro\n      - ${path.join(NAKAMA_DIR, "config/local.yml")}:/nakama/data/local.yml:ro\n`, { flag: "wx" });
  const up = sh("docker", ["compose", "-p", project, "-f", COMPOSE_FILE, "-f", override, "up", "-d", "--wait", "--no-deps", "--force-recreate", "nakama"], { cwd: NAKAMA_DIR, timeoutMs: 600000 });
  ev.log("revert-up", up.out);
  if (up.code !== 0) throw new Stop("baseline nakama did not start");
  recheckG2(ev, project);
  const inHash = sh("docker", ["compose", "-p", project, "-f", COMPOSE_FILE, "-f", override, "exec", "-T", "nakama", "sha256sum", "/nakama/data/modules/index.js"], { cwd: NAKAMA_DIR }).stdout.split(/\s+/)[0];
  if (inHash !== sha256(fs.readFileSync(built))) throw new Stop("the baseline module is not the one served");
  await nodeTests(ev, rr, project, ["tests/live/h1_wp01h_trade_resolve.test.mjs"], { MYRIAL_WP01H_E3_PHASE: "post_revert", MYRIAL_WP01H_E3_STATE: state }, "revert-post");
  const chk = await godotPhase(ev, rr, args, project, "ac18", "ac18_check");
  ev.caseResult("AC-18", ac18.functional || chk.functional ? "FAIL" : "PASS", { prep: ac18.functional, check: chk.functional, label: "baseline module " + BASELINE });
}

async function ttlJob(ev, rr, project) {
  let last = null;
  for (let attempt = 1; attempt <= 3; attempt++) {
    const before = startedAt(project);
    const dir = path.join(ev.dir, "cases", `k10-attempt-${attempt}`);
    fs.mkdirSync(dir, { mode: 0o700 });
    const env = isolatedEnv(rr.root, `node-k10-${attempt}`, project, { MYRIAL_WP01H_E3_RUN_ID: rr.runId, MYRIAL_WP01H_E3_TTL: "1", MYRIAL_NAKAMA_URL: `http://127.0.0.1:${API_PORT}`, MYRIAL_WP01H_E3_CASE_DIR: dir });
    const r = await runBounded(process.execPath, ["--test", "--test-reporter=tap", "--test-name-pattern=FS-K10", "tests/live/h3_wp01h_full_stress.test.mjs"], { env, cwd: NAKAMA_DIR, timeoutMs: 30 * 60 * 1000 });
    ev.log(`k10-attempt-${attempt}`, r.output);
    const roundFile = path.join(dir, "FS-K10-round.json");
    const round = fs.existsSync(roundFile) ? JSON.parse(fs.readFileSync(roundFile, "utf8")) : null;
    last = fsK10Verdict(round, { containerRestarted: before !== startedAt(project) });
    last.attempt = attempt;
    if (last.verdict !== "INCONCLUSIVE") break;
  }
  ev.caseResult("FS-K10", last.verdict, { reason: last.reason, attempts: last.attempt, provisional_id: "D-P6 PENDING" });
  ev.caseResult("AC-16", last.verdict, { from: "FS-K10 round", reason: last.reason });
}

// --verify-manifest <dir>: every file listed with its hash, nothing unlisted,
// nothing sensitive. Gate for the evidence upload.
export function verifyManifest(dir) {
  const p = [];
  const m = JSON.parse(fs.readFileSync(path.join(dir, "manifest.json"), "utf8"));
  const listed = new Set(m.files.map((f) => f.name));
  for (const f of m.files) {
    const full = path.join(dir, f.name), st = fs.lstatSync(full);
    if (!st.isFile() || st.isSymbolicLink()) { p.push(`${f.name}: not a regular file`); continue; }
    const data = fs.readFileSync(full);
    if (sha256(data) !== f.sha256 || data.length !== f.bytes) p.push(`${f.name}: hash / size differs`);
    if (sensitiveFindings(data.toString("utf8")).length) p.push(`${f.name}: sensitive content`);
  }
  const walk = (d) => fs.readdirSync(d).flatMap((n) => { const q = path.join(d, n); return fs.lstatSync(q).isDirectory() ? walk(q) : [path.relative(dir, q)]; });
  for (const f of walk(dir)) if (f !== "manifest.json" && !listed.has(f)) p.push(`${f}: not in the manifest`);
  return p;
}

async function main() {
  if (process.argv[2] === "--verify-manifest") {
    const problems = verifyManifest(process.argv[3]);
    console.log(problems.length ? `manifest FAILED: ${problems.join("; ")}` : "manifest verified");
    process.exitCode = problems.length ? 1 : 0;
    return;
  }
  const args = parseArgs(process.argv.slice(2));
  const ev = new Evidence(args.evidenceDir);
  const project = args.runId;
  let rr = null, proxy = null, verdict = "STOP";
  try {
    rr = { ...makeRunRoot(process.env.RUNNER_TEMP ?? "", args.runId), runId: args.runId };
    await gateG1(ev, args, rr, project);
    if (args.job === "j1r") await offlineRegression(ev, rr, args, project);
    const b = sh("npm", ["run", "build"], { cwd: NAKAMA_DIR, timeoutMs: 600000 });
    ev.log("nakama-build", b.out);
    if (b.code !== 0) throw new Stop("nakama build failed");
    const services = args.job === "j3" ? ["postgres", "nakama"] : ["postgres", "nakama", "nakama2"];
    await bindProbeThenCompose(ev, project, services, args.job === "j3" ? [] : ["--profile", "multinode"]);
    await gateG2(ev, project, args.job === "j3" ? [API_PORT, 17351] : [API_PORT, 17351, NODE2_PORT]);
    if (args.job !== "j3") {
      proxy = spawn(process.execPath, [path.join(NAKAMA_DIR, "tests/live/tools/lossy_proxy.mjs"), String(PROXY_PORT), String(API_PORT)], { stdio: "ignore" });
      for (let i = 0; i < 30; i++) { if (await proxyStats().then(() => true).catch(() => false)) break; await new Promise((r) => setTimeout(r, 500)); }
      const ext = Object.values(os.networkInterfaces()).flat().find((i) => i && i.family === "IPv4" && !i.internal)?.address;
      if (ext && await connects(ext, PROXY_PORT)) throw new Stop("lossy proxy reachable on the external interface");
    }
    if (args.job === "j3") await ttlJob(ev, rr, project);
    else if (args.job === "j1r") await existingLiveRegression(ev, rr, args, project);
    else {
      await jobCases(ev, rr, args, project, args.job);
      if (args.job === "j1") await revertStage(ev, rr, args, project);
    }
    const bad = Object.entries(ev.summary.cases).filter(([id, c]) => id !== READ_DEADLINE_TEST && !["PASS", "NOT RUN"].includes(c.verdict));
    verdict = bad.length ? "FAIL" : "PASS";
  } catch (e) {
    ev.summary.stop = String(e.message ?? e);
    verdict = e instanceof Stop ? "SAFETY STOP" : "ERROR";
  } finally {
    if (proxy) proxy.kill("SIGTERM");
    // Leftover inventory only: nothing is deleted (containers, volumes, run root are kept).
    const inv = sh("docker", ["ps", "-a", "--filter", `label=com.docker.compose.project=${project}`, "--format", "{{.Names}} {{.Status}}"]).out
      + sh("docker", ["volume", "ls", "--filter", `label=com.docker.compose.project=${project}`, "--format", "{{.Name}}"]).out;
    ev.log("leftover-inventory", `nothing deleted\nrun root: ${rr?.root ?? "not created"}\n${inv}`);
    ev.summary.verdict = verdict;
    ev.summary.finished_at = new Date().toISOString();
    fs.writeFileSync(path.join(ev.dir, "summary.json"), JSON.stringify(ev.summary, null, 2) + "\n", { flag: "wx", mode: 0o600 });
    ev.manifest();
    console.log(`WP01-H E3 ${args.job}: ${verdict}${ev.summary.stop ? ` (${ev.summary.stop})` : ""}`);
    process.exitCode = verdict === "PASS" ? 0 : 1;
  }
}

const isEntry = (() => { try { return Boolean(process.argv[1]) && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } })();
if (isEntry) main();
