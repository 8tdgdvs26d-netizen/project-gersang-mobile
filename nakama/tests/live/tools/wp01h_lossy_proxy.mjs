// VS-01 WP01-H E3 LIVE tool (FS-K2): a REPRODUCIBLE random lossy proxy in
// front of the run's own Nakama. Separate from the shared lossy_proxy.mjs
// (WP01-B / C / E), which is not changed.
//
// Loopback only: it listens on 127.0.0.1 and forwards to 127.0.0.1 only.
// Only the WP01-H write RPCs are disturbed (vs01_trade, vs01_trade_resolve,
// vs01e_encounter_claim, vs01e_encounter_abandon); everything else
// (sign-in, session begin, reads) passes untouched, so a run can always
// sign in and recover. Every decision comes from a seeded PRNG over the
// request sequence number, so the same seed + the same request order gives
// the same faults; each decision is logged and counted.
//
// Usage: node wp01h_lossy_proxy.mjs <listen-port> <upstream-port> <seed>
//        [drop_request_pct=15] [drop_response_pct=15] [reset_pct=5] [delay_max_ms=1500]
// GET /__wp01h_lossy/stats returns the counters and the decision log.
import http from "node:http";
import { fileURLToPath } from "node:url";

export const DISTURBED = ["vs01_trade", "vs01_trade_resolve", "vs01e_encounter_claim", "vs01e_encounter_abandon"];
export const HOST = "127.0.0.1";

// mulberry32: small, deterministic PRNG (state = seed mixed with the sequence).
export function rand(seed, seq, salt) {
  let t = (seed ^ Math.imul(seq + 1, 0x9e3779b1) ^ Math.imul(salt + 1, 0x85ebca6b)) >>> 0;
  t = (t + 0x6d2b79f5) >>> 0;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}

// The fault for request number `seq` of a disturbed RPC.
export function decide(seq, seed, cfg) {
  const r = rand(seed, seq, 1) * 100;
  const delay = Math.floor(rand(seed, seq, 2) * (cfg.delay_max_ms + 1));
  if (r < cfg.drop_request_pct) return { fault: "drop_request", delay };
  if (r < cfg.drop_request_pct + cfg.drop_response_pct) return { fault: "drop_response", delay };
  if (r < cfg.drop_request_pct + cfg.drop_response_pct + cfg.reset_pct) return { fault: "reset", delay };
  return { fault: "none", delay };
}

export function parseConfig(argv) {
  const [listen, upstream, seed, dq = "15", dr = "15", rs = "5", dl = "1500"] = argv;
  const cfg = { listen: Number(listen), upstream: Number(upstream), seed: Number(seed),
    drop_request_pct: Number(dq), drop_response_pct: Number(dr), reset_pct: Number(rs), delay_max_ms: Number(dl) };
  for (const [k, v] of Object.entries(cfg)) if (!Number.isSafeInteger(v) || v < 0) throw new Error(`bad ${k}`);
  if (cfg.listen < 1024 || cfg.upstream < 1024 || cfg.listen > 65535 || cfg.upstream > 65535) throw new Error("ports must be 1024-65535");
  if (cfg.drop_request_pct + cfg.drop_response_pct + cfg.reset_pct > 100) throw new Error("fault percentages exceed 100");
  return cfg;
}

export function rpcOf(url) {
  const m = (url ?? "").split("?")[0].match(/^\/v2\/rpc\/([a-z0-9_]+)$/);
  return m ? m[1] : "";
}

export function startProxy(cfg, log = () => {}) {
  const stats = { seed: cfg.seed, config: cfg, disturbed: 0, passed: 0, faults: { none: 0, drop_request: 0, drop_response: 0, reset: 0 }, decisions: [] };
  let seq = 0;
  const server = http.createServer((req, res) => {
    if (req.url === "/__wp01h_lossy/stats") { res.writeHead(200, { "Content-Type": "application/json" }); res.end(JSON.stringify(stats)); return; }
    const rpc = req.method === "POST" ? rpcOf(req.url) : "";
    const disturbed = DISTURBED.includes(rpc);
    const d = disturbed ? decide(seq, cfg.seed, cfg) : { fault: "none", delay: 0 };
    const n = disturbed ? seq++ : -1;
    if (disturbed) { stats.disturbed += 1; stats.faults[d.fault] += 1; stats.decisions.push({ seq: n, rpc, ...d }); log(`#${n} ${rpc} ${d.fault} delay=${d.delay}`); }
    else stats.passed += 1;
    const body = [];
    req.on("data", (c) => body.push(c));
    req.on("end", () => setTimeout(() => {
      if (d.fault === "drop_request") { req.socket.destroy(); return; } // never reaches the server
      const up = http.request({ host: HOST, port: cfg.upstream, method: req.method, path: req.url, headers: req.headers }, (u) => {
        const chunks = [];
        u.on("data", (c) => chunks.push(c));
        u.on("end", () => {
          if (d.fault === "drop_response") { req.socket.destroy(); return; } // the server decided; the client never hears it
          res.writeHead(u.statusCode, u.headers);
          if (d.fault === "reset") { res.write(Buffer.concat(chunks).subarray(0, 1)); req.socket.destroy(); return; } // cut mid-reply
          res.end(Buffer.concat(chunks));
        });
      });
      up.on("error", () => req.socket.destroy());
      up.end(Buffer.concat(body));
    }, d.delay));
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen({ host: HOST, port: cfg.listen, exclusive: true }, () => resolve({ server, stats }));
  });
}

const isEntry = (() => { try { return process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]; } catch { return false; } })();
if (isEntry) {
  const cfg = parseConfig(process.argv.slice(2));
  startProxy(cfg, (m) => console.log(m)).then(() => console.log(`wp01h lossy proxy ${HOST}:${cfg.listen} -> ${HOST}:${cfg.upstream} seed=${cfg.seed}`));
}
