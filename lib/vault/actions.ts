import {
  BaseError,
  ContractFunctionRevertedError,
  formatUnits,
  getAddress,
  isAddress,
  parseEventLogs,
  parseUnits,
  type Address,
  type Hex,
} from "viem";
import { agentVaultAbi } from "../abi/AgentVault";
import { requireWalletAccount } from "../../agent/wallet";
import {
  getAgentWalletClient,
  getVaultAddress,
  parseConfiguredRecipients,
  publicClient,
  USDC_ADDRESS,
} from "./client";

const tokenAbi = [
  {
    type: "function",
    name: "balanceOf",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

const tokenTransferAbi = [
  {
    type: "function",
    name: "transfer",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
] as const;

const ERROR_HINTS: Record<string, string> = {
  VaultPaused: "The owner paused the vault. Stop and tell the user; do not retry.",
  RecipientNotAllowed: "This recipient is not allowlisted. Do not retry or work around it; ask the user to allowlist it.",
  TokenNotAllowed: "This token is not enabled in the vault policy. Do not retry.",
  ExceedsPerTxCap: "This exceeds the per-transaction hard cap. Do not split the transfer to bypass the cap.",
  NeedsApproval: "The amount requires human approval. Submit a request with request_approval.",
  ExceedsDailyCap: "The direct-transfer daily budget is exhausted. Wait for the window to reset or ask the user.",
  TooManyPendingRequests: "The vault has too many pending requests. Stop and ask the owner to review them.",
  NotAgent: "The configured wallet is not the vault's agent. Check the deployment configuration.",
  OwnableUnauthorizedAccount: "The configured wallet is not authorized for this action.",
};

type DecodedVaultError = {
  ok: false;
  error: string;
  args: string[];
  hint: string;
};

type VaultToken = "USDC" | "ETH";

let transactionQueue = Promise.resolve();

function serializeAgentTransaction<T>(operation: () => Promise<T>): Promise<T> {
  const result = transactionQueue.then(operation);
  transactionQueue = result.then(
    () => undefined,
    () => undefined,
  );
  return result;
}

function getToken(token: unknown = "USDC"): { name: VaultToken; address: Address; decimals: number } {
  if (typeof token !== "string") throw new Error("Token must be USDC or ETH.");
  const normalized = token.toUpperCase();
  if (normalized === "USDC") return { name: "USDC", address: USDC_ADDRESS, decimals: 6 };
  if (normalized === "ETH") return { name: "ETH", address: "0x0000000000000000000000000000000000000000", decimals: 18 };
  throw new Error("Supported tokens are USDC and ETH.");
}

function parseAmount(amount: unknown, decimals: number): bigint {
  if (typeof amount !== "string" || !/^(?:0|[1-9]\d*)(?:\.\d+)?$/.test(amount.trim())) {
    throw new Error("Amount must be a positive decimal string, for example \"0.5\".");
  }
  const parsed = parseUnits(amount.trim(), decimals);
  if (parsed <= 0n) throw new Error("Amount must be greater than zero.");
  return parsed;
}

function formatAmount(amount: bigint, decimals: number): string {
  return formatUnits(amount, decimals);
}

function decodeVaultError(error: unknown): DecodedVaultError | null {
  if (!(error instanceof BaseError)) return null;
  const reverted = error.walk((cause) => cause instanceof ContractFunctionRevertedError);
  if (!(reverted instanceof ContractFunctionRevertedError) || !reverted.data?.errorName) return null;

  const name = reverted.data.errorName;
  return {
    ok: false,
    error: name,
    args: (reverted.data.args ?? []).map(String),
    hint: ERROR_HINTS[name] ?? "The vault rejected this action. Do not retry without resolving the reported policy error.",
  };
}

function asAddress(value: unknown, label: string): Address {
  if (typeof value !== "string" || !isAddress(value)) {
    throw new Error(`${label} must be a valid EVM address.`);
  }
  return getAddress(value);
}

function explorerTx(hash: Hex): string {
  return `https://sepolia.basescan.org/tx/${hash}`;
}

async function finishTransaction(hash: Hex) {
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  return {
    hash,
    explorer: explorerTx(hash),
    status: receipt.status,
    receipt,
  };
}

export async function getVaultOverview() {
  const vault = getVaultAddress();
  const recipients = parseConfiguredRecipients();
  const [paused, owner, agent, pendingCount, usdcPolicy, ethPolicy, usdcRemaining, ethRemaining, usdcBalance, ethBalance, ...recipientChecks] =
    await Promise.all([
      publicClient.readContract({ address: vault, abi: agentVaultAbi, functionName: "paused" }),
      publicClient.readContract({ address: vault, abi: agentVaultAbi, functionName: "owner" }),
      publicClient.readContract({ address: vault, abi: agentVaultAbi, functionName: "agent" }),
      publicClient.readContract({ address: vault, abi: agentVaultAbi, functionName: "pendingCount" }),
      publicClient.readContract({ address: vault, abi: agentVaultAbi, functionName: "getPolicy", args: [USDC_ADDRESS] }),
      publicClient.readContract({ address: vault, abi: agentVaultAbi, functionName: "getPolicy", args: ["0x0000000000000000000000000000000000000000"] }),
      publicClient.readContract({ address: vault, abi: agentVaultAbi, functionName: "remainingDaily", args: [USDC_ADDRESS] }),
      publicClient.readContract({ address: vault, abi: agentVaultAbi, functionName: "remainingDaily", args: ["0x0000000000000000000000000000000000000000"] }),
      publicClient.readContract({ address: vault, abi: agentVaultAbi, functionName: "balanceOf", args: [USDC_ADDRESS] }),
      publicClient.readContract({ address: vault, abi: agentVaultAbi, functionName: "balanceOf", args: ["0x0000000000000000000000000000000000000000"] }),
      ...recipients.map((recipient) =>
        publicClient.readContract({ address: vault, abi: agentVaultAbi, functionName: "allowedRecipient", args: [recipient] }),
      ),
    ]);

  const pendingIds = await publicClient.readContract({
    address: vault,
    abi: agentVaultAbi,
    functionName: "getPendingRequestIds",
  });
  const requests = await Promise.all(
    pendingIds.map(async (id) => {
      const request = await publicClient.readContract({
        address: vault,
        abi: agentVaultAbi,
        functionName: "getRequest",
        args: [id],
      });
      return {
        id: id.toString(),
        token: request.token,
        recipient: request.to,
        amount: formatAmount(request.amount, request.token.toLowerCase() === USDC_ADDRESS.toLowerCase() ? 6 : 18),
        createdAt: Number(request.createdAt),
        reason: request.reason,
      };
    }),
  );

  const policy = (data: typeof usdcPolicy, remaining: bigint, decimals: number) => ({
    allowed: data.allowed,
    perTxCap: formatAmount(data.perTxCap, decimals),
    approvalThreshold: formatAmount(data.approvalThreshold, decimals),
    dailyCap: formatAmount(data.dailyCap, decimals),
    remainingDaily: formatAmount(remaining, decimals),
  });

  return {
    vaultAddress: vault,
    owner,
    agent,
    paused,
    network: "Base Sepolia",
    balances: {
      USDC: formatAmount(usdcBalance, 6),
      ETH: formatAmount(ethBalance, 18),
    },
    policies: {
      USDC: policy(usdcPolicy, usdcRemaining, 6),
      ETH: policy(ethPolicy, ethRemaining, 18),
    },
    configuredRecipients: recipients.map((address, index) => ({
      address,
      allowed: recipientChecks[index] as boolean,
    })),
    pendingCount: Number(pendingCount),
    pendingRequests: requests,
  };
}

export async function getAgentWalletOverview() {
  const account = requireWalletAccount();
  const vault = getVaultAddress();
  const [ethBalance, usdcBalance, vaultOverview, registeredAgent] = await Promise.all([
    publicClient.getBalance({ address: account.address }),
    publicClient.readContract({
      address: USDC_ADDRESS,
      abi: tokenAbi,
      functionName: "balanceOf",
      args: [account.address],
    }),
    getVaultOverview(),
    publicClient.readContract({ address: vault, abi: agentVaultAbi, functionName: "agent" }),
  ]);

  return {
    address: account.address,
    isRegisteredAgent: registeredAgent.toLowerCase() === account.address.toLowerCase(),
    network: "Base Sepolia",
    explorer: `https://sepolia.basescan.org/address/${account.address}`,
    balances: {
      ETH: formatAmount(ethBalance, 18),
      USDC: formatAmount(usdcBalance, 6),
    },
    vault: vaultOverview,
  };
}

async function sendTokenTransaction(token: Address, to: Address, amount: bigint) {
  const account = requireWalletAccount();
  const vault = getVaultAddress();
  const walletClient = getAgentWalletClient();
  const forceSend = process.env.DEMO_FORCE_SEND === "true";

  return serializeAgentTransaction(async () => {
    if (token === "0x0000000000000000000000000000000000000000") {
      if (forceSend) {
        let preflightError: DecodedVaultError | null = null;
        try {
          await publicClient.simulateContract({
            account,
            address: vault,
            abi: agentVaultAbi,
            functionName: "transferETH",
            args: [to, amount],
          });
        } catch (error) {
          preflightError = decodeVaultError(error);
          if (!preflightError) throw error;
        }

        const hash = await walletClient.writeContract({
          account,
          address: vault,
          abi: agentVaultAbi,
          functionName: "transferETH",
          args: [to, amount],
          gas: 200_000n,
        });
        const transaction = await finishTransaction(hash);
        return transaction.status === "reverted"
          ? { ...(preflightError ?? { ok: false as const, error: "TransactionReverted", args: [], hint: "The transaction reverted on Base Sepolia." }), blockedOnChain: true, hash, explorer: transaction.explorer }
          : { ok: true as const, hash, explorer: transaction.explorer, status: transaction.status };
      }

      const { request } = await publicClient.simulateContract({
        account,
        address: vault,
        abi: agentVaultAbi,
        functionName: "transferETH",
        args: [to, amount],
      });
      const hash = await walletClient.writeContract(request);
      const transaction = await finishTransaction(hash);
      return transaction.status === "reverted"
        ? { ok: false as const, error: "TransactionReverted", args: [], hint: "The transaction reverted on Base Sepolia.", hash, explorer: transaction.explorer }
        : { ok: true as const, hash, explorer: transaction.explorer, status: transaction.status };
    }

    if (forceSend) {
      let preflightError: DecodedVaultError | null = null;
      try {
        await publicClient.simulateContract({
          account,
          address: vault,
          abi: agentVaultAbi,
          functionName: "transferToken",
          args: [token, to, amount],
        });
      } catch (error) {
        preflightError = decodeVaultError(error);
        if (!preflightError) throw error;
      }

      const hash = await walletClient.writeContract({
        account,
        address: vault,
        abi: agentVaultAbi,
        functionName: "transferToken",
        args: [token, to, amount],
        gas: 200_000n,
      });
      const transaction = await finishTransaction(hash);
      return transaction.status === "reverted"
        ? { ...(preflightError ?? { ok: false as const, error: "TransactionReverted", args: [], hint: "The transaction reverted on Base Sepolia." }), blockedOnChain: true, hash, explorer: transaction.explorer }
        : { ok: true as const, hash, explorer: transaction.explorer, status: transaction.status };
    }

    const { request } = await publicClient.simulateContract({
      account,
      address: vault,
      abi: agentVaultAbi,
      functionName: "transferToken",
      args: [token, to, amount],
    });
    const hash = await walletClient.writeContract(request);
    const transaction = await finishTransaction(hash);
    return transaction.status === "reverted"
      ? { ok: false as const, error: "TransactionReverted", args: [], hint: "The transaction reverted on Base Sepolia.", hash, explorer: transaction.explorer }
      : { ok: true as const, hash, explorer: transaction.explorer, status: transaction.status };
  });
}

export async function sendVaultToken(toValue: unknown, amountValue: unknown, tokenValue: unknown = "USDC") {
  const recipient = asAddress(toValue, "Recipient");
  const token = getToken(tokenValue);
  const amount = parseAmount(amountValue, token.decimals);

  try {
    const result = await sendTokenTransaction(token.address, recipient, amount);
    return { ...result, token: token.name, amount: formatAmount(amount, token.decimals) };
  } catch (error) {
    const decoded = decodeVaultError(error);
    if (decoded) return decoded;
    throw error;
  }
}

export async function depositAgentFundsToVault(amountValue: unknown, tokenValue: unknown = "USDC") {
  const token = getToken(tokenValue);
  const amount = parseAmount(amountValue, token.decimals);
  const account = requireWalletAccount();
  const vault = getVaultAddress();

  return serializeAgentTransaction(async () => {
    const registeredAgent = await publicClient.readContract({
      address: vault,
      abi: agentVaultAbi,
      functionName: "agent",
    });
    if (registeredAgent.toLowerCase() !== account.address.toLowerCase()) {
      throw new Error("The agent wallet is not registered as this vault's agent; refusing to deposit.");
    }

    const walletClient = getAgentWalletClient();
    let hash: Hex;
    if (token.name === "ETH") {
      await publicClient.call({
        account,
        to: vault,
        value: amount,
      });
      hash = await walletClient.sendTransaction({
        account,
        to: vault,
        value: amount,
      });
    } else {
      const { request } = await publicClient.simulateContract({
        account,
        address: token.address,
        abi: tokenTransferAbi,
        functionName: "transfer",
        args: [vault, amount],
      });
      hash = await walletClient.writeContract(request);
    }

    const transaction = await finishTransaction(hash);
    if (transaction.status === "reverted") {
      return {
        ok: false,
        error: "DepositReverted",
        token: token.name,
        amount: formatAmount(amount, token.decimals),
        vaultAddress: vault,
        hash,
        explorer: transaction.explorer,
      };
    }
    return {
      ok: true,
      token: token.name,
      amount: formatAmount(amount, token.decimals),
      from: account.address,
      vaultAddress: vault,
      hash,
      explorer: transaction.explorer,
      status: transaction.status,
      cappedByVaultPolicy: false,
    };
  });
}

export async function requestVaultApproval(toValue: unknown, amountValue: unknown, reasonValue: unknown, tokenValue: unknown = "USDC") {
  const recipient = asAddress(toValue, "Recipient");
  const token = getToken(tokenValue);
  const amount = parseAmount(amountValue, token.decimals);
  if (typeof reasonValue !== "string" || !reasonValue.trim()) {
    throw new Error("Provide a short reason for the approval request.");
  }
  const reason = reasonValue.trim();

  try {
    return await serializeAgentTransaction(async () => {
      const account = requireWalletAccount();
      const vault = getVaultAddress();
      const policy = await publicClient.readContract({
        address: vault,
        abi: agentVaultAbi,
        functionName: "getPolicy",
        args: [token.address],
      });
      if (amount <= policy.approvalThreshold) {
        throw new Error(
          `This amount is at or below the ${formatAmount(policy.approvalThreshold, token.decimals)} ${token.name} approval threshold; use send_token instead.`,
        );
      }
      const { request } = await publicClient.simulateContract({
        account,
        address: vault,
        abi: agentVaultAbi,
        functionName: "requestTransfer",
        args: [token.address, recipient, amount, reason],
      });
      const hash = await getAgentWalletClient().writeContract(request);
      const transaction = await finishTransaction(hash);
      if (transaction.status === "reverted") {
        return {
          ok: false,
          error: "TransactionReverted",
          hint: "The approval request transaction reverted on Base Sepolia.",
          hash,
          explorer: transaction.explorer,
        };
      }

      const events = parseEventLogs({
        abi: agentVaultAbi,
        logs: transaction.receipt.logs,
        eventName: "TransferRequested",
      });
      const requestId = events[0]?.args.id;
      if (requestId === undefined) {
        throw new Error(`Approval request ${hash} succeeded but its TransferRequested event was missing.`);
      }

      return {
        ok: true,
        requestId: requestId.toString(),
        status: "pending_owner_review",
        owner: await publicClient.readContract({ address: vault, abi: agentVaultAbi, functionName: "owner" }),
        token: token.name,
        amount: formatAmount(amount, token.decimals),
        recipient,
        reason,
        hash,
        explorer: transaction.explorer,
        note: "The vault owner must approve or reject this request from the owner wallet. Funds have not moved yet.",
      };
    });
  } catch (error) {
    const decoded = decodeVaultError(error);
    if (decoded) return decoded;
    throw error;
  }
}

export async function getTransactionStatus(hashValue: unknown) {
  if (typeof hashValue !== "string" || !/^0x[a-fA-F0-9]{64}$/.test(hashValue)) {
    throw new Error("Transaction hash must be a 32-byte 0x-prefixed hash.");
  }
  const hash = hashValue as Hex;
  const receipt = await publicClient.getTransactionReceipt({ hash });
  return {
    hash,
    status: receipt.status,
    blockNumber: receipt.blockNumber.toString(),
    explorer: explorerTx(hash),
  };
}
