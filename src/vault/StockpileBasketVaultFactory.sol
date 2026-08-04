// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {IVaultFactoryValidationV2} from "./flap/IVaultFactory.sol";
import {VaultDataSchema, FieldDescriptor, FactoryPolicy} from "./flap/IVaultSchemasV1.sol";
import {StockpileBasketVaultV2} from "./StockpileBasketVaultV2.sol";
import {StockBasketDeployer} from "./StockBasketDeployer.sol";

import {BeaconProxy} from "@openzeppelin/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

/// @notice The `vaultData` payload {StockpileBasketVaultFactory.newVault} decodes. Its ABI encoding is a
///         single FLAT scalar tuple plus ONE opaque `bytes` tail, identical in field order/type to
///         {StockpileBasketVaultFactory.vaultDataSchema}, so a generic Flap UI `abi.encode((...))`
///         round-trips exactly through `abi.decode(vaultData, (VaultDataV1))` (Rule 002 — M1).
///
///         Every scalar is in the schema vocabulary {uint16,uint128,address,uint256,bytes}; the per-stock
///         configuration is carried entirely inside `stocksData`, which is itself
///         `abi.encode(address[] stocks, uint24[] stockFees, uint16[] swapWeights)` — three equal-length
///         parallel arrays (one entry per basket stock; `swapWeights` must sum to 10000). The vault decodes
///         `stocksData` LATER, in the permissionless `setupMarket()` (kept off the launch tx).
struct VaultDataV1 {
    uint16 gridSize;
    uint16 gridTaxRateBps;
    uint128 gridInitialPrice;
    uint16 commissionBps;
    address treasury;
    uint256 minInterval;
    bytes stocksData; // abi.encode(address[] stocks, uint24[] stockFees, uint16[] swapWeights)
}

/// @title StockpileBasketVaultFactory
/// @author The Stockpile Team
/// @notice Beacon-backed factory for {StockpileBasketVaultV2} proxies — the TRUE Flap vault-backed path.
///         Flap's `VaultPortal.newTokenV6WithVault` (native-BNB quote) calls {newVault} here to deploy a
///         per-token vault; the launched token's BNB tax is then dispatched to that vault. Each vault owns
///         its own {StockBasket} + one UGM grid, both built later by the permissionless
///         `StockpileBasketVaultV2.setupMarket()` (kept off the launch tx because the grid create is heavy).
///
/// @dev  ── UPGRADES / GUARDIAN ────────────────────────────────────────────────────
///
///   All vaults delegate to one {UpgradeableBeacon} owned by this factory. The chain Guardian
///   (`_getGuardian()`) is the SOLE upgrade authority: it may `upgradeVaultImplementation` or permanently
///   `lockVaultUpgrades`. No other account can upgrade the vaults or revoke the Guardian's authority
///   (Rule 001/002/009: for proxy vaults the Guardian-only upgrade path IS the emergency control).
///
///   Per Rule 004 (UI-01) every revert uses a literal **bilingual** `require` string (no custom errors).
contract StockpileBasketVaultFactory is VaultFactoryBaseV2 {
    // ── Immutable configuration ────────────────────────────────────────────────

    /// @notice Beacon holding the shared {StockpileBasketVaultV2} implementation.
    address public immutable beacon;
    /// @notice Wrapped BNB — the supported quote token's ERC20 form (fee still settles as native BNB).
    address public immutable wbnb;
    /// @notice USDT / BSC-USD — the shared stable hop (passed through to the impl).
    address public immutable usdt;
    /// @notice Stockpile UnifiedGridManager (grid sink) every vault creates its grid on.
    address public immutable ugm;
    /// @notice PancakeSwap V3 SwapRouter used by every vault's swaps.
    address public immutable swapRouter;
    /// @notice Fee tier of the shared WBNB→USDT first hop.
    uint24 public immutable wbnbUsdtFee;
    /// @notice Shared {StockBasketDeployer} the impl uses to deploy each vault's basket (EIP-170 headroom).
    address public immutable basketDeployer;

    // ── Registry ────────────────────────────────────────────────────────────────

    /// @notice All vaults this factory has created, in creation order.
    address[] public allVaults;
    /// @notice taxToken (predicted launch token) → its vault.
    mapping(address => address) public vaultOf;

    // ── Events ──────────────────────────────────────────────────────────────────

    event VaultCreated(address indexed vault, address indexed taxToken, address creator);

    // ── Construction ────────────────────────────────────────────────────────────

    /// @param _wbnb        Wrapped BNB address.
    /// @param _usdt        USDT / BSC-USD address.
    /// @param _ugm         Stockpile UnifiedGridManager address.
    /// @param _router      PancakeSwap V3 SwapRouter address.
    /// @param _fee         WBNB→USDT first-hop fee tier (e.g. 100).
    constructor(address _wbnb, address _usdt, address _ugm, address _router, uint24 _fee) {
        require(
            _wbnb != address(0) && _usdt != address(0) && _ugm != address(0) && _router != address(0),
            unicode"Zero address / 零地址"
        );
        // The UGM must be a live contract; a codeless address would brick every vault's setupMarket/distribute.
        require(_ugm.code.length > 0, unicode"UGM not a contract / UGM非合约");

        wbnb = _wbnb;
        usdt = _usdt;
        ugm = _ugm;
        swapRouter = _router;
        wbnbUsdtFee = _fee;

        address dep = address(new StockBasketDeployer());
        basketDeployer = dep;

        StockpileBasketVaultV2 impl = new StockpileBasketVaultV2(_wbnb, _usdt, _ugm, _router, _fee, dep);
        beacon = address(new UpgradeableBeacon(address(impl)));
    }

    // ── Create path (VaultPortal-gated — the true Flap vault-backed launch) ─────

    /// @notice Deploy + initialize a per-token {StockpileBasketVaultV2} BeaconProxy. Only callable by the
    ///         chain's Flap VaultPortal (the launch flow). The vault's basket + grid are NOT built here —
    ///         call the vault's permissionless `setupMarket()` after launch (the grid create is heavy).
    /// @param  taxToken  Predicted (not-yet-deployed) tax token — passed to the vault, never called (D18).
    /// @param  quoteToken The launch quote token (must be native BNB / WBNB — see {isQuoteTokenSupported}).
    /// @param  creator   The original launcher (recorded in the event; the vault is guardian-controlled).
    /// @param  vaultData ABI-encoded tuple — see {vaultDataSchema} for the field order/meanings.
    /// @return vault     The freshly deployed BeaconProxy vault.
    function newVault(address taxToken, address quoteToken, address creator, bytes calldata vaultData)
        external
        override
        returns (address vault)
    {
        require(msg.sender == _getVaultPortal(), unicode"Only VaultPortal / 仅限 VaultPortal 调用");
        require(isQuoteTokenSupported(quoteToken), unicode"Quote not supported / 报价代币不支持");

        // Decode into a single memory struct (identical ABI to the schema-encoded tuple) — keeps newVault
        // stack shallow (all fields via `d.`) and matches {vaultDataSchema}'s field order exactly (M1).
        // The per-stock config stays opaque here (`d.stocksData`): the vault validates + decodes it later
        // in the permissionless `setupMarket()` (the heavy basket/grid build is kept off the launch tx).
        VaultDataV1 memory d = abi.decode(vaultData, (VaultDataV1));

        vault = address(
            new BeaconProxy(
                beacon,
                abi.encodeCall(
                    StockpileBasketVaultV2.initialize,
                    (
                        taxToken,
                        d.gridSize,
                        d.gridTaxRateBps,
                        d.gridInitialPrice,
                        d.commissionBps,
                        d.treasury,
                        d.minInterval,
                        d.stocksData
                    )
                )
            )
        );

        allVaults.push(vault);
        vaultOf[taxToken] = vault;
        emit VaultCreated(vault, taxToken, creator);
    }

    /// @notice Whether `quoteToken` is accepted. This vault settles the fee as native BNB, encoded as
    ///         `address(0)`; WBNB is also accepted for launch pairings that denote the quote in ERC20 form.
    function isQuoteTokenSupported(address quoteToken) public view override returns (bool supported) {
        supported = quoteToken == address(0) || quoteToken == wbnb;
    }

    /// @notice Number of vaults this factory has created.
    function allVaultsLength() external view returns (uint256) {
        return allVaults.length;
    }

    // ── Beacon administration (Guardian-only — the SOLE upgrade authority) ──────

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

    // ── Required V2 factory surface ─────────────────────────────────────────────

    /// @notice Pre-launch validation: only a native-BNB (or WBNB) quote is supported.
    function _validateBeforeLaunch(IVaultFactoryValidationV2.LaunchValidationDataV1 memory data)
        internal
        view
        override
        returns (bool success, string memory reason)
    {
        if (data.quoteToken != address(0) && data.quoteToken != wbnb) {
            return (false, unicode"Quote token must be native BNB or WBNB / 报价代币必须为原生 BNB 或 WBNB");
        }
        return (true, "");
    }

    /// @notice No additional machine-readable token-creation policies.
    function tokenCreationPolicies() public pure override returns (FactoryPolicy[] memory policies) {
        policies = new FactoryPolicy[](0);
    }

    /// @notice On-chain schema describing the `vaultData` tuple {newVault} decodes.
    /// @dev    `vaultData` is a single FLAT ABI tuple that round-trips EXACTLY with
    ///         `abi.decode(vaultData, (VaultDataV1))` (Rule 002 — M1):
    ///         `(uint16 gridSize, uint16 gridTaxRateBps, uint128 gridInitialPrice, uint16 commissionBps,
    ///           address treasury, uint256 minInterval, bytes stocksData)`.
    ///         Every field is in the schema vocabulary {uint16,uint128,address,uint256,bytes}; the per-stock
    ///         configuration is the single opaque `stocksData` tail, itself
    ///         `abi.encode(address[] stocks, uint24[] stockFees, uint16[] swapWeights)` (equal-length
    ///         parallel arrays, one entry per stock; swapWeights must sum to 10000). `isArray` is false.
    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description =
            unicode"Create a per-token StockpileBasketVault that routes the launched token's native-BNB tax into a "
            unicode"basket of stock tokens, then into a Stockpile Harberger grid. stocksData is "
            unicode"abi.encode(address[] stocks, uint24[] stockFees, uint16[] swapWeights) — equal-length parallel "
            unicode"arrays (one entry per stock; each stock distinct and not WBNB/USDT); swapWeights must sum to "
            unicode"10000. After launch, call setupMarket() on the vault to deploy its basket + grid."
            unicode" / 创建每代币 StockpileBasketVault，将已发行代币的原生 BNB 税收路由到一篮子股票代币，再进入 Stockpile "
            unicode"Harberger 网格。stocksData 为 abi.encode(address[] stocks, uint24[] stockFees, uint16[] swapWeights)"
            unicode"—— 等长并行数组（每种股票一个，各不相同且非 WBNB/USDT）；swapWeights 之和须为 10000。"
            unicode"发行后，调用金库的 setupMarket() 部署其篮子和网格。";

        schema.fields = new FieldDescriptor[](7);
        schema.fields[0] = FieldDescriptor(
            "gridSize",
            "uint16",
            unicode"Number of seats in the vault's grid. Allowed 4-1024 (e.g. 36/100/144/256)."
            unicode" / 金库网格的席位数量。允许 4-1024（例如 36/100/144/256）。",
            0
        );
        schema.fields[1] = FieldDescriptor(
            "gridTaxRateBps",
            "uint16",
            unicode"Weekly Harberger tax rate for the grid, in basis points. Allowed 10-1000 (0.1%-10%/week)."
            unicode" / 网格每周 Harberger 税率，以基点计。允许 10-1000（每周 0.1%-10%）。",
            0
        );
        schema.fields[2] = FieldDescriptor(
            "gridInitialPrice",
            "uint128",
            unicode"Uniform starting self-assessed price for every seat (must be > 0), denominated in WBNB (18 decimals)."
            unicode" / 每个席位统一的初始自评价格（须 > 0），以 WBNB 计价（18 位小数）。",
            18
        );
        schema.fields[3] = FieldDescriptor(
            "commissionBps",
            "uint16",
            unicode"Commission cap, in basis points, skimmed from each distribute() to the treasury. Max 1000 (10%)."
            unicode" / 佣金上限，以基点计，每次 distribute() 从中抽取给国库。最高 1000（10%）。",
            0
        );
        schema.fields[4] = FieldDescriptor(
            "treasury",
            "address",
            unicode"Commission recipient (non-zero)."
            unicode" / 佣金接收地址（非零）。",
            0
        );
        schema.fields[5] = FieldDescriptor(
            "minInterval",
            "uint256",
            unicode"Minimum seconds between two successful distribute() calls. Max 2592000 (30 days)."
            unicode" / 两次成功 distribute() 之间的最小间隔秒数。最高 2592000（30 天）。",
            0
        );
        schema.fields[6] = FieldDescriptor(
            "stocksData",
            "bytes",
            unicode"abi.encode(address[] stocks, uint24[] stockFees, uint16[] swapWeights): equal-length parallel arrays "
            unicode"(one entry per stock; each distinct, not WBNB/USDT; swapWeights sum to 10000; max 20 stocks)."
            unicode" / abi.encode(address[] stocks, uint24[] stockFees, uint16[] swapWeights)：等长并行数组"
            unicode"（每种股票一个，各不相同、非 WBNB/USDT；swapWeights 总和 = 10000；最多 20 种股票）。",
            0
        );
        schema.isArray = false;
    }
}
