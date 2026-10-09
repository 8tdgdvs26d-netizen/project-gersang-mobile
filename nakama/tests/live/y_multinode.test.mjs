// A14 across nodes: two Nakama processes on the same PostgreSQL share one
// rate-limit log. Runs only when MYRIAL_NAKAMA_URL_2 points at the second node
// (nakama/scripts/run_live_tests.sh starts it with the "multinode" profile).
import test from "node:test";
import assert from "node:assert/strict";
import { authEmail, rpc, begin, order, progress, BASE } from "./live_client.mjs";

const NODE2 = process.env.MYRIAL_NAKAMA_URL_2;

test("two nodes, 45 concurrent requests split across them: at most 30 accepted", { skip: !NODE2 && "MYRIAL_NAKAMA_URL_2 not set" }, async (t) => {
  const a = await authEmail("multinode");
  const g = await begin(a);
  const results = await Promise.all(Array.from({ length: 45 }, (_, i) =>
    rpc(a, "vs01_trade", order(g), { base: i % 2 ? NODE2 : BASE })));
  const applied = results.filter((r) => r.status === 200).length;
  const limited = results.filter((r) => r.status === 429).length;
  t.diagnostic(`rate limit evidence (2 nodes, 45 concurrent): applied ${applied}, throttled ${limited}`);
  assert.equal(applied + limited, 45);
  assert.ok(applied <= 30, `applied ${applied} > 30 across two nodes`);
  const final = await progress(a);
  assert.equal(final.backpack.test_good_01, applied, "each accepted order applied once");
});
