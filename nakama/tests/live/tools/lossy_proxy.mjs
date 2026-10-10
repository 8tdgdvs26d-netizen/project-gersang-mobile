// VS-01 WP01-B LIVE test tool: a local HTTP proxy in front of Nakama that
// forwards every request, but for trade RPCs (POST /v2/rpc/vs01_trade) waits
// for the SERVER's full answer and then drops the connection without sending
// it. The client therefore sees a network failure for a trade that the
// server already decided: the "response lost after commit" case.
//
// Usage: node lossy_proxy.mjs <listen-port> <upstream-port>
// GET /__lossy_proxy/stats returns the counters as JSON. Local only.
import http from "node:http";

const [listenPort, upstreamPort] = process.argv.slice(2).map(Number);
if (!listenPort || !upstreamPort) {
  console.error("usage: node lossy_proxy.mjs <listen-port> <upstream-port>");
  process.exit(2);
}

const stats = { forwarded: 0, trade_requests: 0, trade_responses_dropped: 0, upstream_status: {} };

const server = http.createServer((req, res) => {
  if (req.url === "/__lossy_proxy/stats") {
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(stats));
    return;
  }
  const isTrade = req.method === "POST" && req.url.split("?")[0] === "/v2/rpc/vs01_trade";
  const upstream = http.request(
    { host: "127.0.0.1", port: upstreamPort, method: req.method, path: req.url, headers: req.headers },
    (up) => {
      const chunks = [];
      up.on("data", (c) => chunks.push(c));
      up.on("end", () => {
        stats.forwarded += 1;
        if (isTrade) {
          stats.trade_requests += 1;
          stats.upstream_status[up.statusCode] = (stats.upstream_status[up.statusCode] ?? 0) + 1;
          stats.trade_responses_dropped += 1;
          console.log(`dropped trade response (server status ${up.statusCode})`);
          req.socket.destroy(); // the server decided; the client never hears it
          return;
        }
        res.writeHead(up.statusCode, up.headers);
        res.end(Buffer.concat(chunks));
      });
    },
  );
  upstream.on("error", () => req.socket.destroy());
  req.pipe(upstream);
});

server.listen(listenPort, "127.0.0.1", () => console.log(`lossy proxy 127.0.0.1:${listenPort} -> 127.0.0.1:${upstreamPort}`));
