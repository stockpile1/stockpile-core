// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {IVaultFactoryValidationV2} from "./flap/IVaultFactory.sol";
import {VaultDataSchema, FieldDescriptor, FactoryPolicy} from "./flap/IVaultSchemasV1.sol";
import {StockpileVault} from "./StockpileVault.sol";

import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

// ──────────────────────────────────────────────────────────────────────────────
//  Minimal local interface + structs for the Stockpile UnifiedGridManager (UGM)
// ──────────────────────────────────────────────────────────────────────────────

/// @notice Grid-creation parameters. MUST mirror `libraries/GridTypes.sol::CreateGridParams`
///         field order and types exactly — it is ABI-encoded into `createGrid`.
struct CreateGridParams {
    uint32 totalSeats; // seats to create, bounded [MIN_TOTAL_SEATS, MAX_TOTAL_SEATS]
    uint16 taxRateBps; // Harberger tax rate per week, in basis points [10, 1000]
    uint32 forfeitureDuration; // Dutch decay window (seconds); 0 => UGM applies its own default
    address taxToken; // token used for prices, deposits and tax (must be guardian-allowed)
    address yieldToken; // token distributed to seat holders as yield
    uint128 initialPrice; // uniform starting price for every creator-owned seat
}

/// @notice Minimal view of the Stockpile UnifiedGridManager used by this factory.
interface IUGM {
    function createGrid(CreateGridParams calldata p) external returns (uint256 gridId);
    function assetAdapter(bytes32 assetHash) external view returns (address adapter);
    /// @notice Pull all of the CALLER's accrued payouts in `token` to the caller. Returns the amount swept.
    function claimPayout(address token) external returns (uint256);
    /// @notice Settle unsold-seat yield for `seatIds` on `gridId` into the creator's claimable payouts.
    function claimYieldBatch(uint256 gridId, uint256[] calldata seatIds) external;
}

/// @title StockpileVaultFactory
/// @author The Stockpile Team
/// @notice Beacon-backed factory for {StockpileVault} proxies, each wired to a fresh
///         Stockpile Harberger grid whose tax + yield token is a single ERC20 "stock"
///         settlement token.
///
/// @dev  ── CÁCH B: REGULAR-LAUNCH, STOCK-SETTLED ────────────────────────────────
///
///   Flap's vault-backed launch (`VaultPortal.newTokenV6WithVault`) only accepts a
///   NATIVE-BNB quote, so it cannot deliver an ERC20 "stock" tax stream to a vault.
///   This factory therefore targets the REGULAR launch path: an operator (1) calls
///   `newVault(...)` here to create a grid + vault settled in the stock, then (2)
///   launches a token via `Portal.newTokenV6` with the vault as the `beneficiary`.
///   The token's `TaxProcessor` then liquidates tax to the stock and transfers the
///   market portion to the vault, which `flush()` forwards into the grid.
///
///   Because Flap's VaultPortal never calls this factory in that flow, `newVault` is
///   permissionless (mirroring the UGM's permissionless `createGrid`, which already
///   gates the settlement token via the guardian allowlist) rather than
///   VaultPortal-gated.
///
///   ── APPROVAL BRIDGE (handoff — deliberately NOT automated here) ────────────
///
///   A freshly created vault CANNOT `flush()` yet:
///     a. the Stockpile guardian (UGM owner) calls `ugm.setApprovedAdapter(vault, true)`, then
///     b. anyone calls `vault.registerWithGrid(gridId)`, so the vault itself calls
///        `ugm.registerAsset(gridId, assetHash)` and the UGM binds `assetAdapter[assetHash]`
///        to the vault — the identity `receiveYieldERC20` (hence `flush()`) enforces.
///   The factory emits {VaultAwaitingApproval} and exposes {pendingApproval} for keepers.
///
///   ── UPGRADES / GUARDIAN ────────────────────────────────────────────────────
///
///   All vaults delegate to one {UpgradeableBeacon} owned by this factory. The chain
///   Guardian (`_getGuardian()`) may `upgradeVaultImplementation` or permanently
///   `lockVaultUpgrades`.
contract StockpileVaultFactory is VaultFactoryBaseV2 {
    using SafeERC20 for IERC20;

    // ── Immutable configuration ────────────────────────────────────────────────

    /// @notice Beacon holding the shared {StockpileVault} implementation.
    address public immutable beacon;
    /// @notice Stockpile UnifiedGridManager (grid sink) every vault forwards yield to.
    address public immutable ugm;
    /// @notice Default commission cap (bps) applied when a launch omits its own.
    uint16 public immutable defaultCommissionBps;

    // NOTE (per-vault, not factory-fixed): the settlement "stock" token and the commission
    // recipient (treasury) are chosen PER VAULT at {newVault} time, so any creator can flex their
    // own stock and receive the commission in their own wallet. They are not immutable factory config.

    // ── Defaults for omitted launch params ──────────────────────────────────────

    uint32 internal constant DEFAULT_TOTAL_SEATS = 16;
    uint16 internal constant DEFAULT_TAX_RATE_BPS = 100; // 1% / week, within [10, 1000]
    /// @dev Hard cap on any vault's commission (audit v5 F8): flush() sends `balance*commissionBps/1e4`
    ///      to the treasury and the rest to the grid, so an unbounded cap (100%) could starve seat
    ///      holders of all yield. Capped at 10% so holders always keep >= 90% of every flush.
    uint16 internal constant MAX_COMMISSION_BPS = 1_000; // 10%

    /// @dev UGM `createGrid` bounds; a launch clamps each grid field into these so out-of-range
    ///      `vaultData` degrades to a valid grid instead of reverting.
    uint32 internal constant MIN_TOTAL_SEATS = 4;
    uint32 internal constant MAX_TOTAL_SEATS = 1024;
    uint16 internal constant MIN_TAX_RATE_BPS = 10;
    uint16 internal constant MAX_TAX_RATE_BPS = 1000;
    uint32 internal constant MAX_FORFEITURE_DURATION = 30 days;

    // ── Registry ────────────────────────────────────────────────────────────────

    /// @notice Per-vault launch record kept by this factory.
    struct VaultRecord {
        address vault;
        uint256 gridId;
        bytes32 assetHash;
        address settlementToken; // the stock this vault settles in (grid tax + yield token)
    }

    mapping(address => VaultRecord) public vaultInfo;
    address[] public allVaults;

    // ── Events ──────────────────────────────────────────────────────────────────

    event VaultCreated(address indexed vault, address indexed settlementToken, uint256 indexed gridId, bytes32 assetHash);
    event VaultAwaitingApproval(address indexed vault, uint256 indexed gridId, bytes32 assetHash);
    event CreatorRevenueSwept(uint256 indexed gridId, address indexed to, uint256 amount);

    // Per Rule 004 (UI-01) every revert uses a literal bilingual `require` string (no custom errors).

    // ── Construction ────────────────────────────────────────────────────────────

    /// @param ugm_                  Stockpile UnifiedGridManager address.
    /// @param defaultCommissionBps_ Default commission cap in bps (<= 10000), applied when a vault omits its own.
    constructor(address ugm_, uint16 defaultCommissionBps_) {
        require(ugm_ != address(0), unicode"Zero address / 零地址");
        // UGM must be a live contract; a codeless address would brick every vault's flush().
        require(ugm_.code.length > 0, unicode"UGM not a contract / UGM非合约");
        require(defaultCommissionBps_ <= MAX_COMMISSION_BPS, unicode"Commission too high / 佣金过高");

        ugm = ugm_;
        defaultCommissionBps = defaultCommissionBps_;

        StockpileVault impl = new StockpileVault();
        beacon = address(new UpgradeableBeacon(address(impl)));
    }

    // ── Create path (permissionless — see contract NatSpec) ─────────────────────

    /// @notice Create a grid (settled in `settlementToken`) + a {StockpileVault} proxy bound to it.
    /// @dev    PERMISSIONLESS. The caller (creator) then launches a token via `Portal.newTokenV6` with
    ///         the returned vault as the `beneficiary`. Both the settlement "stock" and the commission
    ///         recipient are chosen HERE, per vault, so any creator flexes their own stock + gets the
    ///         commission in their own wallet — the factory fixes neither.
    ///
    ///         The inherited V2 signature is `(address, address, address, bytes)`; on this path the params
    ///         are repurposed as `(settlementToken, treasury, unused, vaultData)`:
    ///           • `settlementToken` — the ERC20 "stock" the vault settles in AND the grid's tax/yield
    ///             token. Must be guardian-allowlisted on the UGM (else `createGrid` reverts "taxToken").
    ///           • `treasury`        — commission recipient; `address(0)` defaults to `msg.sender` (creator).
    ///           • 3rd param         — unused here.
    ///         `vaultData` is the ABI-encoded tuple from {vaultDataSchema}:
    ///         `(uint16 commissionBps, uint16 taxRateBps, uint256 totalSeats, uint256 forfeitureDuration,
    ///         uint256 initialPrice)`; every field is optional (0 => a sane default).
    /// @return vault The freshly deployed BeaconProxy vault (use it as the launch `beneficiary`).
    function newVault(address settlementToken, address treasury, address, /* unused */ bytes calldata vaultData)
        external
        override
        returns (address vault)
    {
        require(settlementToken != address(0), unicode"Zero settlement token / 结算代币为零");
        address commissionTo = treasury == address(0) ? msg.sender : treasury;

        // 1. Resolve grid params + commission (defaults applied) and create the grid in the stock token.
        (CreateGridParams memory p, uint16 comm) = _buildCreateParams(settlementToken, vaultData);
        uint256 gridId = IUGM(ugm).createGrid(p);

        // 2. Deploy the proxy first (empty init) so its address can seed `assetHash`.
        vault = address(new BeaconProxy(beacon, ""));

        // 3. Bind vault ⇄ grid.
        bytes32 assetHash = keccak256(abi.encode("StockpileVault", vault, gridId));

        // 4. Initialize the vault (settlementToken is both the grid tax + yield token; taxToken ref = 0).
        StockpileVault(payable(vault)).initialize(address(0), ugm, assetHash, settlementToken, comm, commissionTo);

        // 5. Record + announce. The vault is NOT yet flushable — see the approval bridge.
        vaultInfo[vault] =
            VaultRecord({vault: vault, gridId: gridId, assetHash: assetHash, settlementToken: settlementToken});
        allVaults.push(vault);

        emit VaultCreated(vault, settlementToken, gridId, assetHash);
        emit VaultAwaitingApproval(vault, gridId, assetHash);
    }

    /// @dev Decode `vaultData` (or fall back to defaults) into {CreateGridParams} + commission cap,
    ///      using `settlementToken` as the grid's tax + yield token.
    function _buildCreateParams(address settlementToken, bytes calldata vaultData)
        internal
        view
        returns (CreateGridParams memory p, uint16 comm)
    {
        uint16 commissionBps_;
        uint16 taxRateBps_;
        uint256 totalSeats_;
        uint256 forfeitureDuration_;
        uint256 initialPrice_;
        if (vaultData.length != 0) {
            (commissionBps_, taxRateBps_, totalSeats_, forfeitureDuration_, initialPrice_) =
                abi.decode(vaultData, (uint16, uint16, uint256, uint256, uint256));
        }

        if (commissionBps_ == 0) {
            comm = defaultCommissionBps;
        } else {
            comm = commissionBps_ > MAX_COMMISSION_BPS ? MAX_COMMISSION_BPS : commissionBps_;
        }

        uint32 seats;
        if (totalSeats_ == 0) {
            seats = DEFAULT_TOTAL_SEATS;
        } else {
            seats = _toU32(totalSeats_);
            if (seats < MIN_TOTAL_SEATS) seats = MIN_TOTAL_SEATS;
            else if (seats > MAX_TOTAL_SEATS) seats = MAX_TOTAL_SEATS;
        }

        uint16 taxRate;
        if (taxRateBps_ == 0) {
            taxRate = DEFAULT_TAX_RATE_BPS;
        } else {
            taxRate = taxRateBps_;
            if (taxRate < MIN_TAX_RATE_BPS) taxRate = MIN_TAX_RATE_BPS;
            else if (taxRate > MAX_TAX_RATE_BPS) taxRate = MAX_TAX_RATE_BPS;
        }

        uint32 fd = _toU32(forfeitureDuration_);
        if (fd > MAX_FORFEITURE_DURATION) fd = MAX_FORFEITURE_DURATION;

        p = CreateGridParams({
            totalSeats: seats,
            taxRateBps: taxRate,
            forfeitureDuration: fd,
            taxToken: settlementToken,
            yieldToken: settlementToken,
            initialPrice: _toU128(initialPrice_)
        });
    }

    // ── Approval-bridge visibility ──────────────────────────────────────────────

    /// @notice Whether `vault` still awaits the guardian's out-of-band wiring before it can `flush()`.
    /// @dev    Flushable exactly when the vault is the UGM's registered adapter for its `assetHash`.
    ///         Returns false for an unknown vault. Never reverts — safe to poll.
    function pendingApproval(address vault) external view returns (bool pending) {
        VaultRecord memory r = vaultInfo[vault];
        if (r.vault == address(0)) return false;
        pending = IUGM(ugm).assetAdapter(r.assetHash) != vault;
    }

    /// @notice Number of vaults this factory has created.
    function allVaultsLength() external view returns (uint256) {
        return allVaults.length;
    }

    // ── Beacon administration (Guardian-only) ───────────────────────────────────

    function upgradeVaultImplementation(address newImplementation) external {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        UpgradeableBeacon(beacon).upgradeTo(newImplementation);
    }

    function lockVaultUpgrades() external {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        UpgradeableBeacon(beacon).renounceOwnership();
    }

    function isVaultUpgradesLocked() external view returns (bool locked) {
        locked = UpgradeableBeacon(beacon).owner() == address(0);
    }

    function beaconImplementation() external view returns (address impl) {
        impl = UpgradeableBeacon(beacon).implementation();
    }

    // ── Creator-revenue rescue (Guardian-only) ──────────────────────────────────

    /// @notice Route otherwise-locked creator-side revenue (the factory is each grid's `creator`) to a beneficiary.
    /// @dev    Guardian-only. Creator-side flows accrue to `payouts[token][factory]`, claimable only by the
    ///         factory; this is the Guardian's route to forward it. Because settlement is per-vault, the grid's
    ///         stock `token` is supplied explicitly. Settles `seatIds` unsold-seat yield first (empty to skip),
    ///         pulls the full `token` payout to the factory, then forwards it to `to`.
    /// @param  gridId  The grid whose creator revenue is swept.
    /// @param  seatIds Unsold/creator seats to settle into payouts first (empty to skip).
    /// @param  token   The grid's settlement stock token to claim (its `vaultInfo(vault).settlementToken`).
    /// @param  to      Beneficiary that receives the swept `token` (non-zero).
    /// @return swept   Amount of `token` forwarded to `to`.
    function sweepCreatorRevenue(uint256 gridId, uint256[] calldata seatIds, address token, address to)
        external
        returns (uint256 swept)
    {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        require(token != address(0) && to != address(0), unicode"Zero address / 零地址");
        if (seatIds.length != 0) IUGM(ugm).claimYieldBatch(gridId, seatIds);
        swept = IUGM(ugm).claimPayout(token);
        if (swept != 0) IERC20(token).safeTransfer(to, swept);
        emit CreatorRevenueSwept(gridId, to, swept);
    }

    // ── Required V2 factory surface ─────────────────────────────────────────────

    /// @inheritdoc VaultFactoryBaseV2
    function factorySpecVersion() public pure override returns (string memory) {
        return "v3.0-stock";
    }

    /// @notice Vestigial on this factory: the stock quote is gated by Flap's Portal on the REGULAR
    ///         launch path, and this factory is never invoked by Flap's VaultPortal (Cách B). Kept only
    ///         to satisfy the inherited V2 interface; always returns true.
    function isQuoteTokenSupported(address /* quoteToken */ ) external pure override returns (bool supported) {
        supported = true;
    }

    /// @inheritdoc VaultFactoryBaseV2
    /// @dev Vestigial (see {isQuoteTokenSupported}); never called on the regular-launch path.
    function _validateBeforeLaunch(IVaultFactoryValidationV2.LaunchValidationDataV1 memory /* data */ )
        internal
        pure
        override
        returns (bool success, string memory reason)
    {
        return (true, "");
    }

    /// @notice No factory-enforced token-creation policies on the regular-launch path.
    function tokenCreationPolicies() public pure override returns (FactoryPolicy[] memory policies) {
        policies = new FactoryPolicy[](0);
    }

    /// @notice On-chain schema describing the `vaultData` tuple {newVault} decodes.
    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description =
            unicode"Create a StockpileVault that bridges a Flap token's ERC20 (stock) tax into a Stockpile Harberger "
            unicode"grid. Tax accrues on the vault as the stock settlement token; on flush() a commission is skimmed to "
            unicode"the treasury and the remainder is forwarded to the grid. Every field below is optional - leave any "
            unicode"at 0 to use the factory default."
            unicode" / 创建一个 StockpileVault，将 Flap 代币的 ERC20（stock）税收桥接到 Stockpile Harberger 网格。税收以 stock "
            unicode"结算代币形式在金库累积；flush() 时抽取佣金给国库，其余转发到网格。下面每个字段均为可选 - 保留为 0 即用工厂默认值。";
        schema.fields = new FieldDescriptor[](5);
        schema.fields[0] = FieldDescriptor(
            "commissionBps",
            "uint16",
            unicode"Commission cap, in basis points (bps), skimmed from each flush() to the treasury. 0 = factory default; 10000 = 100%."
            unicode" / 佣金上限，以基点（bps）计，每次 flush() 从中抽取给国库。0 = 工厂默认值；10000 = 100%。",
            0
        );
        schema.fields[1] = FieldDescriptor(
            "taxRateBps",
            "uint16",
            unicode"Weekly Harberger tax rate for the grid, in basis points (bps). Allowed 10-1000 (0.1%-10%/week). 0 = default 100 (1%/week)."
            unicode" / 网格每周 Harberger 税率，以基点（bps）计。允许 10-1000（每周 0.1%-10%）。0 = 默认 100（每周 1%）。",
            0
        );
        schema.fields[2] = FieldDescriptor(
            "totalSeats",
            "uint256",
            unicode"Number of seats created in the grid. Allowed 4-1024. 0 = factory default of 16."
            unicode" / 网格中创建的席位数量。允许 4-1024。0 = 工厂默认值 16。",
            0
        );
        schema.fields[3] = FieldDescriptor(
            "forfeitureDuration",
            "uint256",
            unicode"Dutch-auction price-decay window for a forfeited seat, in seconds. 0 = let the grid apply its own default."
            unicode" / 被没收席位的荷兰式拍卖价格衰减窗口，以秒计。0 = 让网格应用其默认值。",
            0
        );
        schema.fields[4] = FieldDescriptor(
            "initialPrice",
            "uint256",
            unicode"Uniform starting self-assessed price for every seat, denominated in the stock settlement token (18 decimals)."
            unicode" / 每个席位统一的初始自评价格，以 stock 结算代币计价（18 位小数）。",
            18
        );
        schema.isArray = false;
    }

    // ── Internal helpers ────────────────────────────────────────────────────────

    function _toU32(uint256 x) internal pure returns (uint32) {
        require(x <= type(uint32).max, unicode"Value exceeds uint32 / 数值超出 uint32");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(x);
    }

    function _toU128(uint256 x) internal pure returns (uint128) {
        require(x <= type(uint128).max, unicode"Value exceeds uint128 / 数值超出 uint128");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(x);
    }
}
