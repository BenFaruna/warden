// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {AgentVault} from "../../src/AgentVault.sol";
import {MockUSDC} from "../mocks/MockERC20.sol";
import {AgentVaultHandler} from "./AgentVaultHandler.sol";

/// @notice Stateful invariant tests for AgentVault.
///
/// @dev Foundry runs hundreds of random sequences of handler actions (agent transfers, requests,
///      owner approvals/rejections, pausing, allowlist flips, withdrawals, deposits, time travel,
///      and attacks from a "compromised" agent and from strangers). After EVERY call in every
///      sequence, each `invariant_*` function below is checked.
///
///      What these prove, in plain language:
///        1. The agent can never send money to an address the owner hasn't allowlisted.
///        2. The agent can never exceed the per-tx cap, approval threshold, or daily cap.
///        3. Nothing moves while the vault is paused.
///        4. A compromised agent or stranger can never change owner-level state.
///        5. Money is conserved: the vault's balance always equals deposits minus recorded outflows.
///        6. Internal counters (pending requests, spend windows) never drift from reality.
contract AgentVaultInvariantTest is Test {
    AgentVault internal vault;
    MockUSDC internal usdc;
    AgentVaultHandler internal handler;

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");

    address internal friend = makeAddr("friend");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal attacker = makeAddr("attacker");
    address internal mallory = makeAddr("mallory");

    uint256 internal constant PER_TX = 2e6;
    uint256 internal constant THRESHOLD = 1e6;
    uint256 internal constant DAILY = 5e6;
    uint256 internal constant ETH_PER_TX = 0.001 ether;
    uint256 internal constant ETH_THRESHOLD = 0.0005 ether;
    uint256 internal constant ETH_DAILY = 0.002 ether;

    function setUp() public {
        vm.warp(1_700_000_000);

        usdc = new MockUSDC();
        vault = new AgentVault(owner);

        vm.startPrank(owner);
        vault.setAgent(agent);
        vault.setTokenPolicy(address(usdc), true, PER_TX, DAILY, THRESHOLD);
        vault.setTokenPolicy(address(0), true, ETH_PER_TX, ETH_DAILY, ETH_THRESHOLD);
        // `toggled` recipients start allowlisted; the owner may flip them during fuzzing.
        vault.setRecipient(friend, true);
        vault.setRecipient(bob, true);
        vault.setRecipient(carol, true);
        vm.stopPrank();

        usdc.mint(address(vault), 100e6);
        vm.deal(address(vault), 1 ether);

        address[] memory toggled = new address[](3);
        toggled[0] = friend;
        toggled[1] = bob;
        toggled[2] = carol;
        address[] memory never = new address[](2);
        never[0] = attacker;
        never[1] = mallory;

        handler = new AgentVaultHandler(
            vault, usdc, owner, agent, toggled, never, [PER_TX, DAILY, THRESHOLD, ETH_PER_TX, ETH_DAILY, ETH_THRESHOLD]
        );

        // Only fuzz the handler, and only its action functions.
        targetContract(address(handler));
        // Selector list doubles as a weighting: repeated entries are called more often. Direct
        // transfers, requests and approvals are weighted up so cap/window/approval logic is
        // exercised heavily; rarer owner and attacker actions still appear in every sequence.
        bytes4[] memory selectors = new bytes4[](20);
        selectors[0] = handler.agentTransferToken.selector;
        selectors[1] = handler.agentTransferToken.selector;
        selectors[2] = handler.agentTransferToken.selector;
        selectors[3] = handler.agentTransferEth.selector;
        selectors[4] = handler.agentTransferEth.selector;
        selectors[5] = handler.agentRequest.selector;
        selectors[6] = handler.agentRequest.selector;
        selectors[7] = handler.agentCancel.selector;
        selectors[8] = handler.ownerApprove.selector;
        selectors[9] = handler.ownerApprove.selector;
        selectors[10] = handler.ownerReject.selector;
        selectors[11] = handler.ownerSetRecipient.selector;
        selectors[12] = handler.ownerSetPaused.selector;
        selectors[13] = handler.ownerWithdraw.selector;
        selectors[14] = handler.fund.selector;
        selectors[15] = handler.fund.selector;
        selectors[16] = handler.agentAttemptsPrivileged.selector;
        selectors[17] = handler.strangerAttacks.selector;
        selectors[18] = handler.warp.selector;
        selectors[19] = handler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /*//////////////////////////////////////////////////////////////
                       1. RECIPIENT ALLOWLIST IS ABSOLUTE
    //////////////////////////////////////////////////////////////*/

    /// @notice No transfer (direct or approved) ever succeeded to an address that was not allowlisted
    ///         at that moment.
    function invariant_NeverSendsToNonAllowlistedRecipient() public view {
        assertEq(handler.violationNonAllowlisted(), 0, "sent to non-allowlisted recipient");
    }

    /// @notice End-to-end version: addresses the owner never allowlisted hold exactly nothing.
    function invariant_NeverAllowedAddressesHoldNoFunds() public view {
        assertEq(usdc.balanceOf(attacker), 0, "attacker got USDC");
        assertEq(usdc.balanceOf(mallory), 0, "mallory got USDC");
        assertEq(attacker.balance, 0, "attacker got ETH");
        assertEq(mallory.balance, 0, "mallory got ETH");
    }

    /*//////////////////////////////////////////////////////////////
                              2. CAPS ARE ABSOLUTE
    //////////////////////////////////////////////////////////////*/

    /// @notice Every successful direct transfer had 0 < amount <= approvalThreshold <= perTxCap.
    function invariant_DirectTransfersRespectPerTxRules() public view {
        assertEq(handler.violationRule(), 0, "direct transfer outside per-tx/threshold rules");
    }

    /// @notice Using an independent model of the 24h window, direct spend never exceeded dailyCap.
    function invariant_DailyCapNeverExceeded_IndependentModel() public view {
        assertEq(handler.violationCap(), 0, "independent window model saw spend above dailyCap");
    }

    /// @notice The other half of the exact oracle: whenever the documented rules say a direct transfer is
    ///         legal, the contract allowed it. Together with the invariants above this pins the
    ///         contract's behaviour to the rule table in BOTH directions (no over-permissive, no
    ///         over-restrictive behaviour, including correct window resets).
    function invariant_LegalTransfersAreNeverWronglyBlocked() public view {
        assertEq(handler.violationWronglyBlocked(), 0, "a rule-compliant transfer was refused");
    }

    /// @notice The contract's own spend counter never exceeds the cap either.
    function invariant_OnChainSpendCounterWithinCap() public view {
        assertLe(uint256(vault.getSpendWindow(address(usdc)).spent), DAILY, "USDC spent counter > dailyCap");
        assertLe(uint256(vault.getSpendWindow(address(0)).spent), ETH_DAILY, "ETH spent counter > dailyCap");
    }

    /// @notice `remainingDaily` never exceeds the cap and never underflows.
    function invariant_RemainingDailyIsSane() public view {
        assertLe(vault.remainingDaily(address(usdc)), DAILY);
        assertLe(vault.remainingDaily(address(0)), ETH_DAILY);
    }

    /// @notice Owner-approved requests never exceeded the hard per-tx ceiling (it can't be approved around).
    function invariant_ApprovedRequestsNeverExceedPerTxCap() public view {
        assertEq(handler.violationApprovedAboveCap(), 0, "approved request above perTxCap");
    }

    /// @notice Expired requests are never executed.
    function invariant_ExpiredRequestsNeverApproved() public view {
        assertEq(handler.violationExpiredApproved(), 0, "expired request was executed");
    }

    /*//////////////////////////////////////////////////////////////
                           3. KILL SWITCH IS ABSOLUTE
    //////////////////////////////////////////////////////////////*/

    /// @notice No agent action ever succeeded while the vault was paused.
    function invariant_NothingHappensWhilePaused() public view {
        assertEq(handler.violationWhilePaused(), 0, "agent action succeeded while paused");
    }

    /*//////////////////////////////////////////////////////////////
                         4. PRIVILEGE SEPARATION
    //////////////////////////////////////////////////////////////*/

    /// @notice A compromised agent (or any stranger) never succeeded at an owner-only function.
    function invariant_AgentAndStrangersHaveNoOwnerPowers() public view {
        assertEq(handler.violationPrivileged(), 0, "non-owner executed an owner function");
    }

    /// @notice Non-agents never moved funds.
    function invariant_OnlyAgentMovesFunds() public view {
        assertEq(handler.violationStranger(), 0, "non-agent moved funds");
    }

    /// @notice Owner, agent and policy are exactly what the owner configured (the handler never
    ///         legitimately changes them, so any drift means an attacker did).
    function invariant_RolesAndPolicyAreUntouched() public view {
        assertEq(vault.owner(), owner, "owner changed");
        assertEq(vault.pendingOwner(), address(0), "ownership transfer was initiated");
        assertEq(vault.agent(), agent, "agent changed");

        AgentVault.TokenPolicy memory p = vault.getPolicy(address(usdc));
        assertTrue(p.allowed);
        assertEq(p.perTxCap, PER_TX, "USDC perTxCap changed");
        assertEq(p.dailyCap, DAILY, "USDC dailyCap changed");
        assertEq(p.approvalThreshold, THRESHOLD, "USDC threshold changed");

        AgentVault.TokenPolicy memory e = vault.getPolicy(address(0));
        assertTrue(e.allowed);
        assertEq(e.perTxCap, ETH_PER_TX, "ETH perTxCap changed");
        assertEq(e.dailyCap, ETH_DAILY, "ETH dailyCap changed");
        assertEq(e.approvalThreshold, ETH_THRESHOLD, "ETH threshold changed");
    }

    /*//////////////////////////////////////////////////////////////
                         5. MONEY IS CONSERVED
    //////////////////////////////////////////////////////////////*/

    /// @notice vault balance == everything deposited - everything that left (direct + approved + withdrawn).
    function invariant_UsdcIsConserved() public view {
        address t = address(usdc);
        uint256 expected = handler.deposited(t) - handler.sentDirect(t) - handler.sentApproved(t) - handler.withdrawn(t);
        assertEq(usdc.balanceOf(address(vault)), expected, "USDC accounting drift");
    }

    function invariant_EthIsConserved() public view {
        address t = address(0);
        uint256 expected = handler.deposited(t) - handler.sentDirect(t) - handler.sentApproved(t) - handler.withdrawn(t);
        assertEq(address(vault).balance, expected, "ETH accounting drift");
    }

    /*//////////////////////////////////////////////////////////////
                      6. INTERNAL BOOKKEEPING STAYS CONSISTENT
    //////////////////////////////////////////////////////////////*/

    /// @notice `pendingCount` always equals the number of requests actually in Pending state, never
    ///         exceeds the spam limit, and `getPendingRequestIds` agrees.
    function invariant_PendingCountMatchesReality() public view {
        uint256 n = vault.requestCount();
        uint256 pending;
        uint256 approved;
        uint256 rejected;
        uint256 cancelled;
        for (uint256 i; i < n; ++i) {
            AgentVault.RequestStatus s = vault.getRequest(i).status;
            if (s == AgentVault.RequestStatus.Pending) pending++;
            else if (s == AgentVault.RequestStatus.Approved) approved++;
            else if (s == AgentVault.RequestStatus.Rejected) rejected++;
            else if (s == AgentVault.RequestStatus.Cancelled) cancelled++;
            else revert("request with status None exists");
        }
        assertEq(vault.pendingCount(), pending, "pendingCount drifted");
        assertLe(pending, vault.MAX_PENDING_REQUESTS(), "pending exceeds limit");
        assertEq(vault.getPendingRequestIds().length, pending, "getPendingRequestIds disagrees");
        assertEq(pending + approved + rejected + cancelled, n, "request lifecycle accounting");
    }

    /// @notice Every stored request obeys the validation applied at filing time.
    function invariant_StoredRequestsAreWellFormed() public view {
        uint256 n = vault.requestCount();
        for (uint256 i; i < n; ++i) {
            AgentVault.TransferRequest memory r = vault.getRequest(i);
            uint256 cap = r.token == address(0) ? ETH_PER_TX : PER_TX;
            assertGt(r.amount, 0, "zero-amount request");
            assertLe(r.amount, cap, "request above perTxCap");
            assertEq(r.requester, agent, "unexpected requester");
            assertLe(bytes(r.reason).length, vault.MAX_REASON_BYTES());
        }
    }

    /// @notice The vault never allowlists or pays itself/zero address.
    function invariant_VaultAndZeroAddressNeverAllowlisted() public view {
        assertFalse(vault.allowedRecipient(address(vault)));
        assertFalse(vault.allowedRecipient(address(0)));
    }

    /*//////////////////////////////////////////////////////////////
                                REPORTING
    //////////////////////////////////////////////////////////////*/

    /// @dev Prints what the fuzzer actually did, so a green run can be trusted as non-vacuous.
    ///      Run with `forge test --match-contract Invariant -vv` to see it.
    function afterInvariant() public view {
        console2.log("--- invariant run summary ---");
        console2.log("direct transfers ok      :", handler.okDirect());
        console2.log("direct transfers blocked :", handler.blockedDirect());
        console2.log("requests filed           :", handler.okRequests());
        console2.log("requests approved        :", handler.okApprovals());
        console2.log("requests rejected        :", handler.okRejects());
        console2.log("requests cancelled       :", handler.okCancels());
        console2.log("privileged attacks tried :", handler.privilegedAttempts());
        console2.log("pause toggles            :", handler.pausedToggles());
        console2.log("time warps               :", handler.warps());
    }
}
