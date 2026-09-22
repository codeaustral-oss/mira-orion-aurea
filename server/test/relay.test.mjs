/**
 * Relay ledger regression tests.
 *
 * These exist because the cross-app demo's promises are all about not
 * double-spending, not losing state, and not inventing money. Each test uses a
 * throwaway storage path under the OS temp directory, so a test run never
 * touches the real demo ledger.
 *
 *   node --test server/test/
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { RelayLedger, IDENTITIES, ASSETS, defaultBalances } from "../lib/ledger-relay.mjs";

const [AUREA, ORION] = IDENTITIES;

async function tempPath(name = "ledger.json") {
  const dir = await mkdtemp(join(tmpdir(), "mira-relay-"));
  return { dir, path: join(dir, name) };
}

async function freshLedger(now = () => 1_000_000) {
  const { dir, path } = await tempPath();
  const ledger = new RelayLedger({ path, now, randomId: (() => {
    let n = 0;
    return () => `id-${(n += 1)}`;
  })() });
  await ledger.load();
  return { ledger, dir, path };
}

test("seeds both identities with the app's own starting balances", async () => {
  const { ledger, dir } = await freshLedger();
  try {
    for (const identity of IDENTITIES) {
      assert.equal(ledger.balance(identity, "USD"), 179_360);
      assert.equal(ledger.balance(identity, "EUR"), 32_000);
      assert.equal(ledger.balance(identity, "USDC"), 1_250_000_000);
      assert.equal(ledger.balance(identity, "BRL"), 0);
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("a settled transfer debits the sender and credits the recipient once", async () => {
  const { ledger, dir } = await freshLedger();
  try {
    const outcome = await ledger.transfer({
      idempotencyKey: "k-1",
      from: AUREA,
      to: ORION,
      asset: "USD",
      amountMinor: 10_000,
    });
    assert.equal(outcome.ok, true);
    assert.equal(outcome.duplicate, false);
    assert.equal(ledger.balance(AUREA, "USD"), 169_360);
    assert.equal(ledger.balance(ORION, "USD"), 189_360);
    assert.equal(outcome.transfer.receipt.simulated, true);
    assert.equal(outcome.transfer.status, "settled");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("a repeated idempotency key returns the original receipt and moves nothing", async () => {
  const { ledger, dir } = await freshLedger();
  try {
    const first = await ledger.transfer({
      idempotencyKey: "retry-me",
      from: AUREA,
      to: ORION,
      asset: "USDC",
      amountMinor: 5_000_000,
    });
    const second = await ledger.transfer({
      idempotencyKey: "retry-me",
      from: AUREA,
      to: ORION,
      asset: "USDC",
      amountMinor: 5_000_000,
    });
    assert.equal(second.ok, true);
    assert.equal(second.duplicate, true);
    assert.equal(second.transfer.id, first.transfer.id);
    assert.equal(ledger.balance(AUREA, "USDC"), 1_245_000_000);
    assert.equal(ledger.transfersFor(AUREA, 0).length, 1);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("insufficient funds are refused and the book is untouched", async () => {
  const { ledger, dir } = await freshLedger();
  try {
    const before = ledger.balance(AUREA, "BRL");
    const outcome = await ledger.transfer({
      idempotencyKey: "too-much",
      from: AUREA,
      to: ORION,
      asset: "BRL",
      amountMinor: 1,
    });
    assert.equal(outcome.ok, false);
    assert.equal(outcome.error, "insufficient_funds");
    assert.equal(ledger.balance(AUREA, "BRL"), before);
    assert.equal(ledger.transfersFor(AUREA, 0).length, 0);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("rejects non-positive, non-integer and unknown-asset amounts", async () => {
  const { ledger, dir } = await freshLedger();
  try {
    const cases = [
      { amountMinor: 0, asset: "USD", error: "invalid_amount" },
      { amountMinor: -5, asset: "USD", error: "invalid_amount" },
      { amountMinor: 1.5, asset: "USD", error: "invalid_amount" },
      { amountMinor: 100, asset: "XYZ", error: "unsupported_asset" },
    ];
    for (const c of cases) {
      const outcome = await ledger.transfer({
        idempotencyKey: `bad-${c.error}-${c.amountMinor}`,
        from: AUREA,
        to: ORION,
        asset: c.asset,
        amountMinor: c.amountMinor,
      });
      assert.equal(outcome.ok, false, `expected ${c.error}`);
      assert.equal(outcome.error, c.error);
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("refuses unknown identities, self-transfers and a missing idempotency key", async () => {
  const { ledger, dir } = await freshLedger();
  try {
    const unknown = await ledger.transfer({
      idempotencyKey: "u", from: "Someone Else", to: ORION, asset: "USD", amountMinor: 100,
    });
    assert.equal(unknown.error, "unknown_identity");

    const self = await ledger.transfer({
      idempotencyKey: "s", from: AUREA, to: AUREA, asset: "USD", amountMinor: 100,
    });
    assert.equal(self.error, "same_identity");

    const noKey = await ledger.transfer({
      from: AUREA, to: ORION, asset: "USD", amountMinor: 100,
    });
    assert.equal(noKey.error, "idempotency_key_required");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("a restart finds the same book and replays nothing", async () => {
  const { dir, path } = await tempPath();
  try {
    const first = new RelayLedger({ path, now: () => 5_000 });
    await first.load();
    await first.transfer({
      idempotencyKey: "persist-1",
      from: ORION,
      to: AUREA,
      asset: "EUR",
      amountMinor: 1_500,
    });
    assert.equal(first.balance(AUREA, "EUR"), 33_500);

    // A brand-new process reading the same file.
    const second = new RelayLedger({ path, now: () => 6_000 });
    await second.load();
    assert.equal(second.balance(AUREA, "EUR"), 33_500);
    assert.equal(second.balance(ORION, "EUR"), 30_500);
    assert.equal(second.transfersFor(AUREA, 0).length, 1);

    // The same key after a restart still returns the original receipt.
    const replay = await second.transfer({
      idempotencyKey: "persist-1",
      from: ORION,
      to: AUREA,
      asset: "EUR",
      amountMinor: 1_500,
    });
    assert.equal(replay.duplicate, true);
    assert.equal(second.balance(AUREA, "EUR"), 33_500);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("the storage file is valid JSON with a stable shape", async () => {
  const { ledger, dir, path } = await freshLedger();
  try {
    await ledger.transfer({
      idempotencyKey: "shape-1", from: AUREA, to: ORION, asset: "USD", amountMinor: 250,
    });
    const parsed = JSON.parse(await readFile(path, "utf8"));
    assert.equal(parsed.version, 1);
    assert.ok(parsed.balances[AUREA]);
    assert.ok(parsed.balances[ORION]);
    assert.equal(parsed.transfers.length, 1);
    assert.equal(parsed.transfers[0].idempotencyKey, "shape-1");
    assert.equal(parsed.transfers[0].amountMinor, 250);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("concurrent transfers serialize without losing or double-booking value", async () => {
  const { ledger, dir } = await freshLedger();
  try {
    const amount = 100;
    const parallel = 20;
    await Promise.all(
      Array.from({ length: parallel }, (_, i) =>
        ledger.transfer({
          idempotencyKey: `race-${i}`,
          from: AUREA,
          to: ORION,
          asset: "USD",
          amountMinor: amount,
        })
      )
    );
    assert.equal(ledger.balance(AUREA, "USD"), 179_360 - amount * parallel);
    assert.equal(ledger.balance(ORION, "USD"), 179_360 + amount * parallel);
    assert.equal(ledger.transfersFor(AUREA, 0).length, parallel);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("legacy send refuses to guess a sender or mint an idempotency key", async () => {
  const { ledger, dir } = await freshLedger();
  try {
    const unknown = await ledger.legacySend({
      from: "Someone Else", idempotencyKey: "legacy-1", asset: "USDC", amountMinor: 1_000_000,
    });
    assert.equal(unknown.ok, false);
    assert.equal(unknown.error, "unknown_identity");

    const noKey = await ledger.legacySend({ from: AUREA, asset: "USDC", amountMinor: 1_000_000 });
    assert.equal(noKey.ok, false);
    assert.equal(noKey.error, "idempotency_key_required");

    const first = await ledger.legacySend({
      from: AUREA, idempotencyKey: "legacy-ok", asset: "USDC", amountMinor: 1_000_000, note: "hi",
    });
    assert.equal(first.ok, true);
    assert.equal(first.transfer.from, AUREA);
    assert.equal(first.transfer.to, ORION);
    assert.equal(ledger.balance(ORION, "USDC"), 1_251_000_000);

    // The same key again is a duplicate and moves nothing.
    const replay = await ledger.legacySend({
      from: AUREA, idempotencyKey: "legacy-ok", asset: "USDC", amountMinor: 1_000_000,
    });
    assert.equal(replay.duplicate, true);
    assert.equal(ledger.balance(ORION, "USDC"), 1_251_000_000);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("the state view is scoped to a known identity and hides nothing", async () => {
  const { ledger, dir } = await freshLedger();
  try {
    await ledger.transfer({
      idempotencyKey: "state-1", from: AUREA, to: ORION, asset: "USD", amountMinor: 500,
    });
    const state = ledger.state(ORION);
    assert.equal(state.known, true);
    assert.equal(state.identity, ORION);
    assert.equal(state.transfers.length, 1);
    assert.equal(state.transfers[0].from, AUREA);

    const unknown = ledger.state("Nobody");
    assert.equal(unknown.known, false);
    assert.equal(unknown.transfers.length, 0);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("supported assets expose their own minor-unit scales", () => {
  assert.equal(ASSETS.USD.minorUnitScale, 2);
  assert.equal(ASSETS.USDC.minorUnitScale, 6);
});

// ---------------------------------------------------------------------------
// The failure modes that the first implementation got wrong.
// ---------------------------------------------------------------------------

test("a fixed-clock burst books every transfer and reports every success", async () => {
  // The old version reported nine failures while still debiting all ten. Every
  // transfer here shares one clock value, so a temp-file name built from the
  // clock alone would collide.
  const { ledger, dir, path } = await freshLedger(() => 42);
  try {
    const amount = 100;
    const parallel = 10;
    const outcomes = await Promise.all(
      Array.from({ length: parallel }, (_, i) =>
        ledger.transfer({
          idempotencyKey: `fixed-${i}`,
          from: AUREA,
          to: ORION,
          asset: "USD",
          amountMinor: amount,
        })
      )
    );
    assert.equal(outcomes.filter((o) => o.ok).length, parallel);
    assert.equal(ledger.balance(AUREA, "USD"), 179_360 - amount * parallel);
    assert.equal(ledger.balance(ORION, "USD"), 179_360 + amount * parallel);
    const persisted = JSON.parse(await readFile(path, "utf8"));
    assert.equal(persisted.transfers.length, parallel);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("a failed write is rolled back, and the same key can retry afterwards", async () => {
  const { ledger, dir, path } = await freshLedger();
  try {
    const blocker = join(dir, "not-a-directory");
    await writeFile(blocker, "x", "utf8");

    // Point the ledger at a path whose parent is a file, so the write fails.
    ledger.path = join(blocker, "ledger.json");
    const failed = await ledger.transfer({
      idempotencyKey: "rollback-1", from: AUREA, to: ORION, asset: "USD", amountMinor: 500,
    });
    assert.equal(failed.ok, false);
    assert.equal(failed.error, "relay_persistence_failed");
    // Nothing was booked: the in-memory book still shows the old truth.
    assert.equal(ledger.balance(AUREA, "USD"), 179_360);
    assert.equal(ledger.balance(ORION, "USD"), 179_360);
    assert.equal(ledger.transfersFor(AUREA, 0).length, 0);

    // A failed write must not have consumed the key.
    ledger.path = path;
    const retry = await ledger.transfer({
      idempotencyKey: "rollback-1", from: AUREA, to: ORION, asset: "USD", amountMinor: 500,
    });
    assert.equal(retry.ok, true);
    assert.equal(retry.duplicate, false);
    assert.equal(ledger.balance(AUREA, "USD"), 178_860);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("reusing an idempotency key for a different transfer is a conflict", async () => {
  const { ledger, dir } = await freshLedger();
  try {
    const first = await ledger.transfer({
      idempotencyKey: "same-key", from: AUREA, to: ORION, asset: "USD", amountMinor: 1_000,
    });
    assert.equal(first.ok, true);

    const differentAmount = await ledger.transfer({
      idempotencyKey: "same-key", from: AUREA, to: ORION, asset: "USD", amountMinor: 2_000,
    });
    assert.equal(differentAmount.ok, false);
    assert.equal(differentAmount.error, "idempotency_conflict");

    const differentRecipient = await ledger.transfer({
      idempotencyKey: "same-key", from: ORION, to: AUREA, asset: "USD", amountMinor: 1_000,
    });
    assert.equal(differentRecipient.error, "idempotency_conflict");

    // The original transfer is untouched and nothing moved a second time.
    assert.equal(ledger.balance(AUREA, "USD"), 178_360);
    assert.equal(ledger.transfersFor(AUREA, 0).length, 1);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("idempotency history is never evicted, so an old key cannot run twice", async () => {
  const { dir, path } = await tempPath();
  try {
    // Pre-seed more transfers than the old 1000-entry cap.
    const transfers = Array.from({ length: 1_500 }, (_, i) => ({
      id: `xfer_${i}`,
      idempotencyKey: `key-${i}`,
      from: AUREA,
      to: ORION,
      asset: "USD",
      amountMinor: 1,
      note: "",
      at: i + 1,
      status: "settled",
    }));
    await writeFile(
      path,
      JSON.stringify({ version: 1, updatedAt: 1, balances: defaultBalances(), transfers }),
      "utf8"
    );

    const ledger = new RelayLedger({ path, now: () => 9_999 });
    await ledger.load();
    assert.equal(ledger.transfersFor(AUREA, 0).length, 1_500);

    const replay = await ledger.transfer({
      idempotencyKey: "key-0", from: AUREA, to: ORION, asset: "USD", amountMinor: 1,
    });
    assert.equal(replay.duplicate, true);
    assert.equal(replay.transfer.id, "xfer_0");
    assert.equal(ledger.transfersFor(AUREA, 0).length, 1_500);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("a missing or malformed stored balance is rejected, not reseeded", async () => {
  const { dir, path } = await tempPath();
  try {
    const broken = defaultBalances();
    broken[AUREA].USD = -5;
    await writeFile(
      path,
      JSON.stringify({ version: 1, updatedAt: 1, balances: broken, transfers: [] }),
      "utf8"
    );
    const ledger = new RelayLedger({ path, now: () => 1 });
    await assert.rejects(() => ledger.load(), (err) => err.code === "storage_invalid");
    // The on-disk file is untouched.
    const stillBroken = JSON.parse(await readFile(path, "utf8"));
    assert.equal(stillBroken.balances[AUREA].USD, -5);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("unparseable storage fails loudly instead of starting a fresh seeded book", async () => {
  const { dir, path } = await tempPath();
  try {
    await writeFile(path, "{ this is not json", "utf8");
    const ledger = new RelayLedger({ path, now: () => 1 });
    await assert.rejects(() => ledger.load(), (err) => err.code === "storage_unreadable");
    const raw = await readFile(path, "utf8");
    assert.equal(raw, "{ this is not json");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
