/**
 * The proxy key gate, over HTTP.
 *
 * The deployed proxy sits behind a public tunnel, so the app has to prove it is
 * one of our builds before any `/v1/*` route answers. What is pinned here:
 *
 *   · with no key in the environment the proxy is exactly as open as it was on
 *     loopback — the local development case;
 *   · with a key, a missing, wrong or wrong-length value is refused in the
 *     server's ordinary error shape, and the key itself is never echoed back;
 *   · the gate is a prefix, not a route list: an unknown `/v1/…` path is
 *     refused too, while `/health` and non-`/v1` paths answer as before.
 *
 * Each server is spawned on its own port with its own relay and task store, so
 * it can never touch a running proxy's state.
 */

import test from "node:test";
import assert from "node:assert/strict";
import { after } from "node:test";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("../..", import.meta.url));

/** A value only this test file knows; nothing reads it from the environment. */
const TEST_KEY = "mira-proxy-key-test-5f2a9c";

async function startProxy({ key = "" } = {}) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "mira-proxy-key-"));
  const port = 20_000 + Math.floor(Math.random() * 20_000);
  const child = spawn(process.execPath, [path.join(ROOT, "server", "server.mjs")], {
    env: {
      ...process.env,
      PORT: String(port),
      HOST: "127.0.0.1",
      // No model credentials: every answer below must be deterministic.
      TYPESAFE_API_KEY: "",
      OPENCODE_GO_API_KEY: "",
      MIRA_TASKS_WORKER: "0",
      MIRA_RELAY_PATH: path.join(dir, "ledger.json"),
      MIRA_TASKS_DIR: path.join(dir, "tasks"),
      MIRA_PROXY_KEY: key,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const base = `http://127.0.0.1:${port}`;
  const started = Date.now();
  for (;;) {
    try {
      const health = await fetch(`${base}/health`);
      if (health.ok) break;
    } catch {
      /* not up yet */
    }
    if (Date.now() - started > 15_000) throw new Error("proxy did not start");
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return {
    base,
    async stop() {
      child.kill("SIGTERM");
      await fs.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 20 });
    },
  };
}

/** A local development server: no key in the environment. */
const open = await startProxy();
/** The same server with the gate closed. */
const gated = await startProxy({ key: TEST_KEY });

after(async () => {
  await open?.stop();
  await gated?.stop();
});

test("with no key configured, every route answers as it always has", async () => {
  const roster = await fetch(`${open.base}/v1/roster?brand=aurea`);
  assert.equal(roster.status, 200);
  assert.equal((await roster.json()).ok, true);

  // A route that takes a body proves the gate never enters the read path when
  // there is nothing to check.
  const xfer = await fetch(`${open.base}/v1/xfer`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({}),
  });
  assert.equal(xfer.status, 422);

  const health = await fetch(`${open.base}/health`);
  assert.equal(health.status, 200);
});

test("with a key configured, /v1 requires the exact header", async () => {
  const refused = await fetch(`${gated.base}/v1/roster?brand=aurea`);
  assert.equal(refused.status, 401);
  const body = await refused.json();
  assert.equal(body.ok, undefined);
  assert.equal(body.error, "unauthorized");
  assert.equal(typeof body.detail, "string");

  // A wrong value of the same length, a wrong value of another length, and an
  // empty header are all the same refusal.
  for (const wrong of ["x".repeat(TEST_KEY.length), "short", "", `${TEST_KEY}x`]) {
    const response = await fetch(`${gated.base}/v1/roster`, {
      headers: { "x-mira-key": wrong },
    });
    assert.equal(response.status, 401, `accepted ${JSON.stringify(wrong)}`);
  }

  const allowed = await fetch(`${gated.base}/v1/roster?brand=aurea`, {
    headers: { "x-mira-key": TEST_KEY },
  });
  assert.equal(allowed.status, 200);
  const payload = await allowed.json();
  assert.equal(payload.ok, true);
  assert.equal(payload.brand, "aurea");
  assert.equal(payload.agents.length, 6);
});

test("the gate covers a POST body route and unknown /v1 paths alike", async () => {
  const posted = await fetch(`${gated.base}/v1/xfer`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({}),
  });
  assert.equal(posted.status, 401);

  const authorised = await fetch(`${gated.base}/v1/xfer`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-mira-key": TEST_KEY },
    body: JSON.stringify({}),
  });
  // Past the gate, the route answers for itself: an empty body is refused.
  assert.equal(authorised.status, 422);

  // Not a route list: a path that does not exist is still closed without the key.
  assert.equal((await fetch(`${gated.base}/v1/not-a-route`)).status, 401);
  const withKey = await fetch(`${gated.base}/v1/not-a-route`, {
    headers: { "x-mira-key": TEST_KEY },
  });
  assert.equal(withKey.status, 404);
});

test("/health stays open, and no refusal ever repeats the key", async () => {
  const health = await fetch(`${gated.base}/health`);
  assert.equal(health.status, 200);
  assert.equal((await health.json()).ok, true);

  // The gate is scoped to /v1: anything else is answered as before.
  assert.equal((await fetch(`${gated.base}/nope`)).status, 404);

  const refused = await fetch(`${gated.base}/v1/roster`, {
    headers: { "x-mira-key": "guess" },
  });
  const text = await refused.text();
  assert.equal(text.includes(TEST_KEY), false);
});
