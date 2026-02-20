#!/usr/bin/env bun
/**
 * Admin CLI for Phase 0 DIEM Relay management.
 *
 * Usage:
 *   bun run admin add-borrower <address> [alias]
 *   bun run admin credit <address> <amount_usd> [tx_hash] [note]
 *   bun run admin list
 *   bun run admin info <address>
 *   bun run admin stats
 *   bun run admin usage [days]
 */

import {
  upsertBorrower,
  addCredit,
  getAllBorrowers,
  getBorrower,
  getUsageSummary,
  getRecentUsage,
} from "./db";

const [command, ...args] = process.argv.slice(2);

function formatUsd(n: number): string {
  return `$${n.toFixed(4)}`;
}

function formatDate(unix: number): string {
  return new Date(unix * 1000).toISOString().slice(0, 19).replace("T", " ");
}

switch (command) {
  case "add-borrower": {
    const [address, alias] = args;
    if (!address) {
      console.error("Usage: admin add-borrower <address> [alias]");
      process.exit(1);
    }
    const b = upsertBorrower(address, alias);
    console.log(`Borrower registered:`);
    console.log(`  Address: ${b.address}`);
    console.log(`  Alias:   ${b.alias ?? "(none)"}`);
    console.log(`  Balance: ${formatUsd(b.balance_usd)}`);
    break;
  }

  case "credit": {
    const [address, amountStr, txHash, ...noteParts] = args;
    const amount = Number(amountStr);
    if (!address || isNaN(amount) || amount <= 0) {
      console.error("Usage: admin credit <address> <amount_usd> [tx_hash] [note]");
      process.exit(1);
    }
    const note = noteParts.join(" ") || undefined;
    const b = addCredit(address, amount, txHash, note);
    console.log(`Credit added:`);
    console.log(`  Address:     ${b.address}`);
    console.log(`  Added:       ${formatUsd(amount)}`);
    console.log(`  New balance: ${formatUsd(b.balance_usd)}`);
    break;
  }

  case "list": {
    const borrowers = getAllBorrowers();
    if (borrowers.length === 0) {
      console.log("No borrowers registered.");
      break;
    }

    console.log(
      `\n${"Address".padEnd(44)} ${"Alias".padEnd(15)} ${"Balance".padStart(10)} ${"Spent".padStart(10)} ${"Active".padStart(6)}`
    );
    console.log("-".repeat(90));
    for (const b of borrowers) {
      console.log(
        `${b.address.padEnd(44)} ${(b.alias ?? "").padEnd(15)} ${formatUsd(b.balance_usd).padStart(10)} ${formatUsd(b.total_spent).padStart(10)} ${(b.active ? "yes" : "no").padStart(6)}`
      );
    }
    console.log(`\nTotal: ${borrowers.length} borrowers`);
    break;
  }

  case "info": {
    const [address] = args;
    if (!address) {
      console.error("Usage: admin info <address>");
      process.exit(1);
    }
    const b = getBorrower(address);
    if (!b) {
      console.error(`Borrower ${address} not found`);
      process.exit(1);
    }
    const usage = getUsageSummary(address) as any;

    console.log(`\nBorrower: ${b.address}`);
    console.log(`  Alias:       ${b.alias ?? "(none)"}`);
    console.log(`  Balance:     ${formatUsd(b.balance_usd)}`);
    console.log(`  Total spent: ${formatUsd(b.total_spent)}`);
    console.log(`  Daily spent: ${formatUsd(b.daily_spent)}`);
    console.log(`  Active:      ${b.active ? "yes" : "no"}`);
    console.log(`  Created:     ${formatDate(b.created_at)}`);
    console.log(`\n  Last 30 days:`);
    console.log(`    Requests:        ${usage?.requests ?? 0}`);
    console.log(`    Prompt tokens:   ${usage?.total_prompt_tokens ?? 0}`);
    console.log(`    Output tokens:   ${usage?.total_completion_tokens ?? 0}`);
    console.log(`    Cost (Venice):   ${formatUsd(usage?.total_cost_usd ?? 0)}`);
    console.log(`    Charged:         ${formatUsd(usage?.total_charged_usd ?? 0)}`);
    console.log(`    Protocol fees:   ${formatUsd(usage?.total_protocol_fee ?? 0)}`);
    break;
  }

  case "stats": {
    const borrowers = getAllBorrowers();
    const active = borrowers.filter((b) => b.total_spent > 0).length;
    const totalBalance = borrowers.reduce((s, b) => s + b.balance_usd, 0);
    const totalSpent = borrowers.reduce((s, b) => s + b.total_spent, 0);
    const summary = getUsageSummary(undefined, 30) as any;

    console.log(`\n=== DIEM Relay Stats ===`);
    console.log(`  Borrowers:      ${borrowers.length} total, ${active} active`);
    console.log(`  Total balance:  ${formatUsd(totalBalance)}`);
    console.log(`  Total spent:    ${formatUsd(totalSpent)}`);
    console.log(`\n  Last 30 days:`);
    console.log(`    Requests:       ${summary?.requests ?? 0}`);
    console.log(`    Revenue:        ${formatUsd(summary?.total_charged_usd ?? 0)}`);
    console.log(`    Protocol fees:  ${formatUsd(summary?.total_protocol_fee ?? 0)}`);
    console.log(`    Venice cost:    ${formatUsd(summary?.total_cost_usd ?? 0)}`);
    break;
  }

  case "usage": {
    const days = Number(args[0] ?? 30);
    const recent = getRecentUsage(20) as any[];

    console.log(`\nRecent usage (last ${days} days):\n`);
    if (recent.length === 0) {
      console.log("  No usage recorded.");
      break;
    }

    console.log(
      `${"Time".padEnd(20)} ${"Borrower".padEnd(12)} ${"Model".padEnd(30)} ${"Tokens".padStart(10)} ${"Charged".padStart(10)}`
    );
    console.log("-".repeat(85));
    for (const u of recent) {
      const alias = u.alias ?? u.borrower.slice(0, 10);
      const tokens = u.prompt_tokens + u.completion_tokens;
      console.log(
        `${formatDate(u.created_at).padEnd(20)} ${alias.padEnd(12)} ${u.model.padEnd(30)} ${String(tokens).padStart(10)} ${formatUsd(u.charged_usd).padStart(10)}`
      );
    }
    break;
  }

  default:
    console.log(`
DIEM Relay Admin CLI

Commands:
  add-borrower <address> [alias]                Register a new borrower
  credit <address> <amount_usd> [tx_hash] [note]  Add credits to a borrower
  list                                           List all borrowers
  info <address>                                 Detailed borrower info
  stats                                          Protocol-wide statistics
  usage [days]                                   Recent usage logs
`);
}
