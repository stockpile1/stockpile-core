// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ForkBase } from "./ForkBase.t.sol";
import { BscAddresses } from "../../src/config/BscAddresses.sol";
import { GenericBuybackKeeper } from "../../src/keeper/GenericBuybackKeeper.sol";
import { TakeoverToken } from "../../src/token/TakeoverToken.sol";
import {
    INonfungiblePositionManager,
    IPancakeV3Factory,
    IPancakeV3Pool
} from "../../src/interfaces/external/IPancakeV3.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice BSC-mainnet fork test for `GenericBuybackKeeper` against the REAL PancakeSwap V3
///         SwapRouter on BSC. TAKEOVER is a token WE deploy, so no WBNB/TAKEOVER pool exists
///         on mainnet; we mirror the V3 adapter fork test and stand up an ISOLATED pool
///         (create -> initialize at 1:1 -> seed a full-range position from this test) so the
///         keeper's `convert` swap has a real on-chain counterparty. We then assert the swap
///         converts the keeper's entire WBNB revenue balance into TAKEOVER and forwards it to
///         the configured receiver.
contract BuybackKeeperForkTest is ForkBase {
    INonfungiblePositionManager internal npm =
        INonfungiblePositionManager(BscAddresses.PANCAKE_V3_POSITION_MANAGER);
    IPancakeV3Factory internal factory = IPancakeV3Factory(BscAddresses.PANCAKE_V3_FACTORY);

    GenericBuybackKeeper internal keeper;
    TakeoverToken internal takeover;
    address internal receiver;

    uint24 internal constant FEE = 10_000; // 1% tier, tickSpacing 200
    int24 internal constant TICK_LOWER = -887_200;
    int24 internal constant TICK_UPPER = 887_200;
    uint160 internal constant SQRT_P_1TO1 = 79_228_162_514_264_337_593_543_950_336; // 2^96

    function setUp() public {
        _forkBsc();

        // TAKEOVER is a token we deploy; the full supply lands on this test contract.
        takeover = new TakeoverToken(address(this), 1_000_000 ether);

        receiver = makeAddr("receiver");
        keeper = new GenericBuybackKeeper(
            BscAddresses.PANCAKE_V3_SWAP_ROUTER, address(takeover), receiver, address(this)
        );

        // Stand up the isolated WBNB/TAKEOVER pool so the keeper's swap has a counterparty.
        _createIsolatedPool();
    }

    function _sorted() internal view returns (address token0, address token1) {
        (token0, token1) = address(takeover) < BscAddresses.WBNB
            ? (address(takeover), BscAddresses.WBNB)
            : (BscAddresses.WBNB, address(takeover));
    }

    /// @notice Create + initialize an isolated WBNB/TAKEOVER V3 pool at price 1:1 and seed a
    ///         full-range position owned by this test — the swap's sole liquidity source.
    function _createIsolatedPool() internal {
        (address token0, address token1) = _sorted();
        address pool = factory.createPool(token0, token1, FEE);
        IPancakeV3Pool(pool).initialize(SQRT_P_1TO1);

        // Provide both sides: real WBNB via the base helper, TAKEOVER from minted supply.
        _mintWBNB(address(this), 500 ether);
        IERC20(BscAddresses.WBNB).approve(address(npm), type(uint256).max);
        takeover.approve(address(npm), type(uint256).max);

        npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: 200 ether,
                amount1Desired: 200 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }

    /// @notice The happy path: keeper holds WBNB revenue, `convert` swaps ALL of it into
    ///         TAKEOVER through the real router and forwards the proceeds to `receiver`.
    function test_Convert_SwapsWbnbIntoTakeover() public {
        // Fund the keeper with WBNB revenue to be bought back.
        _mintWBNB(address(keeper), 5 ether);
        assertEq(IERC20(BscAddresses.WBNB).balanceOf(address(keeper)), 5 ether);
        assertEq(takeover.balanceOf(receiver), 0, "receiver starts empty");

        uint256 amountOut = keeper.convert(BscAddresses.WBNB, FEE, 0);

        // Real swap happened: TAKEOVER came out and went to the receiver.
        assertGt(amountOut, 0, "swap should return TAKEOVER");
        assertEq(takeover.balanceOf(receiver), amountOut, "receiver credited exactly amountOut");
        // Keeper swapped its ENTIRE tokenIn balance.
        assertEq(IERC20(BscAddresses.WBNB).balanceOf(address(keeper)), 0, "keeper WBNB fully spent");
    }

    /// @notice `convert` reverts when the keeper holds none of the requested tokenIn.
    function test_Convert_RevertNothing() public {
        assertEq(IERC20(BscAddresses.WBNB).balanceOf(address(keeper)), 0, "keeper unfunded");
        vm.expectRevert(bytes("nothing"));
        keeper.convert(BscAddresses.WBNB, FEE, 0);
    }

    /// @notice `setReceiver` is owner-gated; the owner can rotate the receiver.
    function test_SetReceiver_OnlyOwner() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        keeper.setReceiver(stranger);

        address newReceiver = makeAddr("newReceiver");
        keeper.setReceiver(newReceiver);
        assertEq(keeper.receiver(), newReceiver, "owner can rotate receiver");
    }
}
