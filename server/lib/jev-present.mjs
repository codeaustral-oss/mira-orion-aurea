/**
 * Which document is this result?
 *
 * A finished task has a shape, and the shape decides the layout: a settled
 * payment is a receipt, a trip is an itinerary, a prepared table is a
 * reservation, a list of shops is picks. That mapping is plain code below, and
 * it is what runs when nothing else can.
 *
 * But the shape is not always obvious from the capability. A "research" task can
 * come back as a price comparison; a travel task can come back as nothing but a
 * list of links; a restaurant search for delivery is a list of dishes, not a
 * table. Reading *what the result actually is* is a typed decision — one Jev
 * call, a choice from a fixed catalogue — and code decides what to do with it.
 * The catalogue is deliberately closed: the app can render four layouts, so the
 * read can only choose among those.
 */

const ENDPOINT = "https://api.typesafe.ai/v1/systemone";
const TIMEOUT_MS = 6000;

/** What the app can actually render. A read outside this set is ignored. */
export const LAYOUTS = Object.freeze(["itinerary", "reservation", "order", "picks", "watch", "plain"]);

/** The shape plain code can see, used when there is no reading. */
export function defaultLayout({ kind, slots = {} } = {}) {
  switch (kind) {
    case "travel":
      return slots.destination || slots.origin ? "itinerary" : "plain";
    case "restaurant":
      // A delivered meal is a list of dishes; a table is a reservation.
      if (slots.mode === "delivery") return "picks";
      return slots.location || slots.date || slots.partySize || slots.time ? "reservation" : "plain";
    case "invest":
      // An order with a symbol and a size is a prepared order; without them it
      // is just a list of pages.
      return slots.symbol || slots.quantity || slots.amount ? "order" : "picks";
    case "watch":
      return "watch";
    case "shopping":
    case "auction":
    case "research":
      return "picks";
    default:
      return "plain";
  }
}

/**
 * @returns {Promise<{ok:boolean, layout?:string, confidence?:number, latencyMs:number}>}
 */
export async function readPresentation(
  { kind, title, summary, options = [], slots = {} },
  { fetchImpl = globalThis.fetch, signal } = {}
) {
  const key = process.env.TYPESAFE_API_KEY;
  if (!key) return { ok: false, detail: "No TYPESAFE_API_KEY configured.", latencyMs: 0 };

  const started = Date.now();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);
  const onAbort = () => controller.abort();
  if (signal) {
    if (signal.aborted) controller.abort();
    else signal.addEventListener("abort", onAbort, { once: true });
  }

  const optionNames = (Array.isArray(options) ? options : [])
    .slice(0, 5)
    .map((option) => String(option?.name || "").trim())
    .filter(Boolean);

  try {
    const response = await fetchImpl(ENDPOINT, {
      method: "POST",
      signal: controller.signal,
      headers: { "content-type": "application/json", authorization: `Bearer ${key}` },
      body: JSON.stringify({
        state: [
          `Capability: ${kind}`,
          `Title: ${title || "(none)"}`,
          `Summary: ${String(summary || "").slice(0, 600)}`,
          optionNames.length ? `Options: ${optionNames.join(" | ")}` : "Options: none",
          `Known details: ${JSON.stringify(slots).slice(0, 300)}`,
        ].join("\n"),
        model: process.env.TYPESAFE_MODEL || "jev-1.13.0",
        questions: {
          layout: {
            type: "choice",
            instructions:
              "What IS this result, so it can be laid out as the thing it is? Choose the layout that fits the content, not the request.",
            criteria: {
              itinerary:
                "A trip being planned: a route, dates or travellers. Prepared, not booked.",
              reservation:
                "A table or venue being prepared: a place, a day, a party. No table is held.",
              picks:
                "A choice between things to open — shops, listings, restaurants, flights, dishes.",
              order:
                "A prepared purchase of a security: a ticker, a size, a quoted price. Prepared, not executed.",
              watch: "A standing check with a schedule and a last result.",
              plain: "None of the above: a written answer with no document in it.",
            },
          },
        },
      }),
    });
    if (!response.ok) {
      return { ok: false, detail: `Jev answered HTTP ${response.status}.`, latencyMs: Date.now() - started };
    }
    const parsed = await response.json();
    const answers = parsed?.answers || {};
    return {
      ok: true,
      latencyMs: Date.now() - started,
      layout: answers?.layout?.choice ?? null,
      confidence: typeof answers?.layout?.confidence === "number" ? answers.layout.confidence : null,
      model: parsed?.model ?? null,
    };
  } catch (err) {
    const aborted = err?.name === "AbortError";
    return {
      ok: false,
      detail: aborted ? "Jev timed out." : `Jev call failed: ${err?.message || err}`,
      latencyMs: Date.now() - started,
    };
  } finally {
    clearTimeout(timer);
    if (signal) signal.removeEventListener("abort", onAbort);
  }
}

/** The reading if it is usable, the shape of the result if it is not. */
export function chooseLayout(read, context = {}) {
  const fallback = defaultLayout(context);
  if (!read?.ok) return fallback;
  if (!LAYOUTS.includes(read.layout)) return fallback;
  if (typeof read.confidence === "number" && read.confidence < 0.4) return fallback;
  return read.layout;
}
