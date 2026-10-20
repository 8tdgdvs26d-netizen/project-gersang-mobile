#!/usr/bin/env node
// VS-01 WP01-F — bounded acceptance launcher for ONE disposable GitHub-hosted
// runner (.github/workflows/wp01f-cloud.yml). Refuses to run anywhere else.
//
//   node nakama/scripts/run_wp01f_bounded.mjs --run-id <wp01f_...> --evidence-dir <abs> --godot <abs>
//   node nakama/scripts/run_wp01f_bounded.mjs --run-id <wp01f_...> --evidence-dir <abs> --cleanup-only
//
// What it does, in order, and it STOPS at the first failure (later steps are
// recorded as NOT RUN, then the cleanup below runs):
//   1. creates one run-owned work root (isolated HOME / XDG / TMPDIR for Godot)
//      and records it, with a sentinel, BEFORE anything else starts;
//   2. Full Normal Regression: root Node tests, Nakama build + unit tests,
//      Godot import, a user-data-folder probe, then every godot/tests/verify_*.gd
//      as its own Godot process;
//   3. starts ONE Docker Compose project named after this run (its own
//      PostgreSQL volume), then the WP01-F live phases, each its own Godot
//      process: seed -> readback (fresh process) -> Nakama restart -> readback
//      -> targeted stress;
//   4. compares the printed results ACROSS processes itself (Trade and Hero
//      revisions checked separately), checks the checkout for tracked changes,
//      and writes everything to the evidence directory.
//
// Every child command has its own timeout and runs in its own process group;
// a timed-out group is stopped (TERM, then KILL). Right after each child ends,
// its group is checked for survivors.
//
// Cleanup (also run alone by --cleanup-only) touches ONLY what this run
// recorded: the Compose project of this run (down -v) and the recorded work
// root, after re-checking its canonical path, device / inode, sentinel, name
// and parent, and that the tree holds no symbolic link or mount crossing. If
// any check fails the data is KEPT and the reason recorded. No glob, no
// unresolved path, nothing outside the recorded root. Cleanup is best effort
// on a disposable runner: it is evidence, never a Gate X / FS-08 PASS.
//
// Secrets: the two disposable account passwords are random per run, passed
// to Godot only through its environment and redacted from every log.

import { spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = fs.realpathSync(path.resolve(HERE, "../.."));
const NAKAMA_DIR = path.join(REPO, "nakama");
const GODOT_DIR = path.join(REPO, "godot");
const COMPOSE_FILE = path.join(NAKAMA_DIR, "docker-compose.yml");
const LIVE_SCRIPT = "res://tests/live_vs01_wp01f_online_progress_resume.gd";
const NEW_VERIFY = "verify_vs01_wp01f_resume_mode";
const HOST = "127.0.0.1";
const API_PORT = 17350;
const RUN_ID_RE = /^wp01f_[a-z0-9_]{1,60}$/;
const PROJECT_RE = /^wp01f_[a-z0-9_]{1,60}$/;
const ROOT_PREFIX = "wp01f-root-";
const SENTINEL = ".wp01f-run.json";
const STATE_FILE = "run-state.json";
const EXPECTED_GODOT = "4.7.2";
const MIN_VERIFY_SCRIPTS = 72; // 71 existing + the new WP01-F one

const TIMEOUT_MS = {
  nodeTest: 10 * 60e3,
  npmCi: 10 * 60e3,
  nakamaTest: 10 * 60e3,
  godotImport: 10 * 60e3,
  probe: 2 * 60e3,
  verify: 4 * 60e3,
  composeUp: 15 * 60e3,
  health: 3 * 60e3,
  seed: 4 * 60e3,
  readback: 3 * 60e3,
  restart: 5 * 60e3,
  stress: 7 * 60e3,
  composeDown: 5 * 60e3,
  short: 60e3,
};
const KILL_GRACE_MS = 5000;

// --- Arguments and environment ------------------------------------------------

function parseArgs(argv) {
  const out = { runId: "", evidenceDir: "", godot: "", cleanupOnly: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--cleanup-only") out.cleanupOnly = true;
    else if (a === "--run-id") out.runId = argv[++i] ?? "";
    else if (a === "--evidence-dir") out.evidenceDir = argv[++i] ?? "";
    else if (a === "--godot") out.godot = argv[++i] ?? "";
    else throw new Error(`unknown argument: ${a}`);
  }
  if (!RUN_ID_RE.test(out.runId)) throw new Error("--run-id must match " + RUN_ID_RE);
  if (!path.isAbsolute(out.evidenceDir)) throw new Error("--evidence-dir must be an absolute path");
  if (!out.cleanupOnly && !path.isAbsolute(out.godot)) throw new Error("--godot must be an absolute path");
  return out;
}

// Fail closed anywhere but a GitHub-hosted runner (never a Mac account).
function requireDisposableRunner() {
  const problems = [];
  if (process.env.GITHUB_ACTIONS !== "true") problems.push("GITHUB_ACTIONS is not 'true'");
  if (process.env.RUNNER_ENVIRONMENT !== "github-hosted") problems.push("RUNNER_ENVIRONMENT is not 'github-hosted'");
  if (process.platform !== "linux") problems.push(`platform is ${process.platform}, not linux`);
  const temp = process.env.RUNNER_TEMP ?? "";
  if (!path.isAbsolute(temp)) problems.push("RUNNER_TEMP is not an absolute path");
  if (problems.length > 0) throw new Error("REFUSED: not a disposable GitHub-hosted runner: " + problems.join("; "));
  return temp;
}

// An existing real directory (not a symbolic link) whose canonical path is itself.
function requireRealDir(p, label) {
  const st = fs.lstatSync(p);
  if (st.isSymbolicLink() || !st.isDirectory()) throw new Error(`${label} is not a real directory: ${p}`);
  const real = fs.realpathSync(p);
  if (real !== path.resolve(p)) throw new Error(`${label} is not canonical: ${p} -> ${real}`);
  return real;
}

// --- Evidence ------------------------------------------------------------------

class Evidence {
  constructor(dir, runId) {
    this.dir = dir;
    this.runId = runId;
    this.secrets = [];
    this.seq = 0;
    this.summary = { run_id: runId, started_at: new Date().toISOString(), steps: [], comparisons: [], results: {}, verdict: "RUNNING" };
  }

  redact(text) {
    let s = String(text);
    for (const secret of this.secrets) if (secret) s = s.split(secret).join("***REDACTED***");
    return s;
  }

  log(line) {
    const s = this.redact(line);
    console.log(s);
    fs.appendFileSync(path.join(this.dir, "launcher.log"), s + "\n");
  }

  file(name, content) {
    fs.writeFileSync(path.join(this.dir, name), this.redact(content));
  }

  save() {
    this.file("summary.json", JSON.stringify(this.summary, null, 2) + "\n");
  }

  nextLogName(name) {
    this.seq += 1;
    return `${String(this.seq).padStart(3, "0")}-${name.replace(/[^A-Za-z0-9_.-]/g, "_")}.log`;
  }
}

// --- Bounded child processes ---------------------------------------------------

function groupAlive(pgid) {
  try {
    process.kill(-pgid, 0);
    return "yes";
  } catch (e) {
    if (e.code === "ESRCH") return "no";
    return "unknown"; // EPERM or anything else: cannot prove it is gone
  }
}

function stopGroup(pgid, signal) {
  try {
    process.kill(-pgid, signal);
  } catch {
    // already gone
  }
}

// Runs one command in its OWN process group with its own timeout. Output is
// kept in memory (for parsing) and written, redacted, to its own log file.
function runBounded(ev, name, cmd, args, { cwd = REPO, env = process.env, timeoutMs }) {
  return new Promise((resolve) => {
    const logName = ev.nextLogName(name);
    const display = [cmd, ...args].join(" ");
    const started = Date.now();
    const chunks = [];
    let timedOut = false;
    let closed = false;
    let child;
    try {
      child = spawn(cmd, args, { cwd, env, detached: true, stdio: ["ignore", "pipe", "pipe"] });
    } catch (e) {
      const rec = { name, command: ev.redact(display), cwd: path.relative(REPO, cwd) || ".", exit_code: null, signal: null,
        timed_out: false, survivors: "no", duration_ms: 0, log: logName, error: String(e) };
      ev.file(logName, `$ ${display}\nspawn failed: ${e}\n`);
      resolve({ rec, output: "" });
      return;
    }
    const pgid = child.pid;
    child.stdout.on("data", (c) => chunks.push(c));
    child.stderr.on("data", (c) => chunks.push(c));
    const timer = setTimeout(() => {
      timedOut = true;
      stopGroup(pgid, "SIGTERM");
      // KILL only while this run's leader is still running: its group id
      // cannot have been reused yet.
      setTimeout(() => { if (!closed) stopGroup(pgid, "SIGKILL"); }, KILL_GRACE_MS).unref();
    }, timeoutMs);
    child.on("error", (e) => chunks.push(Buffer.from(`\nchild error: ${e}\n`)));
    child.on("close", (code, signal) => {
      closed = true;
      clearTimeout(timer);
      // The group was created by this spawn; checked immediately after its
      // leader ended. Survivors are stopped and the step is marked.
      let survivors = groupAlive(pgid);
      if (survivors === "yes") {
        stopGroup(pgid, "SIGKILL");
      }
      const output = Buffer.concat(chunks).toString("utf8");
      const rec = {
        name, command: ev.redact(display), cwd: path.relative(REPO, cwd) || ".",
        exit_code: code, signal, timed_out: timedOut, survivors,
        duration_ms: Date.now() - started, log: logName,
      };
      ev.file(logName, `$ ${display}\n# cwd=${rec.cwd} timeout_ms=${timeoutMs}\n${output}\n# exit=${code} signal=${signal} timed_out=${timedOut} survivors=${survivors} duration_ms=${rec.duration_ms}\n`);
      resolve({ rec, output });
    });
  });
}

// Godot strict pass rule (same rules as godot/tests/run_tests.sh, WP01-B-T01):
// exit 0, its own success line, no parse / script error, no FAILED report.
function godotVerdict(output, successPattern) {
  const lines = output.split("\n");
  if (/SCRIPT ERROR|Parse Error/.test(output)) return "script or parse error";
  if (lines.some((l) => /^(ERROR: )?FAILED:/.test(l))) return "test reported FAILED";
  const success = lines.filter((l) => !/^(ERROR: )?FAILED:/.test(l)).some((l) => successPattern.test(l));
  if (!success) return "no success line";
  return "";
}

function results(output) {
  const out = [];
  for (const line of output.split("\n")) {
    const i = line.indexOf("WP01F_RESULT ");
    if (i < 0) continue;
    try {
      out.push(JSON.parse(line.slice(i + "WP01F_RESULT ".length)));
    } catch {
      out.push({ unparsable: true });
    }
  }
  return out;
}

// --- Run state, work root and cleanup ------------------------------------------

function statePath(evidenceDir) {
  return path.join(evidenceDir, STATE_FILE);
}

function writeState(ev, state) {
  fs.writeFileSync(statePath(ev.dir), JSON.stringify(state, null, 2) + "\n");
}

function readState(evidenceDir) {
  const p = statePath(evidenceDir);
  if (!fs.existsSync(p)) return null;
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

function composeProject(runId) {
  return runId; // already [a-z0-9_]; also matches PROJECT_RE
}

function createRoot(ev, runId, runnerTemp) {
  const base = requireRealDir(runnerTemp, "RUNNER_TEMP");
  const root = fs.realpathSync(fs.mkdtempSync(path.join(base, `${ROOT_PREFIX}${runId}-`)));
  fs.chmodSync(root, 0o700);
  for (const sub of ["home", "xdg-data", "xdg-config", "xdg-cache", "tmp"]) fs.mkdirSync(path.join(root, sub), { mode: 0o700 });
  const st = fs.statSync(root);
  const sentinel = { run_id: runId, root, dev: st.dev, ino: st.ino, created_at: new Date().toISOString() };
  fs.writeFileSync(path.join(root, SENTINEL), JSON.stringify(sentinel) + "\n", { flag: "wx", mode: 0o600 });
  const state = { run_id: runId, base, root, root_dev: st.dev, root_ino: st.ino, compose_project: composeProject(runId),
    compose_started: false, cleaned: false };
  writeState(ev, state);
  ev.log(`work root created: ${root}`);
  return state;
}

// Re-checks the recorded root before any use or removal. Returns "" if it is
// exactly what this run created, otherwise the reason.
function rootProblem(state) {
  const root = state.root;
  if (typeof root !== "string" || !path.isAbsolute(root)) return "recorded root is not an absolute path";
  if (path.dirname(root) !== state.base) return "root is not directly under the recorded RUNNER_TEMP";
  if (!path.basename(root).startsWith(`${ROOT_PREFIX}${state.run_id}-`)) return "root name does not carry this run id";
  let st;
  try {
    st = fs.lstatSync(root);
  } catch (e) {
    return e.code === "ENOENT" ? "absent" : `cannot stat root: ${e.code}`;
  }
  if (st.isSymbolicLink() || !st.isDirectory()) return "root is not a real directory";
  if (fs.realpathSync(root) !== root) return "root canonical path changed";
  if (st.dev !== state.root_dev || st.ino !== state.root_ino) return "root device / inode changed";
  let sentinel;
  try {
    sentinel = JSON.parse(fs.readFileSync(path.join(root, SENTINEL), "utf8"));
  } catch {
    return "sentinel missing or unreadable";
  }
  if (sentinel.run_id !== state.run_id || sentinel.root !== root || sentinel.dev !== st.dev || sentinel.ino !== st.ino) return "sentinel does not match this run";
  return "";
}

// Walks the tree WITHOUT following links. Any symbolic link, other special
// entry outside regular files / directories, or a different device is a reason to keep it.
function treeProblem(root, dev) {
  const stack = [root];
  let entries = 0;
  while (stack.length > 0) {
    const dir = stack.pop();
    for (const name of fs.readdirSync(dir)) {
      const p = path.join(dir, name);
      const st = fs.lstatSync(p);
      entries += 1;
      if (st.isSymbolicLink()) return { problem: `symbolic link inside root: ${p}`, entries };
      if (st.dev !== dev) return { problem: `different device (mount) inside root: ${p}`, entries };
      if (st.isDirectory()) stack.push(p);
      else if (!st.isFile()) return { problem: `special file inside root: ${p}`, entries };
    }
  }
  return { problem: "", entries };
}

async function cleanup(ev, runId) {
  const report = { compose: "not started", root: "not created", kept_reason: "" };
  const state = readState(ev.dir);
  if (state === null) {
    report.root = "no run state: this launcher created nothing to clean";
    ev.log("cleanup: " + report.root);
    return report;
  }
  if (state.run_id !== runId) {
    report.kept_reason = "run state belongs to another run id";
    ev.log("cleanup: STOP, " + report.kept_reason);
    return report;
  }
  if (state.cleaned) {
    ev.log("cleanup: already done by the main run");
    return state.cleanup_report ?? { compose: "done earlier", root: "done earlier", kept_reason: "" };
  }
  // 1. This run's Compose project only.
  if (state.compose_started) {
    const project = state.compose_project;
    if (project !== composeProject(runId) || !PROJECT_RE.test(project)) {
      report.compose = "KEPT: recorded project name is not this run's";
    } else {
      const down = await runBounded(ev, "cleanup-compose-down", "docker",
        ["compose", "-p", project, "-f", COMPOSE_FILE, "down", "-v", "--remove-orphans", "--timeout", "10"],
        { cwd: NAKAMA_DIR, timeoutMs: TIMEOUT_MS.composeDown });
      const ps = await runBounded(ev, "cleanup-compose-check-containers", "docker",
        ["ps", "-a", "-q", "--filter", `label=com.docker.compose.project=${project}`], { timeoutMs: TIMEOUT_MS.short });
      const vols = await runBounded(ev, "cleanup-compose-check-volumes", "docker",
        ["volume", "ls", "-q", "--filter", `label=com.docker.compose.project=${project}`], { timeoutMs: TIMEOUT_MS.short });
      const left = ps.output.trim() + vols.output.trim();
      report.compose = down.rec.exit_code === 0 && ps.rec.exit_code === 0 && vols.rec.exit_code === 0 && left === ""
        ? `removed project ${project} (containers and volume verified gone)`
        : `INCOMPLETE for project ${project} (down exit ${down.rec.exit_code}; remaining: ${left === "" ? "none listed" : "see logs"})`;
    }
  }
  // 2. The recorded work root only, after every check.
  const problem = rootProblem(state);
  if (problem === "absent") {
    report.root = "already absent";
  } else if (problem !== "") {
    report.root = "KEPT";
    report.kept_reason = problem;
  } else {
    const tree = treeProblem(state.root, state.root_dev);
    if (tree.problem !== "") {
      report.root = "KEPT";
      report.kept_reason = tree.problem;
    } else {
      fs.rmSync(state.root, { recursive: true, force: false });
      report.root = fs.existsSync(state.root) ? "INCOMPLETE: root still present" : `removed (${tree.entries} entries, no links, one device)`;
    }
  }
  state.cleaned = report.root !== "KEPT" && !report.compose.startsWith("INCOMPLETE") && !report.compose.startsWith("KEPT");
  state.cleanup_report = report;
  writeState(ev, state);
  ev.log(`cleanup: compose=${report.compose}; root=${report.root}${report.kept_reason ? "; kept because " + report.kept_reason : ""}`);
  return report;
}

// --- Acceptance run --------------------------------------------------------------

class Stop extends Error {}

async function healthy(timeoutMs) {
  const until = Date.now() + timeoutMs;
  while (Date.now() < until) {
    try {
      const r = await fetch(`http://${HOST}:${API_PORT}/healthcheck`, { signal: AbortSignal.timeout(2000) });
      if (r.ok) return true;
    } catch {
      // not up yet
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  return false;
}

async function respondsNow() {
  try {
    const r = await fetch(`http://${HOST}:${API_PORT}/healthcheck`, { signal: AbortSignal.timeout(2000) });
    return r.ok || r.status > 0;
  } catch {
    return false;
  }
}

function godotEnv(state, extra = {}) {
  const r = state.root;
  return {
    PATH: process.env.PATH ?? "/usr/bin:/bin",
    LANG: "C.UTF-8",
    HOME: path.join(r, "home"),
    XDG_DATA_HOME: path.join(r, "xdg-data"),
    XDG_CONFIG_HOME: path.join(r, "xdg-config"),
    XDG_CACHE_HOME: path.join(r, "xdg-cache"),
    TMPDIR: path.join(r, "tmp"),
    ...extra,
  };
}

function inside(root, p) {
  if (typeof p !== "string" || !path.isAbsolute(p)) return false;
  const resolved = path.resolve(p);
  if (!(resolved === root || resolved.startsWith(root + path.sep))) return false;
  try {
    const real = fs.realpathSync(resolved);
    return real === root || real.startsWith(root + path.sep);
  } catch {
    return true; // not created (yet): the lexical containment above is what Godot will use
  }
}

async function acceptance(ev, args, runnerTemp) {
  const steps = ev.summary.steps;
  const record = (rec, verdict, extra = {}) => {
    const entry = { ...rec, verdict: verdict === "" ? "PASS" : "FAIL", reason: verdict, ...extra };
    steps.push(entry);
    ev.save();
    ev.log(`${entry.verdict} ${rec.name}${verdict ? " (" + verdict + ")" : ""} [exit ${rec.exit_code}, ${rec.duration_ms} ms]`);
    if (verdict !== "") throw new Stop(`${rec.name}: ${verdict}`);
    return entry;
  };
  const basic = (r) => {
    if (r.rec.error) return `could not start: ${r.rec.error}`;
    if (r.rec.timed_out) return "timed out";
    if (r.rec.survivors !== "no") return `process group survivors: ${r.rec.survivors}`;
    if (r.rec.exit_code !== 0) return `exit ${r.rec.exit_code}${r.rec.signal ? " signal " + r.rec.signal : ""}`;
    return "";
  };

  // Preflight: tools, source and a clean checkout.
  const godot = fs.realpathSync(args.godot);
  if (!fs.statSync(godot).isFile()) throw new Stop("--godot is not a file");
  const head = await runBounded(ev, "git-head", "git", ["rev-parse", "HEAD"], { timeoutMs: TIMEOUT_MS.short });
  record(head.rec, basic(head));
  ev.summary.source_sha = head.output.trim();
  const statusBefore = await runBounded(ev, "git-status-before", "git", ["status", "--porcelain"], { timeoutMs: TIMEOUT_MS.short });
  record(statusBefore.rec, basic(statusBefore) || (statusBefore.output.trim() === "" ? "" : "checkout has changes before the run"));

  // 1. Run-owned work root (recorded before anything starts).
  const state = createRoot(ev, args.runId, runnerTemp);
  const recheck = (label) => {
    const p = rootProblem(state);
    if (p !== "") throw new Stop(`${label}: work root check failed: ${p}`);
  };

  // 2. Full Normal Regression.
  const nodeEnv = { ...process.env, TMPDIR: path.join(state.root, "tmp") };
  const rootTests = await runBounded(ev, "node-root-tests", "npm", ["test"], { cwd: REPO, env: nodeEnv, timeoutMs: TIMEOUT_MS.nodeTest });
  record(rootTests.rec, basic(rootTests), { ci_kind: "Node (root project), not Godot" });
  const ci = await runBounded(ev, "nakama-npm-ci", "npm", ["ci"], { cwd: NAKAMA_DIR, env: nodeEnv, timeoutMs: TIMEOUT_MS.npmCi });
  record(ci.rec, basic(ci));
  const unit = await runBounded(ev, "nakama-build-and-unit-tests", "npm", ["test"], { cwd: NAKAMA_DIR, env: nodeEnv, timeoutMs: TIMEOUT_MS.nakamaTest });
  record(unit.rec, basic(unit), { ci_kind: "Nakama server unit (Node), not Godot" });

  recheck("before Godot import");
  const imp = await runBounded(ev, "godot-import", godot, ["--headless", "--path", GODOT_DIR, "--import"],
    { cwd: REPO, env: godotEnv(state), timeoutMs: TIMEOUT_MS.godotImport });
  const cache = path.join(GODOT_DIR, ".godot", "global_script_class_cache.cfg");
  record(imp.rec, basic(imp) || (fs.existsSync(cache) ? "" : "import did not create the class cache"));

  recheck("before probe");
  const probe = await runBounded(ev, "godot-user-data-probe", godot,
    ["--headless", "--path", GODOT_DIR, "--script", LIVE_SCRIPT, "--", "--phase", "probe"],
    { cwd: REPO, env: godotEnv(state), timeoutMs: TIMEOUT_MS.probe });
  const probeResult = results(probe.output)[0] ?? {};
  ev.summary.results.probe = probeResult;
  let probeProblem = basic(probe) || godotVerdict(probe.output, /VS-01 WP01-F live probe passed/);
  if (!probeProblem && !inside(state.root, probeResult.user_data_dir)) probeProblem = `user data folder outside the run root: ${probeResult.user_data_dir}`;
  if (!probeProblem && !inside(state.root, probeResult.globalized_user)) probeProblem = `globalized user:// outside the run root: ${probeResult.globalized_user}`;
  if (!probeProblem && !String(probeResult.godot_version ?? "").startsWith(EXPECTED_GODOT)) probeProblem = `Godot ${probeResult.godot_version}, expected ${EXPECTED_GODOT}`;
  record(probe.rec, probeProblem, { user_data_dir: probeResult.user_data_dir, globalized_user: probeResult.globalized_user });

  const verifies = fs.readdirSync(path.join(GODOT_DIR, "tests")).filter((f) => /^verify_.*\.gd$/.test(f)).sort();
  ev.summary.godot_verify_scripts = verifies.length;
  if (verifies.length < MIN_VERIFY_SCRIPTS || !verifies.includes(`${NEW_VERIFY}.gd`)) {
    throw new Stop(`expected at least ${MIN_VERIFY_SCRIPTS} verify scripts including ${NEW_VERIFY}.gd, found ${verifies.length}`);
  }
  for (const file of verifies) {
    recheck(`before ${file}`);
    const name = file.replace(/\.gd$/, "");
    const r = await runBounded(ev, `godot-${name}`, godot, ["--headless", "--path", GODOT_DIR, "--script", `res://tests/${file}`],
      { cwd: REPO, env: godotEnv(state), timeoutMs: TIMEOUT_MS.verify });
    record(r.rec, basic(r) || godotVerdict(r.output, /verification passed/), { ci_kind: "Godot (real headless Godot)" });
  }

  // 3. One disposable Compose project for this run.
  if (await respondsNow()) throw new Stop(`something already answers on ${HOST}:${API_PORT}; refusing to share a server`);
  const project = state.compose_project;
  state.compose_started = true; // recorded BEFORE up, so cleanup also covers a half-started project
  writeState(ev, state);
  const up = await runBounded(ev, "compose-up", "docker", ["compose", "-p", project, "-f", COMPOSE_FILE, "up", "-d", "postgres", "nakama"],
    { cwd: NAKAMA_DIR, timeoutMs: TIMEOUT_MS.composeUp });
  record(up.rec, basic(up), { compose_project: project });
  const t0 = Date.now();
  const ok = await healthy(TIMEOUT_MS.health);
  record({ name: "nakama-healthy", command: `GET http://${HOST}:${API_PORT}/healthcheck`, exit_code: ok ? 0 : 1, signal: null,
    timed_out: !ok, survivors: "no", duration_ms: Date.now() - t0, log: "" }, ok ? "" : "Nakama did not become healthy");

  const runTag = args.runId.replace(/_/g, "-");
  const account = { email: `${runTag}-a@wp01f.invalid`, password: crypto.randomBytes(24).toString("base64url") };
  const stressAccount = { email: `${runTag}-b@wp01f.invalid`, password: crypto.randomBytes(24).toString("base64url") };
  ev.secrets.push(account.password, stressAccount.password);
  const liveEnv = (acc, prefix) => godotEnv(state, { [`${prefix}_EMAIL`]: acc.email, [`${prefix}_PASSWORD`]: acc.password });
  const live = async (stepName, phase, label, env, timeoutMs) => {
    recheck(`before ${stepName}`);
    const r = await runBounded(ev, stepName, godot,
      ["--headless", "--path", GODOT_DIR, "--script", LIVE_SCRIPT, "--", "--phase", phase, "--label", label, "--host", HOST, "--port", String(API_PORT)],
      { cwd: REPO, env, timeoutMs });
    const res = results(r.output);
    ev.summary.results[label] = res;
    let problem = basic(r) || godotVerdict(r.output, new RegExp(`VS-01 WP01-F live ${phase} passed`));
    if (!problem && res.some((x) => x.unparsable)) problem = "unparsable result line";
    if (!problem && res.some((x) => !inside(state.root, x.user_data_dir))) problem = "a phase ran with a user data folder outside the run root";
    record(r.rec, problem, { phase, label, ci_kind: "Godot live (real Nakama + PostgreSQL)" });
    return res;
  };

  // 4. Live phases: each a separate Godot process (fresh memory).
  const [seed] = await live("live-seed", "seed", "seed", liveEnv(account, "MYRIAL_WP01F"), TIMEOUT_MS.seed);
  const rb1 = await live("live-readback-fresh-process", "readback", "fresh_process", liveEnv(account, "MYRIAL_WP01F"), TIMEOUT_MS.readback);
  const restart = await runBounded(ev, "compose-restart-nakama", "docker", ["compose", "-p", project, "-f", COMPOSE_FILE, "restart", "nakama"],
    { cwd: NAKAMA_DIR, timeoutMs: TIMEOUT_MS.restart });
  record(restart.rec, basic(restart));
  const t1 = Date.now();
  const ok2 = await healthy(TIMEOUT_MS.health);
  record({ name: "nakama-healthy-after-restart", command: `GET http://${HOST}:${API_PORT}/healthcheck`, exit_code: ok2 ? 0 : 1, signal: null,
    timed_out: !ok2, survivors: "no", duration_ms: Date.now() - t1, log: "" }, ok2 ? "" : "Nakama did not become healthy after the restart");
  const rb2 = await live("live-readback-after-server-restart", "readback", "after_server_restart", liveEnv(account, "MYRIAL_WP01F"), TIMEOUT_MS.readback);
  await live("live-targeted-stress", "stress", "stress", liveEnv(stressAccount, "MYRIAL_WP01F_STRESS"), TIMEOUT_MS.stress);

  // 5. Cross-process comparison (only the launcher sees both sides).
  const byPhase = (list, phase) => list.find((x) => x.phase === phase) ?? {};
  const fresh = byPhase(rb1, "readback");
  const relogin = byPhase(rb1, "relogin");
  const restarted = byPhase(rb2, "readback");
  const cmp = ev.summary.comparisons;
  const expect = (id, ok, detail) => {
    cmp.push({ id, verdict: ok ? "PASS" : "FAIL", detail });
    ev.log(`${ok ? "PASS" : "FAIL"} ${id}: ${detail}`);
  };
  const same = (a, b, keys) => keys.every((k) => a[k] !== undefined && a[k] === b[k]);
  const values = (x) => `money ${x.money}, goods ${x.goods}, Lv ${x.level}, EXP ${x.exp}/${x.exp_to_next}, trade rev ${x.trade_revision}, hero rev ${x.hero_revision}`;
  expect("C01 fresh process", seed.pid !== fresh.pid && seed.nonce !== fresh.nonce && fresh.pid !== restarted.pid,
    `pids seed ${seed.pid} / readback ${fresh.pid} / after restart ${restarted.pid}; each process began only after the previous one ended (sequential, survivors checked)`);
  expect("C02 same account", typeof seed.user_id === "string" && seed.user_id !== "" && same(seed, fresh, ["user_id"]) && same(seed, restarted, ["user_id"]),
    "the same Nakama user id in seed and both read-backs");
  expect("C03 trade money / goods", same(seed, fresh, ["money", "goods"]), `seed: ${values(seed)} | readback: ${values(fresh)}`);
  expect("C04 trade revision", Number.isInteger(seed.trade_revision) && fresh.trade_revision === seed.trade_revision + 1,
    `readback ${fresh.trade_revision} = seed ${seed.trade_revision} + 1 (only the new session begin)`);
  expect("C05 hero level / EXP", same(seed, fresh, ["level", "exp", "exp_to_next"]), `seed Lv ${seed.level} EXP ${seed.exp}/${seed.exp_to_next} | readback Lv ${fresh.level} EXP ${fresh.exp}/${fresh.exp_to_next}`);
  expect("C06 hero revision", Number.isInteger(seed.hero_revision) && fresh.hero_revision === seed.hero_revision,
    `readback ${fresh.hero_revision} = seed ${seed.hero_revision} (separate contract; a session begin does not move it)`);
  expect("C07 re-login in the same process", same(fresh, relogin, ["money", "goods", "level", "exp", "hero_revision"]) && relogin.trade_revision === fresh.trade_revision + 1,
    `relogin: ${values(relogin)}`);
  expect("C08 after server restart", same(relogin, restarted, ["money", "goods", "level", "exp", "exp_to_next", "hero_revision"]) && restarted.trade_revision === relogin.trade_revision + 1,
    `after restart: ${values(restarted)}`);
  ev.save();
  if (cmp.some((c) => c.verdict !== "PASS")) throw new Stop("cross-process comparison failed");

  // 6. The checkout must have no tracked or new unignored files.
  const statusAfter = await runBounded(ev, "git-status-after", "git", ["status", "--porcelain"], { timeoutMs: TIMEOUT_MS.short });
  record(statusAfter.rec, basic(statusAfter) || (statusAfter.output.trim() === "" ? "" : "the run changed the checkout (see log)"));
}

// --- Main --------------------------------------------------------------------------

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (e) {
    console.error(String(e.message ?? e));
    return 2;
  }
  let runnerTemp;
  let evidenceDir;
  try {
    runnerTemp = requireDisposableRunner();
    evidenceDir = requireRealDir(args.evidenceDir, "--evidence-dir");
  } catch (e) {
    console.error(String(e.message ?? e));
    return 3;
  }
  const ev = new Evidence(evidenceDir, args.runId);
  if (args.cleanupOnly) {
    try {
      const report = await cleanup(ev, args.runId);
      ev.file("cleanup-only.json", JSON.stringify(report, null, 2) + "\n");
      return 0;
    } catch (e) {
      ev.log(`cleanup error (data kept): ${e}`);
      return 4;
    }
  }
  ev.log(`WP01-F bounded run ${args.runId} (node ${process.version}, ${os.platform()} ${os.release()})`);
  let failed = "";
  try {
    await acceptance(ev, args, runnerTemp);
  } catch (e) {
    failed = e instanceof Stop ? e.message : `launcher error: ${e?.stack ?? e}`;
    ev.log(`STOP: ${failed}`);
  }
  ev.summary.verdict = failed === "" ? "PASS" : "FAIL";
  ev.summary.stop_reason = failed;
  ev.summary.not_run_after_stop = failed === "" ? [] : ["every step after the failed one"];
  ev.summary.finished_at = new Date().toISOString();
  ev.save();
  try {
    ev.summary.cleanup = await cleanup(ev, args.runId);
  } catch (e) {
    ev.summary.cleanup = { error: String(e), kept_reason: "cleanup error: data kept" };
    ev.log(`cleanup error (data kept): ${e}`);
  }
  ev.summary.scope_note = "WP01-F Targeted Stress only. Not Full Stress; not a Gate X / FS-08 process-cleanup PASS.";
  ev.save();
  ev.log(failed === "" ? "WP01-F bounded run: PASS" : `WP01-F bounded run: FAIL (${failed})`);
  return failed === "" ? 0 : 1;
}

process.exitCode = await main();
