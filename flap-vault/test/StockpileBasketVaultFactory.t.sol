// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {StockpileBasketVaultV2} from "../src/StockpileBasketVaultV2.sol";
import {StockpileBasketVaultFactory, VaultDataV1} from "../src/StockpileBasketVaultFactory.sol";
import {StockBasket} from "../src/StockBasket.sol";
import {VaultDataSchema} from "../src/flap/IVaultSchemasV1.sol";
import {IVaultFactoryValidationV2} from "../src/flap/IVaultFactory.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

import {MockWBNB} from "./mocks/MockWBNB.sol";
import {MockMintableERC20} from "./mocks/MockMintableERC20.sol";
import {MockUGM} from "./mocks/MockUGM.sol";
import {MockV3Router} from "./mocks/MockV3Router.sol";
import {MockTaxToken} from "./mocks/MockTaxToken.sol";

/// @title StockpileBasketVaultFactory unit tests (Rule 002 / 006 conformance)
contract StockpileBasketVaultFactoryTest is Test {
    address internal constant PORTAL = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
    address internal constant GUARDIAN = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;

    MockWBNB internal wbnb;
    MockMintableERC20 internal usdt;
    MockUGM internal ugm;
    MockV3Router internal router;
    MockMintableERC20 internal s0;
    MockMintableERC20 internal s1;

    StockpileBasketVaultFactory internal factory;
    address internal treasury;

    function setUp() public {
        vm.chainId(97);
        wbnb = new MockWBNB();
        usdt = new MockMintableERC20("USDT", "USDT", 18);
        ugm = new MockUGM();
        router = new MockV3Router();
        s0 = new MockMintableERC20("Stock0", "S0", 18);
        s1 = new MockMintableERC20("Stock1", "S1", 18);
        factory = new StockpileBasketVaultFactory(address(wbnb), address(usdt), address(ugm), address(router), 100);
        treasury = makeAddr("treasury");
    }

    function _vaultData() internal view returns (bytes memory) {
        address[] memory stocks = new address[](2);
        stocks[0] = address(s0);
        stocks[1] = address(s1);
        uint24[] memory fees = new uint24[](2);
        fees[0] = 500;
        fees[1] = 500;
        uint16[] memory w = new uint16[](2);
        w[0] = 6000;
        w[1] = 4000;
        VaultDataV1 memory d = VaultDataV1({
            gridSize: 100,
            gridTaxRateBps: 200,
            gridInitialPrice: 5e17,
            commissionBps: 500,
            treasury: treasury,
            minInterval: 1 hours,
            stocksData: abi.encode(stocks, fees, w)
        });
        return abi.encode(d);
    }

    // ── Construction: beacon + impl deployed, guardian is sole upgrade authority ─

    function testConstructorDeploysBeaconAndImpl() public {
        assertTrue(factory.beacon() != address(0), "beacon deployed");
        assertTrue(factory.beaconImplementation() != address(0), "impl deployed");
        assertTrue(factory.basketDeployer() != address(0), "basket deployer deployed");
        assertFalse(factory.isVaultUpgradesLocked(), "not locked at deploy");
        // The factory owns the beacon (the only account that can upgrade).
        assertEq(UpgradeableBeacon(factory.beacon()).owner(), address(factory), "factory owns beacon");
    }

    // ── newVault: portal succeeds, non-portal reverts (Rule 006) ────────────────

    function testNewVaultFromPortalSucceeds() public {
        address tax = address(new MockTaxToken(100));
        vm.prank(PORTAL);
        address vault = factory.newVault(tax, address(0), address(0xC0FFEE), _vaultData());

        assertTrue(vault != address(0), "vault created");
        assertEq(factory.allVaultsLength(), 1, "registry length");
        assertEq(factory.allVaults(0), vault, "registry entry");
        assertEq(factory.vaultOf(tax), vault, "vaultOf mapping");

        StockpileBasketVaultV2 v = StockpileBasketVaultV2(payable(vault));
        assertEq(v.taxToken(), tax, "taxToken wired");
        assertEq(v.gridSize(), 100, "gridSize wired");
        assertEq(v.commissionBps(), 500, "commission wired");
        assertEq(v.treasury(), treasury, "treasury wired");
        // Stock legs are decoded from the opaque stocksData LATER, in setupMarket (M1).
        assertEq(v.stocksLength(), 0, "stocks not decoded until setupMarket");
        v.setupMarket();
        assertEq(v.stocksLength(), 2, "stock legs wired after setupMarket");
    }

    function testNewVaultFromNonPortalReverts() public {
        address tax = address(new MockTaxToken(100));
        bytes memory data = _vaultData();
        vm.prank(makeAddr("rando"));
        vm.expectRevert(bytes(unicode"Only VaultPortal / 仅限 VaultPortal 调用"));
        factory.newVault(tax, address(0), address(0xC0FFEE), data);
    }

    function testNewVaultRejectsUnsupportedQuote() public {
        address tax = address(new MockTaxToken(100));
        bytes memory data = _vaultData();
        vm.prank(PORTAL);
        vm.expectRevert(bytes(unicode"Quote not supported / 报价代币不支持"));
        factory.newVault(tax, address(0xBAD), address(0xC0FFEE), data);
    }

    // ── setupMarket wires the per-vault basket + grid ───────────────────────────

    function testNewVaultThenSetupMarket() public {
        address tax = address(new MockTaxToken(100));
        bytes memory data = _vaultData();
        vm.prank(PORTAL);
        address vault = factory.newVault(tax, address(0), address(0xC0FFEE), data);
        StockpileBasketVaultV2 v = StockpileBasketVaultV2(payable(vault));

        v.setupMarket();
        assertTrue(v.basket() != address(0), "basket deployed");
        assertEq(StockBasket(v.basket()).vault(), vault, "vault is basket's sole minter");
        assertEq(v.gridId(), 1, "grid created");
    }

    // ── Quote-token support (Rule 006 view / B-11) ──────────────────────────────

    function testIsQuoteTokenSupported() public {
        assertTrue(factory.isQuoteTokenSupported(address(0)), "native BNB supported");
        assertTrue(factory.isQuoteTokenSupported(address(wbnb)), "WBNB supported");
        assertFalse(factory.isQuoteTokenSupported(address(0x1234)), "other quote unsupported");
    }

    // ── _validateBeforeLaunch via onBeforeLaunch ────────────────────────────────

    function testOnBeforeLaunchAcceptsNative() public view {
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory d;
        d.quoteToken = address(0);
        (bool ok, string memory reason) = factory.onBeforeLaunch(abi.encode(d));
        assertTrue(ok, "native accepted");
        assertEq(bytes(reason).length, 0, "no reason");
    }

    function testOnBeforeLaunchRejectsBadQuote() public view {
        IVaultFactoryValidationV2.LaunchValidationDataV1 memory d;
        d.quoteToken = address(0x9999);
        (bool ok,) = factory.onBeforeLaunch(abi.encode(d));
        assertFalse(ok, "bad quote rejected");
    }

    // ── vaultDataSchema matches the decode ABI (Rule 006 / B-12) ────────────────

    function testVaultDataSchema() public view {
        VaultDataSchema memory schema = factory.vaultDataSchema();
        assertEq(schema.fields.length, 7, "7 fields (flat scalars + one bytes tail)");
        assertFalse(schema.isArray, "single tuple");

        // Field order + type MUST match the VaultDataV1 struct exactly (M1). All types are in the schema
        // vocabulary {uint16,uint128,address,uint256,bytes} — no uint32/uint24 anywhere.
        assertEq(schema.fields[0].name, "gridSize");
        assertEq(schema.fields[0].fieldType, "uint16");
        assertEq(schema.fields[1].name, "gridTaxRateBps");
        assertEq(schema.fields[1].fieldType, "uint16");
        assertEq(schema.fields[2].name, "gridInitialPrice");
        assertEq(schema.fields[2].fieldType, "uint128");
        assertEq(schema.fields[3].name, "commissionBps");
        assertEq(schema.fields[3].fieldType, "uint16");
        assertEq(schema.fields[4].name, "treasury");
        assertEq(schema.fields[4].fieldType, "address");
        assertEq(schema.fields[5].name, "minInterval");
        assertEq(schema.fields[5].fieldType, "uint256");
        assertEq(schema.fields[6].name, "stocksData");
        assertEq(schema.fields[6].fieldType, "bytes");
    }

    // ── M1: schema ↔ decode round-trip (the compliance blocker) ─────────────────

    /// @notice Build `vaultData` EXACTLY as the schema describes — a flat scalar tuple + one opaque `bytes`
    ///         field, with stocksData = abi.encode(address[],uint24[],uint16[]) — then prove it round-trips
    ///         through `abi.decode(vaultData,(VaultDataV1))` in newVault and wires the basket/grid/legs
    ///         correctly after setupMarket. This is the Rule-002 schema-fidelity proof (finding M1).
    function testSchemaRoundTrip() public {
        address[] memory stocks = new address[](2);
        stocks[0] = address(s0);
        stocks[1] = address(s1);
        uint24[] memory fees = new uint24[](2);
        fees[0] = 500;
        fees[1] = 3000;
        uint16[] memory w = new uint16[](2);
        w[0] = 6000;
        w[1] = 4000;
        bytes memory stocksData = abi.encode(stocks, fees, w);

        VaultDataV1 memory d = VaultDataV1({
            gridSize: 144,
            gridTaxRateBps: 250,
            gridInitialPrice: 2e18,
            commissionBps: 700,
            treasury: treasury,
            minInterval: 2 hours,
            stocksData: stocksData
        });
        bytes memory vaultData = abi.encode(d);

        address tax = address(new MockTaxToken(100));
        vm.prank(PORTAL); // == factory._getVaultPortal() on chainId 97
        address vault = factory.newVault(tax, address(0), address(0xC0FFEE), vaultData);
        StockpileBasketVaultV2 v = StockpileBasketVaultV2(payable(vault));

        // Scalars decoded + stored at init; stocks stay opaque until setupMarket.
        assertEq(v.gridSize(), 144, "gridSize round-trip");
        assertEq(v.gridTaxRateBps(), 250, "gridTaxRateBps round-trip");
        assertEq(v.gridInitialPrice(), 2e18, "gridInitialPrice round-trip");
        assertEq(v.commissionBps(), 700, "commissionBps round-trip");
        assertEq(v.treasury(), treasury, "treasury round-trip");
        assertEq(v.minInterval(), 2 hours, "minInterval round-trip");
        assertEq(v.stocksLength(), 0, "stocks not decoded at init");

        // setupMarket decodes stocksData and wires legs + basket + grid in the leg order.
        v.setupMarket();
        assertEq(v.stocksLength(), 2, "legs wired from stocksData");
        {
            (address stk0, uint24 f0, uint16 w0) = v.stockAt(0);
            (address stk1, uint24 f1, uint16 w1) = v.stockAt(1);
            assertEq(stk0, address(s0));
            assertEq(f0, 500);
            assertEq(w0, 6000);
            assertEq(stk1, address(s1));
            assertEq(f1, 3000);
            assertEq(w1, 4000);
        }
        assertTrue(v.basket() != address(0), "basket deployed");
        assertEq(StockBasket(v.basket()).stocksLength(), 2, "basket has 2 stocks");
        assertEq(v.gridId(), 1, "grid created");
    }

    /// @notice Independent Rule-002 fidelity proof (M1): the schema declares a single tuple (isArray=false)
    ///         of (uint16,uint16,uint128,uint16,address,uint256,bytes). A generic UI encodes that as one
    ///         tuple-typed parameter — exactly `abi.encode(VaultDataV1)` — which round-trips through the
    ///         same `abi.decode(vaultData,(VaultDataV1))` newVault uses, yielding the identical fields.
    function testSchemaTupleDecodesStruct() public view {
        bytes memory sd0 = abi.encode(new address[](0), new uint24[](0), new uint16[](0));
        bytes memory vaultData = abi.encode(
            VaultDataV1({
                gridSize: 144,
                gridTaxRateBps: 250,
                gridInitialPrice: 2e18,
                commissionBps: 700,
                treasury: treasury,
                minInterval: 2 hours,
                stocksData: sd0
            })
        );
        VaultDataV1 memory r = abi.decode(vaultData, (VaultDataV1));
        assertEq(r.gridSize, 144);
        assertEq(r.gridTaxRateBps, 250);
        assertEq(uint256(r.gridInitialPrice), 2e18);
        assertEq(r.commissionBps, 700);
        assertEq(r.treasury, treasury);
        assertEq(r.minInterval, 2 hours);
        assertEq(keccak256(r.stocksData), keccak256(sd0), "stocksData tail preserved");
    }

    function testFactorySpecVersionDefault() public view {
        // Inherits the base "v2.2" (no override).
        assertEq(factory.factorySpecVersion(), "v2.2", "default spec version");
    }

    // ── Beacon administration: Guardian-only upgrade + lock (Rule 002/009) ──────

    function testUpgradeVaultImplementationGuardianOnly() public {
        StockpileBasketVaultV2 newImpl =
            new StockpileBasketVaultV2(address(wbnb), address(usdt), address(ugm), address(router), 100, factory.basketDeployer());

        vm.prank(makeAddr("rando"));
        vm.expectRevert(bytes(unicode"Only Guardian / 仅限 Guardian"));
        factory.upgradeVaultImplementation(address(newImpl));

        vm.prank(GUARDIAN);
        factory.upgradeVaultImplementation(address(newImpl));
        assertEq(factory.beaconImplementation(), address(newImpl), "impl upgraded by guardian");
    }

    function testLockVaultUpgradesGuardianOnlyAndPermanent() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert(bytes(unicode"Only Guardian / 仅限 Guardian"));
        factory.lockVaultUpgrades();

        vm.prank(GUARDIAN);
        factory.lockVaultUpgrades();
        assertTrue(factory.isVaultUpgradesLocked(), "locked");

        // After lock, even the Guardian can no longer upgrade (beacon ownership renounced).
        StockpileBasketVaultV2 newImpl =
            new StockpileBasketVaultV2(address(wbnb), address(usdt), address(ugm), address(router), 100, factory.basketDeployer());
        vm.prank(GUARDIAN);
        vm.expectRevert();
        factory.upgradeVaultImplementation(address(newImpl));
    }
}
