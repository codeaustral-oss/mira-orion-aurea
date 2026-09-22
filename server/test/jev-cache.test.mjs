/**
 * The decision cache (plan A.3): hash-keyed, bounded, expiring, and blind to
 * the text it was asked about.
 *
 * The tests pin the four properties that make a cache safe here:
 *   · identical inputs compute once, changed state computes again;
 *   · a cached decision performs no upstream call;
 *   · TTL, the LRU bound and the failure circuit breaker are real;
 *   · no entry contains the state, the digest or the message — only the hash
 *     and the typed answer (asserted by dumping every entry).
 */

import test from "node:test";
import assert from "node:assert/strict";

import {
  cached,
  cacheKey,
  remember,
  stats,
  inspect,
  reset,
  cacheEnabled,
  knownLanguage,
  rememberLanguage,
  languageContradicts,
  conversationFacts,
} from "../lib/jev-cache.mjs";
import { batchFor, cachedRoute, languageFor } from "../lib/jev-batch.mjs";

process.env.TYPESAFE_API_KEY = "test-key";

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

const ANSWER = { ok: true, answers: { wants: { choice: "research", confidence: 0.9 } }, model: "jev-test", latencyMs: 3 };

test("identical inputs compute once; a different state computes again", async () => {
  reset();
  let computes = 0;
  const compute = async () => {
    computes += 1;
    return { ...ANSWER };
  };
  const key = cacheKey({ question: "read", version: 1, state: "hello", model: "jev-test" });

  const first = await cached(key, compute);
  const second = await cached(key, compute);
  assert.equal(computes, 1, "the identical read was not computed twice");
  assert.equal(second.cached, true);
  assert.equal(first.cached, undefined);
  assert.deepEqual(second.answers, first.answers);

  const other = cacheKey({ question: "read", version: 1, state: "hello there", model: "jev-test" });
  await cached(other, compute);
  assert.equal(computes, 2, "a different state is a different decision");

  const otherVersion = cacheKey({ question: "read", version: 2, state: "hello", model: "jev-test" });
  await cached(otherVersion, compute);
  assert.equal(computes, 3, "a changed question version can never hit an old answer");

  const otherQuestion = cacheKey({ question: "route", version: 1, state: "hello", model: "jev-test" });
  await cached(otherQuestion, compute);
  assert.equal(computes, 4, "a different question can never hit an old answer");
});

test("a cache hit performs no fetch", async () => {
  reset();
  const { impl, calls } = jevStub({ wants: { choice: "research", confidence: 0.9 } });
  const first = await batchFor("How much is a flight to Lisbon?", { fetchImpl: impl });
  assert.equal(first.ok, true);
  assert.equal(calls.length, 1);

  const second = await batchFor("How much is a flight to Lisbon?", { fetchImpl: impl });
  assert.equal(second.ok, true);
  assert.equal(second.cached, true);
  assert.equal(calls.length, 1, "the second identical batch made no fetch");

  await batchFor("How much is a flight to Porto?", { fetchImpl: impl });
  assert.equal(calls.length, 2, "a different message is a different read");
});

test("the route cache is filled by the batch and served without a fetch", async () => {
  reset();
  const { impl, calls } = jevStub({
    route: { choice: "research", confidence: 0.9 },
    needs: { choice: "none", confidence: 0.9 },
    needs_live_web: { noul: 0.9 },
    wants_advice: { noul: 0.05 },
  });
  const batch = await batchFor("How much is a flight to Lisbon?", { fetchImpl: impl });
  assert.equal(calls.length, 1);
  assert.equal(batch.route.route, "research");

  const routed = await cachedRoute("How much is a flight to Lisbon?", { fetchImpl: impl });
  assert.equal(calls.length, 1, "the batch filled the route cache; no new fetch");
  assert.equal(routed.ok, true);
  assert.equal(routed.route, "research");
  assert.equal(routed.cached, true);
});

test("no stored entry contains the state, the digest or the message", async () => {
  reset();
  const secret = "DIGEST-SECRET-ALPHA-42 / message about my account";
  const key = cacheKey({ question: "read", version: 1, state: `Message: ${secret}`, model: "jev-test" });
  assert.match(key, /^[a-f0-9]{64}$/, "the key is only a hash");
  await cached(key, async () => ({ ...ANSWER }));

  const dump = JSON.stringify(inspect());
  assert.equal(dump.includes("SECRET-ALPHA-42"), false);
  assert.equal(dump.includes("about my account"), false);
  assert.equal(dump.includes("hello"), false);
  assert.ok(dump.includes("research"), "the typed answer itself is stored");
  assert.equal(inspect().length, 1);

  // The same rule for a whole batch, dialogue context included.
  const { impl } = jevStub({ wants: { choice: "research", confidence: 0.9 } });
  await batchFor(secret, {
    dialogue: { activeTitle: `Task about ${secret}`, question: secret, missing: ["origin"] },
    fetchImpl: impl,
  });
  const batchDump = JSON.stringify(inspect());
  assert.equal(batchDump.includes("SECRET-ALPHA-42"), false, "the dialogue bundle is not stored either");
  assert.equal(batchDump.includes("Task about"), false);
});

test("TTL expiry re-computes; the LRU bound evicts the oldest", async () => {
  reset();
  let computes = 0;
  const compute = async () => ({ ok: true, n: (computes += 1) });
  const key = cacheKey({ question: "read", version: 1, state: "ttl", model: "jev-test" });

  await cached(key, compute, { ttlMs: 5_000, now: 1_000 });
  await cached(key, compute, { ttlMs: 5_000, now: 5_999 });
  assert.equal(computes, 1, "inside the TTL is a hit");
  await cached(key, compute, { ttlMs: 5_000, now: 6_000 });
  assert.equal(computes, 2, "at expiry it is a miss");
  assert.ok(stats().expired >= 1);

  reset();
  let lruComputes = 0;
  for (let i = 0; i < 501; i += 1) {
    await cached(cacheKey({ question: "lru", version: 1, state: `s${i}`, model: "m" }), async () => {
      lruComputes += 1;
      return { ok: true, i };
    });
  }
  assert.equal(stats().size, 500, "the bound is enforced");
  assert.equal(stats().evictions, 1);
  await cached(cacheKey({ question: "lru", version: 1, state: "s0", model: "m" }), async () => {
    lruComputes += 1;
    return { ok: true, i: 0 };
  });
  assert.equal(lruComputes, 502, "the oldest entry was the one evicted");
});

test("a failure is negative-cached briefly, not forever", async () => {
  reset();
  let computes = 0;
  const key = cacheKey({ question: "read", version: 1, state: "down", model: "jev-test" });
  const compute = async () => {
    computes += 1;
    return { ok: false, detail: "provider down" };
  };
  const first = await cached(key, compute, { now: 1_000 });
  assert.equal(first.ok, false);
  await cached(key, compute, { now: 2_000 });
  assert.equal(computes, 1, "the failure is a circuit breaker for a moment");
  await cached(key, compute, { now: 6_001 });
  assert.equal(computes, 2, "after five seconds the provider is tried again");
});

test("MIRA_JEV_CACHE=off computes every time and stores nothing", async () => {
  reset();
  const previous = process.env.MIRA_JEV_CACHE;
  process.env.MIRA_JEV_CACHE = "off";
  try {
    assert.equal(cacheEnabled(), false);
    let computes = 0;
    const compute = async () => ({ ok: true, n: (computes += 1) });
    const key = cacheKey({ question: "read", version: 1, state: "off", model: "m" });
    await cached(key, compute);
    await cached(key, compute);
    assert.equal(computes, 2);
    assert.equal(inspect().length, 0);
    assert.equal(stats().skipped, 2);
  } finally {
    if (previous === undefined) delete process.env.MIRA_JEV_CACHE;
    else process.env.MIRA_JEV_CACHE = previous;
  }
});

test("language is read once per conversation and re-asked on a contradiction", async () => {
  reset();
  const { impl, calls } = jevStub({ language: { choice: "english", confidence: 0.9 } });

  const first = await languageFor("Find me a flight to Lisbon", {
    brand: "orion",
    conversationId: "lang-1",
    fetchImpl: impl,
  });
  assert.equal(first.language, "english");
  assert.equal(calls.length, 1, "the first turn reads the language");

  const second = await languageFor("And a hotel on Friday", {
    brand: "orion",
    conversationId: "lang-1",
    fetchImpl: impl,
  });
  assert.equal(second.source, "conversation");
  assert.equal(second.language, "english");
  assert.equal(calls.length, 1, "the second turn pays nothing");

  // A different conversation starts fresh.
  await languageFor("And a hotel on Friday", { brand: "orion", conversationId: "lang-2", fetchImpl: impl });
  assert.equal(calls.length, 2);

  // The detector does not decide the language; it decides to ask again.
  assert.equal(languageContradicts("english", "não quero isso, obrigado"), true);
  const portuguese = await languageFor("não quero isso, obrigado", {
    brand: "orion",
    conversationId: "lang-1",
    fetchImpl: impl,
  });
  assert.equal(calls.length, 3, "a contradictory language re-asks");
  assert.equal(portuguese.language, "english", "the read, not the detector, decides");

  // Facts hold only the four fields, never the message.
  const facts = conversationFacts();
  assert.ok(facts.length >= 1);
  assert.deepEqual(Object.keys(facts[0]).sort(), ["at", "confidence", "key", "language", "turns"]);
  assert.equal(JSON.stringify(facts).includes("hotel"), false);
});

test("conversation facts expire and are invalidated after ten turns", () => {
  reset();
  rememberLanguage("orion", "turn-2", "english", 0.9, { now: 1_000 });
  assert.ok(knownLanguage("orion", "turn-2", { now: 2_000 }), "fresh facts are served");
  assert.equal(conversationFacts()[0].turns, 1);
  // Ten uses exhaust the fact and the next call asks again.
  for (let i = 0; i < 9; i += 1) knownLanguage("orion", "turn-2", { now: 2_000 });
  assert.equal(knownLanguage("orion", "turn-2", { now: 2_000 }), null);
  // And a stale fact is not served either.
  rememberLanguage("orion", "turn-3", "english", 0.9, { now: 100_000 });
  assert.equal(knownLanguage("orion", "turn-3", { now: 100_000 + 30 * 60_000 + 1 }), null);
});

test("stats expose the saving, and remember() respects the switch", () => {
  reset();
  const key = cacheKey({ question: "stats", version: 1, state: "s", model: "m" });
  remember(key, { ok: true });
  assert.equal(stats().stores, 1);
  assert.equal(stats().size, 1);
  assert.equal(stats().enabled, true);
  assert.equal(stats().bound, 500);
  assert.equal(typeof stats().hits, "number");
  assert.equal(typeof stats().misses, "number");

  const previous = process.env.MIRA_JEV_CACHE;
  process.env.MIRA_JEV_CACHE = "off";
  try {
    remember(cacheKey({ question: "stats", version: 1, state: "z", model: "m" }), { ok: true });
    assert.equal(stats().size, 1, "nothing is stored while the switch is off");
    assert.equal(stats().stores, 1, "the disabled store was not counted either");
  } finally {
    if (previous === undefined) delete process.env.MIRA_JEV_CACHE;
    else process.env.MIRA_JEV_CACHE = previous;
  }
});
