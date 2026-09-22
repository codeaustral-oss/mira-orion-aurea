/**
 * Jev dialogue reads: is a reply the answer, a different request, or a
 * refinement of the subject before it?
 *
 * These tests pin the two things that matter:
 *   · the reads ask their typed questions and return the answers, never text;
 *   · the wiring keeps every deterministic fallback — a low-confidence or
 *     failed read leaves the reply path exactly as it was.
 *
 * The reads are exercised with a stubbed fetchImpl (the `consent.test.mjs`
 * pattern); the wiring is exercised through a real TaskService with the stub
 * installed as the global fetch for the duration of one message. No network.
 */

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

import {
  readReplyRole,
  readContinuation,
  dialogueConfigured,
  DIALOGUE_FLOOR,
} from "../lib/jev-dialogue.mjs";
import { TaskService, TASK_STATUS } from "../lib/tasks.mjs";

process.env.TYPESAFE_API_KEY = "test-key";
// Thumbnail enrichment touches the network; unit tests must not.
process.env.MIRA_THUMBNAILS = "off";

const tmpDir = () => fs.mkdtemp(path.join(os.tmpdir(), "mira-dialogue-test-"));

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

async function withFetchStub(impl, fn) {
  const previous = globalThis.fetch;
  globalThis.fetch = impl;
  try {
    return await fn();
  } finally {
    globalThis.fetch = previous;
  }
}

async function withService(fn) {
  const dir = await tmpDir();
  const service = new TaskService({ dir, autoStart: false, runner: async () => ({ ok: false, detail: "unused" }) });
  await service.load();
  try {
    return await fn(service);
  } finally {
    await fs.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 20 });
  }
}

// ── The reads themselves ─────────────────────────────────────────────────────

test("the reply read asks the role and whether the message carries the detail", async () => {
  const { impl, calls } = jevStub({
    role: { choice: "answer", confidence: 0.82 },
    supplies_detail: { noul: 0.9 },
  });
  const read = await readReplyRole("from Lisbon", {
    question: "Which city are you flying from?",
    activeTitle: "Flights to São Paulo",
    missing: ["origin", "dates"],
    fetchImpl: impl,
  });
  assert.equal(read.ok, true);
  assert.equal(read.role, "answer");
  assert.equal(read.roleConfidence, 0.82);
  assert.equal(read.suppliesDetail, 0.9);
  assert.equal(typeof read.latencyMs, "number");

  assert.equal(calls.length, 1, "one HTTP call for both questions");
  const body = calls[0].body;
  assert.equal(calls[0].headers.authorization, "Bearer test-key");
  assert.equal(body.questions.role.type, "choice");
  assert.deepEqual(Object.keys(body.questions.role.criteria).sort(), ["answer", "new_subject", "unclear"]);
  assert.equal(body.questions.supplies_detail.type, "noul");
  assert.match(body.questions.supplies_detail.instructions, /missing detail/i);
  assert.match(body.state, /Flights to São Paulo/);
  assert.match(body.state, /Which city are you flying from\?/);
  assert.match(body.state, /origin, dates/);
  assert.match(body.state, /from Lisbon/);
});

test("the continuation read asks one question: is this a refinement?", async () => {
  const { impl, calls } = jevStub({ continues: { noul: 0.87 } });
  const read = await readContinuation("somewhere quieter with outdoor seating", {
    previousTitle: "Restaurants in Lisbon",
    previousKind: "restaurant",
    fetchImpl: impl,
  });
  assert.equal(read.ok, true);
  assert.equal(read.continues, 0.87);
  assert.equal(typeof read.latencyMs, "number");
  assert.equal(calls.length, 1);
  assert.equal(calls[0].body.questions.continues.type, "noul");
  assert.match(calls[0].body.questions.continues.instructions, /refining the previous subject/i);
  assert.match(calls[0].body.state, /Restaurants in Lisbon \(restaurant\)/);
  assert.match(calls[0].body.state, /outdoor seating/);
});

test("a missing key, an empty message, an HTTP failure or a throw is ok:false, never a guess", async () => {
  const key = process.env.TYPESAFE_API_KEY;
  process.env.TYPESAFE_API_KEY = "";
  try {
    const noKey = await readReplyRole("from Lisbon", {
      question: "From where?",
      fetchImpl: async () => {
        throw new Error("must not fetch without a key");
      },
    });
    assert.equal(noKey.ok, false);
    assert.equal(noKey.role, undefined);
  } finally {
    process.env.TYPESAFE_API_KEY = key;
  }

  const noText = await readContinuation("   ", {
    previousTitle: "X",
    fetchImpl: async () => {
      throw new Error("must not fetch without a message");
    },
  });
  assert.equal(noText.ok, false);
  assert.equal(noText.continues, undefined);

  const failed = await readReplyRole("from Lisbon", {
    question: "From where?",
    fetchImpl: async () => ({ ok: false, status: 500, json: async () => ({}) }),
  });
  assert.equal(failed.ok, false);
  assert.match(failed.detail, /500/);

  const thrown = await readContinuation("somewhere quieter", {
    previousTitle: "Restaurants in Lisbon",
    fetchImpl: async () => {
      throw new Error("network down");
    },
  });
  assert.equal(thrown.ok, false);
  assert.match(thrown.detail, /network down/);
  assert.equal(thrown.continues, undefined);
});

test("the floor is a real number and configuration comes from the environment", () => {
  assert.ok(DIALOGUE_FLOOR > 0 && DIALOGUE_FLOOR < 1);
  assert.equal(dialogueConfigured(), true);
  const key = process.env.TYPESAFE_API_KEY;
  process.env.TYPESAFE_API_KEY = "";
  try {
    assert.equal(dialogueConfigured(), false);
  } finally {
    process.env.TYPESAFE_API_KEY = key;
  }
});

// ── Wiring: the reads change the paths, and never when they fail ─────────────

test("an answer read keeps the existing answer-filling path", async () => {
  await withService(async (service) => {
    const first = await service.handleMessage({
      brand: "orion",
      conversationId: "d-answer",
      message: "Find me a flight to São Paulo",
    });
    assert.equal(first.task.status, TASK_STATUS.NEEDS_INPUT);

    const { impl, calls } = jevStub({
      role: { choice: "answer", confidence: 0.82 },
      supplies_detail: { noul: 0.9 },
      continues: { noul: 0.05 },
    });
    const logs = [];
    const original = console.log;
    console.log = (...args) => logs.push(args.join(" "));
    let second;
    try {
      second = await withFetchStub(impl, () =>
        service.handleMessage({ brand: "orion", conversationId: "d-answer", message: "from Lisbon, 12-19 October" })
      );
    } finally {
      console.log = original;
    }
    assert.equal(second.created, false);
    assert.equal(second.task.id, first.task.id);
    assert.equal(second.task.slots.origin, "Lisbon");
    assert.match(second.task.slots.dates, /October/i);
    assert.equal(second.task.status, TASK_STATUS.QUEUED);
    assert.equal(calls.length, 2, "the answer read and the continuation read both ran");
    assert.ok(
      logs.some((line) => line.startsWith("  jev dialogue: role=answer (0.82) continues=0.05 (")),
      `expected a jev dialogue line, got: ${logs.join(" | ")}`
    );
  });
});

test("a confident new_subject read falls through and starts its own task", async () => {
  await withService(async (service) => {
    const first = await service.handleMessage({
      brand: "orion",
      conversationId: "d-new",
      message: "Find me a flight to São Paulo",
    });
    assert.equal(first.task.status, TASK_STATUS.NEEDS_INPUT);

    const { impl } = jevStub({
      role: { choice: "new_subject", confidence: 0.86 },
      supplies_detail: { noul: 0.05 },
      continues: { noul: 0.1 },
    });
    const second = await withFetchStub(impl, () =>
      service.handleMessage({ brand: "orion", conversationId: "d-new", message: "find me a flight to Paris" })
    );
    assert.equal(second.created, true);
    assert.notEqual(second.task.id, first.task.id);
    assert.equal(second.task.kind, "travel");
    assert.equal(second.task.slots.destination, "Paris");
    // The waiting task was not answered — and not silently rewritten either.
    assert.equal(first.task.status, TASK_STATUS.NEEDS_INPUT);
    assert.deepEqual(first.task.missing.sort(), ["dates", "origin"]);
  });
});

test("a new_subject read still answers when the message itself carries the detail", async () => {
  await withService(async (service) => {
    const first = await service.handleMessage({
      brand: "orion",
      conversationId: "d-carry",
      message: "Find me a flight to São Paulo",
    });
    const { impl } = jevStub({
      role: { choice: "new_subject", confidence: 0.9 },
      supplies_detail: { noul: 0.85 },
      continues: { noul: 0.05 },
    });
    const second = await withFetchStub(impl, () =>
      service.handleMessage({ brand: "orion", conversationId: "d-carry", message: "from Lisbon, 12-19 October" })
    );
    assert.equal(second.created, false);
    assert.equal(second.task.id, first.task.id);
    assert.equal(second.task.slots.origin, "Lisbon");
  });
});

test("a low-confidence new_subject read changes nothing: the reply still answers", async () => {
  await withService(async (service) => {
    const first = await service.handleMessage({
      brand: "orion",
      conversationId: "d-low",
      message: "Find me a flight to São Paulo",
    });
    const { impl } = jevStub({
      role: { choice: "new_subject", confidence: 0.55 },
      supplies_detail: { noul: 0.05 },
      continues: { noul: 0.05 },
    });
    const second = await withFetchStub(impl, () =>
      service.handleMessage({ brand: "orion", conversationId: "d-low", message: "from Lisbon, 12-19 October" })
    );
    assert.equal(second.created, false);
    assert.equal(second.task.id, first.task.id);
    assert.equal(second.task.slots.origin, "Lisbon");
  });
});

test("a failed read leaves the reply path exactly as today", async () => {
  await withService(async (service) => {
    const first = await service.handleMessage({
      brand: "orion",
      conversationId: "d-fail",
      message: "Find me a flight to São Paulo",
    });
    let calls = 0;
    const failing = async () => {
      calls += 1;
      throw new Error("SystemOne down");
    };
    const second = await withFetchStub(failing, () =>
      service.handleMessage({ brand: "orion", conversationId: "d-fail", message: "from Lisbon" })
    );
    assert.equal(second.created, false);
    assert.equal(second.task.id, first.task.id);
    assert.equal(second.task.slots.origin, "Lisbon");
    assert.equal(calls, 2, "both reads were attempted and failed");
  });
});

test("a confident continuation read refines the previous subject", async () => {
  await withService(async (service) => {
    const first = await service.handleMessage({
      brand: "aurea",
      conversationId: "d-cont",
      message: "Find me a restaurant in Lisbon",
    });
    assert.equal(first.task.status, TASK_STATUS.QUEUED);

    const { impl, calls } = jevStub({ continues: { noul: 0.85 } });
    const second = await withFetchStub(impl, () =>
      service.handleMessage({
        brand: "aurea",
        conversationId: "d-cont",
        message: "somewhere quieter with outdoor seating",
      })
    );
    assert.equal(second.created, false);
    assert.equal(second.continued, true);
    assert.equal(second.task.id, first.task.id);
    assert.equal(second.task.slots.refinement, "somewhere quieter with outdoor seating");
    assert.match(second.task.title, /^Somewhere quieter with outdoor seating/);
    assert.equal(calls.length, 1, "only the continuation read was needed");
  });
});

test("a low-confidence continuation read leaves the conversation unchanged", async () => {
  await withService(async (service) => {
    const first = await service.handleMessage({
      brand: "aurea",
      conversationId: "d-cont-low",
      message: "Find me a restaurant in Lisbon",
    });
    const { impl } = jevStub({ continues: { noul: 0.4 } });
    const second = await withFetchStub(impl, () =>
      service.handleMessage({
        brand: "aurea",
        conversationId: "d-cont-low",
        message: "somewhere quieter with outdoor seating",
      })
    );
    assert.equal(second, null, "with no trusted reading it is still not a task");
    assert.equal(service.get(first.task.id).slots.refinement, undefined);
  });
});

test("the money paths the app owns are never refined by the read", async () => {
  await withService(async (service) => {
    const first = await service.handleMessage({
      brand: "aurea",
      conversationId: "d-guard",
      message: "Find me a restaurant in Lisbon",
    });
    const { impl, calls } = jevStub({ continues: { noul: 0.99 } });
    for (const message of ["unsubscribe from netflix", "buy 100 dollars", "send 20 to Maria", "what is my balance"]) {
      const outcome = await withFetchStub(impl, () =>
        service.handleMessage({ brand: "aurea", conversationId: "d-guard", message })
      );
      assert.equal(outcome, null, `"${message}" must stay on the app's own path`);
      assert.equal(
        service.get(first.task.id).slots.refinement,
        undefined,
        `"${message}" must not refine the task`
      );
    }
    assert.equal(calls.length, 0, "no dialogue read may run for a money path");
  });
});
