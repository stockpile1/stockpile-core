// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {
    VaultUISchema,
    VaultMethodSchema,
    FieldDescriptor,
    ApproveAction
} from "./flap/IVaultSchemasV1.sol";

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import {StockBasket} from "./StockBasket.sol";

// ──────────────────────────────────────────────────────────────────────────────
//  Minimal local interfaces + structs (ABI-mirror the real Stockpile UGM / router)
// ──────────────────────────────────────────────────────────────────────────────

/// @notice Grid-creation parameters. MUST mirror `libraries/GridTypes.sol::CreateGridParams`
///         field order and types EXACTLY — it is ABI-encoded into `createGrid`.
struct CreateGridParams {
    uint32 totalSeats; // seats to create, bounded [MIN_TOTAL_SEATS, MAX_SINGLE_TX_CREATE_TOTAL_SEATS]
    uint16 taxRateBps; // Harberger tax rate per week, in basis points [MIN_TAX_BPS, MAX_TAX_BPS]
    uint32 forfeitureDuration; // Dutch decay window (seconds); 0 => UGM applies its own default
    address taxToken; // token used for prices, deposits and tax (must be guardian-allowed on the UGM)
    address yieldToken; // token distributed to seat holders as yield (here: this vault's basket)
    uint128 initialPrice; // uniform starting price for every creator-owned seat
}

/// @notice Stockpile UnifiedGridManager (grid sink). The vault creates its OWN grid, registers as
///         its adapter, then forwards realized yield — BASKET shares — into it via `receiveYieldERC20`.
///         For `receiveYieldERC20` the caller MUST be the registered adapter for `assetHash`, the
///         pushed `token` MUST equal the grid's `yieldToken` (the basket), and the amount MUST be > 0.
interface IUGM {
    function createGrid(CreateGridParams calldata p) external returns (uint256 gridId);
    /// @notice Bind `assetHash` to `gridId` with the CALLER as its adapter. The UGM sets
    ///         `assetAdapter[assetHash] = msg.sender`, so the vault MUST call this itself
    ///         (see {registerWithGrid}) to become the adapter `receiveYieldERC20` accepts.
    function registerAsset(uint256 gridId, bytes32 assetHash) external;
    /// @notice Forward `amount` of `token` (the grid's yieldToken) to seat holders of `assetHash`'s grid.
    function receiveYieldERC20(bytes32 assetHash, address token, uint256 amount) external;
    /// @notice Withdraw the CALLER's accrued pull-based payouts in `token`. The vault is its own grid's
    ///         `creator`, so seat-sale proceeds, the creator share of settled Harberger tax and yield on
    ///         unsold/vacant seats all accrue to the vault here and MUST be pulled — see {claimGridPayout}.
    ///         Reverts ("nothing") when the balance is zero, so callers must tolerate that.
    function claimPayout(address token) external returns (uint256 amount);
}

/// @notice PancakeSwap V3 SwapRouter on BSC (0x1b81D678…). Uses the classic Uniswap V3
///         `exactInput` struct WITH a `deadline` field (the BSC router keeps it).
interface IV3SwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Wrapped BNB — `deposit()` wraps native BNB 1:1 into WBNB ERC20.
interface IWBNB {
    function deposit() external payable;
}

/// @notice A Flap tax token exposing a single weekly `taxRate()` in basis points. Probed
///         LAZILY (best-effort, behind a codeless-token guard — see {distribute} / D18) to size
///         the Flap-recommended commission; a token that lacks the getter is handled by `catch`.
interface ITaxToken {
    function taxRate() external view returns (uint256);
}

/// @notice Off-vault {StockBasket} deployer (keeps the vault runtime under EIP-170; see {StockBasketDeployer}).
interface IStockBasketDeployer {
    function deployBasket(string calldata name, string calldata symbol, address[] calldata stocks, address vault)
        external
        returns (address basket);
}

/// @title StockpileBasketVaultV2
/// @author The Stockpile Team
/// @notice Per-token, Flap-conforming ({VaultBaseV2}) BeaconProxy vault. Flap sets it as a launched
///         token's fee `marketAddress`; the token's BNB tax stream arrives as **native BNB**. A keeper
///         calls {distribute}, which wraps the BNB, skims the Flap-recommended commission, swaps the
///         remainder into a dynamic basket of "stock" tokens (each via a 2-hop PancakeSwap V3 route
///         through USDT), DEPOSITS the bought stocks into this vault's OWN {StockBasket} index token
///         (minting shares sized to the WBNB value spent), and forwards those shares into the vault's
///         OWN single Stockpile grid through the UnifiedGridManager (UGM). Seat holders redeem one
///         share for a pro-rata slice of ALL stocks at once.
///
/// @dev  ── ONE TOKEN → ONE VAULT → ONE BASKET → ONE GRID ─────────────────────────
///
///   Every proxy owns its own {StockBasket} (it is the sole `onlyVault` minter) and its own UGM grid
///   whose size is chosen at launch. Routing addresses (WBNB/USDT/UGM/router/fee) are impl-level
///   IMMUTABLES shared by every proxy through delegatecall; the per-proxy datum is the tax token, the
///   stock legs, the grid parameters, and the tunable commission/treasury/interval/keepers.
///
///   ── SPLIT INIT (gas): initialize is config-only; {setupMarket} builds the market ─
///
///   The real UGM's `createGrid` loops over every seat (up to 1024), so running it inside the Flap
///   launch transaction (VaultPortal → factory.newVault → initialize) could cost millions of gas and
///   abort the launch. {initialize} therefore only validates + stores config (cheap); the heavy
///   basket-deploy + grid-create runs in the separate, permissionless, idempotent {setupMarket}.
///
///   ── D18 (codeless tax token): NEVER call taxToken in initialize ────────────────
///
///   Flap creates+initializes the vault BEFORE deploying the address-predicted token, so at init the
///   `taxToken` is codeless — any high-level call to it reverts uncatchably and aborts the launch.
///   The tax rate is therefore read LAZILY inside {distribute}, behind an `if (taxToken.code.length>0)`
///   guard + `try/catch`, never at init.
///
///   Per Rule 004 (UI-01) every revert is a literal **bilingual** `require` string — no custom errors.
contract StockpileBasketVaultV2 is Initializable, VaultBaseV2, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // ── Constants ────────────────────────────────────────────────────────────

    /// @notice Hard cap on {commissionBps}: guarantees the commission can never exceed 10% of a
    ///         receipt, so seat holders always keep >= 90% of every distribute. Guardian may only lower it.
    uint16 public constant MAX_COMMISSION_BPS = 1_000; // 10%
    /// @notice Sanity ceiling on {minInterval} so a fat-fingered value cannot lock {distribute} forever.
    uint256 public constant MAX_MIN_INTERVAL = 30 days;
    /// @notice UGM grid-size bounds (mirror `UnifiedGridManager.MIN_TOTAL_SEATS` /
    ///         `MAX_SINGLE_TX_CREATE_TOTAL_SEATS`). A launch grid size must fall in this range.
    uint32 public constant MIN_TOTAL_SEATS = 4;
    uint32 public constant MAX_SINGLE_TX_CREATE_TOTAL_SEATS = 1_024;
    /// @notice UGM Harberger tax-rate bounds (mirror `MIN_TAX_BPS` / `MAX_TAX_BPS`).
    uint16 public constant MIN_TAX_BPS = 10;
    uint16 public constant MAX_TAX_BPS = 1_000;
    /// @notice Upper bound on the number of stock legs (L5): a launcher-chosen leg count that is too large
    ///         would gas-brick this vault's own `setupMarket` / `distribute` loops. Bounding it here keeps
    ///         both within a sane gas envelope (funds stay Guardian-recoverable regardless).
    uint256 public constant MAX_STOCKS = 20;

    // ── Routing immutables (set once in the constructor; shared by all proxies) ─

    /// @notice Wrapped BNB — the token the vault accrues (post-wrap) and the first hop of every swap.
    address public immutable wbnb;
    /// @notice USDT / BSC-USD — the shared stable hop every WBNB→stock route passes through.
    address public immutable usdt;
    /// @notice Stockpile UnifiedGridManager (grid sink) the vault creates its grid on + forwards yield to.
    address public immutable ugm;
    /// @notice PancakeSwap V3 SwapRouter used for the 2-hop `exactInput` swaps.
    address public immutable swapRouter;
    /// @notice Fee tier of the shared WBNB→USDT first hop (e.g. 100 = 0.01% on BSC mainnet).
    uint24 public immutable wbnbUsdtFee;
    /// @notice Off-vault {StockBasket} deployer (see {StockBasketDeployer}) — keeps this impl under EIP-170.
    address public immutable basketDeployer;

    // ── Per-leg configuration (set once in `initialize`) ─────────────────────

    /// @notice One stock leg: the target stock token bought via a 2-hop V3 route, the USDT→stock
    ///         fee tier, and the share of `net` allocated to buying it.
    struct StockLeg {
        address stock; // stock token bought (WBNB→USDT→stock) and deposited into the basket
        uint24 stockFee; // USDT→stock V3 fee tier (second hop)
        uint16 swapWeightBps; // share of `net` swapped into this stock (all legs sum to 10_000)
    }

    /// @dev The stock legs (dynamic). Read externally via {stockAt} / {stocksLength}. Built ONCE in
    ///      {setupMarket} by decoding {_stocksBlob}; empty between {initialize} and {setupMarket}.
    StockLeg[] private _stocks;

    /// @dev The opaque per-stock config carried through the Rule-002 schema (M1): the raw
    ///      `abi.encode(address[] stocks, uint24[] stockFees, uint16[] swapWeights)` bytes handed to
    ///      {initialize}. Decoded + validated + turned into {_stocks} LATER, in {setupMarket} (kept off the
    ///      launch tx). Stored verbatim; NEVER decoded in {initialize} (cheap-init invariant).
    bytes private _stocksBlob;

    // ── Per-proxy configuration (set in `initialize`) ────────────────────────

    /// @notice The Flap tax token whose native-BNB tax stream feeds this vault. STORED at init, never
    ///         called there (D18 — codeless at launch); its `taxRate()` is read lazily in {distribute}.
    address public taxToken;
    /// @notice Seats to create for this vault's grid (chosen at launch), in [MIN_TOTAL_SEATS, MAX_SINGLE_TX_CREATE_TOTAL_SEATS].
    uint32 public gridSize;
    /// @notice Weekly Harberger tax rate (bps) for this vault's grid, in [MIN_TAX_BPS, MAX_TAX_BPS].
    uint16 public gridTaxRateBps;
    /// @notice Uniform starting self-assessed price for every seat in this vault's grid.
    uint128 public gridInitialPrice;

    // ── Market (deployed once, in `setupMarket`) ─────────────────────────────

    /// @notice This vault's OWN {StockBasket} index token (the grid's single yield token). The vault is
    ///         its sole minter. Zero until {setupMarket}. Its stock order equals this vault's leg order.
    address public basket;
    /// @notice This vault's OWN UGM grid id. Zero until {setupMarket}.
    uint256 public gridId;
    /// @notice Canonical handle of this vault's grid asset, derived in {setupMarket}:
    ///         `keccak256(abi.encode("StockpileBasketVaultV2", vault, gridId))`.
    bytes32 public assetHash;

    // ── Mutable configuration (guardian-tunable) ─────────────────────────────

    /// @notice Commission cap skimmed from each {distribute}, in basis points. Capped at {MAX_COMMISSION_BPS};
    ///         the guardian may only ever LOWER it (see {setCommissionBps}). The actual skim is the smaller
    ///         of the Flap-recommended fee and this cap.
    uint16 public commissionBps;
    /// @notice Recipient of the WBNB commission skim.
    address public treasury;
    /// @notice Minimum seconds between two successful {distribute} calls (the keeper time-gate).
    uint256 public minInterval;
    /// @notice Block timestamp of the most recent successful {distribute} (0 until the first).
    uint256 public lastDistribute;
    /// @notice Allowlist of keepers permitted to call {distribute} (the Guardian is ALWAYS allowed —
    ///         Rule 001). Gates the slippage-bearing swap so an attacker cannot supply a zero floor.
    mapping(address => bool) public keepers;

    // ── Lazily-read tax rate (D18) ───────────────────────────────────────────

    /// @notice Last-read weekly tax rate (bps) of {taxToken}; 0 until a successful read. Drives the
    ///         Flap-recommended commission. Read lazily in {distribute} once the token has code.
    uint16 public taxRateBps;
    /// @notice True once {taxRateBps} has been successfully read from {taxToken} (a positive value).
    bool public taxRateKnown;

    // ── Upgrade storage gap (I2) ─────────────────────────────────────────────

    /// @dev Reserved storage so future beacon upgrades can append new state without shifting the layout of
    ///      any inheriting/adjacent slots. Sized to keep this contract's own declared storage on a round
    ///      50-slot budget; shrink `__gap` by exactly the number of slots any newly-added variables consume.
    uint256[43] private __gap;

    // ── Events ───────────────────────────────────────────────────────────────

    event Initialized(address indexed taxToken, uint32 gridSize, uint16 gridTaxRateBps, uint16 commissionBps);
    /// @notice Emitted once per stock leg at init (indexer-friendly view of the fixed basket).
    event StockLegConfigured(uint256 indexed legIndex, address stock, uint24 stockFee, uint16 swapWeightBps);
    /// @notice Emitted once when {setupMarket} deploys the basket + creates the grid.
    event MarketSetup(address indexed basket, uint256 indexed gridId, bytes32 assetHash);
    /// @notice Emitted on each successful {distribute}: gross WBNB consumed, commission skimmed, net,
    ///         WBNB actually swapped (excludes skipped legs), and basket shares minted + forwarded.
    event Distributed(
        address indexed caller, uint256 gross, uint256 commission, uint256 net, uint256 spentWBNB, uint256 basketMinted
    );
    /// @notice Emitted when a stock leg is skipped mid-{distribute} (dead pool, unreachable slippage floor,
    ///         or a stock that refuses the basket approval). Makes best-effort degradation OBSERVABLE:
    ///         without it an under-spent round is indistinguishable from a healthy one (AUDIT L-02).
    event LegSkipped(uint256 indexed legIndex, address indexed stock, uint256 amountIn, string phase);
    /// @notice Emitted when the grid push is skipped (grid not yet registered / paused / hijacked).
    event GridFeedFailed(bytes32 indexed assetHash, uint256 amount);
    /// @notice Emitted on {claimGridPayout}: creator-side grid revenue pulled from the UGM into the vault.
    event GridPayoutClaimed(address indexed token, uint256 amount);
    event KeeperSet(address indexed keeper, bool allowed);
    event CommissionSet(uint16 newBps);
    event TreasurySet(address indexed newTreasury);
    event MinIntervalSet(uint256 newInterval);
    event EmergencyWithdrawToken(address indexed token, address indexed to, uint256 amount);
    event EmergencyWithdrawNative(address indexed to, uint256 amount);

    // ── Modifiers ────────────────────────────────────────────────────────────

    /// @notice Restrict a call to the chain Guardian (fixed by the chain; never revocable — Rule 001).
    modifier onlyGuardian() {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        _;
    }

    /// @notice Restrict a call to an allowlisted keeper OR the Guardian (the Guardian is always a
    ///         permitted keeper — Rule 001 mandates Guardian access to every privileged function).
    modifier onlyKeeper() {
        require(
            keepers[msg.sender] || msg.sender == _getGuardian(), unicode"Not authorized keeper / 未授权的keeper"
        );
        _;
    }

    // ── Constructor (routing immutables + lock the bare impl) ─────────────────

    /// @notice Fix the shared routing addresses in the implementation bytecode and disable initializers
    ///         so the impl can never be initialized directly — only proxies pointing at it can.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _wbnb,
        address _usdt,
        address _ugm,
        address _swapRouter,
        uint24 _wbnbUsdtFee,
        address _basketDeployer
    ) {
        require(
            _wbnb != address(0) && _usdt != address(0) && _ugm != address(0) && _swapRouter != address(0)
                && _basketDeployer != address(0),
            unicode"Zero address / 零地址"
        );
        wbnb = _wbnb;
        usdt = _usdt;
        ugm = _ugm;
        swapRouter = _swapRouter;
        wbnbUsdtFee = _wbnbUsdtFee;
        basketDeployer = _basketDeployer;
        _disableInitializers();
    }

    // ── Initialize (config-only; NO taxToken call, NO heavy market build) ─────

    /// @notice Initialize a freshly deployed `BeaconProxy` of this vault with its per-token config.
    /// @dev    Cheap by design (see contract NatSpec): it validates + stores the SCALAR config and the
    ///         opaque per-stock `_stocksData` blob, and NEVER calls `_taxToken` (D18) nor decodes the blob.
    ///         The blob is decoded + validated and the basket + grid are built later in {setupMarket}.
    /// @param  _taxToken         Predicted tax token — STORED, never called (D18).
    /// @param  _gridSize         Seats for this vault's grid, in [MIN_TOTAL_SEATS, MAX_SINGLE_TX_CREATE_TOTAL_SEATS].
    /// @param  _gridTaxRateBps   Weekly Harberger tax rate (bps) for the grid, in [MIN_TAX_BPS, MAX_TAX_BPS].
    /// @param  _gridInitialPrice Uniform starting seat price for the grid (must be > 0 — L3).
    /// @param  _commissionBps    Commission cap in bps (<= {MAX_COMMISSION_BPS}).
    /// @param  _treasury         Commission recipient (non-zero).
    /// @param  _minInterval      Distribute time-gate in seconds (<= {MAX_MIN_INTERVAL}).
    /// @param  _stocksData       `abi.encode(address[] stocks, uint24[] stockFees, uint16[] swapWeights)`;
    ///                           STORED opaque here, decoded + validated in {setupMarket} (M1).
    function initialize(
        address _taxToken,
        uint16 _gridSize,
        uint16 _gridTaxRateBps,
        uint128 _gridInitialPrice,
        uint16 _commissionBps,
        address _treasury,
        uint256 _minInterval,
        bytes calldata _stocksData
    ) external initializer {
        __ReentrancyGuard_init();

        require(_treasury != address(0), unicode"Zero address / 零地址");
        require(_commissionBps <= MAX_COMMISSION_BPS, unicode"Commission too high / 佣金过高");
        require(_minInterval <= MAX_MIN_INTERVAL, unicode"Interval too long / 间隔过长");
        require(
            _gridSize >= MIN_TOTAL_SEATS && _gridSize <= MAX_SINGLE_TX_CREATE_TOTAL_SEATS,
            unicode"Bad grid size / 网格大小无效"
        );
        require(
            _gridTaxRateBps >= MIN_TAX_BPS && _gridTaxRateBps <= MAX_TAX_BPS,
            unicode"Bad grid tax rate / 网格税率无效"
        );
        // L3: a zero (or sub-UGM-minimum) initial price would make setupMarket's createGrid revert forever
        // with no setter to fix it, permanently bricking the vault. Reject it here at init.
        require(_gridInitialPrice > 0, unicode"Bad initial price / 初始价格无效");

        taxToken = _taxToken;
        gridSize = _gridSize;
        gridTaxRateBps = _gridTaxRateBps;
        gridInitialPrice = _gridInitialPrice;
        commissionBps = _commissionBps;
        treasury = _treasury;
        minInterval = _minInterval;
        _stocksBlob = _stocksData;

        emit Initialized(_taxToken, _gridSize, _gridTaxRateBps, _commissionBps);
    }

    // ── Market build (permissionless, idempotent, heavy — off the launch tx) ──

    /// @notice Decode the per-stock config, build this vault's stock legs, then deploy its OWN
    ///         {StockBasket} and create its OWN UGM grid. PERMISSIONLESS and one-shot (idempotent: reverts
    ///         once built). Heavy — the UGM's `createGrid` loops over every seat, and the leg validation is
    ///         O(n²) — so it is intentionally OUTSIDE the launch transaction (see contract NatSpec).
    /// @dev    Decodes {_stocksBlob} (`abi.encode(address[],uint24[],uint16[])`) and validates the legs:
    ///         equal-length arrays; non-empty; <= {MAX_STOCKS}; each stock non-zero, != wbnb/usdt, unique
    ///         (O(n²) dedup); weights sum to 10_000 (M1/L5). The basket's stock order is this leg order, so
    ///         {distribute}'s `amounts[]` lines up with `basket.deposit` positionally. The grid's `taxToken`
    ///         is WBNB (must be guardian-allowed on the UGM) and its `yieldToken` is the fresh basket.
    function setupMarket() external nonReentrant {
        require(basket == address(0), unicode"Market already set up / 市场已建立");

        // Decode + validate the per-stock config (opaque since init — M1), and build the leg set.
        (address[] memory stx, uint24[] memory fees, uint16[] memory weights) =
            abi.decode(_stocksBlob, (address[], uint24[], uint16[]));

        uint256 n = stx.length;
        require(n > 0, unicode"No stocks / 无股票");
        require(n == fees.length && n == weights.length, unicode"Bad stock arrays / 股票数组无效");
        require(n <= MAX_STOCKS, unicode"Too many stocks / 股票过多"); // L5

        address _wbnb = wbnb;
        address _usdt = usdt;
        address[] memory stockAddrs = new address[](n);
        uint256 weightSum;
        for (uint256 i = 0; i < n; i++) {
            address st = stx[i];
            require(st != address(0), unicode"Zero address / 零地址");
            require(st != _wbnb && st != _usdt, unicode"Stock cannot be wbnb/usdt / stock不能为wbnb或usdt");
            for (uint256 j = i + 1; j < n; j++) {
                require(st != stx[j], unicode"Duplicate stock / 股票重复");
            }
            _stocks.push(StockLeg({stock: st, stockFee: fees[i], swapWeightBps: weights[i]}));
            stockAddrs[i] = st;
            weightSum += weights[i];
            emit StockLegConfigured(i, st, fees[i], weights[i]);
        }
        require(weightSum == 10_000, unicode"Weights must sum to 10000 / 权重总和须为10000");

        // Deploy the basket via the off-vault helper (keeps this impl under EIP-170); the helper binds this
        // vault as the sole minter AND transfers ownership to it, so the vault owns + solely mints its basket.
        address b =
            IStockBasketDeployer(basketDeployer).deployBasket(unicode"Stockpile Basket Share", "SPBSK", stockAddrs, address(this));
        basket = b;

        CreateGridParams memory p = CreateGridParams({
            totalSeats: gridSize,
            taxRateBps: gridTaxRateBps,
            forfeitureDuration: 0,
            taxToken: wbnb,
            yieldToken: b,
            initialPrice: gridInitialPrice
        });
        uint256 gid = IUGM(ugm).createGrid(p);
        gridId = gid;
        assetHash = keccak256(abi.encode("StockpileBasketVaultV2", address(this), gid));

        emit MarketSetup(address(b), gid, assetHash);
    }

    // ── Native-BNB intake (THE fee path — Flap dispatches the fee as native BNB) ──

    /// @notice Accept the incoming fee. Flap dispatches the market portion to this vault as **native BNB**
    ///         (a plain value transfer). This hook is a cheap no-op so it can NEVER revert on a gas-limited
    ///         send (Rule 005): NO loops, NO external calls, NO delegatecall. The accrued BNB is wrapped to
    ///         WBNB later, inside {distribute}.
    receive() external payable {}

    // ── Views ────────────────────────────────────────────────────────────────

    /// @notice Fee currently accrued and awaiting {distribute} (gross of commission) — counts BOTH the
    ///         native BNB the vault holds AND any WBNB already on it. Never reverts — safe to poll.
    function pendingDistribute() external view returns (uint256) {
        return IERC20(wbnb).balanceOf(address(this)) + address(this).balance;
    }

    /// @notice The number of stock legs (== the basket's stock count).
    function stocksLength() external view returns (uint256) {
        return _stocks.length;
    }

    /// @notice Full configuration of stock leg `i`.
    function stockAt(uint256 i) external view returns (address stock, uint24 stockFee, uint16 swapWeightBps) {
        require(i < _stocks.length, unicode"Bad stock index / 无效股票索引");
        StockLeg storage l = _stocks[i];
        return (l.stock, l.stockFee, l.swapWeightBps);
    }

    /// @notice Whether {setupMarket} has run (basket + grid exist).
    function isMarketSetUp() external view returns (bool) {
        return basket != address(0);
    }

    // ── The money path ────────────────────────────────────────────────────────

    /// @notice Advanced keeper entrypoint: distribute with an EXPLICIT per-leg slippage floor. Wrap the
    ///         accrued native BNB, swap the net into the basket's stocks, deposit them (minting shares to the
    ///         vault), forward those shares into the vault's grid, and skim the Flap-recommended commission
    ///         proportional to what actually distributed. Keeper/Guardian-gated, time-gated, `nonReentrant`.
    /// @dev    NOT in {vaultUISchema} — its `uint256[] minOut` array cannot be expressed by the scalar
    ///         schema vocabulary (Rule 001, L2). The generic UI uses {distributeUniform}; bespoke keeper
    ///         tooling uses this to set a distinct floor per leg. Both share {_distribute}.
    /// @param  minOut   Per-stock-leg minimum stock out (slippage floor); one entry per stock leg.
    /// @param  deadline Unix timestamp after which the swaps revert (enforced by the router).
    /// @return basketMinted Basket shares minted and forwarded to the grid (0 if nothing swapped).
    function distribute(uint256[] calldata minOut, uint256 deadline)
        external
        onlyKeeper
        nonReentrant
        returns (uint256 basketMinted)
    {
        return _distribute(minOut, deadline);
    }

    /// @notice Schema-friendly keeper entrypoint: distribute with a SINGLE uniform per-leg slippage floor.
    ///         Applies `minOutPerLeg` to every stock leg, then runs the same distribute logic as
    ///         {distribute}. This is the write method in {vaultUISchema} (its scalar `minOut` IS expressible
    ///         by the schema vocabulary — Rule 001, L2). Keeper/Guardian-gated, time-gated, `nonReentrant`.
    /// @param  minOutPerLeg Minimum stock out applied UNIFORMLY to every leg (slippage floor).
    /// @param  deadline     Unix timestamp after which the swaps revert (enforced by the router).
    /// @return basketMinted Basket shares minted and forwarded to the grid (0 if nothing swapped).
    function distributeUniform(uint256 minOutPerLeg, uint256 deadline)
        external
        onlyKeeper
        nonReentrant
        returns (uint256 basketMinted)
    {
        uint256 n = _stocks.length;
        uint256[] memory minOut = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            minOut[i] = minOutPerLeg;
        }
        return _distribute(minOut, deadline);
    }

    /// @dev Shared distribute body for {distribute} / {distributeUniform}. Runs inside their `nonReentrant`
    ///      frame (it is `private`, not itself guarded).
    ///
    ///      CEI: the require-checks read state, {lastDistribute} is advanced BEFORE any external call, and
    ///      only then are the wrap/swap/deposit/skim/push interactions performed.
    ///
    ///      COMMISSION (Flap Rule 001, L1): the FULL commission the gross WOULD pay is computed up front via
    ///      {_commission} (`taxRateBps <= 100 ? gross*6/100 : gross*6/taxRateBps`, capped at
    ///      `gross*commissionBps/10000`; `taxRateBps` read LAZILY, D18-guarded, 0 => 6% branch). But the
    ///      ACTUAL skim is sized to `spentWBNB` AFTER the swaps (`grossCommission * spentWBNB / net`), so
    ///      WBNB retained from a skipped leg is NOT re-taxed each round — it is commissioned exactly once,
    ///      only when it is actually distributed. When every leg succeeds `spentWBNB == net` and the skim
    ///      equals `grossCommission` (unchanged behavior).
    ///
    ///      SWAP/GRID PHASES (best-effort): each swap leg and the grid push are isolated so a dead pool or
    ///      an unregistered/paused grid is SKIPPED, never bricking distribute. A skipped swap leg's WBNB is
    ///      retained for the next round; a skipped grid push leaves the basket shares on the vault.
    function _distribute(uint256[] memory minOut, uint256 deadline) private returns (uint256 basketMinted) {
        require(basket != address(0), unicode"Market not set up / 市场未建立");
        require(minOut.length == _stocks.length, unicode"minOut length mismatch / minOut长度不匹配");
        require(block.timestamp >= lastDistribute + minInterval, unicode"Too soon / 时间未到");

        address _wbnb = wbnb;

        // The Flap fee lands as NATIVE BNB (receive() accepted it cheaply). Wrap it here on the keeper's gas.
        {
            uint256 nativeBal = address(this).balance;
            if (nativeBal > 0) IWBNB(_wbnb).deposit{value: nativeBal}();
        }

        uint256 gross = IERC20(_wbnb).balanceOf(address(this));
        require(gross > 0, unicode"Nothing to distribute / 无可分配");

        // Full Flap-recommended commission the gross WOULD pay if every leg distributes; the ACTUAL skim is
        // sized to `spentWBNB` after the swaps (L1), so retained WBNB is never re-taxed round after round.
        // Read the tax rate lazily (D18). This must be computed BEFORE the swaps so the swap phase cannot
        // change `taxRateBps` mid-round.
        uint256 grossCommission = _commission(gross);
        uint256 net = gross - grossCommission;

        // SWAP PHASE → per-stock bought amounts, per-leg WBNB spend, and the total actually swapped.
        (uint256[] memory amounts, uint256[] memory legSpend, uint256 spentWBNB) = _swapAll(net, minOut, deadline);

        if (spentWBNB == 0) {
            // Dead-pool / all-slippage round: nothing bought. Leave net WBNB for next time and take NO
            // commission — the retained WBNB stays UNTAXED until it is actually distributed (L1). The
            // time-gate is deliberately NOT advanced (AUDIT M-01): a round that distributed nothing must not
            // burn the `minInterval` window, or one bad `minOut`/`deadline` would DoS distribute for up to
            // {MAX_MIN_INTERVAL}. Re-entry is already impossible — both callers hold `nonReentrant`.
            emit Distributed(msg.sender, gross, 0, net, 0, 0);
            return 0;
        }

        // ── Effects: advance the time-gate now that the round is productive. Safe to sequence after the
        //    swaps because {distribute} / {distributeUniform} both wrap this body in `nonReentrant`. ──
        lastDistribute = block.timestamp;

        // Commission proportional to the WBNB actually distributed this round (net > 0 here, since
        // spentWBNB > 0). When every leg succeeds, spentWBNB == net and commission == grossCommission. The
        // router was approved only `net`, so at most `net` WBNB left — the balance always covers the skim.
        uint256 commission = (grossCommission * spentWBNB) / net;
        if (commission > 0) IERC20(_wbnb).safeTransfer(treasury, commission);

        // BASKET PHASE: deposit the bought stocks; shares minted == the value of the legs that LAND (H-02).
        basketMinted = _depositToBasket(amounts, legSpend);

        // GRID PHASE: forward the minted shares (plus any backlog from a prior failed feed) into the grid.
        _feedGrid();

        emit Distributed(msg.sender, gross, commission, net, spentWBNB, basketMinted);
    }

    /// @dev The Flap-recommended commission (Rule 001) on a `gross` receipt: `taxRateBps <= 100 ? gross*6/100
    ///      : gross*6/taxRateBps`, capped at `gross * commissionBps / 10000`. The tax rate is read LAZILY
    ///      (D18-guarded) via {_currentTaxBps}; a codeless / getter-less token uses the 6% branch (still capped).
    function _commission(uint256 gross) private returns (uint256 commission) {
        uint256 taxBps = _currentTaxBps();
        uint256 flapFee = taxBps <= 100 ? (gross * 6) / 100 : (gross * 6) / taxBps;
        uint256 cap = (gross * commissionBps) / 10_000;
        commission = flapFee > cap ? cap : flapFee;
    }

    /// @dev Read the tax rate LAZILY behind the D18 codeless-token guard. Mutates {taxRateBps}/{taxRateKnown}
    ///      on the first successful read. Returns the bps to use for the commission formula (0 => 6% branch).
    function _currentTaxBps() private returns (uint256 bps) {
        if (taxRateKnown) return taxRateBps;
        address t = taxToken;
        if (t.code.length == 0) return 0; // D18: still codeless — try again next round
        try ITaxToken(t).taxRate() returns (uint256 r) {
            if (r > 0) {
                taxRateBps = r > type(uint16).max ? type(uint16).max : uint16(r);
                taxRateKnown = true;
                return taxRateBps;
            }
        } catch {}
        return 0;
    }

    /// @dev Split `net` WBNB across the stock legs (dust on the last leg) and swap each slice best-effort
    ///      via {swapLeg}. Approves the router once for the whole `net`, resets to 0 after.
    ///      Also returns the per-leg WBNB spend so {_depositToBasket} can size the basket mint to the value
    ///      that actually reaches the basket rather than to the whole round (AUDIT H-02).
    function _swapAll(uint256 net, uint256[] memory minOut, uint256 deadline)
        private
        returns (uint256[] memory amounts, uint256[] memory legSpend, uint256 spentWBNB)
    {
        uint256 n = _stocks.length;
        amounts = new uint256[](n);
        legSpend = new uint256[](n);

        IERC20(wbnb).forceApprove(swapRouter, net);

        uint256 allocated;
        for (uint256 i = 0; i < n; i++) {
            uint256 amountIn;
            if (i == n - 1) {
                amountIn = net - allocated; // last leg absorbs the rounding dust so sum(amountIn) == net
            } else {
                amountIn = (net * _stocks[i].swapWeightBps) / 10_000;
                allocated += amountIn;
            }
            if (amountIn == 0) continue;

            // Best-effort per leg: an isolated self-external-call lets a dead pool / unreachable minOut
            // revert ONLY that leg. The catch skips it (amounts[i] stays 0) and its WBNB is retained.
            try this.swapLeg(i, amountIn, minOut[i], deadline) returns (uint256 out) {
                amounts[i] = out;
                legSpend[i] = amountIn;
                spentWBNB += amountIn;
            } catch {
                /* leg failed (dead pool / slippage): skip; its WBNB stays for next distribute */
                emit LegSkipped(i, _stocks[i].stock, amountIn, "swap");
            }
        }

        IERC20(wbnb).forceApprove(swapRouter, 0);
    }

    /// @notice Swap `amountIn` WBNB into stock leg `i` via the 2-hop V3 route and return the measured
    ///         balance delta received. Invoked ONLY by {distribute} as an external self-call so each leg
    ///         gets an isolated, atomically-revertable sub-transaction. Gated to `msg.sender == this`.
    /// @dev    FoT-robust: returns the vault's ACTUAL post-swap balance delta, not the router's return.
    function swapLeg(uint256 i, uint256 amountIn, uint256 minOut, uint256 deadline) external returns (uint256 out) {
        require(msg.sender == address(this), unicode"Only self / 仅限自身");
        StockLeg storage leg = _stocks[i];

        bytes memory path = abi.encodePacked(wbnb, wbnbUsdtFee, usdt, leg.stockFee, leg.stock);

        uint256 balBefore = IERC20(leg.stock).balanceOf(address(this));
        IV3SwapRouter(swapRouter).exactInput(
            IV3SwapRouter.ExactInputParams({
                path: path,
                recipient: address(this),
                deadline: deadline,
                amountIn: amountIn,
                amountOutMinimum: minOut
            })
        );
        out = IERC20(leg.stock).balanceOf(address(this)) - balBefore;
        // No unbacked shares: a pool that consumes `amountIn` but returns 0 must NOT count as spent.
        require(out > 0, unicode"Zero swap output / 兑换输出为零");
    }

    /// @dev Deposit the bought stocks into the basket, minting shares sized to the value of the legs that
    ///      actually land (`legSpend[i]` per successful pull — AUDIT H-02).
    ///
    ///      DEPOSITS BALANCES, NOT THIS ROUND'S DELTAS (AUDIT L-03): each leg contributes its FULL vault
    ///      balance, so stock left behind by a previously-skipped pull is swept in on the next round
    ///      instead of being stranded until a Guardian rescue. Such residue arrives with `legSpend[i]`
    ///      covering only the current round, so it enters the basket unminted — it accrues to every holder
    ///      rather than being lost, mirroring how {_feedGrid} already sweeps a backlog of basket shares.
    ///
    ///      APPROVALS ARE ISOLATED (AUDIT M-05): a stock that permits `transfer` but reverts `approve`
    ///      (compliance tokens gating approvals by spender/owner) would otherwise revert the WHOLE
    ///      distribute here — after the swaps — and brick every subsequent round identically, defeating the
    ///      best-effort design that every other leg interaction on this path follows.
    function _depositToBasket(uint256[] memory amounts, uint256[] memory legSpend) private returns (uint256 minted) {
        address _basket = basket;
        uint256 n = _stocks.length;
        address[] memory stx = new address[](n);

        for (uint256 i = 0; i < n; i++) {
            stx[i] = _stocks[i].stock;
            amounts[i] = IERC20(stx[i]).balanceOf(address(this)); // L-03: sweep this round's buy + any residue
            if (amounts[i] == 0) continue;
            try this.approveStock(stx[i], _basket, amounts[i]) {}
            catch {
                // Un-approvable stock: drop the leg entirely so the basket neither pulls it nor credits it.
                emit LegSkipped(i, stx[i], legSpend[i], "approve");
                amounts[i] = 0;
                legSpend[i] = 0;
            }
        }

        minted = StockBasket(_basket).deposit(amounts, legSpend, address(this));

        for (uint256 i = 0; i < n; i++) {
            if (amounts[i] > 0) {
                try this.approveStock(stx[i], _basket, 0) {} catch { /* dangling allowance to our own basket */ }
            }
        }
    }

    /// @notice Self-gated approval helper for {_depositToBasket}'s isolated per-leg approvals (M-05).
    /// @dev    Callable ONLY by this contract, exactly like {swapLeg}; the self-gate makes it a no-op
    ///         attack surface for anyone else.
    function approveStock(address token, address spender, uint256 amount) external {
        require(msg.sender == address(this), unicode"Only self / 仅限自身");
        IERC20(token).forceApprove(spender, amount);
    }

    /// @dev Forward the vault's ENTIRE basket balance into the vault's single grid, BEST-EFFORT (I1): the
    ///      push is isolated in a try/catch so an unregistered / paused / hijacked grid is SKIPPED (the
    ///      shares stay as basket on the vault, recoverable via {emergencyWithdrawToken}) instead of bricking
    ///      distribute. Feeding the WHOLE balance (not just this round's mint) also sweeps any BACKLOG left
    ///      by a prior failed feed, so a transiently-broken grid self-heals on the next successful round.
    ///      Approves the UGM for the exact amount, resets to 0 after.
    function _feedGrid() private {
        address _basket = basket;
        address _ugm = ugm;
        uint256 bal = IERC20(_basket).balanceOf(address(this));
        if (bal == 0) return; // nothing to forward (and the UGM rejects a zero-amount push)
        IERC20(_basket).forceApprove(_ugm, bal);
        try IUGM(_ugm).receiveYieldERC20(assetHash, _basket, bal) {}
        catch {
            /* grid not yet registered / paused: shares stay as basket on the vault (recoverable) */
            emit GridFeedFailed(assetHash, bal);
        }
        IERC20(_basket).forceApprove(_ugm, 0);
    }

    // ── Grid creator revenue (permissionless) ─────────────────────────────────

    /// @notice Pull this vault's accrued creator-side grid revenue out of the UGM and into the vault.
    /// @dev    PERMISSIONLESS and idempotent. {setupMarket} calls `createGrid` from this vault, so the UGM
    ///         records the VAULT as the grid's `creator` and credits it — pull-based — with the creator
    ///         share of primary seat sales, of buyout fees, of Dutch-auction clearing, of every settled
    ///         Harberger tax payment, and with yield accrued on unsold / vacant seats. All of it is
    ///         withdrawable ONLY by the creator calling `claimPayout`, so without this function every last
    ///         unit of it was stranded in the UGM forever (AUDIT H-01) — `emergencyWithdrawToken` could not
    ///         reach it either, since it moves only tokens the vault already holds.
    ///
    ///         The UGM reverts ("nothing") on a zero balance, so the call is wrapped: a no-op claim returns
    ///         0 instead of reverting, keeping this safe to call speculatively from a keeper or a UI.
    ///
    ///         DESTINATION: claimed WBNB simply lands on the vault and is picked up as `gross` by the next
    ///         {distribute} — it flows onward to seat holders exactly like a fresh fee receipt. Claiming the
    ///         {basket} token is permitted too: those shares are re-forwarded to the grid by the next
    ///         {distribute}'s {_feedGrid}, which redistributes them across the grid's seats. Each such cycle
    ///         moves the unsold-seat portion closer to sold seats, so it converges rather than looping.
    /// @param  token The payout token to withdraw (typically the grid's `taxToken`, i.e. WBNB).
    /// @return amount The amount pulled in (0 if the UGM had nothing credited).
    function claimGridPayout(address token) external nonReentrant returns (uint256 amount) {
        require(basket != address(0), unicode"Market not set up / 市场未建立");
        require(token != address(0), unicode"Zero address / 零地址");
        try IUGM(ugm).claimPayout(token) returns (uint256 a) {
            amount = a;
        } catch {
            /* nothing credited yet: report 0 rather than reverting */
        }
        emit GridPayoutClaimed(token, amount);
    }

    // ── Grid adapter binding (permissionless) ─────────────────────────────────

    /// @notice Bind this vault as the UGM adapter for its grid so {distribute} can deliver its basket shares.
    /// @dev    PERMISSIONLESS one-shot binding. Calls `ugm.registerAsset(gridId, assetHash)`, which sets the
    ///         UGM's `assetAdapter[assetHash]` to THIS vault (the `msg.sender` of that call) — the exact
    ///         identity `receiveYieldERC20` checks. Requires the Stockpile guardian to have first approved
    ///         this vault via `ugm.setApprovedAdapter(vault, true)`. Until bound, {distribute}'s grid push
    ///         best-effort-skips, so nothing bricks.
    function registerWithGrid() external nonReentrant {
        require(basket != address(0), unicode"Market not set up / 市场未建立");
        IUGM(ugm).registerAsset(gridId, assetHash);
    }

    // ── Guardian controls (Guardian-only; never on the receive path) ──────────

    /// @notice Add or remove a {distribute} keeper. The Guardian is always allowed and need not be listed.
    function setKeeper(address keeper, bool allowed) external onlyGuardian {
        require(keeper != address(0), unicode"Zero address / 零地址");
        keepers[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @notice Lower the commission cap. The Guardian can NEVER raise it — `newBps` must be `<=` the
    ///         current {commissionBps} (and thus always `<= {MAX_COMMISSION_BPS}`).
    function setCommissionBps(uint16 newBps) external onlyGuardian {
        require(newBps <= commissionBps, unicode"Fee can only decrease / 费用只能降低");
        commissionBps = newBps;
        emit CommissionSet(newBps);
    }

    /// @notice Change the commission recipient.
    function setTreasury(address newTreasury) external onlyGuardian {
        require(newTreasury != address(0), unicode"Zero address / 零地址");
        treasury = newTreasury;
        emit TreasurySet(newTreasury);
    }

    /// @notice Change the {distribute} time-gate.
    function setMinInterval(uint256 newInterval) external onlyGuardian {
        require(newInterval <= MAX_MIN_INTERVAL, unicode"Interval too long / 间隔过长");
        minInterval = newInterval;
        emit MinIntervalSet(newInterval);
    }

    /// @notice Guardian escape hatch to recover any ERC-20 held by the vault (incl. WBNB, a stock, or
    ///         basket shares). Drains the FULL balance to `to`.
    function emergencyWithdrawToken(address token, address to) external onlyGuardian nonReentrant {
        require(token != address(0) && to != address(0), unicode"Zero address / 零地址");
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(to, bal);
            emit EmergencyWithdrawToken(token, to, bal);
        }
    }

    /// @notice Guardian escape hatch to recover native BNB. Drains the FULL balance to `to`.
    function emergencyWithdrawNative(address to) external onlyGuardian nonReentrant {
        require(to != address(0), unicode"Zero address / 零地址");
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok,) = to.call{value: bal}("");
            require(ok, unicode"Native transfer failed / 原生转账失败");
            emit EmergencyWithdrawNative(to, bal);
        }
    }

    // ── Metadata / UI schema ──────────────────────────────────────────────────

    /// @notice Legacy status string. The UI relies on {vaultUISchema} for rendering.
    function description() public view override returns (string memory) {
        if (basket == address(0)) {
            return unicode"StockpileBasketVault: awaiting setupMarket() to deploy its basket + grid."
                unicode" / StockpileBasketVault：等待 setupMarket() 部署其篮子和网格。";
        }
        return unicode"StockpileBasketVault: routes a Flap token's BNB tax into a stock basket, then into a Stockpile grid. Call distribute() to swap + forward."
            unicode" / StockpileBasketVault：将 Flap 代币的 BNB 税收路由到股票篮子，再进入 Stockpile 网格。调用 distribute() 兑换并转发。";
    }

    /// @notice On-chain UI schema describing this vault's runtime actions.
    /// @dev    Four reads + the single keeper write:
    ///           • pendingDistribute (read)  — BNB/WBNB accrued, awaiting distribute.
    ///           • commissionBps     (read)  — commission cap skimmed to the treasury (bps).
    ///           • basket            (read)  — the vault's StockBasket index token.
    ///           • gridId            (read)  — the vault's UGM grid id.
    ///           • distributeUniform (write) — swap + deposit + forward, scalar (uniform) slippage floor.
    ///                                         No ApproveAction (vault custodies). Rule 001 (L2): the schema
    ///                                         vocabulary is scalar-only, so the array-input {distribute} is
    ///                                         NOT surfaced here — bespoke keepers call it directly.
    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "StockpileBasketVault";
        schema.description =
            unicode"Per-token vault that routes a Flap token's native-BNB tax into a basket of stock tokens, then "
            unicode"into a Stockpile Harberger grid. BNB accrues on the vault; a keeper calls distribute() to skim "
            unicode"the commission, swap the rest into the stocks, mint basket shares, and forward them to the grid "
            unicode"where seat holders earn them."
            unicode" / 每代币金库，将 Flap 代币的原生 BNB 税收路由到一篮子股票代币，再进入 Stockpile Harberger 网格。BNB "
            unicode"在金库累积；keeper 调用 distribute() 抽取佣金、将其余兑换为股票、铸造篮子份额并转发到网格，供席位持有者赚取。";

        schema.methods = new VaultMethodSchema[](5);

        // Read: pendingDistribute() — the actionable live number driving distribute().
        schema.methods[0].name = "pendingDistribute";
        schema.methods[0].description =
            unicode"BNB/WBNB currently accrued on the vault, awaiting distribute() into the basket + grid."
            unicode" / 当前在金库累积、等待通过 distribute() 进入篮子和网格的 BNB/WBNB。";
        schema.methods[0].inputs = new FieldDescriptor[](0);
        schema.methods[0].outputs = new FieldDescriptor[](1);
        schema.methods[0].outputs[0] =
            FieldDescriptor("pending", "uint256", unicode"Pending BNB/WBNB awaiting distribute() / 等待 distribute() 的待处理 BNB/WBNB", 18);
        schema.methods[0].approvals = new ApproveAction[](0);

        // Read: commissionBps() — the commission cap skimmed to the treasury.
        schema.methods[1].name = "commissionBps";
        schema.methods[1].description =
            unicode"Commission cap skimmed from each distribute() to the treasury, in basis points (100 = 1%)."
            unicode" / 每次 distribute() 抽取给国库的佣金上限，以基点计（100 = 1%）。";
        schema.methods[1].inputs = new FieldDescriptor[](0);
        schema.methods[1].outputs = new FieldDescriptor[](1);
        schema.methods[1].outputs[0] =
            FieldDescriptor("commissionBps", "uint16", unicode"Commission cap in basis points / 佣金上限（基点）", 0);
        schema.methods[1].approvals = new ApproveAction[](0);

        // Read: basket() — the vault's StockBasket index token.
        schema.methods[2].name = "basket";
        schema.methods[2].description =
            unicode"The vault's StockBasket index token — the grid's single yield token; redeems for a pro-rata slice of every stock."
            unicode" / 金库的 StockBasket 指数代币 —— 网格的唯一收益代币；可按比例赎回每种股票。";
        schema.methods[2].inputs = new FieldDescriptor[](0);
        schema.methods[2].outputs = new FieldDescriptor[](1);
        schema.methods[2].outputs[0] =
            FieldDescriptor("basket", "address", unicode"StockBasket token address / StockBasket 代币地址", 0);
        schema.methods[2].approvals = new ApproveAction[](0);

        // Read: gridId() — the vault's UGM grid id.
        schema.methods[3].name = "gridId";
        schema.methods[3].description =
            unicode"The UGM grid id this vault feeds; seat holders of this grid earn the basket shares."
            unicode" / 本金库供给的 UGM 网格 id；该网格的席位持有者赚取篮子份额。";
        schema.methods[3].inputs = new FieldDescriptor[](0);
        schema.methods[3].outputs = new FieldDescriptor[](1);
        schema.methods[3].outputs[0] =
            FieldDescriptor("gridId", "uint256", unicode"UGM grid id / UGM 网格 id", 0);
        schema.methods[3].approvals = new ApproveAction[](0);

        // Write: distributeUniform(uint256 minOutPerLeg, uint256 deadline) — keeper/guardian gated; no
        // approvals. Scalar minOut (Rule 001, L2): the array-input distribute() is not schema-expressible.
        schema.methods[4].name = "distributeUniform";
        schema.methods[4].description =
            unicode"Wrap accrued BNB, swap the net into the basket's stocks, mint basket shares, forward them into the grid, and skim the commission proportional to what distributed. Applies ONE uniform slippage floor to every stock leg. Keeper- or Guardian-gated and time-gated."
            unicode" / 包装累积的 BNB、将净额兑换为篮子股票、铸造篮子份额并转发到网格，并按实际分配比例抽取佣金。对每个股票腿应用同一个滑点下限。仅限 keeper 或 Guardian 调用，并有时间间隔限制。";
        schema.methods[4].inputs = new FieldDescriptor[](2);
        schema.methods[4].inputs[0] =
            FieldDescriptor("minOutPerLeg", "uint256", unicode"Uniform minimum output amount applied to every stock leg (slippage floor) / 应用于每个股票腿的统一最小输出数量（滑点下限）", 18);
        schema.methods[4].inputs[1] =
            FieldDescriptor("deadline", "time", unicode"Unix timestamp after which the swaps revert / 兑换在此 Unix 时间戳后回退", 0);
        schema.methods[4].outputs = new FieldDescriptor[](0);
        schema.methods[4].approvals = new ApproveAction[](0);
        schema.methods[4].isWriteMethod = true;
    }
}
