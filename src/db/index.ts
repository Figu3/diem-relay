import { Database } from "bun:sqlite";
import path from "path";
import fs from "fs";
import { SCHEMA } from "./schema";
import { todayUtc } from "../config";

const DB_PATH = path.join(import.meta.dir, "../../data/relay.db");

let _db: Database | null = null;

export function getDb(): Database {
  if (!_db) {
    const dir = path.dirname(DB_PATH);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });

    _db = new Database(DB_PATH);
    _db.exec("PRAGMA journal_mode = WAL");
    _db.exec("PRAGMA foreign_keys = ON");
    _db.exec(SCHEMA);
  }
  return _db;
}

// ── Borrower queries ──

export function getBorrower(address: string) {
  const db = getDb();
  return db
    .prepare("SELECT * FROM borrowers WHERE address = ?")
    .get(address.toLowerCase()) as BorrowerRow | undefined;
}

export function upsertBorrower(address: string, alias?: string) {
  const db = getDb();
  const addr = address.toLowerCase();
  db.prepare(
    `INSERT INTO borrowers (address, alias)
     VALUES (?, ?)
     ON CONFLICT(address) DO UPDATE SET
       alias = COALESCE(excluded.alias, alias),
       updated_at = unixepoch()`
  ).run(addr, alias ?? null);
  return getBorrower(addr)!;
}

// ── Dated credit operations ──

/**
 * Add a dated credit tranche for a borrower.
 * Credits are valid only on the specified date. Returns the new credit row.
 *
 * @param validDate - YYYY-MM-DD date this credit is valid for
 * @param purchaseType - 'advance' (next-day fixed discount) or 'sameday' (dutch auction)
 * @param discountRate - the rate paid (e.g. 0.85 = 15% off)
 */
export function addCredit(params: {
  address: string;
  amountUsd: number;
  validDate: string;
  purchaseType: "advance" | "sameday";
  discountRate: number;
  txHash?: string;
  note?: string;
}): { creditId: number; alreadyProcessed: boolean } {
  const db = getDb();
  const addr = params.address.toLowerCase();

  // Idempotency: if txHash already exists, skip
  if (params.txHash) {
    const existing = db
      .prepare("SELECT id FROM credits WHERE tx_hash = ?")
      .get(params.txHash);
    if (existing) {
      return { creditId: (existing as any).id, alreadyProcessed: true };
    }
  }

  let creditId = 0;

  const txn = db.transaction(() => {
    // Auto-create borrower if not exists
    db.prepare(
      `INSERT INTO borrowers (address) VALUES (?)
       ON CONFLICT(address) DO NOTHING`
    ).run(addr);

    // Insert credit tranche
    const result = db.prepare(
      `INSERT INTO credits (borrower, valid_date, purchase_type, original_usd, remaining_usd, discount_rate, tx_hash)
       VALUES (?, ?, ?, ?, ?, ?, ?)`
    ).run(
      addr,
      params.validDate,
      params.purchaseType,
      params.amountUsd,
      params.amountUsd,
      params.discountRate,
      params.txHash ?? null
    );
    creditId = Number(result.lastInsertRowid);

    // Also record in deposits table for legacy compatibility
    db.prepare(
      `INSERT INTO deposits (borrower, amount_usd, tx_hash, note)
       VALUES (?, ?, ?, ?)`
    ).run(addr, params.amountUsd, params.txHash ?? null, params.note ?? null);

    // Update denormalized balance (only if credit is for today)
    if (params.validDate === todayUtc()) {
      db.prepare(
        `UPDATE borrowers SET balance_usd = ROUND(balance_usd + ?, 6), updated_at = unixepoch()
         WHERE address = ?`
      ).run(params.amountUsd, addr);
    }
  });

  txn();
  return { creditId, alreadyProcessed: false };
}

/**
 * Get today's available credit balance for a borrower.
 * This is the authoritative source — sums remaining_usd from non-expired credits for today.
 */
export function getTodayBalance(address: string): number {
  const db = getDb();
  const addr = address.toLowerCase();
  const today = todayUtc();

  const row = db.prepare(
    `SELECT COALESCE(SUM(remaining_usd), 0) as total
     FROM credits
     WHERE borrower = ? AND valid_date = ? AND expired = 0 AND remaining_usd > 0`
  ).get(addr, today) as { total: number };

  return row.total;
}

/**
 * Sync the denormalized balance_usd on borrowers table with actual today's credits.
 * Call this on day boundary or after expiry sweep.
 */
export function syncBalance(address: string): void {
  const db = getDb();
  const addr = address.toLowerCase();
  const balance = getTodayBalance(addr);
  db.prepare(
    `UPDATE borrowers SET balance_usd = ROUND(?, 6), updated_at = unixepoch()
     WHERE address = ?`
  ).run(balance, addr);
}

// ── Daily reset helper ──

export function resetDailyIfNeeded(address: string): void {
  const db = getDb();
  const addr = address.toLowerCase();
  const now = Math.floor(Date.now() / 1000);
  const dayStart = now - (now % 86400);
  const borrower = getBorrower(addr);
  if (borrower && borrower.daily_reset < dayStart) {
    // Day boundary crossed — reset daily spend and sync balance from credits
    db.prepare(
      "UPDATE borrowers SET daily_spent = 0, daily_reset = ?, updated_at = unixepoch() WHERE address = ?"
    ).run(dayStart, addr);
    syncBalance(addr);
  }
}

export function getDailySpent(address: string): number {
  resetDailyIfNeeded(address);
  const b = getBorrower(address);
  return b?.daily_spent ?? 0;
}

// ── Balance reservation (TOCTOU-safe) ──

/**
 * Atomically reserve (deduct) from today's credit tranches.
 * Consumes credits FIFO (oldest first).
 * Returns true if the full amount was reserved.
 */
export function reserveBalance(address: string, estimatedUsd: number): boolean {
  const db = getDb();
  const addr = address.toLowerCase();
  const today = todayUtc();

  // Check total available first (fast path)
  const available = getTodayBalance(addr);
  if (available < estimatedUsd) return false;

  let remaining = estimatedUsd;

  const txn = db.transaction(() => {
    // Get today's credits with remaining balance, ordered by creation (FIFO)
    const credits = db.prepare(
      `SELECT id, remaining_usd FROM credits
       WHERE borrower = ? AND valid_date = ? AND expired = 0 AND remaining_usd > 0
       ORDER BY id ASC`
    ).all(addr, today) as Array<{ id: number; remaining_usd: number }>;

    for (const credit of credits) {
      if (remaining <= 0) break;
      const deduct = Math.min(remaining, credit.remaining_usd);
      db.prepare(
        `UPDATE credits SET remaining_usd = ROUND(remaining_usd - ?, 6) WHERE id = ?`
      ).run(deduct, credit.id);
      remaining -= deduct;
    }

    if (remaining > 0.000001) {
      // Couldn't reserve full amount (race condition) — rollback
      throw new Error("INSUFFICIENT_CREDITS");
    }

    // Update denormalized balance
    db.prepare(
      `UPDATE borrowers SET balance_usd = ROUND(balance_usd - ?, 6), updated_at = unixepoch()
       WHERE address = ?`
    ).run(estimatedUsd, addr);
  });

  try {
    txn();
    return true;
  } catch (e: any) {
    if (e.message === "INSUFFICIENT_CREDITS") return false;
    throw e;
  }
}

/**
 * Refund a previous reservation (e.g., Venice call failed).
 * Adds back to the most recent credit tranche for today.
 */
export function refundReservation(address: string, amountUsd: number): void {
  const db = getDb();
  const addr = address.toLowerCase();
  const today = todayUtc();

  const txn = db.transaction(() => {
    // Find the most recent credit tranche for today to refund into
    const credit = db.prepare(
      `SELECT id, original_usd, remaining_usd FROM credits
       WHERE borrower = ? AND valid_date = ? AND expired = 0
       ORDER BY id DESC LIMIT 1`
    ).get(addr, today) as { id: number; original_usd: number; remaining_usd: number } | undefined;

    if (credit) {
      // Don't refund more than original — cap at original_usd
      const maxRefund = Math.min(amountUsd, credit.original_usd - credit.remaining_usd);
      const actualRefund = Math.max(maxRefund, 0);

      if (actualRefund > 0) {
        db.prepare(
          `UPDATE credits SET remaining_usd = ROUND(remaining_usd + ?, 6) WHERE id = ?`
        ).run(actualRefund, credit.id);
      }

      // If there's leftover (credit was smaller than refund), create a new credit
      const leftover = amountUsd - actualRefund;
      if (leftover > 0.000001) {
        db.prepare(
          `INSERT INTO credits (borrower, valid_date, purchase_type, original_usd, remaining_usd, discount_rate)
           VALUES (?, ?, 'refund', ?, ?, 1.0)`
        ).run(addr, today, leftover, leftover);
      }
    } else {
      // No credit tranche exists for today — create a refund credit
      db.prepare(
        `INSERT INTO credits (borrower, valid_date, purchase_type, original_usd, remaining_usd, discount_rate)
         VALUES (?, ?, 'refund', ?, ?, 1.0)`
      ).run(addr, today, amountUsd, amountUsd);
    }

    // Update denormalized balance
    db.prepare(
      `UPDATE borrowers SET balance_usd = ROUND(balance_usd + ?, 6), updated_at = unixepoch()
       WHERE address = ?`
    ).run(amountUsd, addr);
  });

  txn();
}

// ── Usage settlement ──

/**
 * Settle actual usage after Venice responds. The balance was already reserved
 * via reserveBalance(), so this refunds the difference and records the log.
 */
export function settleUsage(params: {
  borrower: string;
  model: string;
  promptTokens: number;
  completionTokens: number;
  cacheTokens: number;
  costUsd: number;
  chargedUsd: number;
  protocolFee: number;
  requestId?: string;
  reservedUsd: number;
}) {
  const db = getDb();
  const addr = params.borrower.toLowerCase();
  const refund = params.reservedUsd - params.chargedUsd;

  const txn = db.transaction(() => {
    // Refund the difference between reserved and actual
    if (Math.abs(refund) > 0.000001) {
      if (refund > 0) {
        // Refund excess reservation back to credits
        refundReservation(addr, refund);
      } else {
        // Actual was more than reserved (rare) — deduct extra
        reserveBalance(addr, -refund);
      }
    }

    // Update spent counters
    resetDailyIfNeeded(addr);
    db.prepare(
      `UPDATE borrowers SET
         total_spent = ROUND(total_spent + ?, 6),
         daily_spent = ROUND(daily_spent + ?, 6),
         updated_at = unixepoch()
       WHERE address = ?`
    ).run(params.chargedUsd, params.chargedUsd, addr);

    // Log usage
    db.prepare(
      `INSERT INTO usage_logs
         (borrower, model, prompt_tokens, completion_tokens, cache_tokens, cost_usd, charged_usd, protocol_fee, request_id)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`
    ).run(
      addr,
      params.model,
      params.promptTokens,
      params.completionTokens,
      params.cacheTokens,
      params.costUsd,
      params.chargedUsd,
      params.protocolFee,
      params.requestId ?? null
    );
  });

  txn();
}

// ── Expiry sweep ──

/**
 * Mark all credits with valid_date < today as expired.
 * Returns the number of credits expired and total USD swept.
 */
export function sweepExpiredCredits(): { count: number; totalUsd: number } {
  const db = getDb();
  const today = todayUtc();

  // Get stats before sweep
  const stats = db.prepare(
    `SELECT COUNT(*) as count, COALESCE(SUM(remaining_usd), 0) as total
     FROM credits
     WHERE valid_date < ? AND expired = 0 AND remaining_usd > 0`
  ).get(today) as { count: number; total: number };

  if (stats.count === 0) return { count: 0, totalUsd: 0 };

  // Mark expired
  db.prepare(
    `UPDATE credits SET expired = 1
     WHERE valid_date < ? AND expired = 0`
  ).run(today);

  // Sync all affected borrowers' balances
  const affectedBorrowers = db.prepare(
    `SELECT DISTINCT borrower FROM credits WHERE valid_date < ? AND expired = 1`
  ).all(today) as Array<{ borrower: string }>;

  for (const { borrower } of affectedBorrowers) {
    syncBalance(borrower);
  }

  return { count: stats.count, totalUsd: stats.total };
}

/**
 * Get credit tranches for a borrower, optionally filtered by date.
 */
export function getCredits(address: string, validDate?: string) {
  const db = getDb();
  const addr = address.toLowerCase();

  if (validDate) {
    return db.prepare(
      `SELECT * FROM credits WHERE borrower = ? AND valid_date = ? ORDER BY id ASC`
    ).all(addr, validDate) as CreditRow[];
  }

  return db.prepare(
    `SELECT * FROM credits WHERE borrower = ? ORDER BY valid_date DESC, id ASC`
  ).all(addr) as CreditRow[];
}

// ── Usage queries ──

export function getUsageSummary(borrower?: string, sinceDaysAgo = 30) {
  const db = getDb();
  const since = Math.floor(Date.now() / 1000) - sinceDaysAgo * 86400;

  if (borrower) {
    return db
      .prepare(
        `SELECT
           COUNT(*) as requests,
           SUM(prompt_tokens) as total_prompt_tokens,
           SUM(completion_tokens) as total_completion_tokens,
           SUM(cache_tokens) as total_cache_tokens,
           SUM(cost_usd) as total_cost_usd,
           SUM(charged_usd) as total_charged_usd,
           SUM(protocol_fee) as total_protocol_fee
         FROM usage_logs
         WHERE borrower = ? AND created_at >= ?`
      )
      .get(borrower.toLowerCase(), since);
  }

  return db
    .prepare(
      `SELECT
         COUNT(*) as requests,
         SUM(prompt_tokens) as total_prompt_tokens,
         SUM(completion_tokens) as total_completion_tokens,
         SUM(cache_tokens) as total_cache_tokens,
         SUM(cost_usd) as total_cost_usd,
         SUM(charged_usd) as total_charged_usd,
         SUM(protocol_fee) as total_protocol_fee
       FROM usage_logs
       WHERE created_at >= ?`
    )
    .get(since);
}

export function getAllBorrowers() {
  const db = getDb();
  return db.prepare("SELECT * FROM borrowers ORDER BY total_spent DESC").all() as BorrowerRow[];
}

export function getRecentUsage(limit = 50) {
  const db = getDb();
  return db
    .prepare(
      `SELECT u.*, b.alias
       FROM usage_logs u
       LEFT JOIN borrowers b ON u.borrower = b.address
       ORDER BY u.created_at DESC
       LIMIT ?`
    )
    .all(limit);
}

// ── Session queries ──

export function createSession(borrower: string, token: string, expiresAt: number) {
  const db = getDb();
  db.prepare(
    "INSERT INTO sessions (token, borrower, expires_at) VALUES (?, ?, ?)"
  ).run(token, borrower.toLowerCase(), expiresAt);
}

export function getSession(token: string) {
  const db = getDb();
  const now = Math.floor(Date.now() / 1000);
  return db
    .prepare("SELECT * FROM sessions WHERE token = ? AND expires_at > ?")
    .get(token, now) as SessionRow | undefined;
}

export function cleanExpiredSessions() {
  const db = getDb();
  const now = Math.floor(Date.now() / 1000);
  db.prepare("DELETE FROM sessions WHERE expires_at <= ?").run(now);
}

export function invalidateBorrowerSessions(address: string): number {
  const db = getDb();
  const result = db.prepare("DELETE FROM sessions WHERE borrower = ?").run(address.toLowerCase());
  return result.changes;
}

// ── Types ──

export interface BorrowerRow {
  address: string;
  alias: string | null;
  balance_usd: number;
  total_spent: number;
  daily_spent: number;
  daily_reset: number;
  active: number;
  created_at: number;
  updated_at: number;
}

export interface CreditRow {
  id: number;
  borrower: string;
  valid_date: string;
  purchase_type: string;
  original_usd: number;
  remaining_usd: number;
  discount_rate: number;
  tx_hash: string | null;
  expired: number;
  created_at: number;
}

export interface SessionRow {
  token: string;
  borrower: string;
  expires_at: number;
  created_at: number;
}
