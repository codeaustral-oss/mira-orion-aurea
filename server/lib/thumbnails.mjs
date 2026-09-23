/**
 * A pick with a face on it.
 *
 * Research results are read on a phone, and a list of store names reads slower
 * than the same list with the product in front of it. Every option the agent
 * returns gets a real image when the page offers one: the `og:image` / Twitter
 * card the site itself publishes for sharing, which is exactly the picture a
 * person would see if the link were pasted into a message.
 *
 * This runs on the server, deterministically, after the agent has answered:
 * no model is asked for an image URL, because a model can invent one. It reads
 * the page's own metadata, bounded to a couple of seconds and a couple of
 * hundred kilobytes per page, and a page that blocks or hides its images simply
 * produces no thumbnail rather than a guess.
 *
 * Nothing here is required for a result to be correct: an option without an
 * image is still a finished option.
 */

import { extractPage, extractConfigured, imagesInText } from "./extract.mjs";

const USER_AGENT =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";

/** Pages are big; images live in the head. Read a slice, not the whole page. */
const MAX_BYTES = 300_000;

/** Few enough to stay polite, large enough for a full result set. */
const MAX_OPTIONS = 8;

const IMAGE_KEYS = new Set([
  "og:image",
  "og:image:url",
  "og:image:secure_url",
  "twitter:image",
  "twitter:image:src",
]);

/** Page URL → image URL (or null when the page had none). */
const cache = new Map();
const CACHE_LIMIT = 300;

/** One image search at a time: image backends rate-limit bursts, and a task is
 * never in a hurry for a thumbnail. */
let searchChain = Promise.resolve();
function serialised(work) {
  const run = searchChain.then(work, work);
  searchChain = run.then(
    () => undefined,
    () => undefined
  );
  return run;
}

const SEARCH_UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36";

function cacheGet(url) {
  if (!cache.has(url)) return undefined;
  const value = cache.get(url);
  // Refresh insertion order so the limit evicts the coldest entries.
  cache.delete(url);
  cache.set(url, value);
  return value;
}

function cacheSet(url, value) {
  cache.set(url, value);
  if (cache.size > CACHE_LIMIT) {
    const oldest = cache.keys().next().value;
    cache.delete(oldest);
  }
}

/** Parse the attributes of one tag, quote-style agnostic. */
function attributesOf(tag) {
  const attrs = {};
  const pattern = /([a-zA-Z:_-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/g;
  let match;
  while ((match = pattern.exec(tag)) !== null) {
    attrs[match[1].toLowerCase()] = match[2] ?? match[3] ?? match[4] ?? "";
  }
  return attrs;
}

/** Turn whatever the page wrote into an absolute https URL, or null. */
export function absoluteImageUrl(raw, pageUrl) {
  const value = String(raw || "").trim();
  if (!value || value.startsWith("data:")) return null;
  try {
    const url = new URL(value, pageUrl);
    if (url.protocol !== "http:" && url.protocol !== "https:") return null;
    // The app talks https only; a CDN that only serves http is not worth a
    // broken image frame, and most upgrade cleanly.
    url.protocol = "https:";
    return url.toString();
  } catch {
    return null;
  }
}

/**
 * The image the page publishes for itself, from its own metadata.
 *
 * @param {string} html
 * @param {string} pageUrl  the page the HTML came from, for relative sources
 * @returns {string|null}   absolute https URL
 */
export function imageFromHtml(html, pageUrl) {
  const value = String(html || "").slice(0, MAX_BYTES);

  for (const match of value.match(/<meta\b[^>]*>/gi) || []) {
    const attrs = attributesOf(match);
    const key = (attrs.property || attrs.name || "").toLowerCase();
    if (!IMAGE_KEYS.has(key) || !attrs.content) continue;
    const image = absoluteImageUrl(attrs.content, pageUrl);
    if (usablePhoto(image, 0, 0)) return image;
  }

  for (const match of value.match(/<link\b[^>]*>/gi) || []) {
    const attrs = attributesOf(match);
    if ((attrs.rel || "").toLowerCase() !== "image_src" || !attrs.href) continue;
    const image = absoluteImageUrl(attrs.href, pageUrl);
    if (usablePhoto(image, 0, 0)) return image;
  }

  return null;
}

/** Read at most `cap` bytes of the response body, then stop. */
async function readCapped(response, cap = MAX_BYTES) {
  if (!response.body || typeof response.body.getReader !== "function") {
    const text = await response.text();
    return text.slice(0, cap);
  }
  const reader = response.body.getReader();
  const chunks = [];
  let received = 0;
  try {
    while (received < cap) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      received += value.length;
    }
  } finally {
    reader.cancel().catch(() => {});
  }
  const merged = new Uint8Array(Math.min(received, cap));
  let offset = 0;
  for (const chunk of chunks) {
    if (offset >= merged.length) break;
    const slice = chunk.subarray(0, Math.max(0, merged.length - offset));
    merged.set(slice, offset);
    offset += slice.length;
  }
  return new TextDecoder("utf-8", { fatal: false }).decode(merged);
}

/**
 * @param {string} pageUrl
 * @param {object} [options]
 * @returns {Promise<string|null>}
 */
export async function imageFor(pageUrl, { fetchImpl = globalThis.fetch, timeoutMs = 2300 } = {}) {
  const url = absoluteImageUrl(pageUrl, pageUrl);
  if (!url) return null;
  const cached = cacheGet(url);
  if (cached !== undefined) return cached;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(url, {
      signal: controller.signal,
      redirect: "follow",
      headers: { "user-agent": USER_AGENT, accept: "text/html,application/xhtml+xml" },
    });
    if (!response.ok) {
      // The page refused a server fetch — which is what marketplaces do. A
      // configured extractor reads it from their side instead.
      const extracted = await fromExtractor(url, { fetchImpl, timeoutMs });
      cacheSet(url, extracted);
      return extracted;
    }
    const contentType = response.headers.get("content-type") || "";
    if (contentType && !/text\/html|application\/xhtml/i.test(contentType)) {
      cacheSet(url, null);
      return null;
    }
    const html = await readCapped(response);
    const image = imageFromHtml(html, response.url || url);
    if (image) {
      cacheSet(url, image);
      return image;
    }
    const extracted = await fromExtractor(url, { fetchImpl, timeoutMs });
    cacheSet(url, extracted);
    return extracted;
  } catch {
    // A timeout, a block, a bad certificate: no thumbnail, no failure.
    cacheSet(url, null);
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/// A page the app cannot fetch itself, read through the configured extractor.
/// The picture it returns is one the page really shows, and nothing is invented
/// when no extractor is configured.
async function fromExtractor(url, { fetchImpl, timeoutMs }) {
  if (!extractConfigured()) return null;
  try {
    const extracted = await extractPage(url, { fetchImpl, timeoutMs: Math.max(timeoutMs, 8000) });
    if (!extracted.ok) return null;
    for (const candidate of extracted.images ?? []) {
      const image = absoluteImageUrl(candidate, url);
      if (image && usablePhoto(image, 0, 0)) return image;
    }
    for (const candidate of imagesInText(extracted.text)) {
      const image = absoluteImageUrl(candidate, url);
      if (image && usablePhoto(image, 0, 0)) return image;
    }
  } catch {
    /* no picture, no failure */
  }
  return null;
}

/** Fetch with a hard deadline; the timer always clears. */
async function timedFetch(fetchImpl, url, { headers, timeoutMs }) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(500, timeoutMs));
  try {
    return await fetchImpl(url, { signal: controller.signal, redirect: "follow", headers });
  } finally {
    clearTimeout(timer);
  }
}

/** The per-query token the image endpoint requires. */
async function imageSearchToken(query, { fetchImpl, timeoutMs }) {
  const page = await timedFetch(
    fetchImpl,
    `https://duckduckgo.com/?q=${encodeURIComponent(query)}&iax=images&ia=images`,
    { headers: { "user-agent": SEARCH_UA }, timeoutMs }
  );
  if (!page.ok) return null;
  const html = await page.text();
  const match = /vqd=["']?([\d-]+)/.exec(html);
  return match ? match[1] : null;
}

/** A picture worth showing: a real photo, not a sprite or a badge. */
function usablePhoto(image, width, height) {
  if (!image) return false;
  if (/\.svg($|\?)/i.test(image)) return false;
  // Site icons and wordmarks are not pictures of the product. Nike's running
  // hub, for example, advertises android-icon-192x192.png as its share image.
  if (/(?:^|[\/_-])(?:android-icon|apple-touch-icon|favicon|logo|brandmark|wordmark|sprite)(?:[._/-]|$)/i.test(new URL(image).pathname)) return false;
  const w = Number(width) || 0;
  const h = Number(height) || 0;
  if (w && w < 240) return false;
  if (h && h < 160) return false;
  return true;
}

/**
 * A picture of the thing itself, when the page would not give us one.
 *
 * Keyless: the image endpoint needs a per-query token that the public search
 * page hands out. Nothing is invented — the URL is one an image index really
 * returned for the exact name — and a failure is simply no picture.
 */
export async function searchImage(query, { fetchImpl = globalThis.fetch, timeoutMs = 2500 } = {}) {
  const q = String(query || "").trim().slice(0, 160);
  if (!q) return null;
  const key = `search:${q}`;
  const cached = cacheGet(key);
  if (cached !== undefined) return cached;

  return serialised(async () => {
    const already = cacheGet(key);
    if (already !== undefined) return already;
    let found = null;
    try {
      const token = await imageSearchToken(q, { fetchImpl, timeoutMs });
      if (token) {
        const response = await timedFetch(
          fetchImpl,
          `https://duckduckgo.com/i.js?l=us-en&o=json&q=${encodeURIComponent(q)}&vqd=${encodeURIComponent(token)}`,
          {
            headers: {
              "user-agent": SEARCH_UA,
              referer: "https://duckduckgo.com/",
              "x-requested-with": "XMLHttpRequest",
            },
            timeoutMs,
          }
        );
        if (response.ok) {
          const data = await response.json().catch(() => null);
          for (const result of data?.results || []) {
            const image = absoluteImageUrl(result?.image, "https://duckduckgo.com/");
            if (image && usablePhoto(image, result?.width, result?.height)) {
              found = image;
              break;
            }
          }
        }
      }
    } catch {
      found = null;
    }
    cacheSet(key, found);
    return found;
  });
}

/**
 * Fill in `image` on every option that has a page but no picture yet.
 *
 * Two passes. First the page's own metadata — the share image a site publishes
 * for itself. Then, for the pages that refuse us (iFood and other marketplaces
 * answer 403 to a server), a keyless image search for the option itself, so a
 * dish or a product still has a face. Searches are serialised and capped: a
 * result set is worth a couple of seconds, never a queue of them.
 *
 * Failures leave the option exactly as it was.
 *
 * @param {Array<{name?:string, url?:string|null, image?:string|null}>} options
 * @param {{context?:string}} [hints]  what the task was about, to aim the search
 */
export async function enrichOptions(options, { context = "", fetchImpl = globalThis.fetch, timeoutMs = 2300, searchLimit = 4 } = {}) {
  if (!Array.isArray(options) || options.length === 0) return options;
  const targets = options.slice(0, MAX_OPTIONS);
  const images = await Promise.all(
    targets.map((option) => {
      if (!option || option.image || !option.url) return Promise.resolve(null);
      return imageFor(option.url, { fetchImpl, timeoutMs }).catch(() => null);
    })
  );
  let filled = options.map((option, index) => {
    const image = images[index];
    return image && option && !option.image ? { ...option, image } : option;
  });

  let budget = Math.max(0, searchLimit);
  for (let index = 0; index < filled.length && budget > 0; index += 1) {
    const option = filled[index];
    if (!option || option.image || !option.name) continue;
    const query = [option.name, context].filter(Boolean).join(" ").slice(0, 160);
    const found = await searchImage(query, { fetchImpl, timeoutMs }).catch(() => null);
    if (found) filled[index] = { ...option, image: found };
    budget -= 1;
  }
  return filled;
}

/** For tests: forget what pages returned. */
export function clearThumbnailCache() {
  cache.clear();
}
