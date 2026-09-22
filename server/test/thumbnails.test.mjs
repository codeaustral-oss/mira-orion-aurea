import test from "node:test";
import assert from "node:assert/strict";

import {
  absoluteImageUrl,
  imageFromHtml,
  imageFor,
  enrichOptions,
  searchImage,
  clearThumbnailCache,
} from "../lib/thumbnails.mjs";

function htmlResponse(html, { url = "https://shop.example/p/1", status = 200 } = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    url,
    headers: new Headers({ "content-type": "text/html; charset=utf-8" }),
    text: async () => html,
    body: null,
  };
}

test("og:image is read from the page's own metadata", () => {
  const html = `<html><head>
    <meta property="og:image" content="https://cdn.shop.example/shoe.jpg" />
    </head><body></body></html>`;
  assert.equal(imageFromHtml(html, "https://shop.example/p/1"), "https://cdn.shop.example/shoe.jpg");
});

test("twitter:image is the fallback when og:image is absent", () => {
  const html = `<head><meta name="twitter:image" content="https://cdn.shop.example/shoe.png"></head>`;
  assert.equal(imageFromHtml(html, "https://shop.example/p/1"), "https://cdn.shop.example/shoe.png");
});

test("a relative image is resolved against the page", () => {
  const html = `<head><meta property="og:image" content="/media/shoe.jpg"></head>`;
  assert.equal(imageFromHtml(html, "https://shop.example/p/1"), "https://shop.example/media/shoe.jpg");
});

test("attribute order does not matter", () => {
  const html = `<head><meta content="https://cdn.shop.example/a.jpg" property="og:image"></head>`;
  assert.equal(imageFromHtml(html, "https://shop.example/p/1"), "https://cdn.shop.example/a.jpg");
});

test("an http image is upgraded, a data URI and a nonsense value are refused", () => {
  assert.equal(absoluteImageUrl("http://cdn.shop.example/a.jpg", "https://shop.example"), "https://cdn.shop.example/a.jpg");
  assert.equal(absoluteImageUrl("data:image/png;base64,AAAA", "https://shop.example"), null);
  assert.equal(absoluteImageUrl("javascript:alert(1)", "https://shop.example"), null);
  assert.equal(absoluteImageUrl("", "https://shop.example"), null);
});

test("a page with no image metadata yields no image", () => {
  assert.equal(imageFromHtml("<html><body><p>hello</p></body></html>", "https://shop.example"), null);
});

test("imageFor reads the page once and then serves from cache", async () => {
  clearThumbnailCache();
  let calls = 0;
  const fetchImpl = async () => {
    calls += 1;
    return htmlResponse(`<head><meta property="og:image" content="https://cdn.shop.example/shoe.jpg"></head>`);
  };
  const first = await imageFor("https://shop.example/p/1", { fetchImpl });
  const second = await imageFor("https://shop.example/p/1", { fetchImpl });
  assert.equal(first, "https://cdn.shop.example/shoe.jpg");
  assert.equal(second, first);
  assert.equal(calls, 1);
});

test("a page that fails leaves no image and does not throw", async () => {
  clearThumbnailCache();
  const failed = await imageFor("https://shop.example/down", {
    fetchImpl: async () => {
      throw new Error("connection refused");
    },
  });
  assert.equal(failed, null);

  const refused = await imageFor("https://shop.example/403", {
    fetchImpl: async () => htmlResponse("", { status: 403 }),
  });
  assert.equal(refused, null);
});

test("enrichOptions fills what it can and leaves the rest exactly as they were", async () => {
  clearThumbnailCache();
  const options = [
    { name: "Shoe A", url: "https://a.example/p", why: "", priceNote: null, image: null },
    { name: "Shoe B", url: "https://b.example/p", why: "", priceNote: null, image: null },
    { name: "Already has one", url: "https://c.example/p", why: "", priceNote: null, image: "https://cdn.example/c.jpg" },
    { name: "No link", url: null, why: "", priceNote: null, image: null },
  ];
  const fetchImpl = async (url) => {
    if (String(url).includes("a.example")) {
      return htmlResponse(`<head><meta property="og:image" content="https://cdn.example/a.jpg"></head>`, { url });
    }
    return htmlResponse("<html><body>no picture here</body></html>", { url });
  };
  const enriched = await enrichOptions(options, { fetchImpl });
  assert.equal(enriched[0].image, "https://cdn.example/a.jpg");
  assert.equal(enriched[1].image, null);
  assert.equal(enriched[2].image, "https://cdn.example/c.jpg");
  assert.equal(enriched[3].image, null);
  // The originals are not mutated: the caller decides what to store.
  assert.equal(options[0].image, null);
});

// ── Image search fallback ────────────────────────────────────────────────────
//
// The platform pages that refuse a server fetch (iFood and other marketplaces)
// still need a face on the pick. The fallback is a keyless image search for the
// option itself, with the task's own location or subject as context.

function ddgStub({ image = "https://cdn.example/dish.jpg", width = 640, height = 480, token = "4-1234567890" } = {}) {
  const calls = [];
  const impl = async (url) => {
    calls.push(String(url));
    if (String(url).includes("ia=images")) {
      return {
        ok: true,
        status: 200,
        headers: new Headers({ "content-type": "text/html" }),
        text: async () => `<html><body><script>vqd="${token}"</script></body></html>`,
        body: null,
      };
    }
    if (String(url).includes("/i.js")) {
      return {
        ok: true,
        status: 200,
        url: String(url),
        headers: new Headers({ "content-type": "application/json" }),
        json: async () => ({ results: [{ image, width, height }] }),
        text: async () => JSON.stringify({ results: [{ image, width, height }] }),
        body: null,
      };
    }
    return { ok: false, status: 404, headers: new Headers({}), text: async () => "", body: null };
  };
  return { impl, calls };
}

test("a refused page still gets a picture, found by name and context", async () => {
  clearThumbnailCache();
  const { impl, calls } = ddgStub();
  const options = [
    { name: "Parmegiana — Almoço Supreme", url: "https://www.ifood.com.br/dish/1", why: "", priceNote: null, image: null },
  ];
  const fetchImpl = async (url, init) => {
    // The ifood page itself refuses, as the real one does.
    if (String(url).includes("ifood.com.br")) return { ok: false, status: 403, headers: new Headers({}), text: async () => "", body: null };
    return impl(url, init);
  };
  const enriched = await enrichOptions(options, { fetchImpl, context: "Canasvieiras" });
  assert.equal(enriched[0].image, "https://cdn.example/dish.jpg");
  const search = calls.find((url) => url.includes("/i.js"));
  assert.ok(search, "an image search was made");
  assert.match(decodeURIComponent(search), /Parmegiana — Almoço Supreme Canasvieiras/);
});

test("image search refuses sprites and tiny pictures, and survives a bad token", async () => {
  clearThumbnailCache();
  const options = [{ name: "Feijoada", url: null, why: "", priceNote: null, image: null }];

  const tiny = ddgStub({ image: "https://cdn.example/sprite.png", width: 32, height: 32 });
  const enriched = await enrichOptions(options, { fetchImpl: tiny.impl, context: "Lisbon" });
  assert.equal(enriched[0].image, null);

  clearThumbnailCache();
  const noToken = async (url) => ({
    ok: true,
    status: 200,
    headers: new Headers({ "content-type": "text/html" }),
    text: async () => "<html>no token here</html>",
    body: null,
  });
  const failed = await enrichOptions(options, { fetchImpl: noToken, context: "Lisbon" });
  assert.equal(failed[0].image, null);
});

test("an image search is cached: one query, one fetch", async () => {
  clearThumbnailCache();
  const { impl, calls } = ddgStub();
  const first = await searchImage("Brooks Ghost 15", { fetchImpl: impl });
  const second = await searchImage("Brooks Ghost 15", { fetchImpl: impl });
  assert.equal(first, "https://cdn.example/dish.jpg");
  assert.equal(second, first);
  assert.equal(calls.length, 2); // the token page + the results, once
});

test("a page that refuses a fetch still gets a picture when an extractor is configured", async () => {
  clearThumbnailCache();
  const previous = process.env.TAVILY_API_KEY;
  process.env.TAVILY_API_KEY = "test-key";
  try {
    const options = [
      { name: "Feijoada — Bolinha", url: "https://www.ifood.com.br/dish/1", why: "", priceNote: null, image: null },
    ];
    const fetchImpl = async (url, init) => {
      const target = String(url);
      // The iFood page refuses the server, as the real one does …
      if (target.includes("ifood.com.br")) {
        return { ok: false, status: 403, headers: new Headers({}), text: async () => "", body: null };
      }
      // … and the extractor reads it from their side instead.
      if (target.includes("api.tavily.com")) {
        return {
          ok: true,
          status: 200,
          headers: new Headers({ "content-type": "application/json" }),
          json: async () => ({
            results: [{ raw_content: "Feijoada", images: ["https://static-images.ifood.com.br/dish.jpg"] }],
          }),
        };
      }
      throw new Error(`unexpected fetch ${target}`);
    };
    const enriched = await enrichOptions(options, { fetchImpl, context: "Florianopolis" });
    assert.equal(enriched[0].image, "https://static-images.ifood.com.br/dish.jpg");
  } finally {
    if (previous === undefined) delete process.env.TAVILY_API_KEY;
    else process.env.TAVILY_API_KEY = previous;
  }
});
