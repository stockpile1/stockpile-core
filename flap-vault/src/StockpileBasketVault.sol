// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

// ──────────────────────────────────────────────────────────────────────────────
//  Minimal local interfaces
// ──────────────────────────────────────────────────────────────────────────────

/// @notice Immutable-after-creation configuration of a UGM grid. Field order + types
///         replicate `contracts/core/src/libraries/GridTypes.sol` EXACTLY so
///         `IGridSink.gridConfig` ABI-decodes cleanly against the real
///         UnifiedGridManager (`gridConfig(uint256) returns (GridConfig)`). This vault
///         reads `yieldToken` (the registration-time assert) and `totalSeats` (the
///         seat-proportional grid split in {distribute}); the other fields are carried
///         solely to keep the struct layout identical.
struct GridConfig {
    address creator; // grid creator; owns initial seats, tax-exempt yield
    uint64 createdAt; // creation timestamp
    uint32 totalSeats; // number of seats — the weight of each grid in the {distribute} split
    uint16 taxRateBps; // Harberger tax rate per week, in basis points
    uint32 forfeitureDuration; // Dutch-auction decay window for forfeited seats, in seconds
    address taxToken; // token used for prices, deposits and tax
    address yieldToken; // token distributed to seat holders as yield (here: the basket share token)
}

/// @notice Stockpile grid sink (UnifiedGridManager). The vault forwards realized yield
///         — here BASKET shares — into a grid via `receiveYieldERC20`. The caller MUST be
///         the registered adapter for `assetHash`, the pushed `token` MUST equal the grid's
///         `yieldToken` (the basket), and the amount MUST be > 0 — the UGM reverts otherwise.
interface IGridSink {
    function receiveYieldERC20(bytes32 assetHash, address token, uint256 amount) external;
    /// @notice Bind `assetHash` to `gridId` with the CALLER as its adapter. The UGM sets
    ///         `assetAdapter[assetHash] = msg.sender`, so the vault MUST call this itself
    ///         (see {registerWithGrid}) to become the adapter `receiveYieldERC20` accepts.
    function registerAsset(uint256 gridId, bytes32 assetHash) external;
    /// @notice Immutable configuration of `gridId`. Read in {registerWithGrid} to assert the
    ///         grid's `yieldToken` equals the basket BEFORE binding, and in {distribute} to
    ///         read `totalSeats` for the seat-proportional split.
    function gridConfig(uint256 gridId) external view returns (GridConfig memory);
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

/// @notice The StockBasket index token. The vault is its sole minter: it swaps WBNB into the
///         basket's underlying stocks, {deposit}s them (minting shares to itself), then forwards
///         those shares into the grids. `deposit` pulls exactly `amounts[i]` of each stock — in
///         the basket's OWN stock order — so the vault's stock order MUST equal the basket's.
interface IStockBasket {
    function deposit(uint256[] calldata amounts, uint256 sharesToMint, address to) external returns (uint256 minted);
    function getStocks() external view returns (address[] memory);
    function stocksLength() external view returns (uint256);
}

/// @title StockpileBasketVault
/// @author The Stockpile Team
/// @notice Standalone (non-upgradeable) vault that is set as the fee `marketAddress` of a Flap
///         token (quote = WBNB), so it accrues the token's fee revenue. A keeper periodically
///         calls {distribute}, which skims a capped commission, swaps the accrued balance into a
///         dynamic set of "stock" tokens (each via a 2-hop PancakeSwap V3 route through USDT),
///         DEPOSITS the bought stocks into a single {StockBasket} index token (minting shares
///         sized to the WBNB value spent), and forwards those basket shares into a dynamic set of
///         Stockpile grids — SEAT-PROPORTIONALLY — through the UnifiedGridManager (UGM). Every
///         grid therefore pays out the SAME yield token (the basket), and a seat holder redeems
///         one share for a pro-rata slice of ALL stocks at once.
///
/// @dev  ── HOW THE FEE ARRIVES: NATIVE BNB ───────────────────────────────────────
///
///   Although the token's `quoteToken` is WBNB (for pricing/pairing), Flap settles the tax and
///   DISPATCHES the market portion to this vault (its `marketAddress`) as **native BNB** — a plain
///   value transfer — NOT as a WBNB ERC20 transfer. The {receive} hook therefore just accepts the
///   BNB cheaply (it can never revert on a gas-limited send); {distribute} wraps the accrued BNB to
///   WBNB on the keeper's gas before swapping. WBNB sent directly is also consumed.
///
///   ── FLOW ─────────────────────────────────────────────────────────────────────
///
///   1. Native BNB (the fee) accrues on `address(this)`; {receive} just accepts it.
///   2. A keeper calls {distribute} (time-gated by {minInterval}): it wraps the BNB, skims the
///      commission to the {treasury}, splits the remainder by per-stock `swapWeightBps`, swaps each
///      slice WBNB→USDT→stock on PancakeSwap V3, deposits the bought stocks into the basket (minting
///      `spentWBNB` shares to the vault), then forwards those shares into the grids seat-proportionally.
///
///   ── TWO DYNAMIC LISTS ────────────────────────────────────────────────────────
///
///   • `stocks` (StockLeg[]): the tokens the WBNB is swapped into. `swapWeightBps` across all stocks
///     MUST sum to 10_000, and the list order MUST equal the basket's stock order (the deposit pulls
///     `amounts[]` positionally). Fixed at construction.
///   • `grids` (GridLeg[]): the grids fed the basket shares. Their split weight is each grid's live
///     `totalSeats`. Fixed at construction; each `assetHash` is DERIVED, not supplied.
///
///   ── TRUST MODEL ──────────────────────────────────────────────────────────────
///
///   The deployer is the guardian ({owner}); it may only ever *lower* the commission, change the
///   treasury, tune the time-gate, manage the {keepers} allowlist, and use the emergency escape
///   hatches. The stock legs, grid legs, the basket, and every routing address are fixed at
///   construction and immutable in effect. {distribute} is keeper-gated ({owner} + {keepers});
///   {registerWithGrid}/{registerAllGrids} are permissionless.
///
///   Per Rule 004 (UI-01), reverts use literal **bilingual** `require` strings — never custom
///   errors — so the generic Flap UI can render the reason as-is.
contract StockpileBasketVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Constants ────────────────────────────────────────────────────────────

    /// @notice Hard cap on {commissionBps}: guarantees {distribute} always routes at least 90% of
    ///         every receipt into the grids. The guardian may only lower the fee.
    uint16 public constant MAX_COMMISSION_BPS = 1_000; // 10%

    /// @notice Sanity ceiling on {minInterval} so a fat-fingered value cannot lock {distribute}
    ///         forever. 30 days is far above any sensible keeper cadence.
    uint256 public constant MAX_MIN_INTERVAL = 30 days;

    // ── Routing immutables (set once in the constructor) ─────────────────────

    /// @notice Wrapped BNB — the token the vault accrues and the first hop of every swap.
    address public immutable wbnb;
    /// @notice USDT / BSC-USD — the shared stable hop every WBNB→stock route passes through.
    address public immutable usdt;
    /// @notice Stockpile UnifiedGridManager (grid sink) the vault forwards basket shares to.
    address public immutable ugm;
    /// @notice PancakeSwap V3 SwapRouter used for the 2-hop `exactInput` swaps.
    address public immutable swapRouter;
    /// @notice Fee tier of the shared WBNB→USDT first hop (100 = 0.01% on BSC mainnet).
    uint24 public immutable wbnbUsdtFee;
    /// @notice The {StockBasket} index token — the SINGLE yield token every grid pays out. The
    ///         vault is its sole minter. Its stock order MUST equal this vault's `stocks` order.
    address public immutable basket;

    // ── Per-leg configuration (set once in the constructor) ──────────────────

    /// @notice One stock leg: the target stock token bought via a 2-hop V3 route, the USDT→stock
    ///         fee tier, and the share of `net` allocated to buying it.
    struct StockLeg {
        address stock; // stock token bought (WBNB→USDT→stock) and deposited into the basket
        uint24 stockFee; // USDT→stock V3 fee tier (second hop)
        uint16 swapWeightBps; // share of `net` swapped into this stock (all legs sum to 10_000)
    }

    /// @notice One grid leg: the UGM grid fed basket shares, and its derived `assetHash`.
    struct GridLeg {
        uint256 gridId; // UGM grid id fed basket shares as yield
        bytes32 assetHash; // keccak256(abi.encode("StockpileBasketVault", address(this), gridId))
    }

    /// @dev The stock legs (dynamic). Read externally via {stockAt} / {stocksLength}. Fixed at construction.
    StockLeg[] private _stocks;
    /// @dev The grid legs (dynamic). Read externally via {gridAt} / {gridsLength} / {getGridIds}. Fixed at construction.
    GridLeg[] private _grids;

    // ── Mutable configuration (guardian-tunable) ─────────────────────────────

    /// @notice Commission skimmed from each {distribute}, in basis points. Capped at {MAX_COMMISSION_BPS};
    ///         the guardian may only ever LOWER it (see {setCommissionBps}).
    uint16 public commissionBps;
    /// @notice Recipient of the WBNB commission skim.
    address public treasury;
    /// @notice Minimum seconds between two successful {distribute} calls (the keeper time-gate).
    uint256 public minInterval;
    /// @notice Block timestamp of the most recent successful {distribute} (0 until the first).
    uint256 public lastDistribute;
    /// @notice Allowlist of keepers permitted to call {distribute} (in addition to the {owner}, who is
    ///         always allowed). Gates the swap so an attacker cannot be the caller supplying a zero
    ///         slippage floor and sandwich the pools. The guardian owns this list.
    mapping(address => bool) public keepers;

    // ── Events ───────────────────────────────────────────────────────────────

    /// @notice Emitted once at construction with the immutable routing + initial mutable config.
    event Configured(
        address wbnb,
        address usdt,
        address ugm,
        address swapRouter,
        uint24 wbnbUsdtFee,
        address basket,
        address treasury,
        uint16 commissionBps,
        uint256 minInterval
    );
    /// @notice Emitted once per stock leg at construction (indexer-friendly view of the fixed basket).
    event StockLegConfigured(uint256 indexed legIndex, address stock, uint24 stockFee, uint16 swapWeightBps);
    /// @notice Emitted once per grid leg at construction.
    event GridLegConfigured(uint256 indexed legIndex, uint256 gridId, bytes32 assetHash);
    /// @notice Emitted on each successful {distribute}: gross WBNB consumed, commission skimmed, net,
    ///         the WBNB actually swapped (excludes skipped legs), and the basket shares minted+forwarded.
    event Distributed(
        address indexed caller, uint256 gross, uint256 commission, uint256 net, uint256 spentWBNB, uint256 basketMinted
    );
    /// @notice Emitted when the guardian adds or removes a {distribute} keeper.
    event KeeperSet(address indexed keeper, bool allowed);
    /// @notice Emitted when the guardian lowers the commission.
    event CommissionSet(uint16 newBps);
    /// @notice Emitted when the guardian changes the treasury.
    event TreasurySet(address indexed newTreasury);
    /// @notice Emitted when the guardian changes the distribute time-gate.
    event MinIntervalSet(uint256 newInterval);
    /// @notice Emitted for a guardian ERC-20 escape-hatch sweep.
    event EmergencyWithdrawToken(address indexed token, address indexed to, uint256 amount);
    /// @notice Emitted for a guardian native-BNB escape-hatch sweep.
    event EmergencyWithdrawNative(address indexed to, uint256 amount);

    // ── Modifiers ────────────────────────────────────────────────────────────────

    /// @notice Restrict a call to the {owner} (always allowed) or an allowlisted {keepers} address.
    modifier onlyKeeper() {
        require(msg.sender == owner() || keepers[msg.sender], unicode"Not authorized keeper / 未授权的keeper");
        _;
    }

    // ── Constructor ────────────────────────────────────────────────────────────

    /// @notice Wire the vault to its routing addresses and fix its stock/grid legs + basket. The
    ///         deployer becomes the guardian ({owner}).
    /// @dev    Each grid's `assetHash` is DERIVED here as
    ///         `keccak256(abi.encode("StockpileBasketVault", address(this), gridId))` — never taken as
    ///         input, so it is cryptographically bound to this vault and its grid. The stock legs'
    ///         `swapWeightBps` MUST sum to 10_000, and the vault's stock ORDER MUST equal the basket's
    ///         stock order (deposit pulls `amounts[]` positionally). Heavy validation is delegated to
    ///         {_initStocks}/{_initGrids} to keep the constructor within the stack limit.
    /// @param  _wbnb          Wrapped BNB (accrued token + first swap hop).
    /// @param  _usdt          USDT / BSC-USD (shared stable hop).
    /// @param  _ugm           Stockpile UnifiedGridManager (grid sink).
    /// @param  _swapRouter    PancakeSwap V3 SwapRouter.
    /// @param  _wbnbUsdtFee   WBNB→USDT first-hop fee tier (e.g. 100).
    /// @param  _basket        The StockBasket index token (deployed first; its stock order is matched here).
    /// @param  _treasury      Commission recipient.
    /// @param  _commissionBps Initial commission in bps (<= {MAX_COMMISSION_BPS}).
    /// @param  _minInterval   Initial distribute time-gate in seconds (<= {MAX_MIN_INTERVAL}).
    /// @param  _stocks        The stock legs (non-empty; each stock non-zero, != wbnb/usdt, unique;
    ///                        `swapWeightBps` sum to 10_000; order == basket's stock order).
    /// @param  _gridIds       The grid ids to feed (non-empty; each non-zero and unique).
    constructor(
        address _wbnb,
        address _usdt,
        address _ugm,
        address _swapRouter,
        uint24 _wbnbUsdtFee,
        address _basket,
        address _treasury,
        uint16 _commissionBps,
        uint256 _minInterval,
        StockLeg[] memory _stocks,
        uint256[] memory _gridIds
    ) {
        require(
            _wbnb != address(0) && _usdt != address(0) && _ugm != address(0) && _swapRouter != address(0)
                && _basket != address(0) && _treasury != address(0),
            unicode"Zero address / 零地址"
        );
        require(_commissionBps <= MAX_COMMISSION_BPS, unicode"Commission too high / 佣金过高");
        require(_minInterval <= MAX_MIN_INTERVAL, unicode"Interval too long / 间隔过长");

        wbnb = _wbnb;
        usdt = _usdt;
        ugm = _ugm;
        swapRouter = _swapRouter;
        wbnbUsdtFee = _wbnbUsdtFee;
        basket = _basket;

        treasury = _treasury;
        commissionBps = _commissionBps;
        minInterval = _minInterval;

        // Delegate the per-leg validation + storage to private helpers so the constructor's live-local
        // count stays within the (non-via-ir) stack limit. Immutables are passed in (they cannot be
        // READ during construction).
        _initStocks(_stocks, _wbnb, _usdt, _basket);
        _initGrids(_gridIds);

        emit Configured(
            _wbnb, _usdt, _ugm, _swapRouter, _wbnbUsdtFee, _basket, _treasury, _commissionBps, _minInterval
        );
    }

    /// @dev Validate + store the stock legs. Enforces: non-empty; the vault's stock set matches the
    ///      basket's (same length AND same positional order, so {distribute}'s `amounts[]` lines up with
    ///      `basket.deposit`); each stock non-zero, != wbnb, != usdt, and unique; weights sum to 10_000.
    function _initStocks(StockLeg[] memory stx, address _wbnb, address _usdt, address _basket) private {
        uint256 n = stx.length;
        require(n > 0, unicode"No stocks / 无股票");
        // The basket pulls `amounts[i]` of its OWN i-th stock, so the vault's leg order MUST equal the
        // basket's stock order (else deposits credit the wrong reserve).
        require(IStockBasket(_basket).stocksLength() == n, unicode"Basket stock mismatch / 篮子股票不匹配");
        address[] memory basketStocks = IStockBasket(_basket).getStocks();

        uint256 weightSum;
        for (uint256 i = 0; i < n; i++) {
            address st = stx[i].stock;
            require(st != address(0), unicode"Zero address / 零地址");
            // A stock that is WBNB or USDT would make a degenerate WBNB→USDT→WBNB / …→USDT→USDT path
            // that reverts in the router or burns value to fees.
            require(st != _wbnb && st != _usdt, unicode"Stock cannot be wbnb/usdt / stock不能为wbnb或usdt");
            // Uniqueness is checked BEFORE the basket-order match so a duplicated leg fails as a
            // "Duplicate stock" (the basket itself forbids duplicates, so a matching basket could never
            // exist for a dup leg — this keeps the dedicated revert reachable and defensive).
            for (uint256 j = i + 1; j < n; j++) {
                require(st != stx[j].stock, unicode"Duplicate stock / 股票重复");
            }
            require(basketStocks[i] == st, unicode"Basket stock mismatch / 篮子股票不匹配");

            _stocks.push(stx[i]);
            weightSum += stx[i].swapWeightBps;
            emit StockLegConfigured(i, st, stx[i].stockFee, stx[i].swapWeightBps);
        }
        require(weightSum == 10_000, unicode"Weights must sum to 10000 / 权重总和须为10000");
    }

    /// @dev Validate + store the grid legs. Enforces: non-empty; each id non-zero and unique (duplicate
    ///      ids collide their (vault, gridId)-derived assetHash). Derives each `assetHash`.
    function _initGrids(uint256[] memory gridIds) private {
        uint256 g = gridIds.length;
        require(g > 0, unicode"No grids / 无网格");
        for (uint256 i = 0; i < g; i++) {
            uint256 gid = gridIds[i];
            require(gid != 0, unicode"Zero grid / 网格为零");
            for (uint256 j = i + 1; j < g; j++) {
                require(gid != gridIds[j], unicode"Duplicate grid / 网格重复");
            }
            bytes32 assetHash = keccak256(abi.encode("StockpileBasketVault", address(this), gid));
            _grids.push(GridLeg({gridId: gid, assetHash: assetHash}));
            emit GridLegConfigured(i, gid, assetHash);
        }
    }

    // ── Native-BNB intake (THE fee path — Flap dispatches the fee as native BNB) ──

    /// @notice Accept the incoming fee. Flap dispatches the market portion to this vault as **native
    ///         BNB** (a plain value transfer). This hook is deliberately a cheap no-op so it can NEVER
    ///         revert on a gas-limited send: the accrued BNB is wrapped to WBNB later, inside
    ///         {distribute}. WBNB transferred directly is ALSO consumed there.
    receive() external payable {}

    // ── Views ──────────────────────────────────────────────────────────────────

    /// @notice Fee currently accrued and awaiting {distribute} (gross of commission) — counts BOTH the
    ///         native BNB the vault holds AND any WBNB already on it, since {distribute} wraps the native
    ///         BNB before swapping. Never reverts — safe for the UI/keeper to poll.
    function pendingDistribute() external view returns (uint256) {
        return IERC20(wbnb).balanceOf(address(this)) + address(this).balance;
    }

    /// @notice The number of stock legs.
    function stocksLength() external view returns (uint256) {
        return _stocks.length;
    }

    /// @notice The number of grid legs.
    function gridsLength() external view returns (uint256) {
        return _grids.length;
    }

    /// @notice Full configuration of stock leg `i`.
    /// @param  i Leg index in `[0, {stocksLength})`.
    /// @return stock         Stock token bought and deposited into the basket.
    /// @return stockFee      USDT→stock V3 fee tier (second hop).
    /// @return swapWeightBps Share of `net` swapped into this stock, in bps.
    function stockAt(uint256 i) external view returns (address stock, uint24 stockFee, uint16 swapWeightBps) {
        require(i < _stocks.length, unicode"Bad stock index / 无效股票索引");
        StockLeg storage l = _stocks[i];
        return (l.stock, l.stockFee, l.swapWeightBps);
    }

    /// @notice Full configuration of grid leg `i`.
    /// @param  i Leg index in `[0, {gridsLength})`.
    /// @return gridId    UGM grid id fed basket shares.
    /// @return assetHash Derived grid asset handle (`keccak256(abi.encode("StockpileBasketVault", vault, gridId))`).
    function gridAt(uint256 i) external view returns (uint256 gridId, bytes32 assetHash) {
        require(i < _grids.length, unicode"Bad grid index / 无效网格索引");
        GridLeg storage l = _grids[i];
        return (l.gridId, l.assetHash);
    }

    /// @notice The full ordered list of grid ids fed by this vault.
    function getGridIds() external view returns (uint256[] memory ids) {
        uint256 g = _grids.length;
        ids = new uint256[](g);
        for (uint256 i = 0; i < g; i++) {
            ids[i] = _grids[i].gridId;
        }
    }

    // ── The money path ──────────────────────────────────────────────────────────

    /// @notice Skim the commission, swap the accrued WBNB into the basket's stocks, deposit them into
    ///         the basket (minting shares to the vault), then forward those shares into the grids
    ///         seat-proportionally. Time-gated by {minInterval}, keeper-gated, and `nonReentrant`.
    ///
    /// @dev    Sequencing is strict CEI: the require-checks read state, {lastDistribute} is advanced
    ///         BEFORE any external call, and only then are transfers/swaps/deposits/pushes performed.
    ///
    ///         SWAP PHASE (best-effort, {swapLeg}): WBNB is split by `swapWeightBps` with the rounding
    ///         dust of the split placed on the LAST leg so `sum(amountIn) == net`. Each leg swaps via
    ///         its own atomic self-call, so a leg that reverts (dead pool, unreachable `minOut[i]`) is
    ///         skipped — its `amounts[i]` stays 0 and its WBNB is retained for the next distribute —
    ///         while healthy legs still deliver. `spentWBNB` sums the amountIn of the non-reverting legs.
    ///
    ///         BASKET PHASE: the bought stocks are deposited into the basket, minting `spentWBNB` shares
    ///         to the vault (share count == WBNB value spent — the basket's oracle-free fairness anchor).
    ///
    ///         GRID PHASE (best-effort per grid, S6): the minted shares are split across the grids by
    ///         each grid's live `totalSeats`, dust on the last grid. Each push is isolated in a try/catch,
    ///         so a failing / hijacked / paused grid is skipped (its share stays as basket on the vault,
    ///         recoverable via {emergencyWithdrawToken} or the next round) instead of bricking distribute
    ///         for ALL grids — the sum actually pushed may therefore be < basketMinted.
    ///
    ///         COMMISSION (S1): computed on the gross but SKIMMED only AFTER the swap phase, sized to what
    ///         was actually distributed (`grossCommission * spentWBNB / net`). WBNB retained from
    ///         best-effort-skipped legs is therefore never re-taxed on a later round — each WBNB is taxed
    ///         exactly once, only when it is actually distributed. When every leg succeeds the skim equals
    ///         `gross * commissionBps / 10_000` (unchanged behavior).
    ///
    ///         If NO leg swapped (`spentWBNB == 0`), the vault deposits/forwards nothing, takes NO
    ///         commission, and returns 0; the WBNB stays UNTAXED for the next distribute.
    ///
    /// @param  minOut   Per-stock-leg minimum stock out (slippage protection); paired with the stock legs.
    /// @param  deadline Unix timestamp after which the swaps revert (enforced by the router).
    /// @return basketMinted Basket shares minted and forwarded to the grids (0 if nothing swapped).
    function distribute(uint256[] calldata minOut, uint256 deadline)
        external
        onlyKeeper
        nonReentrant
        returns (uint256 basketMinted)
    {
        require(minOut.length == _stocks.length, unicode"minOut length mismatch / minOut长度不匹配");
        require(block.timestamp >= lastDistribute + minInterval, unicode"Too soon / 时间未到");

        address _wbnb = wbnb;
        // The Flap fee lands as NATIVE BNB (receive() accepted it cheaply). Wrap the accrued BNB to WBNB
        // here — on the keeper's gas. `nonReentrant` guards this; IWBNB.deposit is a trusted call.
        uint256 nativeBal = address(this).balance;
        if (nativeBal > 0) IWBNB(_wbnb).deposit{value: nativeBal}();

        uint256 gross = IERC20(_wbnb).balanceOf(address(this));
        require(gross > 0, unicode"Nothing to distribute / 无可分配");

        // Full commission the gross WOULD pay if every leg distributes; the ACTUAL skim is sized to
        // `spentWBNB` after the swaps (S1), so retained WBNB is never taxed until it is distributed.
        uint256 grossCommission = (gross * commissionBps) / 10_000;
        uint256 net = gross - grossCommission;

        // ── Effects: advance the time-gate BEFORE any external interaction (CEI). ──
        lastDistribute = block.timestamp;

        // SWAP PHASE → per-stock bought amounts + total WBNB actually swapped (spentWBNB <= net).
        (uint256[] memory amounts, uint256 spentWBNB) = _swapAll(net, minOut, deadline);

        // If nothing swapped, leave the WBNB for next time (a dead pool / all-slippage round) and take
        // NO commission — the retained WBNB stays untaxed until it is actually distributed.
        if (spentWBNB == 0) {
            emit Distributed(msg.sender, gross, 0, net, 0, 0);
            return 0;
        }

        // Commission proportional to the WBNB actually distributed this round (net > 0 here, since
        // spentWBNB > 0). When every leg succeeds, spentWBNB == net and commission == grossCommission
        // (unchanged behavior). The vault's WBNB balance is always >= commission after the swaps (the
        // router was approved only `net`, so at most `net` WBNB left), so the transfer never underflows.
        uint256 commission = (grossCommission * spentWBNB) / net;
        if (commission > 0) {
            IERC20(_wbnb).safeTransfer(treasury, commission);
        }

        // BASKET PHASE: deposit the bought stocks, mint `spentWBNB` shares to the vault.
        basketMinted = _depositToBasket(amounts, spentWBNB);

        // GRID PHASE: forward the minted shares to the grids, seat-proportionally (best-effort per grid).
        _feedGrids(basketMinted);

        emit Distributed(msg.sender, gross, commission, net, spentWBNB, basketMinted);
    }

    /// @dev Split `net` WBNB across the stock legs (dust on the last leg) and swap each slice
    ///      best-effort via {swapLeg}. Approves the router once for the whole `net`, resets to 0 after.
    /// @return amounts    Per-stock bought amount (0 for a skipped/failed leg), positionally paired with `_stocks`.
    /// @return spentWBNB  Sum of the amountIn of the legs whose swap did NOT revert (== basket shares to mint).
    function _swapAll(uint256 net, uint256[] calldata minOut, uint256 deadline)
        private
        returns (uint256[] memory amounts, uint256 spentWBNB)
    {
        uint256 n = _stocks.length;
        amounts = new uint256[](n);

        IERC20(wbnb).forceApprove(swapRouter, net);

        uint256 allocated; // running sum of amountIn assigned to prior legs (weight, pre-swap)
        for (uint256 i = 0; i < n; i++) {
            uint256 amountIn;
            if (i == n - 1) {
                // Dust: the last leg absorbs the remainder so sum(amountIn) == net exactly.
                amountIn = net - allocated;
            } else {
                amountIn = (net * _stocks[i].swapWeightBps) / 10_000;
                allocated += amountIn;
            }
            if (amountIn == 0) continue;

            // Best-effort per leg: a self-external-call gives each leg its own atomic sub-transaction,
            // so a dead pool / unreachable minOut reverts ONLY that leg. The catch skips it (amounts[i]
            // stays 0) and, because the swap rolled back, its WBNB is retained for the next distribute.
            try this.swapLeg(i, amountIn, minOut[i], deadline) returns (uint256 out) {
                amounts[i] = out;
                spentWBNB += amountIn;
            } catch {
                /* leg failed (dead pool / slippage): skip; its WBNB stays for next distribute */
            }
        }

        // Reset the router allowance so no dangling approval survives the call.
        IERC20(wbnb).forceApprove(swapRouter, 0);
    }

    /// @notice Swap `amountIn` WBNB into stock leg `i` via the 2-hop V3 route and return the measured
    ///         balance delta received. Invoked ONLY by {distribute} as an external self-call
    ///         (`this.swapLeg`) so each leg gets an isolated, atomically-revertable sub-transaction.
    ///         MUST NOT be `nonReentrant` (it is reached from inside the `nonReentrant` {distribute}); it
    ///         is instead gated to `msg.sender == address(this)`.
    /// @dev    FoT-robust: returns the vault's ACTUAL post-swap balance delta, not the router's returned
    ///         value, so a fee-on-transfer output token is credited its true received amount downstream.
    ///         The router allowance is granted by {distribute} (once, over the batch).
    /// @return out Stock actually received by the vault (0 if the swap netted nothing).
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
        // No unbacked shares (S5): a pool that consumes `amountIn` but returns 0 (possible when
        // minOut==0) must NOT mint shares for WBNB that bought nothing. Revert so {_swapAll} catches the
        // leg, rolls back its swap (WBNB retained), and excludes its amountIn from `spentWBNB`.
        require(out > 0, unicode"Zero swap output / 兑换输出为零");
    }

    /// @dev Deposit the bought stocks into the basket, minting `spentWBNB` shares to the vault. Approves
    ///      the basket per non-zero leg, deposits (which pulls exactly `amounts[i]` in the basket's stock
    ///      order), then resets those approvals to 0. `amounts` length == `_stocks` length (zeros for
    ///      skipped legs); the basket tolerates the zero pulls.
    /// @return minted The basket shares minted (== `spentWBNB`).
    function _depositToBasket(uint256[] memory amounts, uint256 spentWBNB) private returns (uint256 minted) {
        address _basket = basket;
        uint256 n = amounts.length;

        for (uint256 i = 0; i < n; i++) {
            if (amounts[i] > 0) {
                IERC20(_stocks[i].stock).forceApprove(_basket, amounts[i]);
            }
        }

        minted = IStockBasket(_basket).deposit(amounts, spentWBNB, address(this));

        // Reset the per-stock approvals (deposit pulled exactly amounts[i]; belt-and-braces).
        for (uint256 i = 0; i < n; i++) {
            if (amounts[i] > 0) {
                IERC20(_stocks[i].stock).forceApprove(_basket, 0);
            }
        }
    }

    /// @dev Forward `basketMinted` basket shares to the grids, split by each grid's live `totalSeats`
    ///      (dust on the last grid). BEST-EFFORT per grid (S6): each push is isolated in a try/catch via
    ///      the self-gated {_pushGrid}, so a failing / hijacked / paused grid is SKIPPED — its basket
    ///      share stays on the vault (recoverable via {emergencyWithdrawToken} or the next {distribute}) —
    ///      instead of bricking distribute for ALL grids. The sum actually pushed may therefore be
    ///      < basketMinted (leftover basket sits on the vault). Approves the UGM once for the whole
    ///      `basketMinted`, resets to 0 after (any un-consumed allowance from skipped grids is cleared).
    function _feedGrids(uint256 basketMinted) private {
        address _basket = basket;
        address _ugm = ugm;
        uint256 g = _grids.length;

        // Read each grid's seats and the total (the split denominator).
        uint256[] memory seats = new uint256[](g);
        uint256 totalSeats;
        for (uint256 j = 0; j < g; j++) {
            uint256 s = IGridSink(_ugm).gridConfig(_grids[j].gridId).totalSeats;
            seats[j] = s;
            totalSeats += s;
        }
        require(totalSeats > 0, unicode"No seats / 无座位");

        IERC20(_basket).forceApprove(_ugm, basketMinted);

        uint256 allocated; // running sum of shares assigned to prior grids
        for (uint256 j = 0; j < g; j++) {
            if (seats[j] == 0) continue; // hygiene: a zero-seat grid earns nothing
            uint256 share;
            if (j == g - 1) {
                // The last grid absorbs the remainder (dust + any skipped zero-share grids) so the full
                // basketMinted is forwarded when the push succeeds.
                share = basketMinted - allocated;
            } else {
                share = (basketMinted * seats[j]) / totalSeats;
                allocated += share;
            }
            if (share == 0) continue;
            // Best-effort per grid: a self-external-call gives each push its own atomically-revertable
            // sub-transaction, so a failing / hijacked / paused grid is skipped (its share stays as basket
            // on the vault) instead of reverting the whole distribute for every grid.
            try this._pushGrid(_grids[j].assetHash, share) {}
            catch {
                /* skip: this grid's share stays as basket on the vault (recoverable next round) */
            }
        }

        IERC20(_basket).forceApprove(_ugm, 0);
    }

    /// @notice Push `amount` basket shares into the grid identified by `assetHash`. Invoked ONLY by
    ///         {_feedGrids} as an external self-call (`this._pushGrid`) so each grid push gets an isolated,
    ///         atomically-revertable sub-transaction for the best-effort try/catch (S6).
    /// @dev    MUST NOT be `nonReentrant` (it is reached from inside the `nonReentrant` {distribute}); it
    ///         is instead gated to `msg.sender == address(this)`. Pushes `basket` (the grid's yieldToken)
    ///         via the UGM's `receiveYieldERC20`, which pulls it under the allowance {_feedGrids} granted.
    function _pushGrid(bytes32 assetHash, uint256 amount) external {
        require(msg.sender == address(this), unicode"Only self / 仅限自身");
        IGridSink(ugm).receiveYieldERC20(assetHash, basket, amount);
    }

    // ── Grid adapter binding (permissionless) ────────────────────────────────────

    /// @notice Bind this vault as the UGM adapter for grid leg `gridIndex` so {distribute} can deliver
    ///         its basket shares.
    /// @dev    PERMISSIONLESS one-shot binding. Calls `ugm.registerAsset(gridId, assetHash)`, which sets
    ///         the UGM's `assetAdapter[assetHash]` to THIS vault (the `msg.sender` of that call) — the
    ///         exact identity `receiveYieldERC20` checks. The vault MUST perform the registration itself.
    ///         Fails a misconfigured deploy HERE, not silently at the first distribute: the UGM's
    ///         `receiveYieldERC20` requires the pushed token == the grid's yieldToken, so a grid whose
    ///         yieldToken != the basket could never accept its yield.
    /// @param  gridIndex Leg index in `[0, {gridsLength})`.
    function registerWithGrid(uint256 gridIndex) external nonReentrant {
        require(gridIndex < _grids.length, unicode"Bad grid index / 无效网格索引");
        GridLeg storage leg = _grids[gridIndex];
        require(
            IGridSink(ugm).gridConfig(leg.gridId).yieldToken == basket,
            unicode"Grid yieldToken must be basket / 网格收益代币须为篮子"
        );
        IGridSink(ugm).registerAsset(leg.gridId, leg.assetHash);
    }

    /// @notice Convenience: bind all grid legs in one call.
    /// @dev    All-or-nothing — reverts (at the UGM) if ANY leg is already registered or the vault is not
    ///         yet an approved adapter. Use {registerWithGrid} per-leg when some legs are already bound.
    function registerAllGrids() external nonReentrant {
        uint256 g = _grids.length;
        address _basket = basket;
        address _ugm = ugm;
        for (uint256 j = 0; j < g; j++) {
            GridLeg storage leg = _grids[j];
            require(
                IGridSink(_ugm).gridConfig(leg.gridId).yieldToken == _basket,
                unicode"Grid yieldToken must be basket / 网格收益代币须为篮子"
            );
            IGridSink(_ugm).registerAsset(leg.gridId, leg.assetHash);
        }
    }

    // ── Guardian controls (owner-only) ───────────────────────────────────────────

    /// @notice Add or remove a {distribute} keeper. The {owner} is always allowed and need not be listed.
    /// @param  keeper  Keeper address to toggle (non-zero).
    /// @param  allowed True to allow, false to revoke.
    function setKeeper(address keeper, bool allowed) external onlyOwner {
        require(keeper != address(0), unicode"Zero address / 零地址");
        keepers[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @notice Disabled: renouncing ownership would permanently brick every guardian knob — including
    ///         the emergency escape hatches — so it always reverts.
    function renounceOwnership() public override onlyOwner {
        revert(unicode"Renounce disabled / 禁止放弃所有权");
    }

    /// @notice Lower the commission. The guardian can NEVER raise it — `newBps` must be `<=` the current
    ///         {commissionBps} (and thus always `<= {MAX_COMMISSION_BPS}`).
    /// @param  newBps New commission in basis points.
    function setCommissionBps(uint16 newBps) external onlyOwner {
        require(newBps <= commissionBps, unicode"Fee can only decrease / 费用只能降低");
        require(newBps <= MAX_COMMISSION_BPS, unicode"Commission too high / 佣金过高");
        commissionBps = newBps;
        emit CommissionSet(newBps);
    }

    /// @notice Change the commission recipient.
    /// @param  newTreasury New treasury (non-zero).
    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), unicode"Zero address / 零地址");
        treasury = newTreasury;
        emit TreasurySet(newTreasury);
    }

    /// @notice Change the {distribute} time-gate.
    /// @param  newInterval New minimum seconds between distributes (<= {MAX_MIN_INTERVAL}).
    function setMinInterval(uint256 newInterval) external onlyOwner {
        require(newInterval <= MAX_MIN_INTERVAL, unicode"Interval too long / 间隔过长");
        minInterval = newInterval;
        emit MinIntervalSet(newInterval);
    }

    /// @notice Guardian escape hatch to recover any ERC-20 held by the vault (incl. WBNB, a stock, or basket shares).
    /// @param  token ERC-20 to sweep (non-zero).
    /// @param  to    Recipient (non-zero).
    function emergencyWithdrawToken(address token, address to) external onlyOwner nonReentrant {
        require(token != address(0) && to != address(0), unicode"Zero address / 零地址");
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(to, bal);
            emit EmergencyWithdrawToken(token, to, bal);
        }
    }

    /// @notice Guardian escape hatch to recover native BNB.
    /// @param  to Recipient (non-zero).
    function emergencyWithdrawNative(address to) external onlyOwner nonReentrant {
        require(to != address(0), unicode"Zero address / 零地址");
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok,) = to.call{value: bal}("");
            require(ok, unicode"Native transfer failed / 原生转账失败");
            emit EmergencyWithdrawNative(to, bal);
        }
    }
}
