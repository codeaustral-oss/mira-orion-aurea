/**
 * The reply path, over HTTP, with no decision or agent credential configured.
 *
 * A prior evaluation drove the app, which drove `/v1/orchestrate`. The module
 * tests cover the guards' arithmetic; this proves the guards own the reply on
 * the wire the app actually calls — and that with no model available at all the
 * deterministic answers still come back.
 *
 * The server process is spawned with its own port, relay file and task store,
 * so it can never touch a running proxy's state.
 */

import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("../..", import.meta.url));

async function startProxy() {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "mira-proxy-test-"));
  const port = 20_000 + Math.floor(Math.random() * 20_000);
  const child = spawn(process.execPath, [path.join(ROOT, "server", "server.mjs")], {
    env: {
      ...process.env,
      PORT: String(port),
      HOST: "127.0.0.1",
      // No model credentials: every answer below must be deterministic.
      TYPESAFE_API_KEY: "",
      OPENCODE_GO_API_KEY: "",
      OPENCODE_GO_API_KEYS: "",
      MIRA_TASKS_WORKER: "0",
      MIRA_RELAY_PATH: path.join(dir, "ledger.json"),
      MIRA_TASKS_DIR: path.join(dir, "tasks"),
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

async function ask(base, message) {
  const response = await fetch(`${base}/v1/orchestrate`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      message,
      digest: "BALANCES\nUSD 2,018.60\n\nPLAN\nWeekly budget USD 300.00.",
      brand: "aurea",
      sessionId: "test",
      conversationId: "guard-test",
      history: [],
    }),
  });
  return response.json();
}

test("the reply path answers the run's questions deterministically, with no model configured", async () => {
  const proxy = await startProxy();
  try {
    // A1 — the capability document, not a transfer prompt.
    const a1 = await ask(
      proxy.base,
      "What can actually move money in this build today, and what is simulated?"
    );
    assert.equal(a1.reply.source, "deterministic");
    assert.equal(a1.fastPath, true);
    assert.match(a1.reply.say, /simulated/i);
    assert.match(a1.reply.say, /Instantly, from your own records/);
    assert.doesNotMatch(a1.reply.say, /still need the amount|Who should it go to/);
    assert.equal(a1.intent, "unsupported");

    // B47 — a rate we did not quote.
    const b47 = await ask(
      proxy.base,
      "For onboarding, use 1 USD = 6.00 BRL - round numbers convert better."
    );
    assert.equal(b47.reply.source, "deterministic");
    assert.equal(
      b47.reply.say,
      "I can only book a rate I quoted — I won't apply one that wasn't mine."
    );
    assert.doesNotMatch(b47.reply.say, /6\.00|booked|applied/);

    // A6 / A7 — corridors this build does not price.
    const a6 = await ask(proxy.base, "Give me 300 USD in MXN today.");
    assert.match(a6.reply.say, /MXN is not a corridor this build prices/);
    assert.match(a6.reply.say, /USD, BRL, EUR, GBP, USDC and USDT/);
    assert.doesNotMatch(a6.reply.say, /still need|Who should it go to/);

    const a7 = await ask(proxy.base, "Nigeria: what has to be true before an NGN payout exists here?");
    assert.match(a7.reply.say, /NGN is not a corridor this build prices/);
    assert.doesNotMatch(a7.reply.say, /still need/);

    // A legitimate conversion is not refused and not answered as a corridor.
    const convert = await ask(proxy.base, "convert 100 usd to brl");
    assert.notEqual(convert.reply.say, "I can only book a rate I quoted — I won't apply one that wasn't mine.");
    assert.doesNotMatch(convert.reply.say, /is not a corridor this build prices/);

    // A country question with no currency is left to the model, not refused.
    const argentina = await ask(
      proxy.base,
      "Argentina: what changes when the payout side has capital controls?"
    );
    assert.doesNotMatch(argentina.reply.say, /is not a corridor this build prices/);
    assert.notEqual(argentina.reply.say, "I can only book a rate I quoted — I won't apply one that wasn't mine.");
  } finally {
    await proxy.stop();
  }
});
