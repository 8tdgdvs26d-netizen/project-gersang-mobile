// Review findings 2 + 3, LIVE: a storage write that fails for a reason other
// than a version conflict must fail fast (HTTP 503 storage_unavailable), with
// ONE attempt, no retry storm, and no partial state; the same key retried
// after recovery applies exactly once. The fault is a PostgreSQL trigger on
// the LOCAL disposable database, enabled per collection through a database
// setting and removed afterwards. A sequence counts write attempts (sequences
// are not rolled back with the failed transaction).
import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { authEmail, rpc, begin, order, progress, sleep, BASE } from "./live_client.mjs";

const COMPOSE_DIR = fileURLToPath(new URL("../..", import.meta.url));
const DOCKER = process.env.DOCKER ?? "docker";
const sql = (q) => execFileSync(DOCKER, ["compose", "exec", "-T", "postgres", "psql", "-U", "postgres", "-d", "nakama", "-v", "ON_ERROR_STOP=1", "-tAc", q], { cwd: COMPOSE_DIR }).toString().trim();

async function restartNodes() {
  execFileSync(DOCKER, ["compose", "restart", "nakama"], { cwd: COMPOSE_DIR, stdio: "ignore" });
  for (let i = 0; i < 60; i++) {
    try { if ((await fetch(`${BASE}/healthcheck`)).ok) return; } catch { /* restarting */ }
    await sleep(1000);
  }
  throw new Error("nakama did not come back");
}

async function withFault(collection, fn) {
  sql(`ALTER DATABASE nakama SET wp01.fault_collection = '${collection}'`);
  await restartNodes(); // fresh pooled connections read the setting
  try {
    return await fn();
  } finally {
    sql("ALTER DATABASE nakama RESET wp01.fault_collection");
    await restartNodes();
  }
}

test("non-conflict storage write errors fail fast and never apply twice", async (t) => {
  sql("CREATE SEQUENCE IF NOT EXISTS wp01_fault_attempts");
  sql(`CREATE OR REPLACE FUNCTION wp01_fault() RETURNS trigger LANGUAGE plpgsql AS $$
       BEGIN
         IF NEW.collection = current_setting('wp01.fault_collection', true) THEN
           PERFORM nextval('wp01_fault_attempts');
           RAISE EXCEPTION 'wp01 injected storage fault';
         END IF;
         RETURN NEW;
       END $$`);
  sql("DROP TRIGGER IF EXISTS wp01_fault ON storage");
  sql("CREATE TRIGGER wp01_fault BEFORE INSERT OR UPDATE ON storage FOR EACH ROW EXECUTE FUNCTION wp01_fault()");
  // A fresh sequence reports last_value 1 before its first nextval; is_called tells them apart.
  const attempts = () => Number(sql("SELECT CASE WHEN is_called THEN last_value ELSE 0 END FROM wp01_fault_attempts"));
  try {
    const a = await authEmail("fault");
    const g = await begin(a);
    await rpc(a, "vs01_trade", order(g)); // creates the rate-limit row, so later writes are UPDATEs

    // Rate limiter storageWrite (finding 2).
    await withFault("vs01_wp01_rate_limits", async () => {
      const before = attempts();
      const t0 = Date.now();
      const r = await rpc(a, "vs01_trade", order(g));
      t.diagnostic(`rate-limit write fault: HTTP ${r.status} "${r.body.message}" in ${Date.now() - t0} ms, ${attempts() - before} write attempt(s)`);
      assert.equal(r.status, 503);
      assert.equal(r.body.message, "storage_unavailable");
      assert.equal(attempts() - before, 1, "one attempt, no retries");
    });

    // Trade multiUpdate (finding 3), then recovery with the same key.
    const key = order(g, { quantity: 10 });
    const moneyBefore = (await progress(a)).money;
    await withFault("vs01_wp01_receipts", async () => {
      const before = attempts();
      const t0 = Date.now();
      const r = await rpc(a, "vs01_trade", key);
      t.diagnostic(`trade multiUpdate fault: HTTP ${r.status} "${r.body.message}" in ${Date.now() - t0} ms, ${attempts() - before} write attempt(s)`);
      assert.equal(r.status, 503);
      assert.equal(r.body.message, "storage_unavailable");
      assert.equal(attempts() - before, 1, "one attempt, no retries");
    });
    assert.equal((await progress(a)).money, moneyBefore, "nothing applied while storage failed");
    const retry = await rpc(a, "vs01_trade", key);
    assert.equal(retry.status, 200);
    assert.equal(retry.body.replayed, false);
    assert.equal(retry.body.receipt.status, "applied");
    const again = await rpc(a, "vs01_trade", key);
    assert.equal(again.body.replayed, true);
    assert.equal((await progress(a)).money, moneyBefore - retry.body.receipt.total, "applied exactly once");
  } finally {
    sql("DROP TRIGGER IF EXISTS wp01_fault ON storage");
    sql("DROP FUNCTION IF EXISTS wp01_fault()");
    sql("DROP SEQUENCE IF EXISTS wp01_fault_attempts");
    sql("ALTER DATABASE nakama RESET wp01.fault_collection");
  }
});
