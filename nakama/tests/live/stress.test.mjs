// VS-01 WP01 LIVE stress against the local Nakama server (docker compose).
// Run: nakama/scripts/run_live_tests.sh (or `npm run test:live` with the
// server up). Every account is a fresh local email test account.
import test from "node:test";
import assert from "node:assert/strict";
import { loadModule } from "../unit/harness.mjs";
import { authEmail, authRaw, rpc, api, begin, order, progress, receipts, newKey, sleep } from "./live_client.mjs";

const m = loadModule();

// Re-derives an account's state from its receipts with the TypeScript rules
// (same order, same server times) and checks the receipt chain is gap-free.
function checkLedger(all, final) {
  const applied = all.filter((r) => r.status === "applied").sort((a, b) => a.progress_revision - b.progress_revision);
  const p = m.progressCreateDefault();
  let lastRevision = 0;
  for (const r of applied) {
    assert.ok(r.progress_revision > lastRevision, "revisions strictly increase (no double apply)");
    lastRevision = r.progress_revision;
    assert.equal(r.money_before, p.money, `receipt ${r.idempotency_key} starts where the previous ended`);
    m.progressAdvanceRecovery(p, r.server_time_ms);
    const d = m.tradeDecide(p, { action: r.action, city_id: r.city_id, good_id: r.good_id, quantity: r.quantity });
    assert.equal(d.status, "applied", `replayed order ${r.idempotency_key} is valid`);
    assert.equal(d.unit_price, r.unit_price, `server price for ${r.idempotency_key} matches the rules`);
    assert.equal(p.money, r.money_after);
  }
  assert.equal(final.money, p.money, "final money equals the receipt ledger");
  // JSON round-trip: the VM sandbox's objects have another realm's prototype.
  assert.deepEqual(final.backpack, JSON.parse(JSON.stringify(p.backpack)), "final backpack equals the receipt ledger");
  return applied.length;
}

test("20 concurrent distinct orders: all decided, none lost, none doubled", async () => {
  const a = await authEmail("conc");
  const g = await begin(a);
  const results = await Promise.all(Array.from({ length: 20 }, (_, i) =>
    rpc(a, "vs01_trade", order(g, { good_id: i % 2 ? "test_good_01" : "test_good_02" }))));
  for (const r of results) assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(results.filter((r) => r.body.receipt.status === "applied").length, 20);
  const final = await progress(a);
  assert.equal(checkLedger(await receipts(a), final), 20);
  assert.equal(final.backpack.test_good_01 + final.backpack.test_good_02, 20);
});

test("same idempotency key sent 20 times at once applies exactly once", async () => {
  const a = await authEmail("samekey");
  const g = await begin(a);
  const payload = order(g, { quantity: 10 });
  const results = await Promise.all(Array.from({ length: 20 }, () => rpc(a, "vs01_trade", payload)));
  for (const r of results) assert.equal(r.status, 200, JSON.stringify(r.body));
  assert.equal(results.filter((r) => r.body.replayed === false).length, 1, "one original");
  assert.equal(results.filter((r) => r.body.replayed === true).length, 19, "nineteen replays");
  const first = results.find((r) => !r.body.replayed).body.receipt;
  for (const r of results) assert.deepEqual(r.body.receipt, first);
  const final = await progress(a);
  assert.equal(final.money, 9160);
  assert.equal(final.backpack.test_good_01, 10);
  assert.equal(checkLedger(await receipts(a), final), 1);
});

test("racing gameplay-session takeovers leave exactly one writer", async () => {
  const a = await authEmail("takeover");
  const sessions = (await Promise.all(Array.from({ length: 8 }, () => rpc(a, "vs01_session_begin", {}))))
    .filter((r) => r.status === 200).map((r) => r.body.gameplay_session_id);
  assert.ok(sessions.length >= 1);
  const results = await Promise.all(sessions.map((g) => rpc(a, "vs01_trade", order(g))));
  const writers = results.filter((r) => r.status === 200);
  assert.equal(writers.length, 1, `exactly one live session: ${results.map((r) => r.status)}`);
  for (const r of results.filter((x) => x.status !== 200)) assert.equal(r.body.message, "gameplay_session_superseded");
  assert.equal(checkLedger(await receipts(a), await progress(a)), 1);
});

test("10 accounts trading in parallel stay isolated and consistent", async () => {
  const accounts = await Promise.all(Array.from({ length: 10 }, (_, i) => authEmail(`multi${i}`)));
  await Promise.all(accounts.map(async (a, i) => {
    const g = await begin(a);
    for (let round = 0; round < 3; round++) {
      await Promise.all(Array.from({ length: 4 }, (_, j) =>
        rpc(a, "vs01_trade", order(g, { quantity: 1, good_id: `test_good_0${1 + ((i + j) % 3)}` }))));
      await rpc(a, "vs01_trade", order(g, { action: "sell", city_id: "B", good_id: `test_good_0${1 + (i % 3)}`, quantity: 1 }));
    }
  }));
  for (const a of accounts) {
    const final = await progress(a);
    const n = checkLedger(await receipts(a), final);
    assert.ok(n >= 12, `account ${a.email} applied ${n}`);
  }
});

test("mixed workload with duplicate retries (300 commands, 5 accounts)", async () => {
  const accounts = await Promise.all(Array.from({ length: 5 }, (_, i) => authEmail(`soak${i}`)));
  const goods = ["test_good_01", "test_good_02", "test_good_03", "test_good_04"];
  let replays = 0;
  await Promise.all(accounts.map(async (a, i) => {
    const g = await begin(a);
    let seed = 1000 + i;
    const rnd = () => (seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648;
    const sent = [];
    for (let n = 0; n < 60; n++) {
      let payload;
      if (sent.length && rnd() < 0.2) payload = sent[Math.floor(rnd() * sent.length)]; // duplicate retry
      else {
        payload = order(g, {
          action: rnd() < 0.55 ? "buy" : "sell", city_id: rnd() < 0.5 ? "A" : "B",
          good_id: goods[Math.floor(rnd() * goods.length)], quantity: rnd() < 0.7 ? 1 : 10,
        });
        sent.push(payload);
      }
      const r = await rpc(a, "vs01_trade", payload);
      assert.equal(r.status, 200, JSON.stringify(r.body));
      if (r.body.replayed) replays += 1;
      if (n % 20 === 19) await sleep(10500); // stay under the per-user rate limit (30 per 10 s)
    }
    const final = await progress(a);
    const all = await receipts(a);
    assert.equal(all.length, sent.length, "one receipt per distinct key");
    checkLedger(all, final);
  }));
  assert.ok(replays > 0, "the workload exercised duplicate retries");
});

test("client-side abort after send: retry with the same key resolves to one outcome", async () => {
  const a = await authEmail("abort");
  const g = await begin(a);
  const payloads = Array.from({ length: 10 }, () => order(g));
  // Abort each request almost immediately; some reach the server, some not.
  await Promise.all(payloads.map(async (p) => {
    const controller = new AbortController();
    const pending = rpc(a, "vs01_trade", p, { signal: controller.signal }).catch(() => null);
    setTimeout(() => controller.abort(), Math.floor(Math.random() * 6));
    await pending;
  }));
  await sleep(500);
  for (const p of payloads) {
    const r = await rpc(a, "vs01_trade", p);
    assert.equal(r.status, 200);
    assert.equal(r.body.receipt.status, "applied");
  }
  const final = await progress(a);
  assert.equal(final.backpack.test_good_01, 10, "each order applied exactly once");
  assert.equal(checkLedger(await receipts(a), final), 10);
});

test("security: guest auth, forged values, other accounts' data, client storage", async () => {
  assert.equal((await authRaw("device", { id: `guest-device-${newKey()}` })).status, 403);
  assert.equal((await authRaw("custom", { id: `custom-${newKey()}` })).status, 403);
  const a = await authEmail("sec-a");
  const b = await authEmail("sec-b");
  const ga = await begin(a);
  await begin(b);
  const forged = [
    { ...order(ga), price: 1 }, { ...order(ga), money: 99999999 }, { ...order(ga), action: "grant" },
    { ...order(ga), quantity: "10" }, { ...order(ga), idempotency_key: "x" }, "not json", "x".repeat(4000),
  ];
  for (const f of forged) assert.equal((await rpc(a, "vs01_trade", f)).status, 400, JSON.stringify(f).slice(0, 80));
  for (const quantity of [0, -1, 5, 1.5, 1e308]) {
    const r = await rpc(a, "vs01_trade", order(ga, { quantity }));
    assert.equal(r.body.receipt.reason, "invalid_quantity", `quantity ${quantity}`);
  }
  // B cannot use A's session, read A's data, or write progress for itself.
  assert.equal((await rpc(b, "vs01_trade", order(ga))).body.message, "gameplay_session_superseded");
  const peek = await api(b, "POST", "/v2/storage", { object_ids: [{ collection: "vs01_wp01_progress", key: "trade", user_id: a.userId }] });
  assert.deepEqual(peek.body.objects ?? [], []);
  const list = await api(b, "GET", `/v2/storage/vs01_wp01_receipts?user_id=${a.userId}&limit=10`);
  assert.deepEqual(list.body.objects ?? [], []);
  const write = await api(b, "PUT", "/v2/storage", { objects: [{ collection: "vs01_wp01_progress", key: "trade", value: JSON.stringify({ money: 1e9 }) }] });
  assert.equal(write.status, 403);
  const reward = await rpc(a, "vs01_combat_reward_claim", { money: 50000 });
  assert.equal(reward.status, 403);
  assert.equal((await progress(a)).money, 10000);
  assert.equal((await progress(b)).money, 10000);
  // No auth at all.
  const anon = await fetch(`${process.env.MYRIAL_NAKAMA_URL ?? "http://127.0.0.1:17350"}/v2/rpc/vs01_trade`, { method: "POST", body: "{}" });
  assert.equal(anon.status, 401);
});

// The WP01 limiter is a fixed 10 s window counted in the node-local cache
// with a non-atomic increment (documented limit). Guarantee tested here:
// a burst is throttled, never more than 2 x limit passes (window boundary),
// and whatever passes is still exactly-once and consistent. The observed
// counts are printed as evidence.
test("rate limit: a 45-trade burst is throttled, state stays consistent", async (t) => {
  const a = await authEmail("rate");
  const g = await begin(a);
  const results = await Promise.all(Array.from({ length: 45 }, () => rpc(a, "vs01_trade", order(g))));
  const limited = results.filter((r) => r.status === 429).length;
  const applied = results.filter((r) => r.status === 200).length;
  t.diagnostic(`rate limit evidence: sent 45, applied ${applied}, throttled ${limited} (limit 30 per 10 s)`);
  assert.equal(limited + applied, 45, "every request is either throttled or decided");
  assert.ok(limited >= 10, `throttled ${limited}`);
  assert.ok(applied <= 60, `applied ${applied}`);
  const final = await progress(a);
  assert.equal(checkLedger(await receipts(a), final), applied);
});
