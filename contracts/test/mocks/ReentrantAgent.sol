// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AgentVault} from "../../src/AgentVault.sol";

/// @dev A malicious contract that is BOTH the vault's agent and an allowlisted recipient.
///      When it receives ETH (or a hook-token callback) it tries to re-enter the vault to move more
///      than a single transfer allows. The vault's reentrancy guard must stop it.
contract ReentrantAgent {
    AgentVault public vault;
    address public hookToken;
    uint256 public reenterAmount;
    bool public reentered;

    constructor(AgentVault v) {
        vault = v;
    }

    function attackEth(uint256 first, uint256 second) external {
        reenterAmount = second;
        vault.transferETH(address(this), first);
    }

    function attackToken(address token, uint256 first, uint256 second) external {
        hookToken = token;
        reenterAmount = second;
        vault.transferToken(token, address(this), first);
    }

    /// @dev ETH callback: try to re-enter. Reverts bubble up so the outer call fails visibly.
    receive() external payable {
        if (!reentered) {
            reentered = true;
            vault.transferETH(address(this), reenterAmount);
        }
    }

    /// @dev Called by HookToken during a token transfer to this contract (ERC-777 style).
    function onTokensReceived() external {
        if (!reentered) {
            reentered = true;
            vault.transferToken(hookToken, address(this), reenterAmount);
        }
    }
}
