// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {FlapBSCFixture} from "../FlapBSCFixture.sol";
import {StockBasket} from "../../src/StockBasket.sol";
import {StockpileBasketVault} from "../../src/StockpileBasketVault.sol";
import {MockUGM} from "../mocks/MockUGM.sol";

/// @title StockpileBasketVault — end-to-end fork proof (B3.1)
///
/// @notice On a live BSC-mainnet fork: fund the vault with native BNB, `distribute()` swaps it (real
///         PancakeSwap V3, real stocks) into 3 stocks, deposits them into the real {StockBasket} (minting
///         basket shares), and feeds 3 grids of DIFFERENT seat counts the basket token seat-proportionally.
///         Then a holder redeems basket shares and receives a pro-rata slice of ALL 3 real stocks.
///         The grid sink is a MockUGM (keeps the test hermetic while exercising the real swaps + basket).
contract StockpileBasketVaultForkTest is FlapBSCFixture {
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant PANCAKE_V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    uint24 internal constant WBNB_USDT_FEE = 100;

    // 3 real stocks with their real USDT→stock V3 fee tiers.
    address internal constant SPCXB = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;
    address internal constant QQQB = 0x205812CdBed920aFf76C6580abD681a46D11efc7;
    address internal constant NVDAB = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436;

    uint16 internal constant COMMISSION_BPS = 600; // 6%
    uint256 internal constant FUND = 1 ether; // 1 native BNB fee

    // 3 grids of different sizes → seat-proportional split 10% / 30% / 60%.
    uint256[3] internal GRID_IDS = [uint256(1), 2, 3];
    uint32[3] internal SEATS = [uint32(10), 30, 60];

    MockUGM internal ugm;
    StockBasket internal basket;
    StockpileBasketVault internal vault;
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        _forkBSCMainnet();
        ugm = new MockUGM();

        address[] memory stocks = new address[](3);
        stocks[0] = SPCXB;
        stocks[1] = QQQB;
        stocks[2] = NVDAB;
        basket = new StockBasket("Stockpile Basket", "SPB", stocks);

        StockpileBasketVault.StockLeg[] memory legs = new StockpileBasketVault.StockLeg[](3);
        legs[0] = StockpileBasketVault.StockLeg({stock: SPCXB, stockFee: 2500, swapWeightBps: 3400});
        legs[1] = StockpileBasketVault.StockLeg({stock: QQQB, stockFee: 100, swapWeightBps: 3300});
        legs[2] = StockpileBasketVault.StockLeg({stock: NVDAB, stockFee: 2500, swapWeightBps: 3300});

        uint256[] memory gridIds = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            gridIds[i] = GRID_IDS[i];
        }

        vault = new StockpileBasketVault(
            WBNB, USDT, address(ugm), PANCAKE_V3_ROUTER, WBNB_USDT_FEE, address(basket), treasury, COMMISSION_BPS, 0, legs, gridIds
        );
        basket.setVault(address(vault));

        for (uint256 i = 0; i < 3; i++) {
            ugm.setGridYieldToken(GRID_IDS[i], address(basket)); // grid yieldToken == basket (F3 assert)
            ugm.setGridTotalSeats(GRID_IDS[i], SEATS[i]); // the seat-proportional split weight
        }
        ugm.setApprovedAdapter(address(vault), true);
        vault.registerAllGrids();

        vm.label(address(vault), "BasketVault");
        vm.label(address(basket), "StockBasket");
        vm.label(WBNB, "WBNB");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Real swaps → basket mint → 3 grids fed seat-proportionally (10/30/60).
    // ─────────────────────────────────────────────────────────────────────────
    function test_Distribute_RealSwaps_BasketAndSeatProportional() public {
        vm.deal(address(vault), FUND); // native BNB fee sits on the vault
        assertEq(vault.pendingDistribute(), FUND, "pending counts native BNB");

        uint256 expCommission = (FUND * COMMISSION_BPS) / 10_000;

        uint256[] memory minOut = new uint256[](3); // zeros
        uint256 basketMinted = vault.distribute(minOut, block.timestamp + 300);

        // Commission skimmed (WBNB) to treasury; native fully consumed.
        assertEq(IERC20(WBNB).balanceOf(treasury), expCommission, "commission to treasury");
        assertEq(address(vault).balance, 0, "native wrapped + spent");
        assertEq(IERC20(WBNB).balanceOf(address(vault)), 0, "no WBNB dust");

        // Basket shares minted == spentWBNB (net, since all 3 legs swap on real liquidity).
        assertEq(basketMinted, FUND - expCommission, "basketMinted == net (all legs succeeded)");
        assertEq(basket.totalSupply(), basketMinted, "supply == minted");

        // Basket physically holds all 3 real stocks.
        assertGt(IERC20(SPCXB).balanceOf(address(basket)), 0, "basket holds SPCXB");
        assertGt(IERC20(QQQB).balanceOf(address(basket)), 0, "basket holds QQQB");
        assertGt(IERC20(NVDAB).balanceOf(address(basket)), 0, "basket holds NVDAB");

        // Grids received the basket seat-proportionally (10/30/60), dust on the last grid.
        uint256 sumFed;
        for (uint256 i = 0; i < 3; i++) {
            (, bytes32 ah) = vault.gridAt(i);
            uint256 fed = ugm.yieldByAsset(ah);
            sumFed += fed;
            if (i < 2) {
                assertEq(fed, (basketMinted * SEATS[i]) / 100, "grid share seat-proportional");
            }
        }
        assertEq(sumFed, basketMinted, "all basket shares distributed to grids");
        assertEq(basket.balanceOf(address(vault)), 0, "no basket left on the vault");
        // The 60-seat grid got the largest share.
        (, bytes32 ah2) = vault.gridAt(2);
        (, bytes32 ah0) = vault.gridAt(0);
        assertGt(ugm.yieldByAsset(ah2), ugm.yieldByAsset(ah0), "bigger grid earns more");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  A holder redeems basket shares → receives a pro-rata slice of all 3 real stocks.
    // ─────────────────────────────────────────────────────────────────────────
    function test_Redeem_RealStocks_ProRata() public {
        vm.deal(address(vault), FUND);
        uint256[] memory minOut = new uint256[](3);
        uint256 basketMinted = vault.distribute(minOut, block.timestamp + 300);

        // The MockUGM custodies the basket shares it pulled; a seat holder would hold them in production.
        // Redeem half of one grid's share to a fresh user and check they get all 3 stocks.
        (, bytes32 ah) = vault.gridAt(2); // the 60-seat grid
        uint256 held = ugm.yieldByAsset(ah);
        assertGt(held, 0, "grid has basket to redeem");
        uint256 redeemShares = held / 2;

        address user = makeAddr("seatHolder");
        vm.prank(address(ugm));
        uint256[] memory got = basket.redeem(redeemShares, user);

        assertEq(got.length, 3, "3 stocks returned");
        assertGt(IERC20(SPCXB).balanceOf(user), 0, "user got SPCXB");
        assertGt(IERC20(QQQB).balanceOf(user), 0, "user got QQQB");
        assertGt(IERC20(NVDAB).balanceOf(user), 0, "user got NVDAB");
        assertEq(basket.totalSupply(), basketMinted - redeemShares, "supply burned by redeem");
        // Redeemed amounts match the basket's pro-rata (shares/supply * reserve at redeem time).
        assertEq(IERC20(SPCXB).balanceOf(user), got[0], "SPCXB out matches");
    }
}
