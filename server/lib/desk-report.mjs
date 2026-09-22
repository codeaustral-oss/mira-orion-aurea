/**
 * The MoneyDesk report composite.
 *
 * WHY: the competitor scan (docs/nubank-revolut-scan.md, §4.2) found that
 * Nubank ships one deterministic API per job and the model only chooses the
 * tool — the model never does the arithmetic. This module is the smallest
 * version of that for the MoneyDesk questions this build advertises:
 * subscriptions, fees, offers and claims.
 *
 * What the server actually holds: the relay ledger, the durable task store and
 * the FX rates — not the app's engine data. Subscriptions, fee events, cashback
 * offers and claims all live in the app's own store (the app owns the engines,
 * and the app renders them on its own cards). Copying that store here would
 * create a second source of truth, so this composite is pure:
 *
 *   deskReport({ kind, records })
 *
 * renders ONE document from the stored records the caller passes in — the app's
 * records, or a task's — and returns `{ ok: false, detail }` when those records
 * are absent, rather than inventing a figure. Subscriptions are out of scope
 * for this pass for the same reason: they are app-side, and the app already
 * renders them from its own store.
 *
 * The document is the app's `ReceiptSpec.brief` shape, JSON-serialised:
 *
 *   {
 *     ok: true,
 *     title,                      // the heading, e.g. "USD 15.50 in fees"
 *     badge,                      // "FEES", "OFFERS", "CLAIM"
 *     symbol,                     // an SF Symbol name the app already renders
 *     lines: [{ label, value }],  // one row per finding/offer/claim
 *     total: { label, value } | null,
 *     footnote                    // the honest small print, or null
 *   }
 *
 * The arithmetic — summing fee findings, cap remaining, claim totals — happens
 * here, in integer minor units, deterministically: never in a model and never
 * in floating point. `formatMinor` from the orchestrator is the one money
 * formatter in this repository, so the composite does not grow a second one.
 *
 * Payloads (the records, documented so a caller cannot guess wrong):
 *
 *   fees:   { findings: [{ kind, totalMinor, currency, count, advice }] }
 *   offers: { currency, creditedMinor, pendingMinor,
 *             offers: [{ title, funding: "merchant"|"issuer",
 *                        capMinor, capUsedMinor, channel, days,
 *                        expiresAt, whyNotApplied }],
 *             issuer: { costMinor, merchantFundedMinor,
 *                       issuerFundedMinor, redemptions } }
 *   claims: { currency, claims: [{ item, kind, stage, amountMinor, currency,
 *                                  documents, deadline, reference }] }
 */

import { formatMinor } from "./orchestrate.mjs";

/** The kinds the /v1 caller may ask for. Unknown kinds are refused, never guessed. */
export const DESK_KINDS = Object.freeze(["subscriptions", "fees", "offers", "claims"]);

function refuse(detail) {
  return { ok: false, detail };
}

function isMinor(value) {
  return Number.isSafeInteger(value);
}

/** The one document shape this composite emits. */
function document({ title, badge, symbol, lines, total, footnote }) {
  return {
    ok: true,
    title,
    badge,
    symbol,
    lines,
    total: total ?? null,
    footnote: footnote ?? null,
  };
}

/** Normalise a currency code; null when the record does not name one. */
function currencyOf(record) {
  if (!record || typeof record.currency !== "string") return null;
  const code = record.currency.trim().toUpperCase();
  return code || null;
}

/**
 * Every currency the records declare, de-duplicated. A document may only be
 * totalled in one currency; two currencies in one total would be a lie, so the
 * callers below refuse instead of adding reais to dollars.
 */
function declaredCurrencies(records, entries) {
  const codes = [currencyOf(records), ...entries.map(currencyOf)].filter(Boolean);
  return [...new Set(codes)];
}

// ---------------------------------------------------------------------------
// fees — the fee radar's findings
// ---------------------------------------------------------------------------

/**
 * Mirrors `ReceiptSpec.brief` from the app's fee radar: the total in the
 * heading, one row per fee kind, the advice as the footnote.
 */
function feesReport(records) {
  const findings = Array.isArray(records.findings) ? records.findings : [];
  if (!findings.length) return refuse("No fee findings were passed in.");

  const currencies = declaredCurrencies(records, findings);
  if (currencies.length !== 1) {
    return refuse(
      "Fee findings do not name one currency, so they cannot be summed into one total."
    );
  }
  const currency = currencies[0];

  let total = 0;
  const lines = [];
  for (const finding of findings) {
    if (!isMinor(finding.totalMinor)) {
      return refuse("A fee finding carries no whole minor-unit total.");
    }
    total += finding.totalMinor;
    const count = Number.isSafeInteger(finding.count) ? ` · ${finding.count}x` : "";
    lines.push({
      label: String(finding.kind || finding.label || "Fee"),
      value: `${formatMinor(finding.totalMinor, currency)}${count}`,
    });
  }
  if (!Number.isSafeInteger(total)) {
    return refuse("The fee total left the safe integer range.");
  }

  return document({
    title: `${formatMinor(total, currency)} in fees`,
    badge: "FEES",
    symbol: "percent",
    lines,
    total: { label: "Total", value: formatMinor(total, currency) },
    footnote: findings[0].advice ? String(findings[0].advice) : null,
  });
}

// ---------------------------------------------------------------------------
// offers — the issuer's side of the card
// ---------------------------------------------------------------------------

/**
 * Mirrors the app's offers document, with the two things §4.4 of the scan asks
 * for: who funds each offer (merchant vs issuer) and the cap remaining. The
 * remaining cap is computed here from cap minus used, never taken on trust.
 */
function offersReport(records) {
  const offers = Array.isArray(records.offers) ? records.offers : [];
  if (!offers.length) return refuse("No offers were passed in.");

  for (const offer of offers) {
    if (isMinor(offer.capUsedMinor) && (!isMinor(offer.capMinor) || offer.capUsedMinor > offer.capMinor)) {
      return refuse("An offer's cap usage exceeds its cap; the records are inconsistent.");
    }
  }

  const issuer = records.issuer && typeof records.issuer === "object" ? records.issuer : null;
  const currencies = declaredCurrencies(records, offers);
  const needsMoney =
    isMinor(records.creditedMinor) ||
    isMinor(records.pendingMinor) ||
    isMinor(issuer?.costMinor) ||
    offers.some((offer) => isMinor(offer.capMinor) || isMinor(offer.capUsedMinor));
  if (needsMoney && currencies.length !== 1) {
    return refuse("Money figures were passed without one currency to render them in.");
  }
  const currency = currencies[0] ?? null;

  const lines = offers.map((offer) => {
    const conditions = [];
    const funding = String(offer.funding || "").toLowerCase();
    if (funding === "merchant") conditions.push("merchant-funded");
    else if (funding === "issuer") conditions.push("issuer-funded");
    if (offer.days) conditions.push(String(offer.days));
    if (offer.channel && String(offer.channel).toLowerCase() !== "any") {
      conditions.push(String(offer.channel));
    }
    if (isMinor(offer.capMinor)) {
      const used = isMinor(offer.capUsedMinor) ? offer.capUsedMinor : 0;
      conditions.push(`cap ${formatMinor(offer.capMinor - used, currency)} left`);
    }
    if (Number.isFinite(offer.expiresAt)) {
      conditions.push(`ends ${new Date(offer.expiresAt).toISOString().slice(0, 10)}`);
    }
    // Why an offer did not apply is part of the card, not fine print.
    if (offer.whyNotApplied) conditions.push(`not applied: ${String(offer.whyNotApplied)}`);
    return { label: String(offer.title || "Offer"), value: conditions.join(" · ") };
  });

  const title = isMinor(records.creditedMinor)
    ? `${formatMinor(records.creditedMinor, currency)} back this month`
    : `${offers.length} offer${offers.length === 1 ? "" : "s"} running`;

  let total = null;
  if (isMinor(issuer?.costMinor)) {
    total = { label: "Issuer cost", value: formatMinor(issuer.costMinor, currency) };
  } else if (isMinor(records.pendingMinor)) {
    total = { label: "Pending", value: formatMinor(records.pendingMinor, currency) };
  }

  const footnoteBits = [];
  if (issuer && isMinor(issuer.merchantFundedMinor) && isMinor(issuer.issuerFundedMinor)) {
    const redemptions = Number.isSafeInteger(issuer.redemptions)
      ? ` ${issuer.redemptions} redemption${issuer.redemptions === 1 ? "" : "s"} this month.`
      : "";
    footnoteBits.push(
      `${formatMinor(issuer.merchantFundedMinor, currency)} of that is merchant-funded; ` +
        `${formatMinor(issuer.issuerFundedMinor, currency)} is ours.${redemptions}`
    );
  }
  if (isMinor(records.pendingMinor) && total?.label !== "Pending") {
    footnoteBits.push(`${formatMinor(records.pendingMinor, currency)} still pending.`);
  }
  if (!footnoteBits.length) footnoteBits.push("Funding is named on each offer.");

  return document({
    title,
    badge: "OFFERS",
    symbol: "tag",
    lines,
    total,
    footnote: footnoteBits.join(" "),
  });
}

// ---------------------------------------------------------------------------
// claims — price claims and compensation packs
// ---------------------------------------------------------------------------

/**
 * Mirrors the app's claims receipt: the documents are the rows, the claim
 * amount is the emphasised line, and the footnote says plainly that nothing
 * has been filed. Several claims list one row each and total only when every
 * amount shares one currency.
 */
function claimsReport(records) {
  const claims = Array.isArray(records.claims) ? records.claims : [];
  if (!claims.length) return refuse("No claims were passed in.");

  const currencies = declaredCurrencies(records, claims);
  const withAmount = claims.filter((claim) => isMinor(claim.amountMinor));
  if (withAmount.length && currencies.length !== 1) {
    return refuse("Claim amounts use more than one currency, so they cannot be summed into one total.");
  }
  const currency = currencies[0] ?? null;

  if (claims.length === 1) {
    const claim = claims[0];
    const documents = Array.isArray(claim.documents) ? claim.documents : [];
    const lines = documents.length
      ? documents.map((doc) => ({ label: "Document", value: String(doc) }))
      : [{ label: "Claim", value: String(claim.item || claim.kind || "Prepared") }];
    return document({
      title: String(claim.label || claim.kind || claim.item || "Claim"),
      badge: "CLAIM",
      symbol: "doc.badge.clock",
      lines,
      total: isMinor(claim.amountMinor)
        ? { label: "Claiming", value: formatMinor(claim.amountMinor, currency) }
        : null,
      footnote: claim.reference
        ? `Reference ${String(claim.reference)}. Nothing is filed until you say so.`
        : "Nothing is filed until you say so.",
    });
  }

  const lines = claims.map((claim) => {
    const bits = [];
    if (claim.stage) bits.push(String(claim.stage));
    if (isMinor(claim.amountMinor)) bits.push(formatMinor(claim.amountMinor, currency));
    return {
      label: String(claim.item || claim.kind || "Claim"),
      value: bits.join(" · ") || "Prepared",
    };
  });

  const totalMinor = withAmount.reduce((sum, claim) => sum + claim.amountMinor, 0);
  const totals = withAmount.length === claims.length && Number.isSafeInteger(totalMinor);
  return document({
    title: `${claims.length} claims prepared`,
    badge: "CLAIM",
    symbol: "doc.badge.clock",
    lines,
    total: totals ? { label: "Claiming", value: formatMinor(totalMinor, currency) } : null,
    footnote: "Nothing is filed until you say so.",
  });
}

// ---------------------------------------------------------------------------
// The composite
// ---------------------------------------------------------------------------

/**
 * Render one desk document for a question.
 *
 * @param {{kind: "subscriptions"|"fees"|"offers"|"claims", records?: object}} input
 * @returns {{ok:true, title:string, badge:string, symbol:string,
 *            lines:{label:string,value:string}[], total:{label:string,value:string}|null,
 *            footnote:string|null} | {ok:false, detail:string}}
 */
export function deskReport({ kind, records = null } = {}) {
  if (!DESK_KINDS.includes(kind)) {
    return refuse(`'${String(kind)}' is not a desk report kind (${DESK_KINDS.join(", ")}).`);
  }
  if (kind === "subscriptions") {
    // The app owns subscriptions and renders them itself. A server copy would
    // be a second source of truth for the person's recurring charges.
    return refuse("Subscriptions live in the app's own store; this composite does not duplicate them.");
  }
  if (!records || typeof records !== "object") {
    return refuse(`The server does not hold ${kind} records; pass the stored records in.`);
  }
  switch (kind) {
    case "fees":
      return feesReport(records);
    case "offers":
      return offersReport(records);
    case "claims":
      return claimsReport(records);
    default:
      return refuse(`'${kind}' is not implemented.`);
  }
}
