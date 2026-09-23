/**
 * Deterministic task routing.
 *
 * Turns a user message into one concrete task intent (`restaurant`,
 * `shopping`, `travel`, `research`, `admin`) plus whatever details the
 * message already carries. This is deliberately plain code: no model chooses
 * the capability, and a task only starts when the details its capability
 * requires are actually present.
 *
 * Two properties matter here:
 *   · a misspelling like "Find me a fly to sap paulo" is still understood as
 *     a flight to São Paulo, and asks for departure and dates rather than
 *     refusing;
 *   · a task never hijacks an account command. Moving money, checking a
 *     balance or opening card controls stay on the existing deterministic
 *     path.
 */

import { normalisePlace } from "./capabilities.mjs";
import { detectCounterparty, parseAmount } from "./orchestrate.mjs";

const KIND_PATTERNS = [
  [
    "watch",
    // A standing check, not a purchase and not a one-off search. It comes before
    // the nouns it watches: "check every day for flights to Lisbon" is a watch on
    // flights, not a travel search. The phrases are deliberately narrow — "find
    // me a watch" and "find me a monitor" are shopping, "watch a movie" is neither.
    /\b(?:price (?:alert|watch)|alert me (?:when|if)|let me know (?:when|if)|notify me (?:when|if)|keep an eye on|watch(?:ing)? (?:the )?(?:price|stock|deal|listing)|monitor\s+(?:the|this|that|price|prices|stock|deal)|track(?:ing)? (?:the )?(?:price|prices|stock|deal)|check (?:every|daily|hourly|weekly|each (?:day|week|hour|month))|set up a watch|create an alert)\b/i,
  ],
  [
    "travel",
    /\b(flight|flights|fly|flying|airfare|airline|airlines|hotel|hotels|airbnb|trip|itinerary|travel|vacation|visa|train|bus|stay|staying|accommodation|somewhere to stay|place to stay|nights? in)\b/i,
  ],
  [
    "invest",
    // A security has to be named: "invest", "stock", "shares", an ETF, a bond,
    // a ticker. "buy" alone is a shop, and "how much is Tesla stock" is a price
    // question, not an order.
    /\b(invest|investment|investing|stocks?|shares?|equit(?:y|ies)|etfs?|index fund|treasur(?:y|ies)|bonds?|portfolio|dividend|ticker|nyse|nasdaq|\baapl\b|\btsla\b|\bnvda\b|\bmsft\b|\bamzn\b|\bgoogl\b|\bgoog\b|\bmeta\b|\bspy\b|\bqqq\b|\bvt\b)\b/i,
  ],
  [
    "auction",
    // A bid is a purchase at a price the person does not set — the search and
    // the handoff are different from a shop, so they get their own capability.
    /\b(auctions?|biddings?|bids?|place a bid|bid on|ebay|catawiki|leil[ãa]o|leil[õo]es|sotheby'?s|christie'?s)\b/i,
  ],
  [
    "restaurant",
    // "reserve" alone is a *money* word in this product ("without using my
    // reserve") and must never open a restaurant task. A table has to be named.
    /\b(restaurant|restaurants|reservations?|reserve a table|book a table|table for|dinner|lunch|brunch|dining|dine out|opentable|resy|bars?|cocktails?|drinks?|wine bar|rooftop bar|nightcap)\b/i,
  ],
  [
    "shopping",
    /\b(buy|purchase|shop|shopping|product|products|compare prices?|deal|discount|amazon|mercado ?livre|mercadolivre|store|cheapest|price of|headphones?|headset|earbuds?|airpods|laptop|notebook|mac ?book|mac ?mini|imac|\bmacs?\b|desktop|iphone|ipad|tablet|smartphone|phone|monitor|display|sneakers?|shoes?|boots?|trainers?|sandals?|jacket|coat|dress|shirt|jeans|trousers|bag|backpack|(?:a|an|the|my|new)\s+watch|keyboard|mouse|chair|desk|sofa|mattress|tv|television|console|gpu|ssd|camera|lens|drone|bike|bicycle|stroller|vacuum|blender|coffee machine|perfume|sunscreen|size \d+|\bsize\b)\b/i,
  ],
  [
    "admin",
    /\b(plan (?:my|a|the)|schedule|checklist|organize|organise|remind me to|prepare (?:a|the|my)|admin)\b/i,
  ],
  [
    "research",
    /\b(research|look up|look into|find out|compare|reviews? of|latest|news about|is it (?:true|worth)|how much (?:is|does|do)|who owns|what happened with)\b/i,
  ],
];

/**
 * Sending money — to a friend, a family member, a shop — is a transfer, and a
 * capability that returns links cannot send it. "I need to send pix to a
 * friend" became a research task once; it must never become one again.
 */
const MONEY_MOVEMENT =
  /\b(send|pay|transfer|pix|zelle|venmo|cash ?app|sepa|swift|wire|remit|top ?up|withdraw|deposit)\b/i;

export function looksLikeMoneyMovement(text) {
  const value = String(text || "");
  if (!MONEY_MOVEMENT.test(value)) return false;
  // "how do I send money" and "what is a pix" are questions about money
  // movement, not requests to move it.
  if (/^(?:what|why|how|who|when|where|is|are|does|do|can|could|should)\b/i.test(value.trim()) && !/\b(please|now|today)\b/i.test(value)) {
    return false;
  }
  return true;
}

/** The person's own recurring spend: the app holds that record, not a task. */
export function looksLikeOwnRecurringSpend(text) {
  return /\b(subscriptions?|subs|recurring|unsubscribe|renews?|renewals?)\b/i.test(String(text || ""));
}

/** Cashback and offers: the terms are the issuer's data, quoted by the app. */
export function looksLikeIssuerOffers(text) {
  return /\b(cash ?back|cashback|offers?|rewards?|perks?)\b/i.test(String(text || ""));
}

const DATE_PATTERNS = [
  /\b\d{4}-\d{2}-\d{2}\b/,
  // A range written the way people say it: "12-19 October", "12 to 19 October",
  // "12 until 19 Oct".
  /\b\d{1,2}\s*(?:[-–—]|to|until|through)\s*\d{1,2}\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\b/i,
  /\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s+\d{1,2}(?:\s*[-–—]\s*\d{1,2})?\b/i,
  /\b\d{1,2}\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\b/i,
  /\b(?:next|this)\s+(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|week|weekend|month)\b/i,
  /\b(?:tomorrow|tonight|today|this weekend|next weekend|in \d+ (?:days?|weeks?))\b/i,
  /\b(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/i,
  /\b(?:in|during|around)\s+(?:january|february|march|april|may|june|july|august|september|october|november|december)\b/i,
];

const STOP_WORDS = new Set([
  "on", "from", "in", "for", "at", "next", "this", "around", "between", "by", "the", "a", "an",
  "and", "with", "please", "today", "tomorrow", "tonight", "sometime",
]);

function cleanPlace(raw) {
  if (!raw) return null;
  let words = String(raw)
    .replace(/\s+/g, " ")
    .trim()
    .split(" ");
  // An internal preposition ends the place: "Sao Paulo TO Lisbon" is São Paulo.
  // A price qualifier ends it too: "Lisbon under 500 euros" is Lisbon.
  // The first word is kept even if it looks like one ("In Lisbon" is a place
  // as people write it); a capture that starts with a preposition is trimmed
  // below by the loop that follows.
  const separators = new Set([
    "to", "in", "for", "at", "on", "from", "near", "around", "during", "with", "and",
    "under", "over", "below", "above", "about", "up", "less", "more", "max", "maximum", "budget",
    // A place ends where the next verb starts: "Lisbon buy anything" is Lisbon.
    "buy", "order", "get", "find", "book", "reserve", "compare", "check", "search", "look",
    "need", "want", "like", "have", "go",
  ]);
  const cut = words.findIndex((word, index) => index > 0 && separators.has(word.toLowerCase()));
  if (cut > 0) words = words.slice(0, cut);
  while (words.length && STOP_WORDS.has(words[words.length - 1].toLowerCase())) words.pop();
  while (words.length && STOP_WORDS.has(words[0].toLowerCase())) words.shift();
  if (!words.length) return null;
  const place = words.join(" ").replace(/[.,;:!?]+$/g, "").trim();
  if (!place || place.length > 48) return null;
  return normalisePlace(place);
}

function captureAfter(text, preposition) {
  const re = new RegExp(`\\b${preposition}\\s+([A-Za-zÀ-ÿ][A-Za-zÀ-ÿ'’.-]*(?:\\s+[A-Za-zÀ-ÿ][A-Za-zÀ-ÿ'’.-]*){0,3})`, "i");
  const match = re.exec(text);
  return match ? cleanPlace(match[1]) : null;
}

function knownPlace(text) {
  const lower = text.toLowerCase();
  // Longest names first so "new york" wins over "york".
  const names = [
    "sao paulo", "são paulo", "sap paulo", "rio de janeiro", "buenos aires", "mexico city",
    "los angeles", "san francisco", "hong kong", "belo horizonte", "porto alegre", "new york",
    "lisbon", "lisboa", "miami", "london", "paris", "berlin", "madrid", "barcelona", "toronto",
    "vancouver", "chicago", "boston", "seattle", "austin", "dubai", "tokyo", "singapore",
    "bangkok", "bogota", "bogotá", "lima", "santiago", "brasilia", "brasília", "salvador",
    "recife", "curitiba", "porto",
  ];
  for (const name of names) {
    if (lower.includes(name)) return normalisePlace(name);
  }
  return null;
}

function extractDates(text) {
  const found = [];
  for (const pattern of DATE_PATTERNS) {
    const match = pattern.exec(text);
    if (match && !found.includes(match[0])) found.push(match[0].trim());
  }
  // "12 to 19 October" matches twice — once as the range, once as the date at
  // its end. Keep the range and drop what it already contains.
  const kept = found.filter(
    (candidate) => !found.some((other) => other !== candidate && other.includes(candidate)));
  return kept.length ? kept.join("; ") : null;
}

function extractTime(text) {
  const ampm = /\b(?:at\s+)?(\d{1,2}(?::\d{2})?)\s*(am|pm)\b/i.exec(text);
  if (ampm) return `${ampm[1]}${ampm[2].toLowerCase()}`;
  const at = /\bat\s+(\d{1,2}:\d{2})\b/i.exec(text);
  return at ? at[1] : null;
}

function extractPartySize(text) {
  const match = /\b(?:for|party of|table for)\s+(\d{1,2})\b/i.exec(text);
  if (!match) return null;
  const size = Number(match[1]);
  return Number.isInteger(size) && size > 0 && size <= 40 ? String(size) : null;
}

function extractCuisine(text) {
  const match =
    /\b(italian|japanese|sushi|brazilian|mexican|indian|thai|chinese|french|korean|vegan|vegetarian|pizza|seafood|steakhouse|barbecue|bbq|peruvian|argentinian)\b/i.exec(
      text
    );
  return match ? match[1].toLowerCase() : null;
}

/** A ticker (AAPL), or the security's name when no ticker is written. */
/** Words that name a kind of instrument, not a particular one. */
const GENERIC_INSTRUMENTS = /^(?:etfs?|funds?|index funds?|mutual funds?|stocks?|shares?|equit(?:y|ies)|bonds?|treasur(?:y|ies)|index(?:es)?|portfolios?)$/i;

function extractSymbol(text) {
  const value = String(text || "");
  const known = /\b(AAPL|TSLA|NVDA|MSFT|AMZN|GOOGL?|META|SPY|QQQ|VT|VTI|BND)\b/i.exec(value);
  if (known) return known[1].toUpperCase();
  // Two to five capitals that are not ordinary words at the start of a sentence.
  const ticker = /\b([A-Z]{2,5})\b/.exec(value.replace(/^I\b/, ""));
  if (
    ticker &&
    !["I", "A", "THE", "AND", "FOR", "BUY", "SELL", "IN", "AN", "MY", "OF", "ETF", "ETFS", "SP", "USA"].includes(
      ticker[1]
    )
  ) {
    return ticker[1];
  }
  // "invest in an S&P 500 index fund" / "buy tesla shares": the noun phrase.
  const phrase = /\b(?:in|into|buy|sell|purchase|of)\s+((?:the\s+)?[A-Za-z0-9&'. -]{2,40}?)(?:\s+(?:shares?|units?|stocks?|etfs?|fund)\b|[.,;]|$)/i.exec(value);
  if (phrase) {
    const cleaned = phrase[1]
      .replace(/\b(?:a|an|the|some)\b/gi, "")
      .replace(/\b(?:shares?|units?|stocks?|etfs?|fund)\b/gi, "")
      .trim();
    // "in an ETF" names a kind of thing, not the thing: the task should ask.
    if (cleaned && !GENERIC_INSTRUMENTS.test(cleaned)) return cleaned.slice(0, 60);
  }
  return null;
}

/** The condition a lot or listing states, in the seller's own word. */
function extractCondition(text) {
  const match =
    /\b(sealed|brand new|new|used|mint|refurbished|boxed|unboxed|for parts|working|untested)\b/i.exec(
      text
    );
  return match ? match[1].toLowerCase() : null;
}

/** How often a standing check should run. Default is daily. */
function extractCadence(text) {
  const value = String(text || "").toLowerCase();
  if (/\b(hourly|every hour|each hour)\b/.test(value)) return "hourly";
  if (/\b(daily|every day|each day|once a day)\b/.test(value)) return "daily";
  if (/\b(weekly|every week|each week|once a week)\b/.test(value)) return "weekly";
  if (/\b(monthly|every month|each month|once a month)\b/.test(value)) return "monthly";
  return null;
}

function tidyWatchSubject(raw) {
  const phrase = stripTrailingQualifiers(stripLeadIns(String(raw || "")))
    .replace(/\s+(?:price|prices|cost|stock|availability|deal|deals)\s*$/i, "")
    .trim();
  if (!phrase) return null;
  const words = phrase.split(/\s+/).filter(Boolean);
  if (words.length > 8 || words.every((word) => PRODUCT_FILLER.has(word.toLowerCase()))) return null;
  return phrase.slice(0, 120);
}

/** What the person wants kept an eye on, from the shapes they actually use. */
function extractWatchSubject(text) {
  const value = String(text || "");
  const patterns = [
    /\b(?:price|cost) of\s+(.{2,80}?)(?=\s+(?:under|below|less than|drops?|falls?|goes?|hits?|reaches?)\b|[.,;!?]|$)/i,
    /\b(?:keep an eye on|monitor|track|watch(?:ing)?)\s+(.{2,80}?)(?=\s+(?:under|below|less than|drops?|falls?|goes?|hits?|reaches?)\b|[.,;!?]|$)/i,
    /\b(?:let me know (?:when|if)|alert me (?:when|if)|notify me (?:when|if))\s+(.{2,80}?)(?=\s+(?:under|below|less than|drops?|falls?|goes?|hits?|reaches?|is|are)\b|[.,;!?]|$)/i,
    /\bcheck\s+(?:every|each|daily|hourly|weekly)[^,.;!?]*?\bfor\s+(.{2,80}?)(?=\s+(?:under|below|less than)\b|[.,;!?]|$)/i,
  ];
  for (const pattern of patterns) {
    const match = pattern.exec(value);
    if (!match) continue;
    const subject = tidyWatchSubject(match[1]);
    if (subject) return subject;
  }
  // "watching a deal on the Pegasus 41" names the thing the product way.
  return extractProduct(value);
}

/**
 * A definition question — "what is an auction?" — is a question, not a search.
 * The capability vocabularies name nouns ("auction", "restaurant", "flight"),
 * and a person asking what one *is* must get an answer, never a task with
 * questions back. A request verb anywhere in the message settles it: "what is
 * the best restaurant in Lisbon" is a request.
 */
export function looksLikeDefinitionQuestion(text) {
  const value = String(text || "").trim();
  if (!/^(?:what|who|why|how|when|where)\b/i.test(value)) return false;
  if (
    /\b(?:best|cheapest|top|recommend|options?|find|show|search|compare|book|reserve|buy|order|bid|plan|get|need|want|near)\b/i.test(
      value
    )
  ) {
    return false;
  }
  return true;
}

/**
 * Buying a meal, rather than choosing a venue. Only these requests are asked
 * the one question that changes everything about the search: is the food coming
 * to them, or are they going there?
 *
 * "restaurants in Lisbon" is not a meal to buy — the venue is the answer.
 * "I need to buy lunch" is, and it could honestly be either.
 */
const MEAL_WORDS =
  /\b(lunch|dinner|breakfast|brunch|supper|snack|meal|food|hungry|eat|order(?:ing)?|takeout|take-?away|deliver(?:y|ed|ing)?)\b/i;

/** The meal is coming to them: platform delivery, courier, takeaway, pickup. */
const DELIVERY_WORDS =
  /\b(deliver(?:y|ed|ing)?|take ?away|take ?out|to ?go|pick ?up|pickup|order in|ifood|uber ?eats|doordash|deliveroo|rappi|glovo|wolt|just ?eat|grubhub|skipthedishes)\b/i;

/** They are going to the place: a table, a venue, a reservation. */
const DINE_IN_WORDS =
  /\b(eat (?:there|in|out)|dining in|dine ?in|sit ?down|table for|reservation|reserve a table|book a table|restaurants?|diner|caf[eé]|bistro)\b/i;

/** "delivery" or "dine-in", when the message says; otherwise null. */
export function extractMode(text) {
  const value = String(text || "");
  if (DELIVERY_WORDS.test(value)) return "delivery";
  if (DINE_IN_WORDS.test(value)) return "dine-in";
  return null;
}

/** True when the person is buying a meal rather than looking for a venue. */
export function looksLikeMealRequest(text) {
  return MEAL_WORDS.test(String(text || ""));
}

/**
 * Product vocabulary for the shopping capability. A real noun in the message
 * beats a lead-in phrase: "find me some running shoes" is a request for
 * "running shoes", whatever the sentence wrapped around it.
 */
const PRODUCT_NOUNS = [
  "coffee machine", "espresso machine", "air fryer", "robot vacuum", "running shoes",
  "mechanical keyboard", "headphones", "headset", "earbuds", "airpods", "sneakers",
  "trainers", "sandals", "jacket", "backpack", "mattress", "television", "bicycle",
  "stroller", "blender", "perfume", "sunscreen", "monitor", "keyboard", "laptop",
  "notebook", "macbook", "iphone", "ipad", "tablet", "smartphone", "phone", "shoes",
  "boots", "coat", "dress", "shirt", "jeans", "trousers", "bag", "watch", "mouse",
  "chair", "desk", "sofa", "console", "camera", "lens", "drone", "vacuum", "bike",
  "tv", "gpu", "ssd",
].sort((a, b) => b.length - a.length);

/** Words that never belong to the product itself. */
const PRODUCT_FILLER = new Set([
  "a", "an", "the", "some", "good", "cheap", "best", "please", "pls", "find", "found",
  "i", "me", "my", "need", "want", "would", "like", "looking", "for", "search",
  "searching", "shop", "shopping", "where", "can", "buy", "purchase", "get", "show",
  "to", "of", "is", "are", "under", "over", "below", "above", "around", "about",
]);

const LEAD_IN_PATTERNS = [
  // A person says hello before they say what they want. "Hey. I want to buy a
  // Mac Mini" is a request for a Mac Mini; the greeting is not part of it, and
  // not a reason to ask which brand they mean.
  /^(?:hi|hey|hello|yo|hiya|howdy|good\s+(?:morning|afternoon|evening))\b(?:\s+there)?[\s,.!—–-]*/i,
  /^(?:quick\s+question|one\s+thing|so|ok|okay|right|well)\b[\s,.!—–-]*/i,
  /^please[,\s]+/i,
  /^(?:can|could|would|will)\s+you\s+/i,
  /^help\s+me\s+/i,
  /^i\s+would\s+like\s+(?:to\s+)?/i,
  /^i'd\s+like\s+(?:to\s+)?/i,
  /^i\s+(?:need|want)\s+(?:to\s+)?/i,
  /^find\s+me\s+/i,
  /^find\s+/i,
  /^search(?:ing)?\s+for\s+/i,
  /^look(?:ing)?\s+for\s+/i,
  /^shop\s+for\s+/i,
  /^bid(?:ding)?\s+(?:on|for)\s+/i,
  /^watch(?:ing)?\s+for\s+/i,
  /^where\s+can\s+i\s+buy\s+/i,
  /^where\s+to\s+buy\s+/i,
  /^buy\s+me\s+/i,
  /^buy\s+/i,
  /^purchase\s+/i,
  /^get\s+me\s+/i,
  /^show\s+me\s+/i,
  /^(?:a|an|the|good|cheap|best|some)\s+/i,
];

// Trailing qualifiers are never part of the product: "size 43", "43 size",
// "32 cm", "under 120 euros", "in Lisbon", "on Amazon".
const TRAILING_QUALIFIERS = [
  /\s+(?:under|over|below|above|for|around|about|up\s+to|less\s+than|more\s+than|max(?:imum)?|budget(?:\s+of)?)\s*(?:€|R\$|US\$)?\s*\d[\d.,]*\s*(?:euros?|dollars?|usd|eur|brl|reais|reals|gbp|pounds?)?$/i,
  /\s+(?:size\s*\d{1,3}(?:[.,]5)?|\d{1,3}(?:[.,]5)?\s*size)$/i,
  /\s+\d{1,4}(?:[.,]\d+)?\s*(?:cm|mm|inches?|inch)$/i,
  /\s+(?:from|on|at|in)\s+[A-Za-zÀ-ÿ][\w'’.-]*(?:\s+[A-Za-zÀ-ÿ][\w'’.-]*){0,2}$/i,
  /\s+please$/i,
];

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function stripLeadIns(input) {
  let phrase = String(input || "").trim();
  let changed = true;
  while (changed) {
    changed = false;
    for (const pattern of LEAD_IN_PATTERNS) {
      const next = phrase.replace(pattern, "");
      if (next !== phrase) {
        phrase = next.trim();
        changed = true;
        break;
      }
    }
  }
  return phrase;
}

function stripTrailingQualifiers(input) {
  let phrase = String(input || "").trim().replace(/[.,;!?]+$/, "");
  let previous;
  do {
    previous = phrase;
    for (const pattern of TRAILING_QUALIFIERS) phrase = phrase.replace(pattern, "").trim();
  } while (phrase && phrase !== previous);
  return phrase;
}

/** The known noun, with up to two leading modifiers ("running shoes"). */
function productAroundNoun(text) {
  const source = String(text || "");
  const lower = source.toLowerCase();
  for (const noun of PRODUCT_NOUNS) {
    const match = new RegExp(`(?:^|[^a-z0-9])${escapeRegExp(noun)}(?![a-z0-9])`, "i").exec(lower);
    if (!match) continue;
    const start = match.index + match[0].length - noun.length;
    const before = source.slice(0, start).trim().split(/\s+/).filter(Boolean);
    const modifiers = [];
    for (let i = before.length - 1; i >= 0 && modifiers.length < 2; i -= 1) {
      const word = before[i].replace(/^[^\w'’À-ÿ-]+|[^\w'’À-ÿ-]+$/g, "");
      if (!word || PRODUCT_FILLER.has(word.toLowerCase())) break;
      modifiers.unshift(word);
    }
    return [...modifiers, noun].join(" ").trim();
  }
  return null;
}

/** A greeting, question or account command is not a product phrase. */
function isNonProductUtterance(text) {
  const value = String(text || "").trim();
  if (!value) return true;
  if (/^(?:hi|hey|hello|yo|hiya|thanks|thank you|ok|okay|good (?:morning|afternoon|evening))\b/i.test(value)) return true;
  if (/\b(?:balance|statement|account|transfer|send|pay|card controls?|home address|my address|receive|freeze)\b/i.test(value)) return true;
  if (/^(?:what|why|how|who|where|when|which|is|are|am|do|does|did|can|could|would|should|will|may|might)\b/i.test(value)) return true;
  // A bare category word — "find me an auction", "find me a restaurant" — names
  // the search, not the thing. The task should ask what the thing is.
  if (/^(?:auctions?|bids?|bidding|restaurants?|flights?|hotels?|travel|rentals?|products?|items?|deals?|options?|results?)$/i.test(value)) {
    return true;
  }
  return false;
}

function extractProduct(text) {
  const raw = String(text || "").replace(/\s+/g, " ").trim();
  if (!raw) return null;

  // 1. A real product noun is the most reliable signal.
  const noun = productAroundNoun(raw);
  if (noun) return noun.slice(0, 120);

  // 2. Otherwise use a request lead-in ("find me …", "i need …") and strip
  //    whatever is not the product.
  const candidate = stripTrailingQualifiers(stripLeadIns(raw)).trim();
  if (!candidate) return null;

  // 3. A bare phrase counts only when it is not a greeting, question or
  //    account command ("hi", "what is my balance" have no product).
  if (candidate === raw && isNonProductUtterance(candidate)) return null;
  const trimmed = candidate.slice(0, 120).trim();
  if (!trimmed) return null;

  // 4. Last resort, and deliberately generous: a longer message that clearly is
  //    a request ("hey, i want a mac mini for editing") is still a product
  //    request. Carrying a slightly messy phrase into the brief is far better
  //    than replying "which brand or model?" to someone who just named one.
  const stillARequest = /\b(?:want|need|buy|purchase|looking|find|search|get|bid|bidding|win|watching)\b/i.test(raw);
  if (stillARequest && !isNonProductUtterance(trimmed)) return trimmed;
  return null;
}

/**
 * The thing being bid on, from the shapes auction requests actually use:
 * "auction for a vintage watch", "sealed Game Boy auction in Lisbon".
 */
function extractAuctionProduct(text) {
  const value = String(text || "");
  const after = /\bauctions?\s+(?:for|of)\s+([A-Za-z0-9][\w'’.-]*(?:\s+[A-Za-z0-9][\w'’.-]*){0,3})/i.exec(value);
  const before = /\b([A-Za-z0-9][\w'’.-]*(?:\s+[A-Za-z0-9][\w'’.-]*){0,3})\s+auctions?\b/i.exec(value);
  for (const match of [after, before]) {
    if (!match) continue;
    const phrase = stripTrailingQualifiers(stripLeadIns(match[1])).trim();
    const words = phrase.split(/\s+/).filter(Boolean);
    // "find me an auction" leaves only filler before the word: that is not an
    // item, and the task should ask for one.
    if (!phrase || words.length > 5 || words.every((word) => PRODUCT_FILLER.has(word.toLowerCase()))) {
      continue;
    }
    return phrase.slice(0, 120);
  }
  return null;
}

function extractTopic(text) {
  const stripped = text.replace(/^\s*(?:please\s+)?(?:research|look up|look into|find out|compare)\s+/i, "").trim();
  return (stripped || text).slice(0, 240);
}

function formatBudget(parsed) {
  if (!parsed) return null;
  const value = parsed.value >= 100 ? Math.round(parsed.value) : parsed.value;
  return `${parsed.asset} ${value}`;
}

/**
 * A message that asks Mira to go and find something, in plain words, without
 * naming a category. "shoes 43 size", "a good espresso machine", "somewhere to
 * stay in Lisbon" are all tasks; refusing them because none of the specialist
 * vocabularies matched would be the assistant failing at its main job.
 */
const REQUEST_SHAPE =
  /\b(find|finds|look(?:ing)? for|search(?:ing)?|where can i|where to|best|recommend|recommendations?|compare|options?|a good|something (?:good|nice|cheap)|i (?:need|want|would like)|can you (?:find|get|look)|what(?:'s| is) the best)\b/i;

/**
 * "I need to buy euros", "buy 100 dollars" — money changing currency, not a
 * product to research. The app prices these itself; the router must never turn
 * one into a shopping task called "euros".
 */
const CURRENCY_WORDS = /\b(usd|usdc|usdt|eur|euros?|brl|reais|gbp|pounds?|dollars?|bucks)\b/i;

/** Words that describe why the money is wanted, not what is being bought. */
const MONEY_CONTEXT_WORDS = new Set([
  "trip", "travel", "traveling", "travelling", "holiday", "holidays", "vacation", "weekend",
  "flight", "flights", "abroad", "today", "tomorrow", "tonight", "now",
]);

/** The verbs and articles that carry no subject of their own. */
const MONEY_FILLER_WORDS = new Set([
  "buy", "sell", "purchase", "get", "need", "want", "like", "some", "for", "my", "a", "an", "the",
  "of", "to", "in", "into", "and", "or", "i", "me", "is", "are", "much", "many", "how", "worth",
  "exchange", "convert", "change", "swap", "rate", "rates", "please", "can", "could", "you",
]);

export function isCurrencyOnlyRequest(text) {
  const value = String(text || "");
  if (!CURRENCY_WORDS.test(value)) return false;
  const product = extractProduct(value) || value;
  const words = product.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
  const substantive = words.filter(
    (word) =>
      !CURRENCY_WORDS.test(word) &&
      !MONEY_CONTEXT_WORDS.has(word) &&
      !MONEY_FILLER_WORDS.has(word) &&
      !/^\d+([.,]\d+)?$/.test(word)
  );
  return substantive.length === 0;
}

/** The capability kind this message starts (or continues), or null. */
export function detectTaskKind(message) {
  const text = String(message || "");
  if (!text.trim()) return null;
  for (const [kind, pattern] of KIND_PATTERNS) {
    if (!pattern.test(text)) continue;
    // Money changing currency is priced by the app, not researched as a
    // product or a trip — however the sentence is wrapped.
    if ((kind === "shopping" || kind === "travel" || kind === "research") && isCurrencyOnlyRequest(text)) {
      continue;
    }
    // Sending money has its own path in the app: no task may claim it.
    if (looksLikeMoneyMovement(text) && (kind === "research" || kind === "shopping" || kind === "travel")) {
      continue;
    }
    // So does the person's own recurring spend: the app holds that record, and
    // "how much do I spend on subscriptions" is arithmetic, not research.
    if (
      (kind === "research" || kind === "shopping" || kind === "admin") &&
      looksLikeOwnRecurringSpend(text)
    ) {
      continue;
    }
    // A question about a security is research; an order is invest.
    if (kind === "invest") {
      const asks = /^(?:what|how|why|who|when|where|is|are|does|do|can)\b/i.test(text.trim());
      const orders = /\b(buy|sell|purchase|invest|order|add|open a position)\b/i.test(text);
      if (asks && !orders) continue;
    }
    return kind;
  }
  // And if nothing else matched, a money movement is still not research.
  if (looksLikeMoneyMovement(text)) return null;
  // Neither is the person's own recurring spend: the app holds that record.
  if (looksLikeOwnRecurringSpend(text)) return null;
  // Nor their own cashback and offers: the terms are the issuer's data.
  if (looksLikeIssuerOffers(text)) return null;
  // Money changing currency is not a research subject either.
  if (isCurrencyOnlyRequest(text)) return null;
  // Nothing specific matched. If it reads like a request rather than a
  // statement or an account command, it becomes a research task: Mira asks the
  // one question it needs and gets on with it.
  if (REQUEST_SHAPE.test(text) && text.trim().split(/\s+/).length >= 2) return "research";
  return null;
}

/** Extract every detail the message plainly carries for this kind. */
export function extractSlots(kind, message) {
  const text = String(message || "");
  const slots = {};
  const budget = formatBudget(parseAmount(text));

  if (kind === "travel") {
    slots.destination = captureAfter(text, "to") || captureAfter(text, "towards");
    // "to Lisbon in October" is a place and a date; the date has its own slot.
    if (slots.destination) {
      slots.destination = slots.destination
        .replace(/\s+(?:in|on|during|for|at|next|this)\s+.*$/i, "")
        .trim();
      if (!slots.destination) delete slots.destination;
    }
    // "somewhere to stay in Lisbon" puts the verb between "to" and the place.
    if (STAY_HINTS.test(text)) {
      const place =
        captureAfter(text, "in") || captureAfter(text, "near") || captureAfter(text, "around");
      if (place) {
        slots.destination = place
          // "Lisbon in October" is a place and a date; the date has its own slot.
          .replace(/\s+(?:in|on|during|for|from|next|this)\s+.*$/i, "")
          .replace(/^(?:stay|staying|sleep|a hotel in)\s+/i, "")
          .trim();
      }
    }
    slots.origin = captureAfter(text, "from") || captureAfter(text, "departing");
    slots.dates = extractDates(text);
    if (budget) slots.budget = budget;
    const travelers = extractPartySize(text);
    if (travelers) slots.travelers = travelers;
  } else if (kind === "restaurant") {
    slots.location = captureAfter(text, "in") || captureAfter(text, "near") || captureAfter(text, "around");
    // "Lisbon for Friday" is a place and a date; the date has its own slot.
    if (slots.location) {
      slots.location = slots.location
        .replace(/\s+(?:for|on|during|next|this|at)\s+.*$/i, "")
        .trim();
      if (!slots.location) delete slots.location;
    }
    if (!slots.location) slots.location = knownPlace(text);
    slots.mode = extractMode(text);
    slots.date = extractDates(text);
    slots.time = extractTime(text);
    slots.partySize = extractPartySize(text);
    slots.cuisine = extractCuisine(text);
    if (budget) slots.budget = budget;
  } else if (kind === "shopping") {
    slots.product = extractProduct(text);
    if (budget) slots.budget = budget;
    slots.location = captureAfter(text, "in") || null;
  } else if (kind === "auction") {
    slots.product = extractProduct(text) || extractAuctionProduct(text);
    if (budget) slots.budget = budget;
    slots.location = captureAfter(text, "in") || captureAfter(text, "near") || null;
    slots.condition = extractCondition(text);
  } else if (kind === "invest") {
    slots.symbol = extractSymbol(text);
    const quantity = /\b(\d+(?:[.,]\d+)?)\s*(?:shares?|units?|stocks?)\b/i.exec(text);
    if (quantity) slots.quantity = `${quantity[1]} shares`;
    if (budget) slots.amount = budget;
    if (/\blimit\b/i.test(text)) slots.orderType = "limit";
    else if (/\bmarket\b/i.test(text)) slots.orderType = "market";
  } else if (kind === "watch") {
    slots.subject = extractWatchSubject(text);
    if (budget) slots.target = budget;
    slots.cadence = extractCadence(text);
    const link = /\bhttps?:\/\/[^\s"'<>]+/i.exec(text);
    if (link) slots.url = link[0].slice(0, 500);
  } else if (kind === "admin") {
    slots.goal = extractTopic(text);
    slots.deadline = extractDates(text);
  } else if (kind === "research") {
    slots.topic = extractTopic(text);
  }
  return slots;
}

/**
 * Fill the slots a task is still asking for from the user's answer.
 *
 * A follow-up like "São Paulo" — or "12–19 October" — is not a fresh request and
 * does not contain the prepositions a first message does ("from Lisbon"). It is
 * the answer to one question, so it is mapped onto the missing slot directly.
 * Without this the task kept asking the same question forever, which is exactly
 * what it looked like.
 */
export function fillAnswerSlots(kind, missing, message) {
  const answer = String(message || "").replace(/\s+/g, " ").trim();
  const patch = {};
  if (!answer || !Array.isArray(missing) || missing.length === 0) return patch;

  const words = answer.split(" ");
  // A place is one to three words, and it is not a sentence. Anything with a
  // verb, a pronoun or a hesitation in it is an answer we cannot use as a name.
  const notAPlace =
    /\b(i|we|you|they|he|she|it|do|does|did|not|don't|dont|know|maybe|later|undecided|unsure|any|some|and|or|the|for|from|to|in|on|at|next|this|that|please|yes|no|ok|okay|will|would|can|could|should)\b/i;
  // "Canasvieiras, Florianopolis" is one place written the way people write
  // places; the comma is punctuation, not a reason to ignore the answer.
  const placeAnswer = answer.replace(/[,;]+/g, " ").replace(/\s+/g, " ").trim();
  const placeWords = placeAnswer.split(" ");
  const placeShaped = placeWords.length <= 3
    && /^[A-Za-zÀ-ÿ'’.\- ]+$/.test(placeAnswer)
    && !notAPlace.test(placeAnswer);

  for (const slot of missing) {
    switch (slot) {
      case "origin":
      case "destination":
      case "location":
        if (placeShaped) patch[slot] = normalisePlace(placeAnswer);
        break;
      case "dates": {
        const dates = extractDates(answer);
        if (dates) patch.dates = dates;
        break;
      }
      case "partySize": {
        const size = extractPartySize(answer);
        if (size) patch.partySize = size;
        break;
      }
      case "product":
        if (words.length <= 10) patch.product = answer.slice(0, 120);
        break;
      case "mode": {
        // The answer to "Delivery, or eating there?" — however it is phrased.
        const mode = extractMode(answer);
        if (mode) patch.mode = mode;
        else if (/\bthere\b/i.test(answer)) patch.mode = "dine-in";
        // "delivery to Canasvieiras" answers two questions at once: what comes
        // after "to" is where it should go, not part of the mode.
        if (patch.mode === "delivery" && missing.includes("location")) {
          const place = captureAfter(answer, "to") || captureAfter(answer, "in");
          if (place) patch.location = place;
        }
        break;
      }
      case "budget": {
        const budget = formatBudget(parseAmount(answer));
        if (budget) patch.budget = budget;
        break;
      }
      case "topic":
      case "goal":
        patch[slot] = answer.slice(0, 200);
        break;
      default:
        break;
    }
    if (patch[slot]) break;   // one answer fills one slot
  }
  return patch;
}

/**
 * A follow-up in the same conversation: "and bars?", "what about sushi?",
 * "also with a view". These are not new requests and they are not money
 * questions — they refine the thing already being researched, which is what a
 * person means by them.
 */
export function continuationOf(text) {
  const message = String(text || "").trim();
  if (!message) return null;
  if (message.length > 60) return null;
  // A connector has to *be* a connector. A bare "Ok" is an acknowledgement, and
  // the sentence after it is a new request: "Ok I need a flight to Lisbon" must
  // never be merged into the previous subject as a refinement.
  const match =
    /^(?:and|also|plus|but)\b[\s,:]*(.*)$/i.exec(message)
    || /^(?:what about|how about)\b[\s,:]*(.*)$/i.exec(message)
    || /^ok(?:ay)?\s*,?\s*(?:and|also|but|what about)\b[\s,:]*(.*)$/i.exec(message)
    || /^(?:with|for)\s+(.{2,40})\??$/i.exec(message);
  if (!match) return null;
  const tail = String(match[1] || "").replace(/[?.!]+$/g, "").trim();
  return tail || null;
}

/** True when the message is an account command that must not become a task. */
export function looksLikeAccountCommand(message, { hasCounterparty = false, hasPendingTransfer = false } = {}) {
  const text = String(message || "");
  if (
    /\b(balance|budget|receive|freeze|unfreeze|card controls?|cash ?out|withdraw|deposit|statement|account number|my address|home address)\b/i.test(
      text
    )
  ) {
    return true;
  }
  if (
    hasCounterparty &&
    /\b(send|transfer|pay|move|wire)\b/i.test(text) &&
    !/\b(restaurant|flight|hotel|product|reservation|dinner|table for)\b/i.test(text)
  ) {
    return true;
  }
  if (hasPendingTransfer && /\b(send|transfer|pay|move|wire)\b/i.test(text)) return true;
  return false;
}

/**
 * How a task titles itself. Only the ones a person would say out loud keep a
 * word: "Flights to Lisbon", "Watching the price". A capability label —
 * "Shopping: food for my cat" — is machinery, and it never becomes a title.
 */
const TITLE_PREFIX = {
  restaurant: null,
  auction: null,
  invest: null,
  watch: "Watching",
  shopping: null,
  travel: "Travel",
  research: null,
  admin: null,
};

/** True when a travel request is about somewhere to stay rather than a flight. */
export const STAY_HINTS =
  /\b(hotel|hotels|airbnb|stay|staying|accommodation|somewhere to stay|place to stay|room|rooms|nights?)\b/i;

export function deriveTitle(kind, slots, message) {
  // A delivered meal is titled for what it is: "Delivery: Canasvieiras".
  const prefix =
    kind === "restaurant" && slots?.mode === "delivery" ? "Delivery" : TITLE_PREFIX[kind] || "Task";
  const text = String(message || "");
  // What the task is *about*: a purchase is about the thing, not the city it
  // will ship to; a trip is about where it goes.
  const productFirst = kind === "shopping" || kind === "auction";
  const subject =
    (productFirst ? slots.product : null) ||
    slots.destination ||
    slots.location ||
    slots.product ||
    slots.subject ||
    slots.topic ||
    slots.goal ||
    // The last resort never shows the raw sentence: lead-ins ("Ok", "I need")
    // come off first, so a title reads like a subject.
    stripTrailingQualifiers(stripLeadIns(text)).slice(0, 60);
  const short = String(subject || "")
    .replace(/\s+/g, " ")
    // A place written in caps from the middle of a sentence reads as shouting.
    .replace(/\b([A-Z]{2,})\b/g, (word) => word.charAt(0) + word.slice(1).toLowerCase())
    .trim()
    .slice(0, 70);
  const tidy = (place) =>
    String(place).replace(/\b([A-Z]{2,})\b/g, (word) => word.charAt(0) + word.slice(1).toLowerCase());
  // A refined request is titled for the refinement: "Bars in Lisbon", not the
  // question that started the conversation.
  const refinement = String(slots.refinement || "").trim();
  if (refinement && (kind === "restaurant" || kind === "shopping")) {
    const where = slots.location || slots.destination || "";
    const subject = refinement.charAt(0).toUpperCase() + refinement.slice(1);
    if (where) return `${subject} in ${tidy(where)}`;
    return subject;
  }

  const sentence = (value) => {
    const clean = String(value || "").trim();
    return clean ? clean.charAt(0).toUpperCase() + clean.slice(1) : "";
  };

  if (kind === "travel") {
    if (slots.destination && STAY_HINTS.test(text)) return `Stay in ${tidy(slots.destination)}`;
    if (slots.destination) return `Flights to ${tidy(slots.destination)}`;
    if (slots.origin) return `Flights from ${tidy(slots.origin)}`;
    return "Travel plan";
  }
  if (kind === "restaurant") {
    const place = slots.location || slots.destination || "";
    if (slots.mode === "delivery") return place ? `Delivery to ${tidy(place)}` : "Delivery";
    return place ? `Restaurants in ${tidy(place)}` : "Restaurants";
  }
  if (kind === "watch") {
    return short ? `Watching ${sentence(short)}` : "Watching";
  }
  if (kind === "invest") {
    // "AAPL · 10 shares" — the ticker and the size, the way an order reads.
    const symbol = String(slots.symbol || "").trim();
    const size = slots.quantity || slots.amount || "";
    const named = symbol === symbol.toUpperCase() ? symbol : sentence(symbol);
    if (named && size) return `${named} · ${size}`;
    if (named) return named;
    return sentence(short) || "Order";
  }
  // Shopping, auctions, research, plans: the subject itself is the title.
  return sentence(short) || `${prefix || "Task"} task`;
}

export { detectCounterparty };
