// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/// @notice Tokens the router can mint as swap proceeds (the MultiStockVault stocks).
interface IMintableToken {
    function mint(address to, uint256 amount) external;
}

/// @title MockV3Router
/// @notice Deterministic stand-in for the PancakeSwap V3 SwapRouter's `exactInput`
///         used by the MultiStockVault unit tests. It faithfully mirrors the parts
///         the vault depends on:
///           • decodes the packed V3 `path` — tokenIn = first 20 bytes, tokenOut =
///             LAST 20 bytes (a 2-hop path is 20+3+20+3+20 = 66 bytes; the mid hop
///             and fee tiers are irrelevant to the payout math);
///           • pulls `amountIn` of tokenIn from the caller via `transferFrom` (the
///             vault force-approves the router for the batch), so allowances/balances
///             are exercised for real;
///           • computes `amountOut = amountIn * rate(tokenOut) / RATE_DEN` (default
///             1:1) and REVERTS if `amountOut < amountOutMinimum`, mirroring the real
///             router's slippage floor;
///           • delivers the output by MINTING it to `params.recipient` (no pre-fund).
///         Configurable per output token: `setRate` overrides the price, `setForceZero`
///         forces a leg to yield 0 (to exercise the vault's zero-out skip path).
contract MockV3Router {
    /// @dev Same struct/selector as `IV3SwapRouter.ExactInputParams` in MultiStockVault.
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @notice Fixed-point denominator for the per-token rate.
    uint256 public constant RATE_DEN = 1e18;

    /// @notice Default output-per-input numerator (1e18 == 1:1) when a token has no override.
    uint256 public defaultRateNum = 1e18;
    /// @notice Per-tokenOut rate numerator override; 0 means "use `defaultRateNum`".
    mapping(address => uint256) public rateNumOf;
    /// @notice Per-tokenOut kill switch: when true the swap yields exactly 0 out.
    mapping(address => bool) public forceZeroOf;
    /// @notice Per-tokenOut kill switch: when true `exactInput` REVERTS (mirrors a dead pool / paused
    ///         token). Distinct from `forceZeroOf` (which returns 0) — exercises the vault's best-effort
    ///         per-leg try/catch (audit F2), which must skip a REVERTING leg, not just a zero-out one.
    mapping(address => bool) public forceRevertOf;

    // ── Last-swap bookkeeping (per-call; the accumulated per-asset totals live on MockUGM) ─
    uint256 public swapCount;
    address public lastTokenIn;
    address public lastTokenOut;
    uint256 public lastAmountIn;
    uint256 public lastAmountOut;

    /// @notice Set the global default output-per-input numerator (over `RATE_DEN`).
    function setDefaultRate(uint256 num) external {
        defaultRateNum = num;
    }

    /// @notice Override the output-per-input numerator (over `RATE_DEN`) for one output token.
    function setRate(address tokenOut, uint256 num) external {
        rateNumOf[tokenOut] = num;
    }

    /// @notice Force `tokenOut` swaps to return 0 out (exercises the vault's zero-yield skip).
    function setForceZero(address tokenOut, bool z) external {
        forceZeroOf[tokenOut] = z;
    }

    /// @notice Force `tokenOut` swaps to REVERT (exercises the vault's best-effort per-leg skip, F2).
    function setForceRevert(address tokenOut, bool r) external {
        forceRevertOf[tokenOut] = r;
    }

    function _rate(address tokenOut) internal view returns (uint256) {
        uint256 num = rateNumOf[tokenOut];
        return num == 0 ? defaultRateNum : num;
    }

    /// @notice 2-hop `exactInput`: pull tokenIn, compute out, enforce slippage, mint out to recipient.
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut) {
        bytes memory path = params.path;
        require(path.length >= 40, "MockV3Router: bad path");

        address tokenIn = _addr(path, 0);
        address tokenOut = _addr(path, path.length - 20);

        // Dead-pool / paused-token parity: revert the whole swap (audit F2 skip path).
        require(!forceRevertOf[tokenOut], "MockV3Router: forced revert");

        // Pull the input from the caller (the vault force-approved the router for the batch).
        IERC20(tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        if (forceZeroOf[tokenOut]) {
            amountOut = 0;
        } else {
            amountOut = (params.amountIn * _rate(tokenOut)) / RATE_DEN;
        }

        // Real-router parity: revert when the output floor is not met.
        require(amountOut >= params.amountOutMinimum, "MockV3Router: insufficient output");

        if (amountOut > 0) {
            // Deliver like a real pool: mint into the router, then TRANSFER to the recipient. For a
            // fee-on-transfer output token the recipient then receives LESS than `amountOut`, so the
            // vault's measured balance-delta (audit F5) diverges from this nominal — exactly the case
            // the FoT-robust push guards against. Plain tokens deliver the full amount, unchanged.
            IMintableToken(tokenOut).mint(address(this), amountOut);
            IERC20(tokenOut).transfer(params.recipient, amountOut);
        }

        lastTokenIn = tokenIn;
        lastTokenOut = tokenOut;
        lastAmountIn = params.amountIn;
        lastAmountOut = amountOut;
        swapCount += 1;
    }

    /// @dev Read a 20-byte address out of `b` starting at `offset` (top-of-word, V3-path layout).
    function _addr(bytes memory b, uint256 offset) internal pure returns (address a) {
        require(b.length >= offset + 20, "MockV3Router: addr oob");
        assembly {
            a := shr(96, mload(add(add(b, 32), offset)))
        }
    }
}
