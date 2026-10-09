// Loads the compiled Nakama module (build/index.js) into an isolated VM
// context, exactly as one global script like Nakama does, and provides an
// in-memory Nakama double with Nakama's storage version semantics.
import { readFileSync } from "node:fs";
import { createContext, runInContext } from "node:vm";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";

const BUILD = fileURLToPath(new URL("../../build/index.js", import.meta.url));

// `clock` (optional): { now() } replacing Date.now inside the module.
export function loadModule(clock) {
  const FakeDate = clock ? { now: () => clock.now() } : Date;
  const context = createContext({ JSON, Math, Object, String, Date: FakeDate, parseInt, isFinite });
  runInContext(readFileSync(BUILD, "utf8"), context, { filename: "index.js" });
  return context;
}

export const fixtures = JSON.parse(
  readFileSync(fileURLToPath(new URL("../fixtures/rules_vectors.json", import.meta.url)), "utf8"),
);

// Nakama v3.25.0 error texts (server/runtime_javascript_nakama.go wraps
// runtime.ErrStorageRejectedVersion from nakama-common runtime/runtime.go).
export const VERSION_CONFLICT = "Storage write rejected - version check failed.";
const WRITE_PREFIX = "failed to write storage objects: ";
const MULTI_PREFIX = "error running multi update: ";
export const DB_FAULT = "ERROR: wp01 injected storage fault (SQLSTATE P0001)";

// Storage double: version "*" = create only; any other version must match.
// multiUpdate is all-or-nothing. `failNextWrites` injects lost races into
// batches that touch progress / receipts; `failNextRateWrites` into rate-limit
// writes; `beforeWrite` / `beforeRateWrite` run a competing writer first.
// `faultNextWrites` / `faultNextRateWrites` inject NON-conflict database
// errors. `writeCalls` counts write attempts per API.
export class FakeNakama {
  constructor() {
    this.objects = new Map();
    this.cache = new Map();
    this.versionCounter = 0;
    this.failNextWrites = 0;
    this.failNextRateWrites = 0;
    this.beforeWrite = null; // hook to simulate a concurrent writer
    this.beforeRateWrite = null;
    this.rateWrites = 0;
    this.faultNextWrites = 0;
    this.faultNextRateWrites = 0;
    this.writeCalls = { storageWrite: 0, multiUpdate: 0 };
  }
  id(o) { return `${o.collection}/${o.key}/${o.userId}`; }
  storageRead(ids) {
    const out = [];
    for (const i of ids) {
      const o = this.objects.get(this.id(i));
      if (o) out.push(JSON.parse(JSON.stringify(o)));
    }
    return out;
  }
  _check(w, prefix) {
    const existing = this.objects.get(this.id(w));
    if (w.version === "*" && existing) throw new Error(prefix + VERSION_CONFLICT);
    if (w.version && w.version !== "*" && (!existing || existing.version !== w.version)) throw new Error(prefix + VERSION_CONFLICT);
  }
  _apply(w) {
    this.versionCounter += 1;
    this.objects.set(this.id(w), {
      collection: w.collection, key: w.key, userId: w.userId,
      value: JSON.parse(JSON.stringify(w.value)), version: `v${this.versionCounter}`,
      permissionRead: w.permissionRead ?? 1, permissionWrite: w.permissionWrite ?? 1,
    });
  }
  storageWrite(writes) {
    this.writeCalls.storageWrite += 1;
    this._maybeInterfere(writes, WRITE_PREFIX);
    writes.forEach((w) => this._check(w, WRITE_PREFIX));
    writes.forEach((w) => this._apply(w));
  }
  multiUpdate(_accounts, writes, _deletes, _wallets) {
    this.writeCalls.multiUpdate += 1;
    this._maybeInterfere(writes, MULTI_PREFIX);
    writes.forEach((w) => this._check(w, MULTI_PREFIX));
    writes.forEach((w) => this._apply(w));
    return { storageWriteAcks: [], walletUpdateAcks: [] };
  }
  _maybeInterfere(writes, prefix) {
    if (writes.some((w) => w.collection === "vs01_wp01_rate_limits")) {
      this.rateWrites += 1;
      if (this.beforeRateWrite) { const f = this.beforeRateWrite; this.beforeRateWrite = null; f(this); }
      if (this.faultNextRateWrites > 0) { this.faultNextRateWrites -= 1; throw new Error(prefix + DB_FAULT); }
      if (this.failNextRateWrites > 0) { this.failNextRateWrites -= 1; throw new Error(prefix + VERSION_CONFLICT); }
      return;
    }
    if (this.beforeWrite) { const f = this.beforeWrite; this.beforeWrite = null; f(this); }
    if (this.faultNextWrites > 0) { this.faultNextWrites -= 1; throw new Error(prefix + DB_FAULT); }
    if (this.failNextWrites > 0) { this.failNextWrites -= 1; throw new Error(prefix + VERSION_CONFLICT); }
  }
  uuidv4() { return randomUUID(); }
  localcacheGet(k) { return this.cache.get(k); }
  localcachePut(k, v) { this.cache.set(k, v); }
}

export const logger = { info() {}, warn() {}, error() {}, debug() {} };

export function ctxFor(userId, env = {}) {
  return { userId, env };
}

// Calls an RPC and returns {ok, value} or {ok:false, code, message}.
export function call(mod, fn, nk, ctx, payload) {
  try {
    return { ok: true, value: JSON.parse(mod[fn](ctx, logger, nk, typeof payload === "string" ? payload : JSON.stringify(payload))) };
  } catch (e) {
    if (e && typeof e === "object" && "code" in e) return { ok: false, code: e.code, message: e.message };
    throw e;
  }
}
