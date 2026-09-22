/**
 * A hash-keyed memo for typed Jev reads — plan A.3.
 *
 * A decision is a pure function of `(model, question set, state)`, so the
 * answer to an identical read is memoized rather than paid for twice. Three
 * rules keep it safe:
 *
 *   1. **Only the hash and the typed answer are stored.** The key is
 *      `sha256(canonicalJson({ question, version, state, model }))`: the state
 *      string, the digest and the message text never enter the cache — not as
 *      entries, not in keys. A cache read cannot reveal account state.
 *   2. **A bounded, expiring memo, not a database.** 500 entries (LRU), a
 *      per-decision TTL, and `ok:false` kept for 5 s as a circuit breaker so a
 *      failed provider is not hammered. Everything is in memory only.
 *   3. **The cache never bypasses policy.** It stores typed answers; the
 *      adapters in `jev-batch.mjs` apply the same floors and ORDER_SHAPE guards
 *      to cached and live answers alike.
 *
 * `MIRA_JEV_CACHE=off` disables every store and read (the switch is read at
 * call time, so a test can flip it); the default is on. Counters are exposed
 * through `stats()` so the saving is measured, not believed.
 */

import crypto from "node:crypto";

const DEFAULT_TTL_MS = 5 * 60_000;
/** A failure is negative-cached for a moment: a circuit breaker, not a decision. */
const NEGATIVE_TTL_MS = 5_000;
const MAX_ENTRIES = 500;

/** Conversation language facts (A.5): 30 minutes, re-read every 10 turns. */
const LANGUAGE_TTL_MS = 30 * 60_000;
const LANGUAGE_MAX_TURNS = 10;

/** @type {Map<string, {value:any, cachedAt:number, expiresAt:number, uses:number}>} */
const entries = new Map();
/** @type {Map<string, {language:string, confidence:number|null, at:number, turns:number}>} */
const conversations = new Map();

const counters = { hits: 0, misses: 0, stores: 0, evictions: 0, expired: 0, skipped: 0 };

/** The switch: on unless explicitly off. */
export function cacheEnabled() {
  return process.env.MIRA_JEV_CACHE !== "off";
}

/** Deterministic JSON so the same inputs always hash the same. */
function canonicalJson(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (value && typeof value === "object") {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value === undefined ? null : value);
}

/**
 * The cache key: sha256 of (question name, criteria version, state, model).
 * The state is hashed here and the plaintext never leaves this function.
 */
export function cacheKey({ question, version = 1, state = "", model = "" } = {}) {
  const material = canonicalJson({ question, version, state, model });
  return crypto.createHash("sha256").update(material).digest("hex");
}

function withCachedFlag(value) {
  if (value && typeof value === "object" && !Array.isArray(value)) return { ...value, cached: true };
  return value;
}

function readEntry(key, now) {
  const entry = entries.get(key);
  if (!entry) return null;
  if (now >= entry.expiresAt) {
    entries.delete(key);
    counters.expired += 1;
    return null;
  }
  return entry;
}

function writeEntry(key, value, now, ttlMs) {
  if (entries.has(key)) entries.delete(key);
  entries.set(key, {
    value,
    cachedAt: now,
    expiresAt: now + Math.max(0, ttlMs),
    uses: 0,
  });
  counters.stores += 1;
  while (entries.size > MAX_ENTRIES) {
    const oldest = entries.keys().next().value;
    entries.delete(oldest);
    counters.evictions += 1;
  }
}

/**
 * Memoize one typed decision.
 *
 * @param {string} key                from `cacheKey(...)`
 * @param {() => Promise<any>} compute performed only on a miss
 * @param {{ttlMs?:number, negativeTtlMs?:number, now?:number}} [options]
 * @returns {Promise<any>} the stored or freshly computed value; a hit carries `cached: true`
 */
export async function cached(key, compute, { ttlMs = DEFAULT_TTL_MS, negativeTtlMs = NEGATIVE_TTL_MS, now = Date.now() } = {}) {
  if (typeof key !== "string" || !key) throw new TypeError("cached() needs a key.");
  if (typeof compute !== "function") throw new TypeError("cached() needs a compute function.");
  if (!cacheEnabled()) {
    counters.skipped += 1;
    return compute();
  }

  const entry = readEntry(key, now);
  if (entry) {
    counters.hits += 1;
    entry.uses += 1;
    // LRU: a hit makes the entry the most recent.
    entries.delete(key);
    entries.set(key, entry);
    return withCachedFlag(entry.value);
  }

  counters.misses += 1;
  const value = await compute();
  const failed = value && typeof value === "object" && value.ok === false;
  writeEntry(key, value, now, failed ? negativeTtlMs : ttlMs);
  return value;
}

/** Store a value the caller already computed (used to fill the route cache from a batch). */
export function remember(key, value, { ttlMs = DEFAULT_TTL_MS, now = Date.now() } = {}) {
  if (!cacheEnabled() || typeof key !== "string" || !key) return value;
  writeEntry(key, value, now, ttlMs);
  return value;
}

/** Counters for /health: measured, not believed. */
export function stats() {
  return {
    enabled: cacheEnabled(),
    size: entries.size,
    bound: MAX_ENTRIES,
    ...counters,
  };
}

/**
 * The stored entries, for tests and diagnostics only. Values are typed answers
 * (choices, probabilities, scores) — never state, digest or message text; this
 * is asserted in `server/test/jev-cache.test.mjs`.
 */
export function inspect() {
  return [...entries.entries()].map(([key, entry]) => ({
    key,
    value: entry.value,
    cachedAt: entry.cachedAt,
    expiresAt: entry.expiresAt,
    uses: entry.uses,
  }));
}

/** Clear the memo and the conversation facts. Tests call this between cases. */
export function reset() {
  entries.clear();
  conversations.clear();
  for (const name of Object.keys(counters)) counters[name] = 0;
}

// ── Conversation facts (A.5) ────────────────────────────────────────────────
// Language does not change every turn. One read per conversation is enough
// until 30 minutes pass, ten turns pass, or a deterministic detector sees the
// language change. Only `{ language, confidence, at, turns }` is kept.

function conversationKeyOf(brand, conversationId) {
  const id = typeof conversationId === "string" ? conversationId.trim() : "";
  if (!id) return null;
  return `${String(brand || "")}|${id.slice(0, 120)}`;
}

/**
 * The language already read for this conversation, or null when it is time to
 * ask again. Each successful call counts one turn of use.
 */
export function knownLanguage(brand, conversationId, { now = Date.now() } = {}) {
  if (!cacheEnabled()) return null;
  const key = conversationKeyOf(brand, conversationId);
  if (!key) return null;
  const fact = conversations.get(key);
  if (!fact) return null;
  if (now - fact.at > LANGUAGE_TTL_MS || fact.turns >= LANGUAGE_MAX_TURNS) {
    conversations.delete(key);
    return null;
  }
  fact.turns += 1;
  return { language: fact.language, confidence: fact.confidence, at: fact.at, turns: fact.turns };
}

/** Remember the language read for this conversation. Never stores message text. */
export function rememberLanguage(brand, conversationId, language, confidence = null, { now = Date.now() } = {}) {
  if (!cacheEnabled()) return null;
  const key = conversationKeyOf(brand, conversationId);
  if (!key || !language) return null;
  const fact = {
    language: String(language).slice(0, 40),
    confidence: typeof confidence === "number" ? confidence : null,
    at: now,
    turns: 0,
  };
  conversations.set(key, fact);
  return fact;
}

/** A test/diagnostic view of the conversation facts. */
export function conversationFacts() {
  return [...conversations.entries()].map(([key, fact]) => ({ key, ...fact }));
}

// ── The deterministic language detector ─────────────────────────────────────
// It never decides the language. It only decides when the cached one must be
// re-asked: ≥3 tokens that unmistakably match another profile and match none
// of the cached one's.

const LANGUAGE_PROFILES = {
  english: {
    markers: /\b(the|and|with|for|from|this|that|what|where|when|how|want|need|please|hello|thanks|is|are|can)\b/gi,
    strong: null,
  },
  portuguese: {
    markers: /\b(não|nao|você|voce|obrigado|obrigada|estou|quero|preciso|onde|porque|isso|aqui|hoje|amanhã|amanha|também|tambem|uma)\b/gi,
    strong: /[ãõç]/i,
  },
  spanish: {
    markers: /\b(el|los|las|una|está|esta|estoy|quiero|necesito|dónde|donde|cuándo|cuando|cómo|como|mucho|más|mas|esto|aquí|aqui|mañana|hola|gracias|pero)\b/gi,
    strong: /[ñ¿¡]/i,
  },
};

export function languageContradicts(cachedLanguage, text) {
  const value = String(text || "").trim();
  if (!cachedLanguage || !value) return false;
  const tokens = value.split(/\s+/).filter(Boolean);
  if (tokens.length < 3) return false;
  const lower = value.toLowerCase();
  const cachedProfile = LANGUAGE_PROFILES[cachedLanguage] ?? null;
  for (const [language, profile] of Object.entries(LANGUAGE_PROFILES)) {
    if (language === cachedLanguage) continue;
    const strongOther = profile.strong ? profile.strong.test(value) : false;
    const strongCached = cachedProfile?.strong ? cachedProfile.strong.test(value) : false;
    if (strongOther && !strongCached) return true;
    const otherHits = (lower.match(profile.markers) || []).length;
    const cachedHits = cachedProfile ? (lower.match(cachedProfile.markers) || []).length : 0;
    if (otherHits >= 2 && cachedHits === 0) return true;
  }
  return false;
}
