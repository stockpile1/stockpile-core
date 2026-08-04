// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {StockpileBasketVault} from "../src/StockpileBasketVault.sol";
import {StockBasket} from "../src/StockBasket.sol";
import {MockUGM} from "./mocks/MockUGM.sol";
import {MockWBNB} from "./mocks/MockWBNB.sol";
import {MockMintableERC20} from "./mocks/MockMintableERC20.sol";
import {MockFeeOnTransferERC20} from "./mocks/MockFeeOnTransferERC20.sol";
import {MockRevertOnZeroERC20} from "./mocks/MockRevertOnZeroERC20.sol";
import {MockV3Router} from "./mocks/MockV3Router.sol";

/// @title StockpileBasketVault unit tests (no fork)
/// @notice Exercises the standalone basket-settled vault end-to-end against fully local mocks:
///         MockWBNB (accrued token), MockMintableERC20 (USDT hop + 3 stocks), MockV3Router
///         (deterministic 2-hop `exactInput`), a REAL {StockBasket} (the single yield token every
///         grid pays out), and MockUGM (grid sink with per-asset accumulation + per-grid seat counts).
///         The vault: WBNB → 3 stocks → basket.deposit (mints `spentWBNB` shares) → 3 grids
///         seat-proportionally. Grids carry DIFFERENT seat counts (10 / 30 / 60) so the split is asserted.
///         The test contract deploys the vault, hence its `owner` (guardian).
contract StockpileBasketVaultTest is Test {
    // ── Infra ─────────────────────────────────────────────────────────────────
    MockWBNB internal wbnb; // accrued token + first swap hop
    MockMintableERC20 internal usdt; // shared stable hop
    MockMintableERC20[3] internal stock; // the 3 target stock tokens
    MockV3Router internal router; // deterministic exactInput
    MockUGM internal ugm; // grid sink
    address internal treasury;

    uint24 internal constant WBNB_USDT_FEE = 100;
    uint256 internal constant N = 3;

    // Grid ids (1..3) and their seat counts (10 / 30 / 60 => totalSeats 100).
    uint256[3] internal GRID_IDS = [uint256(1), 2, 3];
    uint32[3] internal SEATS = [uint32(10), 30, 60];

    function setUp() public {
        wbnb = new MockWBNB();
        usdt = new MockMintableERC20("Tether USD", "USDT", 18);
        router = new MockV3Router();
        ugm = new MockUGM();
        treasury = makeAddr("treasury");

        for (uint256 i = 0; i < N; i++) {
            stock[i] = new MockMintableERC20(
                string(abi.encodePacked("Stock", vm.toString(i))),
                string(abi.encodePacked("STK", vm.toString(i))),
                18
            );
        }

        // Fund the test contract so it can mint WBNB and send raw native value.
        vm.deal(address(this), 5_000_000 ether);
    }

    // ── Fixture helpers ─────────────────────────────────────────────────────────

    /// @dev Default swap weights: [30%, 30%, 40%] == 10_000 bps.
    function _defaultWeights() internal pure returns (uint16[3] memory w) {
        w = [uint16(3000), 3000, 4000];
    }

    function _stockAddrs() internal view returns (address[] memory a) {
        a = new address[](N);
        for (uint256 i = 0; i < N; i++) {
            a[i] = address(stock[i]);
        }
    }

    /// @dev Build the vault's stock legs (order == basket order) with distinct fee tiers.
    function _legs(uint16[3] memory weights) internal view returns (StockpileBasketVault.StockLeg[] memory legs) {
        uint24[3] memory fees = [uint24(500), 2500, 10000];
        legs = new StockpileBasketVault.StockLeg[](N);
        for (uint256 i = 0; i < N; i++) {
            legs[i] = StockpileBasketVault.StockLeg({
                stock: address(stock[i]),
                stockFee: fees[i],
                swapWeightBps: weights[i]
            });
        }
    }

    function _gridIds() internal view returns (uint256[] memory ids) {
        ids = new uint256[](N);
        for (uint256 i = 0; i < N; i++) {
            ids[i] = GRID_IDS[i];
        }
    }

    /// @dev A fresh basket over the 3 stocks in the canonical order.
    function _freshBasket() internal returns (StockBasket b) {
        b = new StockBasket("Stockpile Basket", "SPB", _stockAddrs());
    }

    /// @dev Deploy a fresh basket + vault, wire the grids on the shared UGM to THIS basket + seat
    ///      counts, approve + register the vault, and warp past the time-gate. Returns both.
    function _deployEnv(uint16 commissionBps, uint256 interval, uint16[3] memory weights)
        internal
        returns (StockpileBasketVault v, StockBasket b)
    {
        b = _freshBasket();
        v = new StockpileBasketVault(
            address(wbnb),
            address(usdt),
            address(ugm),
            address(router),
            WBNB_USDT_FEE,
            address(b),
            treasury,
            commissionBps,
            interval,
            _legs(weights),
            _gridIds()
        );
        b.setVault(address(v));

        for (uint256 i = 0; i < N; i++) {
            ugm.setGridYieldToken(GRID_IDS[i], address(b));
            ugm.setGridTotalSeats(GRID_IDS[i], SEATS[i]);
        }
        ugm.setApprovedAdapter(address(v), true);
        v.registerAllGrids();
        vm.warp(block.timestamp + interval + 1);
    }

    /// @dev Deploy a vault against `b` WITHOUT wiring grids (for constructor-only assertions).
    function _deployRaw(StockBasket b, uint16 commissionBps, uint256 interval, uint16[3] memory weights)
        internal
        returns (StockpileBasketVault v)
    {
        v = new StockpileBasketVault(
            address(wbnb),
            address(usdt),
            address(ugm),
            address(router),
            WBNB_USDT_FEE,
            address(b),
            treasury,
            commissionBps,
            interval,
            _legs(weights),
            _gridIds()
        );
    }

    function _fundWbnb(StockpileBasketVault v, uint256 amount) internal {
        wbnb.deposit{value: amount}();
        require(wbnb.transfer(address(v), amount), "fund transfer");
    }

    function _assetHash(address v, uint256 gridId) internal pure returns (bytes32) {
        return keccak256(abi.encode("StockpileBasketVault", v, gridId));
    }

    function _zeros() internal pure returns (uint256[] memory z) {
        z = new uint256[](N); // all-zero minOut
    }

    /// @dev Re-implements the vault's weight split (dust on the last leg) for per-leg amountIn prediction.
    function _expectedAmountsIn(uint256 net, uint16[3] memory weights) internal pure returns (uint256[3] memory amt) {
        uint256 allocated;
        for (uint256 i = 0; i < N; i++) {
            if (i == N - 1) {
                amt[i] = net - allocated;
            } else {
                amt[i] = (net * weights[i]) / 10_000;
                allocated += amt[i];
            }
        }
    }

    /// @dev Re-implements the vault's seat-proportional grid split (dust on the last grid).
    function _expectedGridShares(uint256 basketMinted) internal view returns (uint256[3] memory share) {
        uint256 total;
        for (uint256 j = 0; j < N; j++) {
            total += SEATS[j];
        }
        uint256 allocated;
        for (uint256 j = 0; j < N; j++) {
            if (j == N - 1) {
                share[j] = basketMinted - allocated;
            } else {
                share[j] = (basketMinted * SEATS[j]) / total;
                allocated += share[j];
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 1. Happy path: WBNB → 3 stocks → basket → grids seat-proportional
    // ══════════════════════════════════════════════════════════════════════════

    function test_HappyPath_SwapsDepositsAndFeedsGrids() public {
        uint16 commissionBps = 500; // 5%
        uint16[3] memory weights = _defaultWeights();
        (StockpileBasketVault v, StockBasket b) = _deployEnv(commissionBps, 1 hours, weights);

        uint256 gross = 1_000 ether;
        _fundWbnb(v, gross);
        assertEq(v.pendingDistribute(), gross, "pendingDistribute == funded WBNB");

        uint256 commission = (gross * commissionBps) / 10_000; // 50 ether
        uint256 net = gross - commission; // 950 ether
        uint256[3] memory expIn = _expectedAmountsIn(net, weights);

        uint256 basketMinted = v.distribute(_zeros(), block.timestamp + 300);

        // Commission skimmed to treasury (WBNB).
        assertEq(wbnb.balanceOf(treasury), commission, "treasury got commission");

        // 1:1 router => spentWBNB == net (all 3 legs succeeded); basketMinted == spentWBNB.
        assertEq(basketMinted, net, "basketMinted == spentWBNB == net");
        assertEq(b.totalSupply(), net, "basket minted `net` shares");

        // Basket holds each bought stock (1:1 swap => amounts[i] == amountIn[i]).
        for (uint256 i = 0; i < N; i++) {
            assertEq(stock[i].balanceOf(address(b)), expIn[i], "basket holds stock i");
        }

        // Grids received basket shares seat-proportionally (10/30/60), dust on the last.
        uint256[3] memory expShare = _expectedGridShares(basketMinted);
        uint256 sumShares;
        for (uint256 j = 0; j < N; j++) {
            bytes32 ah = _assetHash(address(v), GRID_IDS[j]);
            assertEq(ugm.yieldByAsset(ah), expShare[j], "grid j got its seat share");
            sumShares += expShare[j];
        }
        assertEq(sumShares, basketMinted, "sum of grid shares == basketMinted (no dust stranded)");
        assertEq(ugm.receiveYieldCallCount(), N, "exactly 3 grid pushes");

        // The UGM (holder of the basket shares) can be checked: it holds all minted shares.
        assertEq(b.balanceOf(address(ugm)), basketMinted, "UGM holds all forwarded basket shares");

        // Vault fully drained of WBNB and basket; approvals reset; time-gate advanced.
        assertEq(wbnb.balanceOf(address(v)), 0, "vault WBNB drained");
        assertEq(b.balanceOf(address(v)), 0, "no basket dust on vault");
        assertEq(wbnb.allowance(address(v), address(router)), 0, "router allowance reset");
        assertEq(b.allowance(address(v), address(ugm)), 0, "ugm basket allowance reset");
        assertEq(v.lastDistribute(), block.timestamp, "lastDistribute advanced");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 2. Seat-proportional correctness across the 3 different-size grids
    // ══════════════════════════════════════════════════════════════════════════

    function test_SeatProportional_SplitAcrossGrids() public {
        uint16[3] memory weights = _defaultWeights();
        (StockpileBasketVault v,) = _deployEnv(0, 0, weights); // 0 commission => net == gross

        uint256 gross = 1_000 ether; // divisible by totalSeats (100)
        _fundWbnb(v, gross);
        uint256 basketMinted = v.distribute(_zeros(), block.timestamp + 300);
        assertEq(basketMinted, gross, "all swapped, shares == gross");

        // 10/30/60 seats of 100 => 10% / 30% / 60% exactly (gross divisible by 100).
        assertEq(ugm.yieldByAsset(_assetHash(address(v), 1)), (gross * 10) / 100, "grid 1 = 10%");
        assertEq(ugm.yieldByAsset(_assetHash(address(v), 2)), (gross * 30) / 100, "grid 2 = 30%");
        assertEq(ugm.yieldByAsset(_assetHash(address(v), 3)), (gross * 60) / 100, "grid 3 = 60%");
    }

    /// @dev Non-divisible amount: last grid absorbs the rounding dust; shares still sum to basketMinted.
    function test_SeatProportional_DustOnLastGrid() public {
        uint16[3] memory weights = _defaultWeights();
        (StockpileBasketVault v,) = _deployEnv(0, 0, weights);

        uint256 gross = 1_000 ether + 7; // NOT divisible by 100
        _fundWbnb(v, gross);
        uint256 basketMinted = v.distribute(_zeros(), block.timestamp + 300);

        uint256[3] memory expShare = _expectedGridShares(basketMinted);
        // First two grids are the floored seat shares; last absorbs the remainder.
        uint256 s0 = (basketMinted * 10) / 100;
        uint256 s1 = (basketMinted * 30) / 100;
        assertEq(expShare[0], s0);
        assertEq(expShare[1], s1);
        assertEq(expShare[2], basketMinted - s0 - s1, "last grid = remainder incl. dust");

        uint256 sum;
        for (uint256 j = 0; j < N; j++) {
            assertEq(ugm.yieldByAsset(_assetHash(address(v), GRID_IDS[j])), expShare[j], "grid share matches");
            sum += expShare[j];
        }
        assertEq(sum, basketMinted, "conservation: sum == basketMinted");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 3. Native-BNB intake → distribute wraps + works
    // ══════════════════════════════════════════════════════════════════════════

    function test_Receive_AcceptsNativeBnb_PendingCounts() public {
        (StockpileBasketVault v,) = _deployEnv(0, 0, _defaultWeights());
        assertEq(v.pendingDistribute(), 0, "starts empty");

        (bool ok,) = address(v).call{value: 3 ether}("");
        assertTrue(ok, "receive() accepts native BNB");
        assertEq(address(v).balance, 3 ether, "native held");
        assertEq(wbnb.balanceOf(address(v)), 0, "not wrapped until distribute");
        assertEq(v.pendingDistribute(), 3 ether, "pending counts native");
    }

    function test_Receive_LowGasStipendSucceeds() public {
        (StockpileBasketVault v,) = _deployEnv(0, 0, _defaultWeights());
        (bool ok,) = address(v).call{value: 1 ether, gas: 2300}("");
        assertTrue(ok, "receive() must succeed within a 2300-gas stipend");
        assertEq(address(v).balance, 1 ether, "BNB accepted");
    }

    function test_Distribute_WrapsNativeBnbFee() public {
        uint16 commissionBps = 500;
        uint16[3] memory weights = _defaultWeights();
        (StockpileBasketVault v, StockBasket b) = _deployEnv(commissionBps, 1 hours, weights);

        uint256 gross = 1_000 ether;
        (bool ok,) = address(v).call{value: gross}(""); // NATIVE BNB fee, not WBNB
        assertTrue(ok, "fund native");
        assertEq(v.pendingDistribute(), gross, "pending counts the native fee");

        uint256 commission = (gross * commissionBps) / 10_000;
        uint256 net = gross - commission;

        uint256 basketMinted = v.distribute(_zeros(), block.timestamp + 300);

        assertEq(address(v).balance, 0, "native BNB wrapped + spent");
        assertEq(wbnb.balanceOf(address(v)), 0, "no WBNB dust");
        assertEq(wbnb.balanceOf(treasury), commission, "commission skimmed in WBNB");
        assertEq(basketMinted, net, "basketMinted == net");
        assertEq(b.balanceOf(address(ugm)), basketMinted, "grids fed the basket");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 4. Best-effort: a reverting swap leg is skipped; basket + grids still fed
    // ══════════════════════════════════════════════════════════════════════════

    function test_BestEffort_RevertingLegSkipped() public {
        uint16[3] memory weights = _defaultWeights();
        (StockpileBasketVault v, StockBasket b) = _deployEnv(0, 0, weights);

        uint256 gross = 1_000 ether;
        _fundWbnb(v, gross);
        uint256[3] memory expIn = _expectedAmountsIn(gross, weights); // net == gross

        // Force leg-1's swap (stock[1]) to REVERT (dead pool). Best-effort must skip only it.
        router.setForceRevert(address(stock[1]), true);

        uint256 basketMinted = v.distribute(_zeros(), block.timestamp + 300);

        // spentWBNB excludes the skipped leg; basketMinted == spentWBNB.
        uint256 spent = expIn[0] + expIn[2];
        assertEq(basketMinted, spent, "basketMinted == spentWBNB (skipped leg excluded)");
        assertEq(b.totalSupply(), spent, "basket minted spentWBNB shares");

        // Skipped leg's stock never entered the basket; its WBNB retained on the vault.
        assertEq(stock[1].balanceOf(address(b)), 0, "skipped stock not deposited");
        assertEq(stock[0].balanceOf(address(b)), expIn[0], "leg 0 deposited");
        assertEq(stock[2].balanceOf(address(b)), expIn[2], "leg 2 deposited");
        assertEq(wbnb.balanceOf(address(v)), expIn[1], "skipped leg's WBNB retained (swap rolled back)");

        // Grids still fed, seat-proportional over the smaller basketMinted; sum == basketMinted.
        uint256[3] memory expShare = _expectedGridShares(basketMinted);
        uint256 sum;
        for (uint256 j = 0; j < N; j++) {
            assertEq(ugm.yieldByAsset(_assetHash(address(v), GRID_IDS[j])), expShare[j], "grid share");
            sum += expShare[j];
        }
        assertEq(sum, basketMinted, "grids fed the full (smaller) basketMinted");
        assertEq(ugm.receiveYieldCallCount(), N, "all 3 grids still fed");
        assertEq(b.balanceOf(address(v)), 0, "no basket dust on vault");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 5. Keeper gate / commission lower-only / renounce disabled
    // ══════════════════════════════════════════════════════════════════════════

    function test_Distribute_NonKeeperReverts() public {
        (StockpileBasketVault v,) = _deployEnv(0, 0, _defaultWeights());
        _fundWbnb(v, 100 ether);
        vm.prank(makeAddr("rando"));
        vm.expectRevert(bytes(unicode"Not authorized keeper / 未授权的keeper"));
        v.distribute(_zeros(), block.timestamp + 300);
    }

    function test_Distribute_OwnerAndKeeperAllowed() public {
        (StockpileBasketVault v,) = _deployEnv(0, 0, _defaultWeights());

        // Owner (this contract) allowed.
        _fundWbnb(v, 100 ether);
        assertGt(v.distribute(_zeros(), block.timestamp + 300), 0, "owner distribute ok");

        // Allowlisted keeper allowed.
        address keeper = makeAddr("keeper");
        v.setKeeper(keeper, true);
        assertTrue(v.keepers(keeper), "keeper allowlisted");
        _fundWbnb(v, 100 ether);
        vm.prank(keeper);
        assertGt(v.distribute(_zeros(), block.timestamp + 300), 0, "keeper distribute ok");

        // Revoke: keeper blocked again.
        v.setKeeper(keeper, false);
        _fundWbnb(v, 100 ether);
        vm.prank(keeper);
        vm.expectRevert(bytes(unicode"Not authorized keeper / 未授权的keeper"));
        v.distribute(_zeros(), block.timestamp + 300);
    }

    function test_SetKeeper_OnlyOwnerAndNonZero() public {
        (StockpileBasketVault v,) = _deployEnv(0, 0, _defaultWeights());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        v.setKeeper(makeAddr("k"), true);

        vm.expectRevert(bytes(unicode"Zero address / 零地址"));
        v.setKeeper(address(0), true);
    }

    function test_SetCommissionBps_OnlyLower() public {
        StockBasket b = _freshBasket();
        StockpileBasketVault v = _deployRaw(b, 1000, 0, _defaultWeights()); // start at 10% cap

        vm.expectRevert(bytes(unicode"Fee can only decrease / 费用只能降低"));
        v.setCommissionBps(1001);

        v.setCommissionBps(500);
        assertEq(v.commissionBps(), 500, "lowered to 500");
        v.setCommissionBps(0);
        assertEq(v.commissionBps(), 0, "lowered to 0");

        vm.expectRevert(bytes(unicode"Fee can only decrease / 费用只能降低"));
        v.setCommissionBps(1);
    }

    function test_RenounceOwnership_Disabled() public {
        StockBasket b = _freshBasket();
        StockpileBasketVault v = _deployRaw(b, 0, 0, _defaultWeights());
        vm.expectRevert(bytes(unicode"Renounce disabled / 禁止放弃所有权"));
        v.renounceOwnership();
        assertEq(v.owner(), address(this), "owner unchanged");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 6. Constructor validation
    // ══════════════════════════════════════════════════════════════════════════

    function test_Constructor_WeightsSumReverts() public {
        StockBasket b = _freshBasket();
        uint16[3] memory weights = [uint16(3000), 3000, 3999]; // sum 9_999
        vm.expectRevert(bytes(unicode"Weights must sum to 10000 / 权重总和须为10000"));
        _deployRaw(b, 0, 0, weights);
    }

    function test_Constructor_BasketLengthMismatchReverts() public {
        // Basket over only 2 of the 3 stocks => stocksLength() != legs.length.
        address[] memory stx = new address[](2);
        stx[0] = address(stock[0]);
        stx[1] = address(stock[1]);
        StockBasket b2 = new StockBasket("B2", "B2", stx);
        vm.expectRevert(bytes(unicode"Basket stock mismatch / 篮子股票不匹配"));
        _deployRaw(b2, 0, 0, _defaultWeights());
    }

    function test_Constructor_BasketOrderMismatchReverts() public {
        // Basket order [s1, s0, s2] but vault legs [s0, s1, s2] => positional mismatch at index 0.
        address[] memory stx = new address[](3);
        stx[0] = address(stock[1]);
        stx[1] = address(stock[0]);
        stx[2] = address(stock[2]);
        StockBasket bMis = new StockBasket("BM", "BM", stx);
        vm.expectRevert(bytes(unicode"Basket stock mismatch / 篮子股票不匹配"));
        _deployRaw(bMis, 0, 0, _defaultWeights());
    }

    function test_Constructor_DuplicateStockReverts() public {
        StockBasket b = _freshBasket(); // valid 3-stock basket (length matches)
        // Legs with a duplicated stock (s0 at index 0 and 2). Dup is checked before the order-match.
        StockpileBasketVault.StockLeg[] memory legs = new StockpileBasketVault.StockLeg[](3);
        legs[0] = StockpileBasketVault.StockLeg({stock: address(stock[0]), stockFee: 500, swapWeightBps: 3000});
        legs[1] = StockpileBasketVault.StockLeg({stock: address(stock[1]), stockFee: 2500, swapWeightBps: 3000});
        legs[2] = StockpileBasketVault.StockLeg({stock: address(stock[0]), stockFee: 10000, swapWeightBps: 4000});
        vm.expectRevert(bytes(unicode"Duplicate stock / 股票重复"));
        new StockpileBasketVault(
            address(wbnb), address(usdt), address(ugm), address(router), WBNB_USDT_FEE,
            address(b), treasury, 0, 0, legs, _gridIds()
        );
    }

    function test_Constructor_StockIsWbnbReverts() public {
        StockBasket b = _freshBasket();
        StockpileBasketVault.StockLeg[] memory legs = _legs(_defaultWeights());
        legs[0].stock = address(wbnb);
        vm.expectRevert(bytes(unicode"Stock cannot be wbnb/usdt / stock不能为wbnb或usdt"));
        new StockpileBasketVault(
            address(wbnb), address(usdt), address(ugm), address(router), WBNB_USDT_FEE,
            address(b), treasury, 0, 0, legs, _gridIds()
        );
    }

    function test_Constructor_StockIsUsdtReverts() public {
        StockBasket b = _freshBasket();
        StockpileBasketVault.StockLeg[] memory legs = _legs(_defaultWeights());
        legs[1].stock = address(usdt);
        vm.expectRevert(bytes(unicode"Stock cannot be wbnb/usdt / stock不能为wbnb或usdt"));
        new StockpileBasketVault(
            address(wbnb), address(usdt), address(ugm), address(router), WBNB_USDT_FEE,
            address(b), treasury, 0, 0, legs, _gridIds()
        );
    }

    function test_Constructor_DuplicateGridReverts() public {
        StockBasket b = _freshBasket();
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 2; // duplicate
        vm.expectRevert(bytes(unicode"Duplicate grid / 网格重复"));
        new StockpileBasketVault(
            address(wbnb), address(usdt), address(ugm), address(router), WBNB_USDT_FEE,
            address(b), treasury, 0, 0, _legs(_defaultWeights()), ids
        );
    }

    function test_Constructor_ZeroGridReverts() public {
        StockBasket b = _freshBasket();
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 0; // zero grid
        ids[2] = 3;
        vm.expectRevert(bytes(unicode"Zero grid / 网格为零"));
        new StockpileBasketVault(
            address(wbnb), address(usdt), address(ugm), address(router), WBNB_USDT_FEE,
            address(b), treasury, 0, 0, _legs(_defaultWeights()), ids
        );
    }

    function test_Constructor_EmptyGridsReverts() public {
        StockBasket b = _freshBasket();
        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(bytes(unicode"No grids / 无网格"));
        new StockpileBasketVault(
            address(wbnb), address(usdt), address(ugm), address(router), WBNB_USDT_FEE,
            address(b), treasury, 0, 0, _legs(_defaultWeights()), ids
        );
    }

    function test_Constructor_ZeroAddressReverts() public {
        StockBasket b = _freshBasket();
        vm.expectRevert(bytes(unicode"Zero address / 零地址"));
        new StockpileBasketVault(
            address(0), address(usdt), address(ugm), address(router), WBNB_USDT_FEE,
            address(b), treasury, 0, 0, _legs(_defaultWeights()), _gridIds()
        );
    }

    function test_Constructor_ZeroBasketReverts() public {
        vm.expectRevert(bytes(unicode"Zero address / 零地址"));
        new StockpileBasketVault(
            address(wbnb), address(usdt), address(ugm), address(router), WBNB_USDT_FEE,
            address(0), treasury, 0, 0, _legs(_defaultWeights()), _gridIds()
        );
    }

    function test_Constructor_CommissionTooHighReverts() public {
        StockBasket b = _freshBasket();
        vm.expectRevert(bytes(unicode"Commission too high / 佣金过高"));
        _deployRaw(b, 1001, 0, _defaultWeights());
    }

    function test_Constructor_StoresConfigAndDerivesHashes() public {
        (StockpileBasketVault v, StockBasket b) = _deployEnv(300, 2 hours, _defaultWeights());

        assertEq(v.wbnb(), address(wbnb));
        assertEq(v.usdt(), address(usdt));
        assertEq(v.ugm(), address(ugm));
        assertEq(v.swapRouter(), address(router));
        assertEq(v.wbnbUsdtFee(), WBNB_USDT_FEE);
        assertEq(v.basket(), address(b));
        assertEq(v.treasury(), treasury);
        assertEq(v.commissionBps(), 300);
        assertEq(v.minInterval(), 2 hours);
        assertEq(v.owner(), address(this));
        assertEq(v.stocksLength(), N);
        assertEq(v.gridsLength(), N);

        uint16[3] memory weights = _defaultWeights();
        for (uint256 i = 0; i < N; i++) {
            (address st,, uint16 w) = v.stockAt(i);
            assertEq(st, address(stock[i]), "leg stock");
            assertEq(w, weights[i], "leg weight");
            (uint256 gid, bytes32 ah) = v.gridAt(i);
            assertEq(gid, GRID_IDS[i], "grid id");
            assertEq(ah, _assetHash(address(v), GRID_IDS[i]), "assetHash bound to (vault, gridId)");
        }
        uint256[] memory ids = v.getGridIds();
        assertEq(ids.length, N);
        assertEq(ids[2], GRID_IDS[2]);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 7. Registration: yieldToken != basket reverts
    // ══════════════════════════════════════════════════════════════════════════

    function test_Register_YieldTokenNotBasketReverts() public {
        StockBasket b = _freshBasket();
        StockpileBasketVault v = _deployRaw(b, 0, 0, _defaultWeights());
        b.setVault(address(v));

        // Seed only 2 of 3 grids correctly; grid 3's yieldToken is wrong (usdt, not the basket).
        ugm.setGridYieldToken(1, address(b));
        ugm.setGridYieldToken(2, address(b));
        ugm.setGridYieldToken(3, address(usdt));
        ugm.setApprovedAdapter(address(v), true);

        vm.expectRevert(bytes(unicode"Grid yieldToken must be basket / 网格收益代币须为篮子"));
        v.registerAllGrids();

        // Per-grid path: grid index 2 (id 3) reverts; index 0 (id 1) succeeds.
        vm.expectRevert(bytes(unicode"Grid yieldToken must be basket / 网格收益代币须为篮子"));
        v.registerWithGrid(2);
        v.registerWithGrid(0);
        assertEq(ugm.assetAdapter(_assetHash(address(v), 1)), address(v), "grid 1 bound");
    }

    function test_Register_NotApprovedAdapterReverts() public {
        StockBasket b = _freshBasket();
        StockpileBasketVault v = _deployRaw(b, 0, 0, _defaultWeights());
        b.setVault(address(v));
        for (uint256 i = 0; i < N; i++) {
            ugm.setGridYieldToken(GRID_IDS[i], address(b));
        }
        // Not on the adapter allowlist -> UGM.registerAsset reverts "adapter".
        vm.expectRevert(bytes("adapter"));
        v.registerAllGrids();
    }

    function test_RegisterWithGrid_BadIndexReverts() public {
        (StockpileBasketVault v,) = _deployEnv(0, 0, _defaultWeights());
        vm.expectRevert(bytes(unicode"Bad grid index / 无效网格索引"));
        v.registerWithGrid(N);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 8. End-to-end: a holder who received basket shares redeems for the 3 stocks
    // ══════════════════════════════════════════════════════════════════════════

    function test_EndToEnd_HolderRedeemsBasketForStocks() public {
        uint16[3] memory weights = _defaultWeights();
        (StockpileBasketVault v, StockBasket b) = _deployEnv(0, 0, weights);

        uint256 gross = 1_000 ether;
        _fundWbnb(v, gross);
        uint256 basketMinted = v.distribute(_zeros(), block.timestamp + 300);
        uint256[3] memory expIn = _expectedAmountsIn(gross, weights);

        // Simulate a seat holder: the UGM (which now holds the basket shares) forwards a chunk to ALICE,
        // exactly as a real seat-yield claim would credit a holder. Grid 3 (60 seats) holds the biggest share.
        address alice = makeAddr("alice");
        uint256 grid3Share = ugm.yieldByAsset(_assetHash(address(v), 3));
        vm.prank(address(ugm));
        b.transfer(alice, grid3Share);
        assertEq(b.balanceOf(alice), grid3Share, "holder received basket shares");

        // ALICE redeems her basket shares for a pro-rata slice of ALL 3 stocks.
        uint256 supplyBefore = b.totalSupply();
        uint256[] memory expectedOut = new uint256[](N);
        for (uint256 i = 0; i < N; i++) {
            expectedOut[i] = (grid3Share * stock[i].balanceOf(address(b))) / supplyBefore;
        }

        vm.prank(alice);
        uint256[] memory got = b.redeem(grid3Share, alice);

        for (uint256 i = 0; i < N; i++) {
            assertEq(got[i], expectedOut[i], "pro-rata stock payout");
            assertEq(stock[i].balanceOf(alice), expectedOut[i], "alice holds the redeemed stock");
            assertGt(got[i], 0, "each stock slice positive");
        }
        assertEq(b.balanceOf(alice), 0, "shares burned on redeem");
        assertEq(b.totalSupply(), supplyBefore - grid3Share, "supply dropped by redeemed shares");

        // Sanity: her stock-0 slice is ~60% of the basket's stock-0 (she held 60% of supply).
        assertApproxEqAbs(got[0], (expIn[0] * 60) / 100, 1e6, "~60% of stock-0 reserve");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 9. Time-gate + nothing-to-distribute + guardian setters + emergency
    // ══════════════════════════════════════════════════════════════════════════

    function test_TimeGate_SecondImmediateReverts() public {
        uint256 interval = 1 days;
        (StockpileBasketVault v,) = _deployEnv(0, interval, _defaultWeights());

        _fundWbnb(v, 100 ether);
        v.distribute(_zeros(), block.timestamp + 300); // ok (warped past interval in _deployEnv)

        _fundWbnb(v, 100 ether);
        vm.expectRevert(bytes(unicode"Too soon / 时间未到"));
        v.distribute(_zeros(), block.timestamp + 300);

        vm.warp(block.timestamp + interval + 1);
        assertGt(v.distribute(_zeros(), block.timestamp + 300), 0, "works again after warp");
    }

    function test_Distribute_NothingToDistributeReverts() public {
        (StockpileBasketVault v,) = _deployEnv(0, 0, _defaultWeights());
        vm.expectRevert(bytes(unicode"Nothing to distribute / 无可分配"));
        v.distribute(_zeros(), block.timestamp + 300);
    }

    function test_Distribute_MinOutLengthMismatchReverts() public {
        (StockpileBasketVault v,) = _deployEnv(0, 0, _defaultWeights());
        _fundWbnb(v, 100 ether);
        uint256[] memory badMinOut = new uint256[](2); // wrong length (N == 3)
        vm.expectRevert(bytes(unicode"minOut length mismatch / minOut长度不匹配"));
        v.distribute(badMinOut, block.timestamp + 300);
    }

    /// @dev If every leg reverts, spentWBNB == 0: nothing deposited/forwarded, WBNB retained, returns 0.
    function test_Distribute_AllLegsRevert_NothingSwapped() public {
        (StockpileBasketVault v, StockBasket b) = _deployEnv(0, 0, _defaultWeights());
        for (uint256 i = 0; i < N; i++) {
            router.setForceRevert(address(stock[i]), true);
        }
        _fundWbnb(v, 100 ether);

        uint256 basketMinted = v.distribute(_zeros(), block.timestamp + 300);
        assertEq(basketMinted, 0, "returns 0 when nothing swapped");
        assertEq(b.totalSupply(), 0, "no basket minted");
        assertEq(ugm.receiveYieldCallCount(), 0, "no grid pushes");
        assertEq(wbnb.balanceOf(address(v)), 100 ether, "all WBNB retained for next time");
        assertEq(v.lastDistribute(), block.timestamp, "time-gate still advanced");
    }

    function test_SetTreasuryAndMinInterval() public {
        StockBasket b = _freshBasket();
        StockpileBasketVault v = _deployRaw(b, 0, 0, _defaultWeights());

        address newT = makeAddr("newTreasury");
        v.setTreasury(newT);
        assertEq(v.treasury(), newT);
        vm.expectRevert(bytes(unicode"Zero address / 零地址"));
        v.setTreasury(address(0));

        v.setMinInterval(6 hours);
        assertEq(v.minInterval(), 6 hours);
        vm.expectRevert(bytes(unicode"Interval too long / 间隔过长"));
        v.setMinInterval(30 days + 1);

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        v.setTreasury(makeAddr("x"));
    }

    function test_EmergencyWithdraw_TokenAndNative() public {
        StockBasket b = _freshBasket();
        StockpileBasketVault v = _deployRaw(b, 0, 0, _defaultWeights());

        // ERC20 sweep.
        stock[0].mint(address(v), 5 ether);
        address to = makeAddr("tokenRecipient");
        v.emergencyWithdrawToken(address(stock[0]), to);
        assertEq(stock[0].balanceOf(to), 5 ether);
        assertEq(stock[0].balanceOf(address(v)), 0);

        // Native sweep.
        vm.deal(address(v), 4 ether);
        address nto = makeAddr("nativeRecipient");
        v.emergencyWithdrawNative(nto);
        assertEq(nto.balance, 4 ether);
        assertEq(address(v).balance, 0);

        // Non-owner blocked.
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        v.emergencyWithdrawNative(makeAddr("attacker"));
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 10. FoT stock: basket credited the ACTUAL received delta (no revert)
    // ══════════════════════════════════════════════════════════════════════════

    function test_Distribute_FeeOnTransferStock_CreditsActualDelta() public {
        uint16 feeBps = 500; // 5% fee-on-transfer
        MockFeeOnTransferERC20 fot = new MockFeeOnTransferERC20("FeeStock", "FOT", 18, feeBps);

        // Basket with the FoT token as stock 1 (positions: [s0, fot, s2]).
        address[] memory stx = new address[](3);
        stx[0] = address(stock[0]);
        stx[1] = address(fot);
        stx[2] = address(stock[2]);
        StockBasket b = new StockBasket("FoTBasket", "FOTB", stx);

        uint16[3] memory weights = _defaultWeights();
        uint24[3] memory fees = [uint24(500), 2500, 10000];
        StockpileBasketVault.StockLeg[] memory legs = new StockpileBasketVault.StockLeg[](3);
        legs[0] = StockpileBasketVault.StockLeg({stock: address(stock[0]), stockFee: fees[0], swapWeightBps: weights[0]});
        legs[1] = StockpileBasketVault.StockLeg({stock: address(fot), stockFee: fees[1], swapWeightBps: weights[1]});
        legs[2] = StockpileBasketVault.StockLeg({stock: address(stock[2]), stockFee: fees[2], swapWeightBps: weights[2]});

        StockpileBasketVault v = new StockpileBasketVault(
            address(wbnb), address(usdt), address(ugm), address(router), WBNB_USDT_FEE,
            address(b), treasury, 0, 0, legs, _gridIds()
        );
        b.setVault(address(v));
        for (uint256 i = 0; i < N; i++) {
            ugm.setGridYieldToken(GRID_IDS[i], address(b));
            ugm.setGridTotalSeats(GRID_IDS[i], SEATS[i]);
        }
        ugm.setApprovedAdapter(address(v), true);
        v.registerAllGrids();

        uint256 gross = 1_000 ether;
        _fundWbnb(v, gross);
        uint256[3] memory expIn = _expectedAmountsIn(gross, weights); // net == gross

        uint256 basketMinted = v.distribute(_zeros(), block.timestamp + 300);

        // spentWBNB counts the FoT leg's amountIn (the swap did NOT revert); basketMinted == net.
        assertEq(basketMinted, gross, "basketMinted == spentWBNB == net (FoT swap succeeded)");

        // The FoT token is skimmed on BOTH hops of its journey to the basket: first router→vault (the
        // vault measures that delta as `amounts[1]`), then vault→basket inside `deposit`. So the basket
        // ends up holding nominal * 0.95 * 0.95 — proving both the vault (balance-delta `swapLeg`) and
        // the basket (balanceOf-based accounting) forward only what actually arrived, never over-pulling.
        uint256 nominal = expIn[1];
        uint256 vaultGot = nominal - (nominal * feeBps) / 10_000; // received by the vault from the swap
        uint256 credited = vaultGot - (vaultGot * feeBps) / 10_000; // received by the basket from deposit
        assertEq(fot.balanceOf(address(b)), credited, "basket holds the double-skimmed FoT delta");
        assertLt(credited, nominal, "credited < router nominal (FoT skimmed the delivery)");
        assertEq(fot.balanceOf(address(v)), 0, "no FoT dust stranded on the vault");

        // Plain legs deposited fully; all 3 grids fed.
        assertEq(stock[0].balanceOf(address(b)), expIn[0], "plain leg 0 full");
        assertEq(stock[2].balanceOf(address(b)), expIn[2], "plain leg 2 full");
        assertEq(ugm.receiveYieldCallCount(), N, "all 3 grids fed");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 11. Fuzz: commission conservation + full drain + grid-share conservation
    // ══════════════════════════════════════════════════════════════════════════

    function testFuzz_Distribute_ConservesAndDrains(uint16 commissionBps, uint96 amount) public {
        commissionBps = uint16(bound(commissionBps, 0, 1_000));
        uint256 gross = bound(amount, 1e6, 1_000_000 ether); // >= 1e6 so seat shares are non-trivial
        uint16[3] memory weights = _defaultWeights();

        (StockpileBasketVault v, StockBasket b) = _deployEnv(commissionBps, 0, weights);
        _fundWbnb(v, gross);

        uint256 commission = (gross * commissionBps) / 10_000;
        uint256 net = gross - commission;

        uint256 basketMinted = v.distribute(_zeros(), block.timestamp + 300);

        assertEq(wbnb.balanceOf(treasury), commission, "treasury got exactly the commission");
        assertEq(wbnb.balanceOf(address(v)), 0, "vault WBNB fully drained");
        assertEq(basketMinted, net, "basketMinted == net (1:1 swaps)");
        assertEq(b.balanceOf(address(v)), 0, "no basket dust on vault");

        uint256 sumShares;
        for (uint256 j = 0; j < N; j++) {
            sumShares += ugm.yieldByAsset(_assetHash(address(v), GRID_IDS[j]));
        }
        assertEq(sumShares, basketMinted, "grid shares sum to basketMinted");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 12. S1 — commission skimmed AFTER swaps, sized to spentWBNB (no double-tax)
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev A dead pool retains its leg's WBNB. The commission must be sized to what was ACTUALLY
    ///      distributed (proportional to spentWBNB), and the retained WBNB must be taxed ONLY once —
    ///      when it is finally distributed — never re-taxed round after round.
    function test_Distribute_CommissionProportional_NoDoubleTax() public {
        uint16[3] memory weights = _defaultWeights(); // [30%, 30%, 40%]
        (StockpileBasketVault v, StockBasket b) = _deployEnv(1000, 0, weights); // 10% commission

        // ── Round 1: leg 1 (stock[1]) pool is dead → its WBNB is retained, not distributed. ──
        router.setForceRevert(address(stock[1]), true);
        uint256 gross1 = 1_000 ether;
        _fundWbnb(v, gross1);

        uint256 grossCommission1 = (gross1 * 1000) / 10_000; // 100e
        uint256 net1 = gross1 - grossCommission1; // 900e
        uint256[3] memory in1 = _expectedAmountsIn(net1, weights);
        uint256 spent1 = in1[0] + in1[2]; // leg 1 skipped
        uint256 expCommission1 = (grossCommission1 * spent1) / net1;

        uint256 minted1 = v.distribute(_zeros(), block.timestamp + 300);

        assertEq(minted1, spent1, "basketMinted == spentWBNB");
        assertEq(wbnb.balanceOf(treasury), expCommission1, "commission sized to spentWBNB (S1)");
        assertLt(expCommission1, grossCommission1, "strictly less than full commission (a leg was skipped)");
        // Retained WBNB = gross - spentWBNB - commission (leg-1 slice + untaxed remainder) parked on vault.
        uint256 retained1 = gross1 - spent1 - expCommission1;
        assertEq(wbnb.balanceOf(address(v)), retained1, "retained WBNB parked for next round");

        // ── Round 2: NO new fee; the dead pool recovers. The retained WBNB is taxed ONLY now, once. ──
        router.setForceRevert(address(stock[1]), false);
        uint256 minted2 = v.distribute(_zeros(), block.timestamp + 300);
        assertGt(minted2, 0, "second round distributes the retained WBNB");

        // Each WBNB taxed EXACTLY once: total commission == 10% of the 1000e ever received (single-tax),
        // NOT the ~127e a pre-swap skim would double-charge on the retained leg.
        assertEq(wbnb.balanceOf(treasury), grossCommission1, "total commission == single-tax on gross");
        assertEq(wbnb.balanceOf(address(v)), 0, "no WBNB stranded after the dead pool recovered");
        // Basket fully backed by both rounds' spend.
        assertEq(b.totalSupply(), minted1 + minted2, "basket supply == total distributed");
    }

    /// @dev When NOTHING swaps (spentWBNB==0), commission must be ZERO even with a nonzero commissionBps —
    ///      the retained WBNB is left entirely untaxed for the next round.
    function test_Distribute_NothingSwapped_TakesZeroCommission() public {
        uint16[3] memory weights = _defaultWeights();
        (StockpileBasketVault v, StockBasket b) = _deployEnv(1000, 0, weights); // 10% commission
        for (uint256 i = 0; i < N; i++) {
            router.setForceRevert(address(stock[i]), true); // every leg dead
        }
        _fundWbnb(v, 1_000 ether);

        uint256 minted = v.distribute(_zeros(), block.timestamp + 300);

        assertEq(minted, 0, "nothing distributed");
        assertEq(wbnb.balanceOf(treasury), 0, "ZERO commission when spentWBNB==0 (retained untaxed)");
        assertEq(wbnb.balanceOf(address(v)), 1_000 ether, "all WBNB retained for next round");
        assertEq(b.totalSupply(), 0, "no basket minted");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 13. S2 — basket.deposit skips the zero-amount pull (revert-on-zero stock)
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev A basket stock that REVERTS on zero-value transferFrom, whose swap leg is skipped
    ///      (amounts[i]==0). Without the deposit zero-pull guard, basket.deposit would call
    ///      transferFrom(_, _, 0) and revert the WHOLE distribute; with it, the leg is skipped cleanly.
    function test_Distribute_ZeroPullGuard_SkippedLegDoesNotBrick() public {
        MockRevertOnZeroERC20 rz = new MockRevertOnZeroERC20("RevZero", "RZ", 18);

        // Basket [s0, rz, s2]; vault legs match positionally.
        address[] memory stx = new address[](3);
        stx[0] = address(stock[0]);
        stx[1] = address(rz);
        stx[2] = address(stock[2]);
        StockBasket b = new StockBasket("RZB", "RZB", stx);

        uint16[3] memory weights = _defaultWeights();
        uint24[3] memory fees = [uint24(500), 2500, 10000];
        StockpileBasketVault.StockLeg[] memory legs = new StockpileBasketVault.StockLeg[](3);
        legs[0] = StockpileBasketVault.StockLeg({stock: address(stock[0]), stockFee: fees[0], swapWeightBps: weights[0]});
        legs[1] = StockpileBasketVault.StockLeg({stock: address(rz), stockFee: fees[1], swapWeightBps: weights[1]});
        legs[2] = StockpileBasketVault.StockLeg({stock: address(stock[2]), stockFee: fees[2], swapWeightBps: weights[2]});

        StockpileBasketVault v = new StockpileBasketVault(
            address(wbnb), address(usdt), address(ugm), address(router), WBNB_USDT_FEE,
            address(b), treasury, 0, 0, legs, _gridIds()
        );
        b.setVault(address(v));
        for (uint256 i = 0; i < N; i++) {
            ugm.setGridYieldToken(GRID_IDS[i], address(b));
            ugm.setGridTotalSeats(GRID_IDS[i], SEATS[i]);
        }
        ugm.setApprovedAdapter(address(v), true);
        v.registerAllGrids();

        uint256 gross = 1_000 ether;
        _fundWbnb(v, gross);
        uint256[3] memory expIn = _expectedAmountsIn(gross, weights); // net == gross (0 commission)

        // Force the revert-on-zero leg's SWAP to revert → amounts[1] == 0 → deposit must SKIP its pull.
        router.setForceRevert(address(rz), true);

        uint256 basketMinted = v.distribute(_zeros(), block.timestamp + 300);

        uint256 spent = expIn[0] + expIn[2];
        assertEq(basketMinted, spent, "deposit succeeded; skipped leg excluded (guard held)");
        assertEq(stock[0].balanceOf(address(b)), expIn[0], "leg 0 deposited");
        assertEq(stock[2].balanceOf(address(b)), expIn[2], "leg 2 deposited");
        assertEq(rz.balanceOf(address(b)), 0, "revert-on-zero stock never pulled");
        assertEq(wbnb.balanceOf(address(v)), expIn[1], "skipped leg's WBNB retained");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 14. S5 — a zero-output swap leg mints NO unbacked shares
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev With minOut==0, a pool returning 0 out does NOT revert at the router (0 >= 0). Without S5 the
    ///      vault would count that leg's amountIn in spentWBNB and mint UNBACKED shares. `require(out>0)`
    ///      in swapLeg makes it revert → caught → its WBNB retained, excluded from spentWBNB.
    function test_Distribute_ZeroOutputLeg_NoUnbackedShares() public {
        uint16[3] memory weights = _defaultWeights();
        (StockpileBasketVault v, StockBasket b) = _deployEnv(0, 0, weights);

        uint256 gross = 1_000 ether;
        _fundWbnb(v, gross);
        uint256[3] memory expIn = _expectedAmountsIn(gross, weights); // net == gross

        router.setForceZero(address(stock[1]), true); // leg 1 yields 0 out (minOut==0 in _zeros())

        uint256 basketMinted = v.distribute(_zeros(), block.timestamp + 300);

        uint256 spent = expIn[0] + expIn[2]; // leg 1 excluded
        assertEq(basketMinted, spent, "no shares minted for the zero-output leg");
        assertEq(b.totalSupply(), spent, "basket supply == spentWBNB (fully backed)");
        assertEq(stock[1].balanceOf(address(b)), 0, "zero-output stock not deposited");
        assertEq(wbnb.balanceOf(address(v)), expIn[1], "zero-output leg's WBNB retained (swapLeg reverted)");
        // Backing invariant: every basket share is backed by stock actually bought.
        assertEq(stock[0].balanceOf(address(b)), expIn[0], "leg 0 backed");
        assertEq(stock[2].balanceOf(address(b)), expIn[2], "leg 2 backed");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 15. S6 — grid push is best-effort: a failing grid is skipped, others fed
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev One grid's receiveYieldERC20 reverts (failing / hijacked / paused). The push must SKIP it and
    ///      still feed the healthy grids; the skipped grid's basket share stays on the vault (recoverable),
    ///      and distribute does NOT revert.
    function test_Distribute_GridPushBestEffort_SkipsFailingGrid() public {
        uint16[3] memory weights = _defaultWeights();
        (StockpileBasketVault v, StockBasket b) = _deployEnv(0, 0, weights);

        uint256 gross = 1_000 ether;
        _fundWbnb(v, gross);

        // Make the MIDDLE grid's push (id 2, 30 seats) revert. Best-effort must skip only it.
        bytes32 ahFail = _assetHash(address(v), GRID_IDS[1]);
        ugm.setForceReceiveRevert(ahFail, true);

        uint256 basketMinted = v.distribute(_zeros(), block.timestamp + 300);
        assertEq(basketMinted, gross, "all legs swapped");

        uint256[3] memory expShare = _expectedGridShares(basketMinted);
        // Grids 1 and 3 fed their seat-proportional share; grid 2 skipped.
        assertEq(ugm.yieldByAsset(_assetHash(address(v), GRID_IDS[0])), expShare[0], "grid 1 fed");
        assertEq(ugm.yieldByAsset(ahFail), 0, "failing grid 2 received nothing");
        assertEq(ugm.yieldByAsset(_assetHash(address(v), GRID_IDS[2])), expShare[2], "grid 3 fed");
        assertEq(ugm.receiveYieldCallCount(), N - 1, "only the 2 healthy grids pushed");
        // The skipped grid's basket share is LEFT on the vault (recoverable), NOT reverted or redirected.
        assertEq(b.balanceOf(address(v)), expShare[1], "skipped grid's basket share retained on vault");
        assertEq(b.balanceOf(address(ugm)), expShare[0] + expShare[2], "UGM holds only the fed shares");
        assertEq(b.allowance(address(v), address(ugm)), 0, "ugm basket allowance reset");
    }
}
