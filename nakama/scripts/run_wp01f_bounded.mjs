#!/usr/bin/env node
// VS-01 WP01-F bounded acceptance/evidence launcher. Disposable GitHub runner
// only. Acceptance requires --scope core|full. Evidence is never deleted.

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
const HOST = "127.0.0.1";
const API_PORT = 17350;
const RUN_ID_RE = /^wp01f_[a-z0-9_]{1,60}$/;
const ID_RE = /^(0|[1-9][0-9]*):(0|[1-9][0-9]*)$/;
const PROJECT_RE = /^wp01f_[a-z0-9_]{1,60}$/;
const ROOT_PREFIX = "wp01f-root-";
const STATE_FILE = "run-state.json";
const SENTINEL = ".wp01f-run.json";
const EXPECTED_GODOT = "4.7.2";
const MIN_VERIFY_SCRIPTS = 72;
const WRITER_FILES = new Set(["environment.txt", "docker-version.log", "godot-version.txt", "wp01f-console.log", "leftover-inventory.log"]);
const PLANNED = ["relevant_tests", "full_normal_regression", "live_seed", "fresh_process_readback", "nakama_restart", "restart_readback", "C01-C08", "stress_phase", "acceptance_audit"];
const TRANSFERRED = ["T1", "T2", "T3", "T4"].map((id) => ({ id, status: "NOT RUN / TRANSFERRED TO WP01-G" }));
const REQUIRED_PASS = ["environment.txt", "docker-version.log", "godot-version.txt", "wp01f-console.log", "launcher.log", "summary.json", STATE_FILE, "leftover-inventory.log", "inventory-launcher.log", "leftover-inventory.json"];
const OUTCOMES = new Set(["success", "failure", "cancelled", "skipped"]);
const TIMEOUT_MS = { nodeTest: 600000, npmCi: 600000, nakamaTest: 600000, godotImport: 600000,
  probe: 120000, verify: 240000, composeUp: 900000, health: 180000, seed: 240000,
  readback: 180000, restart: 300000, stress: 420000, short: 60000 };
const KILL_GRACE_MS = 5000;
class SafetyError extends Error {}

function parseArgs(argv) {
  const out = { mode: "acceptance", runId: "", evidenceDir: "", evidenceId: "", godot: "", scope: "", writeEvidence: "" };
  const seen = new Set();
  const modes = [];
  const take = (flag, i) => {
    if (seen.has(flag)) throw new Error(`${flag} must not be repeated`);
    seen.add(flag);
    if (i + 1 >= argv.length || argv[i + 1].startsWith("--")) throw new Error(`${flag} requires a value`);
    return argv[i + 1];
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (["--inventory-only", "--finalize", "--verify-manifest"].includes(a)) {
      if (seen.has(a)) throw new Error(`${a} must not be repeated`);
      seen.add(a); modes.push(a.slice(2));
    } else if (a === "--write-evidence") { out.writeEvidence = take(a, i++); modes.push("write-evidence"); }
    else if (a === "--run-id") out.runId = take(a, i++);
    else if (a === "--evidence-dir") out.evidenceDir = take(a, i++);
    else if (a === "--evidence-id") out.evidenceId = take(a, i++);
    else if (a === "--godot") out.godot = take(a, i++);
    else if (a === "--scope") out.scope = take(a, i++);
    else throw new Error(`unknown argument: ${a}`);
  }
  if (modes.length > 1) throw new Error(`modes are mutually exclusive: ${modes.join(", ")}`);
  if (modes.length) out.mode = modes[0];
  if (!RUN_ID_RE.test(out.runId)) throw new Error("--run-id must match " + RUN_ID_RE);
  if (!path.isAbsolute(out.evidenceDir)) throw new Error("--evidence-dir must be an absolute path");
  if (!ID_RE.test(out.evidenceId)) throw new Error("--evidence-id must be <dev>:<ino>");
  if (out.scope && !["core", "full"].includes(out.scope)) throw new Error("--scope must be exactly core or full");
  if (["acceptance", "finalize"].includes(out.mode) && !out.scope) throw new Error(`--scope is required in ${out.mode} mode`);
  if (out.mode === "acceptance" && !path.isAbsolute(out.godot)) throw new Error("--godot must be an absolute path in acceptance mode");
  if (out.mode !== "acceptance" && out.godot) throw new Error("--godot is valid only in acceptance mode");
  if (out.mode === "write-evidence" && !WRITER_FILES.has(out.writeEvidence)) throw new Error(`--write-evidence name is not allowlisted: ${out.writeEvidence}`);
  return out;
}

function requireDisposableRunner() {
  const p = [];
  if (process.env.GITHUB_ACTIONS !== "true") p.push("GITHUB_ACTIONS is not 'true'");
  if (process.env.RUNNER_ENVIRONMENT !== "github-hosted") p.push("RUNNER_ENVIRONMENT is not 'github-hosted'");
  if (process.platform !== "linux") p.push(`platform is ${process.platform}, not linux`);
  const temp = process.env.RUNNER_TEMP ?? "";
  if (!path.isAbsolute(temp)) p.push("RUNNER_TEMP is not an absolute path");
  if (p.length) throw new Error("REFUSED: not a disposable GitHub-hosted runner: " + p.join("; "));
  return temp;
}

function requireRealDir(p, label) {
  const st = fs.lstatSync(p);
  if (st.isSymbolicLink() || !st.isDirectory()) throw new Error(`${label} is not a real directory: ${p}`);
  const real = fs.realpathSync(p);
  if (real !== path.resolve(p)) throw new Error(`${label} is not canonical: ${p} -> ${real}`);
  return real;
}

async function drain() {
  process.stdin.on("error", () => {}); process.stdout.on("error", () => {});
  for await (const chunk of process.stdin) if (!process.stdout.write(chunk)) await new Promise((r) => process.stdout.once("drain", r));
}

function verifyDir(dir, id, runnerTemp) {
  let st;
  try { st = fs.lstatSync(dir, { bigint: true }); }
  catch (e) { throw new SafetyError(`cannot lstat evidence directory: ${e.code ?? e}`); }
  if (st.isSymbolicLink() || !st.isDirectory()) throw new SafetyError("evidence directory is not a real directory");
  const real = fs.realpathSync(dir);
  const expected = path.join(requireRealDir(runnerTemp, "RUNNER_TEMP"), "wp01f-evidence");
  if (real !== path.resolve(dir) || real !== expected) throw new SafetyError("evidence directory canonical path differs");
  if (typeof process.getuid !== "function" || st.uid !== BigInt(process.getuid())) throw new SafetyError("evidence directory owner uid differs");
  if ((st.mode & 0o022n) !== 0n) throw new SafetyError("evidence directory is writable by group/other");
  if (`${st.dev}:${st.ino}` !== id) throw new SafetyError("evidence directory device/inode differs");
  return real;
}

class Leaf {
  constructor(dir, name, id, temp, append = false) {
    verifyDir(dir, id, temp);
    this.dir = dir; this.id = id; this.temp = temp; this.target = path.join(dir, name);
    if (typeof fs.constants.O_NOFOLLOW !== "number") throw new SafetyError("O_NOFOLLOW is unavailable");
    let flags = fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW;
    if (append) flags |= fs.constants.O_APPEND;
    try { this.fd = fs.openSync(this.target, flags, 0o600); }
    catch (e) { throw new SafetyError(`${name}: exclusive no-follow open failed: ${e.code ?? e}`); }
    try {
      const s = fs.fstatSync(this.fd, { bigint: true });
      if (!s.isFile() || s.uid !== BigInt(process.getuid()) || s.nlink !== 1n || s.size !== 0n) throw new SafetyError(`${name}: unsafe exclusive open`);
      this.dev = s.dev; this.ino = s.ino; this.check();
    } catch (e) { fs.closeSync(this.fd); this.fd = -1; throw e; }
  }
  check() {
    verifyDir(this.dir, this.id, this.temp);
    const f = fs.fstatSync(this.fd, { bigint: true }); const l = fs.lstatSync(this.target, { bigint: true });
    if (!f.isFile() || !l.isFile() || l.isSymbolicLink() || f.uid !== BigInt(process.getuid()) || f.nlink !== 1n
      || f.dev !== this.dev || f.ino !== this.ino || l.dev !== this.dev || l.ino !== this.ino) throw new SafetyError(`${this.target}: unsafe leaf identity`);
  }
  writeAll(v, position = null) {
    const data = Buffer.isBuffer(v) ? v : Buffer.from(String(v));
    let offset = 0;
    while (offset < data.length) {
      const written = fs.writeSync(this.fd, data, offset, data.length - offset, position === null ? null : position + offset);
      if (written <= 0) throw new SafetyError(`${this.target}: incomplete write`);
      offset += written;
    }
  }
  append(v) { this.check(); this.writeAll(v); }
  replace(v) { this.check(); fs.ftruncateSync(this.fd, 0); this.check(); this.writeAll(v, 0); fs.fsyncSync(this.fd); }
  once(v) { this.check(); this.writeAll(v); fs.fsyncSync(this.fd); }
  close() { if (this.fd >= 0) { fs.closeSync(this.fd); this.fd = -1; } }
}

function readSafe(dir, name, id, temp, optional = false) {
  verifyDir(dir, id, temp); const p = path.join(dir, name); let l;
  try { l = fs.lstatSync(p, { bigint: true }); } catch (e) { if (optional && e.code === "ENOENT") return null; throw e; }
  if (l.isSymbolicLink() || !l.isFile() || l.uid !== BigInt(process.getuid())) throw new SafetyError(`${name}: unsafe evidence input`);
  const fd = fs.openSync(p, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    const f = fs.fstatSync(fd, { bigint: true });
    if (!f.isFile() || f.uid !== BigInt(process.getuid()) || f.dev !== l.dev || f.ino !== l.ino) throw new SafetyError(`${name}: read identity changed`);
    return { data: fs.readFileSync(fd), size: f.size };
  } finally { fs.closeSync(fd); }
}

function readJson(dir, name, id, temp, optional = false) { const x = readSafe(dir, name, id, temp, optional); return x ? JSON.parse(x.data.toString("utf8")) : null; }
function fileType(s) {
  if (s.isSymbolicLink()) return "symlink";
  if (s.isFile()) return "regular";
  if (s.isDirectory()) return "directory";
  if (s.isFIFO()) return "fifo";
  if (s.isSocket()) return "socket";
  if (s.isCharacterDevice()) return "character-device";
  if (s.isBlockDevice()) return "block-device";
  return "other";
}
function currentFileType(dir, name) {
  try { return fileType(fs.lstatSync(path.join(dir, name), { bigint: true })); }
  catch (e) { return e.code === "ENOENT" ? "missing" : "unknown"; }
}
function scan(dir, id, temp, omit = new Set()) {
  verifyDir(dir, id, temp); const files = [], anomalies = [];
  for (const name of fs.readdirSync(dir).sort()) {
    if (omit.has(name)) continue; let s;
    try { s = fs.lstatSync(path.join(dir, name), { bigint: true }); }
    catch (e) { throw new SafetyError(`${name}: lstat failed during evidence scan: ${e.code ?? e}`); }
    const type = fileType(s), reasons = [];
    if (name.startsWith(".")) reasons.push("hidden");
    if (type !== "regular") reasons.push("non-regular");
    if (reasons.length) anomalies.push({ name, type, reason: reasons.join("; ") }); else files.push(name);
  }
  verifyDir(dir, id, temp); return { files, anomalies };
}

class Evidence {
  constructor(args, temp, inventory = false) {
    this.args = args; this.temp = temp; this.secrets = []; this.seq = 0; this.pgids = [];
    this.logFd = new Leaf(args.evidenceDir, inventory ? "inventory-launcher.log" : "launcher.log", args.evidenceId, temp, true);
    this.summaryFd = inventory ? null : new Leaf(args.evidenceDir, "summary.json", args.evidenceId, temp);
    this.stateFd = null;
    this.summary = inventory ? null : { run_id: args.runId, started_at: new Date().toISOString(), scope: args.scope,
      scope_note: args.scope === "core" ? "Core resume only; T1-T4 NOT RUN and transferred to WP01-G." : "Full scope includes targeted stress; not Full Stress or Gate X/FS-08.",
      planned_steps: PLANNED, transferred_cases: args.scope === "core" ? TRANSFERRED : [],
      stage_status: Object.fromEntries(PLANNED.map((x) => [x, "NOT RUN"])), steps: [], comparisons: [], results: {}, verdict: "RUNNING" };
    if (this.summaryFd) this.save();
  }
  redact(v) { let s = String(v); for (const x of this.secrets) if (x) s = s.split(x).join("***REDACTED***"); return s; }
  log(v) { const s = this.redact(v); console.log(s); this.logFd.append(s + "\n"); }
  file(name, v) { const f = new Leaf(this.args.evidenceDir, name, this.args.evidenceId, this.temp); try { f.once(this.redact(v)); } finally { f.close(); } }
  save() { this.summaryFd.replace(JSON.stringify(this.summary, null, 2) + "\n"); }
  state(v) { if (!this.stateFd) this.stateFd = new Leaf(this.args.evidenceDir, STATE_FILE, this.args.evidenceId, this.temp); this.stateFd.replace(JSON.stringify(v, null, 2) + "\n"); }
  next(name) { return `${String(++this.seq).padStart(3, "0")}-${name.replace(/[^A-Za-z0-9_.-]/g, "_")}.log`; }
  close() { this.logFd.close(); this.summaryFd?.close(); this.stateFd?.close(); }
}

async function writer(args, temp) {
  let fd = null, failed = "";
  try { fd = new Leaf(args.evidenceDir, args.writeEvidence, args.evidenceId, temp, true); }
  catch (e) { failed = String(e.message ?? e); console.error(`writer refused file, draining: ${failed}`); }
  process.stdin.on("error", () => {}); process.stdout.on("error", () => {});
  for await (const chunk of process.stdin) {
    if (!process.stdout.write(chunk)) await new Promise((r) => process.stdout.once("drain", r));
    if (fd && !failed) try { fd.append(chunk); } catch (e) { failed = String(e.message ?? e); console.error(`writer stopped file output, draining: ${failed}`); }
  }
  fd?.close(); return failed ? 7 : 0;
}

function groupAlive(id) { try { process.kill(-id, 0); return "yes"; } catch (e) { return e.code === "ESRCH" ? "no" : "unknown"; } }
function stopGroup(id, sig) { try { process.kill(-id, sig); } catch { /* gone */ } }
function runBounded(ev, name, cmd, argv, { cwd = REPO, env = process.env, timeoutMs }) {
  return new Promise((resolve) => {
    const log = ev.next(name), display = [cmd, ...argv].join(" "), started = Date.now(), chunks = [];
    let child, timed = false, closed = false;
    try { child = spawn(cmd, argv, { cwd, env, detached: true, stdio: ["ignore", "pipe", "pipe"] }); }
    catch (e) { const rec = { name, command: display, cwd: path.relative(REPO, cwd) || ".", exit_code: null, signal: null, timed_out: false, survivors: "no", duration_ms: 0, log, error: String(e) }; ev.file(log, `$ ${display}\nspawn failed: ${e}\n`); resolve({ rec, output: "" }); return; }
    const pgid = child.pid; ev.pgids.push(pgid); child.stdout.on("data", (c) => chunks.push(c)); child.stderr.on("data", (c) => chunks.push(c));
    const timer = setTimeout(() => { timed = true; stopGroup(pgid, "SIGTERM"); setTimeout(() => { if (!closed) stopGroup(pgid, "SIGKILL"); }, KILL_GRACE_MS).unref(); }, timeoutMs);
    child.on("error", (e) => chunks.push(Buffer.from(`\nchild error: ${e}\n`)));
    child.on("close", (code, signal) => { closed = true; clearTimeout(timer); const survivors = groupAlive(pgid); if (survivors === "yes") stopGroup(pgid, "SIGKILL");
      const output = Buffer.concat(chunks).toString("utf8"); const rec = { name, command: ev.redact(display), cwd: path.relative(REPO, cwd) || ".", exit_code: code, signal, timed_out: timed, survivors, duration_ms: Date.now() - started, log, pgid };
      ev.file(log, `$ ${display}\n# cwd=${rec.cwd} timeout_ms=${timeoutMs}\n${output}\n# exit=${code} signal=${signal} timed_out=${timed} survivors=${survivors} duration_ms=${rec.duration_ms}\n`); resolve({ rec, output }); });
  });
}

function godotVerdict(out, re) { const lines = out.split("\n"); if (/SCRIPT ERROR|Parse Error/.test(out)) return "script or parse error"; if (lines.some((x) => /^(ERROR: )?FAILED:/.test(x))) return "test reported FAILED"; return lines.some((x) => !/^(ERROR: )?FAILED:/.test(x) && re.test(x)) ? "" : "no success line"; }
function results(out) { return out.split("\n").filter((x) => x.includes("WP01F_RESULT ")).map((x) => { try { return JSON.parse(x.slice(x.indexOf("WP01F_RESULT ") + 13)); } catch { return { unparsable: true }; } }); }
function c01FreshRuntime(seed, fresh, restarted) {
  const phases = [seed, fresh, restarted];
  const pids = phases.map((x) => x?.pid), nonces = phases.map((x) => x?.nonce);
  const validPids = pids.every((x) => Number.isSafeInteger(x) && x > 0);
  const validNonces = nonces.every((x) => typeof x === "string" && x.trim().length > 0);
  return validPids && validNonces && new Set(pids).size === 3 && new Set(nonces).size === 3;
}
function composeProject(id) { return id; }

function createRoot(ev, runId, temp) {
  const base = requireRealDir(temp, "RUNNER_TEMP"), root = fs.realpathSync(fs.mkdtempSync(path.join(base, `${ROOT_PREFIX}${runId}-`)));
  fs.chmodSync(root, 0o700); for (const s of ["home", "xdg-data", "xdg-config", "xdg-cache", "tmp"]) fs.mkdirSync(path.join(root, s), { mode: 0o700 });
  const st = fs.statSync(root), sentinel = { run_id: runId, root, dev: st.dev, ino: st.ino, created_at: new Date().toISOString() };
  fs.writeFileSync(path.join(root, SENTINEL), JSON.stringify(sentinel) + "\n", { flag: "wx", mode: 0o600 });
  const state = { run_id: runId, base, root, root_dev: st.dev, root_ino: st.ino, compose_project: composeProject(runId), compose_started: false, cleaned: false };
  ev.state(state); ev.log(`work root created: ${root}`); return state;
}

function rootProblem(s) {
  if (!s || typeof s.root !== "string" || !path.isAbsolute(s.root)) return "recorded root is not absolute";
  if (path.dirname(s.root) !== s.base || !path.basename(s.root).startsWith(`${ROOT_PREFIX}${s.run_id}-`)) return "root location/name differs";
  let st; try { st = fs.lstatSync(s.root); } catch (e) { return e.code === "ENOENT" ? "absent" : `cannot stat root: ${e.code}`; }
  if (st.isSymbolicLink() || !st.isDirectory() || fs.realpathSync(s.root) !== s.root || st.dev !== s.root_dev || st.ino !== s.root_ino) return "root identity differs";
  let x; try { x = JSON.parse(fs.readFileSync(path.join(s.root, SENTINEL), "utf8")); } catch { return "sentinel unreadable"; }
  return x.run_id === s.run_id && x.root === s.root && x.dev === st.dev && x.ino === st.ino ? "" : "sentinel differs";
}

async function inventory(ev, args, temp) {
  const report = { mode: "inventory only; nothing deleted", compose: "not started", root: "not created", complete: true, note: "" };
  const state = readJson(args.evidenceDir, STATE_FILE, args.evidenceId, temp, true);
  if (!state) { report.root = "no run state"; ev.log("leftover inventory: no run state"); return report; }
  if (state.run_id !== args.runId) throw new Error("run state belongs to another run");
  if (state.compose_started) {
    const project = state.compose_project; if (project !== composeProject(args.runId) || !PROJECT_RE.test(project)) throw new Error("Compose project differs");
    const ps = await runBounded(ev, "inventory-compose-containers", "docker", ["ps", "-a", "--filter", `label=com.docker.compose.project=${project}`, "--format", "{{.Names}} {{.Status}}"], { timeoutMs: TIMEOUT_MS.short });
    const vs = await runBounded(ev, "inventory-compose-volumes", "docker", ["volume", "ls", "--filter", `label=com.docker.compose.project=${project}`, "--format", "{{.Name}}"], { timeoutMs: TIMEOUT_MS.short });
    if ([ps, vs].some((x) => x.rec.exit_code !== 0 || x.rec.timed_out || x.rec.survivors !== "no")) throw new Error("Docker inventory incomplete");
    const n = (x) => x.output.split("\n").filter((y) => y.trim()).length; report.compose = `PRESERVED: ${project}, ${n(ps)} container(s), ${n(vs)} volume(s)`;
  }
  const p = rootProblem(state); if (p && p !== "absent") throw new Error(`work root: ${p}`); report.root = p === "absent" ? "absent" : `PRESERVED: ${state.root}`;
  ev.log(`leftover inventory: compose=${report.compose}; root=${report.root}`); return report;
}

class Stop extends Error {}
async function healthy(ms) { const until = Date.now() + ms; while (Date.now() < until) { try { const r = await fetch(`http://${HOST}:${API_PORT}/healthcheck`, { signal: AbortSignal.timeout(2000) }); if (r.ok) return true; } catch {} await new Promise((r) => setTimeout(r, 1000)); } return false; }
async function respondsNow() { try { const r = await fetch(`http://${HOST}:${API_PORT}/healthcheck`, { signal: AbortSignal.timeout(2000) }); return r.ok || r.status > 0; } catch { return false; } }
function godotEnv(s, extra = {}) { return { PATH: process.env.PATH ?? "/usr/bin:/bin", LANG: "C.UTF-8", HOME: path.join(s.root, "home"), XDG_DATA_HOME: path.join(s.root, "xdg-data"), XDG_CONFIG_HOME: path.join(s.root, "xdg-config"), XDG_CACHE_HOME: path.join(s.root, "xdg-cache"), TMPDIR: path.join(s.root, "tmp"), ...extra }; }
function inside(root, p) { if (typeof p !== "string" || !path.isAbsolute(p)) return false; const within = (q) => q === root || q.startsWith(root + path.sep); let q = path.resolve(p); if (!within(q)) return false; for (;;) { try { fs.lstatSync(q); break; } catch (e) { if (e.code !== "ENOENT") return false; const up = path.dirname(q); if (up === q) return false; q = up; } } try { return within(fs.realpathSync(q)); } catch { return false; } }
function isolationProblem(s) { const e = godotEnv(s); for (const k of ["HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "TMPDIR"]) { try { requireRealDir(e[k], k); } catch (x) { return String(x.message ?? x); } if (!inside(s.root, e[k])) return `${k} outside run root`; } return ""; }
function stage(ev, name, status) { ev.summary.stage_status[name] = status; ev.save(); }

async function acceptance(ev, args, temp) {
  let active = "relevant_tests"; stage(ev, active, "RUNNING");
  const basic = (r) => r.rec.error ? `could not start: ${r.rec.error}` : r.rec.timed_out ? "timed out" : r.rec.survivors !== "no" ? `survivors ${r.rec.survivors}` : r.rec.exit_code !== 0 ? `exit ${r.rec.exit_code}` : "";
  const record = (rec, problem, extra = {}) => { const x = { ...rec, verdict: problem ? "FAIL" : "PASS", reason: problem, ...extra }; ev.summary.steps.push(x); ev.save(); ev.log(`${x.verdict} ${rec.name}${problem ? ` (${problem})` : ""}`); if (problem) throw new Stop(`${rec.name}: ${problem}`); };
  const next = (name) => { if (active && ev.summary.stage_status[active] === "RUNNING") stage(ev, active, "PASS"); active = name; stage(ev, name, "RUNNING"); };
  try {
    const godot = fs.realpathSync(args.godot); if (!fs.statSync(godot).isFile()) throw new Stop("--godot is not a file");
    const head = await runBounded(ev, "git-head", "git", ["rev-parse", "HEAD"], { timeoutMs: TIMEOUT_MS.short }); record(head.rec, basic(head)); ev.summary.source_sha = head.output.trim();
    const before = await runBounded(ev, "git-status-before", "git", ["status", "--porcelain"], { timeoutMs: TIMEOUT_MS.short }); record(before.rec, basic(before) || (before.output.trim() ? "checkout has changes" : ""));
    const state = createRoot(ev, args.runId, temp), recheck = (label) => { const p = rootProblem(state); if (p) throw new Stop(`${label}: ${p}`); }, nodeEnv = { ...process.env, TMPDIR: path.join(state.root, "tmp") };
    const rt = await runBounded(ev, "node-root-tests", "npm", ["test"], { cwd: REPO, env: nodeEnv, timeoutMs: TIMEOUT_MS.nodeTest }); record(rt.rec, basic(rt), { ci_kind: "Node, not Godot" });
    const ci = await runBounded(ev, "nakama-npm-ci", "npm", ["ci"], { cwd: NAKAMA_DIR, env: nodeEnv, timeoutMs: TIMEOUT_MS.npmCi }); record(ci.rec, basic(ci));
    const unit = await runBounded(ev, "nakama-build-and-unit-tests", "npm", ["test"], { cwd: NAKAMA_DIR, env: nodeEnv, timeoutMs: TIMEOUT_MS.nakamaTest }); record(unit.rec, basic(unit), { ci_kind: "Nakama unit (Node), not Godot" });
    next("full_normal_regression"); recheck("before Godot import"); const iso = isolationProblem(state); if (iso) throw new Stop(`isolation: ${iso}`);
    const imp = await runBounded(ev, "godot-import", godot, ["--headless", "--path", GODOT_DIR, "--import"], { env: godotEnv(state), timeoutMs: TIMEOUT_MS.godotImport }); record(imp.rec, basic(imp) || (fs.existsSync(path.join(GODOT_DIR, ".godot", "global_script_class_cache.cfg")) ? "" : "no class cache"));
    recheck("before probe"); const probe = await runBounded(ev, "godot-user-data-probe", godot, ["--headless", "--path", GODOT_DIR, "--script", LIVE_SCRIPT, "--", "--phase", "probe"], { env: godotEnv(state), timeoutMs: TIMEOUT_MS.probe });
    const pr = results(probe.output)[0] ?? {}; ev.summary.results.probe = pr; let pp = basic(probe) || godotVerdict(probe.output, /VS-01 WP01-F live probe passed/); if (!pp && (!inside(state.root, pr.user_data_dir) || !inside(state.root, pr.globalized_user))) pp = "user data outside run root"; if (!pp && !String(pr.godot_version ?? "").startsWith(EXPECTED_GODOT)) pp = "wrong Godot version"; record(probe.rec, pp);
    const verifies = fs.readdirSync(path.join(GODOT_DIR, "tests")).filter((x) => /^verify_.*\.gd$/.test(x)).sort(); ev.summary.godot_verify_scripts = verifies.length; if (verifies.length < MIN_VERIFY_SCRIPTS || !verifies.includes("verify_vs01_wp01f_resume_mode.gd")) throw new Stop("verify script inventory differs");
    for (const file of verifies) { recheck(`before ${file}`); const r = await runBounded(ev, `godot-${file.slice(0, -3)}`, godot, ["--headless", "--path", GODOT_DIR, "--script", `res://tests/${file}`], { env: godotEnv(state), timeoutMs: TIMEOUT_MS.verify }); record(r.rec, basic(r) || godotVerdict(r.output, /verification passed/), { ci_kind: "Godot headless" }); }
    if (await respondsNow()) throw new Stop("server port already in use"); state.compose_started = true; ev.state(state);
    const up = await runBounded(ev, "compose-up", "docker", ["compose", "-p", state.compose_project, "-f", COMPOSE_FILE, "up", "-d", "postgres", "nakama"], { cwd: NAKAMA_DIR, timeoutMs: TIMEOUT_MS.composeUp }); record(up.rec, basic(up));
    const h0 = Date.now(), ok = await healthy(TIMEOUT_MS.health); record({ name: "nakama-healthy", command: "healthcheck", exit_code: ok ? 0 : 1, signal: null, timed_out: !ok, survivors: "no", duration_ms: Date.now() - h0, log: "" }, ok ? "" : "not healthy");
    const tag = args.runId.replace(/_/g, "-"), account = { email: `${tag}-a@wp01f.invalid`, password: crypto.randomBytes(24).toString("base64url") }; ev.secrets.push(account.password);
    const liveEnv = (a, prefix) => godotEnv(state, { [`${prefix}_EMAIL`]: a.email, [`${prefix}_PASSWORD`]: a.password });
    const live = async (stepName, phase, label, env, timeoutMs) => { recheck(`before ${stepName}`); const r = await runBounded(ev, stepName, godot, ["--headless", "--path", GODOT_DIR, "--script", LIVE_SCRIPT, "--", "--phase", phase, "--label", label, "--host", HOST, "--port", String(API_PORT)], { env, timeoutMs }); const rs = results(r.output); ev.summary.results[label] = rs; let p = basic(r) || godotVerdict(r.output, new RegExp(`VS-01 WP01-F live ${phase} passed`)); if (!p && (rs.some((x) => x.unparsable) || rs.some((x) => !inside(state.root, x.user_data_dir)))) p = "invalid result/user data"; record(r.rec, p); return rs; };
    next("live_seed"); const [seed] = await live("live-seed", "seed", "seed", liveEnv(account, "MYRIAL_WP01F"), TIMEOUT_MS.seed);
    next("fresh_process_readback"); const rb1 = await live("live-readback-fresh-process", "readback", "fresh_process", liveEnv(account, "MYRIAL_WP01F"), TIMEOUT_MS.readback);
    next("nakama_restart"); const rr = await runBounded(ev, "compose-restart-nakama", "docker", ["compose", "-p", state.compose_project, "-f", COMPOSE_FILE, "restart", "nakama"], { cwd: NAKAMA_DIR, timeoutMs: TIMEOUT_MS.restart }); record(rr.rec, basic(rr));
    next("restart_readback"); const h1 = Date.now(), ok2 = await healthy(TIMEOUT_MS.health); record({ name: "nakama-healthy-after-restart", command: "healthcheck", exit_code: ok2 ? 0 : 1, signal: null, timed_out: !ok2, survivors: "no", duration_ms: Date.now() - h1, log: "" }, ok2 ? "" : "not healthy"); const rb2 = await live("live-readback-after-server-restart", "readback", "after_server_restart", liveEnv(account, "MYRIAL_WP01F"), TIMEOUT_MS.readback);
    next("C01-C08"); const by = (xs, p) => xs.find((x) => x.phase === p) ?? {}, fresh = by(rb1, "readback"), relogin = by(rb1, "relogin"), restarted = by(rb2, "readback"), same = (a, b, ks) => ks.every((k) => a[k] !== undefined && a[k] === b[k]);
    const expect = (id, pass, detail) => { ev.summary.comparisons.push({ id, verdict: pass ? "PASS" : "FAIL", detail }); ev.log(`${pass ? "PASS" : "FAIL"} ${id}: ${detail}`); };
    expect("C01", c01FreshRuntime(seed, fresh, restarted), "three valid pairwise-distinct process ids and nonces");
    expect("C02", typeof seed.user_id === "string" && seed.user_id && same(seed, fresh, ["user_id"]) && same(seed, restarted, ["user_id"]), "same user");
    expect("C03", same(seed, fresh, ["money", "goods"]), "money/goods preserved"); expect("C04", Number.isInteger(seed.trade_revision) && fresh.trade_revision === seed.trade_revision + 1, "trade revision +1");
    expect("C05", same(seed, fresh, ["level", "exp", "exp_to_next"]), "hero values preserved"); expect("C06", Number.isInteger(seed.hero_revision) && fresh.hero_revision === seed.hero_revision, "hero revision preserved");
    expect("C07", same(fresh, relogin, ["money", "goods", "level", "exp", "hero_revision"]) && relogin.trade_revision === fresh.trade_revision + 1, "relogin");
    expect("C08", same(relogin, restarted, ["money", "goods", "level", "exp", "exp_to_next", "hero_revision"]) && restarted.trade_revision === relogin.trade_revision + 1, "after restart"); ev.save(); if (ev.summary.comparisons.some((x) => x.verdict !== "PASS")) throw new Stop("comparison failed");
    next("stress_phase"); if (args.scope === "full") { const a = { email: `${tag}-b@wp01f.invalid`, password: crypto.randomBytes(24).toString("base64url") }; ev.secrets.push(a.password); await live("live-targeted-stress", "stress", "stress", liveEnv(a, "MYRIAL_WP01F_STRESS"), TIMEOUT_MS.stress); stage(ev, active, "PASS"); } else stage(ev, active, "NOT RUN / TRANSFERRED TO WP01-G"); active = "";
  } catch (e) { if (active && ev.summary.stage_status[active] === "RUNNING") stage(ev, active, "FAIL"); throw e; }
}

async function audit(ev) {
  stage(ev, "acceptance_audit", "RUNNING"); let problem = "";
  const s = await runBounded(ev, "git-status-after", "git", ["status", "--porcelain"], { timeoutMs: TIMEOUT_MS.short });
  const p = s.rec.error ? "could not start" : s.rec.timed_out ? "timed out" : s.rec.survivors !== "no" ? "survivors" : s.rec.exit_code !== 0 ? `exit ${s.rec.exit_code}` : s.output.trim() ? "checkout changed" : "";
  ev.summary.steps.push({ ...s.rec, verdict: p ? "FAIL" : "PASS", reason: p }); if (p) problem = `git-status-after: ${p}`;
  const groups = ev.pgids.map((pgid) => ({ pgid, status: groupAlive(pgid) })); ev.summary.process_survivor_inventory = groups; if (groups.some((x) => x.status !== "no")) problem = [problem, "process survivor yes/unknown"].filter(Boolean).join("; ");
  stage(ev, "acceptance_audit", problem ? "FAIL" : "PASS"); return problem;
}

function finalize(args, temp) {
  const first = scan(args.evidenceDir, args.evidenceId, temp);
  const firstNames = new Set([...first.files, ...first.anomalies.map((x) => x.name)]);
  if (firstNames.has("final-audit.json") || firstNames.has("manifest.json")) throw Object.assign(new Error("unsafe/pre-existing final evidence target"), { exitCode: 7 });
  const anomalies = [...first.anomalies];
  const readInput = (name, optional = false) => {
    try { return readJson(args.evidenceDir, name, args.evidenceId, temp, optional); }
    catch (e) { if (e instanceof SafetyError) throw e; anomalies.push({ name, type: currentFileType(args.evidenceDir, name), reason: `safe-read-failed: ${e.code ?? e.message ?? e}` }); return null; }
  };
  const summary = readInput("summary.json") ?? {}, inv = readInput("leftover-inventory.json", true);
  const ao = process.env.WP01F_ACCEPTANCE_OUTCOME ?? "", io = process.env.WP01F_INVENTORY_OUTCOME ?? "";
  let f = new Leaf(args.evidenceDir, "final-audit.json", args.evidenceId, temp);
  const last = scan(args.evidenceDir, args.evidenceId, temp);
  for (const anomaly of last.anomalies) if (!anomalies.some((x) => x.name === anomaly.name && x.type === anomaly.type && x.reason === anomaly.reason)) anomalies.push(anomaly);
  if (last.files.includes("manifest.json") || last.anomalies.some((x) => x.name === "manifest.json")) { f.close(); throw Object.assign(new SafetyError("unsafe manifest target"), { exitCode: 7 }); }
  const files = [];
  for (const name of last.files) {
    if (name === "final-audit.json") continue;
    try { const x = readSafe(args.evidenceDir, name, args.evidenceId, temp); files.push({ name, size: Number(x.size), sha256: crypto.createHash("sha256").update(x.data).digest("hex") }); }
    catch (e) { if (e instanceof SafetyError) { f.close(); throw e; } anomalies.push({ name, type: currentFileType(args.evidenceDir, name), reason: `manifest-read-failed: ${e.code ?? e.message ?? e}` }); }
  }
  const checks = { acceptance_outcome_valid: OUTCOMES.has(ao), inventory_outcome_valid: OUTCOMES.has(io), acceptance_success: ao === "success", inventory_success: io === "success", scope_matches: summary.scope === args.scope, summary_verdict_matches: summary.verdict === (args.scope === "core" ? "PASS_CORE_SCOPE" : "PASS_FULL_SCOPE"), acceptance_audit_passed: summary.stage_status?.acceptance_audit === "PASS", inventory_complete: inv?.complete === true, required_evidence_present: REQUIRED_PASS.every((x) => first.files.includes(x)), no_anomalies: anomalies.length === 0 };
  const verdict = Object.values(checks).every(Boolean) ? (args.scope === "core" ? "PASS_CORE_SCOPE" : "PASS_FULL_SCOPE") : "FAIL";
  try { f.once(JSON.stringify({ run_id: args.runId, scope: args.scope, acceptance_outcome: ao, inventory_outcome: io, checks, anomalies, final_verdict: verdict, finalized_at: new Date().toISOString() }, null, 2) + "\n"); } finally { f.close(); }
  const finalAudit = readSafe(args.evidenceDir, "final-audit.json", args.evidenceId, temp);
  files.push({ name: "final-audit.json", size: Number(finalAudit.size), sha256: crypto.createHash("sha256").update(finalAudit.data).digest("hex") });
  files.sort((a, b) => a.name.localeCompare(b.name));
  f = new Leaf(args.evidenceDir, "manifest.json", args.evidenceId, temp); try { f.once(JSON.stringify({ run_id: args.runId, evidence_id: args.evidenceId, files, anomalies }, null, 2) + "\n"); } finally { f.close(); }
  console.log(`final audit ${verdict}; manifest ${files.length} files; anomalies ${anomalies.length}`); return anomalies.length ? 7 : verdict === "FAIL" ? 1 : 0;
}

function verifyManifest(args, temp) {
  const s = scan(args.evidenceDir, args.evidenceId, temp); if (s.anomalies.length) return 7;
  let m; try { m = readJson(args.evidenceDir, "manifest.json", args.evidenceId, temp); } catch (e) { console.error(e); return e instanceof SafetyError ? 7 : 6; }
  if (!Array.isArray(m.files) || !Array.isArray(m.anomalies) || m.anomalies.length) return 6;
  if (!s.files.includes("manifest.json")) return 6;
  const ordinary = s.files.filter((name) => name !== "manifest.json");
  const names = m.files.map((x) => x.name); if (new Set(names).size !== names.length || JSON.stringify([...names].sort()) !== JSON.stringify(ordinary)) return 6;
  for (const e of m.files) { const x = readSafe(args.evidenceDir, e.name, args.evidenceId, temp), hash = crypto.createHash("sha256").update(x.data).digest("hex"); if (Number(x.size) !== e.size || hash !== e.sha256) return 6; }
  verifyDir(args.evidenceDir, args.evidenceId, temp); console.log(`manifest verified: ${names.length} files`); return 0;
}

async function main() {
  const argv = process.argv.slice(2), writerRequested = argv.includes("--write-evidence"); let args;
  try { args = parseArgs(argv); } catch (e) { console.error(String(e.message ?? e)); if (writerRequested) await drain(); return 2; }
  let temp; try { temp = requireDisposableRunner(); } catch (e) { console.error(String(e.message ?? e)); if (args.mode === "write-evidence") await drain(); return 3; }
  try { verifyDir(args.evidenceDir, args.evidenceId, temp); } catch (e) { console.error(`evidence directory refused: ${e.message ?? e}`); if (args.mode === "write-evidence") await drain(); return args.mode === "write-evidence" ? 7 : 3; }
  if (args.mode === "write-evidence") return writer(args, temp);
  if (args.mode === "verify-manifest") return verifyManifest(args, temp);
  if (args.mode === "finalize") try { return finalize(args, temp); } catch (e) { console.error(`finalize failed: ${e.message ?? e}`); return e instanceof SafetyError ? 7 : e.exitCode ?? 5; }
  let ev; try { ev = new Evidence(args, temp, args.mode === "inventory-only"); } catch (e) { console.error(`evidence open failed: ${e.message ?? e}`); return 7; }
  if (args.mode === "inventory-only") { try { const r = await inventory(ev, args, temp); ev.file("leftover-inventory.json", JSON.stringify(r, null, 2) + "\n"); ev.close(); return 0; } catch (e) { try { ev.log(`leftover inventory error: ${e.message ?? e}`); } catch {} ev.close(); return e instanceof SafetyError ? 7 : 4; } }
  ev.log(`WP01-F bounded ${args.scope} run ${args.runId} (node ${process.version}, ${os.platform()} ${os.release()})`); let failed = "";
  try { await acceptance(ev, args, temp); } catch (e) { if (e instanceof SafetyError) { console.error(`evidence safety failure: ${e.message}`); ev.close(); return 7; } failed = e instanceof Stop ? e.message : `launcher error: ${e?.stack ?? e}`; try { ev.log(`STOP: ${failed}`); } catch { ev.close(); return 7; } }
  try { const p = await audit(ev); if (p) failed = [failed, p].filter(Boolean).join("; "); ev.summary.verdict = failed ? "FAIL" : args.scope === "core" ? "PASS_CORE_SCOPE" : "PASS_FULL_SCOPE"; ev.summary.stop_reason = failed; ev.summary.not_run_stages = Object.entries(ev.summary.stage_status).filter(([, x]) => x === "NOT RUN").map(([x]) => x); ev.summary.finished_at = new Date().toISOString(); ev.save(); ev.log(failed ? `WP01-F bounded run: FAIL (${failed})` : `WP01-F bounded run: ${ev.summary.verdict}`); } catch (e) { console.error(`audit/evidence failure: ${e.message ?? e}`); ev.close(); return 7; }
  ev.close(); return failed ? 1 : 0;
}

process.exitCode = await main();
