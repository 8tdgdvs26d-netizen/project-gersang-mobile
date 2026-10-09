// VS-01 WP01 LIVE: server restart mid-session. Confirmed progress and
// receipts survive; an uncertain command retried after the restart resolves
// to its single original outcome. Restarts the LOCAL nakama container only.
import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { authEmail, rpc, begin, order, progress, sleep, BASE } from "./live_client.mjs";

const COMPOSE_DIR = fileURLToPath(new URL("../..", import.meta.url));
const DOCKER = process.env.DOCKER ?? "docker";

async function waitHealthy() {
  for (let i = 0; i < 60; i++) {
    try {
      if ((await fetch(`${BASE}/healthcheck`)).ok) return;
    } catch { /* still restarting */ }
    await sleep(1000);
  }
  throw new Error("nakama did not come back");
}

test("server restart: confirmed state persists, retries stay exactly-once", async () => {
  const a = await authEmail("restart");
  const g = await begin(a);
  const applied = order(g, { quantity: 10 });
  assert.equal((await rpc(a, "vs01_trade", applied)).body.receipt.status, "applied");
  const uncertain = order(g, { good_id: "test_good_02" });
  // Fire and restart immediately: the client does not know if it landed.
  const inFlight = rpc(a, "vs01_trade", uncertain).catch(() => null);
  execFileSync(DOCKER, ["compose", "restart", "nakama"], { cwd: COMPOSE_DIR, stdio: "ignore" });
  await inFlight;
  await waitHealthy();

  const after = await progress(a);
  assert.equal(after.backpack.test_good_01, 10, "confirmed buy survived the restart");
  const replay = await rpc(a, "vs01_trade", applied);
  assert.equal(replay.body.replayed, true, "pre-restart key still replays");
  const retry = await rpc(a, "vs01_trade", uncertain);
  assert.equal(retry.status, 200);
  const final = await progress(a);
  assert.equal(final.backpack.test_good_02, 1, "the uncertain order applied exactly once");
  assert.equal(final.money, 10000 - 840 - retry.body.receipt.total);
  // The gameplay session also survives; no forced death / reset on reconnect.
  assert.equal((await rpc(a, "vs01_trade", order(g))).status, 200);
});
