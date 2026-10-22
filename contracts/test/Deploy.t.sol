// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {AgentVault} from "../src/AgentVault.sol";

/// @notice Runs the deployment script in-process and checks that the resulting vault is configured
///         exactly as documented, so a broken script is caught before it touches a real network.
contract DeployScriptTest is Test {
    address internal agent = makeAddr("agent");
    address internal usdc = makeAddr("usdc");
    address internal friend = makeAddr("friend");
    address internal other = makeAddr("other");

    function _baseEnv() internal {
        vm.setEnv("AGENT_ADDRESS", vm.toString(agent));
        vm.setEnv("USDC_ADDRESS", vm.toString(usdc));
        vm.setEnv("WRITE_DEPLOYMENT", "false");
    }

    function test_Deploy_AppliesDefaultPolicy() public {
        _baseEnv();
        vm.setEnv("RECIPIENTS", string.concat(vm.toString(friend), ",", vm.toString(other)));
        vm.setEnv("OWNER_ADDRESS", "0x0000000000000000000000000000000000000000");

        AgentVault v = new Deploy().run();

        assertEq(v.agent(), agent);
        assertTrue(v.allowedRecipient(friend));
        assertTrue(v.allowedRecipient(other));
        assertFalse(v.paused());

        AgentVault.TokenPolicy memory u = v.getPolicy(usdc);
        assertTrue(u.allowed);
        assertEq(u.perTxCap, 2e6);
        assertEq(u.approvalThreshold, 1e6);
        assertEq(u.dailyCap, 5e6);

        AgentVault.TokenPolicy memory e = v.getPolicy(address(0));
        assertTrue(e.allowed);
        assertEq(e.perTxCap, 0.001 ether);
        assertEq(e.approvalThreshold, 0.0005 ether);
        assertEq(e.dailyCap, 0.002 ether);
    }

    function test_Deploy_StartsTwoStepHandoffToFinalOwner() public {
        _baseEnv();
        vm.setEnv("RECIPIENTS", vm.toString(friend));
        address finalOwner = makeAddr("finalOwner");
        vm.setEnv("OWNER_ADDRESS", vm.toString(finalOwner));

        AgentVault v = new Deploy().run();

        assertEq(v.pendingOwner(), finalOwner, "handoff pending until accepted");
        assertTrue(v.owner() != finalOwner);
        vm.prank(finalOwner);
        v.acceptOwnership();
        assertEq(v.owner(), finalOwner);
    }
}
