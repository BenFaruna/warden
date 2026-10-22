# AgentVault

**A policy-enforced vault that lets an AI agent spend money on its own, inside limits it cannot override.**

`AgentVault` is the on-chain half of [Warden](../README.md). The agent holds a *limited operator key*. The human owner holds the real authority. Every spending rule is enforced by the contract, so the guarantee holds even if the agent is prompt-injected, hallucinating, or fully compromised.

> **Status:** testnet / hackathon-grade. Thoroughly tested (see [Testing](#testing)) but **not audited**. Do not hold real value in it.

---

## Contents

1. [The idea in 60 seconds](#the-idea-in-60-seconds)
2. [Roles](#roles)
3. [The rules](#the-rules)
4. [Approval requests](#approval-requests)
5. [Function reference](#function-reference)
6. [Errors: what the agent should do about each](#errors-what-the-agent-should-do-about-each)
7. [Integrating from the app (viem)](#integrating-from-the-app-viem)
8. [Project layout](#project-layout)
9. [Setup, build, test](#setup-build-test)
10. [Testing](#testing)
11. [Deployment](#deployment)
12. [Design decisions](#design-decisions)
13. [Security model and known limitations](#security-model-and-known-limitations)

---

## The idea in 60 seconds

```
   Owner (human)                         Agent (AI, scoped key)
   ─────────────                         ──────────────────────
   sets policy, allowlists ─────┐   ┌──── transferToken / transferETH   (within policy)
   approves / rejects requests  │   ├──── requestTransfer               (needs a human)
   pauses (kill switch)         ▼   ▼
   withdraws               ┌──────────────┐
                           │  AgentVault  │──▶ only allowlisted recipients,
                           └──────────────┘    only allowlisted tokens, under caps
```

- The owner deposits funds and configures a **policy** per token (per-transaction cap, daily cap, approval threshold) plus a **recipient allowlist**.
- The agent can move funds **directly** only when a transfer passes every rule. Anything larger becomes an **approval request** that a human executes.
- The owner can freeze the agent instantly with a **kill switch**.
- A compromised agent can at worst do what the policy allows: send small amounts to pre-approved addresses.

The vault starts **inert**: no agent, no policy, no allowlist. Nothing works until the owner configures it.

---

## Roles

| Role | Who | Can | Cannot |
|---|---|---|---|
| **Owner** | Human. Use a multisig or passkey wallet in production. Ownership transfer is two-step. | Set policy, allowlist recipients, set/rotate the agent, pause/unpause, approve/reject requests, withdraw anything | Renounce ownership (disabled so funds can't be locked forever) |
| **Agent** | A single address (the AI's operator key). Needs a little native ETH for gas. | Transfer within policy, file approval requests, cancel its own pending requests | Change policy, allowlists, pause state, its own address; approve requests; withdraw. **Also cannot be the same address as the owner.** |
| **Anyone** | n/a | Deposit ETH (`receive()`), read state | Everything else |

---

## The rules

Policy is stored **per token**. Native ETH uses `address(0)` as its token key. Every policy must satisfy:

```
approvalThreshold  <=  perTxCap  <=  dailyCap  <=  type(uint192).max
```

A **direct agent transfer** must pass all of these, checked in this order (the order is chosen so the agent receives the most actionable error first):

| # | Rule | Error if violated |
|---|---|---|
| 0 | Caller is the agent; vault is not paused | `NotAgent`, `VaultPaused` |
| 1 | Recipient is not `address(0)` or the vault itself | `InvalidRecipient` |
| 2 | Token is allowlisted | `TokenNotAllowed(token)` |
| 3 | Recipient is allowlisted | `RecipientNotAllowed(to)` |
| 4 | `amount > 0` | `ZeroAmount` |
| 5 | `amount <= perTxCap` (hard ceiling) | `ExceedsPerTxCap(requested, cap)` |
| 6 | `amount <= approvalThreshold` (above it a human must approve) | `NeedsApproval(requested, threshold)` |
| 7 | `spentInWindow + amount <= dailyCap` | `ExceedsDailyCap(requested, remaining)` |

**Daily window.** A 24-hour *fixed* window per token. It opens at the first spend after the previous window expired and resets after 24h. See [limitations](#security-model-and-known-limitations) for the boundary-burst caveat.

**Example with the demo policy** (USDC, 6 decimals: `perTxCap = 2`, `approvalThreshold = 1`, `dailyCap = 5`):

| Agent tries | Result |
|---|---|
| 1 USDC to an allowlisted address | ✅ sent |
| 1 USDC to an unknown address | ❌ `RecipientNotAllowed` |
| 1.5 USDC to an allowlisted address | ❌ `NeedsApproval`, so file a request instead |
| 100 USDC ("send everything") | ❌ `ExceedsPerTxCap`, and a request would fail too |
| a 6th × 1 USDC in the same day | ❌ `ExceedsDailyCap(1000000, 0)` |

---

## Approval requests

For amounts in `(approvalThreshold, perTxCap]` the agent calls `requestTransfer(token, to, amount, reason)`:

1. **Validated up front.** The token and recipient must be allowlisted and `amount <= perTxCap`, so the owner is never asked to review something that could never run. The hard ceiling can't be approved around.
2. **Pending** until the owner calls `approveRequest(id)` (executes the transfer) or `rejectRequest(id)`. The agent may `cancelRequest(id)` its own.
3. **Safety rails:**
   - Requests **expire after 3 days** (`REQUEST_TTL`). Stale requests can't be approved by accident; the owner can still reject them.
   - At most **25 pending** at once (`MAX_PENDING_REQUESTS`), so a looping agent can't spam the owner.
   - `reason` is limited to **280 bytes**.
   - On approval the token and recipient are **re-checked**. If the owner delisted either since the request was filed, approval reverts.
   - Approved transfers **don't consume the agent's daily budget**: a human explicitly decided.
4. Approvals and rejections **work while paused**, so the owner can still clean up during an incident.

---

## Function reference

### Agent functions (`onlyAgent`, `whenNotPaused`)

| Function | Purpose |
|---|---|
| `transferToken(token, to, amount)` | Send an ERC-20 if every rule passes |
| `transferETH(to, amount)` | Send native ETH if every rule passes (uses the `address(0)` policy) |
| `requestTransfer(token, to, amount, reason) → id` | Ask the owner to approve a larger payment |
| `cancelRequest(id)` | Withdraw one's own pending request |

### Owner functions (`onlyOwner`)

| Function | Purpose |
|---|---|
| `setAgent(address)` | Set or rotate the agent; `address(0)` disables it. Cannot equal the owner |
| `setPaused(bool)` | Kill switch on/off |
| `setTokenPolicy(token, allowed, perTxCap, dailyCap, approvalThreshold)` | Create/update a token's policy (use `address(0)` for ETH) |
| `setRecipient(address, bool)` | Add/remove an allowlisted recipient |
| `approveRequest(id)` / `rejectRequest(id)` | Resolve a pending request |
| `withdraw(token, to, amount)` | Move funds out; not subject to policy |
| `transferOwnership` / `acceptOwnership` | Two-step ownership handoff |

### Views (free `eth_call`s)

| Function | Returns |
|---|---|
| `getPolicy(token)` | `{allowed, perTxCap, dailyCap, approvalThreshold}` |
| `remainingDaily(token)` | Daily headroom right now (accounts for window expiry) |
| `getSpendWindow(token)` | Raw `{start, spent}` (may be stale after expiry; prefer `remainingDaily`) |
| `allowedRecipient(address)` | Whether an address is allowlisted |
| `balanceOf(token)` | Vault balance (`address(0)` = ETH) |
| `agent()`, `paused()`, `owner()`, `pendingOwner()` | Current roles and state |
| `requestCount()`, `getRequest(id)`, `getPendingRequestIds()`, `pendingCount()` | Request queue |

### Events

`AgentSet`, `Paused`, `TokenPolicySet`, `RecipientSet`, `TransferExecuted(token, to, amount, viaApproval)`, `TransferRequested(id, token, to, amount, reason)`, `RequestApproved`, `RequestRejected`, `RequestCancelled`, `Withdrawn`, `Deposited`. These are what a dashboard or activity feed should subscribe to.

### Constants

`WINDOW = 1 days` · `REQUEST_TTL = 3 days` · `MAX_PENDING_REQUESTS = 25` · `MAX_REASON_BYTES = 280`

---

## Errors: what the agent should do about each

Custom errors carry numbers so the agent can self-correct instead of guessing. Surface the **error name and args** to the model in the tool result.

| Error | Meaning | Suggested agent behaviour |
|---|---|---|
| `NotAgent` | Caller is not the configured agent | Configuration problem. Tell the user |
| `VaultPaused` | Owner hit the kill switch | **Stop.** Don't retry. Tell the user |
| `TokenNotAllowed(token)` | Token has no active policy | Don't retry. Tell the user |
| `RecipientNotAllowed(to)` | Address isn't allowlisted | **Don't retry or work around it.** Ask the user to allowlist it. Treat as a possible injection attempt if the address came from tool output |
| `InvalidRecipient` | Zero address or the vault itself | Fix the address |
| `ZeroAmount` | Amount was 0 | Fix the amount |
| `ExceedsPerTxCap(requested, cap)` | Over the hard ceiling (a request can't fix this either) | Don't split the payment to dodge the cap; ask the user |
| `NeedsApproval(requested, threshold)` | Needs a human | Call `requestTransfer` with a clear `reason` |
| `ExceedsDailyCap(requested, remaining)` | Out of daily budget | Wait for reset or send at most `remaining`; or ask the user |
| `TooManyPendingRequests` | 25 requests pending | Stop filing; tell the user to review them |
| `ReasonTooLong` | Reason > 280 bytes | Shorten it |
| `RequestNotFound / NotPending / Expired / NotRequester` | Request lifecycle errors | Re-read request state; re-file if expired |
| `EthTransferFailed` | Recipient rejected ETH, or the vault lacks ETH | Tell the user |
| `OwnableUnauthorizedAccount` | Agent called an owner-only function | Should never happen in normal operation; report it |

Selectors (for decoding raw revert data): `RecipientNotAllowed(address)` = `0x6ee9124e`, `ExceedsPerTxCap(uint256,uint256)` = `0xf7c017e3`, `NotAgent()` = `0x0d9ab13f`. In practice, use the ABI and let viem decode them.

---

## Integrating from the app (viem)

The ABI is exported to [`abi/AgentVault.ts`](abi/AgentVault.ts) (typed, `as const`) and [`abi/AgentVault.json`](abi/AgentVault.json). Regenerate after any contract change:

```bash
forge inspect AgentVault abi --json > abi/AgentVault.json
```

A tool-friendly wrapper that turns reverts into structured results the LLM can act on:

```ts
import { createPublicClient, createWalletClient, http, parseUnits, BaseError, ContractFunctionRevertedError } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";
import { agentVaultAbi } from "./abi/AgentVault";

const account = privateKeyToAccount(process.env.AGENT_PRIVATE_KEY as `0x${string}`);
const publicClient = createPublicClient({ chain: baseSepolia, transport: http(process.env.BASE_SEPOLIA_RPC_URL) });
const walletClient = createWalletClient({ account, chain: baseSepolia, transport: http(process.env.BASE_SEPOLIA_RPC_URL) });
const VAULT = process.env.VAULT_ADDRESS as `0x${string}`;

export async function sendToken(token: `0x${string}`, to: `0x${string}`, amountHuman: string) {
  const amount = parseUnits(amountHuman, 6); // USDC has 6 decimals
  try {
    // simulateContract catches the revert BEFORE spending gas and gives a decoded error.
    const { request } = await publicClient.simulateContract({
      account, address: VAULT, abi: agentVaultAbi,
      functionName: "transferToken", args: [token, to, amount],
    });
    const hash = await walletClient.writeContract(request);
    return { ok: true as const, hash };
  } catch (e) {
    if (e instanceof BaseError) {
      const revert = e.walk((x) => x instanceof ContractFunctionRevertedError);
      if (revert instanceof ContractFunctionRevertedError) {
        // e.g. { errorName: "RecipientNotAllowed", args: ["0xAttacker..."] }
        return { ok: false as const, error: revert.data?.errorName, args: revert.data?.args?.map(String) };
      }
    }
    throw e; // network error etc.
  }
}
```

Useful reads for a `get_vault_policy` tool: `getPolicy(token)`, `remainingDaily(token)`, `paused()`, `getPendingRequestIds()`.

**Tips**
- Simulate first (above) for normal operation. For a *red-team demo* where you want a real on-chain revert and tx hash, skip simulation and send with a manual `gas` limit.
- The agent's EOA needs a little ETH for gas. The vault does not pay gas.
- Convert human amounts using the token's decimals; the contract only knows base units. Keep that conversion out of the LLM's hands.
- **x402 note:** x402 payments are signed by the *payer*. In Week 2 they still come from the agent's own wallet, not the vault. Fund that float from the vault via `transferToken` to the agent's own address (allowlist it). Routing x402 through the vault is a later-week item.

---

## Project layout

```
contracts/
├─ src/AgentVault.sol                 the contract (fully NatSpec-documented)
├─ test/
│  ├─ AgentVault.t.sol                74 unit + fuzz tests
│  ├─ Deploy.t.sol                    tests the deploy script
│  ├─ invariant/
│  │  ├─ AgentVaultHandler.sol        randomized actor + independent rules oracle
│  │  └─ AgentVault.invariants.t.sol  18 invariants
│  └─ mocks/                          MockUSDC (6 dec), NoReturnToken, HookToken, ReentrantAgent
├─ script/Deploy.s.sol                configurable deployment script
├─ abi/AgentVault.{json,ts}           ABI for the app
├─ deployments/                       <chainId>.json written by the deploy script
└─ foundry.toml
```

---

## Setup, build, test

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation) (`foundryup`).

```bash
cd contracts
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v5.1.0
forge build
forge test                 # everything (~45s, dominated by invariant runs)
forge test -vv --match-contract Invariant       # invariants with an activity summary
forge test --no-match-path "test/invariant/*"   # fast: unit + fuzz only
forge coverage --no-match-path "test/invariant/*" --report summary
FOUNDRY_PROFILE=ci forge test                   # heavy run: 5,000 fuzz runs, 1,000 invariant runs
```

Pinned: Solidity `0.8.24`, EVM `cancun` (supported by Base Sepolia), OpenZeppelin Contracts `v5.1.0`. Tested with Foundry 1.5.1. On older Foundry versions, `forge install` auto-commits unless you pass `--no-commit`.

The project must be inside a git repository for `forge install` (a normal clone of your repo already is).

---

## Testing

**94 tests, all passing.** `AgentVault.sol` has **100% line, statement, branch and function coverage** from the unit tests alone.

### Unit tests (74): `test/AgentVault.t.sol`

| Area | What is checked |
|---|---|
| Deployment | Inert by default; constants; ETH deposits |
| Owner config | Agent rotation/disable, can't equal owner; policy ordering and boundary values; allowlist validation; two-step ownership; renounce disabled |
| Happy paths | ERC-20 and ETH transfers; exact-threshold boundary; USDT-style tokens that return nothing; filling the daily cap exactly; 24h reset (1 second before/at expiry); per-token budgets |
| Every rule, precisely | Each revert asserts the exact error **and its arguments**: allowlist, token, zero amount, per-tx cap, "send everything" drain, approval threshold, salami-slicing past the daily cap |
| Edge semantics | Policy changes apply immediately; lowering the cap below current spend clamps to 0 with no underflow; a failed transfer doesn't burn budget; ETH-rejecting recipients; underfunded vault |
| Attacks | Non-agents (stranger, attacker, **owner**) can't use agent functions; a compromised agent calling **every owner function** (all revert, nothing changes) |
| Kill switch | Every agent function freezes; owner functions keep working while paused; unpausing restores |
| Approval flow | Fields/events; validation; reason limit; spam limit; approve/reject/cancel; no double-pay; expiry boundary (exactly at TTL is OK, +1s is not); delisted recipient/disabled token; atomic rollback when underfunded; pending-id listing |
| Reentrancy | Malicious ETH recipient and malicious ERC-777-style token callback both fail; nothing leaves the vault; budget unchanged |
| Documented limitation | A test that **pins** the fixed-window boundary burst, so any future change is deliberate |
| Fuzz (6) | Single transfer vs the complete rule table; window total never exceeds the cap under any slicing; policy ordering validation is exact; no non-agent can transfer; no non-allowlisted recipient is ever paid; reason-length boundary |

### Invariants (18): `test/invariant/`

A **handler** randomly sequences ~100 actions per run across 256 runs (25,600 calls per invariant): agent transfers and requests, owner approvals/rejections/pauses/allowlist flips/withdrawals, deposits, time travel, a **compromised agent** trying all nine owner-only functions, and **strangers** attacking. It records ghost state, and an **independent re-implementation of the rules** acts as an exact oracle (it must allow exactly what the rules allow, *and* block everything else, including correct window resets).

After every call, these hold:

| Group | Invariant |
|---|---|
| Allowlist | No transfer ever succeeds to a non-allowlisted recipient. Addresses never allowlisted hold exactly 0 funds |
| Caps | Every direct transfer satisfies `0 < amount <= threshold <= perTxCap`. Independent window model never sees spend above `dailyCap`. On-chain counter within cap. `remainingDaily` sane. Approved requests never exceed `perTxCap`. Expired requests never execute |
| Exact oracle | A rule-compliant transfer is never wrongly refused (liveness) |
| Kill switch | Nothing succeeds while paused |
| Privilege | A compromised agent or stranger never succeeds at an owner function; non-agents never move funds; owner/agent/policy are unchanged |
| Conservation | `vault balance == deposits − direct − approved − withdrawn`, for USDC and ETH |
| Bookkeeping | `pendingCount` equals the actual number of pending requests (≤ 25); lifecycle counts add up; stored requests are well-formed; vault/zero are never allowlisted |

`forge test -vv --match-contract Invariant` prints a summary of what the fuzzer actually did (transfers allowed/blocked, requests approved, attacks attempted), so a green run can be trusted as non-vacuous.

### Mutation testing

To check that the tests can actually fail, 12 deliberate bugs were injected into the contract one at a time:

| Mutant | Unit tests | Invariants |
|---|---|---|
| Remove recipient allowlist check | caught | caught |
| `perTxCap` off-by-one (`>=`) | caught | not caught (equivalent for direct transfers: the threshold already blocks that range) |
| Daily spend never recorded | caught | caught |
| Kill switch missing on `transferToken` | caught | caught |
| `setPaused` open to anyone | caught | caught |
| `setRecipient` open to anyone | caught | caught |
| Reentrancy guard removed from `transferETH` | caught | not caught (handler uses EOAs; the unit test uses a malicious contract) |
| Request expiry not enforced | caught | caught |
| Approval threshold not enforced | caught | caught |
| Request not marked approved (double pay) | caught | caught |
| Reject forgets `pendingCount--` | caught | caught |
| Window never resets after expiry | caught | caught |

**12/12 caught by unit tests; 10/12 caught independently by invariants.** The first mutation run exposed a weakness: the daily-cap bug slipped past the invariants because the fuzzer rarely produced enough in-window transfers. The handler was then strengthened (amount bias, shorter time hops, exact oracle) and that bug is now caught.

### Real-chain smoke test

The deployment script and the full flow were also run against a local Anvil chain with real transactions: legitimate transfer succeeded; transfer to an attacker reverted `RecipientNotAllowed`; a 100 USDC drain reverted `ExceedsPerTxCap`; 1.5 USDC reverted `NeedsApproval`; the agent trying `setRecipient` reverted `OwnableUnauthorizedAccount`; request → owner approval delivered funds; after `setPaused(true)` the agent reverted `VaultPaused`. The attacker address ended with 0.

---

## Deployment

The script deploys, applies the policy, allowlists recipients, and can start a two-step ownership handoff.

```bash
export AGENT_ADDRESS=0x...        # the agent's address (NOT the owner)
export USDC_ADDRESS=0x...         # must be the token your x402 flow pays in; verify on the explorer
export RECIPIENTS=0xFriend...,0xAgentOwnWalletForFloat...
# optional: OWNER_ADDRESS, USDC_PER_TX, USDC_THRESHOLD, USDC_DAILY, ETH_PER_TX, ETH_THRESHOLD, ETH_DAILY

forge script script/Deploy.s.sol \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --private-key $OWNER_PRIVATE_KEY \
  --broadcast
```

Default policy (USDC has 6 decimals): per-tx **2**, approval threshold **1**, daily **5** USDC; ETH **0.001 / 0.0005 / 0.002**.

After deploying:
1. Fund the vault (USDC transfer and a little ETH) and give the agent's EOA a small ETH balance for gas.
2. Record the address from `deployments/84532.json`; set `VAULT_ADDRESS` in the app.
3. If you set `OWNER_ADDRESS`, that account must call `acceptOwnership()`.
4. Optionally verify on BaseScan: add `--verify --etherscan-api-key $BASESCAN_API_KEY`.

---

## Design decisions

| Decision | Why |
|---|---|
| **Purpose-built vault, not ERC-4337** | The core claim (on-chain limits that survive a compromised agent) doesn't need account abstraction, and AA tooling is the largest schedule risk. The agent is a plain EOA operator that pays its own gas. Session-key accounts remain a future upgrade path |
| **Owner is the only fund-moving root of trust** | Keeps the trust model small and auditable: one human authority, one limited operator |
| **`perTxCap` is checked before the approval threshold** | Gives the agent a precise signal: "over the cap" is a hard no; "needs approval" means *ask a human* |
| **Fixed 24h window** | Cheap (one storage slot) and easy to reason about. The cost is a documented 2× boundary burst |
| **Approved requests bypass the daily cap** | A human explicitly authorised them. They're still bounded by `perTxCap` and the allowlists |
| **Requests expire (3 days) and are re-validated on approval** | Prevents approving a stale request after circumstances changed |
| **Recipient allowlist is global (all tokens)** | Simple mental model. Per-token recipients would be a straightforward extension |
| **`renounceOwnership` disabled; `Ownable2Step`** | Removes two classes of irreversible mistakes |
| **Custom errors with arguments** | Lets the agent self-correct from the revert data (e.g. remaining budget) |
| **Agent can't be the owner** | Keeps the two roles separate |

---

## Security model and known limitations

**What the contract guarantees** (verified by tests and invariants): a compromised agent can only send ≤ `approvalThreshold` per transfer, ≤ `dailyCap` per window per token, only to allowlisted addresses, only in allowlisted tokens, and never while paused. It can't change any of that, can't withdraw, and can't approve its own requests.

**Known limitations. Read before relying on this:**

- **Fixed-window daily cap.** Spending at the end of one window and the start of the next can move up to ~2× `dailyCap` in a short span (pinned by a test). Choose `dailyCap` with that worst case in mind.
- **Allowlisted recipients are trusted.** If the owner allowlists an address that is malicious or compromised, the agent can send it money within limits. Keep the allowlist short and reviewed.
- **No price oracle.** Caps are per-token in base units and are not aggregated across tokens.
- **Plain ERC-20s only.** Fee-on-transfer, rebasing, and hook tokens are unsupported. (Reentrancy is blocked regardless.) Use `NoReturnToken`-style tokens (like USDT) with care; they work via `SafeERC20`.
- **Agent pays its own gas**, so the agent address needs a small ETH balance, and that balance is *outside* the vault's protection.
- **x402 payments are not yet routed through the vault.** They are signed by the payer, which is currently the agent's own wallet. Bound that exposure with a small float and an off-chain budget check. Whether the vault itself can be the x402 payer (ERC-1271 / EIP-3009 contract-signer support) is future research.
- **Owner key = root of trust.** A single EOA owner is fine for a testnet demo; use a multisig or passkey account in production.
- **Not audited.** Treat as hackathon-grade software.

**Reporting issues:** open an issue on the repository.
