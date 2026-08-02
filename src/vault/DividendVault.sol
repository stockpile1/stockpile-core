// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

import { IDividendPayingToken } from "../interfaces/external/IFlap.sol";

/// @title DividendVault
/// @notice A cloneable (EIP-1167 minimal-proxy) DividendPayingToken, faithful to the standard
///         magnified-dividend-per-share pattern verified on-chain in Flap's per-token
///         `dividendContract`. It holds a single reward ERC20 (the grid's quote/yield token, e.g.
///         WBNB or STOCK), tracks per-account "shares" (seat / holder weights), and distributes the
///         reward pro-rata to those shares. Interface-compatible with `IDividendPayingToken`, so a
///         `FlapYieldAdapter` can treat it exactly like a real Flap dividendContract: hold a share,
///         `withdrawDividend()` to claim, `withdrawableDividendOf`/`accumulativeDividendOf` to read.
/// @dev Accounting (Roger Wu's DividendPayingToken, magnitude = 2**128):
///
///        magnifiedDividendPerShare  += distributed * MAGNITUDE / totalShares
///        accumulativeDividendOf(a)   = uint256( magnifiedDividendPerShare * share[a]
///                                               + magnifiedCorrections[a] ) / MAGNITUDE
///
///      A `setShare` change is treated like a mint/burn of the share delta: the account's
///      correction is adjusted by `-/+ magnifiedDividendPerShare * delta` so already-accrued
///      dividends are preserved across weight changes. Integer division leaves sub-unit "dust"
///      permanently in the vault, guaranteeing solvency (vault balance >= sum of withdrawable).
///
///      Clone-safe: no constructor logic runs on clones, so all state is set in {initialize}
///      (re-init blocked by OpenZeppelin {Initializable}); the deployed template disables its own
///      initializers. ReentrancyGuard / Initializable use ERC-7201 namespaced slots, so they work
///      correctly under a minimal proxy's zero-initialized storage.
contract DividendVault is Initializable, ReentrancyGuard, IDividendPayingToken {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Fixed-point scaling factor for per-share accounting (2**128), matching the on-chain
    ///         Flap dividendContract. Large enough that per-share rounding error is negligible.
    uint256 internal constant MAGNITUDE = 2 ** 128;

    // --------------------------------------------------------------------- //
    //                                 State                                 //
    // --------------------------------------------------------------------- //

    /// @notice The reward ERC20 distributed to shareholders (the grid's quote/yield token).
    IERC20 public rewardToken;

    /// @notice Owner authorized to manage shares and owner-gated routing (the factory's caller,
    ///         typically the adapter operator / grid owner).
    address public owner;

    /// @notice Sum of all outstanding shares. Distribution reverts while this is zero.
    uint256 public totalShares;

    /// @notice Per-account share weight (mirrors seat / holder weights).
    mapping(address => uint256) public shareOf;

    /// @notice Lifetime reward ever distributed across all shareholders (implements
    ///         {IDividendPayingToken.totalDividendsDistributed}).
    uint256 public override totalDividendsDistributed;

    /// @notice Lifetime reward ever withdrawn by shareholders. Used to size the syncable surplus.
    uint256 public totalDividendsWithdrawn;

    // Magnified accumulator and per-account corrections (see contract NatSpec for the formula).
    uint256 internal magnifiedDividendPerShare;
    mapping(address => int256) internal magnifiedDividendCorrections;
    mapping(address => uint256) internal withdrawnDividends;

    // --------------------------------------------------------------------- //
    //                                Events                                 //
    // --------------------------------------------------------------------- //

    /// @notice Emitted once when a clone is initialized.
    event Initialized(address indexed rewardToken, address indexed owner);
    /// @notice Emitted when ownership is transferred (including the initial set on init).
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    /// @notice Emitted when an account's share weight changes.
    event ShareUpdated(address indexed account, uint256 oldShare, uint256 newShare, uint256 totalShares);
    /// @notice Emitted when reward is distributed pro-rata to shareholders.
    event DividendsDistributed(address indexed from, uint256 amount);
    /// @notice Emitted when a shareholder's accrued reward is withdrawn.
    event DividendWithdrawn(address indexed account, address indexed to, uint256 amount);

    // --------------------------------------------------------------------- //
    //                              Modifiers                                //
    // --------------------------------------------------------------------- //

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    // --------------------------------------------------------------------- //
    //                          Init / ownership                             //
    // --------------------------------------------------------------------- //

    /// @notice Lock the deployed template so it can never be initialized directly; only clones of it
    ///         (which have their own zero-initialized storage) are usable.
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize a freshly deployed clone. No constructor runs on clones, so this sets all
    ///         state and is protected against re-initialization by {Initializable}.
    /// @param rewardToken_ The reward ERC20 this vault distributes (must be non-zero).
    /// @param owner_ The address authorized to manage shares (must be non-zero).
    function initialize(address rewardToken_, address owner_) external initializer {
        require(rewardToken_ != address(0), "rewardToken");
        require(owner_ != address(0), "owner");
        rewardToken = IERC20(rewardToken_);
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
        emit Initialized(rewardToken_, owner_);
    }

    /// @notice Transfer ownership of the vault.
    /// @param newOwner The new owner (must be non-zero).
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // --------------------------------------------------------------------- //
    //                             Share admin                               //
    // --------------------------------------------------------------------- //

    /// @notice Set `account`'s absolute share weight, updating `totalShares` and the account's
    ///         magnified correction so previously-accrued dividends are preserved.
    /// @param account The account whose weight is set (must be non-zero).
    /// @param newShare The new absolute share weight (0 removes the account's future entitlement).
    function setShare(address account, uint256 newShare) public onlyOwner {
        _setShare(account, newShare);
    }

    /// @notice Batch variant of {setShare}.
    /// @param accounts The accounts to update.
    /// @param newShares The new absolute weights, index-aligned with `accounts`.
    function batchSetShare(address[] calldata accounts, uint256[] calldata newShares) external onlyOwner {
        require(accounts.length == newShares.length, "length");
        for (uint256 i; i < accounts.length; ++i) {
            _setShare(accounts[i], newShares[i]);
        }
    }

    /// @dev Adjust a share weight like a mint/burn of the delta: the correction offsets the change
    ///      in `magnifiedDividendPerShare * share` so `accumulativeDividendOf` is unchanged by the
    ///      reweight (only future distributions accrue at the new weight).
    function _setShare(address account, uint256 newShare) internal {
        require(account != address(0), "account");
        uint256 old = shareOf[account];
        if (newShare == old) return;

        shareOf[account] = newShare;
        if (newShare > old) {
            uint256 added = newShare - old;
            totalShares += added;
            magnifiedDividendCorrections[account] -= (magnifiedDividendPerShare * added).toInt256();
        } else {
            uint256 removed = old - newShare;
            totalShares -= removed;
            magnifiedDividendCorrections[account] += (magnifiedDividendPerShare * removed).toInt256();
        }
        emit ShareUpdated(account, old, newShare, totalShares);
    }

    // --------------------------------------------------------------------- //
    //                            Distribution                               //
    // --------------------------------------------------------------------- //

    /// @notice Pull `amount` of reward from the caller and distribute it pro-rata to shareholders.
    /// @dev Fee-on-transfer safe: credits the ACTUAL balance delta received, not the nominal
    ///      `amount` (mirrors the UGM's AUDIT-1 F-01 fix). Reverts cleanly if there are no shares.
    /// @param amount Nominal reward amount to pull from the caller (via `safeTransferFrom`).
    /// @return distributed The actual amount credited to the per-share accumulator.
    function distribute(uint256 amount) external nonReentrant returns (uint256 distributed) {
        require(amount > 0, "amount");
        require(totalShares > 0, "no shares");
        IERC20 t = rewardToken;
        uint256 balBefore = t.balanceOf(address(this));
        t.safeTransferFrom(msg.sender, address(this), amount);
        distributed = t.balanceOf(address(this)) - balBefore;
        _distribute(distributed);
    }

    /// @notice Distribute reward already sitting in the vault (e.g. transferred in directly, or a
    ///         fee-on-transfer donation) without pulling new funds.
    /// @dev Credits `syncableSurplus()` — the vault balance in excess of what is owed to existing
    ///      shareholders (`totalDividendsDistributed - totalDividendsWithdrawn`). Fee-on-transfer
    ///      safe because the surplus is measured from the real balance. Reverts if there is no
    ///      surplus or no shares.
    /// @return distributed The surplus amount credited to the per-share accumulator.
    function distributeSynced() external nonReentrant returns (uint256 distributed) {
        require(totalShares > 0, "no shares");
        distributed = syncableSurplus();
        _distribute(distributed);
    }

    /// @notice The reward balance not yet accounted to shareholders — what {distributeSynced} would
    ///         distribute right now. Never reverts.
    /// @return The distributable surplus (0 if the balance exactly matches outstanding obligations).
    function syncableSurplus() public view returns (uint256) {
        uint256 bal = rewardToken.balanceOf(address(this));
        uint256 accounted = totalDividendsDistributed - totalDividendsWithdrawn;
        // Invariant: bal == accounted + externalSurplus, so this never underflows.
        return bal - accounted;
    }

    /// @dev Raise the magnified accumulator by `amount / totalShares` and book the distribution.
    function _distribute(uint256 amount) internal {
        require(amount > 0, "nothing to distribute");
        magnifiedDividendPerShare += (amount * MAGNITUDE) / totalShares;
        totalDividendsDistributed += amount;
        emit DividendsDistributed(msg.sender, amount);
    }

    // --------------------------------------------------------------------- //
    //                             Withdrawal                                //
    // --------------------------------------------------------------------- //

    /// @notice Withdraw the caller's currently-withdrawable reward to the caller.
    /// @dev Implements {IDividendPayingToken.withdrawDividend}. This is the selector the
    ///      `FlapYieldAdapter` calls (best-effort) to realize its share.
    function withdrawDividend() external override nonReentrant {
        _withdraw(msg.sender, msg.sender);
    }

    /// @notice Owner-gated pull-routing: flush `account`'s withdrawable reward to `account`.
    /// @dev Lets an operator realize a shareholder's dividends on their behalf (the funds always go
    ///      to the entitled `account`, never to the caller). No-op (returns 0) if nothing is owed.
    /// @param account The shareholder whose reward is withdrawn.
    /// @return withdrawn The amount transferred to `account`.
    function withdrawDividendTo(address account) external onlyOwner nonReentrant returns (uint256 withdrawn) {
        withdrawn = _withdraw(account, account);
    }

    /// @dev Move `account`'s withdrawable reward to `recipient`, booking it against withdrawals.
    function _withdraw(address account, address recipient) internal returns (uint256 withdrawable) {
        withdrawable = withdrawableDividendOf(account);
        if (withdrawable == 0) return 0;
        withdrawnDividends[account] += withdrawable;
        totalDividendsWithdrawn += withdrawable;
        rewardToken.safeTransfer(recipient, withdrawable);
        emit DividendWithdrawn(account, recipient, withdrawable);
    }

    // --------------------------------------------------------------------- //
    //                                Views                                  //
    // --------------------------------------------------------------------- //

    /// @notice Reward currently withdrawable by `account` (accumulated minus already withdrawn).
    /// @dev Never reverts. Implements {IDividendPayingToken.withdrawableDividendOf}.
    /// @param account The shareholder to query.
    /// @return The amount `account` can withdraw right now.
    function withdrawableDividendOf(address account) public view override returns (uint256) {
        return accumulativeDividendOf(account) - withdrawnDividends[account];
    }

    /// @notice Total reward ever allocated to `account` (withdrawn + still withdrawable).
    /// @dev Never reverts under correct maintenance. Implements
    ///      {IDividendPayingToken.accumulativeDividendOf}.
    /// @param account The shareholder to query.
    /// @return The lifetime reward allocated to `account`.
    function accumulativeDividendOf(address account) public view override returns (uint256) {
        int256 magnified = (magnifiedDividendPerShare * shareOf[account]).toInt256() + magnifiedDividendCorrections[account];
        // Casting to 'uint256' is safe: under correct share maintenance the magnified sum is always
        // >= 0 (the correction only offsets per-share*share already granted), the DividendPayingToken
        // invariant. forge-lint: disable-next-line(unsafe-typecast)
        return uint256(magnified) / MAGNITUDE;
    }

    /// @notice Reward already withdrawn by `account`.
    /// @param account The shareholder to query.
    /// @return The lifetime reward withdrawn by `account`.
    function withdrawnDividendOf(address account) external view returns (uint256) {
        return withdrawnDividends[account];
    }
}
