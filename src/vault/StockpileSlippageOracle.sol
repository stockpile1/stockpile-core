// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @notice Minimal PancakeSwap V3 factory view used to locate a pool.
interface IPancakeV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @notice Minimal PancakeSwap V3 pool view used for the price oracle.
interface IPancakeV3PoolOracle {
    /// @notice Cumulative tick and liquidity-per-second values at each `secondsAgos` point.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @title StockpileSlippageOracle
/// @author The Stockpile Team
/// @notice Derives an on-chain slippage floor for the vault's 2-hop WBNB→USDT→stock swaps from
///         PancakeSwap V3's built-in TWAP oracle, so a distribute never executes with an unbounded
///         `amountOutMinimum`.
///
/// @dev  ── WHY THIS IS A SEPARATE CONTRACT ────────────────────────────────────────
///
///   {StockpileBasketVaultV2} sits within a few hundred bytes of the EIP-170 runtime limit, so the tick
///   math below cannot live on the vault. Keeping it here also means the vault's money path gains only
///   two `view` calls per distribute — one shared WBNB→USDT quote plus one per stock leg — and this
///   contract holds NO funds and NO privileged state, so it is pure computation over public pool data
///   and can be reviewed in isolation.
///
///   ── WHY TWAP, NOT SPOT ────────────────────────────────────────────────────────
///
///   A spot floor read from `slot0` follows a manipulated price, so it would sanction the very execution
///   it is meant to bound. The time-weighted mean over {WINDOW} costs an attacker sustained capital
///   across multiple blocks to move, while still tracking genuine price moves within a few minutes.
///
///   ── FAILURE BEHAVIOUR IS FAIL-CLOSED, BY DESIGN ───────────────────────────────
///
///   Every path here REVERTS rather than returning a permissive value: a missing pool, a pool too young
///   for the window, or an out-of-range tick all bubble up. Never returning 0 is the point — a permissive
///   return would read as "no floor needed" at exactly the moment pricing is unavailable.
///
///   The vault isolates EVERY call into this contract (AUDIT v11): the per-leg quote inside `swapLeg` is
///   wrapped by `_swapAll`'s try/catch, and the shared WBNB→USDT quote is wrapped directly. So an
///   unusable oracle degrades instead of bricking:
///     • the keeper path (`distribute` / `distributeUniform`) still executes under the caller's own
///       explicit floors — it does NOT hard-depend on this contract;
///     • the trigger path, which supplies no floors, skips the leg and emits `LegSkipped` rather than
///       swapping unbounded.
///   That distinction is enforced by the `minOut > 0` check in `swapLeg`, not by trusting this contract.
contract StockpileSlippageOracle {
    /// @notice TWAP window. Long enough that moving the mean requires holding a dislocated price across
    ///         several blocks, short enough to track real moves in a fast market.
    uint32 public constant WINDOW = 300; // 5 minutes

    /// @notice Upper bound on the tolerance a caller may ask for (50%). A caller asking for more is
    ///         almost certainly misconfigured, and a floor that loose provides no protection at all.
    uint16 public constant MAX_SLIPPAGE_BPS = 5_000;

    /// @notice PancakeSwap V3 factory used to locate the two hop pools.
    address public immutable v3Factory;
    /// @notice Wrapped BNB — the input of hop 1.
    address public immutable wbnb;
    /// @notice USDT — the shared intermediate hop.
    address public immutable usdt;
    /// @notice Fee tier of the WBNB→USDT pool (hop 1).
    uint24 public immutable wbnbUsdtFee;

    constructor(address _v3Factory, address _wbnb, address _usdt, uint24 _wbnbUsdtFee) {
        require(
            _v3Factory != address(0) && _wbnb != address(0) && _usdt != address(0),
            unicode"Zero address / 零地址"
        );
        v3Factory = _v3Factory;
        wbnb = _wbnb;
        usdt = _usdt;
        wbnbUsdtFee = _wbnbUsdtFee;
    }

    /// @notice The minimum acceptable `stock` output for swapping `amountIn` WBNB through USDT, allowing
    ///         `maxSlippageBps` of tolerance against the TWAP-implied fair value.
    /// @dev    Reverts if either hop's pool is missing or lacks {WINDOW} seconds of observations — see the
    ///         fail-closed note on the contract.
    /// @param  stock          The stock token bought on hop 2.
    /// @param  stockFee       Fee tier of the USDT→stock pool.
    /// @param  amountIn       WBNB being swapped (hop-1 input).
    /// @param  maxSlippageBps Tolerance below the TWAP-implied output, in bps.
    /// @return minOut The floor to pass as `amountOutMinimum`.
    function minOutFor(address stock, uint24 stockFee, uint256 amountIn, uint16 maxSlippageBps)
        external
        view
        returns (uint256 minOut)
    {
        require(amountIn > 0 && amountIn <= type(uint128).max, unicode"Bad amountIn / 输入数量无效");
        // Hop 1: WBNB → USDT at the pool's time-weighted mean price.
        uint256 usdtOut = _quote(wbnb, usdt, wbnbUsdtFee, uint128(amountIn));
        return _floorFromUsdt(stock, stockFee, usdtOut, maxSlippageBps);
    }

    /// @notice Same floor as {minOutFor} but starting from a USDT amount, so a caller swapping several
    ///         stocks in one batch can quote the shared WBNB→USDT hop ONCE and reuse it.
    /// @dev    This is the form the vault uses. Each `observe()` costs real gas and the vault's triggered
    ///         distribute runs inside a 2,000,000-gas callback budget: quoting hop 1 per leg would spend
    ///         ~56k gas per leg re-deriving an identical number. Hop 1 is linear in the input amount, so
    ///         the caller scales one quote across its legs and only hop 2 is priced per stock.
    /// @param  stock          The stock token bought on hop 2.
    /// @param  stockFee       Fee tier of the USDT→stock pool.
    /// @param  usdtIn         USDT notionally entering hop 2.
    /// @param  maxSlippageBps Tolerance below the TWAP-implied output, in bps.
    /// @return minOut The floor to pass as `amountOutMinimum`.
    function minOutForUsdtIn(address stock, uint24 stockFee, uint256 usdtIn, uint16 maxSlippageBps)
        external
        view
        returns (uint256 minOut)
    {
        return _floorFromUsdt(stock, stockFee, usdtIn, maxSlippageBps);
    }

    function _floorFromUsdt(address stock, uint24 stockFee, uint256 usdtIn, uint16 maxSlippageBps)
        private
        view
        returns (uint256 minOut)
    {
        require(maxSlippageBps <= MAX_SLIPPAGE_BPS, unicode"Slippage too high / 滑点过高");
        require(usdtIn > 0 && usdtIn <= type(uint128).max, unicode"Bad hop1 quote / 第一跳报价无效");

        uint256 expected = _quote(usdt, stock, stockFee, uint128(usdtIn));
        minOut = (expected * (10_000 - maxSlippageBps)) / 10_000;
    }

    /// @notice TWAP-implied USDT out for `wbnbIn` WBNB — the shared hop 1, quoted once per distribute.
    /// @dev    Takes a single argument on purpose: the vault calls this on its hot path and every extra
    ///         parameter costs calldata-encoding bytecode it does not have (EIP-170).
    function quoteWbnbForUsdt(uint256 wbnbIn) external view returns (uint256 usdtOut) {
        require(wbnbIn > 0 && wbnbIn <= type(uint128).max, unicode"Bad amountIn / 输入数量无效");
        return _quote(wbnb, usdt, wbnbUsdtFee, uint128(wbnbIn));
    }

    /// @notice The raw TWAP-implied output for one hop, with no slippage tolerance applied.
    /// @dev    Exposed for off-chain checks and for the fork test that validates this contract's maths
    ///         against a real executed swap.
    function quoteHop(address tokenIn, address tokenOut, uint24 fee, uint128 amountIn)
        external
        view
        returns (uint256 amountOut)
    {
        return _quote(tokenIn, tokenOut, fee, amountIn);
    }

    // ── Internals ─────────────────────────────────────────────────────────────

    /// @dev TWAP-implied `tokenOut` amount for `amountIn` of `tokenIn` in the (tokenIn, tokenOut, fee) pool.
    function _quote(address tokenIn, address tokenOut, uint24 fee, uint128 amountIn)
        private
        view
        returns (uint256)
    {
        address pool = IPancakeV3Factory(v3Factory).getPool(tokenIn, tokenOut, fee);
        require(pool != address(0), unicode"No pool / 无流动性池");
        return _getQuoteAtTick(_consult(pool), amountIn, tokenIn, tokenOut);
    }

    /// @dev Arithmetic mean tick over {WINDOW}. Mirrors Uniswap V3's `OracleLibrary.consult`, including
    ///      the negative-delta rounding correction (integer division truncates toward zero, so a negative
    ///      remainder must round DOWN to stay conservative).
    function _consult(address pool) private view returns (int24 meanTick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = WINDOW;
        secondsAgos[1] = 0;

        (int56[] memory tickCumulatives,) = IPancakeV3PoolOracle(pool).observe(secondsAgos);
        int56 delta = tickCumulatives[1] - tickCumulatives[0];

        meanTick = int24(delta / int56(uint56(WINDOW)));
        if (delta < 0 && (delta % int56(uint56(WINDOW)) != 0)) meanTick--;
    }

    /// @dev Uniswap V3 `OracleLibrary.getQuoteAtTick`: the `quoteToken` amount equivalent to `baseAmount`
    ///      of `baseToken` at `tick`.
    function _getQuoteAtTick(int24 tick, uint128 baseAmount, address baseToken, address quoteToken)
        private
        pure
        returns (uint256 quoteAmount)
    {
        uint160 sqrtRatioX96 = _getSqrtRatioAtTick(tick);

        // Avoid overflowing the intermediate: square in X192 when it fits, otherwise step down to X128.
        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? _mulDiv(ratioX192, baseAmount, 1 << 192)
                : _mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = _mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? _mulDiv(ratioX128, baseAmount, 1 << 128)
                : _mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }

    /// @dev Uniswap V3 `TickMath.getSqrtRatioAtTick`, verbatim (constants unchanged), wrapped in
    ///      `unchecked` for Solidity >=0.8 — every operation here is intentionally modular.
    function _getSqrtRatioAtTick(int24 tick) private pure returns (uint160 sqrtPriceX96) {
        unchecked {
            uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
            require(absTick <= 887272, unicode"Tick out of range / 价格刻度越界");

            uint256 ratio =
                absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
            if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

            if (tick > 0) ratio = type(uint256).max / ratio;

            // Round up when shifting X128 down to X96, so the quote never rounds in the pool's favour.
            sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }

    /// @dev Uniswap V3 `FullMath.mulDiv` (Remco Bloemen, MIT): full 512-bit multiply then divide, so
    ///      `a * b` may exceed 256 bits as long as the final result does not.
    function _mulDiv(uint256 a, uint256 b, uint256 denominator) private pure returns (uint256 result) {
        unchecked {
            uint256 prod0; // least significant 256 bits of a * b
            uint256 prod1; // most significant 256 bits
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // No overflow into the high word: a plain division suffices.
            if (prod1 == 0) {
                require(denominator > 0, unicode"Division by zero / 除以零");
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }

            require(denominator > prod1, unicode"Quote overflow / 报价溢出");

            // 512-bit division.
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor the powers of two out of the denominator.
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // Invert the denominator mod 2**256 by Newton-Raphson (doubles correct bits each step).
            uint256 inv = (3 * denominator) ^ 2;
            inv *= 2 - denominator * inv; // 8
            inv *= 2 - denominator * inv; // 16
            inv *= 2 - denominator * inv; // 32
            inv *= 2 - denominator * inv; // 64
            inv *= 2 - denominator * inv; // 128
            inv *= 2 - denominator * inv; // 256

            result = prod0 * inv;
        }
    }
}
