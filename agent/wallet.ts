/**
 * THE AGENT'S WALLET
 *
 * The agent owns a wallet (a private key). It uses it to sign payments,
 * so it can pay for APIs on its own. This is the "x402" idea:
 *
 *   1. Agent calls an API         ->  API answers "402 Payment Required" + a price
 *   2. Agent signs a payment      ->  with its wallet
 *   3. Agent retries with payment ->  API checks the signature and answers 200 OK
 *
 * You create the wallet with the "Create wallet" button on the page.
 * It is saved in `.agent-wallet.json` so it survives restarts.
 *
 * Payments here are signed but NOT sent on-chain (it's a demo, no real money).
 */
import fs from "fs";
import path from "path";
import { createPublicClient, formatEther, http, verifyMessage, type Address, type Hex } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";

const WALLET_FILE = path.join(process.cwd(), ".agent-wallet.json");
const X402_BUDGET_FILE = path.join(process.cwd(), ".x402-budget.json");
const X402_MAX_PER_CALL = Number(process.env.X402_MAX_PER_CALL ?? "0.05");
const X402_DAILY_BUDGET = Number(process.env.X402_DAILY_BUDGET ?? "0.50");
const chain = createPublicClient({ chain: baseSepolia, transport: http() });

export type Payment = { from: Address; to: Address; amount: string; asset: string; resource: string; nonce: string };

/** The wallet from .env or .agent-wallet.json, or null if none was created yet. */
function loadAccount() {
  const key = process.env.WALLET_PRIVATE_KEY || (fs.existsSync(WALLET_FILE) && JSON.parse(fs.readFileSync(WALLET_FILE, "utf8")).privateKey);
  return key ? privateKeyToAccount(key as Hex) : null;
}

function requireAccount() {
  const account = loadAccount();
  if (!account) throw new Error("The agent has no wallet yet. Ask the user to click 'Create wallet' first.");
  return account;
}

/** Make a brand new wallet and save it. */
export function createWallet() {
  if (loadAccount()) return getWalletAddress();
  const privateKey = generatePrivateKey();
  fs.writeFileSync(WALLET_FILE, JSON.stringify({ privateKey }, null, 2));
  return privateKeyToAccount(privateKey).address;
}

export function getWalletAddress() {
  return loadAccount()?.address ?? null;
}

export async function getWalletBalance() {
  const wei = await chain.getBalance({ address: requireAccount().address });
  return `${formatEther(wei)} ETH`;
}

export function getX402BudgetStatus() {
  const today = new Date().toISOString().slice(0, 10);
  const state = (() => {
    try {
      if (!fs.existsSync(X402_BUDGET_FILE)) return { date: today, spent: 0 };
      const raw = JSON.parse(fs.readFileSync(X402_BUDGET_FILE, "utf8"));
      return { date: raw.date ?? today, spent: Number(raw.spent ?? 0) };
    } catch {
      return { date: today, spent: 0 };
    }
  })();

  const spent = state.date === today ? Number(state.spent ?? 0) : 0;
  return {
    maxPerCall: X402_MAX_PER_CALL,
    dailyBudget: X402_DAILY_BUDGET,
    spentToday: spent,
    remainingDaily: Math.max(X402_DAILY_BUDGET - spent, 0),
    lastReset: state.date,
  };
}

function ensureX402Budget(amount: string | number, payTo?: string) {
  const value = Number(amount);
  if (!Number.isFinite(value) || value <= 0) {
    throw new Error(`Invalid x402 price: ${amount}`);
  }

  const allowedPayees = (process.env.X402_ALLOWED_PAYEES ?? "")
    .split(",")
    .map((entry) => entry.trim().toLowerCase())
    .filter(Boolean);

  if (allowedPayees.length > 0 && payTo && !allowedPayees.includes(payTo.toLowerCase())) {
    throw new Error(`x402 payments to ${payTo} are not allowed by X402_ALLOWED_PAYEES.`);
  }

  const { maxPerCall, dailyBudget } = getX402BudgetStatus();
  if (value > maxPerCall) {
    throw new Error(`Payment of ${amount} USDC exceeds the per-call budget of ${maxPerCall} USDC.`);
  }

  const today = new Date().toISOString().slice(0, 10);
  const state = (() => {
    try {
      const raw = fs.existsSync(X402_BUDGET_FILE) ? JSON.parse(fs.readFileSync(X402_BUDGET_FILE, "utf8")) : { date: today, spent: 0 };
      return { date: raw.date ?? today, spent: Number(raw.spent ?? 0) };
    } catch {
      return { date: today, spent: 0 };
    }
  })();

  const nextSpent = state.date === today ? Number(state.spent ?? 0) + value : value;
  if (nextSpent > dailyBudget) {
    throw new Error(`Payment of ${amount} USDC would exceed the daily x402 budget of ${dailyBudget} USDC.`);
  }

  fs.writeFileSync(X402_BUDGET_FILE, JSON.stringify({ date: today, spent: nextSpent }, null, 2));
  return { ...getX402BudgetStatus(), due: value, nextSpent };
}

/** Fetch a URL. If it asks for payment (402), sign one with the wallet and try again. */
export async function payAndFetch(url: string) {
  const first = await fetch(url);
  if (first.status !== 402) return { data: await first.json() };

  const account = requireAccount();
  const { price, asset, payTo } = await first.json();
  ensureX402Budget(price, payTo);

  const payment: Payment = {
    from: account.address,
    to: payTo,
    amount: price,
    asset,
    resource: new URL(url).pathname,
    nonce: crypto.randomUUID(),
  };
  const signature = await account.signMessage({ message: JSON.stringify(payment) });
  const header = Buffer.from(JSON.stringify({ payment, signature })).toString("base64");

  const paid = await fetch(url, { headers: { "X-PAYMENT": header } });
  return {
    data: await paid.json(),
    payment: { status: paid.status, amount: `${price} ${asset}`, to: payTo, signature: `${signature.slice(0, 18)}...` },
  };
}

/** Used by the API: is this X-PAYMENT header a real, signed payment? */
export async function verifyPayment(header: string | null) {
  if (!header) return null;
  try {
    const { payment, signature } = JSON.parse(Buffer.from(header, "base64").toString()) as {
      payment: Payment;
      signature: Hex;
    };
    const valid = await verifyMessage({ address: payment.from, message: JSON.stringify(payment), signature });
    return valid ? payment : null;
  } catch {
    return null;
  }
}
