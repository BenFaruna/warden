<div align="center">

<img src="./public/warden.png" alt="Warden logo" width="120" />

# Warden

**An AI agent with a testnet wallet, tool calling, and experimental spending guardrails.**

[Twitter/X](#social-media) · [Demo](#demo) · [Roadmap](#roadmap) · [Live](https://warden.pxxlspace.cv/)

</div>

---

## What Warden does

Warden is a Next.js chat app backed by a Google Gemini agent. The agent can call tools, create and inspect a Base Sepolia wallet, read webpages, and use a mock paid-weather endpoint. The homepage also lets you choose from the Gemini models configured in the environment.

This repository is currently a prototype. It does **not** contain or connect to a policy smart contract, and the agent cannot make token transfers. The wallet balance lookup reads the wallet's native testnet ETH balance; the mock weather payment is a signed message, not an on-chain USDC payment.

## Current capabilities

| Tool | What it does | Important detail |
| --- | --- | --- |
| `get_weather` | Requests demo weather data from the local `/api/weather` endpoint. | The endpoint requests a `0.01 USDC`-labelled signed payment, but no USDC is transferred. |
| `get_my_wallet` | Reports the agent wallet address, native ETH balance, and x402 budget status. | The balance is queried on Base Sepolia. |
| `roll_dice` | Rolls a die with the requested number of sides, defaulting to 6. | Local utility; no wallet required. |
| `get_joke` | Requests a random joke from the Official Joke API. | Requires the external service to be reachable. |
| `get_vault_policy` | Returns example policy values and x402 budget status. | Static demo data; it does not read a deployed vault or enforce those values. |
| `request_approval` | Returns a generated request ID and pending-review details. | No request is persisted, sent to an owner, or approved on-chain. |
| `read_url` | Fetches a URL, removes basic script/style markup, and returns a text excerpt. | Page content is untrusted; see [Security and limitations](#security-and-limitations). |
| `get_country_info` | Calls the local `/api/countries` route. | Experimental; the route's API-key name and `.env.example` are currently inconsistent. |

The agent's system prompt warns it not to follow instructions or payment addresses found in web content. This is a model instruction, not an enforceable security boundary.

## Spending budget behavior

When the mock weather endpoint responds with HTTP 402, the agent checks the declared price against `X402_MAX_PER_CALL` and `X402_DAILY_BUDGET` before signing the payment message. The daily total is stored locally in `.x402-budget.json` and rolls over by UTC date. `X402_ALLOWED_PAYEES` can optionally restrict the payee addresses used by this flow.

These are **off-chain demo checks**, not a wallet policy or security guarantee. Budget state is local to the app's filesystem, is not concurrency-safe, and is recorded before signing and retrying the request. A signing or request failure can therefore still count toward the budget. The mock server verifies the signed message, but does not settle a payment or verify a blockchain transaction.

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
| Network for wallet balance lookup | Base Sepolia | Chain ID `84532` |

## Getting started

Requirements: Node.js compatible with the installed Next.js version and npm.

```bash
git clone https://github.com/BenFaruna/warden.git
cd warden
npm install
cp .env.example .env
npm run dev
```

Add a Google AI API key as `GEMINI_API_KEY` in `.env`, then open [http://localhost:3000](http://localhost:3000). The app can create a new wallet using the **Create wallet** button, or use a testnet key provided as `WALLET_PRIVATE_KEY`.

Example optional configuration:

```dotenv
GEMINI_API_KEY=
GEMINI_MODEL=gemini-flash-latest
GEMINI_MODELS=gemini-flash-latest,gemini-2.5-flash
WALLET_PRIVATE_KEY=
X402_MAX_PER_CALL=0.05
X402_DAILY_BUDGET=0.50
X402_ALLOWED_PAYEES=
COUNTRIES_API_KEY=
```

Use only a dedicated test wallet. The app stores a wallet created in the UI in `.agent-wallet.json` as a private key in plaintext. Keep `.env` and `.agent-wallet.json` private; do not use a mainnet wallet or expose this prototype as a public service.

## Security and limitations

- There is no smart contract, vault deployment, token-transfer tool, on-chain spending cap, real approval workflow, or kill switch in this repository.
- `get_vault_policy` and `request_approval` are illustrative placeholders, not enforcement or a durable workflow.
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

This is a historical demo link. It does not demonstrate a deployed policy vault or the current prototype's budget checks.

## Roadmap

Possible next steps—not currently implemented:

- Implement and test an on-chain spending-policy vault and connect agent-side transfer tools to it.
- Replace placeholder policy and approval tools with persistent, owner-controlled workflows.
- Improve x402 payment handling and budget persistence, including concurrency-safe accounting.
- Add authentication and network restrictions before enabling arbitrary URL fetching for other users.

## Social media

- Twitter/X: [Warden](https://x.com/Barthol85956518)
- Builder camp: [@riseinweb3](https://twitter.com/riseinweb3)
