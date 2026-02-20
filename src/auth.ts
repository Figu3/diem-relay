import { verifyMessage } from "viem";
import { createSession, getSession, getBorrower } from "./db";
import { config } from "./config";

/**
 * Phase 0 auth: Simple message signing.
 *
 * Flow:
 * 1. Borrower signs a message: "DIEM Relay Auth\nTimestamp: {unix}\nAddress: {0x...}"
 * 2. Relay verifies signature, checks borrower exists and has balance
 * 3. Returns a session token (random hex) valid for 1 hour
 *
 * Phase 1+ will upgrade to EIP-712 typed data.
 */

const AUTH_MESSAGE_PREFIX = "DIEM Relay Auth";
const MAX_TIMESTAMP_DRIFT_SECONDS = 300; // 5 minutes

export interface AuthRequest {
  address: string;
  timestamp: number;
  signature: `0x${string}`;
}

export interface AuthResult {
  success: boolean;
  sessionToken?: string;
  expiresAt?: number;
  error?: string;
}

export async function authenticate(req: AuthRequest): Promise<AuthResult> {
  const { address, timestamp, signature } = req;

  // Validate timestamp freshness
  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - timestamp) > MAX_TIMESTAMP_DRIFT_SECONDS) {
    return { success: false, error: "Timestamp too old or in the future" };
  }

  // Reconstruct the expected message
  const message = `${AUTH_MESSAGE_PREFIX}\nTimestamp: ${timestamp}\nAddress: ${address.toLowerCase()}`;

  // Verify signature
  let valid: boolean;
  try {
    valid = await verifyMessage({
      address: address as `0x${string}`,
      message,
      signature,
    });
  } catch {
    return { success: false, error: "Invalid signature" };
  }

  if (!valid) {
    return { success: false, error: "Signature verification failed" };
  }

  // Check borrower exists and is active
  const borrower = getBorrower(address);
  if (!borrower) {
    return { success: false, error: "Address not registered as borrower" };
  }
  if (!borrower.active) {
    return { success: false, error: "Account suspended" };
  }

  // Create session
  const token = generateSessionToken();
  const expiresAt = now + config.sessionTtlSeconds;
  createSession(address, token, expiresAt);

  return { success: true, sessionToken: token, expiresAt };
}

export function validateSession(token: string): { valid: boolean; borrower?: string; error?: string } {
  const session = getSession(token);
  if (!session) {
    return { valid: false, error: "Invalid or expired session" };
  }

  const borrower = getBorrower(session.borrower);
  if (!borrower || !borrower.active) {
    return { valid: false, error: "Account not found or suspended" };
  }

  return { valid: true, borrower: session.borrower };
}

function generateSessionToken(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/**
 * Helper: build the message string a borrower needs to sign.
 * Exposed so the frontend/CLI can construct it.
 */
export function buildAuthMessage(address: string, timestamp: number): string {
  return `${AUTH_MESSAGE_PREFIX}\nTimestamp: ${timestamp}\nAddress: ${address.toLowerCase()}`;
}
