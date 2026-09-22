/**
 * Keyless web search for the task agent.
 *
 * Primary backend is Parallel's public MCP endpoint (no API key, the same
 * keyless tier a fresh Hermes install uses). Fallback is DuckDuckGo's HTML
 * endpoint. Both return plain `{title, url, description}` records; every URL is
 * run through the public-URL check so the agent is never handed a target it is
 * not allowed to fetch.
 *
 * A search that fails returns `{ ok:false, reason }`. It never returns invented
 * results.
 */

import crypto from "node:crypto";
import { isSafePublicUrl } from "./url-safety.mjs";
import { htmlToText } from "./html-text.mjs";

const PARALLEL_MCP_URL = "https://search.parallel.ai/mcp";
const DDG_LITE_URL = "https://lite.duckduckgo.com/lite/";

const SESSION_ID = crypto.randomBytes(8).toString("hex");

function parseMcpBody(body) {
  const fromPayload = (payload) => {
    const trimmed = String(payload || "").trim();
    if (!trimmed.startsWith("{")) return null;
    const data = JSON.parse(trimmed);
    if (data.error) throw new Error(data.error.message || String(data.error));
    const result = data.result || {};
    if (result.isError) {
      const text = (result.content || []).map((item) => item?.text || "").filter(Boolean).join(" ");
      throw new Error(text || "search tool call failed");
    }
    for (const item of result.content || []) {
      if (item && typeof item.text === "string") return item.text;
    }
    return null;
  };

  const stripped = String(body || "").trim();
  if (stripped.startsWith("{")) {
    try {
      const text = fromPayload(stripped);
      if (text !== null) return text;
    } catch (err) {
      if (!(err instanceof SyntaxError)) throw err;
    }
  }
  for (const line of String(body || "").split("\n")) {
    if (!line.startsWith("data: ")) continue;
    try {
      const text = fromPayload(line.slice(6));
      if (text !== null) return text;
    } catch (err) {
      if (!(err instanceof SyntaxError)) throw err;
    }
  }
  throw new Error("unrecognised search response shape");
}

function normaliseResults(records, limit) {
  const results = [];
  const seen = new Set();
  for (const record of records || []) {
    const url = String(record?.url || "").trim();
    if (!url || seen.has(url) || !isSafePublicUrl(url)) continue;
    seen.add(url);
    results.push({
      title: String(record?.title || url).replace(/\s+/g, " ").trim().slice(0, 200),
      url,
      description: String(record?.description || "")
        .replace(/\s+/g, " ")
        .trim()
        .slice(0, 400),
    });
    if (results.length >= limit) break;
  }
  return results;
}

async function parallelSearch(query, limit, { fetchImpl, timeoutMs }) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(PARALLEL_MCP_URL, {
      method: "POST",
      signal: controller.signal,
      headers: {
        "content-type": "application/json",
        accept: "application/json, text/event-stream",
        "user-agent": "mira-task-runtime",
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "web_search",
          arguments: { objective: query, search_queries: [query], session_id: SESSION_ID },
        },
      }),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const text = parseMcpBody(await response.text());
    const data = JSON.parse(text);
    return normaliseResults(data.results || [], limit);
  } finally {
    clearTimeout(timer);
  }
}

function decodeDdgHref(href) {
  try {
    const url = new URL(href, DDG_LITE_URL);
    const uddg = url.searchParams.get("uddg");
    if (uddg) return decodeURIComponent(uddg);
    if (url.hostname.endsWith("duckduckgo.com")) return null;
    return url.toString();
  } catch {
    return null;
  }
}

async function duckDuckGoSearch(query, limit, { fetchImpl, timeoutMs }) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(`${DDG_LITE_URL}?q=${encodeURIComponent(query)}`, {
      method: "GET",
      signal: controller.signal,
      headers: { "user-agent": "Mozilla/5.0 (compatible; MiraTaskBot/0.1)", accept: "text/html" },
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const html = await response.text();
    const results = [];
    const seen = new Set();
    const re = /<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi;
    let match;
    while ((match = re.exec(html)) && results.length < limit) {
      const url = decodeDdgHref(match[1]);
      if (!url || seen.has(url) || !isSafePublicUrl(url)) continue;
      const title = htmlToText(match[2], { maxChars: 200 }).replace(/\n/g, " ").trim();
      if (!title) continue;
      seen.add(url);
      results.push({ title: title.slice(0, 200), url, description: "" });
    }
    if (!results.length) throw new Error("no parsable results");
    return results;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Create the search function used by the agent toolset.
 * @returns {(query:string, limit?:number) => Promise<{ok:boolean, results?:object[], backend?:string, reason?:string}>}
 */
export function makeWebSearch({ fetchImpl = globalThis.fetch, timeoutMs = 20_000 } = {}) {
  return async function webSearch(query, limit = 6) {
    const q = String(query || "").trim();
    if (!q) return { ok: false, reason: "empty query" };
    const capped = Math.min(Math.max(Number(limit) || 6, 1), 10);
    const attempts = [];
    try {
      const results = await parallelSearch(q, capped, { fetchImpl, timeoutMs });
      if (results.length) return { ok: true, results, backend: "parallel-keyless" };
      attempts.push("parallel returned no usable results");
    } catch (err) {
      attempts.push(`parallel: ${err?.message || err}`);
    }
    try {
      const results = await duckDuckGoSearch(q, capped, { fetchImpl, timeoutMs });
      return { ok: true, results, backend: "duckduckgo-html" };
    } catch (err) {
      attempts.push(`duckduckgo: ${err?.message || err}`);
    }
    return { ok: false, reason: attempts.join("; ") };
  };
}
