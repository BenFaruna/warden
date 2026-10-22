// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AgentVault} from "../../src/AgentVault.sol";
import {MockUSDC} from "../mocks/MockERC20.sol";

/// @notice Fuzz "driver" for the AgentVault invariant tests.
///
/// @dev Foundry's invariant runner calls the public functions of this contract in random order with
///      random arguments. Each action impersonates the agent, the owner, or an attacker, and records
///      GHOST VARIABLES: an independent bookkeeping of what *should* be true. The invariant tests then
///      compare those ghosts against the real contract state.
///
///      Design choices:
///      - The token policy is deliberately FIXED during fuzzing so the handler can re-derive the
///        expected window/cap behaviour independently (a second implementation of the rules is a
///        much stronger oracle than re-reading the contract's own counters). Policy-change behaviour
///        is covered by the unit tests.
///      - Two address groups: `toggled` recipients that the owner flips on/off during the run, and
///        `neverAllowed` addresses the handler never allowlists. Any funds reaching the latter group
///        is an immediate invariant failure.
///      - Every external call is wrapped in try/catch: a revert is a *legitimate outcome* here
///        (the contract refusing), so the handler itself never reverts.
contract AgentVaultHandler is Test {
    AgentVault public immutable VAULT;
    MockUSDC public immutable USDC;
    address public immutable OWNER;
    address public immutable AGENT;

    // Fixed policy used by the handler's oracle (must match the test's setUp).
    uint256 public immutable PER_TX;
    uint256 public immutable DAILY;
    uint256 public immutable THRESHOLD;
    uint256 public immutable ETH_PER_TX;
    uint256 public immutable ETH_DAILY;
    uint256 public immutable ETH_THRESHOLD;

    address[] public toggled; // owner may allowlist/delist these
    address[] public neverAllowed; // handler never allowlists these
    address[2] public tokens; // [USDC, native ETH]

    /*//////////////////////////////////////////////////////////////
                               GHOST STATE
    //////////////////////////////////////////////////////////////*/

    // Fund-flow accounting per token (address(0) = ETH). Conservation invariant uses these.
    mapping(address => uint256) public deposited;
    mapping(address => uint256) public sentDirect;
    mapping(address => uint256) public sentApproved;
    mapping(address => uint256) public withdrawn;

    // Independent window oracle per token.
    mapping(address => uint256) internal modelStart;
    mapping(address => uint256) internal modelSpent;

    // Violation counters. ALL of these must stay 0 for the whole run.
    uint256 public violationNonAllowlisted; // a transfer succeeded to a non-allowlisted recipient
    uint256 public violationWhilePaused; // an agent action succeeded while paused
    uint256 public violationRule; // amount outside (0, threshold] succeeded directly
    uint256 public violationCap; // oracle window spend exceeded dailyCap
    uint256 public violationApprovedAboveCap; // approved request exceeded perTxCap
    uint256 public violationPrivileged; // agent/stranger succeeded at an owner-only function
    uint256 public violationStranger; // non-agent moved funds
    uint256 public violationExpiredApproved; // an expired request was approved
    uint256 public violationWronglyBlocked; // the rules say a transfer is legal, yet the contract refused it

    // Activity counters (not invariants; logged so we can see the fuzzer isn't running vacuously).
    uint256 public okDirect;
    uint256 public blockedDirect;
    uint256 public okRequests;
    uint256 public okApprovals;
    uint256 public okRejects;
    uint256 public okCancels;
    uint256 public pausedToggles;
    uint256 public warps;
    uint256 public privilegedAttempts;

    constructor(
        AgentVault vault_,
        MockUSDC usdc_,
        address owner_,
        address agent_,
        address[] memory toggled_,
        address[] memory neverAllowed_,
        uint256[6] memory policy // perTx, daily, threshold, ethPerTx, ethDaily, ethThreshold
    ) {
        VAULT = vault_;
        USDC = usdc_;
        OWNER = owner_;
        AGENT = agent_;
        toggled = toggled_;
        neverAllowed = neverAllowed_;
        tokens = [address(usdc_), address(0)];
        PER_TX = policy[0];
        DAILY = policy[1];
        THRESHOLD = policy[2];
        ETH_PER_TX = policy[3];
        ETH_DAILY = policy[4];
        ETH_THRESHOLD = policy[5];

        deposited[address(usdc_)] = usdc_.balanceOf(address(vault_));
        deposited[address(0)] = address(vault_).balance;
    }

    /*//////////////////////////////////////////////////////////////
                              AGENT ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Agent attempts a direct ERC-20 transfer to a random actor with a random amount.
    function agentTransferToken(uint256 toSeed, uint256 amountSeed) external {
        address to = _anyActor(toSeed);
        uint256 amount = _biasedAmount(amountSeed, PER_TX, THRESHOLD);
        _agentDirect(address(USDC), to, amount, PER_TX, THRESHOLD, DAILY);
    }

    /// @dev Agent attempts a direct ETH transfer.
    function agentTransferEth(uint256 toSeed, uint256 amountSeed) external {
        address to = _anyActor(toSeed);
        uint256 amount = _biasedAmount(amountSeed, ETH_PER_TX, ETH_THRESHOLD);
        _agentDirect(address(0), to, amount, ETH_PER_TX, ETH_THRESHOLD, ETH_DAILY);
    }

    function agentRequest(uint256 toSeed, uint256 amountSeed, bool eth) external {
        address token = eth ? address(0) : address(USDC);
        uint256 cap = eth ? ETH_PER_TX : PER_TX;
        address to = _anyActor(toSeed);
        uint256 amount = bound(amountSeed, 0, cap + cap / 2);

        bool paused = VAULT.paused();
        vm.prank(AGENT);
        try VAULT.requestTransfer(token, to, amount, "fuzz") returns (uint256) {
            okRequests++;
            if (paused) violationWhilePaused++;
            if (!VAULT.allowedRecipient(to)) violationNonAllowlisted++;
        } catch {}
    }

    function agentCancel(uint256 idSeed) external {
        uint256 n = VAULT.requestCount();
        if (n == 0) return;
        uint256 id = idSeed % n;
        bool paused = VAULT.paused();
        vm.prank(AGENT);
        try VAULT.cancelRequest(id) {
            okCancels++;
            if (paused) violationWhilePaused++;
        } catch {}
    }

    /*//////////////////////////////////////////////////////////////
                              OWNER ACTIONS
    //////////////////////////////////////////////////////////////*/

    function ownerApprove(uint256 idSeed) external {
        uint256 n = VAULT.requestCount();
        if (n == 0) return;
        uint256 id = idSeed % n;
        AgentVault.TransferRequest memory r = VAULT.getRequest(id);
        bool recipientAllowed = VAULT.allowedRecipient(r.to);
        bool expired = block.timestamp > uint256(r.createdAt) + VAULT.REQUEST_TTL();

        vm.prank(OWNER);
        try VAULT.approveRequest(id) {
            okApprovals++;
            sentApproved[r.token] += r.amount;
            if (!recipientAllowed) violationNonAllowlisted++;
            if (expired) violationExpiredApproved++;
            if (r.amount > (r.token == address(0) ? ETH_PER_TX : PER_TX)) violationApprovedAboveCap++;
        } catch {}
    }

    function ownerReject(uint256 idSeed) external {
        uint256 n = VAULT.requestCount();
        if (n == 0) return;
        vm.prank(OWNER);
        try VAULT.rejectRequest(idSeed % n) {
            okRejects++;
        } catch {}
    }

    /// @dev Owner flips a *toggled* actor. Biased (75%) toward ALLOWING so the vault spends most of
    ///      its time in states where transfers can succeed. `neverAllowed` actors are never touched.
    function ownerSetRecipient(uint256 actorSeed, uint256 modeSeed) external {
        address who = toggled[actorSeed % toggled.length];
        vm.prank(OWNER);
        VAULT.setRecipient(who, modeSeed % 4 != 0);
    }

    /// @dev Biased so the vault is paused only ~1 time in 6 and is usually resumed immediately after.
    function ownerSetPaused(uint256 modeSeed) external {
        vm.prank(OWNER);
        VAULT.setPaused(modeSeed % 6 == 0);
        pausedToggles++;
    }

    function ownerWithdraw(bool eth, uint256 amountSeed) external {
        address token = eth ? address(0) : address(USDC);
        uint256 bal = VAULT.balanceOf(token);
        if (bal == 0) return;
        uint256 amount = bound(amountSeed, 1, bal);
        vm.prank(OWNER);
        try VAULT.withdraw(token, OWNER, amount) {
            withdrawn[token] += amount;
        } catch {}
    }

    /// @dev Anyone can top the vault up; keeps it from running dry so transfers keep succeeding.
    function fund(bool eth, uint256 amountSeed) external {
        if (eth) {
            uint256 amount = bound(amountSeed, 0, 1 ether);
            vm.deal(address(VAULT), address(VAULT).balance + amount);
            deposited[address(0)] += amount;
        } else {
            uint256 amount = bound(amountSeed, 0, 50e6);
            USDC.mint(address(VAULT), amount);
            deposited[address(USDC)] += amount;
        }
    }

    /*//////////////////////////////////////////////////////////////
                           ADVERSARIAL ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev A compromised agent key tries every owner-only function. NONE may succeed.
    function agentAttemptsPrivileged(uint256 which, address victim, uint256 amountSeed) external {
        privilegedAttempts++;
        uint256 pick = which % 9;
        vm.startPrank(AGENT);
        if (pick == 0) {
            try VAULT.setAgent(victim) {
                violationPrivileged++;
            } catch {}
        } else if (pick == 1) {
            try VAULT.setPaused(false) {
                violationPrivileged++;
            } catch {}
        } else if (pick == 2) {
            try VAULT.setTokenPolicy(address(USDC), true, type(uint128).max, type(uint128).max, type(uint128).max) {
                violationPrivileged++;
            } catch {}
        } else if (pick == 3) {
            try VAULT.setRecipient(victim, true) {
                violationPrivileged++;
            } catch {}
        } else if (pick == 4) {
            try VAULT.withdraw(address(USDC), victim, amountSeed) {
                violationPrivileged++;
            } catch {}
        } else if (pick == 5) {
            try VAULT.approveRequest(amountSeed) {
                violationPrivileged++;
            } catch {}
        } else if (pick == 6) {
            try VAULT.rejectRequest(amountSeed) {
                violationPrivileged++;
            } catch {}
        } else if (pick == 7) {
            try VAULT.transferOwnership(victim) {
                violationPrivileged++;
            } catch {}
        } else {
            try VAULT.renounceOwnership() {
                violationPrivileged++;
            } catch {}
        }
        vm.stopPrank();
    }

    /// @dev A random third party tries to move funds or call privileged functions.
    function strangerAttacks(address caller, uint256 which, uint256 amountSeed) external {
        if (caller == AGENT || caller == OWNER) return;
        uint256 amount = bound(amountSeed, 1, THRESHOLD);
        vm.startPrank(caller);
        if (which % 3 == 0) {
            try VAULT.transferToken(address(USDC), caller, amount) {
                violationStranger++;
            } catch {}
        } else if (which % 3 == 1) {
            try VAULT.transferETH(caller, amount) {
                violationStranger++;
            } catch {}
        } else {
            try VAULT.withdraw(address(USDC), caller, amount) {
                violationPrivileged++;
            } catch {}
        }
        vm.stopPrank();
    }

    /// @dev Time passes: lets windows roll over and requests expire.
    function warp(uint256 secondsSeed) external {
        // 80%: small hops (<= 6h) so several transfers land in one window and the cap is actually hit.
        // 20%: big hops (<= 2 days) so windows roll over and requests expire.
        uint256 delta = secondsSeed % 10 < 8 ? bound(secondsSeed >> 8, 0, 6 hours) : bound(secondsSeed >> 8, 0, 2 days);
        vm.warp(block.timestamp + delta);
        warps++;
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _agentDirect(address token, address to, uint256 amount, uint256 perTx, uint256 threshold, uint256 daily)
        internal
    {
        bool paused = VAULT.paused();
        bool recipientAllowed = VAULT.allowedRecipient(to);

        // EXACT ORACLE: decide, from the documented rules alone, whether this transfer must succeed.
        uint256 spentNow = _modelSpentNow(token);
        bool shouldSucceed = !paused && recipientAllowed && amount > 0 && amount <= perTx && amount <= threshold
            && spentNow + amount <= daily && VAULT.balanceOf(token) >= amount;

        vm.prank(AGENT);
        bool ok;
        if (token == address(0)) {
            try VAULT.transferETH(to, amount) {
                ok = true;
            } catch {}
        } else {
            try VAULT.transferToken(token, to, amount) {
                ok = true;
            } catch {}
        }

        if (!ok) {
            blockedDirect++;
            // Liveness half of the oracle: a legal transfer must not be refused.
            if (shouldSucceed) violationWronglyBlocked++;
            return;
        }
        okDirect++;
        sentDirect[token] += amount;

        // Rule oracle: re-check every documented rule against what just succeeded.
        if (paused) violationWhilePaused++;
        if (!recipientAllowed) violationNonAllowlisted++;
        if (amount == 0 || amount > perTx || amount > threshold) violationRule++;

        // Window oracle: independent re-implementation of the fixed 24h window.
        if (modelStart[token] == 0 || block.timestamp >= modelStart[token] + 1 days) {
            modelStart[token] = block.timestamp;
            modelSpent[token] = 0;
        }
        modelSpent[token] += amount;
        if (modelSpent[token] > daily) violationCap++;
    }

    /// @dev 70% of amounts are legal-sized (1..threshold) so the daily cap is actually reached;
    ///      30% span zero, needs-approval, and over-cap values to exercise every rejection path.
    function _biasedAmount(uint256 seed, uint256 perTx, uint256 threshold) internal pure returns (uint256) {
        if (seed % 10 < 7) return bound(seed >> 8, 1, threshold);
        return bound(seed >> 8, 0, perTx * 2);
    }

    /// @dev What the independent window model says has been spent in the window that applies now.
    function _modelSpentNow(address token) internal view returns (uint256) {
        if (modelStart[token] == 0 || block.timestamp >= modelStart[token] + 1 days) return 0;
        return modelSpent[token];
    }

    function _anyActor(uint256 seed) internal view returns (address) {
        uint256 total = toggled.length + neverAllowed.length;
        uint256 i = seed % total;
        return i < toggled.length ? toggled[i] : neverAllowed[i - toggled.length];
    }

    function toggledLength() external view returns (uint256) {
        return toggled.length;
    }

    function neverAllowedLength() external view returns (uint256) {
        return neverAllowed.length;
    }
}
