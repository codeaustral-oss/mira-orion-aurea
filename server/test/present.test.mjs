import test from "node:test";
import assert from "node:assert/strict";

import { defaultLayout, chooseLayout, readPresentation, LAYOUTS } from "../lib/jev-present.mjs";

test("the shape of the result decides the layout when nothing else can", () => {
  assert.equal(defaultLayout({ kind: "travel", slots: { destination: "Lisbon" } }), "itinerary");
  assert.equal(defaultLayout({ kind: "travel", slots: {} }), "plain");
  assert.equal(defaultLayout({ kind: "restaurant", slots: { location: "Lisbon", partySize: "2" } }), "reservation");
  // A delivered meal is a list of dishes, never a reservation.
  assert.equal(defaultLayout({ kind: "restaurant", slots: { location: "Canasvieiras", mode: "delivery" } }), "picks");
  assert.equal(defaultLayout({ kind: "shopping", slots: { product: "shoes" } }), "picks");
  assert.equal(defaultLayout({ kind: "watch", slots: { subject: "price" } }), "watch");
});

test("a usable reading wins; an unusable one falls back to the shape", () => {
  const context = { kind: "travel", slots: { destination: "Lisbon" } };
  assert.equal(chooseLayout({ ok: true, layout: "picks", confidence: 0.9 }, context), "picks");
  assert.equal(chooseLayout({ ok: true, layout: "receipt", confidence: 0.9 }, context), "itinerary");
  assert.equal(chooseLayout({ ok: true, layout: "picks", confidence: 0.2 }, context), "itinerary");
  assert.equal(chooseLayout({ ok: false }, context), "itinerary");
  assert.equal(chooseLayout(null, context), "itinerary");
  assert.ok(LAYOUTS.includes("itinerary"));
});

test("the read asks what the result is, and quotes the result", async () => {
  process.env.TYPESAFE_API_KEY = "test-key";
  let seen = null;
  const fetchImpl = async (url, init) => {
    seen = JSON.parse(init.body);
    return {
      ok: true,
      status: 200,
      headers: new Headers({ "content-type": "application/json" }),
      json: async () => ({ answers: { layout: { choice: "itinerary", confidence: 0.93 } }, model: "jev-test" }),
    };
  };
  const read = await readPresentation(
    { kind: "research", title: "Trip to Lisbon", summary: "A route with dates.", options: [{ name: "TAP" }], slots: { destination: "Lisbon" } },
    { fetchImpl }
  );
  assert.equal(read.ok, true);
  assert.equal(read.layout, "itinerary");
  assert.match(seen.state, /Capability: research/);
  assert.match(seen.state, /TAP/);
  assert.ok(seen.questions.layout);
  assert.equal(chooseLayout(read, { kind: "research", slots: {} }), "itinerary");
});

test("an invest result with a size is an order", () => {
  assert.equal(defaultLayout({ kind: "invest", slots: { symbol: "NVDA", quantity: "10 shares" } }), "order");
  assert.equal(defaultLayout({ kind: "invest", slots: { symbol: "AAPL", amount: "USD 1000" } }), "order");
  // A ticker alone is still an order being prepared — the size can follow.
  assert.equal(defaultLayout({ kind: "invest", slots: { symbol: "AAPL" } }), "order");
});
