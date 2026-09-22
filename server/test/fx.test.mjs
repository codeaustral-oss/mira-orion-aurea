import test from "node:test";
import assert from "node:assert/strict";

import { liveRates, clearRateCache } from "../lib/fx.mjs";

function jsonResponse(body, { status = 200 } = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: new Headers({ "content-type": "application/json" }),
    json: async () => body,
  };
}

test("rates come from the first source that answers, with a timestamp", async () => {
  clearRateCache();
  const fetchImpl = async (url) => {
    if (String(url).includes("coinbase")) {
      return jsonResponse({ data: { rates: { EUR: "0.87", BRL: "5.14", USDC: "1", USDT: "1.0003" } } });
    }
    throw new Error("should not be reached");
  };
  const rates = await liveRates({ fetchImpl, now: 1_000 });
  assert.equal(rates.ok, true);
  assert.equal(rates.source, "coinbase");
  assert.equal(rates.perUSD.EUR, 0.87);
  assert.equal(rates.perUSD.BRL, 5.14);
  assert.equal(rates.perUSD.USD, 1);
  assert.equal(rates.perUSD.USDC, 1);
  assert.ok(rates.asOf > 0);
  assert.equal(rates.cached, false);
});

test("the second source is used when the first fails, and stablecoins default to par", async () => {
  clearRateCache();
  const fetchImpl = async (url) => {
    if (String(url).includes("coinbase")) return jsonResponse({}, { status: 500 });
    return jsonResponse({ rates: { EUR: 0.9, BRL: 5.2 } });
  };
  const rates = await liveRates({ fetchImpl, now: 1_000 });
  assert.equal(rates.ok, true);
  assert.equal(rates.source, "open.er-api.com");
  assert.equal(rates.perUSD.EUR, 0.9);
  assert.equal(rates.perUSD.USDT, 0.9998);
});

test("a minute of cache means one fetch, not one per message", async () => {
  clearRateCache();
  let calls = 0;
  const fetchImpl = async () => {
    calls += 1;
    return jsonResponse({ data: { rates: { EUR: "0.87", BRL: "5.14" } } });
  };
  await liveRates({ fetchImpl, now: 1_000 });
  const second = await liveRates({ fetchImpl, now: 30_000 });
  assert.equal(calls, 1);
  assert.equal(second.cached, true);

  await liveRates({ fetchImpl, now: 90_000 });
  assert.equal(calls, 2);
});

test("no source answering is a failure, never a number", async () => {
  clearRateCache();
  const rates = await liveRates({
    fetchImpl: async () => {
      throw new Error("offline");
    },
    now: 1_000,
  });
  assert.equal(rates.ok, false);
  assert.equal(rates.perUSD, undefined);
  assert.match(rates.detail, /no live rate source/i);
});
