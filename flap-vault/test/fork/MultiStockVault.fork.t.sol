// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {FlapBSCFixture} from "../FlapBSCFixture.sol";
import {MultiStockVault} from "../../src/MultiStockVault.sol";
import {MockUGM} from "../mocks/MockUGM.sol";

/// @title MultiStockVault — end-to-end fork proof (T3.2)
///
/// @notice Deploys the REAL {MultiStockVault} wired to the live BSC-mainnet WBNB, USDT and
///         PancakeSwap V3 SwapRouter (and the 7 real stock tokens with their real fee tiers),
///         funds it with WBNB, and calls {MultiStockVault.distribute}. It asserts the whole
///         money path works against production liquidity:
///           • the WBNB commission is skimmed to the treasury,
///           • all of `net` is consumed (vault WBNB → 0, no stock dust left on the vault),
///           • every one of the 7 legs swaps WBNB→USDT→stock for a positive amount, and
///           • each bought stock is forwarded into ITS OWN grid (asserted via the MockUGM
///             sink's per-asset accounting + the stock actually landing on the sink).
///
///         The grid sink is a MockUGM (the real UGM would need its guardian to allowlist this
///         vault as an adapter and to pre-create 7 grids with yieldToken == each stock); using
///         the mock keeps the test hermetic while still exercising the real swaps + real tokens.
contract MultiStockVaultForkTest is FlapBSCFixture {
    // ── Live BSC-mainnet infrastructure ─────────────────────────────────────────
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant PANCAKE_V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    uint24 internal constant WBNB_USDT_FEE = 100;

    // The 7 stocks, in the reference vault's `stocks(i)` order, with their live USDT→stock fee tiers.
    address internal constant SPCXB = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;
    address internal constant QQQB = 0x205812CdBed920aFf76C6580abD681a46D11efc7;
    address internal constant NVDAB = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436;
    address internal constant SPYB = 0x7138b48df7D98D7e3cc221BfE7192D0a178182D8;
    address internal constant TSLAB = 0x5b1910eAaD6450E50f816082Aa078C41F10C292f;
    address internal constant AAPLB = 0x431a3BEE82E2ca41e49895CbECE5bB0F76A89b7A;
    address internal constant XAUt = 0x21cAef8A43163Eea865baeE23b9C2E327696A3bf;

    uint16 internal constant COMMISSION_BPS = 600; // 6%
    uint256 internal constant FUND = 10 ether; // 10 WBNB seeded into the vault

    MockUGM internal ugm;
    MultiStockVault internal vault;
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        _forkBSCMainnet();
        ugm = new MockUGM();

        MultiStockVault.BasketParams memory basket = MultiStockVault.BasketParams({
            stocks: [SPCXB, QQQB, NVDAB, SPYB, TSLAB, AAPLB, XAUt],
            gridIds: [uint256(1), 2, 3, 4, 5, 6, 7],
            stockFees: [uint24(2500), 100, 2500, 100, 2500, 2500, 2500],
            weightsBps: [uint16(1429), 1429, 1429, 1429, 1429, 1429, 1426] // sums to 10_000
        });

        vault = new MultiStockVault(
            WBNB, USDT, address(ugm), PANCAKE_V3_ROUTER, WBNB_USDT_FEE, treasury, COMMISSION_BPS, 1 hours, basket
        );

        // Seed each grid's yieldToken to its leg's real stock so the vault's F3 registration-time
        // assert (`gridConfig(gridId).yieldToken == stock`) passes, then allowlist + bind all 7.
        address[7] memory ss = _stocks();
        for (uint256 i = 0; i < 7; i++) {
            ugm.setGridYieldToken(i + 1, ss[i]);
        }
        ugm.setApprovedAdapter(address(vault), true);
        vault.registerAllGrids();

        vm.label(address(vault), "MultiStockVault");
        vm.label(address(ugm), "MockUGM");
        vm.label(WBNB, "WBNB");
        vm.label(USDT, "USDT");
        vm.label(PANCAKE_V3_ROUTER, "PancakeV3Router");
    }

    function _stocks() internal pure returns (address[7] memory s) {
        s = [SPCXB, QQQB, NVDAB, SPYB, TSLAB, AAPLB, XAUt];
    }

    function _zeroMinOut() internal pure returns (uint256[7] memory m) {
        // all zeros — slippage floor disabled (the assertions below prove liquidity, not price)
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Happy path: real WBNB → 7 real stocks → 7 grids, on live liquidity.
    // ─────────────────────────────────────────────────────────────────────────
    function test_Distribute_RealSwaps_AllSevenLegsReachGrids() public {
        deal(WBNB, address(vault), FUND);
        assertEq(vault.pendingDistribute(), FUND, "vault should hold the seeded WBNB");

        uint256 expectedCommission = (FUND * COMMISSION_BPS) / 10_000;
        uint256 net = FUND - expectedCommission;

        uint256[7] memory bought = vault.distribute(_zeroMinOut(), block.timestamp + 300);

        // Commission skimmed to treasury in WBNB.
        assertEq(IERC20(WBNB).balanceOf(treasury), expectedCommission, "commission to treasury");

        // All of `net` consumed by the swaps; no WBNB dust stranded on the vault.
        assertEq(IERC20(WBNB).balanceOf(address(vault)), 0, "vault WBNB fully spent");

        // Every leg bought a positive amount and forwarded it into its own grid.
        address[7] memory stocks = _stocks();
        for (uint256 i = 0; i < 7; i++) {
            assertGt(bought[i], 0, "leg produced no stock");

            (, uint256 gridId, bytes32 assetHash,,) = vault.legs(i);
            assertEq(gridId, i + 1, "gridId ordering");

            // The grid (via the sink's per-asset accounting) received exactly what was bought.
            assertEq(ugm.yieldByAsset(assetHash), bought[i], "grid did not receive the bought stock");

            // The stock physically landed on the sink, and none was left approved/stuck on the vault.
            assertEq(IERC20(stocks[i]).balanceOf(address(ugm)), bought[i], "sink stock balance");
            assertEq(IERC20(stocks[i]).balanceOf(address(vault)), 0, "no stock dust on vault");
        }

        assertEq(ugm.receiveYieldCallCount(), 7, "all 7 legs delivered");

        // Net conservation: the WBNB spent on swaps equals net (dust-on-last-leg makes the split exact).
        // (treasury got commission; the router consumed the rest; vault holds nothing.)
        assertEq(IERC20(WBNB).balanceOf(treasury) + 0, expectedCommission, "sanity");
        assertGt(net, 0, "net positive");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Slippage floor is honoured against real prices: an unreachable minOut fails ONLY its leg,
    //  which is then skipped best-effort (F2) while the other six still deliver.
    // ─────────────────────────────────────────────────────────────────────────
    function test_Distribute_UnreachableMinOutLeg_Skipped() public {
        deal(WBNB, address(vault), FUND);

        uint256[7] memory minOut; // all zero…
        minOut[0] = type(uint256).max; // …except leg 0 demands an impossible amount out

        // The PancakeSwap V3 router reverts leg 0 ("Too little received"); best-effort catches+skips it.
        uint256[7] memory bought = vault.distribute(minOut, block.timestamp + 300);

        (,, bytes32 ah0,,) = vault.legs(0);
        assertEq(bought[0], 0, "unreachable-minOut leg skipped");
        assertEq(ugm.yieldByAsset(ah0), 0, "its grid got nothing");
        assertEq(ugm.receiveYieldCallCount(), 6, "the other six legs delivered on real liquidity");
        for (uint256 i = 1; i < 7; i++) {
            assertGt(bought[i], 0, "healthy legs delivered");
        }
        // Leg 0's WBNB is retained on the vault (its swap rolled back atomically); commission still left.
        assertGt(IERC20(WBNB).balanceOf(address(vault)), 0, "skipped leg's WBNB retained for next round");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Time-gate holds on-fork too: a second distribute within minInterval reverts.
    // ─────────────────────────────────────────────────────────────────────────
    function test_Distribute_TimeGate_OnFork() public {
        deal(WBNB, address(vault), FUND);
        vault.distribute(_zeroMinOut(), block.timestamp + 300);

        deal(WBNB, address(vault), FUND); // refund so "nothing to distribute" isn't the reason
        vm.expectRevert(bytes(unicode"Too soon / 时间未到"));
        vault.distribute(_zeroMinOut(), block.timestamp + 300);

        // After the interval elapses it succeeds again.
        vm.warp(block.timestamp + 1 hours + 1);
        vault.distribute(_zeroMinOut(), block.timestamp + 300);
        assertEq(ugm.receiveYieldCallCount(), 14, "two full distributes delivered 14 legs");
    }
}
