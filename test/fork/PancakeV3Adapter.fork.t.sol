// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ForkBase } from "./ForkBase.t.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { BscAddresses } from "../../src/config/BscAddresses.sol";
import { UnifiedGridManager } from "../../src/core/UnifiedGridManager.sol";
import { PancakeV3YieldAdapter } from "../../src/adapters/PancakeV3YieldAdapter.sol";
import { CreateGridParams } from "../../src/libraries/GridTypes.sol";
import {
    INonfungiblePositionManager,
    IPancakeV3SwapRouter,
    IPancakeV3Factory,
    IPancakeV3Pool
} from "../../src/interfaces/external/IPancakeV3.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Fork test for the PancakeSwap V3 adapter against the REAL Pancake V3 contracts
///         on BSC. To make fees deterministic, we create an isolated MockToken/WBNB pool
///         at the 1% tier where the adapter's position is the sole liquidity, run swaps to
///         accrue fees, then harvest and assert the yield reaches the UGM.
contract PancakeV3AdapterForkTest is ForkBase {
    INonfungiblePositionManager internal npm =
        INonfungiblePositionManager(BscAddresses.PANCAKE_V3_POSITION_MANAGER);
    IPancakeV3SwapRouter internal router = IPancakeV3SwapRouter(BscAddresses.PANCAKE_V3_SWAP_ROUTER);
    IPancakeV3Factory internal factory = IPancakeV3Factory(BscAddresses.PANCAKE_V3_FACTORY);

    UnifiedGridManager internal ugm;
    PancakeV3YieldAdapter internal adapter;
    MockERC20 internal myt;

    uint24 internal constant FEE = 10_000; // 1% tier, tickSpacing 200
    int24 internal constant TICK_LOWER = -887_200;
    int24 internal constant TICK_UPPER = 887_200;
    uint160 internal constant SQRT_P_1TO1 = 79_228_162_514_264_337_593_543_950_336; // 2^96

    function setUp() public {
        _forkBsc();
        myt = new MockERC20("MockYield", "MYT");

        ugm = new UnifiedGridManager(address(this), 0, 0, 0);
        adapter = new PancakeV3YieldAdapter(
            address(ugm), address(npm), address(router), address(this)
        );
        ugm.setApprovedAdapter(address(adapter), true);
        ugm.setAllowedTaxToken(BscAddresses.WBNB, true);

        // Fund this test with both tokens.
        _mintWBNB(address(this), 500 ether);
        myt.mint(address(this), 1_000_000 ether);

        IERC20(address(WBNB)).approve(address(npm), type(uint256).max);
        myt.approve(address(npm), type(uint256).max);
        IERC20(address(WBNB)).approve(address(router), type(uint256).max);
        myt.approve(address(router), type(uint256).max);
    }

    function _sorted() internal view returns (address token0, address token1) {
        (token0, token1) =
            address(myt) < BscAddresses.WBNB ? (address(myt), BscAddresses.WBNB) : (BscAddresses.WBNB, address(myt));
    }

    /// @notice F-02: the permissionless `collectYield` forwards ONLY the already-WBNB (yield-side)
    ///         fees and performs NO swap (nothing sandwichable), leaving the MYT side in the
    ///         adapter. The slippage-guarded `harvestWithMinOut` is the only path that swaps the
    ///         MYT side into WBNB, under a caller-supplied `minOut` floor.
    function test_HarvestRealV3FeesIntoGrid() public {
        // 1. Create + initialize an isolated pool.
        (address token0, address token1) = _sorted();
        address pool = factory.createPool(token0, token1, FEE);
        IPancakeV3Pool(pool).initialize(SQRT_P_1TO1);

        // 2. Mint a full-range position owned by the adapter.
        (uint256 tokenId,,,) = npm.mint(
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
                recipient: address(adapter),
                deadline: block.timestamp
            })
        );
        assertEq(npm.ownerOf(tokenId), address(adapter));

        // 3. Generate real swap fees (adapter's position is the only liquidity).
        //    Round-trip swaps sized within the pool's liquidity so price stays in range.
        //    MYT->WBNB legs accrue MYT fees; WBNB->MYT legs accrue WBNB fees.
        _swap(address(myt), BscAddresses.WBNB, 20 ether);
        _swap(BscAddresses.WBNB, address(myt), 20 ether);
        _swap(address(myt), BscAddresses.WBNB, 20 ether);
        _swap(BscAddresses.WBNB, address(myt), 20 ether);

        // pendingYield never reverts and is 0 for an asset this adapter does not know.
        assertEq(adapter.pendingYield(bytes32(uint256(0xdead))), 0, "unregistered asset -> 0");

        // 4. Wire the position to a WBNB-yield grid.
        uint256 gridId = _createWbnbGrid();
        bytes32 assetHash = adapter.registerPosition(gridId, tokenId, BscAddresses.WBNB, FEE);

        // One position per yield token (mirrors FlapYieldAdapter). `_harvest` sweeps the adapter's WHOLE
        // balance of the yield token, so a second position claiming WBNB could carry off this position's
        // residual — registering it must be rejected outright.
        vm.expectRevert(bytes("yieldToken in use"));
        adapter.registerPosition(gridId, tokenId, BscAddresses.WBNB, FEE);

        // pendingYield reads the position's tokensOwed best-effort without reverting.
        adapter.pendingYield(assetHash);

        // 5. Permissionless collectYield: forwards ONLY the WBNB (yield) side, performs NO swap.
        uint256 ugmBefore = IERC20(address(WBNB)).balanceOf(address(ugm));
        uint256 forwarded1 = adapter.collectYield(assetHash);

        assertGt(forwarded1, 0, "collectYield forwards the WBNB fee side");
        assertEq(IERC20(address(WBNB)).balanceOf(address(ugm)) - ugmBefore, forwarded1, "UGM received exactly forwarded");
        assertEq(IERC20(address(WBNB)).balanceOf(address(adapter)), 0, "all collected WBNB forwarded");
        // The non-yield MYT side was collected but NOT swapped: it sits in the adapter (no
        // 0-slippage swap on the permissionless path).
        uint256 mytRetained = myt.balanceOf(address(adapter));
        assertGt(mytRetained, 0, "collect did NOT swap the MYT side");
        assertGt(ugm.pendingYieldSeat(gridId, 0), 0, "grid seat has pending yield from the WBNB side");

        // 6. Slippage-guarded harvest: converts the retained MYT into WBNB under a minOut floor
        //    and forwards it. This is the ONLY path that swaps.
        uint256 ugmBefore2 = IERC20(address(WBNB)).balanceOf(address(ugm));
        uint256 forwarded2 = adapter.harvestWithMinOut(assetHash, 1); // minOut = 1 wei guard (non-zero)

        assertGt(forwarded2, 0, "harvestWithMinOut swaps the MYT side into WBNB and forwards it");
        assertEq(IERC20(address(WBNB)).balanceOf(address(ugm)) - ugmBefore2, forwarded2, "UGM received the swapped WBNB");
        assertEq(myt.balanceOf(address(adapter)), 0, "MYT side fully converted by the guarded path");

        // 7. Idempotency: with no further swaps, another collectYield forwards 0.
        uint256 ugmBefore3 = IERC20(address(WBNB)).balanceOf(address(ugm));
        uint256 forwarded3 = adapter.collectYield(assetHash);
        assertEq(forwarded3, 0, "2nd collectYield with no new fees forwards 0");
        assertEq(IERC20(address(WBNB)).balanceOf(address(ugm)), ugmBefore3, "UGM unchanged by idempotent call");
    }

    function _createWbnbGrid() internal returns (uint256 gridId) {
        gridId = ugm.createGrid(
            CreateGridParams({
                totalSeats: 4,
                taxRateBps: 500,
                forfeitureDuration: 0,
                taxToken: BscAddresses.WBNB,
                yieldToken: BscAddresses.WBNB,
                initialPrice: 1 ether
            })
        );
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn) internal {
        router.exactInputSingle(
            IPancakeV3SwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: FEE,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }
    /// @notice COM-MEV-SANDWICH fix: the swap path `harvestWithMinOut` is now owner-gated, so a
    ///         stranger can no longer trigger it with minOut=0 and sandwich the pool swap.
    function test_HarvestWithMinOut_OnlyOwner_RevertsForStranger() public {
        bytes32 assetHash = keccak256("pv3.asset");
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(bytes("not owner/guardian"));
        adapter.harvestWithMinOut(assetHash, 0);
    }
}
