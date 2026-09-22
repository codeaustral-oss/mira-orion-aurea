import test from "node:test";
import assert from "node:assert/strict";

import { readConsent, decideConsent, READ_FLOOR } from "../lib/jev-consent.mjs";

process.env.TYPESAFE_API_KEY = "test-key";

function jevStub(answers) {
  const calls = [];
  const impl = async (url, init) => {
    calls.push({ url: String(url), body: JSON.parse(init.body) });
    return {
      ok: true,
      status: 200,
      headers: new Headers({ "content-type": "application/json" }),
      json: async () => ({ answers, model: "jev-test" }),
    };
  };
  return { impl, calls };
}

test("the read asks for an authorisation, a supplied detail, what is missing and the risk", async () => {
  const { impl, calls } = jevStub({
    authorises: { noul: 0.9 },
    supplies_detail: { noul: 0.2 },
    missing: { choice: "none", confidence: 0.9 },
    risk: { choice: "low", confidence: 0.8 },
  });
  const read = await readConsent("buy it now", {
    action: "checkout",
    known: { address: "Florianopolis, Brazil", card: "ending 2809" },
    fetchImpl: impl,
  });
  assert.equal(read.ok, true);
  assert.equal(read.authorises, 0.9);
  assert.equal(read.missing, "none");
  assert.equal(read.risk, "low");
  const state = calls[0].body.state;
  assert.match(state, /Already known to the app/);
  assert.match(state, /Florianopolis, Brazil/);
  assert.ok(calls[0].body.questions.authorises);
  assert.ok(calls[0].body.questions.risk);
});

test("an explicit authorisation proceeds; a plain purchase intent gets one confirmation", () => {
  const authorised = { ok: true, authorises: 0.92, suppliesDetail: 0.1, missing: "none", risk: "low" };
  const intent = { ok: true, authorises: 0.1, suppliesDetail: 0.1, missing: "none", risk: "low" };
  assert.equal(decideConsent(authorised, { known: {} }).decision, "proceed");
  assert.equal(decideConsent(intent, { known: {} }).decision, "confirm");
});

test("a detail the app already holds is never asked for", () => {
  const read = { ok: true, authorises: 0.2, suppliesDetail: 0.1, missing: "address", risk: "low" };
  // The app has the address: nothing to ask.
  assert.equal(decideConsent(read, { known: { address: "Lisbon" } }).decision, "confirm");
  // It does not have one: ask, exactly that.
  const asked = decideConsent(read, { known: {} });
  assert.equal(asked.decision, "ask");
  assert.equal(asked.detail, "address");
});

test("a detail supplied in the message is not asked for either", () => {
  const read = { ok: true, authorises: 0.1, suppliesDetail: 0.85, missing: "address", risk: "low" };
  assert.equal(decideConsent(read, { known: {} }).decision, "confirm");
});

test("high risk always stops for a person, however the message reads", () => {
  const read = { ok: true, authorises: 0.99, suppliesDetail: 0.9, missing: "none", risk: "high" };
  assert.equal(decideConsent(read, { known: {} }).decision, "confirm");
});

test("a failed read is never an authorisation", () => {
  assert.equal(decideConsent({ ok: false }, { known: {} }).decision, "confirm");
  assert.equal(decideConsent(null, { known: {} }).decision, "confirm");
});

test("the floor is a real number so callers can reason about it", () => {
  assert.ok(READ_FLOOR > 0 && READ_FLOOR < 1);
});
