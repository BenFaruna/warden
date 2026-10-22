// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {AgentVault} from "../src/AgentVault.sol";

/// @notice Deploys and configures an AgentVault.
///
/// @dev The broadcaster deploys the vault as its initial owner, applies the policy, then (optionally)
///      hands ownership to OWNER_ADDRESS. Ownership transfer is two-step, so the new owner must call
///      `acceptOwnership()` before it takes effect.
///
///      Required env vars
///        AGENT_ADDRESS     address the agent will sign with (must differ from the owner)
///        USDC_ADDRESS      the ERC-20 the agent may spend (must match the token your x402 flow uses)
///      Optional env vars (defaults shown; USDC has 6 decimals)
///        OWNER_ADDRESS     final owner; defaults to the broadcaster
///        RECIPIENTS        comma-separated allowlist, e.g. 0xabc...,0xdef...
///        USDC_PER_TX=2000000  USDC_THRESHOLD=1000000  USDC_DAILY=5000000
///        ETH_PER_TX=1000000000000000  ETH_THRESHOLD=500000000000000  ETH_DAILY=2000000000000000
///        WRITE_DEPLOYMENT=true   write deployments/<chainId>.json
///
///      Example (Base Sepolia):
///        forge script script/Deploy.s.sol --rpc-url $BASE_SEPOLIA_RPC_URL \
///          --private-key $OWNER_PRIVATE_KEY --broadcast
contract Deploy is Script {
    function run() external returns (AgentVault vault) {
        address agent = vm.envAddress("AGENT_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address finalOwner = vm.envOr("OWNER_ADDRESS", address(0));
        address[] memory recipients = vm.envOr("RECIPIENTS", ",", new address[](0));

        uint256 usdcPerTx = vm.envOr("USDC_PER_TX", uint256(2e6));
        uint256 usdcThreshold = vm.envOr("USDC_THRESHOLD", uint256(1e6));
        uint256 usdcDaily = vm.envOr("USDC_DAILY", uint256(5e6));
        uint256 ethPerTx = vm.envOr("ETH_PER_TX", uint256(0.001 ether));
        uint256 ethThreshold = vm.envOr("ETH_THRESHOLD", uint256(0.0005 ether));
        uint256 ethDaily = vm.envOr("ETH_DAILY", uint256(0.002 ether));

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        vault = new AgentVault(deployer);
        vault.setAgent(agent);
        vault.setTokenPolicy(usdc, true, usdcPerTx, usdcDaily, usdcThreshold);
        vault.setTokenPolicy(address(0), true, ethPerTx, ethDaily, ethThreshold);
        for (uint256 i; i < recipients.length; ++i) {
            vault.setRecipient(recipients[i], true);
        }

        if (finalOwner != address(0) && finalOwner != deployer) {
            vault.transferOwnership(finalOwner); // pending until finalOwner calls acceptOwnership()
        }
        vm.stopBroadcast();

        console2.log("AgentVault deployed at:", address(vault));
        console2.log("  owner (current):", vault.owner());
        console2.log("  owner (pending):", vault.pendingOwner());
        console2.log("  agent          :", agent);
        console2.log("  recipients     :", recipients.length);

        if (vm.envOr("WRITE_DEPLOYMENT", true)) {
            string memory key = "deployment";
            vm.serializeAddress(key, "vault", address(vault));
            vm.serializeAddress(key, "agent", agent);
            vm.serializeAddress(key, "usdc", usdc);
            vm.serializeUint(key, "blockNumber", block.number);
            string memory json = vm.serializeUint(key, "chainId", block.chainid);
            vm.writeJson(json, string.concat("./deployments/", vm.toString(block.chainid), ".json"));
        }
    }
}
