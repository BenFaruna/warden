// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {AgentVault} from "../src/AgentVault.sol";
import {MockUSDC} from "./mocks/MockERC20.sol";
import {NoReturnToken} from "./mocks/NoReturnToken.sol";
import {HookToken} from "./mocks/HookToken.sol";
import {ReentrantAgent} from "./mocks/ReentrantAgent.sol";

/// @notice Behavioural tests for AgentVault.
/// @dev Layout: happy paths, policy rules, attack cases, kill switch, approval flow,
///      reentrancy, then fuzz tests. Every revert asserts the *specific* custom error and its
///      arguments, because the agent integration relies on those to self-correct.
contract AgentVaultTest is Test {
    AgentVault internal vault;
    MockUSDC internal usdc;

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");
    address internal friend = makeAddr("friend"); // allowlisted recipient
    address internal attacker = makeAddr("attacker"); // never allowlisted
    address internal stranger = makeAddr("stranger");

    // Demo policy: USDC has 6 decimals.
    uint256 internal constant PER_TX = 2e6; // 2 USDC
    uint256 internal constant THRESHOLD = 1e6; // 1 USDC
    uint256 internal constant DAILY = 5e6; // 5 USDC

    uint256 internal constant ETH_PER_TX = 0.001 ether;
    uint256 internal constant ETH_THRESHOLD = 0.0005 ether;
    uint256 internal constant ETH_DAILY = 0.002 ether;

    uint256 internal constant VAULT_USDC = 100e6;
    uint256 internal constant VAULT_ETH = 1 ether;

    // Mirror events for vm.expectEmit.
    event TransferExecuted(address indexed token, address indexed to, uint256 amount, bool viaApproval);
    event TransferRequested(
        uint256 indexed id, address indexed token, address indexed to, uint256 amount, string reason
    );
    event RequestApproved(uint256 indexed id);
    event RequestRejected(uint256 indexed id);
    event RequestCancelled(uint256 indexed id);
    event AgentSet(address indexed previousAgent, address indexed newAgent);
    event Paused(bool isPaused);
    event TokenPolicySet(
        address indexed token, bool allowed, uint256 perTxCap, uint256 dailyCap, uint256 approvalThreshold
    );
    event RecipientSet(address indexed recipient, bool allowed);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event Deposited(address indexed from, uint256 amount);

    function setUp() public {
        // Foundry's default timestamp is 1; use a realistic one so window maths is meaningful.
        vm.warp(1_700_000_000);

        usdc = new MockUSDC();
        vault = new AgentVault(owner);

        vm.startPrank(owner);
        vault.setAgent(agent);
        vault.setTokenPolicy(address(usdc), true, PER_TX, DAILY, THRESHOLD);
        vault.setTokenPolicy(address(0), true, ETH_PER_TX, ETH_DAILY, ETH_THRESHOLD);
        vault.setRecipient(friend, true);
        vm.stopPrank();

        usdc.mint(address(vault), VAULT_USDC);
        vm.deal(address(vault), VAULT_ETH);
    }

    /*//////////////////////////////////////////////////////////////
                         DEPLOYMENT / DEFAULTS
    //////////////////////////////////////////////////////////////*/

    function test_Deploy_IsInertByDefault() public {
        AgentVault fresh = new AgentVault(owner);
        assertEq(fresh.owner(), owner);
        assertEq(fresh.agent(), address(0));
        assertFalse(fresh.paused());
        assertEq(fresh.pendingCount(), 0);
        assertEq(fresh.requestCount(), 0);

        // Even a would-be agent can do nothing: no agent is configured.
        vm.prank(agent);
        vm.expectRevert(AgentVault.NotAgent.selector);
        fresh.transferToken(address(usdc), friend, 1);
    }

    function test_Deploy_ConstantsAreAsDocumented() public view {
        assertEq(vault.WINDOW(), 1 days);
        assertEq(vault.REQUEST_TTL(), 3 days);
        assertEq(vault.MAX_PENDING_REQUESTS(), 25);
        assertEq(vault.MAX_REASON_BYTES(), 280);
    }

    function test_Receive_AcceptsEthAndEmits() public {
        vm.deal(stranger, 1 ether);
        vm.expectEmit(true, false, false, true);
        emit Deposited(stranger, 0.1 ether);
        vm.prank(stranger);
        (bool ok,) = address(vault).call{value: 0.1 ether}("");
        assertTrue(ok);
        assertEq(vault.balanceOf(address(0)), VAULT_ETH + 0.1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        OWNER CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function test_SetAgent_RotatesAndEmits() public {
        address newAgent = makeAddr("newAgent");
        vm.expectEmit(true, true, false, false);
        emit AgentSet(agent, newAgent);
        vm.prank(owner);
        vault.setAgent(newAgent);
        assertEq(vault.agent(), newAgent);

        // Old agent is immediately powerless; new agent works.
        vm.prank(agent);
        vm.expectRevert(AgentVault.NotAgent.selector);
        vault.transferToken(address(usdc), friend, 1e6);

        vm.prank(newAgent);
        vault.transferToken(address(usdc), friend, 1e6);
        assertEq(usdc.balanceOf(friend), 1e6);
    }

    function test_SetAgent_ZeroDisablesAgent() public {
        vm.prank(owner);
        vault.setAgent(address(0));
        vm.prank(agent);
        vm.expectRevert(AgentVault.NotAgent.selector);
        vault.transferToken(address(usdc), friend, 1e6);
    }

    function test_SetAgent_CannotBeOwner() public {
        vm.prank(owner);
        vm.expectRevert(AgentVault.InvalidAgent.selector);
        vault.setAgent(owner);
    }

    function test_SetTokenPolicy_StoresAndEmits() public {
        address tok = makeAddr("tok");
        vm.expectEmit(true, false, false, true);
        emit TokenPolicySet(tok, true, 30, 40, 10);
        vm.prank(owner);
        vault.setTokenPolicy(tok, true, 30, 40, 10);

        AgentVault.TokenPolicy memory p = vault.getPolicy(tok);
        assertTrue(p.allowed);
        assertEq(p.perTxCap, 30);
        assertEq(p.dailyCap, 40);
        assertEq(p.approvalThreshold, 10);
    }

    function test_SetTokenPolicy_RevertsOnBadOrdering() public {
        vm.startPrank(owner);
        // threshold > perTx
        vm.expectRevert(AgentVault.InvalidPolicy.selector);
        vault.setTokenPolicy(address(usdc), true, 5, 10, 6);
        // perTx > daily
        vm.expectRevert(AgentVault.InvalidPolicy.selector);
        vault.setTokenPolicy(address(usdc), true, 11, 10, 5);
        // daily above uint192 max
        vm.expectRevert(AgentVault.InvalidPolicy.selector);
        vault.setTokenPolicy(address(usdc), true, 1, uint256(type(uint192).max) + 1, 1);
        vm.stopPrank();
    }

    function test_SetTokenPolicy_AcceptsBoundaryValues() public {
        vm.startPrank(owner);
        vault.setTokenPolicy(address(usdc), true, 5, 5, 5); // all equal
        vault.setTokenPolicy(address(usdc), true, 0, 0, 0); // all zero
        vault.setTokenPolicy(address(usdc), true, 1, type(uint192).max, 1); // max daily
        vm.stopPrank();
    }

    function test_SetRecipient_Validations() public {
        vm.startPrank(owner);
        vm.expectRevert(AgentVault.InvalidRecipient.selector);
        vault.setRecipient(address(0), true);
        vm.expectRevert(AgentVault.InvalidRecipient.selector);
        vault.setRecipient(address(vault), true);

        vm.expectEmit(true, false, false, true);
        emit RecipientSet(stranger, true);
        vault.setRecipient(stranger, true);
        assertTrue(vault.allowedRecipient(stranger));

        vault.setRecipient(stranger, false);
        assertFalse(vault.allowedRecipient(stranger));
        vm.stopPrank();
    }

    function test_Ownership_IsTwoStepAndCannotBeRenounced() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        vault.transferOwnership(newOwner);
        assertEq(vault.owner(), owner, "owner unchanged until accepted");
        assertEq(vault.pendingOwner(), newOwner);

        // Wrong account cannot accept.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.acceptOwnership();

        vm.prank(newOwner);
        vault.acceptOwnership();
        assertEq(vault.owner(), newOwner);

        // Renounce would brick the vault; it is disabled.
        vm.prank(newOwner);
        vm.expectRevert(AgentVault.RenounceDisabled.selector);
        vault.renounceOwnership();
    }

    /*//////////////////////////////////////////////////////////////
                           HAPPY PATHS
    //////////////////////////////////////////////////////////////*/

    function test_TransferToken_WithinPolicy() public {
        vm.expectEmit(true, true, false, true);
        emit TransferExecuted(address(usdc), friend, 1e6, false);
        vm.prank(agent);
        vault.transferToken(address(usdc), friend, 1e6);

        assertEq(usdc.balanceOf(friend), 1e6);
        assertEq(usdc.balanceOf(address(vault)), VAULT_USDC - 1e6);
        assertEq(vault.remainingDaily(address(usdc)), DAILY - 1e6);
        assertEq(vault.getSpendWindow(address(usdc)).spent, 1e6);
        assertEq(vault.getSpendWindow(address(usdc)).start, block.timestamp);
    }

    function test_TransferETH_WithinPolicy() public {
        vm.expectEmit(true, true, false, true);
        emit TransferExecuted(address(0), friend, ETH_THRESHOLD, false);
        vm.prank(agent);
        vault.transferETH(friend, ETH_THRESHOLD);

        assertEq(friend.balance, ETH_THRESHOLD);
        assertEq(vault.balanceOf(address(0)), VAULT_ETH - ETH_THRESHOLD);
        assertEq(vault.remainingDaily(address(0)), ETH_DAILY - ETH_THRESHOLD);
    }

    function test_TransferToken_ExactlyAtThresholdIsAllowed() public {
        vm.prank(agent);
        vault.transferToken(address(usdc), friend, THRESHOLD); // boundary is inclusive
        assertEq(usdc.balanceOf(friend), THRESHOLD);
    }

    function test_TransferToken_WorksWithNoReturnTokens() public {
        NoReturnToken usdt = new NoReturnToken();
        usdt.mint(address(vault), 10e6);
        vm.startPrank(owner);
        vault.setTokenPolicy(address(usdt), true, PER_TX, DAILY, THRESHOLD);
        vm.stopPrank();

        vm.prank(agent);
        vault.transferToken(address(usdt), friend, 1e6); // SafeERC20 must tolerate empty return data
        assertEq(usdt.balanceOf(friend), 1e6);
    }

    function test_DailyCap_CanBeFilledExactly_ThenBlocks() public {
        vm.startPrank(agent);
        for (uint256 i; i < 5; ++i) {
            vault.transferToken(address(usdc), friend, 1e6);
        }
        assertEq(vault.remainingDaily(address(usdc)), 0);

        vm.expectRevert(abi.encodeWithSelector(AgentVault.ExceedsDailyCap.selector, 1, 0));
        vault.transferToken(address(usdc), friend, 1);
        vm.stopPrank();
        assertEq(usdc.balanceOf(friend), DAILY);
    }

    function test_DailyCap_WindowResetsAfter24h() public {
        vm.startPrank(agent);
        for (uint256 i; i < 5; ++i) {
            vault.transferToken(address(usdc), friend, 1e6);
        }
        uint256 start = vault.getSpendWindow(address(usdc)).start;

        // One second before expiry: still blocked.
        vm.warp(start + 1 days - 1);
        assertEq(vault.remainingDaily(address(usdc)), 0);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.ExceedsDailyCap.selector, 1e6, 0));
        vault.transferToken(address(usdc), friend, 1e6);

        // At expiry the view already reports a full budget, and spending works.
        vm.warp(start + 1 days);
        assertEq(vault.remainingDaily(address(usdc)), DAILY);
        vault.transferToken(address(usdc), friend, 1e6);
        vm.stopPrank();

        assertEq(vault.getSpendWindow(address(usdc)).start, start + 1 days, "new window starts now");
        assertEq(vault.getSpendWindow(address(usdc)).spent, 1e6);
    }

    /// @dev DOCUMENTS A KNOWN LIMITATION (see contract natspec): fixed windows allow a burst
    ///      straddling the boundary of up to ~2x dailyCap. This test pins that behaviour so a
    ///      future change to sliding windows is a deliberate, visible decision.
    function test_DailyCap_FixedWindowBoundaryBurst_IsPossible() public {
        vm.startPrank(agent);
        vault.transferToken(address(usdc), friend, 1e6); // opens the window at T
        uint256 start = block.timestamp;

        vm.warp(start + 1 days - 1); // last second of the window
        for (uint256 i; i < 4; ++i) {
            vault.transferToken(address(usdc), friend, 1e6); // fills it to DAILY
        }
        vm.warp(start + 1 days); // one second later: fresh window
        for (uint256 i; i < 5; ++i) {
            vault.transferToken(address(usdc), friend, 1e6);
        }
        vm.stopPrank();

        // 9 USDC moved within ~1 second while dailyCap is 5 USDC.
        assertEq(usdc.balanceOf(friend), 10e6);
    }

    function test_DailyCap_IsTrackedPerToken() public {
        vm.startPrank(agent);
        for (uint256 i; i < 5; ++i) {
            vault.transferToken(address(usdc), friend, 1e6);
        }
        // USDC budget exhausted, but ETH budget is separate and untouched.
        vault.transferETH(friend, ETH_THRESHOLD);
        vm.stopPrank();
        assertEq(vault.remainingDaily(address(usdc)), 0);
        assertEq(vault.remainingDaily(address(0)), ETH_DAILY - ETH_THRESHOLD);
    }

    function test_RemainingDaily_IsFullBeforeAnySpend() public view {
        assertEq(vault.remainingDaily(address(usdc)), DAILY);
    }

    /*//////////////////////////////////////////////////////////////
                 POLICY RULES (each must revert precisely)
    //////////////////////////////////////////////////////////////*/

    function test_Revert_RecipientNotAllowed() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.RecipientNotAllowed.selector, attacker));
        vault.transferToken(address(usdc), attacker, 1e6);
        assertEq(usdc.balanceOf(attacker), 0);
    }

    function test_Revert_RecipientNotAllowed_ETH() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.RecipientNotAllowed.selector, attacker));
        vault.transferETH(attacker, 1);
    }

    function test_Revert_TokenNotAllowed_Unknown() public {
        MockUSDC other = new MockUSDC();
        other.mint(address(vault), 10e6);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.TokenNotAllowed.selector, address(other)));
        vault.transferToken(address(other), friend, 1e6);
    }

    function test_Revert_TokenNotAllowed_Disabled() public {
        vm.prank(owner);
        vault.setTokenPolicy(address(usdc), false, PER_TX, DAILY, THRESHOLD);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.TokenNotAllowed.selector, address(usdc)));
        vault.transferToken(address(usdc), friend, 1e6);
    }

    function test_Revert_TransferToken_WithZeroAddressTokenMustUseTransferETH() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.TokenNotAllowed.selector, address(0)));
        vault.transferToken(address(0), friend, 1);
    }

    function test_Revert_InvalidRecipient() public {
        vm.startPrank(agent);
        vm.expectRevert(AgentVault.InvalidRecipient.selector);
        vault.transferToken(address(usdc), address(0), 1e6);
        vm.expectRevert(AgentVault.InvalidRecipient.selector);
        vault.transferToken(address(usdc), address(vault), 1e6);
        vm.expectRevert(AgentVault.InvalidRecipient.selector);
        vault.transferETH(address(0), 1);
        vm.stopPrank();
    }

    function test_Revert_ZeroAmount() public {
        vm.startPrank(agent);
        vm.expectRevert(AgentVault.ZeroAmount.selector);
        vault.transferToken(address(usdc), friend, 0);
        vm.expectRevert(AgentVault.ZeroAmount.selector);
        vault.transferETH(friend, 0);
        vm.stopPrank();
    }

    function test_Revert_ExceedsPerTxCap() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.ExceedsPerTxCap.selector, PER_TX + 1, PER_TX));
        vault.transferToken(address(usdc), friend, PER_TX + 1);
    }

    function test_Revert_HugeAmount_TheDrainAttempt() public {
        // "Send everything" is exactly what a prompt-injected agent would try.
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.ExceedsPerTxCap.selector, VAULT_USDC, PER_TX));
        vault.transferToken(address(usdc), friend, VAULT_USDC);
        assertEq(usdc.balanceOf(address(vault)), VAULT_USDC);
    }

    function test_Revert_NeedsApproval_AboveThresholdWithinPerTx() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.NeedsApproval.selector, THRESHOLD + 1, THRESHOLD));
        vault.transferToken(address(usdc), friend, THRESHOLD + 1);

        // Exactly PER_TX is still "needs approval", not "exceeds cap".
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.NeedsApproval.selector, PER_TX, THRESHOLD));
        vault.transferToken(address(usdc), friend, PER_TX);
    }

    function test_Revert_PerTxCapIsCheckedBeforeApproval() public {
        // Above perTxCap the agent is told "exceeds cap" (hard no), not "needs approval" (maybe).
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.ExceedsPerTxCap.selector, PER_TX + 1, PER_TX));
        vault.transferToken(address(usdc), friend, PER_TX + 1);
    }

    function test_Revert_ExceedsDailyCap_AcrossManySmallTransfers() public {
        // Salami-slicing: each transfer is individually legal.
        vm.startPrank(agent);
        vault.transferToken(address(usdc), friend, 1e6);
        vault.transferToken(address(usdc), friend, 1e6);
        vault.transferToken(address(usdc), friend, 1e6);
        vault.transferToken(address(usdc), friend, 1e6);
        vault.transferToken(address(usdc), friend, 0.5e6); // 4.5 spent
        vm.expectRevert(abi.encodeWithSelector(AgentVault.ExceedsDailyCap.selector, 1e6, 0.5e6));
        vault.transferToken(address(usdc), friend, 1e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(friend), 4.5e6);
    }

    function test_Revert_ExceedsDailyCap_ETH() public {
        vm.startPrank(agent);
        vault.transferETH(friend, ETH_THRESHOLD);
        vault.transferETH(friend, ETH_THRESHOLD);
        vault.transferETH(friend, ETH_THRESHOLD);
        vault.transferETH(friend, ETH_THRESHOLD); // 0.002 = DAILY
        vm.expectRevert(abi.encodeWithSelector(AgentVault.ExceedsDailyCap.selector, 1, 0));
        vault.transferETH(friend, 1);
        vm.stopPrank();
    }

    function test_PolicyChanges_TakeEffectImmediately() public {
        vm.prank(owner);
        vault.setRecipient(friend, false);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.RecipientNotAllowed.selector, friend));
        vault.transferToken(address(usdc), friend, 1e6);

        vm.prank(owner);
        vault.setRecipient(friend, true);
        vm.prank(agent);
        vault.transferToken(address(usdc), friend, 1e6); // allowed again
    }

    function test_LoweringDailyCapBelowSpent_BlocksUntilWindowResets() public {
        vm.prank(agent);
        vault.transferToken(address(usdc), friend, 1e6);
        vm.prank(agent);
        vault.transferToken(address(usdc), friend, 1e6); // 2 spent

        // Owner tightens to 1 USDC/day: spent (2) now exceeds cap (1).
        vm.prank(owner);
        vault.setTokenPolicy(address(usdc), true, 1e6, 1e6, 1e6);
        assertEq(vault.remainingDaily(address(usdc)), 0, "no underflow: remaining clamps at 0");

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.ExceedsDailyCap.selector, 1, 0));
        vault.transferToken(address(usdc), friend, 1);

        vm.warp(block.timestamp + 1 days);
        vm.prank(agent);
        vault.transferToken(address(usdc), friend, 1e6); // new window, works
    }

    function test_FailedTransfer_DoesNotConsumeBudget() public {
        // Drain the vault's USDC so the underlying transfer fails.
        vm.prank(owner);
        vault.withdraw(address(usdc), owner, VAULT_USDC);

        uint256 before = vault.remainingDaily(address(usdc));
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(vault), 0, 1e6)
        );
        vault.transferToken(address(usdc), friend, 1e6);

        // The whole tx reverted, so the spend counter was rolled back too.
        assertEq(vault.remainingDaily(address(usdc)), before);
        assertEq(vault.getSpendWindow(address(usdc)).spent, 0);
    }

    function test_Revert_EthTransferFailed_WhenRecipientRejectsEth() public {
        // usdc contract has no receive(), so it rejects ETH.
        vm.prank(owner);
        vault.setRecipient(address(usdc), true);
        vm.prank(agent);
        vm.expectRevert(AgentVault.EthTransferFailed.selector);
        vault.transferETH(address(usdc), 1);
        assertEq(vault.getSpendWindow(address(0)).spent, 0);
    }

    function test_Revert_EthTransferFailed_WhenVaultHasInsufficientEth() public {
        vm.prank(owner);
        vault.withdraw(address(0), owner, VAULT_ETH);
        vm.prank(agent);
        vm.expectRevert(AgentVault.EthTransferFailed.selector);
        vault.transferETH(friend, 1);
    }

    /*//////////////////////////////////////////////////////////////
                         ACCESS CONTROL / ATTACKS
    //////////////////////////////////////////////////////////////*/

    function test_Revert_NonAgentCannotUseAgentFunctions() public {
        address[3] memory callers = [stranger, attacker, owner];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert(AgentVault.NotAgent.selector);
            vault.transferToken(address(usdc), friend, 1e6);
            vm.expectRevert(AgentVault.NotAgent.selector);
            vault.transferETH(friend, 1);
            vm.expectRevert(AgentVault.NotAgent.selector);
            vault.requestTransfer(address(usdc), friend, 1e6, "x");
            vm.expectRevert(AgentVault.NotAgent.selector);
            vault.cancelRequest(0);
            vm.stopPrank();
        }
    }

    /// @dev The core security claim: a fully compromised agent key cannot change ANY owner-level state.
    function test_Revert_AgentCannotCallAnyOwnerFunction() public {
        // Create a pending request so approve/reject have something real to target.
        vm.prank(agent);
        uint256 id = vault.requestTransfer(address(usdc), friend, 1.5e6, "need more");

        bytes memory notOwner = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, agent);
        vm.startPrank(agent);

        vm.expectRevert(notOwner);
        vault.setAgent(attacker);
        vm.expectRevert(notOwner);
        vault.setPaused(true);
        vm.expectRevert(notOwner);
        vault.setTokenPolicy(address(usdc), true, type(uint128).max, type(uint128).max, type(uint128).max);
        vm.expectRevert(notOwner);
        vault.setRecipient(attacker, true);
        vm.expectRevert(notOwner);
        vault.withdraw(address(usdc), attacker, VAULT_USDC);
        vm.expectRevert(notOwner);
        vault.approveRequest(id);
        vm.expectRevert(notOwner);
        vault.rejectRequest(id);
        vm.expectRevert(notOwner);
        vault.transferOwnership(agent);
        vm.expectRevert(notOwner);
        vault.renounceOwnership();

        // acceptOwnership requires being the *pending owner*; the agent isn't.
        vm.expectRevert(notOwner);
        vault.acceptOwnership();
        vm.stopPrank();

        // Nothing changed.
        assertEq(vault.agent(), agent);
        assertFalse(vault.paused());
        assertFalse(vault.allowedRecipient(attacker));
        assertEq(vault.getPolicy(address(usdc)).perTxCap, PER_TX);
        assertEq(usdc.balanceOf(address(vault)), VAULT_USDC);
    }

    function test_Revert_StrangerCannotCallOwnerFunctions() public {
        bytes memory notOwner = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger);
        vm.startPrank(stranger);
        vm.expectRevert(notOwner);
        vault.setAgent(stranger);
        vm.expectRevert(notOwner);
        vault.setPaused(true);
        vm.expectRevert(notOwner);
        vault.withdraw(address(0), stranger, 1);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              KILL SWITCH
    //////////////////////////////////////////////////////////////*/

    function test_Pause_FreezesEveryAgentFunction() public {
        vm.prank(agent);
        uint256 id = vault.requestTransfer(address(usdc), friend, 1.5e6, "pending before pause");

        vm.expectEmit(false, false, false, true);
        emit Paused(true);
        vm.prank(owner);
        vault.setPaused(true);
        assertTrue(vault.paused());

        vm.startPrank(agent);
        vm.expectRevert(AgentVault.VaultPaused.selector);
        vault.transferToken(address(usdc), friend, 1);
        vm.expectRevert(AgentVault.VaultPaused.selector);
        vault.transferETH(friend, 1);
        vm.expectRevert(AgentVault.VaultPaused.selector);
        vault.requestTransfer(address(usdc), friend, 1, "x");
        vm.expectRevert(AgentVault.VaultPaused.selector);
        vault.cancelRequest(id);
        vm.stopPrank();
    }

    function test_Pause_OwnerFunctionsKeepWorking() public {
        vm.prank(agent);
        uint256 id = vault.requestTransfer(address(usdc), friend, 1.5e6, "approve me during incident");

        vm.startPrank(owner);
        vault.setPaused(true);

        // Policy edits, approvals and withdrawals all still work while paused.
        vault.setRecipient(stranger, true);
        vault.approveRequest(id);
        vault.withdraw(address(usdc), owner, 10e6);
        vm.stopPrank();

        assertEq(usdc.balanceOf(friend), 1.5e6);
        assertEq(usdc.balanceOf(owner), 10e6);
    }

    function test_Unpause_RestoresAgent() public {
        vm.startPrank(owner);
        vault.setPaused(true);
        vault.setPaused(false);
        vm.stopPrank();

        vm.prank(agent);
        vault.transferToken(address(usdc), friend, 1e6);
        assertEq(usdc.balanceOf(friend), 1e6);
    }

    /*//////////////////////////////////////////////////////////////
                          OWNER WITHDRAWALS
    //////////////////////////////////////////////////////////////*/

    function test_Withdraw_OwnerCanMoveFundsRegardlessOfPolicy() public {
        vm.expectEmit(true, true, false, true);
        emit Withdrawn(address(usdc), stranger, VAULT_USDC);
        vm.prank(owner);
        vault.withdraw(address(usdc), stranger, VAULT_USDC); // far above perTxCap, not allowlisted
        assertEq(usdc.balanceOf(stranger), VAULT_USDC);

        vm.prank(owner);
        vault.withdraw(address(0), stranger, VAULT_ETH);
        assertEq(stranger.balance, VAULT_ETH);
    }

    function test_Withdraw_Validations() public {
        vm.startPrank(owner);
        vm.expectRevert(AgentVault.InvalidRecipient.selector);
        vault.withdraw(address(usdc), address(0), 1);
        vm.expectRevert(AgentVault.ZeroAmount.selector);
        vault.withdraw(address(usdc), owner, 0);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            APPROVAL REQUESTS
    //////////////////////////////////////////////////////////////*/

    function _request(uint256 amount) internal returns (uint256 id) {
        vm.prank(agent);
        id = vault.requestTransfer(address(usdc), friend, amount, "invoice #42");
    }

    function test_Request_StoresAllFieldsAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit TransferRequested(0, address(usdc), friend, 1.5e6, "invoice #42");
        uint256 id = _request(1.5e6);

        assertEq(id, 0);
        assertEq(vault.pendingCount(), 1);
        assertEq(vault.requestCount(), 1);

        AgentVault.TransferRequest memory r = vault.getRequest(id);
        assertEq(r.token, address(usdc));
        assertEq(r.to, friend);
        assertEq(r.amount, 1.5e6);
        assertEq(r.requester, agent);
        assertEq(r.createdAt, block.timestamp);
        assertEq(uint8(r.status), uint8(AgentVault.RequestStatus.Pending));
        assertEq(r.reason, "invoice #42");
        // Nothing moved yet.
        assertEq(usdc.balanceOf(friend), 0);
    }

    function test_Request_AtPerTxCapIsAllowed() public {
        uint256 id = _request(PER_TX);
        assertEq(vault.getRequest(id).amount, PER_TX);
    }

    function test_Request_Validations() public {
        vm.startPrank(agent);

        vm.expectRevert(abi.encodeWithSelector(AgentVault.RecipientNotAllowed.selector, attacker));
        vault.requestTransfer(address(usdc), attacker, 1.5e6, "x");

        vm.expectRevert(abi.encodeWithSelector(AgentVault.TokenNotAllowed.selector, makeAddr("nope")));
        vault.requestTransfer(makeAddr("nope"), friend, 1.5e6, "x");

        vm.expectRevert(AgentVault.ZeroAmount.selector);
        vault.requestTransfer(address(usdc), friend, 0, "x");

        // The hard ceiling cannot be approved around.
        vm.expectRevert(abi.encodeWithSelector(AgentVault.ExceedsPerTxCap.selector, PER_TX + 1, PER_TX));
        vault.requestTransfer(address(usdc), friend, PER_TX + 1, "x");
        vm.stopPrank();

        assertEq(vault.pendingCount(), 0);
    }

    function test_Request_ReasonLengthLimit() public {
        bytes memory ok = new bytes(280);
        bytes memory tooLong = new bytes(281);
        for (uint256 i; i < ok.length; ++i) {
            ok[i] = "a";
        }
        for (uint256 i; i < tooLong.length; ++i) {
            tooLong[i] = "a";
        }

        vm.startPrank(agent);
        vault.requestTransfer(address(usdc), friend, 1.5e6, string(ok)); // exactly 280 bytes: fine
        vm.expectRevert(AgentVault.ReasonTooLong.selector);
        vault.requestTransfer(address(usdc), friend, 1.5e6, string(tooLong));
        vm.stopPrank();
    }

    function test_Request_PendingLimit_BlocksSpam() public {
        vm.startPrank(agent);
        for (uint256 i; i < 25; ++i) {
            vault.requestTransfer(address(usdc), friend, 1.5e6, "spam");
        }
        vm.expectRevert(AgentVault.TooManyPendingRequests.selector);
        vault.requestTransfer(address(usdc), friend, 1.5e6, "spam");
        vm.stopPrank();

        // Resolving one frees a slot.
        vm.prank(owner);
        vault.rejectRequest(0);
        vm.prank(agent);
        vault.requestTransfer(address(usdc), friend, 1.5e6, "now there is room");
        assertEq(vault.pendingCount(), 25);
    }

    function test_Approve_ExecutesTransferAndUpdatesState() public {
        uint256 id = _request(1.5e6);

        vm.expectEmit(true, false, false, false);
        emit RequestApproved(id);
        vm.expectEmit(true, true, false, true);
        emit TransferExecuted(address(usdc), friend, 1.5e6, true);
        vm.prank(owner);
        vault.approveRequest(id);

        assertEq(usdc.balanceOf(friend), 1.5e6);
        assertEq(vault.pendingCount(), 0);
        assertEq(uint8(vault.getRequest(id).status), uint8(AgentVault.RequestStatus.Approved));
    }

    function test_Approve_DoesNotConsumeDailyCap() public {
        uint256 id = _request(PER_TX);
        vm.prank(owner);
        vault.approveRequest(id);
        assertEq(vault.remainingDaily(address(usdc)), DAILY, "approved spend is outside the agent's budget");
    }

    function test_Approve_Eth() public {
        vm.prank(agent);
        uint256 id = vault.requestTransfer(address(0), friend, ETH_PER_TX, "gas refill");
        vm.prank(owner);
        vault.approveRequest(id);
        assertEq(friend.balance, ETH_PER_TX);
    }

    function test_Approve_CannotBeExecutedTwice() public {
        uint256 id = _request(1.5e6);
        vm.startPrank(owner);
        vault.approveRequest(id);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.RequestNotPending.selector, id));
        vault.approveRequest(id);
        vm.stopPrank();
        assertEq(usdc.balanceOf(friend), 1.5e6, "paid exactly once");
    }

    function test_Approve_UnknownIdReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.RequestNotFound.selector, 7));
        vault.approveRequest(7);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.RequestNotFound.selector, 7));
        vault.getRequest(7);
    }

    function test_Approve_ExpiryBoundary() public {
        uint256 id = _request(1.5e6);
        uint256 created = block.timestamp;

        // Exactly at createdAt + TTL: still approvable (strictly-greater check).
        vm.warp(created + 3 days);
        vm.prank(owner);
        vault.approveRequest(id);
        assertEq(usdc.balanceOf(friend), 1.5e6);
    }

    function test_Approve_RevertsWhenExpired_ButCanStillBeRejected() public {
        uint256 id = _request(1.5e6);
        vm.warp(block.timestamp + 3 days + 1);

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.RequestExpired.selector, id));
        vault.approveRequest(id);

        vault.rejectRequest(id); // cleanup is always possible
        vm.stopPrank();
        assertEq(vault.pendingCount(), 0);
    }

    function test_Approve_RevertsIfRecipientWasDelistedMeanwhile() public {
        uint256 id = _request(1.5e6);
        vm.startPrank(owner);
        vault.setRecipient(friend, false);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.RecipientNotAllowed.selector, friend));
        vault.approveRequest(id);
        vm.stopPrank();

        // The failed approval left the request intact and still pending.
        assertEq(uint8(vault.getRequest(id).status), uint8(AgentVault.RequestStatus.Pending));
        assertEq(vault.pendingCount(), 1);
    }

    function test_Approve_RevertsIfTokenWasDisabledMeanwhile() public {
        uint256 id = _request(1.5e6);
        vm.startPrank(owner);
        vault.setTokenPolicy(address(usdc), false, PER_TX, DAILY, THRESHOLD);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.TokenNotAllowed.selector, address(usdc)));
        vault.approveRequest(id);
        vm.stopPrank();
    }

    function test_Approve_IsAtomicWhenVaultIsUnderfunded() public {
        uint256 id = _request(1.5e6);
        vm.startPrank(owner);
        vault.withdraw(address(usdc), owner, VAULT_USDC);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(vault), 0, 1.5e6)
        );
        vault.approveRequest(id);
        vm.stopPrank();

        // Status and counter were rolled back with the revert; owner can retry after refunding.
        assertEq(uint8(vault.getRequest(id).status), uint8(AgentVault.RequestStatus.Pending));
        assertEq(vault.pendingCount(), 1);

        usdc.mint(address(vault), 2e6);
        vm.prank(owner);
        vault.approveRequest(id);
        assertEq(usdc.balanceOf(friend), 1.5e6);
    }

    function test_Reject_MarksRejectedAndMovesNothing() public {
        uint256 id = _request(1.5e6);
        vm.expectEmit(true, false, false, false);
        emit RequestRejected(id);
        vm.prank(owner);
        vault.rejectRequest(id);

        assertEq(uint8(vault.getRequest(id).status), uint8(AgentVault.RequestStatus.Rejected));
        assertEq(vault.pendingCount(), 0);
        assertEq(usdc.balanceOf(friend), 0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.RequestNotPending.selector, id));
        vault.approveRequest(id);
    }

    function test_Cancel_AgentCanWithdrawOwnRequest() public {
        uint256 id = _request(1.5e6);
        vm.expectEmit(true, false, false, false);
        emit RequestCancelled(id);
        vm.prank(agent);
        vault.cancelRequest(id);

        assertEq(uint8(vault.getRequest(id).status), uint8(AgentVault.RequestStatus.Cancelled));
        assertEq(vault.pendingCount(), 0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.RequestNotPending.selector, id));
        vault.approveRequest(id);
    }

    function test_Cancel_OnlyTheRequesterMayCancel() public {
        uint256 id = _request(1.5e6);
        address newAgent = makeAddr("newAgent");
        vm.prank(owner);
        vault.setAgent(newAgent);

        vm.prank(newAgent);
        vm.expectRevert(AgentVault.NotRequester.selector);
        vault.cancelRequest(id);

        // Owner cleans up the old agent's request instead.
        vm.prank(owner);
        vault.rejectRequest(id);
    }

    function test_Cancel_CannotCancelResolvedRequests() public {
        uint256 id = _request(1.5e6);
        vm.prank(owner);
        vault.approveRequest(id);

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.RequestNotPending.selector, id));
        vault.cancelRequest(id);
    }

    function test_GetPendingRequestIds_OnlyReturnsPending() public {
        uint256 a = _request(1.5e6); // 0 -> approve
        uint256 b = _request(1.5e6); // 1 -> stays pending
        uint256 c = _request(1.5e6); // 2 -> reject
        uint256 d = _request(1.5e6); // 3 -> cancel
        uint256 e = _request(1.5e6); // 4 -> stays pending

        vm.startPrank(owner);
        vault.approveRequest(a);
        vault.rejectRequest(c);
        vm.stopPrank();
        vm.prank(agent);
        vault.cancelRequest(d);

        uint256[] memory ids = vault.getPendingRequestIds();
        assertEq(ids.length, 2);
        assertEq(ids[0], b);
        assertEq(ids[1], e);
        assertEq(vault.pendingCount(), 2);
    }

    /*//////////////////////////////////////////////////////////////
                              REENTRANCY
    //////////////////////////////////////////////////////////////*/

    function test_Reentrancy_EthRecipientCannotReenter() public {
        ReentrantAgent evil = new ReentrantAgent(vault);
        vm.startPrank(owner);
        vault.setAgent(address(evil));
        vault.setRecipient(address(evil), true);
        vm.stopPrank();

        // Each transfer is individually legal; the attack is the nested second call.
        vm.expectRevert(AgentVault.EthTransferFailed.selector);
        evil.attackEth(ETH_THRESHOLD, ETH_THRESHOLD);

        assertEq(address(evil).balance, 0);
        assertEq(vault.balanceOf(address(0)), VAULT_ETH, "nothing left the vault");
        assertEq(vault.getSpendWindow(address(0)).spent, 0, "budget not consumed by the failed attack");
    }

    function test_Reentrancy_TokenHookCannotReenter() public {
        HookToken hook = new HookToken();
        hook.mint(address(vault), 10e6);
        ReentrantAgent evil = new ReentrantAgent(vault);
        vm.startPrank(owner);
        vault.setAgent(address(evil));
        vault.setRecipient(address(evil), true);
        vault.setTokenPolicy(address(hook), true, PER_TX, DAILY, THRESHOLD);
        vm.stopPrank();

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        evil.attackToken(address(hook), THRESHOLD, THRESHOLD);

        assertEq(hook.balanceOf(address(evil)), 0);
        assertEq(hook.balanceOf(address(vault)), 10e6);
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev A single direct transfer succeeds iff it satisfies every rule, and fails with the
    ///      right error otherwise. This is a full oracle of the rule table for one transfer.
    function testFuzz_DirectTransfer_MatchesRuleTable(uint256 amount) public {
        amount = bound(amount, 0, 10e6);
        vm.prank(agent);
        if (amount == 0) {
            vm.expectRevert(AgentVault.ZeroAmount.selector);
        } else if (amount > PER_TX) {
            vm.expectRevert(abi.encodeWithSelector(AgentVault.ExceedsPerTxCap.selector, amount, PER_TX));
        } else if (amount > THRESHOLD) {
            vm.expectRevert(abi.encodeWithSelector(AgentVault.NeedsApproval.selector, amount, THRESHOLD));
        }
        vault.transferToken(address(usdc), friend, amount);

        bool shouldSucceed = amount > 0 && amount <= THRESHOLD;
        assertEq(usdc.balanceOf(friend), shouldSucceed ? amount : 0);
    }

    /// @dev However the agent slices its transfers, one window can never release more than dailyCap.
    function testFuzz_WindowTotal_NeverExceedsDailyCap(uint256[12] memory amounts) public {
        uint256 total;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 amt = bound(amounts[i], 1, THRESHOLD);
            vm.prank(agent);
            try vault.transferToken(address(usdc), friend, amt) {
                total += amt;
            } catch {}
        }
        assertLe(total, DAILY);
        assertEq(usdc.balanceOf(friend), total);
    }

    /// @dev Policy validation is exactly the documented ordering, nothing more or less.
    function testFuzz_SetPolicy_OrderingIsEnforced(uint256 perTx, uint256 daily, uint256 threshold) public {
        vm.prank(owner);
        bool valid = threshold <= perTx && perTx <= daily && daily <= type(uint192).max;
        if (!valid) vm.expectRevert(AgentVault.InvalidPolicy.selector);
        vault.setTokenPolicy(address(usdc), true, perTx, daily, threshold);

        if (valid) {
            AgentVault.TokenPolicy memory p = vault.getPolicy(address(usdc));
            assertEq(p.perTxCap, perTx);
            assertEq(p.dailyCap, daily);
            assertEq(p.approvalThreshold, threshold);
        }
    }

    /// @dev Nobody but the agent can ever move funds, for any caller address.
    function testFuzz_OnlyAgentCanTransfer(address caller, uint256 amount) public {
        vm.assume(caller != agent);
        amount = bound(amount, 1, THRESHOLD);
        vm.prank(caller);
        vm.expectRevert(AgentVault.NotAgent.selector);
        vault.transferToken(address(usdc), friend, amount);
    }

    /// @dev Money only ever reaches allowlisted addresses, for any destination.
    function testFuzz_OnlyAllowlistedRecipientsReceive(address to, uint256 amount) public {
        vm.assume(to != friend && to != address(0) && to != address(vault));
        amount = bound(amount, 1, THRESHOLD);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AgentVault.RecipientNotAllowed.selector, to));
        vault.transferToken(address(usdc), to, amount);
    }

    /// @dev Reason strings: accepted iff <= 280 bytes.
    function testFuzz_RequestReasonLength(uint16 len) public {
        len = uint16(bound(len, 0, 600));
        bytes memory reason = new bytes(len);
        vm.prank(agent);
        if (len > 280) vm.expectRevert(AgentVault.ReasonTooLong.selector);
        vault.requestTransfer(address(usdc), friend, 1.5e6, string(reason));
    }
}
