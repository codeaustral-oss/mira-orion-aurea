/**
 * A grounded shopping result when the model provider cannot finish a task.
 * Search records supply every name and URL; this never invents a product,
 * price, merchant, or availability claim.
 */
import { makeWebSearch } from "./search.mjs";

function queryFor(task) {
  const message = String(task.originalMessage || "");
  const product = String(task.slots?.product || task.title || "product").trim();
  if (task.kind === "travel") {
    return `${task.slots?.origin || ""} ${task.slots?.destination || ""} flights ${task.slots?.dates || ""}`.trim();
  }
  if (task.kind === "restaurant") {
    const city = String(task.slots?.location || "").split(",").pop().trim();
    return `${task.slots?.cuisine || ""} restaurants ${city}`.trim();
  }
  if (task.kind === "auction") return `${product} auction online`;
  if (task.kind === "research") return String(task.slots?.topic || task.slots?.subject || message).trim();
  const brand = message.match(/\b(nike|adidas|puma|asics|new balance|sony|apple|samsung)\b/i)?.[0];
  const shoes = /\b(shoes?|sneakers?|trainers?|t[eê]nis)\b/i.test(`${message} ${product}`);
  if (shoes && brand) return `tênis ${brand} comprar loja oficial Brasil modelo`;
  return `${brand ? `${brand} ` : ""}${product} comprar online Brasil produto`;
}

function productScore(hit, brand) {
  const title = String(hit.title || "");
  const url = String(hit.url || "");
  if (!/^https:\/\//i.test(url)) return -100;
  if (brand && !new RegExp(`\\b${brand}\\b`, "i").test(`${title} ${url}`)) return -100;
  let score = 0;
  if (/\b(t[eê]nis|shoes?|sneakers?|headphones?|book|livro|product)\b/i.test(title)) score += 2;
  if (/\b(loja|store|oficial|official|categoria|collection|ofertas)\b/i.test(title)) score -= 2;
  if (/\/(?:tenis-|product\/|produto\/|t\/)/i.test(url) || /\.html(?:\?|$)/i.test(url)) score += 2;
  if (/\/(?:nav|busca|search|collections?|loja)(?:\/|\?|$)/i.test(url)) score -= 2;
  if (brand && new URL(url).hostname === `www.${brand.toLowerCase()}.com.br`) score += 2;
  return score;
}

export async function shoppingSearchFallback(task, { search = makeWebSearch(), signal } = {}) {
  if (signal?.aborted) return null;
  const query = queryFor(task);
  const started = Date.now();
  const found = await search(query, 10).catch(() => null);
  if (signal?.aborted || !found?.ok || !Array.isArray(found.results)) return null;
  const shopping = task.kind === "shopping";
  const brand = shopping
    ? String(task.originalMessage || "").match(/\b(nike|adidas|puma|asics|new balance|sony|apple|samsung)\b/i)?.[0]
    : null;
  const ranked = found.results
    .map((hit, index) => ({ hit, index, score: shopping ? productScore(hit, brand) :
      /^https:\/\//i.test(String(hit.url || "")) && String(hit.title || "").trim() ? 2 : -100 }))
    .filter(({ score }) => score >= 2)
    .sort((a, b) => b.score - a.score || a.index - b.index)
    .slice(0, 3)
    .map(({ hit }) => hit);
  if (!ranked.length) return null;
  const options = ranked.map((hit) => {
    const merchant = new URL(hit.url).hostname.replace(/^www\./, "");
    const name = String(hit.title).split(/\s+[-–|]\s+/)[0].trim().slice(0, 120);
    return { name, url: hit.url, why: `Found on ${merchant}.`, priceNote: null, image: null };
  });
  const subject = String(task.slots?.product || task.title || "products").toLowerCase();
  return {
    ok: true,
    result: {
      title: task.title,
      summary: shopping
        ? `I found live listings for ${brand ? `${brand} ` : ""}${subject}. Choose one to prepare the purchase with your Mira card.`
        : `I found live pages for ${subject}. Open a result to check the details.`,
      options,
      sources: ranked.map((hit) => ({ title: hit.title, url: hit.url })),
      next_step: shopping ? "Choose a product to continue." : "Open a result to continue.",
      blocked: [],
    },
    evidence: {
      toolCalls: 1,
      groundedCalls: 1,
      provenUrls: found.results.map((hit) => hit.url),
      backends: [found.backend || "web_search"],
      calls: [{ tool: "web_search", args: JSON.stringify({ query, limit: 10 }), ok: true,
        grounded: true, retrieval: false, resultCount: found.results.length,
        urls: found.results.map((hit) => hit.url), backend: found.backend || "web_search",
        ms: Date.now() - started }],
      failed: [],
      durationMs: Date.now() - started,
    },
  };
}
