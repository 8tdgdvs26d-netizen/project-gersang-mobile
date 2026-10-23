#!/usr/bin/env node
// VS-01 WP01-G Phase B diagnostic runner (Proposal r2.1). Disposable GitHub
// runner only (except --selftest, which is in-memory and writes nothing).
//
// DIAGNOSTIC, NOT ACCEPTANCE: no result here is a T1-T4, Deadline-late or
// WP01-G PASS. It changes no product code and never deletes anything. It sends
// a signal only to a process whose ownership it has proven (Proposal §4.2).
// Every child output line is redacted (rules S1-S5, Proposal §6.1) BEFORE it is
// written to evidence or to this process's console (the GitHub job log).
//
// Modes (exactly one is required; there is no default):
//   --diag             run D1-D5 (11 cases) and write evidence
//   --inventory-only   list leftovers (nothing is deleted)
//   --finalize         final secret re-scan, final-audit.json, manifest.json
//   --verify-manifest  independent manifest + upload-safety check
//   --selftest         A8: synthetic checks of the secret rules and the gap
//                      computation (no other argument; no file is created)

import { spawn } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { StringDecoder } from "node:string_decoder";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = fs.realpathSync(path.resolve(HERE, "../.."));
const NAKAMA_DIR = path.join(REPO, "nakama");
const GODOT_DIR = path.join(REPO, "godot");
const COMPOSE_FILE = path.join(NAKAMA_DIR, "docker-compose.yml");
const HARNESS = "res://tests/diag_wp01g_http_modes.gd";
const HOST = "127.0.0.1";
const NAKAMA_PORT = 17350;
const RUN_ID_RE = /^wp01g_[a-z0-9_]{1,60}$/;
const ID_RE = /^(0|[1-9][0-9]*):(0|[1-9][0-9]*)$/;
const ROOT_PREFIX = "wp01g-root-";
const EVIDENCE_LEAF = "wp01g-evidence";
const STATE_FILE = "run-state.json";
const SENTINEL = ".wp01g-run.json";
const EXPECTED_GODOT = "4.7.2";

// Proposal r2.1 §2.2: 11 cases. server: stall / drop / delay = external fault
// server mode; nakama = disposable Nakama (D5).
const CASES = [
  { id: "D1-R", layer: "R", threads: true, server: "stall" },
  { id: "D1-S", layer: "S", threads: true, server: "stall" },
  { id: "D2-R", layer: "R", threads: false, server: "stall" },
  { id: "D2-S", layer: "S", threads: false, server: "stall" },
  { id: "D3-R", layer: "R", threads: true, server: "drop" },
  { id: "D3-S", layer: "S", threads: true, server: "drop" },
  { id: "D4-R-T", layer: "R", threads: true, server: "delay" },
  { id: "D4-R-F", layer: "R", threads: false, server: "delay" },
  { id: "D4-S-F", layer: "S", threads: false, server: "delay" },
  { id: "D5-F", layer: "D5", threads: false, server: "nakama" },
  { id: "D5-T", layer: "D5", threads: true, server: "nakama" },
];
const CASE_HARD_CAP_MS = 60000;      // provisional (Proposal §4.1)
const HB_INTERVAL_MS = 250;
const DROP_FALLBACK_MS = 1000;       // drop mode: cut once the request head arrived (fallback: 1 s after the first byte)
const HB_GAP_MS = 500;               // ① short-gap record threshold: 2 heartbeat intervals
const LONG_STALL_MS = 1500;          // ② long-stall alert (separate mechanism, unchanged)
const SNAPSHOT_AFTER_MS = [3000, 6000];
const BASELINE_MAX_DIFF_MS = 100;
const APPROX_MS = 500;               // "about X" = X ± 0.5 s (Proposal §2.1)
const DIAG_TIMEOUT_MS = 2000;        // harness timeout (same as T2)
const DELAY_REPLY_MS = 3000;
const PRE_REQUEST_SLACK_MS = 300;
const KILL_GRACE_MS = 5000;
const CLOSE_WAIT_MS = 5000;
const WATCHDOG_TICK_MS = 100;
const MAX_LINE_CHARS = 1 << 20;
const CPU_SPIN_TICKS = 100;          // clock ticks between two snapshots that count as spinning
const CPU_ANY_TICKS = 10;
const TIMEOUT_MS = { short: 60000, docker: 120000, godotVersion: 60000, godotImport: 600000,
  npmCi: 600000, nakamaTest: 600000, composeUp: 900000, health: 180000 };
const TOP = ["DIAG_COMPLETE", "DIAG_INCOMPLETE", "DIAG_STOPPED_SAFETY"];
const SS = "STRONGLY SUPPORTED", NS = "NOT SUPPORTED", INC = "INCONCLUSIVE";
const OUTCOMES = new Set(["success", "failure", "cancelled", "skipped"]);
const DIAG_NOTE = "WP01-G Phase B diagnostic only (Linux GitHub runner). Not acceptance: never T1-T4, Deadline-late or WP01-G PASS.";
class SafetyError extends Error {}
class Precondition extends Error {}

// --- Secret rules (Proposal r2.1 §6.1): one rule set for redaction AND scanning.
// Values only: a bare header NAME such as Authorization (for example in the
// fault server's header_names array) never matches. Evidence records rule ids
// and counts only, never the rule text.
const SECRET_RULES = [
  { id: "S2", re: /eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{2,}(?:\.[A-Za-z0-9_-]*)?/g },
  { id: "S3", re: /authorization["']?\s*[:=]\s*["']?[^\s"',;}\]]+(?:[ \t]+[^\s"',;}\]]+)?/gi },
  { id: "S4", re: /\bbearer\s+(?=[A-Za-z0-9._~+/=-]*[0-9._~+/=-])[A-Za-z0-9._~+/=-]{8,}/gi },
  { id: "S5", re: /\bbasic\s+(?=[A-Za-z0-9+/]*[0-9+/=])[A-Za-z0-9+/]{8,}={0,2}/gi },
];
const RULE_IDS = ["S1", "S2", "S3", "S4", "S5"];

function redactText(text, secrets) {
  let s = String(text);
  const hits = {};
  for (const x of secrets) {
    if (!x || !s.includes(x)) continue;
    const parts = s.split(x);
    hits.S1 = (hits.S1 ?? 0) + parts.length - 1;
    s = parts.join("[REDACTED:S1]");
  }
  for (const { id, re } of SECRET_RULES) {
    re.lastIndex = 0;
    s = s.replace(re, () => { hits[id] = (hits[id] ?? 0) + 1; return `[REDACTED:${id}]`; });
  }
  return { text: s, hits };
}

function scanText(text, secrets, ids = RULE_IDS) {
  const { hits } = redactText(text, ids.includes("S1") ? secrets : []);
  const out = {};
  for (const id of ids) if (hits[id]) out[id] = hits[id];
  return out;
}

function deepRedact(v, secrets, hits) {
  if (typeof v === "string") { const r = redactText(v, secrets); for (const [k, n] of Object.entries(r.hits)) hits[k] = (hits[k] ?? 0) + n; return r.text; }
  if (Array.isArray(v)) return v.map((x) => deepRedact(x, secrets, hits));
  if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, deepRedact(x, secrets, hits)]));
  return v;
}

// Whole lines only, so a secret split across two chunks is still redacted.
class LineSplitter {
  constructor(onLine, maxLine = MAX_LINE_CHARS) {
    this.onLine = onLine; this.maxLine = maxLine; this.decoder = new StringDecoder("utf8");
    this.buf = ""; this.discarding = false; this.overflows = 0;
  }
  push(chunk) { this.feed(this.decoder.write(chunk)); }
  feed(s) {
    this.buf += s;
    for (;;) {
      const i = this.buf.indexOf("\n");
      if (i < 0) break;
      const line = this.buf.slice(0, i).replace(/\r$/, "");
      this.buf = this.buf.slice(i + 1);
      if (this.discarding) { this.discarding = false; continue; }
      this.onLine(line, false);
    }
    if (this.buf.length > this.maxLine) {
      if (!this.discarding) { this.overflows++; this.onLine(`[WP01G_LINE_TOO_LONG over ${this.maxLine} chars; content dropped]`, true); }
      this.discarding = true; this.buf = "";
    }
  }
  end() {
    this.feed(this.decoder.end());
    if (this.buf.length && !this.discarding) this.onLine(this.buf.replace(/\r$/, ""), true);
    this.buf = ""; this.discarding = false;
  }
}

// --- Heartbeat gaps (Proposal r2.1 §4.1 ①): every heartbeat, both clocks.
const round1 = (x) => Math.round(x * 10) / 10;
function computeGaps(hbs, { thresholdMs = HB_GAP_MS, endRecv = null } = {}) {
  const gaps = [], missing = [];
  let maxGodot = 0, maxRunner = 0;
  for (let i = 1; i < hbs.length; i++) {
    const a = hbs[i - 1], b = hbs[i];
    if (b.seq !== a.seq + 1) missing.push({ after_seq: a.seq, next_seq: b.seq });
    const g = b.ticks - a.ticks, r = b.recv - a.recv;
    maxGodot = Math.max(maxGodot, g); maxRunner = Math.max(maxRunner, r);
    if (g >= thresholdMs || r >= thresholdMs) {
      gaps.push({ start_seq: a.seq, end_seq: b.seq, start_ticks: a.ticks, end_ticks: b.ticks, godot_ms: g,
        runner_ms: round1(r), start_recv_ms: round1(a.recv), end_recv_ms: round1(b.recv), duration_ms: g, open: false,
        source: g >= thresholdMs && r >= thresholdMs ? "both" : g >= thresholdMs ? "godot" : "runner" });
    }
  }
  if (endRecv !== null && hbs.length) {
    const last = hbs[hbs.length - 1], r = endRecv - last.recv;
    if (r >= thresholdMs) gaps.push({ start_seq: last.seq, end_seq: null, start_ticks: last.ticks, end_ticks: null, godot_ms: null,
      runner_ms: round1(r), start_recv_ms: round1(last.recv), end_recv_ms: round1(endRecv), duration_ms: round1(r), open: true, source: "runner" });
  }
  return { threshold_ms: thresholdMs, heartbeats: hbs.length, gaps, missing, max_godot_gap_ms: maxGodot, max_runner_gap_ms: round1(maxRunner) };
}

function baselineCheck(hbs, requestTicks) {
  const pts = requestTicks === null ? [] : hbs.filter((h) => h.ticks < requestTicks);
  if (pts.length < 4) return { status: "UNKNOWN", reason: "fewer than 4 heartbeats before the request", intervals: Math.max(0, pts.length - 1) };
  let worst = 0;
  for (let i = 1; i < pts.length; i++) worst = Math.max(worst, Math.abs((pts[i].ticks - pts[i - 1].ticks) - (pts[i].recv - pts[i - 1].recv)));
  return { status: worst <= BASELINE_MAX_DIFF_MS ? "OK" : "MISMATCH", worst_diff_ms: round1(worst), intervals: pts.length - 1,
    note: worst <= BASELINE_MAX_DIFF_MS ? "" : "stdout may be buffered: long-stall alert and /proc snapshot timing for this case are UNKNOWN; gap lengths use the Godot clock" };
}

// B2: every recorded gap gets the nearest client event before its start and
// after its end (Godot clock; harness events carry a sequence number `n`).
// Where no event can be associated, the field is "UNKNOWN" (no guessing).
const EVENT_ID_FIELDS = ["attempt", "step", "result", "is_timeout", "layer", "reason", "status_is_disconnected"];
function eventBrief(e, ref) {
  const id = {};
  for (const k of EVENT_ID_FIELDS) if (e[k] !== undefined) id[k] = e[k];
  return { n: typeof e.n === "number" ? e.n : "UNKNOWN", e: e.e, t: e.t, delta_ms: e.t - ref, id };
}
function correlateGaps(gapList, events) {
  const evs = events.filter((e) => typeof e.t === "number" && typeof e.e === "string" && e.e !== "unparsable")
    .sort((a, b) => a.t - b.t || (a.n ?? 0) - (b.n ?? 0));
  return gapList.map((g) => {
    let before = null;
    for (const e of evs) { if (e.t <= g.start_ticks) before = e; else break; }
    const after = g.open || g.end_ticks === null ? null : evs.find((e) => e.t >= g.end_ticks) ?? null;
    const inside = evs.filter((e) => e.t > g.start_ticks && (g.end_ticks === null || e.t < g.end_ticks)).map((e) => ({ n: e.n ?? "UNKNOWN", e: e.e, t: e.t }));
    return { ...g, client_event_before: before ? eventBrief(before, g.start_ticks) : "UNKNOWN",
      client_event_after: after ? eventBrief(after, g.end_ticks) : "UNKNOWN", client_events_inside: inside };
  });
}

// B3: per attempt, the actual attempt time (start -> completion) and the retry
// backoff before it (previous completion -> start) are kept apart.
function attemptTimeline(events, reqEv, serverReqs) {
  const starts = events.filter((e) => e.e === "attempt_started"), comps = events.filter((e) => e.e === "attempt_completed");
  const req = reqEv && typeof reqEv.t === "number" ? reqEv.t : null, n = Math.max(starts.length, comps.length), rows = [];
  for (let i = 0; i < n; i++) {
    const s = starts[i] ?? null, c = comps[i] ?? null, prev = i > 0 ? comps[i - 1] ?? null : null;
    rows.push({ attempt: i + 1, start_rel_ms: s && req !== null ? s.t - req : null, completion_rel_ms: c && req !== null ? c.t - req : null,
      duration_ms: s && c && c.t >= s.t ? c.t - s.t : null,
      backoff_before_ms: i === 0 ? null : s && prev && s.t >= prev.t ? s.t - prev.t : null,
      result: c ? c.result : null, is_timeout: c ? c.is_timeout === true : null,
      server_request_rel_ms: serverReqs[i] && reqEv && typeof reqEv.recv_ms === "number" && typeof serverReqs[i].headers_complete_ms === "number"
        ? round1(serverReqs[i].headers_complete_ms - reqEv.recv_ms) : null });
  }
  const complete = n > 0 && starts.length === comps.length && rows.every((r) => r.duration_ms !== null && (r.attempt === 1 || r.backoff_before_ms !== null));
  return { attempts: rows, starts: starts.length, completions: comps.length, complete };
}

// --- Arguments, runner guard, evidence directory ------------------------------
function parseArgs(argv) {
  if (argv.includes("--selftest")) {
    if (argv.length !== 1) throw new Error("--selftest takes no other argument");
    return { mode: "selftest" };
  }
  const out = { mode: "", runId: "", evidenceDir: "", evidenceId: "", godot: "" };
  const seen = new Set();
  const take = (flag, i) => {
    if (seen.has(flag)) throw new Error(`${flag} must not be repeated`);
    seen.add(flag);
    if (i + 1 >= argv.length || argv[i + 1].startsWith("--")) throw new Error(`${flag} requires a value`);
    return argv[i + 1];
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (["--diag", "--inventory-only", "--finalize", "--verify-manifest"].includes(a)) {
      if (out.mode) throw new Error("exactly one mode is allowed");
      out.mode = a.slice(2);
    } else if (a === "--run-id") out.runId = take(a, i++);
    else if (a === "--evidence-dir") out.evidenceDir = take(a, i++);
    else if (a === "--evidence-id") out.evidenceId = take(a, i++);
    else if (a === "--godot") out.godot = take(a, i++);
    else throw new Error(`unknown argument: ${a}`);
  }
  if (!out.mode) throw new Error("a mode is required: --diag | --inventory-only | --finalize | --verify-manifest | --selftest");
  if (!RUN_ID_RE.test(out.runId)) throw new Error("--run-id must match " + RUN_ID_RE);
  if (!path.isAbsolute(out.evidenceDir)) throw new Error("--evidence-dir must be an absolute path");
  if (!ID_RE.test(out.evidenceId)) throw new Error("--evidence-id must be <dev>:<ino>");
  if (out.mode === "diag" && !path.isAbsolute(out.godot)) throw new Error("--godot must be an absolute path in --diag mode");
  if (out.mode !== "diag" && out.godot) throw new Error("--godot is valid only in --diag mode");
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

function verifyDir(dir, id, runnerTemp) {
  let st;
  try { st = fs.lstatSync(dir, { bigint: true }); } catch (e) { throw new SafetyError(`cannot lstat evidence directory: ${e.code ?? e}`); }
  if (st.isSymbolicLink() || !st.isDirectory()) throw new SafetyError("evidence directory is not a real directory");
  const real = fs.realpathSync(dir);
  const expected = path.join(requireRealDir(runnerTemp, "RUNNER_TEMP"), EVIDENCE_LEAF);
  if (real !== path.resolve(dir) || real !== expected) throw new SafetyError("evidence directory canonical path differs");
  if (typeof process.getuid !== "function" || st.uid !== BigInt(process.getuid())) throw new SafetyError("evidence directory owner uid differs");
  if ((st.mode & 0o022n) !== 0n) throw new SafetyError("evidence directory is writable by group/other");
  if (`${st.dev}:${st.ino}` !== id) throw new SafetyError("evidence directory device/inode differs");
  return real;
}

// Exclusive, no-follow evidence file (same design as the accepted WP01-F launcher).
class Leaf {
  constructor(dir, name, id, temp, append = false) {
    verifyDir(dir, id, temp);
    this.dir = dir; this.id = id; this.temp = temp; this.target = path.join(dir, name);
    if (typeof fs.constants.O_NOFOLLOW !== "number") throw new SafetyError("O_NOFOLLOW is unavailable");
    let flags = fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW;
    if (append) flags |= fs.constants.O_APPEND;
    try { this.fd = fs.openSync(this.target, flags, 0o600); } catch (e) { throw new SafetyError(`${name}: exclusive no-follow open failed: ${e.code ?? e}`); }
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
  // Rewrites THIS run's own exclusive file in place (summary / state); never another file.
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
  try { return fileType(fs.lstatSync(path.join(dir, name), { bigint: true })); } catch (e) { return e.code === "ENOENT" ? "missing" : "unknown"; }
}
function scanDir(dir, id, temp, omit = new Set()) {
  verifyDir(dir, id, temp); const files = [], anomalies = [];
  for (const name of fs.readdirSync(dir).sort()) {
    if (omit.has(name)) continue; let s;
    try { s = fs.lstatSync(path.join(dir, name), { bigint: true }); } catch (e) { throw new SafetyError(`${name}: lstat failed during evidence scan: ${e.code ?? e}`); }
    const type = fileType(s), reasons = [];
    if (name.startsWith(".")) reasons.push("hidden");
    if (type !== "regular") reasons.push("non-regular");
    if (reasons.length) anomalies.push({ name, type, reason: reasons.join("; ") }); else files.push(name);
  }
  verifyDir(dir, id, temp); return { files, anomalies };
}

const nowMs = () => Number(process.hrtime.bigint()) / 1e6;

class Evidence {
  constructor(args, temp, inventory = false) {
    this.args = args; this.temp = temp; this.secrets = []; this.seq = 0; this.pgids = [];
    this.streamHits = {}; this.safetyProblems = []; this.stateObj = null; this.stateFd = null; this.inSafety = false;
    this.logFd = new Leaf(args.evidenceDir, inventory ? "inventory-runner.log" : "runner.log", args.evidenceId, temp, true);
    this.summaryFd = inventory ? null : new Leaf(args.evidenceDir, "summary.json", args.evidenceId, temp);
    this.summary = inventory ? null : { run_id: args.runId, kind: "WP01-G Phase B diagnostic", proposal: "r2.1", note: DIAG_NOTE,
      started_at: new Date().toISOString(), steps: [], cases: {}, case_order: CASES.map((c) => c.id), top_result: "RUNNING" };
    if (this.summaryFd) this.save();
  }
  addHits(hits) {
    const ids = Object.keys(hits);
    if (!ids.length) return;
    for (const k of ids) this.streamHits[k] = (this.streamHits[k] ?? 0) + hits[k];
    this.safety(`secret rule(s) ${ids.sort().join(",")} matched in output; redacted before any output`);
  }
  redactLine(line) { const r = redactText(line, this.secrets); this.addHits(r.hits); return r.text; }
  safety(msg) {
    this.safetyProblems.push(msg);
    if (this.inSafety) return;
    this.inSafety = true;
    try { this.log(`SAFETY: ${msg}`); } finally { this.inSafety = false; }
  }
  log(v) { const s = this.redactLine(String(v)); console.log(s); this.logFd.append(s + "\n"); }
  file(name, text) {
    const r = redactText(String(text), this.secrets); this.addHits(r.hits);
    const f = new Leaf(this.args.evidenceDir, name, this.args.evidenceId, this.temp); try { f.once(r.text); } finally { f.close(); }
  }
  json(name, obj) {
    const hits = {}; const clean = deepRedact(obj, this.secrets, hits); this.addHits(hits);
    const f = new Leaf(this.args.evidenceDir, name, this.args.evidenceId, this.temp); try { f.once(JSON.stringify(clean, null, 2) + "\n"); } finally { f.close(); }
  }
  openLog(name) { return new Leaf(this.args.evidenceDir, name, this.args.evidenceId, this.temp, true); }
  next(name) { return `${String(++this.seq).padStart(3, "0")}-${name.replace(/[^A-Za-z0-9_.-]/g, "_")}.log`; }
  save() { const hits = {}; const clean = deepRedact(this.summary, this.secrets, hits); this.addHits(hits); this.summaryFd.replace(JSON.stringify(clean, null, 2) + "\n"); }
  state(v) {
    this.stateObj = v;
    if (!this.stateFd) this.stateFd = new Leaf(this.args.evidenceDir, STATE_FILE, this.args.evidenceId, this.temp);
    this.stateFd.replace(JSON.stringify(v, null, 2) + "\n");
  }
  trackPgid(pgid) {
    this.pgids.push(pgid);
    if (this.stateObj) { this.stateObj.pgids = [...this.pgids]; this.state(this.stateObj); }
  }
  close() { this.logFd.close(); this.summaryFd?.close(); this.stateFd?.close(); }
}

// --- Process ownership and termination (Proposal r2.1 §4.2; conservative --------
// design after GPT Diff Review round 3: S1-A, S1-B)
// - A signal goes ONLY to the spawned leader PID: never to a process group,
//   never to a negative, 0 or 1 pid. Before EACH signal the leader's identity
//   is proven from /proc: not reaped (no `exit` event, so its pid cannot have
//   been reused), same pid, process group = session = pid (spawned detached,
//   so setsid), same start time, same executable (the verified Godot binary for
//   Godot cases), and the runner's real and effective uid.
// - Survivors (any process still in the leader's process group after the
//   leader exited) are NEVER signalled: they are inventoried and the run takes
//   Safety FAIL -> STOP. A leader still running after the bounded wait is
//   handled the same way. Survivors are never reported as a normal completion.
// - realSignal() is the only place that calls process.kill. terminateFlow() and
//   checkSurvivors() take their effects as parameters, so A8 runs the real
//   decision flow with fakes and never sends a signal.
function readProc(rel, enc = "utf8") { try { return fs.readFileSync(`/proc/${rel}`, enc); } catch { return null; } }
function parseStat(text) {
  if (!text) return null;
  const close = text.lastIndexOf(")");
  if (close < 0) return null;
  const f = text.slice(close + 2).trim().split(/\s+/); // f[0] = field 3 (state)
  if (f.length < 20) return null;
  return { state: f[0], ppid: Number(f[1]), pgrp: Number(f[2]), sid: Number(f[3]), utime: Number(f[11]), stime: Number(f[12]), starttime: f[19] };
}
function readUid(pid) {
  const m = /^Uid:\s+(\d+)\s+(\d+)/m.exec(readProc(`${pid}/status`) ?? "");
  return m ? { real: Number(m[1]), effective: Number(m[2]) } : null;
}
function readExe(pid) { try { return fs.readlinkSync(`/proc/${pid}/exe`); } catch { return null; } }
function readCmd0Real(pid) {
  const c0 = (readProc(`${pid}/cmdline`) ?? "").split("\0")[0];
  if (!c0 || !path.isAbsolute(c0)) return null;
  try { return fs.realpathSync(c0); } catch { return null; }
}
// One read-only /proc snapshot of a process (null if its stat is unreadable).
function procIdentity(pid) {
  const st = parseStat(readProc(`${pid}/stat`));
  if (!st) return null;
  const uid = readUid(pid);
  return { pid: Number(pid), state: st.state, pgrp: st.pgrp, sid: st.sid, starttime: st.starttime,
    uid: uid ? uid.real : null, euid: uid ? uid.effective : null, exe: readExe(pid), cmd0: readCmd0Real(pid),
    comm: (readProc(`${pid}/comm`) ?? "").trim() || null };
}

// Pure: is a still-running leader the process recorded at spawn? "" = proven.
function leaderVerdict(proc, cur, me) {
  if (proc.exited) return "leader already exited and was reaped (exit event); its pid may be reused";
  const id = proc.identity;
  if (!id) return `identity not captured${proc.identityError ? `: ${proc.identityError}` : ""}`;
  if (proc.expectedExe && id.exe !== proc.expectedExe) return "recorded executable is not the verified binary";
  if (!cur) return "cannot read /proc identity";
  if (cur.pid !== proc.pid || id.pid !== proc.pid) return "pid differs";
  if (cur.pgrp !== id.pgid || id.pgid !== proc.pid) return "process group differs";
  if (cur.sid !== id.sid || id.sid !== proc.pid) return "session differs";
  if (cur.starttime !== id.starttime) return "start time differs";
  if ((id.exe_source === "exe" ? cur.exe : cur.cmd0) !== id.exe) return "executable differs";
  if (cur.uid !== me || cur.euid !== me || id.uid !== me || id.euid !== me) return "uid differs";
  return "";
}
// Pure: a signal target must be one positive process id (> 1); never a group.
function signalTargetProblem(pid, leaderPid) {
  if (!Number.isSafeInteger(pid) || pid <= 1) return `refusing to signal pid ${pid} (only one positive leader pid > 1 is allowed)`;
  if (pid !== leaderPid) return `refusing to signal pid ${pid}: it is not the spawned leader ${leaderPid}`;
  return "";
}
function inventoryEntry(s, reason) {
  return { pid: s.pid, starttime: s.starttime ?? null, pgrp: s.pgrp ?? null, sid: s.sid ?? null, uid: s.uid ?? null, euid: s.euid ?? null,
    state: s.state ?? null, exe: s.exe ?? null, comm: s.comm ?? null, reason };
}

function captureIdentity(proc) {
  if (proc.exited || proc.identity || !Number.isSafeInteger(proc.pid)) return;
  const cur = procIdentity(proc.pid);
  let exe = cur?.exe ?? null, exeSource = "exe";
  if (!exe && cur) { exe = cur.cmd0; exeSource = "cmdline"; }
  if (!cur || cur.uid === null || !exe) { proc.identityError = "identity unreadable"; return; }
  if (cur.pgrp !== proc.pid) { proc.identityError = `process group ${cur.pgrp} is not the spawned pid`; return; }
  if (cur.sid !== proc.pid) { proc.identityError = `session ${cur.sid} is not the spawned pid`; return; }
  if (proc.expectedExe && exe !== proc.expectedExe) { proc.identityError = "executable is not the verified binary"; return; }
  proc.identity = { pid: proc.pid, pgid: cur.pgrp, sid: cur.sid, starttime: cur.starttime, exe, exe_source: exeSource, uid: cur.uid, euid: cur.euid };
  proc.identityError = "";
}

function survivorsOf(pgid) {
  const out = [];
  let names = [];
  try { names = fs.readdirSync("/proc"); } catch { return { list: out, readable: false }; }
  for (const name of names) {
    if (!/^\d+$/.test(name)) continue;
    const st = parseStat(readProc(`${name}/stat`));
    if (st && st.pgrp === pgid) out.push(procIdentity(name) ?? { pid: Number(name), pgrp: st.pgrp, sid: st.sid, starttime: st.starttime, uid: null, euid: null });
  }
  return { list: out, readable: true };
}

// The ONLY call of process.kill in this file: one positive leader pid.
function realSignal(pid, sig, leaderPid) {
  const problem = signalTargetProblem(pid, leaderPid);
  if (problem) throw new SafetyError(problem);
  process.kill(pid, sig);
}
function liveIo(ev, proc) {
  return { me: process.getuid(), identity: (pid) => procIdentity(pid), signal: (pid, sig) => realSignal(pid, sig, proc.pid),
    waitExit: (ms) => waitExit(proc, ms), scanGroup: (pgid) => survivorsOf(pgid), safety: (m) => ev.safety(m), now: () => round1(nowMs() - proc.t0) };
}
// Decision flow: SIGTERM, then SIGKILL, each to the leader pid only and only
// after a fresh identity proof. Any refusal or error stops the flow.
async function terminateFlow(proc, why, io) {
  for (const sig of ["SIGTERM", "SIGKILL"]) {
    if (proc.exited) return;
    const problem = leaderVerdict(proc, io.identity(proc.pid), io.me);
    if (problem) {
      proc.signals.push({ sig, why, sent: false, target: proc.pid, problem });
      io.safety(`${proc.name}: ${sig} not sent, leader identity not proven (${problem})`);
      return;
    }
    try { io.signal(proc.pid, sig); proc.signals.push({ sig, why, sent: true, target: proc.pid, at_ms: io.now() }); }
    catch (e) {
      proc.signals.push({ sig, why, sent: false, target: proc.pid, error: e?.code ?? String(e?.message ?? e) });
      if (e instanceof SafetyError) io.safety(`${proc.name}: ${e.message}`);
      return;
    }
    if (await io.waitExit(KILL_GRACE_MS)) return;
  }
}
// After the bounded wait. Never signals anything: any process left in the
// leader's group (or a leader still running) -> inventory + Safety STOP.
function checkSurvivors(proc, io) {
  if (!Number.isSafeInteger(proc.pid)) return { survivors: [], inventory: [], leader_running: false };
  const g = io.scanGroup(proc.pid);
  if (!g.readable) {
    io.safety(`${proc.name}: /proc unreadable; survivors unknown; no signal sent`);
    return { survivors: "unknown", inventory: "unknown", leader_running: !proc.exited };
  }
  const pids = g.list.map((x) => x.pid);
  if (!proc.exited) {
    io.safety(`${proc.name}: leader still running after the bounded wait; no further signal; inventory recorded`);
    return { survivors: pids, inventory: g.list.map((s) => inventoryEntry(s, "leader still running after the bounded wait (no further signal)")), leader_running: true };
  }
  if (pids.length) io.safety(`${proc.name}: ${pids.length} survivor(s) in the process group (pids ${pids.join(",")}); never signalled; inventory recorded`);
  return { survivors: pids, inventory: g.list.map((s) => inventoryEntry(s, "survivor in the leader's process group after the leader exited (never signalled)")), leader_running: false };
}

function spawnTracked(ev, name, cmd, argv, { cwd = REPO, env = process.env, expectedExe = null, t0 = nowMs() } = {}) {
  const proc = { name, pid: null, child: null, identity: null, identityError: "", exited: false, exitCode: null, exitSignal: null,
    closed: false, signals: [], expectedExe, t0, waiters: [], closeWaiters: [] };
  try { proc.child = spawn(cmd, argv, { cwd, env, detached: true, stdio: ["ignore", "pipe", "pipe"] }); }
  catch (e) { proc.spawnError = String(e?.message ?? e); proc.exited = true; proc.closed = true; return proc; }
  proc.pid = proc.child.pid;
  if (!Number.isSafeInteger(proc.pid)) { proc.spawnError = "spawn returned no pid"; }
  else ev.trackPgid(proc.pid);
  proc.child.on("error", (e) => {
    proc.spawnError = proc.spawnError || String(e?.message ?? e);
    if (!Number.isSafeInteger(proc.pid)) { // never started (for example ENOENT): nothing to wait for
      proc.exited = true; proc.closed = true;
      for (const w of proc.closeWaiters.splice(0)) w(true); for (const w of proc.waiters.splice(0)) w(true);
    }
  });
  proc.child.on("exit", (code, signal) => {
    proc.exited = true; proc.exitCode = code; proc.exitSignal = signal; proc.exitAt = round1(nowMs() - t0);
    for (const w of proc.waiters.splice(0)) w(true);
  });
  proc.child.on("close", () => { proc.closed = true; if (!proc.exited) proc.exited = true; for (const w of proc.closeWaiters.splice(0)) w(true); for (const w of proc.waiters.splice(0)) w(true); });
  if (Number.isSafeInteger(proc.pid)) { captureIdentity(proc); setTimeout(() => captureIdentity(proc), 250).unref(); }
  return proc;
}
function waitExit(proc, ms) {
  if (proc.exited) return Promise.resolve(true);
  return new Promise((resolve) => { const t = setTimeout(() => resolve(false), ms); proc.waiters.push(() => { clearTimeout(t); resolve(true); }); });
}
function waitClose(proc, ms) {
  if (proc.closed) return Promise.resolve(true);
  return new Promise((resolve) => { const t = setTimeout(() => resolve(false), ms); proc.closeWaiters.push(() => { clearTimeout(t); resolve(true); }); });
}
async function terminate(ev, proc, why) {
  if (proc.exited) return;
  captureIdentity(proc);
  await terminateFlow(proc, why, liveIo(ev, proc));
}
async function settleSurvivors(ev, proc) {
  const r = checkSurvivors(proc, liveIo(ev, proc));
  return { survivors: r.survivors, killed: [], remaining: r.survivors, inventory: r.inventory, leader_running: r.leader_running };
}

function attachLines(ev, proc, onLine) {
  const mk = (stream) => new LineSplitter((raw, partial) => onLine(stream, ev.redactLine(raw), partial));
  const out = mk("stdout"), err = mk("stderr");
  proc.child.stdout.on("data", (c) => out.push(c)); proc.child.stdout.on("end", () => out.end());
  proc.child.stderr.on("data", (c) => err.push(c)); proc.child.stderr.on("end", () => err.end());
  return { out, err };
}

async function runBounded(ev, name, cmd, argv, { cwd = REPO, env = process.env, timeoutMs, expectedExe = null, echo = true }) {
  const logName = ev.next(name), display = ev.redactLine([cmd, ...argv].join(" ")), lines = [];
  const log = ev.openLog(logName);
  const t0 = nowMs();
  log.append(`$ ${display}\n# cwd=${path.relative(REPO, cwd) || "."} timeout_ms=${timeoutMs}\n`);
  const proc = spawnTracked(ev, name, cmd, argv, { cwd, env, expectedExe, t0 });
  if (proc.spawnError && !proc.child) {
    log.append(`spawn failed: ${ev.redactLine(proc.spawnError)}\n`); log.close();
    return { rec: { name, command: display, exit_code: null, signal: null, timed_out: false, survivors: [], duration_ms: 0, log: logName, error: proc.spawnError }, output: "" };
  }
  const safetyAtStart = ev.safetyProblems.length;
  let safetyStop = false;
  attachLines(ev, proc, (stream, line) => {
    lines.push(line); log.append((stream === "stderr" ? "[stderr] " : "") + line + "\n"); if (echo) console.log(`[${name}] ${line}`);
    if (!safetyStop && ev.safetyProblems.length > safetyAtStart) { safetyStop = true; terminate(ev, proc, "safety STOP"); }
  });
  let timedOut = false;
  const timer = setTimeout(() => { timedOut = true; terminate(ev, proc, `step timeout ${timeoutMs} ms`); }, timeoutMs);
  const closed = await waitClose(proc, timeoutMs + 2 * KILL_GRACE_MS + CLOSE_WAIT_MS);
  clearTimeout(timer);
  const surv = await settleSurvivors(ev, proc);
  const rec = { name, command: display, cwd: path.relative(REPO, cwd) || ".", exit_code: proc.exitCode, signal: proc.exitSignal, timed_out: timedOut,
    close_wait_expired: !closed, survivors: surv.survivors, survivors_killed: surv.killed, survivors_remaining: surv.remaining, survivor_inventory: surv.inventory ?? [], leader_running: surv.leader_running ?? false, signals: proc.signals,
    identity: proc.identity, duration_ms: round1(nowMs() - t0), log: logName, pgid: proc.pid, error: proc.spawnError || undefined };
  log.append(`# exit=${proc.exitCode} signal=${proc.exitSignal} timed_out=${timedOut} close_wait_expired=${!closed} survivors=${JSON.stringify(surv.survivors)} duration_ms=${rec.duration_ms}\n`);
  log.close();
  return { rec, output: lines.join("\n") };
}
const stepProblem = (r) => r.rec.error ? `could not start: ${r.rec.error}` : r.rec.timed_out ? "timed out" : r.rec.close_wait_expired ? "did not close"
  : (Array.isArray(r.rec.survivors_remaining) ? r.rec.survivors_remaining.length : 1) ? "process survivors remain" : r.rec.exit_code !== 0 ? `exit ${r.rec.exit_code}` : "";

// --- Fault server: outside Godot, 127.0.0.1 only, owned by this process ---------
const DELAY_BODY = "{\"diag\":\"late\"}";
const DELAY_RESPONSE = `HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(DELAY_BODY)}\r\nConnection: close\r\n\r\n${DELAY_BODY}`;
const HEADER_NAME_RE = /^[!#$%&'*+.^_`|~0-9A-Za-z-]{1,64}$/;
function parseHead(c, buf) {
  const lines = buf.toString("latin1").split("\r\n");
  c.request_line = lines[0].replace(/[^\x20-\x7e]/g, "?").slice(0, 200);
  // Header NAMES only, as a JSON string array; values and body are never stored.
  c.header_names = lines.slice(1, 65).map((l) => { const k = l.indexOf(":"); const n = k > 0 ? l.slice(0, k).trim() : ""; return HEADER_NAME_RE.test(n) ? n : "<invalid>"; });
}
function startFaultServer(mode, t0) {
  return new Promise((resolve, reject) => {
    const conns = [], sockets = new Set(); let seq = 0;
    const rel = () => round1(nowMs() - t0);
    const server = net.createServer((sock) => {
      const c = { conn: ++seq, accept_ms: rel(), first_byte_ms: null, bytes_in: 0, request_line: null, header_names: null, headers_complete_ms: null,
        reply_due_ms: null, reply_ms: null, reply_result: null, closed_ms: null, close_kind: null, socket_error: null };
      conns.push(c); sockets.add(sock);
      let head = Buffer.alloc(0), headDone = false;
      const reply = () => {
        if (sock.destroyed || !sock.writable) { c.reply_result = "client_closed_before_reply"; return; }
        c.reply_ms = rel();
        sock.write(DELAY_RESPONSE, (err) => { c.reply_result = err ? `write_error:${err.code ?? err}` : "write_callback_ok"; c.reply_written_ms = rel(); });
        sock.end();
      };
      const drop = (kind) => { if (c.close_kind) return; c.close_kind = kind; c.dropped_ms = rel(); sock.destroy(); };
      sock.on("data", (d) => {
        if (c.first_byte_ms === null) {
          c.first_byte_ms = rel();
          if (mode === "drop") setTimeout(() => drop("dropped_by_server_head_incomplete"), DROP_FALLBACK_MS);
        }
        c.bytes_in += d.length;
        if (!headDone) {
          head = Buffer.concat([head, d]).subarray(0, 65536);
          const i = head.indexOf("\r\n\r\n");
          if (i >= 0 || head.length >= 65536) {
            headDone = true; c.headers_complete_ms = rel(); parseHead(c, head.subarray(0, i >= 0 ? i : head.length)); head = Buffer.alloc(0);
            if (mode === "delay") { c.reply_due_ms = round1(c.headers_complete_ms + DELAY_REPLY_MS); setTimeout(reply, DELAY_REPLY_MS); }
            // Drop only after the request line + headers arrived, so every drop case records the request (B1).
            if (mode === "drop") drop("dropped_by_server");
          }
        }
      });
      sock.on("error", (e) => { c.socket_error = e.code ?? String(e); });
      sock.on("close", () => { c.closed_ms = rel(); if (!c.close_kind) c.close_kind = "closed"; sockets.delete(sock); });
    });
    server.on("error", reject);
    server.listen(0, HOST, () => {
      const addr = server.address();
      resolve({ mode, port: addr.port, host: addr.address, conns, close: () => new Promise((done) => {
        for (const s of sockets) s.destroy();
        const t = setTimeout(() => done(false), 2000);
        server.close(() => { clearTimeout(t); done(true); });
      }) });
    });
  });
}

// --- /proc thread snapshots (read only; never attach) ---------------------------
function procSnapshot(proc, label) {
  const snap = { label, at_recv_ms: round1(nowMs() - proc.t0), threads: [], error: null };
  if (proc.exited) { snap.error = "process already exited"; return snap; }
  let tids;
  try { tids = fs.readdirSync(`/proc/${proc.pid}/task`).filter((x) => /^\d+$/.test(x)).sort((a, b) => Number(a) - Number(b)); }
  catch (e) { snap.error = `task list unreadable: ${e.code ?? e}`; return snap; }
  for (const tid of tids) {
    const base = `${proc.pid}/task/${tid}`, st = parseStat(readProc(`${base}/stat`));
    snap.threads.push({ tid: Number(tid), main: Number(tid) === proc.pid, comm: (readProc(`${base}/comm`) ?? "").trim() || null,
      state: st?.state ?? null, utime: st?.utime ?? null, stime: st?.stime ?? null,
      wchan: (readProc(`${base}/wchan`) ?? "").trim() || null, syscall: (readProc(`${base}/syscall`) ?? "").trim().split(" ")[0] || null });
  }
  return snap;
}
function interpretThreads(snaps) {
  const note = "Indirect evidence only (read-only /proc, no stack trace): STRONGLY SUPPORTED is the highest level.";
  const okSnaps = snaps.filter((s) => !s.error && s.threads.length);
  if (okSnaps.length < 2) return { busy_loop: "UNKNOWN", blocking_read: "UNKNOWN", join_wait: "UNKNOWN", reason: "fewer than 2 readable snapshots", note };
  const a = okSnaps[0], b = okSnaps[okSnaps.length - 1];
  const cpu = b.threads.map((t) => { const p = a.threads.find((x) => x.tid === t.tid); const d = p && t.utime !== null && p.utime !== null ? (t.utime + t.stime) - (p.utime + p.stime) : null; return { tid: t.tid, main: t.main, comm: t.comm, state: t.state, cpu_ticks_delta: d, wchan: t.wchan, syscall: t.syscall }; });
  const spinning = cpu.filter((t) => !t.main && t.cpu_ticks_delta !== null && t.cpu_ticks_delta >= CPU_SPIN_TICKS && t.state === "R");
  const anyCpu = cpu.filter((t) => t.cpu_ticks_delta !== null && t.cpu_ticks_delta >= CPU_ANY_TICKS);
  const sockWait = cpu.filter((t) => !t.main && (/sk_wait|wait_woken|tcp|inet|sock|unix_stream|poll|select/i.test(t.wchan ?? "") || ["0", "45", "7", "232", "270", "271", "281"].includes(t.syscall ?? "")));
  const main = cpu.find((t) => t.main);
  const futex = main && (/futex/i.test(main.wchan ?? "") || main.syscall === "202");
  return { window_ms: round1(b.at_recv_ms - a.at_recv_ms), busy_loop: spinning.length ? SS : anyCpu.length ? INC : NS,
    blocking_read: !anyCpu.length && sockWait.length ? SS : INC, join_wait: futex ? SS : main ? INC : "UNKNOWN", threads: cpu, note };
}

// --- Run root, isolation, Nakama checks -------------------------------------------
function createRoot(ev, runId, temp) {
  const base = requireRealDir(temp, "RUNNER_TEMP"), root = fs.realpathSync(fs.mkdtempSync(path.join(base, `${ROOT_PREFIX}${runId}-`)));
  fs.chmodSync(root, 0o700); for (const s of ["home", "xdg-data", "xdg-config", "xdg-cache", "tmp"]) fs.mkdirSync(path.join(root, s), { mode: 0o700 });
  const st = fs.statSync(root), sentinel = { run_id: runId, root, dev: st.dev, ino: st.ino, created_at: new Date().toISOString() };
  fs.writeFileSync(path.join(root, SENTINEL), JSON.stringify(sentinel) + "\n", { flag: "wx", mode: 0o600 });
  const state = { run_id: runId, base, root, root_dev: st.dev, root_ino: st.ino, compose_project: runId, compose_started: false, secrets_generated: false, pgids: [...ev.pgids] };
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
function godotEnv(s, extra = {}) { return { PATH: process.env.PATH ?? "/usr/bin:/bin", LANG: "C.UTF-8", HOME: path.join(s.root, "home"), XDG_DATA_HOME: path.join(s.root, "xdg-data"), XDG_CONFIG_HOME: path.join(s.root, "xdg-config"), XDG_CACHE_HOME: path.join(s.root, "xdg-cache"), TMPDIR: path.join(s.root, "tmp"), ...extra }; }
function inside(root, p) { if (typeof p !== "string" || !path.isAbsolute(p)) return false; const within = (q) => q === root || q.startsWith(root + path.sep); let q = path.resolve(p); if (!within(q)) return false; for (;;) { try { fs.lstatSync(q); break; } catch (e) { if (e.code !== "ENOENT") return false; const up = path.dirname(q); if (up === q) return false; q = up; } } try { return within(fs.realpathSync(q)); } catch { return false; } }
function isolationProblem(s) { const e = godotEnv(s); for (const k of ["HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "TMPDIR"]) { try { requireRealDir(e[k], k); } catch (x) { return String(x.message ?? x); } if (!inside(s.root, e[k])) return `${k} outside run root`; } return ""; }
async function healthy(ms) { const until = Date.now() + ms; while (Date.now() < until) { try { const r = await fetch(`http://${HOST}:${NAKAMA_PORT}/healthcheck`, { signal: AbortSignal.timeout(2000) }); if (r.ok) return true; } catch {} await new Promise((r) => setTimeout(r, 1000)); } return false; }
async function respondsNow() { try { const r = await fetch(`http://${HOST}:${NAKAMA_PORT}/healthcheck`, { signal: AbortSignal.timeout(2000) }); return r.ok || r.status > 0; } catch { return false; } }

// --- One case = one Godot process -------------------------------------------------
async function runCase(ev, state, def, { godot, port = null, server = null, env, t0 }) {
  const id = def.id, files = { log: `${id}-godot.log` };
  const log = ev.openLog(files.log);
  const hbs = [], events = [], stalls = [], snapshots = [], timers = [];
  let result = null, resultRecv = null, lastHbRecv = null, stall = null, finished = false, capReached = false, capAt = null;
  const rel = () => round1(nowMs() - t0);
  const argv = ["--headless", "--path", GODOT_DIR, "--script", HARNESS, "--", "--case", id, ...(port ? ["--port", String(port)] : [])];
  const proc = spawnTracked(ev, `case-${id}`, godot, argv, { cwd: REPO, env, expectedExe: godot, t0 });
  const rec = { id, layer: def.layer, use_threads: def.threads, server_mode: def.server, port, started_at: new Date().toISOString(), files };
  if (!proc.child) { log.append(`spawn failed: ${ev.redactLine(proc.spawnError ?? "")}\n`); log.close(); return { ...rec, status: "INCONCLUSIVE", reason: "spawn failed" }; }
  const endStall = (at) => { if (!stall) return; stall.end_recv_ms = at; for (const t of stall.timers) clearTimeout(t); delete stall.timers; stall = null; };
  const safetyAtStart = ev.safetyProblems.length;
  let safetyStop = false;
  attachLines(ev, proc, (stream, line) => {
    const at = rel();
    log.append((stream === "stderr" ? "[stderr] " : "") + line + "\n");
    // Safety FAIL (for example a secret pattern in the output): STOP this case now.
    if (!safetyStop && ev.safetyProblems.length > safetyAtStart) { safetyStop = true; rec.safety_stop = true; terminate(ev, proc, "safety STOP"); }
    if (!proc.identity) captureIdentity(proc);
    if (stream === "stdout") {
      const m = /^HB (\d+) (\d+)$/.exec(line);
      if (m) { hbs.push({ seq: Number(m[1]), ticks: Number(m[2]), recv: at }); lastHbRecv = at; endStall(at); return; }
      if (line.startsWith("EV ")) { try { events.push({ ...JSON.parse(line.slice(3)), recv_ms: at }); } catch { events.push({ e: "unparsable", recv_ms: at }); } }
      else if (line.startsWith("WP01G_DIAG ")) { try { result = JSON.parse(line.slice(11)); } catch { result = { unparsable: true }; } resultRecv = at; }
    }
    console.log(`[${id}] ${line}`);
  });
  const watchdog = setInterval(() => {
    if (finished || proc.exited || lastHbRecv === null || stall || result) return;
    const at = rel();
    if (at - lastHbRecv <= LONG_STALL_MS) return;
    const s = { start_recv_ms: lastHbRecv, alert_recv_ms: at, end_recv_ms: null, timers: [] };
    stalls.push(s); stall = s;
    for (const after of SNAPSHOT_AFTER_MS) {
      const t = setTimeout(() => { if (stall === s && !proc.exited) snapshots.push(procSnapshot(proc, `stall${stalls.length}+${after}ms`)); }, Math.max(0, s.start_recv_ms + after - at));
      s.timers.push(t);
    }
  }, WATCHDOG_TICK_MS);
  timers.push(setTimeout(() => { capReached = true; capAt = rel(); terminate(ev, proc, `case hard cap ${CASE_HARD_CAP_MS} ms`); }, CASE_HARD_CAP_MS));
  const closed = await waitClose(proc, CASE_HARD_CAP_MS + 2 * KILL_GRACE_MS + CLOSE_WAIT_MS);
  finished = true; clearInterval(watchdog); for (const t of timers) clearTimeout(t);
  if (stall) { for (const t of stall.timers) clearTimeout(t); stall = null; } // an unrecovered stall keeps end_recv_ms = null
  const surv = await settleSurvivors(ev, proc);
  if (server) rec.fault_server_closed = await server.close();
  const endRecv = capReached || !result ? (proc.exitAt ?? rel()) : null;
  const gaps = computeGaps(hbs, { endRecv });
  gaps.gaps = correlateGaps(gaps.gaps, events);
  const reqEv = events.find((e) => e.e === "request_start");
  const baseline = baselineCheck(hbs, reqEv ? reqEv.t : null);
  for (const s of stalls) delete s.timers;
  const threads = interpretThreads(snapshots);
  Object.assign(rec, { exit_code: proc.exitCode, exit_signal: proc.exitSignal, exit_at_ms: proc.exitAt ?? null, cap_reached: capReached, cap_at_ms: capAt,
    close_wait_expired: !closed, signals: proc.signals, identity: proc.identity, identity_error: proc.identityError || undefined,
    survivors: surv.survivors, survivors_killed: surv.killed, survivors_remaining: surv.remaining, survivor_inventory: surv.inventory ?? [], leader_running: surv.leader_running ?? false, result, result_recv_ms: resultRecv });
  log.close();
  ev.json(`${id}-heartbeat.json`, { case: id, interval_ms: 250, heartbeats: hbs });
  ev.json(`${id}-hb-gaps.json`, { case: id, ...gaps, baseline, long_stall_alert_ms: LONG_STALL_MS, long_stalls: stalls });
  ev.json(`${id}-client-events.json`, { case: id, events, result });
  if (server) ev.json(`${id}-server-events.json`, { case: id, mode: server.mode, connections: server.conns });
  ev.json(`${id}-proc.json`, { case: id, snapshots, interpretation: threads });
  ev.json(`${id}-exit.json`, { case: id, exit_code: rec.exit_code, exit_signal: rec.exit_signal, exit_at_ms: rec.exit_at_ms, cap_reached: capReached, cap_at_ms: capAt,
    close_wait_expired: !closed, signals: proc.signals, identity: proc.identity, identity_error: proc.identityError || null, survivors: surv.survivors, survivors_killed: surv.killed, survivors_remaining: surv.remaining, survivor_inventory: surv.inventory ?? [], leader_running: surv.leader_running ?? false });
  Object.assign(files, { heartbeat: `${id}-heartbeat.json`, gaps: `${id}-hb-gaps.json`, client: `${id}-client-events.json`, server: server ? `${id}-server-events.json` : null, proc: `${id}-proc.json`, exit: `${id}-exit.json` });
  rec.facts = caseFacts({ def, hbs, gaps, events, result, capReached, server, baseline, threads });
  rec.status = caseStatus(def, rec.facts);
  rec.reason = rec.status === "INCONCLUSIVE" ? inconclusiveReason(def, rec.facts, rec) : "";
  ev.log(`case ${id}: ${rec.status}${rec.reason ? ` (${rec.reason})` : ""}; heartbeats=${hbs.length} gaps>=${HB_GAP_MS}ms=${gaps.gaps.length} long_stalls=${stalls.length} cap=${capReached}`);
  return rec;
}

const FAULT_MODES = ["stall", "drop", "delay"];
function caseFacts({ def, hbs, gaps, events, result, capReached, server, baseline, threads }) {
  const layer = def.layer;
  const of = (n) => events.filter((e) => e.e === n);
  const reqEv = of("request_start")[0] ?? null, req = reqEv ? reqEv.t : null;
  const endEv = of("observe_window_end")[0] ?? null, obsEnd = endEv ? endEv.t : null;
  const rel = (t) => (req === null || typeof t !== "number" ? null : t - req);
  const returned = !!result && !result.unparsable;
  // Window: from just before the request to the end of the harness observation.
  // An open gap counts only when no result line arrived (otherwise it is an
  // exit-phase wait after the result, recorded separately as exit_hang).
  const inWindow = (g) => req !== null && g.start_ticks >= req - PRE_REQUEST_SLACK_MS && (obsEnd === null || g.start_ticks < obsEnd)
    && (g.open ? !returned : g.godot_ms >= HB_GAP_MS);
  const post = gaps.gaps.filter(inWindow);
  const comps = (layer === "S" ? of("attempt_completed") : of("completion")).map((e) => ({ n: e.n ?? null, rel_ms: rel(e.t), result: e.result, is_timeout: e.is_timeout === true, is_success: e.is_success === true, http_code: e.http_code }));
  const sdk = of("sdk_return")[0] ?? null, ready = of("adapter_ready")[0] ?? null, listener = of("listener_ready")[0] ?? null;
  const stallGap = post.find((g) => g.open || g.duration_ms >= LONG_STALL_MS) ?? null;
  const recoverGap = post.find((g) => !g.open && g.duration_ms >= HB_GAP_MS && g.duration_ms < LONG_STALL_MS) ?? null;
  // B1: did the request really reach the EXTERNAL fault server? Only connections
  // whose request line is this case's own URL count.
  const isFault = FAULT_MODES.includes(def.server);
  const line = `POST /wp01g/diag/${def.id} `;
  const conns = server ? server.conns : [];
  const reqs = conns.filter((c) => typeof c.request_line === "string" && c.request_line.startsWith(line) && typeof c.headers_complete_ms === "number");
  const stallStartRecv = stallGap ? stallGap.start_recv_ms : null;
  const firstReq = reqs[0] ?? null;
  const openAt = (t) => reqs.some((c) => c.closed_ms === null || c.closed_ms > t);
  const server_evidence = !isFault ? null : {
    mode: def.server, connections: conns.length, requests_with_case_url: reqs.length,
    other_connections: conns.length - reqs.length,
    first_request_rel_ms: firstReq && reqEv && typeof reqEv.recv_ms === "number" ? round1(firstReq.headers_complete_ms - reqEv.recv_ms) : null,
    request_before_stall: stallStartRecv === null || !firstReq ? null : firstReq.headers_complete_ms <= stallStartRecv + HB_INTERVAL_MS,
    connection_open_at_stall: def.server !== "stall" || stallStartRecv === null ? null : openAt(stallStartRecv + HB_INTERVAL_MS),
    connection_open_at_observe_end: def.server !== "stall" || !endEv || typeof endEv.recv_ms !== "number" ? null : openAt(endEv.recv_ms),
    reply_sent: conns.some((c) => c.reply_ms !== null),
    replies: conns.map((c) => c.reply_result).filter(Boolean),
  };
  const timeline = layer === "S" ? attemptTimeline(events, reqEv, reqs) : null;
  const firstStart = of("attempt_started")[0] ?? null;
  return {
    returned, harness_ok: result?.harness_ok === true, cap_reached: capReached, exit_hang: capReached && returned,
    request_seen: req !== null, observe_end_reason: endEv?.reason ?? null, hb_count: hbs.length, hb_complete: hbs.length > 0 && gaps.missing.length === 0,
    hang: capReached && !returned && post.some((g) => g.open), baseline: baseline.status,
    post_gaps: post.map((g) => ({ start_rel_ms: rel(g.start_ticks), duration_ms: g.duration_ms, open: g.open, source: g.source,
      client_event_before: g.client_event_before === "UNKNOWN" ? "UNKNOWN" : `${g.client_event_before.e}#${g.client_event_before.n}`,
      client_event_after: g.client_event_after === "UNKNOWN" ? "UNKNOWN" : `${g.client_event_after.e}#${g.client_event_after.n}` })),
    stall_start_rel_ms: stallGap ? rel(stallGap.start_ticks) : null,
    recover_gap_start_rel_ms: recoverGap ? rel(recoverGap.start_ticks) : null,
    long_stall: post.some((g) => !g.open && g.duration_ms >= LONG_STALL_MS),
    stall_then_recover: !!recoverGap,
    completions: comps,
    sdk_returned: !!sdk, sdk_return_rel_ms: sdk ? rel(sdk.t) : null, sdk_exception: sdk ? sdk.exception === true : null, sdk_status_code: sdk?.status_code ?? null,
    server_request_seen: isFault ? reqs.length > 0 : null, server_requests: isFault ? reqs.length : null, server_evidence,
    attempt_timeline: timeline,
    // R1: the completion listener was attached while the request was not yet started.
    listener_ready_before_request: !listener ? false : listener.status_is_disconnected === true
      && (layer !== "S" || !firstStart || (typeof listener.n === "number" && typeof firstStart.n === "number" && listener.n < firstStart.n)),
    adapter_timeout_initial: result?.adapter_timeout_initial ?? null, adapter_timeout: ready?.adapter_timeout ?? null,
    http_request_timeout: layer === "S" ? listener?.http_request_timeout ?? null : null, http_request_use_threads: listener?.http_request_use_threads ?? null,
    thread_interpretation: { busy_loop: threads.busy_loop, blocking_read: threads.blocking_read, join_wait: threads.join_wait },
    d5_steps: layer === "D5" ? (result?.steps ?? null) : undefined,
  };
}
function caseStatus(def, f) {
  if (def.layer === "probe") return f.returned && f.harness_ok ? "RETURNED" : "INCONCLUSIVE";
  if (def.layer === "D5") return f.returned && f.harness_ok && Array.isArray(f.d5_steps) && f.hb_complete ? "RETURNED" : "INCONCLUSIVE";
  // B1: no request seen at the external fault server -> nothing can be interpreted.
  if (FAULT_MODES.includes(def.server) && !f.server_request_seen) return "INCONCLUSIVE";
  // R1: completion events are trusted only if the listener was ready before the request.
  if (!f.listener_ready_before_request) return "INCONCLUSIVE";
  if (f.hang && f.request_seen && f.hb_complete) return "OBSERVED_HANG";
  if (f.returned && f.harness_ok && f.request_seen && f.hb_complete) return "RETURNED"; // exit_hang is recorded separately
  return "INCONCLUSIVE";
}
function inconclusiveReason(def, f, rec) {
  const r = [];
  if (FAULT_MODES.includes(def.server) && !f.server_request_seen) r.push("request did not reach the external fault server (no connection with this case's request line)");
  if (def.layer !== "D5" && def.layer !== "probe" && !f.listener_ready_before_request) r.push("completion listener not proven ready before the request");
  if (!f.hb_count) r.push("no heartbeat"); else if (!f.hb_complete) r.push("heartbeat lines missing");
  if (def.layer !== "D5" && !f.request_seen) r.push("no request_start event");
  if (!f.returned && !f.hang) r.push(rec.cap_reached ? "hard cap reached without an open heartbeat gap" : "no result line");
  if (f.returned && !f.harness_ok) r.push("harness reported an error");
  return r.join("; ") || "not interpretable";
}

// --- Proposal r2.1 §2.4: STRONGLY SUPPORTED / NOT SUPPORTED / INCONCLUSIVE only.
function judge(cases) {
  const usable = (id) => cases[id] && ["RETURNED", "OBSERVED_HANG"].includes(cases[id].status);
  const f = (id) => cases[id]?.facts ?? {};
  const approx = (x, t) => typeof x === "number" && Math.abs(x - t) <= APPROX_MS;
  const num = (x) => (typeof x === "number" ? x : null);
  const H = {};
  const set = (h, level, reason, extra = {}) => { H[h] = { level, reason, ...extra }; };
  // B1: a heartbeat stall alone never decides a hypothesis. A stall may be
  // interpreted only if this case's request reached the EXTERNAL fault server
  // before the stall began and, in stall mode, the connection was still open
  // with no reply ("connected, no reply") when the stall began.
  const se = (id) => f(id).server_evidence ?? null;
  const stallEvidence = (id) => { const s = se(id); return !!s && f(id).server_request_seen === true && s.request_before_stall === true && s.connection_open_at_stall === true && s.reply_sent === false; };
  const noReplyHeld = (id) => { const s = se(id); return !!s && f(id).server_request_seen === true && s.connection_open_at_observe_end === true && s.reply_sent === false; };
  // D1: H1 / H3 / H5 / H6 use heartbeat stall timing; they accept a case only if
  // its two-clock baseline was OK (MISMATCH or UNKNOWN -> INCONCLUSIVE).
  const hbOk = (id) => f(id).baseline === "OK";
  const hbNote = (ids) => ids.filter((id) => !hbOk(id)).map((id) => `${id} baseline ${f(id).baseline ?? "UNKNOWN"}`).join(", ");
  const evidenceNote = (id) => { const s = se(id); return s ? `server: requests=${s.requests_with_case_url} before_stall=${s.request_before_stall} open_at_stall=${s.connection_open_at_stall} open_at_observe_end=${s.connection_open_at_observe_end} reply_sent=${s.reply_sent}` : "no server evidence"; };
  // H1: the timeout did not fire while connected with no reply.
  if (!usable("D1-R")) set("H1", INC, "D1-R not interpretable");
  else if (!hbOk("D1-R")) set("H1", INC, `heartbeat baseline not reliable: ${hbNote(["D1-R"])}`);
  else {
    const d = f("D1-R"), d2 = f("D2-R"), c2 = (d2.completions ?? [])[0];
    const supporting = usable("D2-R") && c2 ? `D2-R first completion ${c2.is_timeout ? "RESULT_TIMEOUT" : `result ${c2.result}`} at ${c2.rel_ms} ms (non-thread mode only; supporting)` : "D2-R not available";
    const ev = evidenceNote("D1-R");
    if (d.returned && d.post_gaps.length === 0 && d.completions.length === 0 && d.observe_end_reason === "max" && noReplyHeld("D1-R")) set("H1", SS, "D1-R: request at the external stall server, connection open with no reply; heartbeat continued after the timeout with no >=500 ms gap and no completion until the observation window end (just before the hard cap)", { supporting, server: ev });
    else if (approx(d.stall_start_rel_ms, DIAG_TIMEOUT_MS) && stallEvidence("D1-R")) set("H1", NS, `D1-R: request reached the external stall server before the stall; main-thread stall began ${d.stall_start_rel_ms} ms after the request (about the timeout: consistent with the timer firing, then blocking in cancel)`, { supporting, server: ev });
    else set("H1", INC, `D1-R: stall start ${d.stall_start_rel_ms} ms, completions ${d.completions.length}; ${ev}`, { supporting, server: ev });
  }
  // H2: SDK retry / backoff never ends (D2: only direct evidence of a 4th
  // attempt counts; an S-layer case not returning while its R-layer case
  // returns is not by itself evidence about retry / backoff).
  if (!usable("D2-S") || !usable("D3-S")) set("H2", INC, "D2-S or D3-S not interpretable");
  else {
    const d2 = f("D2-S"), d3 = f("D3-S");
    const srv = (d) => d.server_requests ?? 0, starts = (d) => d.attempt_timeline?.starts ?? 0;
    const detail = { server_requests: { "D2-S": srv(d2), "D3-S": srv(d3) }, attempt_starts: { "D2-S": starts(d2), "D3-S": starts(d3) },
      client_completions: { "D2-S": d2.completions.length, "D3-S": d3.completions.length }, sdk_returned: { "D2-S": d2.sdk_returned, "D3-S": d3.sdk_returned } };
    if (srv(d2) > 3 || srv(d3) > 3 || starts(d2) > 3 || starts(d3) > 3) set("H2", SS, "direct evidence of a 4th attempt (requests at the external fault server or attempt starts)", detail);
    else if (d2.sdk_returned && d3.sdk_returned && srv(d2) === 3 && srv(d3) === 3 && d2.completions.length === 3 && d3.completions.length === 3) set("H2", NS, "D2-S and D3-S both returned after exactly 3 requests at the server and 3 client completions", detail);
    else set("H2", INC, "no direct evidence of more than 3 attempts, and no complete 3-attempt return; a missing SDK return alone is not evidence about retry / backoff", detail);
  }
  // H3: the in-process FaultPort stall mode is the cause.
  if (!usable("D1-R") || !usable("D1-S")) set("H3", INC, "D1-R or D1-S not interpretable");
  else if (!hbOk("D1-R") || !hbOk("D1-S")) set("H3", INC, `heartbeat baseline not reliable: ${hbNote(["D1-R", "D1-S"])}`);
  else {
    const stuck = (d) => d.hang || d.long_stall;
    const ev = `D1-R ${evidenceNote("D1-R")}; D1-S ${evidenceNote("D1-S")}`;
    if (!stuck(f("D1-R")) && !stuck(f("D1-S")) && noReplyHeld("D1-R") && noReplyHeld("D1-S")) set("H3", SS, "the EXTERNAL fault server held 'connected, no reply' and neither D1 case stalled (the stall would be specific to the in-process FaultPort)", { server: ev });
    else if ((f("D1-R").hang && stallEvidence("D1-R")) || (f("D1-S").hang && stallEvidence("D1-S"))) set("H3", NS, "the D1 hang reproduced with the external fault server (request reached it before the stall; connection open, no reply)", { server: ev });
    else set("H3", INC, `no interpretable stall with request evidence, or no stall without it; ${ev}`, { server: ev });
  }
  // H4: timeout_sec did not reach the adapter / HTTPRequest (B3: read-backs decide;
  // timing alone never gives STRONGLY SUPPORTED; attempt time is kept apart from backoff).
  if (!usable("D2-S")) set("H4", INC, "D2-S not interpretable");
  else {
    const d = f("D2-S"), a = num(d.adapter_timeout), h = num(d.http_request_timeout), tl = d.attempt_timeline ?? { attempts: [], complete: false };
    const detail = { adapter_timeout_initial: d.adapter_timeout_initial, adapter_timeout: a, http_request_timeout: h, attempt_timeline: tl };
    if (a === null || h === null) set("H4", INC, "timeout read-back incomplete (adapter and/or in-flight HTTPRequest): timing alone is not used", detail);
    else if (Math.abs(a - 2) >= 1e-6) set("H4", SS, "client._adapter.timeout read back is not 2", detail);
    else if (Math.abs(h - a) >= 1e-6) set("H4", SS, "in-flight HTTPRequest.timeout differs from the adapter value", detail);
    else if (!tl.complete || tl.attempts.length !== 3) set("H4", INC, "read-backs are 2, but the attempt timeline is incomplete: attempt time cannot be separated from retry backoff", detail);
    else if (tl.attempts.every((r) => approx(r.duration_ms, DIAG_TIMEOUT_MS))) set("H4", NS, "both read-backs are 2 and each of the 3 D2-S attempts (start -> completion, backoff excluded) took about 2 s", detail);
    else set("H4", INC, "read-backs are 2 but the measured attempt durations (backoff excluded) do not match", detail);
  }
  // H5: the Trade + Hero combination is required.
  if (!usable("D1-S")) set("H5", INC, "D1-S not interpretable");
  else if (!hbOk("D1-S")) set("H5", INC, `heartbeat baseline not reliable: ${hbNote(["D1-S"])}`);
  else if ((f("D1-S").hang || f("D1-S").long_stall) && stallEvidence("D1-S")) set("H5", NS, "a single adapter request (D1-S) already stalls with request evidence: the combination is not a necessary condition", { server: evidenceNote("D1-S") });
  else set("H5", INC, `D1-S did not reproduce a stall with request evidence; Phase B cannot test the combination (no refresh_all() under stall) -> Phase C; ${evidenceNote("D1-S")}`);
  H.H5.never_strongly_supported_in_phase_b = true;
  // H6: with use_threads the cancellation waits for the thread.
  const need = ["D1-R", "D1-S", "D2-R", "D2-S"];
  const extra = {
    max_level: "STRONGLY SUPPORTED (Phase B has no thread-level direct evidence such as a stack trace)",
    d4_r_t_stall_then_recover: !usable("D4-R-T") ? "not available" : !hbOk("D4-R-T") ? `UNKNOWN (${hbNote(["D4-R-T"])})`
      : (f("D4-R-T").stall_then_recover && approx(f("D4-R-T").recover_gap_start_rel_ms, DIAG_TIMEOUT_MS)),
    d1_main_thread_futex_wait: ["D1-R", "D1-S"].map((id) => `${id}: ${f(id).thread_interpretation?.join_wait ?? "UNKNOWN"}`).join("; "),
    server: `D1-R ${evidenceNote("D1-R")}; D1-S ${evidenceNote("D1-S")}`,
  };
  if (!need.every(usable)) set("H6", INC, `not interpretable: ${need.filter((id) => !usable(id)).join(", ")}`, extra);
  else if (!need.every(hbOk)) set("H6", INC, `heartbeat baseline not reliable: ${hbNote(need)}`, extra);
  else {
    const d1 = (id) => f(id).hang && approx(f(id).stall_start_rel_ms, DIAG_TIMEOUT_MS) && stallEvidence(id);
    const r2 = f("D2-R"), s2 = f("D2-S"), c = r2.completions[0];
    const d2rOk = r2.returned && !!c && c.is_timeout && approx(c.rel_ms, DIAG_TIMEOUT_MS) && r2.post_gaps.length === 0;
    const d2sOk = s2.returned && s2.sdk_returned && s2.post_gaps.length === 0;
    const r1 = f("D1-R"), s1 = f("D1-S"), c1 = r1.completions[0];
    if (d1("D1-R") && d1("D1-S") && d2rOk && d2sOk) set("H6", SS, "D1-R and D1-S: request reached the external stall server and the connection stayed open with no reply; the main thread stalled from about the timeout until the hard cap, while D2-R and D2-S (use_threads=false) returned normally", extra);
    else if (!r1.hang && !s1.hang && r1.post_gaps.length === 0 && s1.post_gaps.length === 0 && c1 && approx(c1.rel_ms, DIAG_TIMEOUT_MS) && s1.sdk_returned) set("H6", NS, "D1-R and D1-S returned at about the timeout without a stall", extra);
    else set("H6", INC, `D1-R hang=${r1.hang} D1-S hang=${s1.hang} D2-R normal=${d2rOk} D2-S normal=${d2sOk} (e.g. not specific to use_threads=true)`, extra);
  }
  // D4 (Proposal §2.2, D4 rule): client completions and SDK return decide; server times only align.
  const d4 = {};
  for (const id of ["D4-R-T", "D4-R-F", "D4-S-F"]) {
    const d = f(id);
    d4[id] = usable(id) ? { status: cases[id].status, client_completions: d.completions, sdk_returned: d.sdk_returned ?? null, sdk_exception: d.sdk_exception ?? null,
      late_reply_taken_as_success: d.completions.some((x) => x.is_success) || (d.sdk_returned === true && d.sdk_exception === false),
      stall_then_recover: d.stall_then_recover, recover_gap_start_rel_ms: d.recover_gap_start_rel_ms, attempt_timeline: d.attempt_timeline ?? null,
      server_evidence_aux_only: d.server_evidence } : { status: cases[id]?.status ?? "NOT_RUN" };
  }
  return { levels: [SS, NS, INC], rules: "Proposal r2.1 §2.4 (no CONFIRMED / REFUTED / VERIFIED)", tolerance_ms: APPROX_MS, hypotheses: H, d4_observations: d4, note: DIAG_NOTE };
}

function d5Findings(cases) {
  const out = {};
  for (const id of ["D5-F", "D5-T"]) {
    const c = cases[id];
    if (!c || c.status !== "RETURNED") { out[id] = { status: c?.status ?? "NOT_RUN" }; continue; }
    const steps = c.facts.d5_steps ?? [], by = Object.fromEntries(steps.map((s) => [s.step, s])), findings = [];
    const okAll = steps.length === 6 && steps.every((s) => s.ok === true);
    if (!okAll) findings.push(`not all 6 steps OK (${steps.map((s) => `${s.step}:${s.ok ? "ok" : s.status}`).join(", ")})`);
    const b = by.session_begin, buy = by.buy, r2 = by.trade_read_2, hero = by.hero_read;
    if (b && (b.money !== 10000 || b.goods !== 0)) findings.push(`new account did not start at money 10000 / goods 0 (${b.money} / ${b.goods})`);
    if (b && buy && buy.ok && (buy.money !== b.money - buy.total_value || buy.goods !== b.goods + 1)) findings.push("money / goods after the buy do not match the receipt");
    if (buy && r2 && (r2.money !== buy.money || r2.goods !== buy.goods || r2.trade_revision !== buy.trade_revision)) findings.push("read-back after the buy differs from the buy answer (money / goods / revision)");
    if (hero && hero.ok !== true) findings.push("Hero read not OK");
    out[id] = { status: c.status, all_steps_ok: okAll, consistent: findings.length === 0, findings, elapsed_ms: steps.map((s) => ({ step: s.step, elapsed_ms: s.elapsed_ms })) };
  }
  return out;
}

// --- --diag ---------------------------------------------------------------------
// S2 (GPT Diff Review round 4): one shared Safety guard at every step boundary.
// After any Safety / Isolation FAIL no further ordinary diagnostic, preparation
// or test step starts (SafetyStop). Only the audit, the inventory and the
// evidence finalization still run, and the top result is DIAG_STOPPED_SAFETY.
class SafetyStop extends Error {}
function safetyGate(ev, next) {
  if (ev.safetyProblems.length) throw new SafetyStop(`Safety STOP: not starting ${next} (first safety problem: ${ev.safetyProblems[0]})`);
}
// Wraps the step executor (runBounded in a real run; a fake in A8): the guard
// runs before the step starts and again right after it, so nothing that
// follows a step that raised a Safety FAIL can start.
function makeStep(ev, S, exec) {
  return async (name, cmd, argv, opts) => {
    safetyGate(ev, `step ${name}`);
    const r = await exec(ev, name, cmd, argv, opts); const p = stepProblem(r);
    S.steps.push({ ...r.rec, verdict: p ? "FAIL" : "OK", reason: p }); ev.save(); ev.log(`${p ? "FAIL" : "OK"} ${name}${p ? ` (${p})` : ""}`);
    safetyGate(ev, `anything after step ${name}`);
    return { ...r, problem: p };
  };
}
// Pure: a Safety FAIL (or an unclean final secret scan) always wins; never DIAG_COMPLETE.
function decideTopResult({ safetyCount, precondition, interpretable, auditOk, scanClean }) {
  if (safetyCount > 0 || scanClean === false) return "DIAG_STOPPED_SAFETY";
  if (precondition || !interpretable || !auditOk) return "DIAG_INCOMPLETE";
  return "DIAG_COMPLETE";
}

async function diagnose(ev, args, temp) {
  const S = ev.summary;
  const step = makeStep(ev, S, runBounded);
  const gate = (next) => safetyGate(ev, next);
  const godot = fs.realpathSync(args.godot);
  if (!fs.statSync(godot).isFile()) throw new Precondition("--godot is not a file");
  const head = await step("git-head", "git", ["rev-parse", "HEAD"], { timeoutMs: TIMEOUT_MS.short });
  if (head.problem) throw new Precondition("git rev-parse failed");
  S.source_sha = head.output.trim();
  const before = await step("git-status-before", "git", ["status", "--porcelain"], { timeoutMs: TIMEOUT_MS.short });
  if (before.problem || before.output.trim()) throw new Precondition("checkout is not clean before the run");
  gate("work root creation");
  const state = createRoot(ev, args.runId, temp);
  const uname = await step("uname", "uname", ["-a"], { timeoutMs: TIMEOUT_MS.short });
  ev.file("environment.txt", [`source_sha=${S.source_sha}`, `source_ref=${process.env.GITHUB_REF ?? ""}`, `run_id=${args.runId}`,
    `runner_os=${process.env.RUNNER_OS ?? ""}`, `node=${process.version}`, `platform=${os.platform()} ${os.release()}`, `uname=${uname.output.trim()}`, ""].join("\n"));
  const dv = await step("docker-version", "docker", ["version"], { timeoutMs: TIMEOUT_MS.docker });
  const dcv = await step("docker-compose-version", "docker", ["compose", "version"], { timeoutMs: TIMEOUT_MS.docker });
  const iso = isolationProblem(state);
  if (iso) ev.safety(`isolation: ${iso}`);
  const gv = await step("godot-version", godot, ["--version"], { env: godotEnv(state), timeoutMs: TIMEOUT_MS.godotVersion, expectedExe: godot });
  if (gv.problem || !gv.output.split("\n").some((l) => l.trim().startsWith(EXPECTED_GODOT))) throw new Precondition(`Godot version is not ${EXPECTED_GODOT}`);
  S.docker = { version_ok: !dv.problem, compose_version_ok: !dcv.problem };
  const recheck = (next) => { const p = rootProblem(state); if (p) ev.safety(`work root: ${p}`); gate(next); };
  recheck("godot-import");
  const imp = await step("godot-import", godot, ["--headless", "--path", GODOT_DIR, "--import"], { env: godotEnv(state), timeoutMs: TIMEOUT_MS.godotImport, expectedExe: godot });
  if (imp.problem || !fs.existsSync(path.join(GODOT_DIR, ".godot", "global_script_class_cache.cfg"))) throw new Precondition("Godot import failed");
  recheck("probe");
  const pt0 = nowMs();
  const probe = await runCase(ev, state, { id: "probe", layer: "probe", threads: false, server: "none" }, { godot, env: godotEnv(state), t0: pt0 });
  S.probe = { status: probe.result ? "RETURNED" : "INCONCLUSIVE", result: probe.result, exit_code: probe.exit_code };
  ev.save();
  gate("anything after the probe");
  const pr = probe.result ?? {};
  if (!probe.result || pr.harness_ok !== true) throw new Precondition("probe did not return");
  if (!inside(state.root, pr.user_data_dir) || !inside(state.root, pr.globalized_user)) ev.safety("user:// is outside the run root");
  gate("the D1-D4 cases");
  if (!String(pr.godot_version ?? "").startsWith(EXPECTED_GODOT)) throw new Precondition("probe reports a different Godot version");
  ev.log("probe: user:// is inside the run root");
  // D1-D4: external fault server per case.
  for (const def of CASES.filter((c) => c.layer !== "D5")) {
    recheck(`case ${def.id}`);
    const t0 = nowMs();
    let server;
    try { server = await startFaultServer(def.server, t0); } catch (e) { S.cases[def.id] = { status: "INCONCLUSIVE", reason: `fault server: ${e.code ?? e}` }; ev.save(); continue; }
    ev.log(`case ${def.id}: fault server ${def.server} on ${server.host}:${server.port}`);
    const rec = await runCase(ev, state, def, { godot, port: server.port, server, env: godotEnv(state), t0 });
    S.cases[def.id] = rec; ev.save();
    gate(`anything after case ${def.id}`);
  }
  // D5: disposable Nakama + PostgreSQL (Proposal §6).
  recheck("the D5 preparation");
  const d5Skip = (why) => { for (const def of CASES.filter((c) => c.layer === "D5")) S.cases[def.id] = { status: "INCONCLUSIVE", reason: `D5 environment: ${why}` }; ev.save(); ev.log(`D5 INCONCLUSIVE: ${why}`); };
  const nodeEnv = { ...process.env, TMPDIR: path.join(state.root, "tmp") };
  const ci = await step("nakama-npm-ci", "npm", ["ci"], { cwd: NAKAMA_DIR, env: nodeEnv, timeoutMs: TIMEOUT_MS.npmCi });
  if (ci.problem) return d5Skip("npm ci failed");
  const unit = await step("nakama-build-and-unit-tests", "npm", ["test"], { cwd: NAKAMA_DIR, env: nodeEnv, timeoutMs: TIMEOUT_MS.nakamaTest });
  S.steps[S.steps.length - 1].ci_kind = "Nakama build + unit (Node), not Godot";
  if (unit.problem) return d5Skip("Nakama build / unit tests failed");
  const clean = await step("git-status-after-build", "git", ["status", "--porcelain"], { timeoutMs: TIMEOUT_MS.short });
  if (clean.problem || clean.output.trim()) return d5Skip("checkout changed after the build");
  gate("the Nakama port check");
  if (await respondsNow()) return d5Skip(`port ${NAKAMA_PORT} is already in use`);
  gate("compose up");
  state.compose_started = true; ev.state(state);
  const up = await step("compose-up", "docker", ["compose", "-p", state.compose_project, "-f", COMPOSE_FILE, "up", "-d", "postgres", "nakama"], { cwd: NAKAMA_DIR, timeoutMs: TIMEOUT_MS.composeUp });
  if (up.problem) return d5Skip("compose up failed");
  gate("the Nakama health check");
  const h0 = Date.now(), ok = await healthy(TIMEOUT_MS.health);
  S.steps.push({ name: "nakama-healthy", verdict: ok ? "OK" : "FAIL", duration_ms: Date.now() - h0 }); ev.save();
  if (!ok) return d5Skip("Nakama not healthy");
  gate("the D5 cases");
  state.secrets_generated = true; ev.state(state);
  const tag = args.runId.replace(/_/g, "-");
  for (const def of CASES.filter((c) => c.layer === "D5")) {
    recheck(`case ${def.id}`);
    const account = { email: `${tag}-${def.id.toLowerCase().replace(/-/g, "")}@wp01g.invalid`, password: crypto.randomBytes(24).toString("base64url") };
    ev.secrets.push(account.password);
    const rec = await runCase(ev, state, def, { godot, port: NAKAMA_PORT, env: godotEnv(state, { MYRIAL_WP01G_EMAIL: account.email, MYRIAL_WP01G_PASSWORD: account.password }), t0: nowMs() });
    S.cases[def.id] = rec; ev.save();
    gate(`anything after case ${def.id}`);
  }
}

async function audit(ev) {
  const r = await runBounded(ev, "git-status-after", "git", ["status", "--porcelain"], { timeoutMs: TIMEOUT_MS.short });
  const p = stepProblem(r) || (r.output.trim() ? "checkout changed" : "");
  const groups = ev.pgids.map((pgid) => { const s = survivorsOf(pgid); return { pgid, members: s.readable ? s.list.map((x) => x.pid) : "unknown" }; });
  const survivors = groups.filter((g) => g.members === "unknown" || g.members.length);
  if (survivors.length) ev.safety(`process groups of this run still have members at the end (${survivors.map((g) => g.pgid).join(",")}); never signalled; inventory in summary`);
  return { git_status_after: p ? `FAIL (${p})` : "clean", process_groups: groups.length, survivor_groups: survivors, ok: !p && survivors.length === 0 };
}

function secretScanAll(ev) {
  const { files, anomalies } = scanDir(ev.args.evidenceDir, ev.args.evidenceId, ev.temp);
  const hitsByRule = {}, filesWithHits = [];
  for (const name of files) {
    const x = readSafe(ev.args.evidenceDir, name, ev.args.evidenceId, ev.temp);
    const h = scanText(x.data.toString("utf8"), ev.secrets);
    if (Object.keys(h).length) { filesWithHits.push({ name, rules: Object.keys(h).sort() }); for (const [k, n] of Object.entries(h)) hitsByRule[k] = (hitsByRule[k] ?? 0) + n; }
  }
  const streamTotal = Object.values(ev.streamHits).reduce((a, b) => a + b, 0);
  return { rules: RULE_IDS, s1_secrets_known: ev.secrets.length, files_scanned: files.length, anomalies: anomalies.length,
    file_hits_by_rule: hitsByRule, files_with_hits: filesWithHits, stream_hits_by_rule: { ...ev.streamHits },
    clean: filesWithHits.length === 0 && streamTotal === 0 && anomalies.length === 0, scanned_at: new Date().toISOString() };
}

function printJudgement(ev, j, cases) {
  ev.log("== case status (Linux GitHub runner only) ==");
  for (const c of CASES) ev.log(`  ${c.id.padEnd(7)} ${cases[c.id]?.status ?? "NOT_RUN"}${cases[c.id]?.reason ? ` (${cases[c.id].reason})` : ""}`);
  ev.log("== H1-H6 (Proposal r2.1 §2.4; STRONGLY SUPPORTED is the highest level) ==");
  for (const [h, x] of Object.entries(j.hypotheses)) ev.log(`  ${h}: ${x.level} - ${x.reason}`);
}

// --- --inventory-only ---------------------------------------------------------------
async function inventory(ev, args, temp) {
  const report = { mode: "inventory only; nothing deleted", compose: "not started", root: "not created", process_groups: [], complete: true };
  const state = readJson(args.evidenceDir, STATE_FILE, args.evidenceId, temp, true);
  if (!state) { report.root = "no run state"; ev.log("leftover inventory: no run state"); return report; }
  if (state.run_id !== args.runId) throw new Error("run state belongs to another run");
  if (state.compose_started) {
    const project = state.compose_project;
    if (project !== args.runId || !RUN_ID_RE.test(project)) throw new Error("Compose project differs");
    const ps = await runBounded(ev, "inventory-compose-containers", "docker", ["ps", "-a", "--filter", `label=com.docker.compose.project=${project}`, "--format", "{{.Names}} {{.Status}}"], { timeoutMs: TIMEOUT_MS.short });
    const vs = await runBounded(ev, "inventory-compose-volumes", "docker", ["volume", "ls", "--filter", `label=com.docker.compose.project=${project}`, "--format", "{{.Name}}"], { timeoutMs: TIMEOUT_MS.short });
    if ([ps, vs].some((x) => stepProblem(x))) throw new Error("Docker inventory incomplete");
    const n = (x) => x.output.split("\n").filter((y) => y.trim()).length;
    report.compose = `PRESERVED: ${project}, ${n(ps)} container(s), ${n(vs)} volume(s)`;
  }
  for (const pgid of Array.isArray(state.pgids) ? state.pgids : []) {
    const s = survivorsOf(pgid);
    report.process_groups.push({ pgid, members: s.readable ? s.list.map((x) => x.pid) : "unknown" });
  }
  if (report.process_groups.some((g) => g.members === "unknown")) report.complete = false;
  const p = rootProblem(state);
  if (p && p !== "absent") throw new Error(`work root: ${p}`);
  report.root = p === "absent" ? "absent" : `PRESERVED: ${state.root}`;
  ev.log(`leftover inventory: compose=${report.compose}; root=${report.root}; process groups with members=${report.process_groups.filter((g) => g.members === "unknown" || g.members.length).length}`);
  return report;
}

// --- --finalize / --verify-manifest -------------------------------------------------
function finalize(args, temp) {
  const first = scanDir(args.evidenceDir, args.evidenceId, temp);
  const firstNames = new Set([...first.files, ...first.anomalies.map((x) => x.name)]);
  if (firstNames.has("final-audit.json") || firstNames.has("manifest.json")) throw Object.assign(new SafetyError("unsafe/pre-existing final evidence target"), { exitCode: 7 });
  const anomalies = [...first.anomalies];
  const readInput = (name) => {
    try { return readJson(args.evidenceDir, name, args.evidenceId, temp, true); }
    catch (e) { if (e instanceof SafetyError) throw e; anomalies.push({ name, type: currentFileType(args.evidenceDir, name), reason: `safe-read-failed: ${e.code ?? e.message ?? e}` }); return null; }
  };
  const summary = readInput("summary.json"), inv = readInput("leftover-inventory.json"), scanned = readInput("secret-scan.json"), state = readInput(STATE_FILE);
  // Re-scan every file with S2-S5 (the S1 password is known only inside --diag).
  const rescan = {}, rescanFiles = [];
  for (const name of first.files) {
    let x; try { x = readSafe(args.evidenceDir, name, args.evidenceId, temp); } catch (e) { if (e instanceof SafetyError) throw e; anomalies.push({ name, type: currentFileType(args.evidenceDir, name), reason: `rescan-read-failed: ${e.code ?? e}` }); continue; }
    const h = scanText(x.data.toString("utf8"), [], ["S2", "S3", "S4", "S5"]);
    if (Object.keys(h).length) { rescanFiles.push({ name, rules: Object.keys(h).sort() }); for (const [k, n] of Object.entries(h)) rescan[k] = (rescan[k] ?? 0) + n; }
  }
  const secretsGenerated = state?.secrets_generated === true;
  const diagScanClean = scanned ? scanned.clean === true : !secretsGenerated;
  const rescanClean = rescanFiles.length === 0;
  const dio = process.env.WP01G_DIAG_OUTCOME ?? "", io = process.env.WP01G_INVENTORY_OUTCOME ?? "";
  let f = new Leaf(args.evidenceDir, "final-audit.json", args.evidenceId, temp);
  const last = scanDir(args.evidenceDir, args.evidenceId, temp);
  for (const a of last.anomalies) if (!anomalies.some((x) => x.name === a.name && x.type === a.type && x.reason === a.reason)) anomalies.push(a);
  if (last.files.includes("manifest.json") || last.anomalies.some((x) => x.name === "manifest.json")) { f.close(); throw Object.assign(new SafetyError("unsafe manifest target"), { exitCode: 7 }); }
  const files = [];
  for (const name of last.files) {
    if (name === "final-audit.json") continue;
    try { const x = readSafe(args.evidenceDir, name, args.evidenceId, temp); files.push({ name, size: Number(x.size), sha256: crypto.createHash("sha256").update(x.data).digest("hex") }); }
    catch (e) { if (e instanceof SafetyError) { f.close(); throw e; } anomalies.push({ name, type: currentFileType(args.evidenceDir, name), reason: `manifest-read-failed: ${e.code ?? e.message ?? e}` }); }
  }
  const checks = { diag_outcome_valid: OUTCOMES.has(dio), inventory_outcome_valid: OUTCOMES.has(io), summary_present: !!summary,
    top_result_valid: TOP.includes(summary?.top_result), diag_secret_scan_clean: diagScanClean, finalize_rescan_clean: rescanClean,
    inventory_complete: inv?.complete === true, no_anomalies: anomalies.length === 0 };
  const uploadSafe = diagScanClean && rescanClean && anomalies.length === 0;
  try {
    f.once(JSON.stringify({ run_id: args.runId, note: DIAG_NOTE, diag_outcome: dio, inventory_outcome: io, top_result: summary?.top_result ?? "MISSING",
      secret_scan: { diag_scan_present: !!scanned, secrets_generated: secretsGenerated, finalize_rescan_rules: ["S2", "S3", "S4", "S5"], finalize_rescan_hits_by_rule: rescan, finalize_rescan_files_with_hits: rescanFiles },
      checks, anomalies, upload_safe: uploadSafe, finalized_at: new Date().toISOString() }, null, 2) + "\n");
  } finally { f.close(); }
  const fa = readSafe(args.evidenceDir, "final-audit.json", args.evidenceId, temp);
  files.push({ name: "final-audit.json", size: Number(fa.size), sha256: crypto.createHash("sha256").update(fa.data).digest("hex") });
  files.sort((a, b) => a.name.localeCompare(b.name));
  f = new Leaf(args.evidenceDir, "manifest.json", args.evidenceId, temp); try { f.once(JSON.stringify({ run_id: args.runId, evidence_id: args.evidenceId, files, anomalies }, null, 2) + "\n"); } finally { f.close(); }
  console.log(`final audit: top_result=${summary?.top_result ?? "MISSING"} upload_safe=${uploadSafe}; manifest ${files.length} files; anomalies ${anomalies.length}`);
  return uploadSafe ? 0 : 7;
}

function verifyManifest(args, temp) {
  const s = scanDir(args.evidenceDir, args.evidenceId, temp); if (s.anomalies.length) return 7;
  let m, fa;
  try { m = readJson(args.evidenceDir, "manifest.json", args.evidenceId, temp); fa = readJson(args.evidenceDir, "final-audit.json", args.evidenceId, temp); }
  catch (e) { console.error(`verify: ${e.message ?? e}`); return e instanceof SafetyError ? 7 : 6; }
  if (!Array.isArray(m.files) || !Array.isArray(m.anomalies) || m.anomalies.length) return 6;
  if (!s.files.includes("manifest.json")) return 6;
  const ordinary = s.files.filter((name) => name !== "manifest.json");
  const names = m.files.map((x) => x.name); if (new Set(names).size !== names.length || JSON.stringify([...names].sort()) !== JSON.stringify(ordinary)) return 6;
  for (const e of m.files) { const x = readSafe(args.evidenceDir, e.name, args.evidenceId, temp), hash = crypto.createHash("sha256").update(x.data).digest("hex"); if (Number(x.size) !== e.size || hash !== e.sha256) return 6; }
  if (fa?.upload_safe !== true) { console.log("manifest verified, but final audit says upload is NOT safe"); return 7; }
  verifyDir(args.evidenceDir, args.evidenceId, temp); console.log(`manifest verified: ${names.length} files; upload safe`); return 0;
}

// --- --selftest (A8): synthetic data only, in memory, no file is created ---------
async function selftest() {
  const realKill = process.kill;
  let killCalls = 0;
  process.kill = () => { killCalls++; throw new Error("selftest: process.kill is trapped"); };
  try { return await selftestBody(() => killCalls); } finally { process.kill = realKill; }
}

async function selftestBody(killCalls) {
  let failures = 0, n = 0;
  const t = (name, cond) => { n++; if (cond) console.log(`ok   - ${name}`); else { failures++; console.log(`FAILED: ${name}`); } };
  const pw = "Zx9-fakePassword_ForSelfTest_1234567890";
  const jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJ1aWQiOiJmYWtlLXVzZXIifQ.ZmFrZS1zaWduYXR1cmUtZm9yLXRlc3Q";
  const total = (h) => Object.values(h).reduce((a, b) => a + b, 0);
  // Header names only: must PASS (no hit).
  for (const [label, text] of [
    ["header name array (compact JSON)", JSON.stringify({ header_names: ["Host", "Authorization", "Content-Type"] })],
    ["header name array (pretty JSON)", JSON.stringify({ header_names: ["Host", "Authorization", "Content-Type"] }, null, 2)],
    ["header name in prose", "fault server recorded header names: Host, Authorization, Content-Type"],
    ["header name followed by a word", "Authorization header name recorded"],
    ["English 'basic' is not a credential", "basic connectivity check passed"],
    ["English 'bearer' is not a credential", "bearer authentication scheme in use"],
  ]) t(`no false positive: ${label}`, total(scanText(text, [pw])) === 0);
  // Values: must be found AND redacted.
  for (const [label, text, rule, leak] of [
    ["Authorization: Basic <value>", "Authorization: Basic ZGVmYXVsdGtleTo=", "S3", "ZGVmYXVsdGtleTo"],
    ["JSON \"Authorization\": \"<value>\"", "{\"Authorization\": \"Bearer abc.def.ghi1234\"}", "S3", "abc.def"],
    ["Bearer <token>", "sent with Bearer 3f9a7c2e1b8d4a6f0e", "S4", "3f9a7c2e1b8d4a6f0e"],
    ["Basic <base64>", "header value Basic ZGVmYXVsdGtleTo=", "S5", "ZGVmYXVsdGtleTo"],
    ["fake JWT", `EV {"note":"${jwt}"}`, "S2", "eyJhbGci"],
    ["fake password", `login with ${pw} now`, "S1", pw],
  ]) {
    const r = redactText(text, [pw]);
    t(`detected: ${label} (${rule})`, (r.hits[rule] ?? 0) > 0);
    t(`redacted: ${label}`, !r.text.includes(leak));
    t(`redacted output has no further hit: ${label}`, total(scanText(r.text, [pw])) === 0);
  }
  // A JWT split across two chunks is still redacted (whole-line assembly).
  const got = []; const sp = new LineSplitter((line) => got.push(redactText(line, [pw])));
  const split = `EV {"tok":"${jwt}"}\n`, cut = 25;
  sp.push(Buffer.from(split.slice(0, cut))); sp.push(Buffer.from(split.slice(cut))); sp.end();
  t("split-chunk JWT: one line assembled", got.length === 1);
  t("split-chunk JWT: detected (S2)", (got[0]?.hits.S2 ?? 0) > 0);
  t("split-chunk JWT: redacted", got.length === 1 && !got[0].text.includes("eyJhbGci"));
  const pwLines = []; const sp2 = new LineSplitter((line) => pwLines.push(redactText(line, [pw])));
  sp2.push(Buffer.from(`x ${pw.slice(0, 10)}`)); sp2.push(Buffer.from(`${pw.slice(10)} y`)); sp2.end();
  t("split-chunk password in a final partial line: redacted", pwLines.length === 1 && (pwLines[0].hits.S1 ?? 0) === 1 && !pwLines[0].text.includes(pw));
  const utf = []; const sp3 = new LineSplitter((line) => utf.push(line)); const zh = Buffer.from("中文測試\n");
  sp3.push(zh.subarray(0, 4)); sp3.push(zh.subarray(4)); sp3.end();
  t("multi-byte UTF-8 split across chunks decodes intact", utf.length === 1 && utf[0] === "中文測試");
  const big = []; const sp4 = new LineSplitter((line, partial) => big.push({ line, partial }), 64);
  sp4.push(Buffer.from("A".repeat(100))); sp4.push(Buffer.from("B".repeat(10) + "\nnext\n")); sp4.end();
  t("over-long line: content dropped, placeholder kept", big.length === 2 && big[0].line.startsWith("[WP01G_LINE_TOO_LONG") && !big[0].line.includes("AAAA") && big[1].line === "next");
  // Gap computation (Proposal r2.1 §4.1 ①).
  const hbs = []; let seq = 0, ticks = 1000, recv = 50;
  const add = (dt, dr = dt, skip = 0) => { seq += 1 + skip; ticks += dt; recv += dr; hbs.push({ seq, ticks, recv }); };
  hbs.push({ seq, ticks, recv }); for (let i = 0; i < 8; i++) add(250);
  add(1000); for (let i = 0; i < 4; i++) add(250);
  add(600); for (let i = 0; i < 4; i++) add(250);
  add(250, 250, 1); add(250);
  add(499); add(500);
  add(250, 700);
  const g = computeGaps(hbs, { endRecv: hbs[hbs.length - 1].recv + 2000 });
  const closed = g.gaps.filter((x) => !x.open), open = g.gaps.filter((x) => x.open);
  t("gap: 1 s gap recorded (Godot and runner clocks)", closed.some((x) => x.godot_ms === 1000 && x.runner_ms === 1000 && x.source === "both"));
  t("gap: 600 ms gap recorded", closed.some((x) => x.godot_ms === 600));
  t("gap: 499 ms not recorded, 500 ms recorded", !closed.some((x) => x.godot_ms === 499) && closed.some((x) => x.godot_ms === 500));
  t("gap: runner-only gap (stdout buffering) flagged as runner", closed.some((x) => x.source === "runner" && x.godot_ms === 250 && x.runner_ms === 700));
  t("gap: missing heartbeat line recorded", g.missing.length === 1);
  t("gap: open gap at termination recorded", open.length === 1 && open[0].runner_ms === 2000 && open[0].godot_ms === null);
  t("gap: exactly 5 gaps (1000, 600, 500, runner 700, open 2000)", g.gaps.length === 5);
  t("gap: max Godot gap 1000 ms", g.max_godot_gap_ms === 1000);
  const base = hbs.slice(0, 9);
  t("baseline: matching clocks OK", baselineCheck(base, base[8].ticks + 1).status === "OK");
  t("baseline: 150 ms clock mismatch flagged", baselineCheck(base.map((h, i) => ({ ...h, recv: h.recv + (i === 5 ? 150 : 0) })), base[8].ticks + 1).status === "MISMATCH");
  t("baseline: fewer than 4 heartbeats UNKNOWN", baselineCheck(base.slice(0, 3), base[8].ticks).status === "UNKNOWN");
  // Gap <-> client event correlation (B2): nearest event before / after, UNKNOWN when none.
  const evs = [
    { n: 1, e: "request_start", t: 900, layer: "R" }, { n: 2, e: "logger_assert", t: 950 },
    { n: 3, e: "inside_gap", t: 1500 }, { n: 4, e: "completion", t: 2000, result: 13, is_timeout: true }, { n: 5, e: "late", t: 2600 },
  ];
  const cg = correlateGaps([
    { start_ticks: 1000, end_ticks: 2000, open: false },
    { start_ticks: 500, end_ticks: 800, open: false },
    { start_ticks: 2700, end_ticks: null, open: true },
    { start_ticks: 2650, end_ticks: 3200, open: false },
  ], evs);
  t("correlation: event before = nearest at or before the gap start (#2, -50 ms)", cg[0].client_event_before.n === 2 && cg[0].client_event_before.delta_ms === -50);
  t("correlation: event after = nearest at or after the gap end (#4, 0 ms, ids kept)", cg[0].client_event_after.n === 4 && cg[0].client_event_after.delta_ms === 0 && cg[0].client_event_after.id.result === 13 && cg[0].client_event_after.id.is_timeout === true);
  t("correlation: events inside the gap listed (#3)", cg[0].client_events_inside.length === 1 && cg[0].client_events_inside[0].n === 3);
  t("correlation: no event before -> UNKNOWN", cg[1].client_event_before === "UNKNOWN" && cg[1].client_event_after.n === 1);
  t("correlation: open gap -> event after UNKNOWN", cg[2].client_event_before.n === 5 && cg[2].client_event_after === "UNKNOWN");
  t("correlation: no event after the gap end -> UNKNOWN", cg[3].client_event_before.n === 5 && cg[3].client_event_after === "UNKNOWN");
  t("correlation: works on computeGaps output", correlateGaps(g.gaps, [{ n: 1, e: "x", t: 0 }]).every((x) => x.client_event_before !== undefined && x.client_event_after !== undefined));

  // S1 (rounds 2-3): leader identity and the REAL termination decision flow
  // (terminateFlow / checkSurvivors) with fake effects: no /proc read and no
  // signal. process.kill is trapped for the whole selftest (checked at the end).
  const me = 1001;
  const leaderId = { pid: 4242, pgid: 4242, sid: 4242, starttime: "5000", exe: "/opt/godot/Godot", exe_source: "exe", uid: me, euid: me };
  const leaderProc = { pid: 4242, exited: false, identity: leaderId, expectedExe: "/opt/godot/Godot" };
  const live = { pid: 4242, pgrp: 4242, sid: 4242, starttime: "5000", exe: "/opt/godot/Godot", cmd0: "/opt/godot/Godot", uid: me, euid: me };
  t("S1 leader: fully matching live leader is proven", leaderVerdict(leaderProc, live, me) === "");
  for (const [label, proc, cur] of [
    ["exited (reaped) leader", { ...leaderProc, exited: true }, live],
    ["identity never captured", { ...leaderProc, identity: null }, live],
    ["recorded exe is not the verified Godot binary", { ...leaderProc, identity: { ...leaderId, exe: "/usr/bin/other" } }, { ...live, exe: "/usr/bin/other" }],
    ["/proc unreadable", leaderProc, null],
    ["process group differs", leaderProc, { ...live, pgrp: 1 }],
    ["session differs", leaderProc, { ...live, sid: 1 }],
    ["start time differs (pid reused)", leaderProc, { ...live, starttime: "9999" }],
    ["executable differs", leaderProc, { ...live, exe: "/usr/bin/sleep" }],
    ["real uid differs", leaderProc, { ...live, uid: 0 }],
    ["effective uid differs", leaderProc, { ...live, euid: 0 }],
  ]) t(`S1 leader refused: ${label}`, leaderVerdict(proc, cur, me) !== "");
  for (const [label, pid] of [["negative pid (a whole process group)", -4242], ["pid 0 (own process group)", 0], ["pid -1 (every process)", -1],
    ["pid 1 (init)", 1], ["non-integer pid", 4242.5], ["NaN", Number.NaN], ["another pid (not the leader)", 4300]]) t(`S1 signal target refused: ${label}`, signalTargetProblem(pid, 4242) !== "");
  t("S1 signal target: only the leader pid itself is accepted", signalTargetProblem(4242, 4242) === "");
  const flow = async ({ proc = {}, reads = [live], exitAfter = null, throwOn = null } = {}) => {
    const p = { name: "case-T", pid: 4242, exited: false, identity: { ...leaderId }, expectedExe: "/opt/godot/Godot", signals: [], ...proc };
    const sent = [], safety = [];
    let n = 0;
    const io = { me, now: () => 0, safety: (m) => safety.push(m),
      identity: () => reads[Math.min(n++, reads.length - 1)],
      signal: (pid, sig) => {
        const problem = signalTargetProblem(pid, p.pid);
        if (problem) throw new SafetyError(problem);
        if (throwOn === sig) throw Object.assign(new Error("no such process"), { code: "ESRCH" });
        sent.push({ pid, sig });
      },
      waitExit: async () => { if (exitAfter !== null && sent.length >= exitAfter) { p.exited = true; return true; } return false; } };
    await terminateFlow(p, "selftest", io);
    return { sent, safety, p };
  };
  const a = await flow({ exitAfter: 1 });
  t("S1 flow: proven leader, exits after SIGTERM -> exactly one SIGTERM to the leader pid", a.sent.length === 1 && a.sent[0].sig === "SIGTERM" && a.sent[0].pid === 4242 && a.safety.length === 0);
  const b = await flow({ exitAfter: 2 });
  t("S1 flow: leader ignores SIGTERM -> SIGTERM then SIGKILL, both to the leader pid", b.sent.map((x) => x.sig).join(",") === "SIGTERM,SIGKILL" && b.sent.every((x) => x.pid === 4242));
  t("S1 flow: every signal target is the positive leader pid (never a group)", [...a.sent, ...b.sent].every((x) => x.pid === 4242 && x.pid > 1));
  const c = await flow({ proc: { identity: null } });
  t("S1 flow: identity not captured -> no signal, Safety", c.sent.length === 0 && c.safety.length === 1);
  const d = await flow({ proc: { exited: true } });
  t("S1 flow: leader already reaped -> no signal", d.sent.length === 0);
  const e = await flow({ reads: [live, { ...live, starttime: "9999" }] });
  t("S1 flow: pid reused between SIGTERM and SIGKILL -> no SIGKILL, Safety", e.sent.length === 1 && e.sent[0].sig === "SIGTERM" && e.safety.length === 1 && e.p.signals.some((x) => x.sig === "SIGKILL" && x.sent === false));
  for (const [label, cur] of [["executable differs", { ...live, exe: "/usr/bin/sleep" }], ["uid differs", { ...live, uid: 0 }],
    ["process group differs", { ...live, pgrp: 9 }], ["session differs", { ...live, sid: 9 }], ["/proc unreadable", null]]) {
    const r = await flow({ reads: [cur] });
    t(`S1 flow: ${label} -> no signal at all, Safety`, r.sent.length === 0 && r.safety.length === 1);
  }
  const gerr = await flow({ throwOn: "SIGTERM" });
  t("S1 flow: signal error -> flow stops, no further signal", gerr.sent.length === 0 && gerr.p.signals.length === 1 && gerr.p.signals[0].sent === false);
  const survIo = (group) => { const io = { safety: (m) => io.msgs.push(m), msgs: [], signals: 0, signal: () => { io.signals++; }, scanGroup: () => group }; return io; };
  const s1 = { pid: 4300, pgrp: 4242, sid: 4242, starttime: "5100", uid: me, euid: me, state: "S", exe: "/usr/bin/node", comm: "node" };
  const k = survIo({ readable: true, list: [s1, { ...s1, pid: 4301 }] }), kr = checkSurvivors({ name: "x", pid: 4242, exited: true }, k);
  t("S1 survivors: 2 survivors -> inventory of both, Safety, NOT signalled", kr.survivors.length === 2 && kr.inventory.length === 2 && kr.inventory.every((x) => x.reason.includes("never signalled")) && k.msgs.length === 1 && k.signals === 0);
  const l = survIo({ readable: false, list: [] }), lr = checkSurvivors({ name: "x", pid: 4242, exited: true }, l);
  t("S1 survivors: /proc unreadable -> unknown, Safety, no signal", lr.survivors === "unknown" && l.msgs.length === 1 && l.signals === 0);
  const m2 = survIo({ readable: true, list: [{ ...s1, pid: 4242 }] }), mr = checkSurvivors({ name: "x", pid: 4242, exited: false }, m2);
  t("S1 survivors: leader still running -> inventory, Safety, no signal", mr.leader_running === true && mr.inventory.length === 1 && m2.msgs.length === 1 && m2.signals === 0);
  const o = survIo({ readable: true, list: [] }), or = checkSurvivors({ name: "x", pid: 4242, exited: true }, o);
  t("S1 survivors: none -> no Safety", Array.isArray(or.survivors) && or.survivors.length === 0 && o.msgs.length === 0);
  const rec = (x) => ({ rec: { error: undefined, timed_out: false, close_wait_expired: false, exit_code: 0, ...x } });
  t("S1 not normal completion: survivors remain -> step problem", stepProblem(rec({ survivors_remaining: [4300] })) === "process survivors remain");
  t("S1 not normal completion: survivors unknown -> step problem", stepProblem(rec({ survivors_remaining: "unknown" })) === "process survivors remain");
  t("S1 normal completion only with no survivors and exit 0", stepProblem(rec({ survivors_remaining: [] })) === "");

  // D1 / D2 (round 2): judgement guards. Synthetic case facts only.
  const fact = (o = {}) => ({ returned: true, harness_ok: true, hang: false, baseline: "OK", post_gaps: [], completions: [], stall_start_rel_ms: null,
    long_stall: false, stall_then_recover: false, recover_gap_start_rel_ms: null, observe_end_reason: "settled", sdk_returned: false, sdk_exception: null,
    server_request_seen: true, server_requests: 1, attempt_timeline: null, adapter_timeout: null, http_request_timeout: null, adapter_timeout_initial: null,
    server_evidence: { requests_with_case_url: 1, request_before_stall: null, connection_open_at_stall: null, connection_open_at_observe_end: null, reply_sent: false },
    thread_interpretation: { busy_loop: "UNKNOWN", blocking_read: "UNKNOWN", join_wait: "UNKNOWN" }, ...o });
  const hangFact = (o = {}) => fact({ returned: false, hang: true, stall_start_rel_ms: 1900, post_gaps: [{ start_rel_ms: 1900, duration_ms: 58000, open: true }],
    server_evidence: { requests_with_case_url: 1, request_before_stall: true, connection_open_at_stall: true, connection_open_at_observe_end: null, reply_sent: false }, ...o });
  const comp = { rel_ms: 2000, is_timeout: true, result: 13, is_success: false };
  const tl3 = { attempts: [1, 2, 3].map((i) => ({ attempt: i, duration_ms: 2000, backoff_before_ms: i === 1 ? null : 5 })), starts: 3, completions: 3, complete: true };
  const scenario = (edit = {}) => {
    const c = {
      "D1-R": { status: "OBSERVED_HANG", facts: hangFact() }, "D1-S": { status: "OBSERVED_HANG", facts: hangFact() },
      "D2-R": { status: "RETURNED", facts: fact({ completions: [{ ...comp, rel_ms: 2010 }] }) },
      "D2-S": { status: "RETURNED", facts: fact({ sdk_returned: true, sdk_exception: true, server_requests: 3, completions: [comp, comp, comp], attempt_timeline: tl3, adapter_timeout: 2, http_request_timeout: 2 }) },
      "D3-R": { status: "RETURNED", facts: fact({ completions: [{ ...comp, is_timeout: false, result: 4, rel_ms: 15 }] }) },
      "D3-S": { status: "RETURNED", facts: fact({ sdk_returned: true, sdk_exception: true, server_requests: 3, completions: [comp, comp, comp], attempt_timeline: { ...tl3, starts: 1, complete: false } }) },
    };
    for (const [id, o] of Object.entries(edit)) c[id] = { ...c[id], ...(o.status ? { status: o.status } : {}), facts: { ...c[id].facts, ...(o.facts ?? {}) } };
    return judge(c).hypotheses;
  };
  const levelsOnly = (h) => Object.values(h).every((x) => [SS, NS, INC].includes(x.level));
  const ref = scenario();
  t("judge reference: H6 SS, H1 NS, H3 NS, H5 NS, H2 NS, H4 NS; only 3 levels", ref.H6.level === SS && ref.H1.level === NS && ref.H3.level === NS && ref.H5.level === NS && ref.H2.level === NS && ref.H4.level === NS && levelsOnly(ref));
  const mis = scenario({ "D1-R": { facts: { baseline: "MISMATCH" } } });
  t("D1: D1-R baseline MISMATCH -> H1, H3, H6 INCONCLUSIVE", mis.H1.level === INC && mis.H3.level === INC && mis.H6.level === INC);
  t("D1: D1-R baseline MISMATCH does not change H5 (D1-S) or H2 / H4", mis.H5.level === NS && mis.H2.level === NS && mis.H4.level === NS);
  const unk = scenario({ "D1-R": { facts: { baseline: "UNKNOWN" } } });
  t("D1: D1-R baseline UNKNOWN -> H1 and H6 INCONCLUSIVE", unk.H1.level === INC && unk.H6.level === INC);
  t("D1: D2-R baseline UNKNOWN -> H6 INCONCLUSIVE", scenario({ "D2-R": { facts: { baseline: "UNKNOWN" } } }).H6.level === INC);
  t("D1: D2-S baseline MISMATCH -> H6 INCONCLUSIVE", scenario({ "D2-S": { facts: { baseline: "MISMATCH" } } }).H6.level === INC);
  t("D1: D1-S baseline MISMATCH -> H5 and H3 INCONCLUSIVE", (() => { const h = scenario({ "D1-S": { facts: { baseline: "MISMATCH" } } }); return h.H5.level === INC && h.H3.level === INC; })());
  t("B1 kept: request not before the stall -> H1 and H6 INCONCLUSIVE", (() => { const h = scenario({ "D1-R": { facts: { server_evidence: { ...hangFact().server_evidence, request_before_stall: false } } } }); return h.H1.level === INC && h.H6.level === INC; })());
  const noRet = scenario({ "D2-S": { facts: { sdk_returned: false, sdk_exception: null } } });
  t("D2: S layer not returned while R layer returned, 3 attempts -> H2 INCONCLUSIVE (not SS)", noRet.H2.level === INC);
  t("D2: 4 requests at the external server -> H2 SS", scenario({ "D2-S": { facts: { server_requests: 4 } } }).H2.level === SS);
  t("D2: 4 attempt starts -> H2 SS", scenario({ "D3-S": { facts: { attempt_timeline: { ...tl3, starts: 4 } } } }).H2.level === SS);
  t("D2: 4 client completions but 3 server requests / 3 starts -> not SS", scenario({ "D2-S": { facts: { completions: [comp, comp, comp, comp] } } }).H2.level !== SS);
  t("D2: D3-S returned after only 2 server requests -> H2 INCONCLUSIVE", scenario({ "D3-S": { facts: { server_requests: 2 } } }).H2.level === INC);
  t("B3 kept: H4 read-back missing -> INCONCLUSIVE even with bad timing", scenario({ "D2-S": { facts: { http_request_timeout: null, attempt_timeline: { ...tl3, attempts: tl3.attempts.map((x) => ({ ...x, duration_ms: 5000 })) } } } }).H4.level === INC);
  // S2 (round 4): Safety guard at the shared step boundary. Fake step executor
  // only (no process is started; process.kill stays trapped).
  const fakeEv = () => ({ safetyProblems: [], logs: [], log(m) { this.logs.push(m); }, save() {} });
  const okRun = { rec: { name: "x", exit_code: 0, timed_out: false, close_wait_expired: false, survivors_remaining: [] }, output: "" };
  {
    const ev1 = fakeEv(), st1 = { steps: [] }, calls = [];
    const step = makeStep(ev1, st1, async (_ev, name) => { calls.push(name); return okRun; });
    await step("a"); await step("b");
    t("S2: no Safety FAIL -> every step runs", calls.join(",") === "a,b" && st1.steps.length === 2);
  }
  {
    const ev2 = fakeEv(), st2 = { steps: [] }, calls = [];
    const step = makeStep(ev2, st2, async (_ev, name) => { calls.push(name); if (name === "b") _ev.safetyProblems.push("synthetic Safety FAIL in b"); return okRun; });
    let stopped = null;
    try { for (const name of ["a", "b", "c", "d"]) await step(name); } catch (e) { stopped = e; }
    t("S2: Safety FAIL during step b -> SafetyStop raised right after b", stopped instanceof SafetyStop && stopped.message.includes("after step b"));
    t("S2: the steps after the failing step (c, d) are never called", calls.join(",") === "a,b");
    t("S2: the failing step's own record is kept for the evidence", st2.steps.length === 2);
  }
  {
    const ev3 = fakeEv(), calls = [];
    ev3.safetyProblems.push("earlier Safety FAIL (for example isolation)");
    const step = makeStep(ev3, { steps: [] }, async (_ev, name) => { calls.push(name); return okRun; });
    let thrown = null;
    try { await step("next"); } catch (e) { thrown = e; }
    t("S2: Safety FAIL already present -> the next step is not started", thrown instanceof SafetyStop && calls.length === 0);
  }
  {
    const ev4 = fakeEv(), calls = [];
    const step = makeStep(ev4, { steps: [] }, async (_ev, name) => { calls.push(name); if (name === "a") _ev.safetyProblems.push("synthetic"); return okRun; });
    let thrown = null;
    try { await step("a"); calls.push("work between steps (for example createRoot or a case)"); await step("b"); } catch (e) { thrown = e; }
    t("S2: code between steps after a Safety FAIL never runs", thrown instanceof SafetyStop && calls.join("|") === "a");
  }
  t("S2: safetyGate lets work continue only while there is no Safety FAIL", (() => { try { safetyGate(fakeEv(), "x"); return true; } catch { return false; } })()
    && (() => { const e = fakeEv(); e.safetyProblems.push("y"); try { safetyGate(e, "x"); return false; } catch (err) { return err instanceof SafetyStop; } })());
  const base5 = { safetyCount: 0, precondition: "", interpretable: true, auditOk: true, scanClean: true };
  for (const [label, input, want] of [
    ["Safety FAIL with everything else fine -> STOPPED_SAFETY, never COMPLETE", { ...base5, safetyCount: 1 }, "DIAG_STOPPED_SAFETY"],
    ["Safety FAIL plus precondition / incomplete cases -> STOPPED_SAFETY", { safetyCount: 2, precondition: "x", interpretable: false, auditOk: false, scanClean: true }, "DIAG_STOPPED_SAFETY"],
    ["Safety FAIL before the final scan (scan not yet run) -> STOPPED_SAFETY", { ...base5, safetyCount: 1, scanClean: null }, "DIAG_STOPPED_SAFETY"],
    ["final secret scan not clean -> STOPPED_SAFETY", { ...base5, scanClean: false }, "DIAG_STOPPED_SAFETY"],
    ["precondition only -> INCOMPLETE", { ...base5, precondition: "x" }, "DIAG_INCOMPLETE"],
    ["a case not interpretable -> INCOMPLETE", { ...base5, interpretable: false }, "DIAG_INCOMPLETE"],
    ["audit not OK -> INCOMPLETE", { ...base5, auditOk: false }, "DIAG_INCOMPLETE"],
    ["nothing wrong -> COMPLETE", base5, "DIAG_COMPLETE"],
  ]) t(`S2 top result: ${label}`, decideTopResult(input) === want);
  t("no real signal was sent during the selftest (process.kill trapped: 0 calls)", killCalls() === 0);
  console.log(failures ? `selftest FAILED: ${failures} of ${n}` : `selftest passed: ${n} checks`);
  return failures ? 1 : 0;
}

// --- main ---------------------------------------------------------------------------
async function main() {
  const argv = process.argv.slice(2); let args;
  try { args = parseArgs(argv); } catch (e) { console.error(String(e.message ?? e)); return 2; }
  if (args.mode === "selftest") return await selftest();
  let temp; try { temp = requireDisposableRunner(); } catch (e) { console.error(String(e.message ?? e)); return 3; }
  try { verifyDir(args.evidenceDir, args.evidenceId, temp); } catch (e) { console.error(`evidence directory refused: ${e.message ?? e}`); return 3; }
  if (args.mode === "verify-manifest") { try { return verifyManifest(args, temp); } catch (e) { console.error(`verify failed: ${e.message ?? e}`); return e instanceof SafetyError ? 7 : 6; } }
  if (args.mode === "finalize") { try { return finalize(args, temp); } catch (e) { console.error(`finalize failed: ${e.message ?? e}`); return e instanceof SafetyError ? 7 : e.exitCode ?? 5; } }
  let ev; try { ev = new Evidence(args, temp, args.mode === "inventory-only"); } catch (e) { console.error(`evidence open failed: ${e.message ?? e}`); return 7; }
  if (args.mode === "inventory-only") {
    try { const r = await inventory(ev, args, temp); ev.json("leftover-inventory.json", r); ev.close(); return r.complete ? 0 : 4; }
    catch (e) { try { ev.log(`leftover inventory error: ${e.message ?? e}`); } catch {} ev.close(); return e instanceof SafetyError ? 7 : 4; }
  }
  const S = ev.summary;
  ev.log(`WP01-G Phase B diagnostic run ${args.runId} (node ${process.version}, ${os.platform()} ${os.release()}). ${DIAG_NOTE}`);
  let precondition = "", safetyStop = "";
  try { await diagnose(ev, args, temp); }
  catch (e) {
    if (e instanceof SafetyError) { console.error(`evidence safety failure: ${e.message}`); ev.close(); return 7; }
    if (e instanceof SafetyStop) { safetyStop = e.message; try { ev.log(safetyStop); } catch { ev.close(); return 7; } }
    else {
      precondition = e instanceof Precondition ? e.message : `runner error: ${e?.stack ?? e}`;
      try { ev.log(`STOP (precondition / runner error): ${precondition}`); } catch { ev.close(); return 7; }
    }
  }
  try {
    for (const c of CASES) if (!S.cases[c.id]) S.cases[c.id] = { status: "NOT_RUN" };
    S.audit = await audit(ev);
    if (!S.audit.ok) ev.log(`audit: ${JSON.stringify(S.audit)}`);
    const j = judge(S.cases); S.d5 = d5Findings(S.cases);
    ev.json("judgement.json", { ...j, case_status: Object.fromEntries(CASES.map((c) => [c.id, S.cases[c.id]?.status ?? "NOT_RUN"])), d5: S.d5 });
    printJudgement(ev, j, S.cases);
    const interpretable = CASES.every((c) => ["RETURNED", "OBSERVED_HANG"].includes(S.cases[c.id]?.status));
    S.precondition_failure = precondition || null;
    S.safety_stop = safetyStop || null;
    const decide = (scanClean) => decideTopResult({ safetyCount: ev.safetyProblems.length, precondition, interpretable, auditOk: S.audit.ok, scanClean });
    S.top_result = decide(null);
    S.safety_problems = [...ev.safetyProblems];
    S.finished_at = new Date().toISOString(); ev.save();
    const scan = secretScanAll(ev); ev.json("secret-scan.json", scan);
    if (!scan.clean) ev.safety("final secret scan is not clean");
    S.top_result = decide(scan.clean); S.safety_problems = [...ev.safetyProblems];
    S.secret_scan_clean = scan.clean; ev.save();
    ev.log(`WP01-G Phase B diagnostic: ${S.top_result} (diagnostic only; not acceptance)`);
  } catch (e) { console.error(`audit/evidence failure: ${e.message ?? e}`); ev.close(); return 7; }
  ev.close();
  return S.top_result === "DIAG_COMPLETE" ? 0 : S.top_result === "DIAG_STOPPED_SAFETY" ? 7 : 1;
}

process.exitCode = await main();
