/**
 * Durable cross-app relay ledger.
 *
 * The prototype's two apps (Mira Aurea and Mira Orion) talk to the same local
 * proxy, so it doubles as the "network" between them. The original version kept
 * an in-memory array of transfers: it lost everything on restart, accepted any
 * amount, and could book the same transfer twice. This replaces it with a small
 * durable ledger that keeps its promises:
 *
 *   · every write runs inside one serialized promise chain
 *   · a write mutates a copy and is committed only after the file lands, so a
 *     failed write can never leave a half-booked balance
 *   · persistence is atomic (unique temp file + rename)
 *   · an idempotency key makes a retry or a repeated poll a no-op, and reusing a
 *     key for a different payload is refused rather than silently accepted
 *   · idempotency history is never evicted, so an old key can never run twice
 *   · amounts are positive, safe integers in the asset's own minor units
 *   · the asset must be supported, both identities must be known
 *   · a debit that would take a balance below zero is refused
 *   · a successful transfer returns a receipt that is stable across retries
 *   · a stored ledger that is corrupt or out of range is rejected, never
 *     silently reseeded with fresh money
 *
 * It is still a simulated ledger. Nothing here reaches a real bank or chain.
 */

import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { randomUUID } from "node:crypto";

export const IDENTITIES = ["Mira Aurea", "Mira Orion"];

export const ASSETS = {
  USD: { code: "USD", minorUnitScale: 2 },
  BRL: { code: "BRL", minorUnitScale: 2 },
  EUR: { code: "EUR", minorUnitScale: 2 },
  USDC: { code: "USDC", minorUnitScale: 6 },
  USDT: { code: "USDT", minorUnitScale: 6 },
};

const STORAGE_VERSION = 1;

/** Nothing in this prototype is a large transfer; the cap catches typos. */
export const MAX_TRANSFER_MINOR = 1_000_000_000_000; // 10 billion at 2dp / 1 million at 6dp
export const MAX_BALANCE_MINOR = 1_000_000_000_000_000;

/** Seed balances mirror the app's own seeded ledger, so the two agree. */
export function defaultBalances() {
  const balances = {};
  for (const identity of IDENTITIES) {
    balances[identity] = {
      USD: 179_360,
      BRL: 0,
      EUR: 32_000,
      USDC: 1_250_000_000,
      USDT: 0,
    };
  }
  return balances;
}

export function defaultStoragePath(env = process.env) {
  if (env.MIRA_RELAY_PATH) return resolve(env.MIRA_RELAY_PATH);
  const root = resolve(new URL("../..", import.meta.url).pathname);
  return resolve(root, ".build/relay/ledger.json");
}

class RelayError extends Error {
  constructor(code, detail) {
    super(detail || code);
    this.code = code;
    this.detail = detail || code;
  }
}

function failure(err) {
  if (err instanceof RelayError) {
    return { ok: false, error: err.code, detail: err.detail };
  }
  return { ok: false, error: "relay_failure", detail: String(err?.message || err) };
}

export class RelayLedger {
  /**
   * @param {{path?: string, now?: () => number, randomId?: () => string}} [options]
   */
  constructor({ path, now = Date.now, randomId = () => randomUUID() } = {}) {
    this.path = path || defaultStoragePath();
    this.now = now;
    this.randomId = randomId;
    this.data = {
      version: STORAGE_VERSION,
      updatedAt: this.now(),
      balances: defaultBalances(),
      transfers: [],
    };
    this.loaded = false;
    /** Serializes every read-modify-write so two transfers cannot interleave. */
    this.chain = Promise.resolve();
  }

  // -- persistence ---------------------------------------------------------

  async load() {
    if (this.loaded) return this;
    try {
      const raw = await readFile(this.path, "utf8");
      const parsed = JSON.parse(raw);
      this.data = this.#validate(parsed);
    } catch (err) {
      if (err && err.code === "ENOENT") {
        // First run: seed and persist, so a restart always finds the same book.
        await this.#persistData(this.data);
      } else {
        // A corrupt or out-of-range book is fatal. It is never replaced with
        // fresh seed balances, because that would silently mint money.
        throw err instanceof RelayError
          ? err
          : new RelayError("storage_unreadable", `Could not read the relay ledger: ${err.message}`);
      }
    }
    this.loaded = true;
    return this;
  }

  /**
   * Reject anything that is not a complete, in-range book.
   *
   * Missing identities, missing asset keys, negative or non-integer balances,
   * amounts above the cap and a malformed transfer history all fail loudly. The
   * alternative — substituting seed balances — is how a corrupt file quietly
   * becomes a funded account.
   */
  #validate(parsed) {
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new RelayError("storage_invalid", "Relay ledger is not an object.");
    }
    if (parsed.version !== undefined && parsed.version !== STORAGE_VERSION) {
      throw new RelayError(
        "storage_invalid",
        `Relay ledger version ${parsed.version} is not supported.`,
      );
    }
    if (!parsed.balances || typeof parsed.balances !== "object") {
      throw new RelayError("storage_invalid", "Relay ledger has no balances.");
    }

    const balances = {};
    for (const identity of IDENTITIES) {
      const source = parsed.balances[identity];
      if (!source || typeof source !== "object") {
        throw new RelayError("storage_invalid", `Relay ledger is missing balances for ${identity}.`);
      }
      balances[identity] = {};
      for (const code of Object.keys(ASSETS)) {
        const value = source[code];
        if (!Number.isSafeInteger(value) || value < 0 || value > MAX_BALANCE_MINOR) {
          throw new RelayError(
            "storage_invalid",
            `Relay ledger has an invalid ${code} balance for ${identity}.`,
          );
        }
        balances[identity][code] = value;
      }
    }

    if (parsed.transfers !== undefined && !Array.isArray(parsed.transfers)) {
      throw new RelayError("storage_invalid", "Relay ledger transfers are not a list.");
    }
    const transfers = [];
    const seenKeys = new Set();
    for (const transfer of parsed.transfers ?? []) {
      if (!transfer || typeof transfer !== "object") {
        throw new RelayError("storage_invalid", "Relay ledger contains a malformed transfer.");
      }
      const { id, idempotencyKey, from, to, asset, amountMinor, at } = transfer;
      if (typeof id !== "string" || !id) {
        throw new RelayError("storage_invalid", "A stored transfer has no id.");
      }
      if (typeof idempotencyKey !== "string" || !idempotencyKey) {
        throw new RelayError("storage_invalid", `Stored transfer ${id} has no idempotency key.`);
      }
      if (seenKeys.has(idempotencyKey)) {
        throw new RelayError("storage_invalid", `Stored transfer ${id} repeats an idempotency key.`);
      }
      seenKeys.add(idempotencyKey);
      if (!IDENTITIES.includes(from) || !IDENTITIES.includes(to) || from === to) {
        throw new RelayError("storage_invalid", `Stored transfer ${id} has invalid identities.`);
      }
      if (!ASSETS[asset]) {
        throw new RelayError("storage_invalid", `Stored transfer ${id} has an unsupported asset.`);
      }
      if (!Number.isSafeInteger(amountMinor) || amountMinor <= 0 || amountMinor > MAX_TRANSFER_MINOR) {
        throw new RelayError("storage_invalid", `Stored transfer ${id} has an invalid amount.`);
      }
      if (!Number.isInteger(at)) {
        throw new RelayError("storage_invalid", `Stored transfer ${id} has an invalid timestamp.`);
      }
      transfers.push({ ...transfer });
    }

    return {
      version: STORAGE_VERSION,
      updatedAt: Number.isInteger(parsed.updatedAt) ? parsed.updatedAt : this.now(),
      balances,
      transfers,
    };
  }

  /** Write one snapshot atomically. The temp name is unique, so two writers
   * cannot collide on it even if they somehow overlapped. */
  async #persistData(data) {
    data.updatedAt = this.now();
    const body = JSON.stringify(data, null, 2);
    await mkdir(dirname(this.path), { recursive: true });
    const tmp = `${this.path}.${process.pid}.${randomUUID()}.tmp`;
    await writeFile(tmp, body, "utf8");
    await rename(tmp, this.path);
  }

  /** Run `fn` with the data lock held. The chain survives a thrown operation. */
  #serialize(fn) {
    const run = this.chain.then(() => fn());
    this.chain = run.then(
      () => undefined,
      () => undefined,
    );
    return run;
  }

  // -- reads ---------------------------------------------------------------

  balances(identity) {
    return { ...(this.data.balances[identity] ?? {}) };
  }

  balance(identity, asset) {
    return this.data.balances[identity]?.[asset] ?? 0;
  }

  transfersFor(identity, since = 0) {
    return this.data.transfers.filter(
      (t) => (t.from === identity || t.to === identity) && t.at > since,
    );
  }

  recentTransfers(limit = 50) {
    return [...this.data.transfers].slice(-limit).reverse();
  }

  state(identity) {
    const isKnown = IDENTITIES.includes(identity);
    return {
      identity: isKnown ? identity : null,
      known: isKnown,
      balances: isKnown ? this.balances(identity) : defaultBalances(),
      transfers: isKnown ? this.transfersFor(identity, 0) : [],
      allIdentities: IDENTITIES,
      updatedAt: this.data.updatedAt,
    };
  }

  // -- writes --------------------------------------------------------------

  /**
   * Move simulated value between the two app identities.
   *
   * Shape validation happens first. The idempotency check, the balance check and
   * the mutation then happen inside the lock, on a copy, and are committed only
   * after the file lands. A repeated key with the same payload returns the
   * original receipt; a repeated key with a different payload is refused.
   *
   * @returns {Promise<{ok:true, transfer:object, duplicate:boolean}|{ok:false, error:string, detail:string}>}
   */
  async transfer({ idempotencyKey, from, to, asset, amountMinor, note } = {}) {
    try {
      this.#assertReady();
      const key = typeof idempotencyKey === "string" ? idempotencyKey.trim() : "";
      if (!key) throw new RelayError("idempotency_key_required", "An idempotency key is required.");
      if (key.length > 200) throw new RelayError("idempotency_key_invalid", "That key is too long.");

      const code = typeof asset === "string" ? asset.toUpperCase() : "";
      if (!ASSETS[code]) {
        throw new RelayError(
          "unsupported_asset",
          `Only ${Object.keys(ASSETS).join(", ")} are supported.`,
        );
      }
      if (!Number.isSafeInteger(amountMinor) || amountMinor <= 0) {
        throw new RelayError(
          "invalid_amount",
          "The amount must be a positive whole number of minor units.",
        );
      }
      if (amountMinor > MAX_TRANSFER_MINOR) {
        throw new RelayError("amount_exceeds_limit", "That amount is above this build's limit.");
      }
      if (!IDENTITIES.includes(from) || !IDENTITIES.includes(to)) {
        throw new RelayError("unknown_identity", "Both sender and recipient must be known identities.");
      }
      if (from === to) {
        throw new RelayError("same_identity", "Sender and recipient must differ.");
      }

      return await this.#serialize(() =>
        this.#executeTransfer({ key, from, to, code, amountMinor, note }),
      );
    } catch (err) {
      return failure(err);
    }
  }

  /** The locked half of `transfer`. Runs one at a time. */
  async #executeTransfer({ key, from, to, code, amountMinor, note }) {
    const existing = this.data.transfers.find((t) => t.idempotencyKey === key);
    if (existing) {
      const samePayload =
        existing.from === from &&
        existing.to === to &&
        existing.asset === code &&
        existing.amountMinor === amountMinor;
      if (!samePayload) {
        return {
          ok: false,
          error: "idempotency_conflict",
          detail: "That idempotency key was already used for a different transfer.",
        };
      }
      return { ok: true, transfer: existing, duplicate: true };
    }

    const available = this.balance(from, code);
    if (available < amountMinor) {
      return { ok: false, error: "insufficient_funds", detail: `Not enough ${code} in ${from}.` };
    }
    const recipientBalance = this.balance(to, code);
    if (recipientBalance + amountMinor > MAX_BALANCE_MINOR) {
      return { ok: false, error: "balance_limit", detail: "That would take the recipient above this build's limit." };
    }

    const at = this.now();
    const transfer = {
      id: `xfer_${this.randomId().replace(/-/g, "").slice(0, 16)}`,
      idempotencyKey: key,
      from,
      to,
      asset: code,
      amountMinor,
      note: String(note || "").slice(0, 160),
      at,
      status: "settled",
    };
    transfer.receipt = {
      id: transfer.id,
      at,
      from,
      to,
      asset: code,
      amountMinor,
      fromBalanceAfter: available - amountMinor,
      toBalanceAfter: recipientBalance + amountMinor,
      simulated: true,
    };

    // Build the next book without touching the live one. If the write fails,
    // `this.data` still describes the pre-transfer truth.
    const next = {
      ...this.data,
      balances: {
        ...this.data.balances,
        [from]: { ...this.data.balances[from], [code]: available - amountMinor },
        [to]: { ...this.data.balances[to], [code]: recipientBalance + amountMinor },
      },
      transfers: [...this.data.transfers, transfer],
    };

    try {
      await this.#persistData(next);
    } catch (err) {
      return {
        ok: false,
        error: "relay_persistence_failed",
        detail: `The transfer was not booked because it could not be saved: ${err.message}`,
      };
    }

    this.data = next;
    return { ok: true, transfer, duplicate: false };
  }

  /**
   * Legacy `/v1/xfer` compatibility.
   *
   * It no longer guesses the sender and it no longer mints a fresh idempotency
   * key, because both of those turned a retry into a second transfer. Callers
   * must name a known sender and supply their own stable key; anything else is
   * refused with a clear error.
   */
  async legacySend({ from, idempotencyKey, asset, amountMinor, note } = {}) {
    if (!IDENTITIES.includes(from)) {
      return {
        ok: false,
        error: "unknown_identity",
        detail: "The legacy endpoint requires a known sender; it will not substitute one.",
      };
    }
    if (typeof idempotencyKey !== "string" || !idempotencyKey.trim()) {
      return {
        ok: false,
        error: "idempotency_key_required",
        detail:
          "The legacy endpoint no longer mints a key. Send one, or use POST /v1/relay/transfer.",
      };
    }
    const recipient = from === IDENTITIES[0] ? IDENTITIES[1] : IDENTITIES[0];
    return this.transfer({
      idempotencyKey,
      from,
      to: recipient,
      asset,
      amountMinor: Number(amountMinor),
      note,
    });
  }

  #assertReady() {
    if (!this.loaded) {
      throw new RelayError("not_loaded", "The relay ledger has not been loaded.");
    }
  }
}
