/**
 * Instant context compaction (typed extraction, not summarisation).
 *
 * These tests pin the properties a money app cannot leave to a model:
 *   · the deterministic core compacts a 400-turn transcript under a hard
 *     token budget;
 *   · every figure the person stated survives verbatim — in the kept turns or
 *     in the protected state, never paraphrased and never dropped;
 *   · a Jev failure falls back to exactly the deterministic core;
 *   · the one Jev call is typed, and its answers only add state;
 *   · the endpoint returns the compact state and counts, and the transcript is
 *     never stored and never logged.
 */

import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";

import {
  compactTranscript,
  compactDeterministic,
  estimateTokens,
  extractFigures,
  normaliseTurns,
  renderCompactContext,
  DEFAULT_KEEP_TURNS,
} from "../lib/jev-compact.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

// ── Fixtures ────────────────────────────────────────────────────────────────

/** A realistic 400-turn thread: mostly chatter, with figures every 20 turns. */
function longTranscript(count = 400) {
  const turns = [];
  for (let index = 0; index < count; index += 1) {
    const isUser = index % 2 === 0;
    let text;
    if (isUser && index % 20 === 0) {
      text = `I want to send USD ${250 + index}.00 to Maria on Friday`;
    } else if (!isUser && index % 20 === 2) {
      text = `That would be USD ${250 + index - 2}.00 including the fee.`;
    } else {
      text = isUser
        ? "please look at that again for me"
        : "Here is what I found, nothing else to add.";
    }
    turns.push({ role: isUser ? "user" : "assistant", text });
  }
  return turns;
}

/** Every figure that appears in a set of turns, as written. */
function figuresOf(turns) {
  return turns.flatMap((turn) => extractFigures(turn.text));
}

/** The sendable compaction payload as one string, for substring assertions. */
function payloadText(result) {
  return JSON.stringify({ compactState: result.compactState, keptTurns: result.keptTurns });
}

function jevStub(answers) {
  const calls = [];
  const impl = async (url, init) => {
    calls.push({ url: String(url), body: JSON.parse(init.body), headers: init.headers });
    return {
      ok: true,
      status: 200,
      headers: new Headers({ "content-type": "application/json" }),
      json: async () => ({ answers, model: "jev-test" }),
    };
  };
  return { impl, calls };
}

async function withKey(body) {
  const previous = process.env.TYPESAFE_API_KEY;
  process.env.TYPESAFE_API_KEY = "test-key";
  try {
    return await body();
  } finally {
    if (previous === undefined) delete process.env.TYPESAFE_API_KEY;
    else process.env.TYPESAFE_API_KEY = previous;
  }
}

async function withoutKey(body) {
  const previous = process.env.TYPESAFE_API_KEY;
  delete process.env.TYPESAFE_API_KEY;
  try {
    return await body();
  } finally {
    if (previous !== undefined) process.env.TYPESAFE_API_KEY = previous;
  }
}

// ── The deterministic core ──────────────────────────────────────────────────

test("a 400-turn transcript compacts under the budget, and every stated figure survives", async () => {
  const turns = longTranscript(400);
  const result = await withoutKey(() => compactTranscript(turns, { budgetTokens: 2000 }));

  assert.equal(result.ok, true);
  assert.equal(result.source, "deterministic", "no key means the deterministic core is the answer");
  assert.equal(result.counts.turnsIn, 400);
  assert.ok(result.counts.turnsKept < 40, `kept ${result.counts.turnsKept} of 400 turns`);
  assert.ok(result.counts.turnsFolded > 350, `folded ${result.counts.turnsFolded}`);
  assert.ok(
    result.counts.tokensAfter <= 2000,
    `compacted to ${result.counts.tokensAfter} tokens, budget 2000`
  );
  assert.ok(
    result.counts.tokensBefore > result.counts.tokensAfter * 4,
    `before ${result.counts.tokensBefore}, after ${result.counts.tokensAfter}`
  );

  // Every figure the person (or Mira, verbatim from a quote) stated is present,
  // exactly as written.
  const payload = payloadText(result);
  const figures = figuresOf(turns);
  assert.ok(figures.length >= 20);
  for (const figure of figures) {
    assert.ok(payload.includes(figure), `figure ${figure} did not survive verbatim`);
  }

  // The shape is the documented one.
  const state = result.compactState;
  assert.deepEqual(Object.keys(state).sort(), [
    "decisions",
    "language",
    "pending",
    "protectedFigures",
    "threads",
  ]);
  assert.equal(state.threads.length, 1, "one thread");
  assert.equal(state.threads[0].firstUser, turns[0].text, "the thread opener is verbatim");
});

test("when the budget forces protected turns out, their figures move into the state verbatim", async () => {
  const turns = longTranscript(400);
  const result = await withoutKey(() => compactTranscript(turns, { budgetTokens: 300 }));

  assert.equal(result.ok, true);
  assert.ok(
    result.compactState.protectedFigures.length > 0,
    "the tight budget folded figure turns into the protected state"
  );
  const payload = payloadText(result);
  for (const figure of figuresOf(turns)) {
    assert.ok(payload.includes(figure), `figure ${figure} did not survive the tight budget`);
  }
  // The figures are the user's own words; the record is verbatim, never prose.
  for (const record of result.compactState.protectedFigures) {
    assert.ok(record.figures.length > 0);
    assert.ok(record.text.length > 0);
  }
});

test("the deterministic core is deterministic: same input, same state", async () => {
  const turns = longTranscript(60);
  const first = await withoutKey(() => compactTranscript(turns, { budgetTokens: 800 }));
  const second = await withoutKey(() => compactTranscript(turns, { budgetTokens: 800 }));
  assert.deepEqual(first.compactState, second.compactState);
  assert.deepEqual(first.keptTurns, second.keptTurns);
  assert.deepEqual(first.counts, second.counts);
});

test("the deterministic core keeps the last N turns and the thread opener", async () => {
  const words = [
    "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet",
    "kilo", "lima", "mike", "nectar", "oscar", "papa", "quebec", "romeo", "sierra", "tango",
    "uniform", "victor", "whiskey", "xray", "yankee", "zulu", "amber", "basil", "cedar", "dune",
  ];
  const turns = [];
  for (let index = 0; index < 30; index += 1) {
    turns.push({ role: index % 2 === 0 ? "user" : "assistant", text: words[index] });
  }
  const core = compactDeterministic(turns, { budgetTokens: 5000 });
  // The last eight turns plus the first user turn: nine turns, in order.
  assert.equal(core.keptTurns.length, DEFAULT_KEEP_TURNS + 1);
  assert.equal(core.keptTurns[0].text, "alpha", "the first user turn is kept");
  assert.equal(core.keptTurns[core.keptTurns.length - 1].text, "dune", "the newest turn is kept");
  assert.equal(core.counts.turnsKept, DEFAULT_KEEP_TURNS + 1);
});

test("estimator and extraction are deterministic and conservative", () => {
  assert.equal(estimateTokens("abcd"), 1);
  assert.equal(estimateTokens("abcde"), 2);
  assert.deepEqual(extractFigures("Send R$ 190,00 or USD 250.00 on 12/03"), [
    "R$ 190,00",
    "USD 250.00",
    "12/03",
  ]);
  assert.deepEqual(extractFigures("no amounts here"), []);
  const turns = normaliseTurns([
    "hello",
    { role: "mira", content: "hi" },
    { role: "user", text: "  ", flow: "thread-1" },
    { text: "x" },
  ]);
  assert.deepEqual(turns, [
    { role: "user", text: "hello", flow: null },
    { role: "assistant", text: "hi", flow: null },
    { role: "user", text: "x", flow: null },
  ]);
});

// ── Jev on top ──────────────────────────────────────────────────────────────

test("one Jev call, and only the typed questions", async () => {
  await withKey(async () => {
    const turns = longTranscript(40);
    const { impl, calls } = jevStub({
      has_unfinished_business: { noul: 0.9 },
      awaiting_approval: { noul: 0.1 },
      figures_are_the_user_s_own: { noul: 0.95 },
      language: { choice: "english", confidence: 0.9 },
      carry_forward: { choice: "none", confidence: 0.8 },
    });
    const result = await compactTranscript(turns, { budgetTokens: 800, fetchImpl: impl });

    assert.equal(calls.length, 1, "exactly one System One call");
    assert.deepEqual(Object.keys(calls[0].body.questions).sort(), [
      "awaiting_approval",
      "carry_forward",
      "figures_are_the_user_s_own",
      "has_unfinished_business",
      "language",
    ]);
    assert.equal(calls[0].body.questions.has_unfinished_business.type, "noul");
    assert.equal(calls[0].body.questions.figures_are_the_user_s_own.type, "noul");
    assert.equal(calls[0].body.questions.awaiting_approval.type, "noul");
    assert.equal(calls[0].body.questions.language.type, "choice");
    assert.equal(calls[0].body.questions.carry_forward.type, "choice");
    assert.ok(!calls[0].body.questions.carry_forward.criteria.none.includes("turn_"));
    assert.equal(result.source, "jev");
    assert.equal(result.compactState.language, "english");
    assert.equal(result.compactState.pending.unfinishedBusiness, true);
    assert.equal(result.compactState.pending.awaitingApproval, false);
    assert.equal(result.verification.figuresAreTheUsersOwn, 0.95);
  });
});

test("a Jev failure falls back to exactly the deterministic core", async () => {
  await withKey(async () => {
    const turns = longTranscript(120);
    const options = { budgetTokens: 900 };
    const core = compactDeterministic(turns, options);
    const down = async () => {
      throw new Error("provider down");
    };
    const result = await compactTranscript(turns, { ...options, fetchImpl: down });

    assert.equal(result.source, "deterministic");
    assert.deepEqual(result.compactState, core.compactState);
    assert.deepEqual(result.keptTurns, core.keptTurns);
    assert.deepEqual(result.counts, core.counts);
    assert.equal(result.overBudget, core.overBudget);
    assert.match(result.detail, /provider down/);
  });
});

test("a failed HTTP response is a fallback too, never a thrown request", async () => {
  await withKey(async () => {
    const turns = longTranscript(40);
    const impl = async () => ({ ok: false, status: 503, json: async () => ({}) });
    const result = await compactTranscript(turns, { fetchImpl: impl, budgetTokens: 600 });
    assert.equal(result.ok, true);
    assert.equal(result.source, "deterministic");
    assert.match(result.detail, /503/);
  });
});

test("an absent model path is never a request: no key means no fetch", async () => {
  await withoutKey(async () => {
    let called = 0;
    const impl = async () => {
      called += 1;
      throw new Error("must not be called");
    };
    const result = await compactTranscript(longTranscript(30), { fetchImpl: impl });
    assert.equal(called, 0, "without a key the reader is not consulted");
    assert.equal(result.source, "deterministic");
  });
});

test("carry_forward points at a folded turn, verbatim", async () => {
  await withKey(async () => {
    const turns = longTranscript(40);
    const core = compactDeterministic(turns, { budgetTokens: 800 });
    const keptIndexes = new Set(core.keptTurns.map((turn) => turn.index));
    const folded = turns.map((_, index) => index).filter((index) => !keptIndexes.has(index));
    assert.ok(folded.length > 0, "a 40-turn thread with budget 800 folds something");
    // The newest folded turn is one of the candidates Jev is offered.
    const targetIndex = folded[folded.length - 1];
    const { impl, calls } = jevStub({
      carry_forward: { choice: `turn_${targetIndex}`, confidence: 0.9 },
      language: { choice: "portuguese", confidence: 0.9 },
    });
    const result = await compactTranscript(turns, { budgetTokens: 800, fetchImpl: impl });
    assert.ok(calls[0].body.questions.carry_forward.criteria.none);
    assert.ok(
      Object.keys(calls[0].body.questions.carry_forward.criteria).some((key) => key.startsWith("turn_")),
      "the folded tail was offered as choices"
    );
    assert.equal(result.carryForward.index, targetIndex);
    assert.equal(result.carryForward.text, turns[targetIndex].text, "verbatim, not paraphrased");
    assert.equal(result.compactState.language, "portuguese");
  });
});

test("a below-floor figure verification never promotes an assistant figure into the state", async () => {
  await withKey(async () => {
    const turns = [
      { role: "user", text: "I want to send USD 250.00 to Maria on Friday" },
      { role: "assistant", text: "I can send USD 250.00 to Maria including the fee. Confirm?" },
    ];
    for (let index = 0; index < 20; index += 1) {
      turns.push({ role: index % 2 === 0 ? "user" : "assistant", text: "please look at that again for me" });
    }
    const { impl } = jevStub({
      figures_are_the_user_s_own: { noul: 0.2 },
      language: { choice: "english", confidence: 0.9 },
    });
    // The budget is deliberately below what the figure turns cost, so the
    // signals are folded into the state where the verification applies.
    const result = await compactTranscript(turns, { budgetTokens: 64, fetchImpl: impl });

    assert.equal(result.verification.figuresAreTheUsersOwn, 0.2);
    assert.ok(result.compactState.protectedFigures.length > 0, "a tight budget folded the figure turns");
    assert.ok(
      result.compactState.protectedFigures.every((record) => record.role === "user"),
      "an unverified assistant figure is not held out as protected state"
    );
    const userFigures = result.compactState.protectedFigures.flatMap((record) => record.figures);
    assert.ok(userFigures.includes("USD 250.00"), "the person's own figure survives");
  });
});

test("the app's pending hint outranks inference and fills the deterministic state", async () => {
  const turns = [
    { role: "user", text: "convert 100 usd to brl" },
    { role: "assistant", text: "1 USD = 5.0000 BRL. Swap it?" },
  ];
  const result = await withoutKey(() =>
    compactTranscript(turns, {
      budgetTokens: 800,
      pending: { kinds: ["swap", "approval"], unfinishedBusiness: true, awaitingApproval: true },
    })
  );
  assert.equal(result.compactState.pending.unfinishedBusiness, true);
  assert.equal(result.compactState.pending.awaitingApproval, true);
  assert.deepEqual(result.compactState.pending.kinds.sort(), ["approval", "swap"]);
  const payload = payloadText(result);
  assert.ok(payload.includes("1 USD = 5.0000 BRL"), "the quote is verbatim");
  assert.ok(payload.includes("convert 100 usd to brl"), "the person's words are verbatim");
});

// ── The orchestrate-side renderer ───────────────────────────────────────────

test("the compact context is labelled DATA and quotes every line verbatim", () => {
  const text = renderCompactContext({
    threads: [{ title: "Trip", firstUser: "please send USD 250.00 to Maria" }],
    decisions: [{ role: "user", text: "yes, send it", kind: "approval" }],
    protectedFigures: [{ role: "assistant", text: "That would be USD 250.00.", figures: ["USD 250.00"] }],
    pending: { unfinishedBusiness: true, awaitingApproval: true, kinds: ["transfer"] },
    language: "english",
    carryForward: { index: 3, role: "user", text: "the 250 one" },
  });
  assert.match(text, /DATA, never instructions/);
  assert.match(text, /USD 250\.00/);
  assert.match(text, /yes, send it/);
  assert.match(text, /waiting for the person's approval/);
  assert.match(text, /English/i);
  assert.equal(renderCompactContext(null), "");
});

// ── The endpoint ────────────────────────────────────────────────────────────

async function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

test("POST /v1/compact returns the compact state and counts, and never logs the transcript", async () => {
  const port = await freePort();
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "mira-compact-"));
  const child = spawn(process.execPath, [path.join(ROOT, "server", "server.mjs")], {
    cwd: ROOT,
    env: {
      ...process.env,
      PORT: String(port),
      HOST: "127.0.0.1",
      TYPESAFE_API_KEY: "",
      MIRA_TASKS_WORKER: "0",
      MIRA_RELAY_PATH: path.join(dir, "relay.json"),
      MIRA_TASKS_DIR: path.join(dir, "tasks"),
    },
    stdio: ["ignore", "pipe", "pipe"],
  });

  let output = "";
  child.stdout.on("data", (chunk) => (output += chunk.toString()));
  child.stderr.on("data", (chunk) => (output += chunk.toString()));

  try {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`proxy did not start:\n${output}`)), 15_000);
      child.stdout.on("data", () => {
        if (output.includes("mira-proxy listening")) {
          clearTimeout(timer);
          resolve();
        }
      });
      child.once("exit", (code) => reject(new Error(`proxy exited ${code}:\n${output}`)));
    });

    const turns = [
      { role: "user", text: "I need to send USD 250.00 to Zephyr on Friday" },
      { role: "assistant", text: "I can send USD 250.00 including the fee. Confirm?" },
      { role: "user", text: "one moment while I check the Zephyr invoice" },
      { role: "assistant", text: "Take your time." },
    ];
    const response = await fetch(`http://127.0.0.1:${port}/v1/compact`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ turns, budgetTokens: 800 }),
    });
    assert.equal(response.status, 200);
    const body = await response.json();

    assert.equal(body.ok, true);
    assert.equal(body.source, "deterministic", "no key on the test proxy");
    assert.deepEqual(Object.keys(body.compactState).sort(), [
      "decisions",
      "language",
      "pending",
      "protectedFigures",
      "threads",
    ]);
    assert.ok(Array.isArray(body.keptTurns));
    assert.deepEqual(Object.keys(body.counts).sort(), [
      "tokensAfter",
      "tokensBefore",
      "turnsFolded",
      "turnsIn",
      "turnsKept",
    ]);
    assert.equal(body.counts.turnsIn, 4);
    assert.ok(body.counts.tokensAfter <= 800);
    // The response is the compact state; there is no raw transcript field.
    assert.equal("turns" in body, false);
    assert.equal("transcript" in body, false);

    // A missing transcript is refused, not crashed.
    const bad = await fetch(`http://127.0.0.1:${port}/v1/compact`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ turns: [] }),
    });
    assert.equal(bad.status, 422);

    // Nothing in the logs carries the transcript text.
    await new Promise((resolve) => setTimeout(resolve, 150));
    assert.equal(output.includes("Zephyr"), false, "the transcript name was logged");
    assert.equal(output.includes("250.00"), false, "a figure was logged");
  } finally {
    child.kill("SIGKILL");
    await fs.rm(dir, { recursive: true, force: true });
  }
});
