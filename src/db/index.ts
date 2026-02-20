import { Database } from "bun:sqlite";
import path from "path";
import fs from "fs";
import { SCHEMA } from "./schema";

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

export function addCredit(address: string, amountUsd: number, txHash?: string, note?: string): { borrower: BorrowerRow; alreadyProcessed: boolean } {
  const db = getDb();
  const addr = address.toLowerCase();

  // Idempotency: if txHash already exists, skip (watcher replay safety)
  if (txHash) {
    const existing = db
      .prepare("SELECT id FROM deposits WHERE tx_hash = ?")
      .get(txHash);
    if (existing) {
      return { borrower: getBorrower(addr)!, alreadyProcessed: true };
    }
  }

  const txn = db.transaction(() => {
    db.prepare(
      `UPDATE borrowers SET balance_usd = balance_usd + ?, updated_at = unixepoch()
       WHERE address = ?`
    ).run(amountUsd, addr);

    db.prepare(
      `INSERT INTO deposits (borrower, amount_usd, tx_hash, note)
       VALUES (?, ?, ?, ?)`
    ).run(addr, amountUsd, txHash ?? null, note ?? null);
  });

  txn();
  return { borrower: getBorrower(addr)!, alreadyProcessed: false };
}

// ── Usage queries ──

export function recordUsage(params: {
  borrower: string;
  model: string;
  promptTokens: number;
  completionTokens: number;
  costUsd: number;
  chargedUsd: number;
  protocolFee: number;
  requestId?: string;
}) {
  const db = getDb();
  const addr = params.borrower.toLowerCase();
  const now = Math.floor(Date.now() / 1000);

  const txn = db.transaction(() => {
    // Reset daily counter if new day
    const borrower = getBorrower(addr);
    if (borrower) {
      const lastReset = borrower.daily_reset;
      const dayStart = now - (now % 86400);
      if (lastReset < dayStart) {
        db.prepare(
          "UPDATE borrowers SET daily_spent = 0, daily_reset = ? WHERE address = ?"
        ).run(dayStart, addr);
      }
    }

    // Deduct from balance and add to spent
    db.prepare(
      `UPDATE borrowers SET
         balance_usd = balance_usd - ?,
         total_spent = total_spent + ?,
         daily_spent = daily_spent + ?,
         updated_at = unixepoch()
       WHERE address = ?`
    ).run(params.chargedUsd, params.chargedUsd, params.chargedUsd, addr);

    // Log usage
    db.prepare(
      `INSERT INTO usage_logs
         (borrower, model, prompt_tokens, completion_tokens, cost_usd, charged_usd, protocol_fee, request_id)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`
    ).run(
      addr,
      params.model,
      params.promptTokens,
      params.completionTokens,
      params.costUsd,
      params.chargedUsd,
      params.protocolFee,
      params.requestId ?? null
    );
  });

  txn();
}

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

export interface SessionRow {
  token: string;
  borrower: string;
  expires_at: number;
  created_at: number;
}
