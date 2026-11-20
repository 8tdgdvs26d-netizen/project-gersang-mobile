// VS-01 WP01-H E3 LIVE tool: R-04 legacy / malformed trade-receipt seed.
//
// Real legacy v1 applied / rejected receipts are produced by the unchanged
// vs01_trade (no seed). ONLY receipts no current server can write (bad hash,
// missing / extra field, wrong contract version, foreign user id, readable
// permission) are seeded here, under these rules (Blueprint v0.1r2 R-04):
//   - the run's own compose project only (wp01h_db.runProject);
//   - INSERT only, collection vs01_wp01_receipts only, never UPDATE / DELETE;
//   - user ids only from the run's allow-list (accounts created by this run);
//   - keys are 32-hex, derived from "wp01h-seed";
//   - the storage table columns are checked first (G2-6): any difference STOP;
//   - every seed is read back (hash) and appended to the seed manifest;
//   - nothing is ever cleaned up.
import fs from "node:fs";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import { COMPOSE_DIR, runProject, checkUser, objects, sha, canonical, sql } from "./wp01h_db.mjs";

export const SEED_COLLECTION = "vs01_wp01_receipts";
// Columns the seed writes / relies on (Nakama 3.25 storage table). PENDING:
// confirmed only at run time by checkStorageColumns (G2-6); mismatch = STOP.
export const EXPECTED_COLUMNS = ["collection", "create_time", "key", "read", "update_time", "user_id", "value", "version", "write"];

export function checkStorageColumns(env = process.env) {
  const out = sql("SELECT string_agg(column_name, ',' ORDER BY column_name) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'storage'", env).trim();
  const have = out.split(",").filter(Boolean);
  const missing = EXPECTED_COLUMNS.filter((c) => !have.includes(c));
  if (missing.length) throw new Error(`STOP G2-6: storage columns differ (missing ${missing.join(",")}; have ${have.join(",")})`);
  return have;
}

export function seedKey(label) {
  if (!/^[a-z0-9_]{1,40}$/.test(label)) throw new Error("bad seed label");
  return crypto.createHash("sha256").update(`wp01h-seed:${label}`).digest("hex").slice(0, 32);
}

// One INSERT. `allowedUsers` is the run's own account list.
export function seedReceipt({ userId, label, value, read = 0 }, allowedUsers, manifestPath, env = process.env) {
  const project = runProject(env);
  checkUser(userId);
  if (!(allowedUsers instanceof Set) || !allowedUsers.has(userId)) throw new Error("STOP R-04: user is not an account of this run");
  if (![0, 1, 2].includes(read)) throw new Error("bad read permission");
  if (typeof manifestPath !== "string" || !manifestPath.startsWith("/")) throw new Error("manifest path must be absolute");
  const key = seedKey(label);
  if (objects(userId, SEED_COLLECTION, env).some((o) => o.key === key)) throw new Error("STOP R-04: seed key already exists (no overwrite)");
  const json = JSON.stringify(value);
  if (/'/.test(json)) throw new Error("seed value must not contain a single quote");
  const version = crypto.createHash("md5").update(json).digest("hex");
  const insert = `INSERT INTO storage (collection, key, user_id, value, version, read, write) VALUES ('${SEED_COLLECTION}', '${key}', '${userId}', '${json}'::jsonb, '${version}', ${read}, 0)`;
  execFileSync(env.DOCKER ?? "docker", ["compose", "-p", project, "exec", "-T", "postgres", "psql", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "nakama", "-c", insert],
    { cwd: COMPOSE_DIR, env, maxBuffer: 16 * 1024 * 1024 });
  const back = objects(userId, SEED_COLLECTION, env).find((o) => o.key === key);
  if (!back || canonical(back.value) !== canonical(value) || back.read !== read) throw new Error("STOP R-04: seed readback differs");
  const entry = { at: new Date().toISOString(), collection: SEED_COLLECTION, key, user_sha256: sha(userId), label, read, value_sha256: sha(value) };
  fs.appendFileSync(manifestPath, JSON.stringify(entry) + "\n", { mode: 0o600 });
  return { key, entry };
}
