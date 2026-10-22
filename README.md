<div align="center">

<img src="./public/warden.png" alt="Warden logo" width="120" />

# Warden

**An AI agent that can spend from a policy-enforced testnet vault.**

[Twitter/X](#social-media) · [Demo](#demo) · [Roadmap](#roadmap) · [Live](https://warden.pxxlspace.cv/)

</div>

---

## What Warden does

Warden is a Next.js chat app backed by a Google Gemini agent. The agent can inspect its Base Sepolia wallet and an `AgentVault`, send USDC or ETH through the vault's on-chain policy, and file on-chain transfer requests for owner review. It can also read webpages and use a mock paid-weather endpoint. The homepage lets you choose from the Gemini models configured in the environment.

The contract and ABI are in `contracts/` and `lib/abi/AgentVault.ts`. Agent tools use the Base Sepolia deployment in `contracts/deployments/84532.json` by default; `VAULT_ADDRESS` can override it. The owner console is not implemented, so approval, pause, policy, and owner-management actions must be performed separately by the vault owner.

## Current capabilities

| Tool | What it does | Important detail |
| --- | --- | --- |
| `get_weather` | Requests demo weather data from the local `/api/weather` endpoint. | The endpoint requests a `0.01 USDC`-labelled signed message, but no USDC is transferred. |
| `get_my_wallet` | Reports the agent address, ETH and USDC balances, vault balances, and whether the agent address matches the configured vault agent. | Reads Base Sepolia balances and vault state. |
| `roll_dice` | Rolls a die with the requested number of sides, defaulting to 6. | Local utility; no wallet required. |
| `get_joke` | Requests a random joke from the Official Joke API. | Requires the external service to be reachable. |
| `get_vault_policy` | Reads live pause state, USDC/ETH policies and remaining daily caps, vault balances, configured recipient status, and pending requests. | Only recipients listed in `AGENT_ALLOWED_RECIPIENTS` are displayed; the contract itself remains authoritative. |
| `send_token` | Sends USDC or ETH from the vault to a recipient. | Simulates first and returns decoded policy errors by default. Set `DEMO_FORCE_SEND=true` to submit a testnet transaction even if simulation identifies a policy revert. |
| `deposit_to_vault` | Deposits USDC or ETH from the agent wallet into the configured vault. | The tool has no recipient argument: its only possible destination is the configured vault. Deposits are not subject to vault spending caps. |
| `request_approval` | Creates a transfer request on-chain with a reason and returns its request ID. | Funds do not move until the owner approves the request using an owner-controlled wallet. |
| `check_tx` | Reads a mined Base Sepolia transaction receipt and returns its BaseScan link. | A pending or unknown transaction does not yet have a receipt. |
| `read_url` | Fetches a URL, removes basic script/style markup, and returns a text excerpt. | Page content is untrusted; see [Security and limitations](#security-and-limitations). |
| `get_country_info` | Calls the local `/api/countries` route. | Experimental; the route's API-key name and `.env.example` are currently inconsistent. |

The agent's system prompt warns it not to follow instructions or payment addresses found in web content. This is a model instruction, not an enforceable security boundary; the vault contract is the enforcement boundary for transfers made through it. The agent may also fund the vault from its own wallet using `deposit_to_vault`; that tool can send only to the configured vault address.

## Spending budget behavior

When the mock weather endpoint responds with HTTP 402, the agent checks the declared price against `X402_MAX_PER_CALL` and `X402_DAILY_BUDGET` before signing the payment message. The daily total is stored locally in `.x402-budget.json` and rolls over by UTC date. `X402_ALLOWED_PAYEES` can optionally restrict the payee addresses used by this flow.

These are **off-chain demo checks**, not a wallet policy or security guarantee. Budget state is local to the app's filesystem, is not concurrency-safe, and is recorded before signing and retrying the request. A signing or request failure can therefore still count toward the budget. The mock server verifies the signed message, but does not settle a payment or verify a blockchain transaction. A separate x402 SDK buyer integration, third-party paid API discovery, and vault-to-agent float refill are not implemented.

## Model selection

Set `GEMINI_MODELS` to a comma-separated list of Gemini model IDs. The list populates the homepage dropdown; its first entry is the initial/default selection. If `GEMINI_MODELS` is unset, `GEMINI_MODEL` is used as the single model. If neither is set, the default is `gemini-flash-latest`.

```dotenv
GEMINI_MODEL=gemini-flash-latest
GEMINI_MODELS=gemini-flash-latest,gemini-2.5-flash
```

The model IDs must be available to the configured Google AI API key. Restart the development server after changing environment variables.

## Tech stack

Versions below are resolved in `package-lock.json`:

| Layer | Technology | Version / details |
| --- | --- | --- |
| Language | TypeScript | 5.9.3 |
| Framework | Next.js | 16.4.0 |
| UI | React | 19.3.0 |
| AI SDK | `@google/genai` | 2.27.0 |
| EVM client | viem | 2.57.3 |
| Smart contract | Solidity `AgentVault` | Solidity `0.8.24`; OpenZeppelin Contracts `5.1.0` |
| Network | Base Sepolia | Chain ID `84532` |

## Getting started

Requirements: Node.js compatible with the installed Next.js version and npm.

```bash
git clone https://github.com/BenFaruna/warden.git
cd warden
npm install
cp .env.example .env
npm run dev
```

Add a Google AI API key as `GEMINI_API_KEY` in `.env`, then open [http://localhost:3000](http://localhost:3000). The app can create a wallet using the **Create wallet** button, or use a testnet key provided as `AGENT_PRIVATE_KEY` (preferred) or the legacy `WALLET_PRIVATE_KEY`. To use the vault tools, the wallet address must be configured as the vault's agent and must have Base Sepolia ETH for gas.

Example optional configuration:

```dotenv
GEMINI_API_KEY=
GEMINI_MODEL=gemini-flash-latest
GEMINI_MODELS=gemini-flash-latest,gemini-2.5-flash
BASE_SEPOLIA_RPC_URL=https://sepolia.base.org
VAULT_ADDRESS=
USDC_ADDRESS=0x036CbD53842c5426634e7929541eC2318f3dCF7e
AGENT_PRIVATE_KEY=
WALLET_PRIVATE_KEY=
AGENT_ALLOWED_RECIPIENTS=
DEMO_FORCE_SEND=false
X402_MAX_PER_CALL=0.05
X402_DAILY_BUDGET=0.50
X402_ALLOWED_PAYEES=
COUNTRIES_API_KEY=
```

Use only a dedicated test wallet. The app stores a wallet created in the UI in `.agent-wallet.json` as a private key in plaintext. Keep `.env` and `.agent-wallet.json` private; do not use a mainnet wallet or expose this prototype as a public service.

## Security and limitations

- The vault enforces token allowlists, recipient allowlists, transaction caps, daily direct-transfer caps, approvals, and pause state on-chain. These checks apply to outgoing transfers through the deployed vault; they do not govern the agent's own EOA or x402 signatures.
- `deposit_to_vault` is an uncapped inbound funding path from the agent EOA to the configured vault only. It exposes no arbitrary destination input and verifies that the signer is the vault's configured agent. For any transfer from the agent wallet to another address, no such tool is provided; payments from vault funds must use `send_token` or `request_approval`.
- The deployment record in `contracts/deployments/84532.json` is used as the default vault address. Set `VAULT_ADDRESS` if using another Base Sepolia deployment. Confirm the address and agent configuration before funding the vault.
- `request_approval` creates a real on-chain request, but this app has no owner console or in-app notification/approval flow. The owner must approve or reject through a separate wallet interface.
- Transactions are simulated before submission by default. `DEMO_FORCE_SEND=true` is for controlled Base Sepolia demonstrations only: it submits transactions even when simulation identifies a contract policy revert, so reverted transactions still incur gas.
- The contract uses a fixed 24-hour spend window, not a rolling window. Amount limits are denominated independently in each token's base units; the vault does not aggregate token values.
- The weather endpoint is a mock API. Its `X-PAYMENT` message is custom demo data; it does not use a production x402 settlement flow or move USDC.
- The wallet private key is held by the server process and is stored unencrypted when created through the UI. Anyone who can access that file or the configured environment can use the key.
- The x402 budget file is local and should not be treated as tamper-proof, shared across instances, or resistant to simultaneous requests.
- `read_url` fetches a model-selected URL from the server. Basic markup removal is not a security-grade HTML sanitizer or network-access control. Do not make this endpoint available to untrusted users or use it to fetch sensitive/internal services.
- Tool output and the system prompt cannot guarantee protection from prompt injection.
- `get_country_info` is experimental. The route currently checks `COUTRIES_API_KEY`, while `.env.example` lists `COUNTRIES_API_KEY`; correct this configuration mismatch before relying on the feature.
- The application has a production build command but no dedicated automated test suite configured in `package.json`.

## Demo

**Week 1:** [Video](https://x.com/Barthol85956518/status/2109341716759331183)

**Week 2:** [Video](https://x.com/Barthol85956518/status/2111033727073816774)

These are historical demo links; check the current repository configuration before assuming that a video demonstrates the current tool behavior.

## Roadmap

Possible next steps—not currently implemented:

- Add a browser-wallet owner console for policy management, pending request approval/rejection, pause/resume, and withdrawal.
- Add transaction/activity history for both successful and reverted vault actions.
- Improve x402 payment handling and budget persistence, including concurrency-safe accounting.
- Integrate the production x402 buyer SDK and a trusted third-party paid service; consider a policy-safe float refill.
- Add authentication and network restrictions before enabling arbitrary URL fetching for other users.

## Social media

- Twitter/X: [Warden](https://x.com/Barthol85956518)
- Builder camp: [@riseinweb3](https://twitter.com/riseinweb3)
