/** SQLite schema for Phase 0 usage tracking */

export const SCHEMA = `
  CREATE TABLE IF NOT EXISTS borrowers (
    address       TEXT PRIMARY KEY,          -- 0x... lowercase
    alias         TEXT,                      -- human-readable name
    balance_usd   REAL NOT NULL DEFAULT 0,   -- prepaid credit balance
    total_spent   REAL NOT NULL DEFAULT 0,   -- lifetime spend
    daily_spent   REAL NOT NULL DEFAULT 0,   -- rolling daily spend
    daily_reset   INTEGER NOT NULL DEFAULT 0,-- unix timestamp of last daily reset
    active        INTEGER NOT NULL DEFAULT 1,-- 0 = suspended
    created_at    INTEGER NOT NULL DEFAULT (unixepoch()),
    updated_at    INTEGER NOT NULL DEFAULT (unixepoch())
  );

  CREATE TABLE IF NOT EXISTS usage_logs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    borrower        TEXT NOT NULL REFERENCES borrowers(address),
    model           TEXT NOT NULL,
    prompt_tokens   INTEGER NOT NULL,
    completion_tokens INTEGER NOT NULL,
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

  CREATE INDEX IF NOT EXISTS idx_usage_borrower ON usage_logs(borrower);
  CREATE INDEX IF NOT EXISTS idx_usage_created ON usage_logs(created_at);
  CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at);
`;
