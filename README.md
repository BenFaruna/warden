<div align="center">

<!-- Replace with your logo path or URL -->
<img src="./public/warden.png" alt="Warden logo" width="120" />

# Warden

**An AI agent with a wallet it can't abuse.**

Spending power for agents, enforced by rules instead of trust.

[Twitter/X](#social-media) · [Demo Video](#demo) · [Future Scope](#future-scope)

</div>

---

## Project Description

### The problem

AI agents are starting to move money: paying for APIs, swapping tokens, funding other agents. But handing an LLM a raw private key is dangerous. Agents can be prompt-injected by a malicious webpage, hallucinate an address, or get stuck in a loop and drain a wallet.

### What Warden does

Warden is an AI agent that owns an on-chain wallet and can use it autonomously, inside strict spending limits. The long-term goal is a policy-enforced agent wallet where the agent holds only a scoped, revocable session key. Per-transaction caps, daily budgets, contract allowlists, and human approval for large payments are enforced on-chain rather than by the agent's own good behavior. Warden also pays for paid APIs automatically using the **x402** (HTTP 402) pay-per-request protocol.

Even if the agent is manipulated, the damage is capped by the policy.

> **Current status (Week 1):** a working tool-calling agent with its own Base Sepolia wallet and x402 payments for paid endpoints. The guardrail layer is planned for Weeks 2 and 3 (see [Future Scope](#future-scope)).

---

## Tech Stack

> Fill in the exact versions from your `package.json` / lockfile.

| Layer | Technology | Version |
| --- | --- | --- |
| Language | TypeScript | `5.9.3` |
| Framework | Next.js (API routes) | `16.3.6` |
| Runtime | Node.js | `24.10.0` |
| Blockchain library | viem | `2.56.9` |
| Network | Base Sepolia (testnet) | Chain ID `84532` |
| Payment token | USDC (testnet) | n/a |
| AI provider SDK | `<your SDK>` | `x.x.x` |

---

## Tools

The agent currently supports **5 built-in tools**:

| # | Tool | Description | Wallet / Payment |
| --- | --- | --- | --- |
| 1 | `get_weather` | Gets the current weather for a city from a paywalled API. | Pays **0.01 USDC** via x402 from the agent's wallet |
| 2 | `get_my_wallet` | Returns the agent's own wallet address and ETH balance on Base Sepolia. | Read-only |
| 3 | `roll_dice` | Rolls a dice with a configurable number of sides (default 6). | None |
| 4 | `get_joke` | Fetches a random joke from the Official Joke API. | None |
| 5 | `get_country_info` | Returns facts about a country (capital, population, region). | None |

Tools 3 to 5 are utility and testing tools used to validate the tool-calling framework. They will be replaced or extended with wallet, policy, and approval tools as the project evolves (see [Future Scope](#future-scope)).

---

## Supported AI Models

> List every model your agent supports with exact versions. If you have a model switcher, list all of them.

| Provider | Model | Version / ID | Default |
| --- | --- | --- | --- |
| Google | Gemini 3.8 Flash | `gemini-3.8-flash` | Yes |

---

## Key Features

- **Autonomous tool calling:** the agent decides which tool to use based on the user's request.
- **Agent-owned wallet:** the agent has its own address on Base Sepolia and can inspect its balance.
- **x402 pay-per-request:** when an API responds with HTTP 402, the agent signs a USDC payment and retries automatically.
- **Extensible tool framework:** each tool is a typed definition (`name`, `description`, JSON-schema `parameters`, `run`), so adding a new capability takes a few lines.
- **Testnet-first:** all payments run on Base Sepolia, so there is no real money at risk while the system is built.

---

## Demo

**Week 1 (warden.v1):** [Link](https://x.com/Barthol85956518/status/2109341716759331183)

---

## Future Scope

Planned improvements for the coming weeks:

**Week 2: Wallet guardrails**

- Smart-contract wallet (ERC-4337) with a scoped, revocable session key for the agent
- Per-transaction and rolling daily spend caps
- Allowlisted contracts, function selectors, recipients, and tokens
- Instant kill switch that revokes the agent's session key
- Replace the demo tools (`roll_dice`, `get_joke`) with `send_token`, `pay_for_api`, and `request_approval`
- Foundry tests covering attack scenarios

**Week 3: x402 policy checks and human approval**

- x402 payment wrapper that checks every price against the policy before signing
- Human-in-the-loop approval flow for payments above a threshold (Telegram or web notification)
- Dashboard showing agent activity, budgets, and blocked attempts
- Red-team demo: a prompt-injection attack that tries to drain the wallet and is rejected on-chain

**Stretch**

- Natural-language policy authoring with a human-reviewed preview
- Per-merchant budgets and spend analytics
- Anomaly detection that auto-pauses the agent
- Multiple agents with separate policies under one owner
- ZK-based proofs for private policy compliance

---

## Week 1 Submission

### Task summary

| Requirement | Status |
| --- | --- |
| Choose a niche / problem / project idea | Done: safe spending infrastructure for AI agents with wallets |
| Modify the default Agentmaxxin project or build from scratch | Done: `<modified default project / new project>` |
| At least 5 core built-in tools | Done: 5 tools (`get_weather`, `get_my_wallet`, `roll_dice`, `get_joke`, `get_country_info`) |
| README includes logo, name, description, tech stack, tools, models, features, demo, future scope, socials | Done |
| Dedicated Twitter/X product page | [Warden](https://x.com/Barthol85956518) |

### What was built this week

- Set up the agent framework and tool-calling loop.
- Implemented the agent's wallet on Base Sepolia, including address and balance lookup.
- Integrated an x402-paywalled weather API that the agent pays for automatically (0.01 USDC per call).
- Added utility tools to test how the framework handles different tool shapes: no-parameter tools, optional parameters, external API calls, and internal API routes.

### What was learned

- How the tool schema (`name`, `description`, `parameters`) drives the model's decision on when and how to call a tool.
- How an HTTP 402 response, a signed payment, and a retry work end to end through `payAndFetch`.
- Where the project needs to change next: the agent currently pays without any spending policy, which is the gap the Week 2 guardrail layer is designed to close.

### Week 1 demo

**Week 1 (warden.v1):** [Video](https://x.com/Barthol85956518/status/2109341716759331183)

### Week 1 social posts

1. [Post](https://x.com/Barthol85956518/status/2109341716759331183)

---

## Social Media

- Twitter/X: [Warden](https://x.com/Barthol85956518)
- Builder camp: [@riseinweb3](https://twitter.com/riseinweb3)

---

## Getting Started

```bash
git clone <repo-url>
cd warden
npm install
cp .env.example .env   # add your model API key and agent wallet private key (testnet only)
npm run dev
```

> **Security note:** use a dedicated testnet wallet for the agent. Never put a mainnet key in `.env`.
