import {
  createPublicClient,
  createWalletClient,
  getAddress,
  http,
  isAddress,
  type Address,
} from "viem";
import { baseSepolia } from "viem/chains";
import deployment from "../../contracts/deployments/84532.json";
import { requireWalletAccount } from "../../agent/wallet";

export const USDC_ADDRESS = getAddress(
  process.env.USDC_ADDRESS ?? "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
);

const RPC_URL =
  process.env.BASE_SEPOLIA_RPC_URL ??
  process.env.BASE_SEPOLIA_RPC ??
  "https://sepolia.base.org";
const CONFIGURED_VAULT =
  process.env.VAULT_ADDRESS ??
  process.env.NEXT_PUBLIC_VAULT_ADDRESS ??
  deployment.vault;

export const publicClient = createPublicClient({
  chain: baseSepolia,
  transport: http(RPC_URL),
});

export function getVaultAddress(): Address {
  if (!isAddress(CONFIGURED_VAULT)) {
    throw new Error("Set VAULT_ADDRESS to the deployed Base Sepolia AgentVault address.");
  }
  return getAddress(CONFIGURED_VAULT);
}

export function getAgentWalletClient() {
  const account = requireWalletAccount();
  return createWalletClient({
    account,
    chain: baseSepolia,
    transport: http(RPC_URL),
  });
}

export function parseConfiguredRecipients(): Address[] {
  return (process.env.AGENT_ALLOWED_RECIPIENTS ?? "")
    .split(",")
    .map((recipient) => recipient.trim())
    .filter(Boolean)
    .map((recipient) => {
      if (!isAddress(recipient)) {
        throw new Error(`Invalid address in AGENT_ALLOWED_RECIPIENTS: ${recipient}`);
      }
      return getAddress(recipient);
    });
}
