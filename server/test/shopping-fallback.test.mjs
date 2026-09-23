import test from "node:test";
import assert from "node:assert/strict";
import { shoppingSearchFallback } from "../lib/shopping-fallback.mjs";

test("a Nike request produces only sourced product picks when the model fails", async () => {
  let query = "";
  const outcome = await shoppingSearchFallback({
    kind: "shopping", title: "Shoes", originalMessage: "I need to buy shoes Nike",
    slots: { product: "shoes", location: "Rua Aurora 120, Florianopolis" },
  }, { search: async (value) => {
    query = value;
    return { ok: true, backend: "test-search", results: [
      { title: "Nike | Loja Oficial", url: "https://www.mercadolivre.com.br/loja/nike" },
      { title: "Tênis Nike Winflo 12 Masculino - Nike", url: "https://www.nike.com.br/tenis-nike-winflo-12-masculino-097664.html" },
      { title: "Tênis Nike Vomero 17 - Loja Over", url: "https://www.lojaover.com.br/calcados/tenis-nike-vomero-17" },
      { title: "Tênis Adidas Run", url: "https://example.com/tenis-adidas-run.html" },
    ] };
  } });
  assert.ok(outcome.ok);
  assert.equal(outcome.result.options.length, 2);
  assert.equal(outcome.result.options[0].name, "Tênis Nike Winflo 12 Masculino");
  assert.deepEqual(outcome.result.options.map((option) => option.url), outcome.result.sources.map((source) => source.url));
  assert.equal(outcome.evidence.groundedCalls, 1);
  assert.match(query, /Nike/);
  assert.doesNotMatch(query, /Rua Aurora/);
});

test("no search evidence means no shopping result", async () => {
  const outcome = await shoppingSearchFallback({ title: "Shoes", originalMessage: "Buy shoes", slots: { product: "shoes" } },
    { search: async () => ({ ok: false, reason: "search unavailable" }) });
  assert.equal(outcome, null);
});

test("a flight task keeps sourced pages available when the model fails", async () => {
  const outcome = await shoppingSearchFallback({
    kind: "travel", title: "Flights to Lisbon", originalMessage: "Flights from Sao Paulo to Lisbon next week",
    slots: { origin: "Sao Paulo", destination: "Lisbon", dates: "next week" },
  }, { search: async (query) => {
    assert.match(query, /Sao Paulo Lisbon flights next week/);
    return { ok: true, backend: "test-search", results: [
      { title: "Flights to Lisbon - Airline", url: "https://airline.example/flights/lisbon" },
    ] };
  } });
  assert.equal(outcome.result.options.length, 1);
  assert.match(outcome.result.summary, /live pages/);
  assert.equal(outcome.result.options[0].url, outcome.result.sources[0].url);
});
