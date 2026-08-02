// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IPancakeV3SwapRouter } from "../interfaces/external/IPancakeV3.sol";

/// @title GenericBuybackKeeper
/// @notice Permissionless keeper that converts accrued tax/protocol revenue into
///         TAKEOVER and forwards it to a configured receiver:
///         `Tax Token -> Swap (PancakeSwap V3) -> TAKEOVER -> receiver`.
/// @dev Mirrors Takeover's GenericBuybackKeeper. Revenue is routed here (e.g. via
///      UGM.withdrawTaxRevenue), then anyone may trigger `convert`.
contract GenericBuybackKeeper is Ownable {
    using SafeERC20 for IERC20;

    IPancakeV3SwapRouter public immutable swapRouter;
    address public immutable takeover;
    address public receiver;

    /// @notice Emitted when a revenue token is swapped into TAKEOVER for the receiver.
    /// @param tokenIn The revenue token spent.
    /// @param amountIn Amount of `tokenIn` swapped.
    /// @param takeoverOut Amount of TAKEOVER sent to the receiver.
    /// @param receiver The address that received the TAKEOVER.
    event Converted(address indexed tokenIn, uint256 amountIn, uint256 takeoverOut, address indexed receiver);

    /// @notice Emitted when the buyback receiver is updated.
    /// @param receiver The new receiver address.
    event ReceiverSet(address indexed receiver);

    /// @notice Deploy the keeper with its swap route, buyback token and receiver.
    /// @param swapRouter_ The PancakeSwap V3 SwapRouter used for conversions.
    /// @param takeover_ The TAKEOVER token bought back.
    /// @param receiver_ The initial recipient of bought-back TAKEOVER.
    /// @param owner_ The owner (guardian) authorized to configure and rescue.
    constructor(address swapRouter_, address takeover_, address receiver_, address owner_) Ownable(owner_) {
        require(swapRouter_ != address(0) && takeover_ != address(0) && receiver_ != address(0), "zero");
        swapRouter = IPancakeV3SwapRouter(swapRouter_);
        takeover = takeover_;
        receiver = receiver_;
    }

    /// @notice Update the recipient of bought-back TAKEOVER.
    /// @param receiver_ The new receiver address (must be non-zero).
    function setReceiver(address receiver_) external onlyOwner {
        require(receiver_ != address(0), "zero");
        receiver = receiver_;
        emit ReceiverSet(receiver_);
    }

    /// @notice Swap this keeper's entire `tokenIn` balance into TAKEOVER via a single
    ///         PancakeSwap V3 pool and send the proceeds to `receiver`.
    /// @param tokenIn      Revenue token held by this keeper (e.g. USDT, WBNB).
    /// @param fee          PancakeSwap V3 pool fee tier for the tokenIn/TAKEOVER pool.
    /// @param minAmountOut Slippage guard (caller/keeper supplies; 0 only for tests).
    /// @return amountOut Amount of TAKEOVER sent to the receiver.
    function convert(address tokenIn, uint24 fee, uint256 minAmountOut)
        external
        returns (uint256 amountOut)
    {
        require(tokenIn != takeover, "tokenIn==TAKEOVER");
        uint256 amountIn = IERC20(tokenIn).balanceOf(address(this));
        require(amountIn > 0, "nothing");

        IERC20(tokenIn).forceApprove(address(swapRouter), amountIn);
        amountOut = swapRouter.exactInputSingle(
            IPancakeV3SwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: takeover,
                fee: fee,
                recipient: receiver,
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: 0
            })
        );
        emit Converted(tokenIn, amountIn, amountOut, receiver);
    }

    /// @notice Guardian rescue for stuck tokens.
    /// @param token The ERC20 to transfer out.
    /// @param to The recipient of the rescued tokens.
    /// @param amount Amount of `token` to transfer.
    function rescue(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }
}
