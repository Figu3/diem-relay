/** SQLite schema for DIEM Relay — v2 with dated credit tranches */

export const SCHEMA = `
  CREATE TABLE IF NOT EXISTS borrowers (
    address       TEXT PRIMARY KEY,          -- 0x... lowercase
    alias         TEXT,                      -- human-readable name
    balance_usd   REAL NOT NULL DEFAULT 0,   -- denormalized: sum of today's available credits
    total_spent   REAL NOT NULL DEFAULT 0,   -- lifetime spend
    daily_spent   REAL NOT NULL DEFAULT 0,   -- rolling daily spend
    daily_reset   INTEGER NOT NULL DEFAULT 0,-- unix timestamp of last daily reset
    active        INTEGER NOT NULL DEFAULT 1,-- 0 = suspended
    created_at    INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at    INTEGER NOT NULL DEFAULT (unixepoch())
  );

  -- Dated credit tranches: each credit is valid for a specific day only
  CREATE TABLE IF NOT EXISTS credits (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    borrower        TEXT NOT NULL REFERENCES borrowers(address),
    valid_date      TEXT NOT NULL,             -- YYYY-MM-DD UTC date this credit is valid for
    purchase_type   TEXT NOT NULL DEFAULT 'advance', -- 'advance' (next-day) or 'sameday' (dutch auction)
    original_usd    REAL NOT NULL,             -- amount at time of purchase
    remaining_usd   REAL NOT NULL,             -- amount still available to spend
    discount_rate   REAL NOT NULL,             -- rate paid (e.g. 0.85 = 15% off Venice list)
    tx_hash         TEXT,                      -- on-chain tx hash (idempotency for watcher deposits)
    expired         INTEGER NOT NULL DEFAULT 0,-- 1 = swept (past valid_date)
    created_at      INTEGER NOT NULL DEFAULT (unixepoch())
  );

  CREATE TABLE IF NOT EXISTS usage_logs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    borrower        TEXT NOT NULL REFERENCES borrowers(address),
    model           TEXT NOT NULL,
    prompt_tokens   INTEGER NOT NULL,
    completion_tokens INTEGER NOT NULL,
    cache_tokens    INTEGER NOT NULL DEFAULT 0, -- prompt cache read tokens
    cost_usd        REAL NOT NULL,            -- cost at Venice list price
    charged_usd     REAL NOT NULL,            -- what borrower was charged (discounted)
    protocol_fee    REAL NOT NULL,            -- protocol's cut
    request_id      TEXT,                     -- Venice request ID if available
    created_at      INTEGER NOT NULL DEFAULT (unixepoch())
  );

  CREATE TABLE IF NOT EXISTS deposits (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    borrower      TEXT NOT NULL REFERENCES borrowers(address),
    amount_usd    REAL NOT NULL,
    tx_hash       TEXT,                       -- USDC transfer tx hash (manual verification)
    note          TEXT,
    created_at    INTEGER NOT NULL DEFAULT (unixepoch())
  );

  CREATE TABLE IF NOT EXISTS sessions (
    token         TEXT PRIMARY KEY,
    borrower      TEXT NOT NULL REFERENCES borrowers(address),
    expires_at    INTEGER NOT NULL,
    created_at    INTEGER NOT NULL DEFAULT (unixepoch())
  );

  CREATE INDEX IF NOT EXISTS idx_credits_borrower_date ON credits(borrower, valid_date);
  CREATE INDEX IF NOT EXISTS idx_credits_valid_date ON credits(valid_date);
  CREATE UNIQUE INDEX IF NOT EXISTS idx_credits_tx_hash ON credits(tx_hash) WHERE tx_hash IS NOT NULL;
  CREATE INDEX IF NOT EXISTS idx_usage_borrower ON usage_logs(borrower);
  CREATE INDEX IF NOT EXISTS idx_usage_created ON usage_logs(created_at);
  CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at);
  CREATE UNIQUE INDEX IF NOT EXISTS idx_deposits_tx_hash ON deposits(tx_hash) WHERE tx_hash IS NOT NULL;
`;
