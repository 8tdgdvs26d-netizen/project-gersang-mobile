# Gersang Mobile First Playable v0.4

This repository now includes the deployable P0 First Playable.

## Runtime

- Node.js 22+
- Built-in `node:sqlite`
- Browser UI served from `/public`
- HTTP API and SQLite persistence in `server.mjs`

## Start

```bash
PORT=10000 DB_PATH=./first-playable.sqlite node server.mjs
```

Open:

```text
http://localhost:10000
```

## Health

```text
GET /api/health
```

Expected:

```json
{"ok":true,"version":"0.4","phase":"First Playable"}
```

## Render

Use this repository as a Docker Web Service. The root `Dockerfile` starts `server.mjs` and binds the server to `0.0.0.0:$PORT`.

For persistent game saves, mount a persistent disk at `/data` and set:

```text
DB_PATH=/data/first-playable.sqlite
```

Do not run multiple replicas against the same SQLite file. This is a single-process prototype build.

## P0 playable loop

Login / Session → City Market → Buy → Cargo / Storage → Travel → Arrival → Sell → Persistence / Reconnect.
