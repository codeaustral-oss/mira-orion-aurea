/**
 * MoneyDesk composite tests.
 *
 * WHY: docs/nubank-revolut-scan.md §4.2 — one deterministic API per job, and
 * an eval that the model can never do the arithmetic. These tests hold the
 * composite to that: it sums in integer minor units, refuses mixed currencies
 * rather than adding reais to dollars, and returns an honest refusal when the
 * server does not hold the records. Deterministic: no network, no clock.
 */

import test from "node:test";
import assert from "node:assert/strict";

import { deskReport, DESK_KINDS } from "../lib/desk-report.mjs";

test("fees: the composite does the arithmetic in minor units, never the caller", () => {
  const report = deskReport({
    kind: "fees",
    records: {
      findings: [
        { kind: "FX mark-up", totalMinor: 1200, currency: "USD", count: 4, advice: "Use a weekday transfer." },
        { kind: "ATM", totalMinor: 350, currency: "USD", count: 1 },
      ],
    },
  });
  assert.equal(report.ok, true);
  assert.equal(report.badge, "FEES");
  assert.equal(report.symbol, "percent");
  assert.equal(report.title, "USD 15.50 in fees");
  assert.deepEqual(report.total, { label: "Total", value: "USD 15.50" });
  assert.equal(report.lines.length, 2);
  assert.deepEqual(report.lines[0], { label: "FX mark-up", value: "USD 12.00 · 4x" });
  assert.deepEqual(report.lines[1], { label: "ATM", value: "USD 3.50 · 1x" });
  assert.match(report.footnote, /weekday transfer/);
});

test("fees: absent, mixed-currency or float records are refused, never invented", () => {
  const absent = deskReport({ kind: "fees" });
  assert.equal(absent.ok, false);
  assert.match(absent.detail, /does not hold/);

  const mixed = deskReport({
    kind: "fees",
    records: {
      findings: [
        { kind: "FX", totalMinor: 100, currency: "USD" },
        { kind: "IOF", totalMinor: 100, currency: "BRL" },
      ],
    },
  });
  assert.equal(mixed.ok, false);
  assert.match(mixed.detail, /one currency/);

  const floaty = deskReport({
    kind: "fees",
    records: { findings: [{ kind: "FX", totalMinor: 12.34, currency: "USD" }] },
  });
  assert.equal(floaty.ok, false, "a float is not minor units");
  assert.match(floaty.detail, /minor-unit/);

  const empty = deskReport({ kind: "fees", records: { findings: [] } });
  assert.equal(empty.ok, false);
});

test("offers: funding, cap remaining and the issuer side come from the records", () => {
  const report = deskReport({
    kind: "offers",
    records: {
      currency: "BRL",
      creditedMinor: 3200,
      pendingMinor: 800,
      offers: [
        {
          title: "5% on groceries",
          funding: "merchant",
          capMinor: 5000,
          capUsedMinor: 2000,
          channel: "online",
          days: "weekends",
          expiresAt: Date.UTC(2026, 8, 30),
        },
        { title: "Fuel points", funding: "issuer", whyNotApplied: "out of category" },
      ],
      issuer: { costMinor: 4000, merchantFundedMinor: 2500, issuerFundedMinor: 1500, redemptions: 3 },
    },
  });
  assert.equal(report.ok, true);
  assert.equal(report.badge, "OFFERS");
  assert.equal(report.symbol, "tag");
  assert.equal(report.title, "BRL 32.00 back this month");
  assert.equal(report.lines[0].label, "5% on groceries");
  assert.match(report.lines[0].value, /merchant-funded/);
  assert.match(report.lines[0].value, /cap BRL 30\.00 left/);
  assert.match(report.lines[0].value, /online/);
  assert.match(report.lines[0].value, /ends 2026-09-30/);
  assert.match(report.lines[1].value, /issuer-funded/);
  assert.match(report.lines[1].value, /not applied: out of category/);
  assert.deepEqual(report.total, { label: "Issuer cost", value: "BRL 40.00" });
  assert.match(report.footnote, /BRL 25\.00 of that is merchant-funded/);
  assert.match(report.footnote, /BRL 15\.00 is ours/);
  assert.match(report.footnote, /3 redemptions this month/);
  assert.match(report.footnote, /BRL 8\.00 still pending/);
});

test("offers: inconsistent caps and money without a currency are refused", () => {
  const inconsistent = deskReport({
    kind: "offers",
    records: { currency: "BRL", offers: [{ title: "X", capMinor: 100, capUsedMinor: 200 }] },
  });
  assert.equal(inconsistent.ok, false);
  assert.match(inconsistent.detail, /inconsistent/);

  const currencyless = deskReport({
    kind: "offers",
    records: { creditedMinor: 100, offers: [{ title: "X", funding: "issuer" }] },
  });
  assert.equal(currencyless.ok, false);
  assert.match(currencyless.detail, /currency/);
});

test("claims: a single pack lists its documents and totals the claim", () => {
  const report = deskReport({
    kind: "claims",
    records: {
      claims: [
        {
          kind: "Flight delay",
          stage: "prepared",
          amountMinor: 12000,
          currency: "EUR",
          documents: ["Boarding pass", "Booking confirmation"],
          deadline: "2026-09-30",
        },
      ],
    },
  });
  assert.equal(report.ok, true);
  assert.equal(report.badge, "CLAIM");
  assert.equal(report.symbol, "doc.badge.clock");
  assert.equal(report.title, "Flight delay");
  assert.deepEqual(report.lines, [
    { label: "Document", value: "Boarding pass" },
    { label: "Document", value: "Booking confirmation" },
  ]);
  assert.deepEqual(report.total, { label: "Claiming", value: "EUR 120.00" });
  assert.match(report.footnote, /Nothing is filed until you say so/);
});

test("claims: several claims list one row each and sum only one currency", () => {
  const report = deskReport({
    kind: "claims",
    records: {
      claims: [
        { item: "Headphones", stage: "prepared", amountMinor: 2500, currency: "USD" },
        { item: "Shoes", stage: "filed", amountMinor: 1750, currency: "USD", reference: "PM-12345" },
      ],
    },
  });
  assert.equal(report.ok, true);
  assert.equal(report.title, "2 claims prepared");
  assert.deepEqual(report.lines, [
    { label: "Headphones", value: "prepared · USD 25.00" },
    { label: "Shoes", value: "filed · USD 17.50" },
  ]);
  assert.deepEqual(report.total, { label: "Claiming", value: "USD 42.50" });
});

test("claims: two currencies do not become one total", () => {
  const report = deskReport({
    kind: "claims",
    records: {
      claims: [
        { item: "A", amountMinor: 100, currency: "USD" },
        { item: "B", amountMinor: 100, currency: "BRL" },
      ],
    },
  });
  assert.equal(report.ok, false);
  assert.match(report.detail, /one currency/);
});

test("subscriptions stay with the app; the composite refuses to duplicate them", () => {
  const report = deskReport({
    kind: "subscriptions",
    records: { subscriptions: [{ name: "Netflix" }] },
  });
  assert.equal(report.ok, false);
  assert.match(report.detail, /app's own store/);
});

test("every advertised kind answers honestly with no records", () => {
  for (const kind of DESK_KINDS) {
    const report = deskReport({ kind });
    assert.equal(report.ok, false, `${kind} refuses without records`);
    assert.equal(typeof report.detail, "string");
    assert.ok(report.detail.length > 10);
  }
});

test("an unknown kind never invents a document", () => {
  const report = deskReport({ kind: "everything" });
  assert.equal(report.ok, false);
  assert.match(report.detail, /not a desk report kind/);
});

test("a document carries exactly the app's brief shape, with no float artefacts", () => {
  const report = deskReport({
    kind: "fees",
    records: { findings: [{ kind: "FX", totalMinor: 1234, currency: "USD" }] },
  });
  assert.deepEqual(
    Object.keys(report).sort(),
    ["badge", "footnote", "lines", "ok", "symbol", "title", "total"].sort()
  );
  assert.deepEqual(Object.keys(report.lines[0]).sort(), ["label", "value"]);
  assert.match(report.title, /USD 12\.34/);
  assert.equal(JSON.stringify(report).includes("1234"), false, "raw minor units never leak");

  const again = deskReport({
    kind: "fees",
    records: { findings: [{ kind: "FX", totalMinor: 1234, currency: "USD" }] },
  });
  assert.deepEqual(report, again, "the same records produce the same document");
});
