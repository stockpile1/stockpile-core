// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {StockpileBasketVaultV2} from "../../src/vault/StockpileBasketVaultV2.sol";
import {StockpileBasketVaultFactory, VaultDataV1} from "../../src/vault/StockpileBasketVaultFactory.sol";
import {StockBasket} from "../../src/vault/StockBasket.sol";
import {VaultUISchema} from "../../src/vault/flap/IVaultSchemasV1.sol";

import {MockWBNB} from "./mocks/MockWBNB.sol";
import {MockMintableERC20} from "./mocks/MockMintableERC20.sol";
import {MockUGM} from "./mocks/MockUGM.sol";
import {MockV3Router} from "./mocks/MockV3Router.sol";
import {MockTaxToken} from "./mocks/MockTaxToken.sol";

/// @title StockpileBasketVaultV2 unit tests (Flap rules 001-009 conformance)
/// @notice Runs on chainId 97 (BSC testnet) so VaultBaseV2's chain-fixed `_getVaultPortal()` /
///         `_getGuardian()` resolve; `newVault` is then driven by pranking the resolved portal.
contract StockpileBasketVaultV2Test is Test {
    // Chain-fixed Flap addresses for chainId 97 (see VaultFactoryBaseV2 / VaultBase).
    address internal constant PORTAL = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
    address internal constant GUARDIAN = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;

    MockWBNB internal wbnb;
    MockMintableERC20 internal usdt;
    MockUGM internal ugm;
    MockV3Router internal router;
    MockMintableERC20 internal s0;
    MockMintableERC20 internal s1;
    MockMintableERC20 internal s2;

    StockpileBasketVaultFactory internal factory;

    address internal treasury;
    address internal keeper;

    function setUp() public {
        vm.chainId(97);

        wbnb = new MockWBNB();
        usdt = new MockMintableERC20("USDT", "USDT", 18);
        ugm = new MockUGM();
        router = new MockV3Router();
        s0 = new MockMintableERC20("Stock0", "S0", 18);
        s1 = new MockMintableERC20("Stock1", "S1", 18);
        s2 = new MockMintableERC20("Stock2", "S2", 18);

        factory = new StockpileBasketVaultFactory(address(wbnb), address(usdt), address(ugm), address(router), 100);

        treasury = makeAddr("treasury");
        keeper = makeAddr("keeper");
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    function _vaultData(uint16 commissionBps, uint256 minInterval) internal view returns (bytes memory) {
        address[] memory stocks = new address[](3);
        stocks[0] = address(s0);
        stocks[1] = address(s1);
        stocks[2] = address(s2);
        uint24[] memory fees = new uint24[](3);
        fees[0] = 500;
        fees[1] = 500;
        fees[2] = 500;
        uint16[] memory w = new uint16[](3);
        w[0] = 4000;
        w[1] = 3000;
        w[2] = 3000;
        VaultDataV1 memory d = VaultDataV1({
            gridSize: 36,
            gridTaxRateBps: 100,
            gridInitialPrice: 1e18,
            commissionBps: commissionBps,
            treasury: treasury,
            minInterval: minInterval,
            stocksData: abi.encode(stocks, fees, w)
        });
        return abi.encode(d);
    }

    /// @dev Build a full `vaultData` with explicit scalars + an opaque `stocksData` blob (M1/I3 helper).
    function _vaultDataFull(
        uint16 gridSize,
        uint16 gridTaxRateBps,
        uint128 gridInitialPrice,
        uint16 commissionBps_,
        address treasury_,
        uint256 minInterval,
        bytes memory stocksData
    ) internal pure returns (bytes memory) {
        VaultDataV1 memory d = VaultDataV1({
            gridSize: gridSize,
            gridTaxRateBps: gridTaxRateBps,
            gridInitialPrice: gridInitialPrice,
            commissionBps: commissionBps_,
            treasury: treasury_,
            minInterval: minInterval,
            stocksData: stocksData
        });
        return abi.encode(d);
    }

    /// @dev A well-formed 2-stock stocksData blob (weights sum 10000) reused by the setupMarket revert tests.
    function _goodStocksData() internal view returns (bytes memory) {
        address[] memory stocks = new address[](2);
        stocks[0] = address(s0);
        stocks[1] = address(s1);
        uint24[] memory fees = new uint24[](2);
        fees[0] = 500;
        fees[1] = 500;
        uint16[] memory w = new uint16[](2);
        w[0] = 6000;
        w[1] = 4000;
        return abi.encode(stocks, fees, w);
    }

    /// @dev newVault a vault carrying `stocksData` (pranked as the portal), leaving setupMarket to the test.
    function _newVaultWithStocks(bytes memory stocksData) internal returns (StockpileBasketVaultV2 v) {
        bytes memory data = _vaultDataFull(36, 100, 1e18, 600, treasury, 0, stocksData);
        address tax = address(new MockTaxToken(100));
        vm.prank(PORTAL);
        address vault = factory.newVault(tax, address(0), address(0xC0FFEE), data);
        v = StockpileBasketVaultV2(payable(vault));
    }

    /// @dev Assert `factory.newVault` reverts with `reason` for `data` (init-time validation, I3).
    function _expectInitRevert(bytes memory data, bytes memory reason) internal {
        address tax = address(new MockTaxToken(100));
        vm.prank(PORTAL);
        vm.expectRevert(reason);
        factory.newVault(tax, address(0), address(0xC0FFEE), data);
    }

    function _newVault(address taxToken, uint16 commissionBps, uint256 minInterval)
        internal
        returns (StockpileBasketVaultV2 v)
    {
        vm.prank(PORTAL);
        address vault = factory.newVault(taxToken, address(0), address(0xC0FFEE), _vaultData(commissionBps, minInterval));
        v = StockpileBasketVaultV2(payable(vault));
    }

    function _setupAndRegister(StockpileBasketVaultV2 v) internal {
        v.setupMarket();
        ugm.setApprovedAdapter(address(v), true);
        v.registerWithGrid();
    }

    function _minOut3() internal pure returns (uint256[] memory m) {
        m = new uint256[](3);
    }

    // ── initialize wires config; setupMarket wires basket + grid ────────────────

    function testInitializeStoresConfig() public {
        address tax = address(new MockTaxToken(100));
        StockpileBasketVaultV2 v = _newVault(tax, 600, 0);

        assertEq(v.taxToken(), tax, "taxToken");
        assertEq(v.commissionBps(), 600, "commissionBps");
        assertEq(v.treasury(), treasury, "treasury");
        assertEq(v.gridSize(), 36, "gridSize");
        assertEq(v.gridTaxRateBps(), 100, "gridTaxRateBps");
        // Stocks are wired LATER, in setupMarket (M1): the opaque stocksData blob is stored at init.
        assertEq(v.stocksLength(), 0, "no stocks before setup");
        assertFalse(v.isMarketSetUp(), "market not yet set up");
        assertEq(v.basket(), address(0), "basket zero before setup");

        v.setupMarket();
        assertEq(v.stocksLength(), 3, "stocksLength after setup");
        (address stk, uint24 fee, uint16 wt) = v.stockAt(0);
        assertEq(stk, address(s0));
        assertEq(fee, 500);
        assertEq(wt, 4000);
    }

    function testSetupMarketDeploysBasketAndGrid() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 0);
        v.setupMarket();

        address basket = v.basket();
        assertTrue(basket != address(0), "basket deployed");
        assertTrue(v.isMarketSetUp(), "market set up");
        assertEq(StockBasket(basket).vault(), address(v), "vault is basket minter");
        assertEq(StockBasket(basket).owner(), address(v), "vault owns basket");
        assertEq(StockBasket(basket).stocksLength(), 3, "basket has 3 stocks");
        assertEq(v.gridId(), 1, "grid id assigned");
        assertEq(v.assetHash(), keccak256(abi.encode("StockpileBasketVaultV2", address(v), uint256(1))), "assetHash");
    }

    function testSetupMarketIsOneShot() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 0);
        v.setupMarket();
        vm.expectRevert(bytes(unicode"Market already set up / 市场已建立"));
        v.setupMarket();
    }

    // ── receive() gas budget (Rule 005, Critical) ───────────────────────────────

    function testReceiveGasUnder1M() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 0);
        vm.deal(address(this), 1 ether);
        uint256 gasBefore = gasleft();
        (bool ok,) = address(v).call{value: 1 ether}("");
        uint256 gasUsed = gasBefore - gasleft();
        assertTrue(ok, "receive() should not revert");
        assertLe(gasUsed, 1_000_000, "receive() exceeds 1M gas limit");
        assertEq(v.pendingDistribute(), 1 ether, "native BNB accrues");
    }

    // ── distribute happy path: swap -> basket -> grid ───────────────────────────

    function testDistributeHappyPath() public {
        // taxRate 100 bps (1%) => Flap fee = 6% of gross; cap 10% => commission = 6%.
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 1000, 0);
        _setupAndRegister(v);

        vm.deal(address(v), 10 ether);

        vm.prank(GUARDIAN);
        uint256 basketMinted = v.distribute(_minOut3(), block.timestamp + 1);

        uint256 expCommission = (10 ether * 6) / 100; // 0.6 ether
        uint256 expNet = 10 ether - expCommission; // 9.4 ether (== spent == minted, 1:1 router)

        assertEq(wbnb.balanceOf(treasury), expCommission, "commission to treasury");
        assertEq(basketMinted, expNet, "basket minted == net (1:1 swaps)");

        address basket = v.basket();
        assertEq(StockBasket(basket).totalSupply(), expNet, "basket total supply");
        assertEq(StockBasket(basket).balanceOf(address(ugm)), expNet, "basket forwarded to grid/ugm");
        assertEq(ugm.yieldByAsset(v.assetHash()), expNet, "grid received the basket yield");
        assertEq(v.pendingDistribute(), 0, "vault drained of WBNB");
    }

    // ── distribute best-effort grid skip (unregistered grid) ────────────────────

    function testDistributeSkipsUnregisteredGrid() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 1000, 0);
        v.setupMarket(); // NOT registered with the grid

        vm.deal(address(v), 10 ether);
        vm.prank(GUARDIAN);
        uint256 basketMinted = v.distribute(_minOut3(), block.timestamp + 1);

        // Grid push best-effort-skipped: shares stay as basket on the vault; nothing reached the UGM.
        assertGt(basketMinted, 0, "still minted");
        assertEq(StockBasket(v.basket()).balanceOf(address(v)), basketMinted, "basket retained on vault");
        assertEq(ugm.yieldByAsset(v.assetHash()), 0, "grid received nothing");
    }

    // ── distribute revert paths (Rule 006) ──────────────────────────────────────

    function testDistributeRevertsForNonKeeper() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 0);
        _setupAndRegister(v);
        vm.deal(address(v), 1 ether);
        vm.prank(makeAddr("rando"));
        vm.expectRevert(bytes(unicode"Not authorized keeper / 未授权的keeper"));
        v.distribute(_minOut3(), block.timestamp + 1);
    }

    function testKeeperCanDistribute() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 0);
        _setupAndRegister(v);
        vm.prank(GUARDIAN);
        v.setKeeper(keeper, true);

        vm.deal(address(v), 5 ether);
        vm.prank(keeper);
        uint256 minted = v.distribute(_minOut3(), block.timestamp + 1);
        assertGt(minted, 0, "keeper distribute works");
    }

    function testDistributeRevertsTooSoon() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 1 hours);
        _setupAndRegister(v);

        // Warp past the interval so the FIRST distribute passes the time-gate (lastDistribute starts at 0).
        vm.warp(block.timestamp + 1 hours);
        vm.deal(address(v), 5 ether);
        vm.prank(GUARDIAN);
        v.distribute(_minOut3(), block.timestamp + 1);

        // Immediately after: still within the interval => "Too soon".
        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Too soon / 时间未到"));
        v.distribute(_minOut3(), block.timestamp + 1);
    }

    function testDistributeRevertsMinOutLengthMismatch() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 0);
        _setupAndRegister(v);
        vm.deal(address(v), 1 ether);
        uint256[] memory bad = new uint256[](2);
        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"minOut length mismatch / minOut长度不匹配"));
        v.distribute(bad, block.timestamp + 1);
    }

    function testDistributeRevertsBeforeSetup() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 0);
        vm.deal(address(v), 1 ether);
        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Market not set up / 市场未建立"));
        v.distribute(_minOut3(), block.timestamp + 1);
    }

    // ── commission = Flap Rule-001 formula for taxRate ∈ {50,100,300,1000} ───────

    function _commissionFor(uint16 taxRate, uint16 commissionBps) internal returns (uint256 commission) {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(taxRate)), commissionBps, 0);
        _setupAndRegister(v);
        vm.deal(address(v), 10 ether);
        vm.prank(GUARDIAN);
        v.distribute(_minOut3(), block.timestamp + 1);
        commission = wbnb.balanceOf(treasury);
    }

    function testCommissionFormula() public {
        // commissionBps = 1000 (10%) so the cap never binds for these tax rates.
        assertEq(_commissionFor(50, 1000), (10 ether * 6) / 100, "taxRate 50bps -> 6%");
    }

    function testCommissionFormula100() public {
        assertEq(_commissionFor(100, 1000), (10 ether * 6) / 100, "taxRate 100bps -> 6%");
    }

    function testCommissionFormula300() public {
        assertEq(_commissionFor(300, 1000), (10 ether * 6) / 300, "taxRate 300bps -> 2%");
    }

    function testCommissionFormula1000() public {
        assertEq(_commissionFor(1000, 1000), (10 ether * 6) / 1000, "taxRate 1000bps -> 0.6%");
    }

    function testCommissionCappedAtCommissionBps() public {
        // taxRate 50bps -> Flap fee 6%, but commissionBps cap = 50bps (0.5%) binds.
        uint256 commission = _commissionFor(50, 50);
        assertEq(commission, (10 ether * 50) / 10_000, "commission capped at 0.5%");
    }

    // ── D18: initialize + distribute with a CODELESS tax token ───────────────────

    function testD18CodelessTaxToken() public {
        address codelessTax = address(0xDEAD); // no code at init nor distribute
        assertEq(codelessTax.code.length, 0, "precondition: codeless");

        StockpileBasketVaultV2 v = _newVault(codelessTax, 1000, 0); // initialize must NOT call taxToken
        _setupAndRegister(v);

        vm.deal(address(v), 10 ether);
        vm.prank(GUARDIAN);
        v.distribute(_minOut3(), block.timestamp + 1);

        // Codeless token => tax rate unread => 6% branch, capped at 10% => 6% commission.
        assertEq(wbnb.balanceOf(treasury), (10 ether * 6) / 100, "codeless -> 6% branch");
        assertFalse(v.taxRateKnown(), "tax rate still unknown");
    }

    // ── Guardian access matrix (Rule 001) ───────────────────────────────────────

    function testSetKeeperGuardianOnly() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 0);
        vm.prank(makeAddr("rando"));
        vm.expectRevert(bytes(unicode"Only Guardian / 仅限 Guardian"));
        v.setKeeper(keeper, true);

        vm.prank(GUARDIAN);
        v.setKeeper(keeper, true);
        assertTrue(v.keepers(keeper), "keeper set by guardian");
    }

    function testSetCommissionLowerOnly() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 0);

        vm.prank(GUARDIAN);
        v.setCommissionBps(300);
        assertEq(v.commissionBps(), 300, "lowered");

        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Fee can only decrease / 费用只能降低"));
        v.setCommissionBps(400);
    }

    function testSetTreasuryAndMinIntervalGuardianOnly() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 0);

        vm.prank(makeAddr("rando"));
        vm.expectRevert(bytes(unicode"Only Guardian / 仅限 Guardian"));
        v.setTreasury(address(0xBEEF));

        vm.startPrank(GUARDIAN);
        v.setTreasury(address(0xBEEF));
        v.setMinInterval(2 days);
        vm.stopPrank();
        assertEq(v.treasury(), address(0xBEEF));
        assertEq(v.minInterval(), 2 days);
    }

    // ── Emergency withdraws (Rule 009 shape: onlyGuardian nonReentrant, full drain) ─

    function testEmergencyWithdrawNative() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 0);
        vm.deal(address(v), 3 ether);
        address to = makeAddr("rescue");

        vm.prank(makeAddr("rando"));
        vm.expectRevert(bytes(unicode"Only Guardian / 仅限 Guardian"));
        v.emergencyWithdrawNative(to);

        vm.prank(GUARDIAN);
        v.emergencyWithdrawNative(to);
        assertEq(to.balance, 3 ether, "full native drain");
        assertEq(address(v).balance, 0, "vault emptied");
    }

    function testEmergencyWithdrawToken() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 0);
        s0.mint(address(v), 777e18);
        address to = makeAddr("rescue");

        vm.prank(makeAddr("rando"));
        vm.expectRevert(bytes(unicode"Only Guardian / 仅限 Guardian"));
        v.emergencyWithdrawToken(address(s0), to);

        vm.prank(GUARDIAN);
        v.emergencyWithdrawToken(address(s0), to);
        assertEq(s0.balanceOf(to), 777e18, "full token drain");
        assertEq(s0.balanceOf(address(v)), 0, "vault emptied of token");
    }

    // ── Views / description / vaultUISchema (Rule 006) ──────────────────────────

    function testPendingDistributeCountsNativeAndWbnb() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 0);
        vm.deal(address(v), 2 ether);
        assertEq(v.pendingDistribute(), 2 ether, "native counted");
        vm.deal(address(this), 1 ether);
        wbnb.deposit{value: 1 ether}();
        wbnb.transfer(address(v), 1 ether);
        assertEq(v.pendingDistribute(), 3 ether, "native + wbnb counted");
    }

    function testDescriptionNonEmptyAndChanges() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 0);
        string memory before = v.description();
        assertGt(bytes(before).length, 0, "description non-empty before setup");
        v.setupMarket();
        string memory afterS = v.description();
        assertGt(bytes(afterS).length, 0, "description non-empty after setup");
        assertTrue(keccak256(bytes(before)) != keccak256(bytes(afterS)), "description changes on setup");
    }

    function testVaultUISchema() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 0);
        VaultUISchema memory schema = v.vaultUISchema();
        assertEq(schema.methods.length, 5, "5 methods");
        assertEq(schema.vaultType, "StockpileBasketVault", "vaultType");

        // Only distribute (index 4) is a write method.
        assertFalse(schema.methods[0].isWriteMethod, "pendingDistribute is read");
        assertFalse(schema.methods[1].isWriteMethod, "commissionBps is read");
        assertFalse(schema.methods[2].isWriteMethod, "basket is read");
        assertFalse(schema.methods[3].isWriteMethod, "gridId is read");
        assertTrue(schema.methods[4].isWriteMethod, "distributeUniform is write");
        assertEq(schema.methods[4].name, "distributeUniform", "5th is distributeUniform (L2 scalar minOut)");
        assertEq(schema.methods[4].inputs.length, 2, "distributeUniform has minOutPerLeg + deadline");
        // Rule 001 (L2): the schema's write-method input must be scalar (uint256), not an array.
        assertEq(schema.methods[4].inputs[0].name, "minOutPerLeg", "scalar uniform minOut");
        assertEq(schema.methods[4].inputs[0].fieldType, "uint256", "minOut is scalar uint256");
    }

    // ── Immutable routing is correctly read through the proxy ───────────────────

    function testProxyReadsImplImmutables() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 0);
        assertEq(v.wbnb(), address(wbnb), "wbnb immutable via proxy");
        assertEq(v.usdt(), address(usdt), "usdt immutable via proxy");
        assertEq(v.ugm(), address(ugm), "ugm immutable via proxy");
        assertEq(v.swapRouter(), address(router), "router immutable via proxy");
        assertEq(v.wbnbUsdtFee(), 100, "fee immutable via proxy");
    }

    // ── L2: distributeUniform (the schema write method, scalar minOut) ──────────

    function testDistributeUniformHappyPath() public {
        // taxRate 100 bps => Flap fee 6% of gross; cap 10% => commission 6%. Mirrors testDistributeHappyPath
        // but through the scalar-minOut schema entrypoint (L2).
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 1000, 0);
        _setupAndRegister(v);

        vm.deal(address(v), 10 ether);
        vm.prank(GUARDIAN);
        uint256 basketMinted = v.distributeUniform(0, block.timestamp + 1);

        uint256 expCommission = (10 ether * 6) / 100; // 0.6 ether
        uint256 expNet = 10 ether - expCommission; // 9.4 ether (== spent == minted, 1:1 router)

        assertEq(wbnb.balanceOf(treasury), expCommission, "commission to treasury");
        assertEq(basketMinted, expNet, "basket minted == net (1:1 swaps)");
        assertEq(ugm.yieldByAsset(v.assetHash()), expNet, "grid received the basket yield");
        assertEq(v.pendingDistribute(), 0, "vault drained of WBNB");
    }

    function testDistributeUniformRevertsForNonKeeper() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 0);
        _setupAndRegister(v);
        vm.deal(address(v), 1 ether);
        vm.prank(makeAddr("rando"));
        vm.expectRevert(bytes(unicode"Not authorized keeper / 未授权的keeper"));
        v.distributeUniform(0, block.timestamp + 1);
    }

    // ── L1: no commission when nothing swapped (retained WBNB is not re-taxed) ───

    function testDistributeNoCommissionWhenNothingSwapped() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 1000, 0);
        _setupAndRegister(v);

        // Force every leg's swap to revert (dead pools): spentWBNB == 0 => NO commission is taken and the
        // net WBNB is retained UNTAXED for the next round (L1).
        router.setForceRevert(address(s0), true);
        router.setForceRevert(address(s1), true);
        router.setForceRevert(address(s2), true);

        vm.deal(address(v), 10 ether);
        vm.prank(GUARDIAN);
        uint256 basketMinted = v.distribute(_minOut3(), block.timestamp + 1);

        assertEq(basketMinted, 0, "nothing minted");
        assertEq(wbnb.balanceOf(treasury), 0, "NO commission when nothing distributed (L1)");
        assertEq(v.pendingDistribute(), 10 ether, "full gross retained as WBNB for next round");
    }

    function testDistributeCommissionProportionalToSpent() public {
        // One of three legs dead. gross 10, commissionBps cap 10% (never binds; taxRate 100 => 6% Flap fee).
        // grossCommission = 0.6. Leg s1 (weight 3000) fails => spentWBNB = net * 7000/10000 (s0 4000 + s2
        // 3000). commission = grossCommission * spentWBNB / net = 0.6 * 0.7 = 0.42 ether.
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 1000, 0);
        _setupAndRegister(v);
        router.setForceRevert(address(s1), true);

        vm.deal(address(v), 10 ether);
        vm.prank(GUARDIAN);
        v.distribute(_minOut3(), block.timestamp + 1);

        uint256 gross = 10 ether;
        uint256 grossCommission = (gross * 6) / 100; // 0.6 ether (6% Flap fee, under the 10% cap)
        uint256 net = gross - grossCommission; // 9.4 ether
        uint256 spent = (net * 4000) / 10_000 + (net - (net * 4000) / 10_000 - (net * 3000) / 10_000); // s0 + s2 dust-absorbing last leg
        // s2 is the last leg (absorbs dust): amountIn(s2) = net - alloc(s0) - alloc(s1). alloc(s1) is
        // computed but its swap reverts, so spentWBNB = alloc(s0) + amountIn(s2).
        uint256 allocS0 = (net * 4000) / 10_000;
        uint256 allocS1 = (net * 3000) / 10_000;
        uint256 amountInS2 = net - allocS0 - allocS1;
        spent = allocS0 + amountInS2;
        uint256 expCommission = (grossCommission * spent) / net;

        assertEq(wbnb.balanceOf(treasury), expCommission, "commission proportional to WBNB actually spent (L1)");
    }

    // ── I3: initialize-time validation reverts (via factory.newVault) ───────────

    function testInitRevertsBadGridSizeLow() public {
        _expectInitRevert(
            _vaultDataFull(3, 100, 1e18, 600, treasury, 0, _goodStocksData()),
            bytes(unicode"Bad grid size / 网格大小无效")
        );
    }

    function testInitRevertsBadGridSizeHigh() public {
        _expectInitRevert(
            _vaultDataFull(2000, 100, 1e18, 600, treasury, 0, _goodStocksData()),
            bytes(unicode"Bad grid size / 网格大小无效")
        );
    }

    function testInitRevertsBadGridTaxRate() public {
        _expectInitRevert(
            _vaultDataFull(36, 5, 1e18, 600, treasury, 0, _goodStocksData()),
            bytes(unicode"Bad grid tax rate / 网格税率无效")
        );
    }

    function testInitRevertsCommissionTooHigh() public {
        _expectInitRevert(
            _vaultDataFull(36, 100, 1e18, 2000, treasury, 0, _goodStocksData()),
            bytes(unicode"Commission too high / 佣金过高")
        );
    }

    function testInitRevertsZeroInitialPrice() public {
        _expectInitRevert(
            _vaultDataFull(36, 100, 0, 600, treasury, 0, _goodStocksData()),
            bytes(unicode"Bad initial price / 初始价格无效")
        );
    }

    function testInitRevertsZeroTreasury() public {
        _expectInitRevert(
            _vaultDataFull(36, 100, 1e18, 600, address(0), 0, _goodStocksData()),
            bytes(unicode"Zero address / 零地址")
        );
    }

    function testInitRevertsIntervalTooLong() public {
        _expectInitRevert(
            _vaultDataFull(36, 100, 1e18, 600, treasury, 31 days, _goodStocksData()),
            bytes(unicode"Interval too long / 间隔过长")
        );
    }

    // ── I3: setupMarket-time validation reverts (stocksData decoded there) ──────

    function testSetupRevertsWeightsNot10000() public {
        address[] memory stocks = new address[](2);
        stocks[0] = address(s0);
        stocks[1] = address(s1);
        uint24[] memory fees = new uint24[](2);
        fees[0] = 500;
        fees[1] = 500;
        uint16[] memory w = new uint16[](2);
        w[0] = 5000;
        w[1] = 4000; // sums to 9000
        StockpileBasketVaultV2 v = _newVaultWithStocks(abi.encode(stocks, fees, w));
        vm.expectRevert(bytes(unicode"Weights must sum to 10000 / 权重总和须为10000"));
        v.setupMarket();
    }

    function testSetupRevertsDuplicateStock() public {
        address[] memory stocks = new address[](2);
        stocks[0] = address(s0);
        stocks[1] = address(s0); // duplicate
        uint24[] memory fees = new uint24[](2);
        fees[0] = 500;
        fees[1] = 500;
        uint16[] memory w = new uint16[](2);
        w[0] = 6000;
        w[1] = 4000;
        StockpileBasketVaultV2 v = _newVaultWithStocks(abi.encode(stocks, fees, w));
        vm.expectRevert(bytes(unicode"Duplicate stock / 股票重复"));
        v.setupMarket();
    }

    function testSetupRevertsStockIsWbnb() public {
        address[] memory stocks = new address[](2);
        stocks[0] = address(wbnb); // illegal
        stocks[1] = address(s1);
        uint24[] memory fees = new uint24[](2);
        fees[0] = 500;
        fees[1] = 500;
        uint16[] memory w = new uint16[](2);
        w[0] = 6000;
        w[1] = 4000;
        StockpileBasketVaultV2 v = _newVaultWithStocks(abi.encode(stocks, fees, w));
        vm.expectRevert(bytes(unicode"Stock cannot be wbnb/usdt / stock不能为wbnb或usdt"));
        v.setupMarket();
    }

    function testSetupRevertsStockIsUsdt() public {
        address[] memory stocks = new address[](2);
        stocks[0] = address(s0);
        stocks[1] = address(usdt); // illegal
        uint24[] memory fees = new uint24[](2);
        fees[0] = 500;
        fees[1] = 500;
        uint16[] memory w = new uint16[](2);
        w[0] = 6000;
        w[1] = 4000;
        StockpileBasketVaultV2 v = _newVaultWithStocks(abi.encode(stocks, fees, w));
        vm.expectRevert(bytes(unicode"Stock cannot be wbnb/usdt / stock不能为wbnb或usdt"));
        v.setupMarket();
    }

    function testSetupRevertsEmptyStocks() public {
        address[] memory stocks = new address[](0);
        uint24[] memory fees = new uint24[](0);
        uint16[] memory w = new uint16[](0);
        StockpileBasketVaultV2 v = _newVaultWithStocks(abi.encode(stocks, fees, w));
        vm.expectRevert(bytes(unicode"No stocks / 无股票"));
        v.setupMarket();
    }

    function testSetupRevertsMismatchedArrays() public {
        address[] memory stocks = new address[](2);
        stocks[0] = address(s0);
        stocks[1] = address(s1);
        uint24[] memory fees = new uint24[](1); // wrong length
        fees[0] = 500;
        uint16[] memory w = new uint16[](2);
        w[0] = 6000;
        w[1] = 4000;
        StockpileBasketVaultV2 v = _newVaultWithStocks(abi.encode(stocks, fees, w));
        vm.expectRevert(bytes(unicode"Bad stock arrays / 股票数组无效"));
        v.setupMarket();
    }

    function testSetupRevertsTooManyStocks() public {
        uint256 n = 21; // > MAX_STOCKS (20)
        address[] memory stocks = new address[](n);
        uint24[] memory fees = new uint24[](n);
        uint16[] memory w = new uint16[](n);
        for (uint256 i = 0; i < n; i++) {
            stocks[i] = address(uint160(0x1000 + i)); // distinct, not wbnb/usdt
            fees[i] = 500;
            w[i] = 0;
        }
        StockpileBasketVaultV2 v = _newVaultWithStocks(abi.encode(stocks, fees, w));
        vm.expectRevert(bytes(unicode"Too many stocks / 股票过多"));
        v.setupMarket();
    }

    function testSetupExactlyMaxStocksOk() public {
        // Boundary: exactly MAX_STOCKS legs is allowed (weights sum to 10000).
        uint256 n = 20;
        address[] memory stocks = new address[](n);
        uint24[] memory fees = new uint24[](n);
        uint16[] memory w = new uint16[](n);
        for (uint256 i = 0; i < n; i++) {
            stocks[i] = address(uint160(0x2000 + i));
            fees[i] = 500;
            w[i] = 500; // 20 * 500 == 10000
        }
        StockpileBasketVaultV2 v = _newVaultWithStocks(abi.encode(stocks, fees, w));
        v.setupMarket();
        assertEq(v.stocksLength(), 20, "exactly MAX_STOCKS legs accepted");
    }

    // ── I3: registerWithGrid before setup, swapLeg/_pull only-self, guardian-only setters ─

    function testRegisterWithGridBeforeSetupReverts() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 0);
        vm.expectRevert(bytes(unicode"Market not set up / 市场未建立"));
        v.registerWithGrid();
    }

    function testSwapLegOnlySelfReverts() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 0);
        vm.prank(makeAddr("rando"));
        vm.expectRevert(bytes(unicode"Only self / 仅限自身"));
        v.swapLeg(0, 1, 0, block.timestamp + 1);
    }

    function testBasketPullOnlySelfReverts() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 0);
        v.setupMarket();
        StockBasket b = StockBasket(v.basket());
        vm.prank(makeAddr("rando"));
        vm.expectRevert(bytes(unicode"Only self / 仅限自身"));
        b._pull(address(s0), address(v), 0);
    }

    function testSetCommissionNonGuardianReverts() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 0);
        vm.prank(makeAddr("rando"));
        vm.expectRevert(bytes(unicode"Only Guardian / 仅限 Guardian"));
        v.setCommissionBps(100);
    }

    function testSetMinIntervalNonGuardianReverts() public {
        StockpileBasketVaultV2 v = _newVault(address(new MockTaxToken(100)), 600, 0);
        vm.prank(makeAddr("rando"));
        vm.expectRevert(bytes(unicode"Only Guardian / 仅限 Guardian"));
        v.setMinInterval(1 days);
    }
}
