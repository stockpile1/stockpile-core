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
///         UnifiedGridManager (`gridConfig(uint256) returns (GridConfig)`). The vault
///         only reads `yieldToken` (the F3 registration-time assert); the other fields
///         are carried solely to keep the struct layout identical.
struct GridConfig {
    address creator; // grid creator; owns initial seats, tax-exempt yield
    uint64 createdAt; // creation timestamp
    uint32 totalSeats; // number of seats
    uint16 taxRateBps; // Harberger tax rate per week, in basis points
    uint32 forfeitureDuration; // Dutch-auction decay window for forfeited seats, in seconds
    address taxToken; // token used for prices, deposits and tax
    address yieldToken; // token distributed to seat holders as yield (the leg's `stock`)
}

/// @notice Stockpile grid sink (UnifiedGridManager). The vault forwards realized
///         ERC20 yield (a "stock" token) into a grid via `receiveYieldERC20`.
///         The caller MUST be the registered adapter for `assetHash`, the pushed
///         `token` MUST equal the grid's `yieldToken`, and the amount MUST be > 0 —
///         the UGM reverts otherwise (see `distribute` / `registerWithGrid`).
interface IGridSink {
    function receiveYieldERC20(bytes32 assetHash, address token, uint256 amount) external;
    /// @notice Bind `assetHash` to `gridId` with the CALLER as its adapter. The UGM sets
    ///         `assetAdapter[assetHash] = msg.sender`, so the vault MUST call this itself
    ///         (see `registerWithGrid`) to become the adapter `receiveYieldERC20` accepts.
    ///         Reverts unless the caller is a guardian-approved adapter and the asset is unregistered.
    function registerAsset(uint256 gridId, bytes32 assetHash) external;
    /// @notice Immutable configuration of `gridId` — read in `registerWithGrid` to assert
    ///         the grid's `yieldToken` equals the leg's `stock` (F3) BEFORE binding, so a
    ///         misconfigured deploy fails at registration instead of silently at distribute.
    function gridConfig(uint256 gridId) external view returns (GridConfig memory);
}

/// @notice PancakeSwap V3 SwapRouter on BSC (0x1b81D678…). Uses the classic Uniswap V3
///         `exactInput` struct WITH a `deadline` field (the BSC router keeps it). Verified
///         on a live BSC-mainnet fork against the reference bStonkBroker vault (D20 / T1.1).
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

/// @title MultiStockVault
/// @author The Stockpile Team
/// @notice Standalone (non-upgradeable) vault that is set as the fee `marketAddress`
///         of a Flap token (quote = WBNB), so it accrues the token's fee revenue.
///         A keeper periodically calls {distribute}, which skims a capped commission,
///         swaps the accrued balance into 7 "stock" tokens (each via a 2-hop PancakeSwap
///         V3 route through USDT), and forwards each stock into ITS OWN Stockpile grid
///         through the UnifiedGridManager (UGM) — so seat holders in each grid earn
///         that stock (grid SPCXB → SPCXB, grid QQQB → QQQB, …).
///
/// @dev  ── HOW THE FEE ARRIVES: NATIVE BNB ───────────────────────────────────────
///
///   Although the token's `quoteToken` is WBNB (for pricing/pairing), Flap settles the
///   tax and DISPATCHES the market portion to this vault (its `marketAddress`) as
///   **native BNB** — a plain value transfer — NOT as a WBNB ERC20 transfer. (Verified
///   on-chain against the reference bStonkBroker vault, which holds native BNB awaiting
///   distribution.) The {receive} hook therefore just accepts the BNB cheaply (it can
///   never revert on a gas-limited send); {distribute} wraps the accrued BNB to WBNB on
///   the keeper's gas before swapping. WBNB sent directly is also consumed.
///
///   ── FLOW ─────────────────────────────────────────────────────────────────────
///
///   1. Native BNB (the fee) accrues on `address(this)`; {receive} just accepts it.
///   2. A keeper calls {distribute} (time-gated by {minInterval}): it skims the
///      commission to the {treasury}, then splits the remainder by per-leg weight,
///      swaps each slice WBNB→USDT→stock on PancakeSwap V3, and forwards each bought
///      stock into its grid via the UGM, where it is paid to seat holders as yield.
///
///   ── TRUST MODEL ──────────────────────────────────────────────────────────────
///
///   The deployer is the guardian ({owner}); it may only ever *lower* the commission,
///   change the treasury, tune the time-gate, manage the {keepers} allowlist, and use the
///   {emergencyWithdrawToken} / {emergencyWithdrawNative} escape hatches. The 7 legs (stock /
///   grid / fee tier / weight) and every routing address are fixed at construction and
///   immutable in effect. {distribute} is keeper-gated ({owner} + {keepers}); {registerWithGrid}
///   is permissionless.
///
///   Per Rule 004 (UI-01), reverts use literal **bilingual** `require` strings — never
///   custom errors — so the generic Flap UI can render the reason as-is.
contract MultiStockVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Constants ────────────────────────────────────────────────────────────

    /// @notice Number of stock legs. Fixed at 7 (mirrors the reference bStonkBroker basket).
    uint256 public constant NUM_STOCKS = 7;

    /// @notice Hard cap on {commissionBps} (mirrors StockpileVault audit v5 F8): guarantees
    ///         {distribute} always routes at least 90% of every receipt into the grids, so
    ///         seat holders can never be starved of yield. The guardian may only lower the fee.
    uint16 public constant MAX_COMMISSION_BPS = 1_000; // 10%

    /// @notice Sanity ceiling on {minInterval} so a fat-fingered value cannot lock {distribute}
    ///         forever. 30 days is far above any sensible keeper cadence.
    uint256 public constant MAX_MIN_INTERVAL = 30 days;

    // ── Routing immutables (set once in the constructor) ─────────────────────

    /// @notice Wrapped BNB — the token the vault accrues and the first hop of every swap.
    address public immutable wbnb;
    /// @notice USDT / BSC-USD — the shared stable hop every WBNB→stock route passes through.
    address public immutable usdt;
    /// @notice Stockpile UnifiedGridManager (grid sink) the vault forwards stock yield to.
    address public immutable ugm;
    /// @notice PancakeSwap V3 SwapRouter used for the 2-hop `exactInput` swaps.
    address public immutable swapRouter;
    /// @notice Fee tier of the shared WBNB→USDT first hop (100 = 0.01% on BSC mainnet).
    uint24 public immutable wbnbUsdtFee;

    // ── Per-leg configuration (set once in the constructor) ──────────────────

    /// @notice One stock leg: the target stock token, the Stockpile grid it feeds, the grid
    ///         `assetHash` (derived, not supplied), the USDT→stock V3 fee tier, and the split weight.
    struct Leg {
        address stock; // stock token bought and forwarded as grid yield
        uint256 gridId; // UGM grid id this stock is paid into
        bytes32 assetHash; // keccak256(abi.encode("MultiStockVault", address(this), gridId))
        uint24 stockFee; // USDT→stock V3 fee tier (second hop)
        uint16 weightBps; // share of `net` allocated to this leg (all 7 sum to 10_000)
    }

    /// @dev The 7 legs. Read externally via {legs} / {stocks}. Fixed at construction.
    Leg[NUM_STOCKS] private _legs;

    /// @notice The 7-stock basket, supplied to the constructor as one struct (four positionally-paired
    ///         fixed arrays). Packed into a single struct so the constructor's ABI decoder stays within
    ///         the stack limit under the project's non-`via-ir` optimizer (see the deviation note / D-log);
    ///         it carries the SAME four arrays the flat spec listed, in the same order.
    struct BasketParams {
        address[NUM_STOCKS] stocks; // the 7 stock tokens (all non-zero)
        uint256[NUM_STOCKS] gridIds; // the 7 grid ids (all non-zero)
        uint24[NUM_STOCKS] stockFees; // the 7 USDT→stock V3 fee tiers
        uint16[NUM_STOCKS] weightsBps; // the 7 split weights (sum to 10_000)
    }

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
    ///         slippage floor and sandwich the pools (audit F1). The guardian owns this list.
    mapping(address => bool) public keepers;

    // ── Events ───────────────────────────────────────────────────────────────

    /// @notice Emitted once at construction with the immutable routing + initial mutable config.
    event Configured(
        address wbnb,
        address usdt,
        address ugm,
        address swapRouter,
        uint24 wbnbUsdtFee,
        address treasury,
        uint16 commissionBps,
        uint256 minInterval
    );
    /// @notice Emitted once per leg at construction (indexer-friendly view of the fixed basket).
    event LegConfigured(
        uint256 indexed legIndex, address stock, uint256 gridId, bytes32 assetHash, uint24 stockFee, uint16 weightBps
    );
    /// @notice Emitted on each successful {distribute}: gross WBNB consumed, commission skimmed, net
    ///         swapped, and the amount of each stock bought and forwarded to its grid.
    event Distributed(
        address indexed caller, uint256 gross, uint256 commission, uint256 net, uint256[NUM_STOCKS] bought
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
    /// @dev    Gates {distribute} (audit F1): only a trusted keeper — who computes a real off-chain
    ///         `minOut` slippage floor — may trigger the swap, so an attacker can no longer be the
    ///         caller passing an all-zeros floor and sandwich the pools.
    modifier onlyKeeper() {
        require(msg.sender == owner() || keepers[msg.sender], unicode"Not authorized keeper / 未授权的keeper");
        _;
    }

    // ── Constructor ────────────────────────────────────────────────────────────

    /// @notice Wire the vault to its routing addresses and fix its 7-stock basket. The deployer
    ///         becomes the guardian ({owner}).
    /// @dev    Each leg's `assetHash` is DERIVED here as
    ///         `keccak256(abi.encode("MultiStockVault", address(this), gridId))` — it is never taken
    ///         as input, so it is cryptographically bound to this vault and its grid, exactly as the
    ///         UGM expects in {registerWithGrid}. The 7 weights MUST sum to 10_000.
    /// @param  _wbnb         Wrapped BNB (accrued token + first swap hop).
    /// @param  _usdt         USDT / BSC-USD (shared stable hop).
    /// @param  _ugm          Stockpile UnifiedGridManager (grid sink).
    /// @param  _swapRouter   PancakeSwap V3 SwapRouter.
    /// @param  _wbnbUsdtFee  WBNB→USDT first-hop fee tier (e.g. 100).
    /// @param  _treasury     Commission recipient.
    /// @param  _commissionBps Initial commission in bps (<= {MAX_COMMISSION_BPS}).
    /// @param  _minInterval  Initial distribute time-gate in seconds (<= {MAX_MIN_INTERVAL}).
    /// @param  basket        The 7-stock basket: `stocks` (all non-zero), `gridIds` (all non-zero),
    ///                       `stockFees`, and `weightsBps` (which MUST sum to 10_000), all positionally paired.
    constructor(
        address _wbnb,
        address _usdt,
        address _ugm,
        address _swapRouter,
        uint24 _wbnbUsdtFee,
        address _treasury,
        uint16 _commissionBps,
        uint256 _minInterval,
        BasketParams memory basket
    ) {
        require(
            _wbnb != address(0) && _usdt != address(0) && _ugm != address(0) && _swapRouter != address(0)
                && _treasury != address(0),
            unicode"Zero address / 零地址"
        );
        require(_commissionBps <= MAX_COMMISSION_BPS, unicode"Commission too high / 佣金过高");
        require(_minInterval <= MAX_MIN_INTERVAL, unicode"Interval too long / 间隔过长");

        wbnb = _wbnb;
        usdt = _usdt;
        ugm = _ugm;
        swapRouter = _swapRouter;
        wbnbUsdtFee = _wbnbUsdtFee;

        treasury = _treasury;
        commissionBps = _commissionBps;
        minInterval = _minInterval;

        uint256 weightSum;
        for (uint256 i = 0; i < NUM_STOCKS; i++) {
            address stock = basket.stocks[i];
            uint256 gridId = basket.gridIds[i];
            require(stock != address(0), unicode"Zero address / 零地址");
            require(gridId != 0, unicode"Zero grid / 网格为零");
            // A stock that is WBNB or USDT would make a degenerate WBNB→USDT→WBNB / …→USDT→USDT path
            // that reverts in the router or burns value to fees (audit F10).
            require(stock != _wbnb && stock != _usdt, unicode"Stock cannot be wbnb/usdt / stock不能为wbnb或usdt");

            bytes32 assetHash = keccak256(abi.encode("MultiStockVault", address(this), gridId));

            _legs[i] = Leg({
                stock: stock,
                gridId: gridId,
                assetHash: assetHash,
                stockFee: basket.stockFees[i],
                weightBps: basket.weightsBps[i]
            });
            weightSum += basket.weightsBps[i];

            emit LegConfigured(i, stock, gridId, assetHash, basket.stockFees[i], basket.weightsBps[i]);
        }
        require(weightSum == 10_000, unicode"Weights must sum to 10000 / 权重总和须为10000");

        // Duplicate gridIds collide their (vault, gridId)-derived assetHash, so `registerAllGrids`
        // would revert on the second occurrence and two legs would credit one grid (audit F4). O(49).
        for (uint256 i = 0; i < NUM_STOCKS; i++) {
            for (uint256 j = i + 1; j < NUM_STOCKS; j++) {
                require(_legs[i].gridId != _legs[j].gridId, unicode"Duplicate grid / 网格重复");
            }
        }

        emit Configured(_wbnb, _usdt, _ugm, _swapRouter, _wbnbUsdtFee, _treasury, _commissionBps, _minInterval);
    }

    // ── Native-BNB intake (THE fee path — Flap dispatches the fee as native BNB) ──

    /// @notice Accept the incoming fee. Flap settles the token's tax and dispatches the market
    ///         portion to this vault (its `marketAddress`) as **native BNB** (a plain value transfer),
    ///         NOT as a WBNB ERC20 transfer. This hook is deliberately a cheap no-op so it can NEVER
    ///         revert on a gas-limited send (e.g. a 2300-gas `.transfer()`): the accrued BNB is wrapped
    ///         to WBNB later, inside {distribute} (on the keeper's gas), keeping the fee delivery robust.
    /// @dev    WBNB transferred directly is ALSO handled — {distribute} consumes the WBNB balance too.
    receive() external payable {}

    // ── Views ──────────────────────────────────────────────────────────────────

    /// @notice Fee currently accrued and awaiting {distribute} (gross of commission) — counts BOTH the
    ///         native BNB the vault holds (the normal fee) AND any WBNB already on it, since {distribute}
    ///         wraps the native BNB before swapping.
    /// @dev    Never reverts — safe for the UI/keeper to poll.
    function pendingDistribute() external view returns (uint256) {
        return IERC20(wbnb).balanceOf(address(this)) + address(this).balance;
    }

    /// @notice Full configuration of leg `i`.
    /// @param  i Leg index in `[0, {NUM_STOCKS})`.
    /// @return stock     Stock token bought and forwarded as grid yield.
    /// @return gridId    UGM grid id this stock is paid into.
    /// @return assetHash Derived grid asset handle (`keccak256(abi.encode("MultiStockVault", vault, gridId))`).
    /// @return stockFee  USDT→stock V3 fee tier (second hop).
    /// @return weightBps Share of `net` allocated to this leg, in bps.
    function legs(uint256 i)
        external
        view
        returns (address stock, uint256 gridId, bytes32 assetHash, uint24 stockFee, uint16 weightBps)
    {
        require(i < NUM_STOCKS, unicode"Bad leg index / 无效腿索引");
        Leg storage l = _legs[i];
        return (l.stock, l.gridId, l.assetHash, l.stockFee, l.weightBps);
    }

    /// @notice The stock token of leg `i` (mirrors the reference vault's `stocks(i)` getter).
    /// @param  i Leg index in `[0, {NUM_STOCKS})`.
    function stocks(uint256 i) external view returns (address) {
        require(i < NUM_STOCKS, unicode"Bad leg index / 无效腿索引");
        return _legs[i].stock;
    }

    // ── The money path ──────────────────────────────────────────────────────────

    /// @notice Skim the commission, then swap the accrued WBNB into the 7 stocks and forward each
    ///         into its grid. Time-gated by {minInterval}, keeper-gated ({owner} or a {keepers} address,
    ///         audit F1), and `nonReentrant`.
    ///
    /// @dev    Sequencing is strict CEI: the require-checks read state, {lastDistribute} is advanced
    ///         BEFORE any external call, and only then are transfers/swaps/pushes performed.
    ///
    ///         WBNB is split by per-leg weight; the rounding dust of the 7-way integer split is placed
    ///         on the LAST leg so `sum(amountIn) == net` exactly (the router approval covers it and is
    ///         reset to 0 afterwards). Each leg swaps `WBNB --(wbnbUsdtFee)--> USDT --(stockFee)--> stock`
    ///         via a 2-hop V3 `exactInput` with the caller-supplied `minOut[i]` slippage floor and
    ///         shared `deadline`, then forwards the bought stock into the grid via the UGM (per-leg
    ///         approval granted then reset to 0).
    ///
    ///         Preconditions the UGM enforces per leg: the grid must exist with `yieldToken == stock`,
    ///         this vault must be its registered adapter (call {registerWithGrid} once, after the
    ///         guardian approves the vault), and the pushed amount must be > 0. Distribution is
    ///         BEST-EFFORT (audit F2): each leg runs in its own atomic self-call, so a leg that reverts
    ///         (dead pool, unreachable `minOut[i]`, mis-registered/paused grid) is skipped — its
    ///         `bought[i]` stays 0 and its `amountIn` WBNB is retained for the next distribute — while
    ///         the healthy legs still deliver. A swap that nets 0 likewise skips only its own grid push.
    ///
    /// @param  minOut   Per-leg minimum stock out (slippage protection); positionally paired with the legs.
    /// @param  deadline Unix timestamp after which the swaps revert (enforced by the router).
    /// @return bought   Amount of each stock bought and forwarded to its grid (0 for any skipped leg).
    function distribute(uint256[NUM_STOCKS] calldata minOut, uint256 deadline)
        external
        nonReentrant
        onlyKeeper
        returns (uint256[NUM_STOCKS] memory bought)
    {
        require(block.timestamp >= lastDistribute + minInterval, unicode"Too soon / 时间未到");

        address _wbnb = wbnb;
        // The Flap fee lands as NATIVE BNB (receive() accepted it cheaply). Wrap the accrued BNB to WBNB
        // here — on the keeper's gas — so the swap path is uniform. `nonReentrant` guards this; IWBNB.deposit
        // is a trusted, non-reentrant call. Any WBNB sent directly is already in the balance below.
        uint256 nativeBal = address(this).balance;
        if (nativeBal > 0) IWBNB(_wbnb).deposit{value: nativeBal}();

        uint256 gross = IERC20(_wbnb).balanceOf(address(this));
        require(gross > 0, unicode"Nothing to distribute / 无可分配");

        uint256 commission = (gross * commissionBps) / 10_000;
        uint256 net = gross - commission;

        // ── Effects: advance the time-gate BEFORE any external interaction (CEI). ──
        lastDistribute = block.timestamp;

        // ── Interactions ──
        if (commission > 0) {
            IERC20(_wbnb).safeTransfer(treasury, commission);
        }

        // Approve the router once for the whole `net`; reset to 0 after the loop.
        IERC20(_wbnb).forceApprove(swapRouter, net);

        uint256 allocated; // running sum of amountIn assigned to prior legs (weight, pre-swap)
        for (uint256 i = 0; i < NUM_STOCKS; i++) {
            uint256 amountIn;
            if (i == NUM_STOCKS - 1) {
                // Dust: the last leg absorbs the remainder so sum(amountIn) == net exactly.
                amountIn = net - allocated;
            } else {
                amountIn = (net * _legs[i].weightBps) / 10_000;
                allocated += amountIn;
            }
            if (amountIn == 0) continue;

            // Best-effort per leg (audit F2): a self-external-call gives each leg its own atomic
            // sub-transaction, so a dead pool / unreachable minOut / mis-registered or paused grid
            // reverts ONLY that leg. The catch skips it (bought[i] stays 0) and, because the swap
            // rolled back, its `amountIn` WBNB is retained on the vault for the next distribute —
            // one bad leg can no longer brick the other six.
            try this.swapLegAndForward(i, amountIn, minOut[i], deadline) returns (uint256 out) {
                bought[i] = out;
            } catch {
                /* leg failed (dead pool / slippage / bad grid): skip; its WBNB stays for next distribute */
            }
        }

        // Reset the router allowance so no dangling approval survives the call.
        IERC20(_wbnb).forceApprove(swapRouter, 0);

        emit Distributed(msg.sender, gross, commission, net, bought);
    }

    /// @notice Swap `amountIn` WBNB into leg `i`'s stock via the 2-hop V3 route and forward the proceeds
    ///         into its grid. Invoked ONLY by {distribute} as an external self-call (`this.swapLegAndForward`)
    ///         so each leg gets an isolated, atomically-revertable sub-transaction (audit F2). MUST NOT be
    ///         `nonReentrant`: it is reached from inside the `nonReentrant` {distribute}, so a guard would
    ///         revert the whole batch — instead it is gated to `msg.sender == address(this)`.
    ///
    /// @dev    FoT-robust (audit F5): the amount forwarded is the vault's ACTUAL post-swap balance delta,
    ///         not the router's returned value. For a fee-on-transfer output token the router may deliver
    ///         less than it reports; pushing the measured `got` keeps the UGM `transferFrom(vault, ugm, got)`
    ///         within the vault's real balance (no over-pull revert). The router allowance is granted by
    ///         {distribute} (once, over the batch); the UGM allowance is granted and reset here per leg. A
    ///         swap that nets 0 skips the grid push (the UGM reverts on amount==0).
    /// @return out Stock actually received and forwarded to the grid (0 if the swap netted nothing).
    function swapLegAndForward(uint256 i, uint256 amountIn, uint256 minOut, uint256 deadline)
        external
        returns (uint256 out)
    {
        require(msg.sender == address(this), unicode"Only self / 仅限自身");
        Leg storage leg = _legs[i];

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
        uint256 got = IERC20(leg.stock).balanceOf(address(this)) - balBefore;

        if (got > 0) {
            address _ugm = ugm;
            IERC20(leg.stock).forceApprove(_ugm, got);
            IGridSink(_ugm).receiveYieldERC20(leg.assetHash, leg.stock, got);
            IERC20(leg.stock).forceApprove(_ugm, 0);
            out = got;
        }
    }

    // ── Grid adapter binding (permissionless) ────────────────────────────────────

    /// @notice Bind this vault as the UGM adapter for leg `legIndex`'s grid so {distribute} can deliver its stock.
    /// @dev    PERMISSIONLESS one-shot binding. Calls `ugm.registerAsset(gridId, assetHash)`, which sets the
    ///         UGM's `assetAdapter[assetHash]` to THIS vault (the `msg.sender` of that call) — the exact identity
    ///         `receiveYieldERC20` checks in {distribute}. Because the UGM binds the adapter to its own caller,
    ///         the vault MUST perform the registration itself; a guardian/factory calling `registerAsset` would
    ///         bind the wrong address and permanently break {distribute} for that leg.
    ///
    ///         Preconditions enforced by the UGM: the Stockpile guardian must have first approved this vault as
    ///         an adapter, and the asset must be unregistered (a second call reverts at the UGM). The stored
    ///         `assetHash` is cryptographically bound to `(vault, gridId)`, so no privileged check is needed here.
    /// @param  legIndex Leg index in `[0, {NUM_STOCKS})`.
    function registerWithGrid(uint256 legIndex) external nonReentrant {
        require(legIndex < NUM_STOCKS, unicode"Bad leg index / 无效腿索引");
        Leg storage leg = _legs[legIndex];
        // Fail a misconfigured deploy HERE, not silently at the first distribute (audit F3): the UGM's
        // `receiveYieldERC20` requires the pushed token == the grid's yieldToken, so a grid whose
        // yieldToken != this leg's stock could never accept its yield.
        require(
            IGridSink(ugm).gridConfig(leg.gridId).yieldToken == leg.stock,
            unicode"Grid yieldToken mismatch / 网格收益代币不匹配"
        );
        IGridSink(ugm).registerAsset(leg.gridId, leg.assetHash);
    }

    /// @notice Convenience: bind all 7 legs' grids in one call.
    /// @dev    All-or-nothing — reverts (at the UGM) if ANY leg is already registered or the vault is not yet
    ///         an approved adapter. Use {registerWithGrid} per-leg when some legs are already bound.
    function registerAllGrids() external nonReentrant {
        for (uint256 i = 0; i < NUM_STOCKS; i++) {
            Leg storage leg = _legs[i];
            // Per-leg yieldToken assert (audit F3), same as {registerWithGrid}.
            require(
                IGridSink(ugm).gridConfig(leg.gridId).yieldToken == leg.stock,
                unicode"Grid yieldToken mismatch / 网格收益代币不匹配"
            );
            IGridSink(ugm).registerAsset(leg.gridId, leg.assetHash);
        }
    }

    // ── Guardian controls (owner-only) ───────────────────────────────────────────

    /// @notice Add or remove a {distribute} keeper (audit F1). The {owner} is always allowed and need
    ///         not be listed. Keepers are trusted to compute a real off-chain `minOut` slippage floor.
    /// @param  keeper  Keeper address to toggle (non-zero).
    /// @param  allowed True to allow, false to revoke.
    function setKeeper(address keeper, bool allowed) external onlyOwner {
        require(keeper != address(0), unicode"Zero address / 零地址");
        keepers[keeper] = allowed;
        emit KeeperSet(keeper, allowed);
    }

    /// @notice Disabled (audit F6): renouncing ownership would permanently brick every guardian knob —
    ///         including the {emergencyWithdrawToken}/{emergencyWithdrawNative} escape hatches that
    ///         recover funds stuck by a bricked leg — so it always reverts.
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

    /// @notice Guardian escape hatch to recover any ERC-20 held by the vault (incl. WBNB or a bought stock).
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

    /// @notice Guardian escape hatch to recover native BNB (normally none, since intake is WBNB ERC20).
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
