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

// Storage double: version "*" = create only; any other version must match.
// multiUpdate is all-or-nothing. `failNextWrites` injects lost races into
// batches that touch progress / receipts; `failNextRateWrites` into rate-limit
// writes; `beforeWrite` / `beforeRateWrite` run a competing writer first.
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
  _check(w) {
    const existing = this.objects.get(this.id(w));
    if (w.version === "*" && existing) throw new Error("version conflict (exists)");
    if (w.version && w.version !== "*" && (!existing || existing.version !== w.version)) throw new Error("version conflict");
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
    this._maybeInterfere(writes);
    writes.forEach((w) => this._check(w));
    writes.forEach((w) => this._apply(w));
  }
  multiUpdate(_accounts, writes, _deletes, _wallets) {
    this._maybeInterfere(writes);
    writes.forEach((w) => this._check(w));
    writes.forEach((w) => this._apply(w));
    return { storageWriteAcks: [], walletUpdateAcks: [] };
  }
  _maybeInterfere(writes) {
    if (writes.some((w) => w.collection === "vs01_wp01_rate_limits")) {
      this.rateWrites += 1;
      if (this.beforeRateWrite) { const f = this.beforeRateWrite; this.beforeRateWrite = null; f(this); }
      if (this.failNextRateWrites > 0) { this.failNextRateWrites -= 1; throw new Error("injected rate conflict"); }
      return;
    }
    if (this.beforeWrite) { const f = this.beforeWrite; this.beforeWrite = null; f(this); }
    if (this.failNextWrites > 0) { this.failNextWrites -= 1; throw new Error("injected conflict"); }
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
