import test from "node:test";
import assert from "node:assert/strict";

import { extractPage, extractProvider, extractConfigured, imagesInText } from "../lib/extract.mjs";

function jsonResponse(body, { status = 200 } = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: new Headers({ "content-type": "application/json" }),
    json: async () => body,
  };
}

function withKey(name, value, fn) {
  return async () => {
    const previous = process.env[name];
    process.env[name] = value;
    try {
      await fn();
    } finally {
      if (previous === undefined) delete process.env[name];
      else process.env[name] = previous;
    }
  };
}

test("no key means no reading, and it says so", () => {
  const previous = { t: process.env.TAVILY_API_KEY, f: process.env.FIRECRAWL_API_KEY, e: process.env.EXA_API_KEY };
  delete process.env.TAVILY_API_KEY;
  delete process.env.FIRECRAWL_API_KEY;
  delete process.env.EXA_API_KEY;
  assert.equal(extractConfigured(), false);
  assert.equal(extractProvider(), null);
  if (previous.t !== undefined) process.env.TAVILY_API_KEY = previous.t;
});

test("tavily reads a blocked page and brings its images", withKey("TAVILY_API_KEY", "k", async () => {
  let seen = null;
  const fetchImpl = async (url, init) => {
    seen = { url: String(url), body: JSON.parse(init.body) };
    return jsonResponse({
      results: [{ url: "https://www.ifood.com.br/x", raw_content: "Feijoada — R$ 39,90", images: ["https://static-images.ifood.com.br/a.jpg"] }],
    });
  };
  const result = await extractPage("https://www.ifood.com.br/x", { fetchImpl });
  assert.equal(result.ok, true);
  assert.equal(result.source, "tavily");
  assert.match(result.text, /Feijoada/);
  assert.deepEqual(result.images, ["https://static-images.ifood.com.br/a.jpg"]);
  assert.equal(seen.body.urls[0], "https://www.ifood.com.br/x");
}));

test("firecrawl returns markdown and the page's own og:image", withKey("FIRECRAWL_API_KEY", "k", async () => {
  const fetchImpl = async () =>
    jsonResponse({ data: { markdown: "Current bid: USD 210", metadata: { ogImage: "https://i.ebayimg.com/x.jpg" } } });
  const result = await extractPage("https://www.ebay.com/itm/1", { fetchImpl });
  assert.equal(result.source, "firecrawl");
  assert.match(result.text, /Current bid/);
  assert.deepEqual(result.images, ["https://i.ebayimg.com/x.jpg"]);
}));

test("exa returns the page text", withKey("EXA_API_KEY", "k", async () => {
  const fetchImpl = async () => jsonResponse({ results: [{ text: "Only 3 left in stock." }] });
  const result = await extractPage("https://www.amazon.com/dp/1", { fetchImpl });
  assert.equal(result.source, "exa");
  assert.match(result.text, /Only 3 left/);
}));

test("a provider that fails is a failure, never a guess", withKey("TAVILY_API_KEY", "k", async () => {
  const refused = await extractPage("https://www.ifood.com.br/x", {
    fetchImpl: async () => jsonResponse({}, { status: 403 }),
  });
  assert.equal(refused.ok, false);
  assert.match(refused.detail, /403/);
}));

test("images are found in extracted text when the provider returns none", () => {
  const text = "See ![dish](https://cdn.example/dish.png) and https://cdn.example/other.jpg?w=600";
  const images = imagesInText(text);
  assert.ok(images.includes("https://cdn.example/dish.png"));
  assert.ok(images.some((url) => url.startsWith("https://cdn.example/other.jpg")));
});
