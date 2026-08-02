// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ForkBase } from "./ForkBase.t.sol";
import { BscAddresses } from "../../src/config/BscAddresses.sol";
import { UnifiedGridManager } from "../../src/core/UnifiedGridManager.sol";
import { PancakeV3YieldAdapter } from "../../src/adapters/PancakeV3YieldAdapter.sol";
import { FlapYieldAdapter } from "../../src/adapters/FlapYieldAdapter.sol";
import { GenericBuybackKeeper } from "../../src/keeper/GenericBuybackKeeper.sol";
import { TakeoverToken } from "../../src/token/TakeoverToken.sol";
import { AntiSnipeHook } from "../../src/hooks/AntiSnipeHook.sol";
import { CreateGridParams, Seat, GridConfig } from "../../src/libraries/GridTypes.sol";
import {
    INonfungiblePositionManager,
    IPancakeV3SwapRouter,
    IPancakeV3Factory,
    IPancakeV3Pool
} from "../../src/interfaces/external/IPancakeV3.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice ONE comprehensive end-to-end scenario on a BSC-mainnet fork that deploys the FULL
///         Takeover BNB protocol exactly like `script/Deploy.s.sol` and drives the whole
///         product lifecycle end to end, all denominated in the REAL STOCK token
///         ("SpaceX" / SPCXB, 0xbe9D…03E1) — the canonical Flap-fee asset (see DECISIONS D9):
///
///           deploy (token + UGM + V3 adapter + Flap adapter + buyback keeper + hook)
///             → open a STOCK grid
///             → wire a REAL PancakeSwap V3 STOCK/WBNB position and harvest its fees as STOCK yield
///             → Harberger seat lifecycle: claim, buyout cooldown, takeover
///             → Flap STOCK fee stream distributed across the same seats
///             → holder claims STOCK yield
///             → continuous tax depletes a thin deposit → seat forfeits back to the creator
///             → grid STOCK revenue is bought back into TAKEOVER via the keeper
///             → AntiSnipeHook vetoes a claim on a fresh grid until its snipe window opens
///
/// @dev The live STOCK/WBNB 1% (fee 10000) pool already exists on BSC, so an isolated position
///      there could never be the sole liquidity. To keep fee accrual deterministic we open the
///      adapter's position at the UNUSED 2500 tier (still a real Pancake V3 STOCK/WBNB pool where
///      our position is the only liquidity), mirroring `PancakeV3Adapter.fork.t.sol`. TAKEOVER is
///      freshly deployed, so its STOCK pool is stood up from scratch at the 1% tier.
contract EndToEndForkTest is ForkBase {
    // --- Real BSC infrastructure ---
    INonfungiblePositionManager internal npm =
        INonfungiblePositionManager(BscAddresses.PANCAKE_V3_POSITION_MANAGER);
    IPancakeV3SwapRouter internal router = IPancakeV3SwapRouter(BscAddresses.PANCAKE_V3_SWAP_ROUTER);
    IPancakeV3Factory internal factory = IPancakeV3Factory(BscAddresses.PANCAKE_V3_FACTORY);
    IERC20 internal stock = IERC20(BscAddresses.STOCK);

    // --- Full protocol (deployed in setUp like Deploy.s.sol, guardian = this test) ---
    TakeoverToken internal takeover;
    UnifiedGridManager internal ugm;
    PancakeV3YieldAdapter internal v3;
    FlapYieldAdapter internal flap;
    GenericBuybackKeeper internal keeper;
    AntiSnipeHook internal hook;

    // --- Actors ---
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal receiver = makeAddr("buybackReceiver");
    address internal flapLaunch = makeAddr("spacexPairedLaunch");

    // --- Constants ---
    uint160 internal constant SQRT_P_1TO1 = 79_228_162_514_264_337_593_543_950_336; // 2^96, price 1:1
    uint24 internal constant FEE_YIELD = 2500; // isolated STOCK/WBNB tier (10000 already exists on BSC)
    uint24 internal constant FEE_BUYBACK = 10_000; // isolated STOCK/TAKEOVER tier (TAKEOVER just deployed)
    int24 internal constant SPACING_YIELD = 50; // tickSpacing for the 2500 tier
    int24 internal constant SPACING_BUYBACK = 200; // tickSpacing for the 10000 tier

    uint256 internal mainGrid;
    bytes32 internal v3Asset;
    bytes32 internal flapAsset;

    // ------------------------------------------------------------------ //
    //                               setUp                                //
    // ------------------------------------------------------------------ //
    function setUp() public {
        _forkBsc();

        // Deploy the full system exactly like script/Deploy.s.sol, guardian = address(this).
        takeover = new TakeoverToken(address(this), 1_000_000 ether);
        ugm = new UnifiedGridManager(address(this), 100, 0, 0); // 1% protocol seat-sale cut
        v3 = new PancakeV3YieldAdapter(address(ugm), address(npm), address(router), address(this));
        flap = new FlapYieldAdapter(
            address(ugm), BscAddresses.FLAP_PORTAL, BscAddresses.FLAP_VAULT_PORTAL, address(this)
        );
        keeper = new GenericBuybackKeeper(
            BscAddresses.PANCAKE_V3_SWAP_ROUTER, address(takeover), receiver, address(this)
        );
        hook = new AntiSnipeHook(address(this));

        ugm.setApprovedAdapter(address(v3), true);
        ugm.setApprovedAdapter(address(flap), true);
        ugm.setApprovedModule(address(hook), true);
        // Allow STOCK as a tax token and route the protocol fee bucket to the buyback keeper.
        ugm.setAllowedTaxToken(BscAddresses.STOCK, true);
        ugm.setProtocolFeeReceiver(address(keeper));

        // Fund actors with STOCK (grid tax + yield token) and approve the UGM.
        address[3] memory actors = [creator, alice, bob];
        for (uint256 i; i < actors.length; ++i) {
            deal(BscAddresses.STOCK, actors[i], 100_000 ether);
            vm.prank(actors[i]);
            stock.approve(address(ugm), type(uint256).max);
        }
    }

    // ------------------------------------------------------------------ //
    //                       The one big scenario                         //
    // ------------------------------------------------------------------ //
    function test_EndToEnd_FullProtocolLifecycle() public {
        // === 1. Creator opens a STOCK-denominated grid (4 seats, 5%/week tax) ===
        mainGrid = _openStockGrid(creator, 4, 500, 1 ether);
        {
            GridConfig memory c = ugm.gridConfig(mainGrid);
            assertEq(c.creator, creator, "creator owns the grid");
            assertEq(c.totalSeats, 4, "4 seats");
            assertEq(c.taxToken, BscAddresses.STOCK, "priced in STOCK");
            assertEq(c.yieldToken, BscAddresses.STOCK, "paid in STOCK");
            assertEq(ugm.seatInfo(mainGrid, 0).holder, creator, "seats start creator-owned");
        }

        // === 2. Real PancakeSwap V3 STOCK/WBNB position → STOCK yield reaches the UGM ===
        // Fund this test to seed the pool and drive swaps; approve Pancake infra once.
        deal(BscAddresses.STOCK, address(this), 2_000_000 ether);
        _mintWBNB(address(this), 1_000 ether);
        _approveInfra();
        {
            _createPool(BscAddresses.STOCK, BscAddresses.WBNB, FEE_YIELD);
            uint256 tokenId =
                _mintFull(BscAddresses.STOCK, BscAddresses.WBNB, FEE_YIELD, SPACING_YIELD, 200 ether, address(v3));
            assertEq(npm.ownerOf(tokenId), address(v3), "V3 position held by the adapter");

            // Round-trip swaps accrue fees on BOTH sides (fee is taken from the input token):
            // STOCK->WBNB legs accrue the STOCK (yield) side; WBNB->STOCK legs accrue the WBNB side.
            _swap(BscAddresses.STOCK, BscAddresses.WBNB, FEE_YIELD, 20 ether);
            _swap(BscAddresses.WBNB, BscAddresses.STOCK, FEE_YIELD, 20 ether);
            _swap(BscAddresses.STOCK, BscAddresses.WBNB, FEE_YIELD, 20 ether);
            _swap(BscAddresses.WBNB, BscAddresses.STOCK, FEE_YIELD, 20 ether);

            v3Asset = v3.registerPosition(mainGrid, tokenId, BscAddresses.STOCK, FEE_YIELD);

            // Permissionless collectYield: forwards ONLY the STOCK (yield) side, no swap.
            uint256 ugmStockBefore = stock.balanceOf(address(ugm));
            uint256 forwarded = v3.collectYield(v3Asset);
            assertGt(forwarded, 0, "collectYield forwards the STOCK fee side");
            assertEq(stock.balanceOf(address(ugm)) - ugmStockBefore, forwarded, "UGM received exactly forwarded STOCK");
            assertGt(ugm.pendingYieldSeat(mainGrid, 0), 0, "seat has pending STOCK yield");

            // Guarded harvest additionally swaps the retained WBNB side into STOCK and forwards it.
            uint256 forwarded2 = v3.harvestWithMinOut(v3Asset, 1);
            assertGt(forwarded2, 0, "harvestWithMinOut swaps the WBNB side into STOCK");
        }

        // === 3. Seat lifecycle: claim, immediate (non-cooldown-gated) takeover (all in STOCK) ===
        {
            vm.prank(alice);
            ugm.buySeat(mainGrid, 0, 5 ether, 100 ether, 0); // alice claims seat 0
            vm.prank(bob);
            ugm.buySeat(mainGrid, 1, 5 ether, 100 ether, 0); // bob claims seat 1
            assertEq(ugm.seatInfo(mainGrid, 0).holder, alice, "alice holds seat 0");
            assertEq(ugm.seatInfo(mainGrid, 1).holder, bob, "bob holds seat 1");

            // Buyouts are never cooldown-gated: alice takes over bob's seat 1 at his declared price
            // straight away (let a little tax accrue first).
            vm.warp(block.timestamp + 21 minutes);
            uint256 bobBefore = stock.balanceOf(bob);
            vm.prank(alice);
            ugm.buySeat(mainGrid, 1, 6 ether, 100 ether, 0);
            assertEq(ugm.seatInfo(mainGrid, 1).holder, alice, "alice took over seat 1");
            // bob refunded his ~100 STOCK deposit + sale proceeds (5 - 1% fee), minus tiny held-time tax.
            assertGt(stock.balanceOf(bob) - bobBefore, 100 ether, "bob refunded deposit + proceeds in STOCK");
        }

        // === 4. Flap STOCK fee stream distributed across the same seats ===
        // The canonical product flow: a Flap launch paired with STOCK accrues STOCK trading fees,
        // which the FlapYieldAdapter forwards into the grid. Alice now holds seats 0 and 1.
        {
            flapAsset = flap.registerFlapToken(mainGrid, flapLaunch, BscAddresses.STOCK);
            deal(BscAddresses.STOCK, address(flap), 40 ether); // simulate accrued STOCK fees to the adapter
            uint256 forwardedFlap = flap.collectYield(flapAsset);
            assertEq(forwardedFlap, 40 ether, "Flap adapter forwards the STOCK fee stream");
            assertEq(ugm.pendingYieldSeat(mainGrid, 0), 10 ether, "40 STOCK split across 4 seats");
        }

        // === 5. Holder claims STOCK yield ===
        {
            uint256 aliceBefore = stock.balanceOf(alice);
            ugm.claimYield(mainGrid, 0); // settle seat 0's yield to its holder (alice)
            vm.prank(alice);
            ugm.claimPayout(BscAddresses.STOCK);
            assertEq(stock.balanceOf(alice) - aliceBefore, 10 ether, "alice received her seat's STOCK yield");
        }

        // === 6. Continuous tax -> Dutch-auction forfeiture on a thin deposit ===
        // bob claims seat 2 at a high price with a thin deposit; tax outruns the deposit and the
        // seat forfeits into its Dutch window (vacant, price preserved). (Isolated on seat 2.)
        {
            uint256 revBefore = ugm.gridTaxRevenue(mainGrid);
            vm.prank(bob);
            ugm.buySeat(mainGrid, 2, 10 ether, 0.1 ether, 0); // 10 STOCK price, 0.1 STOCK deposit
            // Capture the creator's payout AFTER the claim (buying from the creator settles the
            // creator's accrued yield on seat 2), so the delta below isolates the consumed tax.
            uint256 creatorPayoutBefore = ugm.payouts(BscAddresses.STOCK, creator);
            vm.warp(block.timestamp + 2 days); // 10 * 5%/wk * 2/7 wk ≈ 0.143 > 0.1 deposit
            ugm.pokeTax(mainGrid, 2);

            Seat memory s2 = ugm.seatInfo(mainGrid, 2);
            assertEq(s2.holder, address(0), "seat 2 forfeited into its Dutch window");
            assertEq(s2.price, 10 ether, "forfeited seat keeps its price to anchor the Dutch decay");
            assertEq(s2.deposit, 0, "forfeited seat has no deposit");
            assertEq(ugm.forfeitedFrom(mainGrid, 2), bob, "bob recorded as the forfeited holder");
            // Protocol bucket grew only by the 1% fee on the 1 STOCK claim; the consumed 0.1 deposit
            // accrues to the creator (protocolTaxBps == 0).
            assertEq(ugm.gridTaxRevenue(mainGrid) - revBefore, 0.01 ether, "seat-sale fee -> protocol bucket");
            assertEq(ugm.payouts(BscAddresses.STOCK, creator) - creatorPayoutBefore, 0.1 ether, "consumed tax -> creator");
        }

        // === 7. Buyback: grid STOCK revenue → TAKEOVER via the keeper ===
        // Stand up an isolated STOCK/TAKEOVER pool (TAKEOVER just deployed, so none exists), route
        // the grid's accrued STOCK revenue to the keeper, and buy back TAKEOVER for the receiver.
        {
            _createPool(BscAddresses.STOCK, address(takeover), FEE_BUYBACK);
            _mintFull(BscAddresses.STOCK, address(takeover), FEE_BUYBACK, SPACING_BUYBACK, 200 ether, address(this));

            uint256 rev = ugm.gridTaxRevenue(mainGrid);
            assertGt(rev, 0, "grid accrued STOCK protocol revenue");
            // protocolFeeReceiver was set to the keeper in setUp; the sweep routes the bucket there.
            ugm.withdrawTaxRevenue(mainGrid);
            assertEq(stock.balanceOf(address(keeper)), rev, "keeper funded with the STOCK revenue");

            assertEq(takeover.balanceOf(receiver), 0, "receiver starts with no TAKEOVER");
            uint256 out = keeper.convert(BscAddresses.STOCK, FEE_BUYBACK, 0);
            assertGt(out, 0, "buyback swap produced TAKEOVER");
            assertEq(takeover.balanceOf(receiver), out, "receiver credited the bought-back TAKEOVER");
            assertEq(stock.balanceOf(address(keeper)), 0, "keeper spent its entire STOCK balance");
        }

        // === 8. AntiSnipeHook vetoes a launch claim until the grid's snipe window opens ===
        {
            uint256 grid2 = _openStockGrid(creator, 4, 500, 1 ether);
            ugm.setGridGovernanceModule(grid2, address(hook)); // owner wires the approved module
            hook.setClaimOpenAt(grid2, uint64(block.timestamp + 1 hours));

            // Claim before the window opens is vetoed by the hook.
            vm.prank(alice);
            vm.expectRevert(bytes("hook: claim vetoed"));
            ugm.buySeat(grid2, 0, 2 ether, 10 ether, 0);

            // Once the window opens, the same claim succeeds.
            vm.warp(block.timestamp + 61 minutes);
            vm.prank(alice);
            ugm.buySeat(grid2, 0, 2 ether, 10 ether, 0);
            assertEq(ugm.seatInfo(grid2, 0).holder, alice, "claim allowed after the snipe window");
        }
    }

    // ------------------------------------------------------------------ //
    //                              Helpers                               //
    // ------------------------------------------------------------------ //
    function _openStockGrid(address who, uint32 seats, uint16 taxBps, uint128 price)
        internal
        returns (uint256 gridId)
    {
        vm.prank(who);
        gridId = ugm.createGrid(
            CreateGridParams({
                totalSeats: seats,
                taxRateBps: taxBps,
                forfeitureDuration: 0,
                taxToken: BscAddresses.STOCK,
                yieldToken: BscAddresses.STOCK,
                initialPrice: price
            })
        );
    }

    function _approveInfra() internal {
        address[3] memory toks = [BscAddresses.STOCK, BscAddresses.WBNB, address(takeover)];
        for (uint256 i; i < toks.length; ++i) {
            IERC20(toks[i]).approve(address(npm), type(uint256).max);
            IERC20(toks[i]).approve(address(router), type(uint256).max);
        }
    }

    function _sorted(address a, address b) internal pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }

    /// @dev Full-range tick bounds for a fee tier's tick spacing (nearest multiples within MAX_TICK).
    function _fullRange(int24 spacing) internal pure returns (int24 lower, int24 upper) {
        int24 hi = (int24(887_272) / spacing) * spacing;
        return (-hi, hi);
    }

    /// @dev Create + initialize (1:1) an isolated pool; requires that none exists at this tier.
    function _createPool(address a, address b, uint24 fee) internal returns (address pool) {
        (address t0, address t1) = _sorted(a, b);
        require(factory.getPool(t0, t1, fee) == address(0), "pool already exists");
        pool = factory.createPool(t0, t1, fee);
        IPancakeV3Pool(pool).initialize(SQRT_P_1TO1);
    }

    /// @dev Mint a full-range position with equal desired amounts of each side to `recipient`.
    function _mintFull(address a, address b, uint24 fee, int24 spacing, uint256 amt, address recipient)
        internal
        returns (uint256 tokenId)
    {
        (address t0, address t1) = _sorted(a, b);
        (int24 lower, int24 upper) = _fullRange(spacing);
        (tokenId,,,) = npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: t0,
                token1: t1,
                fee: fee,
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: amt,
                amount1Desired: amt,
                amount0Min: 0,
                amount1Min: 0,
                recipient: recipient,
                deadline: block.timestamp
            })
        );
    }

    function _swap(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn) internal {
        router.exactInputSingle(
            IPancakeV3SwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
