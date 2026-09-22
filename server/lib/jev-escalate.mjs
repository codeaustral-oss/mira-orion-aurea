/**
 * Below-floor escalation — plan A.4.
 *
 * A typed read that lands below its floor is exactly the read code must not act
 * on. For three decisions the plan allows one second, differently-asked read:
 * whether a message authorises a payment (`readConsent.authorises`), whether a
 * quoted rate is the right way round (`verifyQuote.direction_is_right`), and
 * whether a message is asking for advice (`classifyAdvice.wants_advice`, in the
 * 0.35–0.5 band only). Nowhere else.
 *
 * The helper keeps that shape in one place and nothing more:
 *
 *   · a first read at or above the floor is returned untouched and the second
 *     ask is never made (zero extra calls);
 *   · a first read below the floor triggers exactly one second ask;
 *   · the second read replaces the first only when it *clears the floor* — a
 *     second answer that is also below the floor changes nothing, so the
 *     caller's deterministic path is byte-for-byte what it was before.
 *
 * `firstRead` and whatever `secondAsk()` resolves to share one shape:
 *
 *   { ok, value, confidence?, latencyMs?, detail? }
 *
 * `value` is the typed answer on the caller's own scale — for a negated second
 * question the caller inverts it before handing it back, so both reads measure
 * the same quantity. `confidence` is how sure the model was; it decides only
 * between two reads that both clear the floor, and it is never a reason to
 * trust a below-floor answer. Policy stays in the caller: this module picks
 * which reading is believed, and nothing else.
 */

export const ESCALATION_FLOOR = 0.5;

function normalise(read) {
  if (!read || typeof read !== "object") {
    return { ok: false, value: null, confidence: null, latencyMs: 0, detail: null };
  }
  return {
    ok: read.ok === true,
    value: typeof read.value === "number" ? read.value : null,
    confidence: typeof read.confidence === "number" ? read.confidence : null,
    latencyMs: typeof read.latencyMs === "number" ? read.latencyMs : 0,
    detail: read.detail ?? null,
  };
}

/**
 * Escalate one below-floor reading.
 *
 * @param {string} key            the decision's name (returned for logging/tests)
 * @param {{ok:boolean, value:number|null, confidence?:number|null, latencyMs?:number}} firstRead
 * @param {() => Promise<object>} secondAsk   the differently-asked read
 * @param {{floor?:number, min?:number}} [options]  `min` narrows escalation to a
 *        band (the advice read only pays twice between 0.35 and 0.5)
 * @returns {Promise<{ok:boolean, value:number|null, confidence:number|null,
 *                    latencyMs:number, key:string, escalated:boolean,
 *                    source:"first"|"second"}>}
 */
export async function escalate(key, firstRead, secondAsk, { floor = ESCALATION_FLOOR, min = null } = {}) {
  const first = normalise(firstRead);
  const eligible =
    first.ok &&
    first.value !== null &&
    first.value < floor &&
    (min === null || first.value >= min);
  if (!eligible) return { ...first, key, escalated: false, source: "first" };

  let second = null;
  try {
    second = normalise(await secondAsk());
  } catch (err) {
    // A failed second read is not an answer: keep the first, exactly as the
    // caller would have without the escalation.
    second = normalise({ ok: false, detail: String(err?.message || err) });
  }
  const latencyMs = first.latencyMs + second.latencyMs;

  const clearsFloor = (read) => read.ok && read.value !== null && read.value >= floor;
  const candidates = [first, second].filter(clearsFloor);
  if (!candidates.length) {
    // Both readings are below the floor: today's deterministic path, to the
    // letter. The first read is returned exactly as it arrived.
    return { ...first, latencyMs, key, escalated: true, source: "first" };
  }
  candidates.sort((a, b) => (b.confidence ?? 0) - (a.confidence ?? 0));
  const chosen = candidates[0];
  return {
    ...chosen,
    latencyMs,
    key,
    escalated: true,
    source: chosen === second ? "second" : "first",
  };
}
