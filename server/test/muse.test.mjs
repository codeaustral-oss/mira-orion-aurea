/**
 * Agent-model client tests.
 *
 * These prove the honest-failure contract: with no credential the client says so
 * and does not invent an answer, and an orchestration reply whose model call
 * failed is labelled as unavailable rather than presented as prose from a model.
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { askMuse, extractText, buildInput } from "../lib/muse.mjs";
import { composeReply, fallbackLine, ACTION_TYPES } from "../lib/orchestrate.mjs";

test("extractText reads only output_text parts of message items", () => {
  const payload = {
    output: [
      { type: "reasoning", summary: [{ type: "summary_text", text: "thinking" }] },
      { type: "message", content: [{ type: "output_text", text: "hello " }] },
      { type: "message", content: [{ type: "output_text", text: "world" }] },
    ],
  };
  assert.equal(extractText(payload), "hello world");
  assert.equal(extractText({ output: [] }), "");
  assert.equal(extractText(null), "");
});

test("buildInput turns history and the message into real turns", () => {
  const turns = buildInput({
    input: "and now?",
    history: [
      { role: "user", content: "send 10 usd" },
      { role: "assistant", content: "ok" },
      { role: "user", content: "   " },
    ],
  });
  assert.equal(turns.length, 3);
  assert.deepEqual(turns[0], { role: "user", content: "send 10 usd" });
  assert.deepEqual(turns[1], { role: "assistant", content: "ok" });
  assert.deepEqual(turns[2], { role: "user", content: "and now?" });
});

test("with no credential the client reports failure instead of a fake answer", async () => {
  const previous = process.env.OPENCODE_GO_API_KEY;
  delete process.env.OPENCODE_GO_API_KEY;
  try {
    const result = await askMuse({ instructions: "be helpful", input: "hi" });
    assert.equal(result.ok, false);
    assert.equal(result.configured, false);
    assert.match(result.detail, /OPENCODE_GO_API_KEY/);
    assert.equal(result.text, undefined);
  } finally {
    if (previous !== undefined) process.env.OPENCODE_GO_API_KEY = previous;
  }
});

test("a failed model call yields a labelled deterministic fallback", async () => {
  const previous = process.env.OPENCODE_GO_API_KEY;
  delete process.env.OPENCODE_GO_API_KEY;
  try {
    const reply = await composeReply({
      result: {
        specialist: { id: "treasurer" },
        action: { type: ACTION_TYPES.PROPOSE_TRANSFER, asset: "USD", amountMinor: 10_000 },
      },
      message: "send 100 usd to Mira Orion",
      digest: "BALANCES\nUSD 1,793.60",
      brand: "aurea",
    });
    assert.equal(reply.ok, false);
    assert.equal(reply.source, "unavailable");
    assert.equal(reply.model, "deterministic");
    assert.ok(reply.say.length > 0);
  } finally {
    if (previous !== undefined) process.env.OPENCODE_GO_API_KEY = previous;
  }
});

test("a fallback never claims a live search, booking or purchase", () => {
  const line = fallbackLine({ type: ACTION_TYPES.REQUIREMENTS_FLOW, topic: "travel" });
  assert.match(line, /not connected/);
  // It may say nothing was booked; it must never claim something was.
  assert.doesNotMatch(
    line.toLowerCase(),
    /has been booked|was booked|is booked|has been purchased|has been paid|you bought/
  );
});

test("a provider flake falls back to the other model rather than failing the reply", async () => {
  // The live failure: muse answered 5xx / produced no text, and the person was
  // told the model was unavailable for a one-line answer.
  const previous = {
    key: process.env.OPENCODE_GO_API_KEY,
    model: process.env.MIRA_AGENT_MODEL,
    fallback: process.env.MIRA_AGENT_FALLBACK_MODEL,
  };
  process.env.OPENCODE_GO_API_KEY = "test-key";
  process.env.MIRA_AGENT_MODEL = "muse-spark-1.3-contributor";
  process.env.MIRA_AGENT_FALLBACK_MODEL = "deepseek-v4.1-flash";

  const calls = [];
  const fetchImpl = async (url, init) => {
    const body = JSON.parse(init.body);
    calls.push(body.model);
    if (body.model === "muse-spark-1.3-contributor") {
      return {
        ok: false,
        status: 502,
        headers: new Headers({ "content-type": "application/json" }),
        text: async () => JSON.stringify({ error: "The model failed to generate a response." }),
        json: async () => ({}),
      };
    }
    return {
      ok: true,
      status: 200,
      headers: new Headers({ "content-type": "application/json" }),
      text: async () => "{}",
      json: async () => ({
        model: body.model,
        output: [{ type: "message", content: [{ type: "output_text", text: "A fee is a charge." }] }],
      }),
    };
  };

  // The module keeps its own fetch; the exported client uses globalThis.fetch.
  const originalFetch = globalThis.fetch;
  globalThis.fetch = fetchImpl;
  try {
    const reply = await askMuse({ input: "what is a fee?", instructions: "x" });
    assert.equal(reply.ok, true);
    assert.equal(reply.text, "A fee is a charge.");
    assert.equal(reply.fellBack, true);
    assert.deepEqual(calls, ["muse-spark-1.3-contributor", "deepseek-v4.1-flash"]);
  } finally {
    globalThis.fetch = originalFetch;
    process.env.OPENCODE_GO_API_KEY = previous.key ?? "";
    if (previous.model === undefined) delete process.env.MIRA_AGENT_MODEL;
    else process.env.MIRA_AGENT_MODEL = previous.model;
    if (previous.fallback === undefined) delete process.env.MIRA_AGENT_FALLBACK_MODEL;
    else process.env.MIRA_AGENT_FALLBACK_MODEL = previous.fallback;
  }
});

test("the reply path's own model is allowed to be the fallback — it still gets a second model", async () => {
  // The live turn: the reply model is configured to the same name as the
  // process fallback (`MIRA_AGENT_REPLY_MODEL=deepseek-v4.1-flash`), so the old
  // code found nothing left to try and the person was told the model was
  // unreachable while the agent model was available.
  const previous = {
    key: process.env.OPENCODE_GO_API_KEY,
    model: process.env.MIRA_AGENT_MODEL,
    fallback: process.env.MIRA_AGENT_FALLBACK_MODEL,
  };
  process.env.OPENCODE_GO_API_KEY = "test-key";
  process.env.MIRA_AGENT_MODEL = "muse-spark-1.3-contributor";
  process.env.MIRA_AGENT_FALLBACK_MODEL = "deepseek-v4.1-flash";

  const calls = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    calls.push(body.model);
    if (body.model === "deepseek-v4.1-flash") {
      return {
        ok: false,
        status: 500,
        text: async () => "{}",
        json: async () => ({}),
      };
    }
    return {
      ok: true,
      status: 200,
      text: async () => "{}",
      json: async () => ({
        model: body.model,
        output: [{ type: "message", content: [{ type: "output_text", text: "Here is the honest line." }] }],
      }),
    };
  };
  try {
    // The reply path names its model explicitly, exactly as composeReply does.
    const reply = await askMuse({
      input: "Argentina: what changes when the payout side has capital controls?",
      instructions: "x",
      model: "deepseek-v4.1-flash",
    });
    assert.equal(reply.ok, true, "the second model answered");
    assert.equal(reply.text, "Here is the honest line.");
    assert.equal(reply.fellBack, true);
    assert.equal(reply.model, "muse-spark-1.3-contributor");
    assert.deepEqual(calls, ["deepseek-v4.1-flash", "muse-spark-1.3-contributor"]);
  } finally {
    globalThis.fetch = originalFetch;
    process.env.OPENCODE_GO_API_KEY = previous.key ?? "";
    if (previous.model === undefined) delete process.env.MIRA_AGENT_MODEL;
    else process.env.MIRA_AGENT_MODEL = previous.model;
    if (previous.fallback === undefined) delete process.env.MIRA_AGENT_FALLBACK_MODEL;
    else process.env.MIRA_AGENT_FALLBACK_MODEL = previous.fallback;
  }
});

test("a transport error on the preferred model does not skip the fallback", async () => {
  const previous = {
    key: process.env.OPENCODE_GO_API_KEY,
    model: process.env.MIRA_AGENT_MODEL,
    fallback: process.env.MIRA_AGENT_FALLBACK_MODEL,
  };
  process.env.OPENCODE_GO_API_KEY = "test-key";
  process.env.MIRA_AGENT_MODEL = "muse-spark-1.3-contributor";
  process.env.MIRA_AGENT_FALLBACK_MODEL = "deepseek-v4.1-flash";

  const calls = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    calls.push(body.model);
    if (body.model === "muse-spark-1.3-contributor") throw new Error("socket hang up");
    return {
      ok: true,
      status: 200,
      text: async () => "{}",
      json: async () => ({
        model: body.model,
        output: [{ type: "message", content: [{ type: "output_text", text: "Answered by the fallback." }] }],
      }),
    };
  };
  try {
    const reply = await askMuse({ input: "what is a fee?", instructions: "x" });
    assert.equal(reply.ok, true);
    assert.equal(reply.text, "Answered by the fallback.");
    assert.deepEqual(calls, ["muse-spark-1.3-contributor", "deepseek-v4.1-flash"]);
  } finally {
    globalThis.fetch = originalFetch;
    process.env.OPENCODE_GO_API_KEY = previous.key ?? "";
    if (previous.model === undefined) delete process.env.MIRA_AGENT_MODEL;
    else process.env.MIRA_AGENT_MODEL = previous.model;
    if (previous.fallback === undefined) delete process.env.MIRA_AGENT_FALLBACK_MODEL;
    else process.env.MIRA_AGENT_FALLBACK_MODEL = previous.fallback;
  }
});

test("when both models fail, the reply says so and never invents an answer", async () => {
  const previous = {
    key: process.env.OPENCODE_GO_API_KEY,
    model: process.env.MIRA_AGENT_MODEL,
    fallback: process.env.MIRA_AGENT_FALLBACK_MODEL,
  };
  process.env.OPENCODE_GO_API_KEY = "test-key";
  process.env.MIRA_AGENT_MODEL = "muse-spark-1.3-contributor";
  process.env.MIRA_AGENT_FALLBACK_MODEL = "deepseek-v4.1-flash";

  const calls = [];
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    calls.push(JSON.parse(init.body).model);
    return { ok: false, status: 503, text: async () => "{}", json: async () => ({}) };
  };
  try {
    const reply = await composeReply({
      result: { specialist: { id: "treasurer" }, action: { type: ACTION_TYPES.REPLY } },
      message: "what changes when the payout side has capital controls?",
      digest: "BALANCES\nUSD 2,018.60",
      brand: "aurea",
    });
    assert.equal(reply.ok, false);
    assert.equal(reply.source, "unavailable");
    assert.equal(reply.model, "deterministic");
    assert.match(reply.say, /assistant model is not reachable/);
    // Every distinct model was tried once before that line was produced.
    assert.deepEqual(new Set(calls), new Set(["muse-spark-1.3-contributor", "deepseek-v4.1-flash"]));
  } finally {
    globalThis.fetch = originalFetch;
    process.env.OPENCODE_GO_API_KEY = previous.key ?? "";
    if (previous.model === undefined) delete process.env.MIRA_AGENT_MODEL;
    else process.env.MIRA_AGENT_MODEL = previous.model;
    if (previous.fallback === undefined) delete process.env.MIRA_AGENT_FALLBACK_MODEL;
    else process.env.MIRA_AGENT_FALLBACK_MODEL = previous.fallback;
  }
});
