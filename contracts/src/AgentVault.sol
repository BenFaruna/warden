// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title AgentVault
/// @author Warden
/// @notice A policy-enforced vault that lets an AI agent spend funds autonomously, but only
///         inside limits that the human owner sets and that are enforced on-chain.
///
/// @dev ## Why this exists
///      An LLM-driven agent can be prompt-injected, can hallucinate addresses, and can loop.
///      Handing it a raw wallet key means any of those failures can drain the wallet. With this
///      vault the agent holds a *limited operator key*: even a fully compromised agent can only
///      do what the policy allows. The safety property does not depend on the agent behaving.
///
///      ## Roles
///      - **Owner** (human; use a multisig/passkey in production): sets policy, approves or rejects
///        requests, pauses the vault, withdraws funds. Ownership transfer is two-step.
///      - **Agent** (a single operator address): may only (a) transfer within policy,
///        (b) file approval requests, (c) cancel its own pending requests. It can never change
///        policy, allowlists, pause state, or its own address, and it can never withdraw.
///
///      ## Policy model (per token; `address(0)` represents native ETH)
///      Invariant enforced on every policy update:
///      `approvalThreshold <= perTxCap <= dailyCap <= type(uint192).max`
///
///      A direct agent transfer must satisfy ALL of:
///      1. vault is not paused
///      2. token is allowlisted, recipient is allowlisted
///      3. `amount > 0`
///      4. `amount <= perTxCap`                (hard ceiling; cannot be approved around)
///      5. `amount <= approvalThreshold`       (above this, a human must approve)
///      6. spend in the current 24h window + `amount <= dailyCap`
///
///      Amounts in `(approvalThreshold, perTxCap]` are not lost causes: the agent files a
///      request via {requestTransfer}; the owner executes it with {approveRequest}.
///
///      ## Known limitations (read before relying on this)
///      - The daily cap is a **fixed window** that starts at the first spend after the previous
///        window expired. It is not a true sliding window: spending right at the end of one window
///        and right at the start of the next can move up to ~2x `dailyCap` in a short span.
///        Choose `dailyCap` with that worst case in mind. (Covered by a test that documents it.)
///      - Caps are denominated in token base units. There is no price oracle, so caps for different
///        tokens are independent and the vault does not aggregate value across tokens.
///      - Fee-on-transfer, rebasing, and ERC-777-style hook tokens are not supported. Only allowlist
///        plain ERC-20s. (Reentrancy is blocked regardless.)
///      - The agent pays its own gas, so the agent address needs a small native-ETH balance.
///      - Owner-approved requests are an explicit human decision and do NOT consume the daily cap.
contract AgentVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Spending policy for a single token (or native ETH when keyed by `address(0)`).
    /// @param allowed            Whether the agent may move this token at all.
    /// @param perTxCap           Max amount for any single transfer or request (base units).
    /// @param dailyCap           Max total direct-transfer volume per 24h window (base units).
    /// @param approvalThreshold  Largest amount the agent may send directly; anything above needs approval.
    struct TokenPolicy {
        bool allowed;
        uint256 perTxCap;
        uint256 dailyCap;
        uint256 approvalThreshold;
    }

    /// @notice Running spend counter for a token's current 24h window.
    /// @dev `spent` is uint192 so the struct packs into one storage slot with `start` (64 + 192 = 256).
    struct SpendWindow {
        uint64 start;
        uint192 spent;
    }

    /// @notice Lifecycle of an approval request. `None` is the zero value so unknown ids are detectable.
    enum RequestStatus {
        None,
        Pending,
        Approved,
        Rejected,
        Cancelled
    }

    /// @notice A transfer the agent wants but is not allowed to make on its own.
    struct TransferRequest {
        address token;
        address to;
        uint256 amount;
        address requester;
        uint64 createdAt;
        RequestStatus status;
        string reason; // free-text justification from the agent, shown to the human owner
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Length of the spend window.
    uint64 public constant WINDOW = 1 days;

    /// @notice How long a pending request stays approvable. Stale requests must be re-filed,
    ///         so an owner can't accidentally approve something that was requested weeks ago.
    uint64 public constant REQUEST_TTL = 3 days;

    /// @notice Cap on simultaneously pending requests (prevents a looping agent from spamming the owner).
    uint256 public constant MAX_PENDING_REQUESTS = 25;

    /// @notice Cap on the length (bytes) of a request's `reason` string.
    uint256 public constant MAX_REASON_BYTES = 280;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The single address allowed to act as the agent. `address(0)` means no agent (disabled).
    address public agent;

    /// @notice Kill switch. While true, every agent function reverts. Owner functions keep working.
    bool public paused;

    /// @notice Number of requests currently in `Pending` state.
    uint256 public pendingCount;

    /// @dev token => policy. `address(0)` keys native ETH.
    mapping(address token => TokenPolicy) private _policies;

    /// @dev recipient => allowed. Applies to every token (and to ETH).
    mapping(address recipient => bool) public allowedRecipient;

    /// @dev token => current spend window.
    mapping(address token => SpendWindow) private _windows;

    /// @dev All requests ever filed; the array index is the request id.
    TransferRequest[] private _requests;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event AgentSet(address indexed previousAgent, address indexed newAgent);
    event Paused(bool isPaused);
    event TokenPolicySet(
        address indexed token, bool allowed, uint256 perTxCap, uint256 dailyCap, uint256 approvalThreshold
    );
    event RecipientSet(address indexed recipient, bool allowed);
    /// @notice Emitted for every executed transfer. `viaApproval` is true when the owner approved a request.
    event TransferExecuted(address indexed token, address indexed to, uint256 amount, bool viaApproval);
    event TransferRequested(
        uint256 indexed id, address indexed token, address indexed to, uint256 amount, string reason
    );
    event RequestApproved(uint256 indexed id);
    event RequestRejected(uint256 indexed id);
    event RequestCancelled(uint256 indexed id);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);
    event Deposited(address indexed from, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    // Custom errors carry the numbers an agent needs to self-correct (e.g. how much budget is left).

    error NotAgent();
    error VaultPaused();
    error TokenNotAllowed(address token);
    error RecipientNotAllowed(address to);
    error InvalidRecipient();
    error ZeroAmount();
    error ExceedsPerTxCap(uint256 requested, uint256 cap);
    error NeedsApproval(uint256 requested, uint256 threshold);
    error ExceedsDailyCap(uint256 requested, uint256 remaining);
    error InvalidPolicy();
    error InvalidAgent();
    error RequestNotFound(uint256 id);
    error RequestNotPending(uint256 id);
    error RequestExpired(uint256 id);
    error NotRequester();
    error TooManyPendingRequests();
    error ReasonTooLong();
    error EthTransferFailed();
    error RenounceDisabled();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Restricts to the agent address. A zero `agent` disables all agent functions.
    modifier onlyAgent() {
        _checkAgent();
        _;
    }

    /// @dev Blocks execution while the kill switch is on.
    modifier whenNotPaused() {
        _checkNotPaused();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param initialOwner The human owner. Deploys with no agent, no policy and no allowlist:
    ///        the vault is inert until the owner configures it (secure by default).
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @notice Accept native ETH deposits.
    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    /*//////////////////////////////////////////////////////////////
                         OWNER: CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Set (or rotate) the agent operator. Pass `address(0)` to disable the agent entirely.
    /// @dev The agent cannot equal the owner, to keep the two roles separate. Pending requests
    ///      filed by a previous agent stay in place; the owner can reject them.
    function setAgent(address newAgent) external onlyOwner {
        if (newAgent == owner()) revert InvalidAgent();
        emit AgentSet(agent, newAgent);
        agent = newAgent;
    }

    /// @notice Kill switch. `true` freezes all agent activity immediately; `false` resumes it.
    /// @dev Owner functions (approve, reject, withdraw, policy changes) remain usable while paused,
    ///      so the owner can still clean up and recover funds during an incident.
    function setPaused(bool isPaused) external onlyOwner {
        paused = isPaused;
        emit Paused(isPaused);
    }

    /// @notice Create or update the policy for a token (use `address(0)` for native ETH).
    /// @dev Enforces `approvalThreshold <= perTxCap <= dailyCap <= type(uint192).max`.
    ///      The uint192 bound keeps the packed spend counter overflow-free.
    ///      Lowering `dailyCap` below current-window spend simply blocks further direct spending
    ///      until the window resets; it does not revert or claw anything back.
    function setTokenPolicy(
        address token,
        bool allowed,
        uint256 perTxCap,
        uint256 dailyCap,
        uint256 approvalThreshold
    ) external onlyOwner {
        if (approvalThreshold > perTxCap || perTxCap > dailyCap || dailyCap > type(uint192).max) {
            revert InvalidPolicy();
        }
        _policies[token] = TokenPolicy({
            allowed: allowed,
            perTxCap: perTxCap,
            dailyCap: dailyCap,
            approvalThreshold: approvalThreshold
        });
        emit TokenPolicySet(token, allowed, perTxCap, dailyCap, approvalThreshold);
    }

    /// @notice Add or remove an address from the recipient allowlist.
    /// @dev The zero address and the vault itself can never be allowlisted: sending to them is
    ///      either a burn or a pointless self-transfer.
    function setRecipient(address recipient, bool allowed) external onlyOwner {
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        allowedRecipient[recipient] = allowed;
        emit RecipientSet(recipient, allowed);
    }

    /*//////////////////////////////////////////////////////////////
                           OWNER: FUND MOVEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Owner withdrawal to any address. Not subject to policy (the owner is the root of trust).
    /// @param token `address(0)` for native ETH.
    function withdraw(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidRecipient();
        if (amount == 0) revert ZeroAmount();
        _send(token, to, amount);
        emit Withdrawn(token, to, amount);
    }

    /// @notice Execute a pending request. This is the human-in-the-loop path for larger payments.
    /// @dev Checks, in order: request exists, is pending, not expired, token still allowlisted,
    ///      recipient still allowlisted. The last two are re-checked because the owner may have
    ///      removed them since the request was filed, and removal signals intent.
    ///      Works while paused (owner actions are never blocked by the kill switch).
    ///      Does NOT count against the daily cap and does not re-check caps: approval is an explicit
    ///      human decision. State is updated before the external call (checks-effects-interactions).
    function approveRequest(uint256 id) external onlyOwner nonReentrant {
        TransferRequest storage r = _getPending(id);
        if (block.timestamp > uint256(r.createdAt) + REQUEST_TTL) revert RequestExpired(id);
        if (!_policies[r.token].allowed) revert TokenNotAllowed(r.token);
        if (!allowedRecipient[r.to]) revert RecipientNotAllowed(r.to);

        r.status = RequestStatus.Approved;
        pendingCount--;

        _send(r.token, r.to, r.amount);

        emit RequestApproved(id);
        emit TransferExecuted(r.token, r.to, r.amount, true);
    }

    /// @notice Reject a pending request. Works at any time, including after expiry and while paused.
    function rejectRequest(uint256 id) external onlyOwner {
        TransferRequest storage r = _getPending(id);
        r.status = RequestStatus.Rejected;
        pendingCount--;
        emit RequestRejected(id);
    }

    /*//////////////////////////////////////////////////////////////
                          AGENT: DIRECT TRANSFERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Agent sends an ERC-20 directly, if and only if the policy allows it.
    /// @dev Reverts with a descriptive custom error otherwise. See the contract-level docs for the full
    ///      rule list. Spend is recorded BEFORE the external call (checks-effects-interactions).
    function transferToken(address token, address to, uint256 amount)
        external
        onlyAgent
        whenNotPaused
        nonReentrant
    {
        if (token == address(0)) revert TokenNotAllowed(token); // ETH must use transferETH
        _enforceAndRecord(token, to, amount);
        _send(token, to, amount);
        emit TransferExecuted(token, to, amount, false);
    }

    /// @notice Agent sends native ETH directly, if and only if the policy for `address(0)` allows it.
    // forge-lint: disable-next-line(mixed-case-function)
    function transferETH(address to, uint256 amount) external onlyAgent whenNotPaused nonReentrant {
        _enforceAndRecord(address(0), to, amount);
        _send(address(0), to, amount);
        emit TransferExecuted(address(0), to, amount, false);
    }

    /*//////////////////////////////////////////////////////////////
                          AGENT: APPROVAL REQUESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Ask the owner to approve a transfer the agent cannot make directly.
    /// @dev The request is validated up front so the owner is never asked to review something that
    ///      could never execute: token and recipient must be allowlisted, and `amount <= perTxCap`
    ///      (the hard ceiling cannot be approved around). Funds do not move until the owner approves.
    /// @param token  `address(0)` for native ETH.
    /// @param reason Short justification shown to the owner (max {MAX_REASON_BYTES} bytes).
    /// @return id    The request id to pass to {approveRequest} / {rejectRequest}.
    function requestTransfer(address token, address to, uint256 amount, string calldata reason)
        external
        onlyAgent
        whenNotPaused
        returns (uint256 id)
    {
        TokenPolicy memory p = _policies[token];
        if (!p.allowed) revert TokenNotAllowed(token);
        if (!allowedRecipient[to]) revert RecipientNotAllowed(to);
        if (amount == 0) revert ZeroAmount();
        if (amount > p.perTxCap) revert ExceedsPerTxCap(amount, p.perTxCap);
        if (bytes(reason).length > MAX_REASON_BYTES) revert ReasonTooLong();
        if (pendingCount >= MAX_PENDING_REQUESTS) revert TooManyPendingRequests();

        id = _requests.length;
        _requests.push(
            TransferRequest({
                token: token,
                to: to,
                amount: amount,
                requester: msg.sender,
                // forge-lint: disable-next-line(unsafe-typecast)
                createdAt: uint64(block.timestamp),
                status: RequestStatus.Pending,
                reason: reason
            })
        );
        pendingCount++;

        emit TransferRequested(id, token, to, amount, reason);
    }

    /// @notice Agent withdraws one of its own pending requests.
    /// @dev Only the address that filed the request may cancel it (a rotated-in agent cannot cancel
    ///      the old agent's requests; the owner should reject those instead).
    function cancelRequest(uint256 id) external onlyAgent whenNotPaused {
        TransferRequest storage r = _getPending(id);
        if (r.requester != msg.sender) revert NotRequester();
        r.status = RequestStatus.Cancelled;
        pendingCount--;
        emit RequestCancelled(id);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Policy for a token (`address(0)` = native ETH).
    function getPolicy(address token) external view returns (TokenPolicy memory) {
        return _policies[token];
    }

    /// @notice Raw spend-window state for a token. `spent` may be stale if the window has expired;
    ///         use {remainingDaily} for the effective remaining budget.
    function getSpendWindow(address token) external view returns (SpendWindow memory) {
        return _windows[token];
    }

    /// @notice How much the agent can still send *directly* right now, accounting for window expiry.
    /// @dev This is the daily-cap headroom only. The agent is also bound by `perTxCap` and
    ///      `approvalThreshold` on each individual transfer.
    function remainingDaily(address token) external view returns (uint256) {
        (, uint256 spent) = _effectiveWindow(token);
        uint256 cap = _policies[token].dailyCap;
        return cap > spent ? cap - spent : 0;
    }

    /// @notice Total number of requests ever filed (ids are `0 .. requestCount()-1`).
    function requestCount() external view returns (uint256) {
        return _requests.length;
    }

    /// @notice Read one request. Reverts with {RequestNotFound} for unknown ids.
    function getRequest(uint256 id) external view returns (TransferRequest memory) {
        if (id >= _requests.length) revert RequestNotFound(id);
        return _requests[id];
    }

    /// @notice Ids of all requests currently pending (including expired-but-unresolved ones).
    /// @dev Iterates the whole request array; intended for off-chain `eth_call` use.
    function getPendingRequestIds() external view returns (uint256[] memory ids) {
        ids = new uint256[](pendingCount);
        uint256 n;
        uint256 len = _requests.length;
        for (uint256 i; i < len && n < ids.length; ++i) {
            if (_requests[i].status == RequestStatus.Pending) ids[n++] = i;
        }
    }

    /// @notice Vault balance of a token (`address(0)` = native ETH).
    function balanceOf(address token) external view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }

    /// @notice Renouncing ownership would permanently lock funds and policy, so it is disabled.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /*//////////////////////////////////////////////////////////////
                               INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev Modifier bodies live in functions to keep bytecode small.
    function _checkAgent() internal view {
        if (agent == address(0) || msg.sender != agent) revert NotAgent();
    }

    function _checkNotPaused() internal view {
        if (paused) revert VaultPaused();
    }

    /// @dev Validates a direct agent transfer against policy and records the spend.
    ///      Rule order matters: it is chosen so the agent gets the most actionable error first
    ///      (e.g. "recipient not allowed" before "over cap").
    function _enforceAndRecord(address token, address to, uint256 amount) internal {
        TokenPolicy memory p = _policies[token];

        if (to == address(0) || to == address(this)) revert InvalidRecipient();
        if (!p.allowed) revert TokenNotAllowed(token);
        if (!allowedRecipient[to]) revert RecipientNotAllowed(to);
        if (amount == 0) revert ZeroAmount();
        if (amount > p.perTxCap) revert ExceedsPerTxCap(amount, p.perTxCap);
        if (amount > p.approvalThreshold) revert NeedsApproval(amount, p.approvalThreshold);

        (uint64 start, uint256 spent) = _effectiveWindow(token);
        uint256 remaining = p.dailyCap > spent ? p.dailyCap - spent : 0;
        if (amount > remaining) revert ExceedsDailyCap(amount, remaining);

        // Safe cast: spent + amount <= dailyCap <= type(uint192).max (enforced in setTokenPolicy).
        // `start` is persisted so a freshly rolled window is saved even on the first spend.
        // forge-lint: disable-next-line(unsafe-typecast)
        _windows[token] = SpendWindow({start: start, spent: uint192(spent + amount)});
    }

    /// @dev Returns the window that applies *now*: the stored one if still open, otherwise a fresh
    ///      window starting at the current timestamp with zero spend. A never-used window
    ///      (`start == 0`) is treated as expired.
    function _effectiveWindow(address token) internal view returns (uint64 start, uint256 spent) {
        SpendWindow memory w = _windows[token];
        if (w.start == 0 || block.timestamp >= uint256(w.start) + WINDOW) {
            // forge-lint: disable-next-line(unsafe-typecast)
            return (uint64(block.timestamp), 0);
        }
        return (w.start, w.spent);
    }

    /// @dev Loads a request and requires it to exist and be Pending.
    function _getPending(uint256 id) internal view returns (TransferRequest storage r) {
        if (id >= _requests.length) revert RequestNotFound(id);
        r = _requests[id];
        if (r.status != RequestStatus.Pending) revert RequestNotPending(id);
    }

    /// @dev Moves funds out of the vault. Callers must have updated state first and hold `nonReentrant`.
    function _send(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}
