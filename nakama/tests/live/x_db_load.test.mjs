// A14 cost evidence: extra PostgreSQL work of the storage-backed limiter,
// measured from pg_stat_user_tables on the local stack's `storage` table.
import test from "node:test";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { authEmail, rpc, begin, order, sleep } from "./live_client.mjs";

const COMPOSE_DIR = fileURLToPath(new URL("../..", import.meta.url));
const DOCKER = process.env.DOCKER ?? "docker";

function stats() {
  const out = execFileSync(DOCKER, ["compose", "exec", "-T", "postgres", "psql", "-U", "postgres", "-d", "nakama", "-tAc",
    "select n_tup_ins, n_tup_upd, idx_scan, seq_scan from pg_stat_user_tables where relname = 'storage'"], { cwd: COMPOSE_DIR }).toString().trim();
  const [ins, upd, idx, seq] = out.split("|").map(Number);
  return { ins, upd, scans: idx + seq };
}

// PostgreSQL publishes table statistics late: an idle pooled connection can
// hold its counters up to 10 s (PGSTAT_IDLE_INTERVAL), so wait 12 s on both
// sides of each measurement.
// PostgreSQL publishes table statistics late: an idle pooled connection can
// hold its counters up to 10 s (PGSTAT_IDLE_INTERVAL), so wait 12 s on both
// sides of each measurement. Throttled requests must stay inside one rate
// window, so their cost is taken as (accepted + throttled) - (accepted only).
async function measure(fn) {
  await sleep(12000);
  const before = stats();
  const statuses = await fn();
  await sleep(12000);
  const after = stats();
  return { statuses, ins: after.ins - before.ins, upd: after.upd - before.upd, scans: after.scans - before.scans };
}

const count = (statuses, code) => statuses.filter((s) => s === code).length;
const per = (v, n) => (v / n).toFixed(2);

async function sequential(account, gsid, n) {
  const out = [];
  for (let i = 0; i < n; i++) out.push((await rpc(account, "vs01_trade", order(gsid))).status);
  return out;
}

test("database load of the rate limiter (evidence only)", async (t) => {
  const a = await authEmail("dbload-a");
  const ga = await begin(a);
  const accepted = await measure(() => sequential(a, ga, 30));
  t.diagnostic(`db load, 30 sequential trades (${count(accepted.statuses, 200)} accepted): storage inserts ${accepted.ins}, updates ${accepted.upd}, scans ${accepted.scans} -> per accepted trade ins ${per(accepted.ins, 30)}, upd ${per(accepted.upd, 30)}, scans ${per(accepted.scans, 30)}`);

  const b = await authEmail("dbload-b");
  const gb = await begin(b);
  const mixed = await measure(() => sequential(b, gb, 230));
  const throttled = count(mixed.statuses, 429);
  t.diagnostic(`db load, 230 sequential requests (${count(mixed.statuses, 200)} accepted, ${throttled} throttled, same window): storage inserts ${mixed.ins}, updates ${mixed.upd}, scans ${mixed.scans}`);
  t.diagnostic(`db load per THROTTLED request: ins ${per(mixed.ins - accepted.ins, throttled)}, upd ${per(mixed.upd - accepted.upd, throttled)}, scans ${per(mixed.scans - accepted.scans, throttled)}`);

  const c = await authEmail("dbload-c");
  const gc = await begin(c);
  const conc = await measure(() => Promise.all(Array.from({ length: 30 }, () => rpc(c, "vs01_trade", order(gc)).then((r) => r.status))));
  t.diagnostic(`db load, 30 CONCURRENT trades on one account (${count(conc.statuses, 200)} accepted): storage inserts ${conc.ins} (includes create-only attempts that lost the race), updates ${conc.upd}, scans ${conc.scans} -> per request ins ${per(conc.ins, 30)}, upd ${per(conc.upd, 30)}, scans ${per(conc.scans, 30)}`);
});
