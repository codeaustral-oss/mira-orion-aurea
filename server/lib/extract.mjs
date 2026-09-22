/**
 * Reading pages that refuse to be read.
 *
 * iFood, Amazon, eBay and most marketplaces answer a server fetch with 403 —
 * so a price, a stock state or a lot's current bid stays invisible however good
 * the agent is. A hosted extractor solves exactly that: it fetches the page
 * from their own infrastructure and hands back its text.
 *
 * Three providers, whichever key is present, and no key means no reading: a
 * failed extraction is a failure, never a guess. Keys live in `.env` and are
 * passed to the agent runtime as well, so its own `web_extract` tool can use
 * the same provider.
 */

const TIMEOUT_MS = 12_000;

/** Which extractor is configured, if any. */
export function extractProvider() {
  if (process.env.TAVILY_API_KEY) return "tavily";
  if (process.env.FIRECRAWL_API_KEY) return "firecrawl";
  if (process.env.EXA_API_KEY) return "exa";
  return null;
}

export function extractConfigured() {
  return extractProvider() !== null;
}

async function timedFetch(fetchImpl, url, options, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(1000, timeoutMs));
  try {
    return await fetchImpl(url, { ...options, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

/** Any image URLs inside extracted text: markdown images, then bare URLs. */
export function imagesInText(text) {
  const value = String(text || "");
  const found = [];
  for (const match of value.matchAll(/!\[[^\]]*\]\((https?:\/\/[^)\s]+)\)/g)) found.push(match[1]);
  for (const match of value.matchAll(/(https?:\/\/[^\s)"']+\.(?:jpe?g|png|webp)(?:\?[^\s)"']*)?)/gi)) {
    found.push(match[1]);
  }
  return [...new Set(found)];
}

/**
 * @returns {Promise<{ok:boolean, text?:string, images?:string[], source?:string, detail?:string}>}
 */
export async function extractPage(
  url,
  { fetchImpl = globalThis.fetch, timeoutMs = TIMEOUT_MS, provider = extractProvider() } = {}
) {
  const target = String(url || "").trim();
  if (!/^https?:\/\//i.test(target)) return { ok: false, detail: "Only http(s) pages can be read." };
  if (!provider) {
    return {
      ok: false,
      detail: "No extract provider configured (TAVILY_API_KEY, FIRECRAWL_API_KEY or EXA_API_KEY).",
    };
  }

  try {
    if (provider === "tavily") {
      const response = await timedFetch(
        fetchImpl,
        "https://api.tavily.com/extract",
        {
          method: "POST",
          headers: {
            "content-type": "application/json",
            authorization: `Bearer ${process.env.TAVILY_API_KEY}`,
          },
          body: JSON.stringify({ urls: [target], include_images: true }),
        },
        timeoutMs
      );
      if (!response.ok) return { ok: false, detail: `Tavily answered ${response.status}.`, source: "tavily" };
      const data = await response.json().catch(() => null);
      const first = data?.results?.[0];
      const text = String(first?.raw_content || "");
      const images = Array.isArray(first?.images)
        ? first.images.filter((candidate) => typeof candidate === "string")
        : [];
      return { ok: Boolean(text || images.length), text, images, source: "tavily" };
    }

    if (provider === "firecrawl") {
      const response = await timedFetch(
        fetchImpl,
        "https://api.firecrawl.dev/v1/scrape",
        {
          method: "POST",
          headers: {
            "content-type": "application/json",
            authorization: `Bearer ${process.env.FIRECRAWL_API_KEY}`,
          },
          body: JSON.stringify({ url: target, formats: ["markdown"], onlyMainContent: true }),
        },
        timeoutMs
      );
      if (!response.ok) return { ok: false, detail: `Firecrawl answered ${response.status}.`, source: "firecrawl" };
      const data = await response.json().catch(() => null);
      const text = String(data?.data?.markdown || "");
      const ogImage = data?.data?.metadata?.ogImage;
      const images = typeof ogImage === "string" && ogImage ? [ogImage] : [];
      return { ok: Boolean(text || images.length), text, images, source: "firecrawl" };
    }

    // exa
    const response = await timedFetch(
      fetchImpl,
      "https://api.exa.ai/contents",
      {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-api-key": process.env.EXA_API_KEY,
        },
        body: JSON.stringify({ ids: [target], text: true }),
      },
      timeoutMs
    );
    if (!response.ok) return { ok: false, detail: `Exa answered ${response.status}.`, source: "exa" };
    const data = await response.json().catch(() => null);
    const text = String(data?.results?.[0]?.text || "");
    return { ok: Boolean(text), text, images: [], source: "exa" };
  } catch (err) {
    return {
      ok: false,
      detail: `The extract provider failed: ${err?.message || err}`,
      source: provider,
    };
  }
}
