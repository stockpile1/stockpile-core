// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {FlapBSCFixture} from "../FlapBSCFixture.sol";
import {IVaultPortal, IVaultPortalTypes} from "../../../src/vault/flap/IVaultPortal.sol";

import {StockpileBasketVaultFactory, VaultDataV1} from "../../../src/vault/StockpileBasketVaultFactory.sol";
import {StockpileBasketVaultV2} from "../../../src/vault/StockpileBasketVaultV2.sol";
import {StockBasket} from "../../../src/vault/StockBasket.sol";
import {MockUGM} from "../mocks/MockUGM.sol";
import {StockpileSlippageOracle} from "../../../src/vault/StockpileSlippageOracle.sol";

/// @title FlapVaultBackedLaunch — TRUE Flap vault-backed launch, end-to-end on a BSC-mainnet fork
///
/// @notice Proves the WHOLE conforming path against production Flap + PancakeSwap V3 liquidity:
///
///   1. Deploy our {StockpileBasketVaultFactory} wired to the REAL mainnet WBNB / USDT / PancakeSwap V3
///      router (fee 100) + a hermetic {MockUGM} grid sink (the factory self-deploys its own
///      {StockBasketDeployer} + vault impl + beacon in its constructor).
///   2. Launch a real 7777-vanity Flap V3 tax token through the REAL mainnet Flap
///      `VaultPortal.newTokenV6WithVault` (native-BNB quote, factory = ours, vaultData = a valid
///      VaultDataV1 with the 4 production stocks). The VaultPortal calls our `factory.newVault(...)`, which
///      deploys + initializes the per-token BeaconProxy vault. We assert the vault exists both via
///      `VaultPortal.getVault(token).vault` and `factory.vaultOf(token)`, and that init wired the config.
///   3. `vault.setupMarket()` deploys the vault's OWN {StockBasket} (over the 4 production stocks) + creates its
///      OWN grid on the sink; assert basket.getStocks() == the 4 stocks and gridId != 0.
///   4. Wire the sink: `ugm.setApprovedAdapter(vault, true)` + `vault.registerWithGrid()`.
///   5. Fund the vault with native BNB (the Flap fee path), then — pranking as the mainnet Flap Guardian
///      (`_getGuardian()`) — call `vault.distributeUniform(0, deadline)`: assert the commission is skimmed
///      to the treasury, the real WBNB→USDT→stock swaps executed (basket physically holds all 4 stocks),
///      basket shares were minted, and the grid was fed (`MockUGM.yieldByAsset(assetHash) > 0`).
///   6. A holder redeems basket shares → receives a pro-rata slice of ALL 4 real stocks.
///
///         Run (public RPC may 429 — the TEST itself is the proof):
///           BSC_RPC_URL=https://bsc-dataseed.bnbchain.org \
///             forge test --root contracts/vault \
///             --match-path 'test/fork/FlapVaultBackedLaunch.fork.t.sol' -vv
contract FlapVaultBackedLaunchForkTest is FlapBSCFixture {
    // ── Live BSC-mainnet infrastructure ─────────────────────────────────────────
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant PANCAKE_V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    uint24 internal constant WBNB_USDT_FEE = 100;

    // The 4 PRODUCTION stocks with their live USDT→stock V3 fee tiers — kept identical to
    // {StockConfig} so this fork run measures the real basket, gas included.
    address internal constant SPCXB = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;
    address internal constant NVDAB = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436;
    address internal constant AAPLB = 0x431a3BEE82E2ca41e49895CbECE5bB0F76A89b7A;
    address internal constant GMEON = 0xdABb9afF4cf02f26D2014e4cA9f94aC6fe6572a3;

    // ── Vault config (a valid VaultDataV1) ──────────────────────────────────────
    uint16 internal constant GRID_SIZE = 100;
    uint16 internal constant GRID_TAX_BPS = 100; // 1%/week (∈ [10,1000])
    uint128 internal constant GRID_INITIAL_PRICE = 1e15;
    uint16 internal constant COMMISSION_BPS = 600; // 6% cap
    uint256 internal constant MIN_INTERVAL = 0;
    uint256 internal constant FUND = 1 ether; // native BNB fee seeded on the vault

    MockUGM internal ugm;
    StockpileBasketVaultFactory internal factory;
    StockpileSlippageOracle internal oracle;
    address internal treasury = makeAddr("treasury");
    address internal launcher = makeAddr("launcher");

    function setUp() public {
        _forkBSCMainnet(); // chainid becomes 56 ⇒ _getVaultPortal()/_getGuardian() resolve to mainnet
        ugm = new MockUGM();
        // 5-arg constructor: self-deploys StockBasketDeployer + vault impl + UpgradeableBeacon.
        // The REAL oracle against live PancakeSwap V3 pools — this fork run is what validates its maths.
        oracle = new StockpileSlippageOracle(PANCAKE_V3_FACTORY, WBNB, USDT, WBNB_USDT_FEE);
        factory = new StockpileBasketVaultFactory(
            WBNB, USDT, address(ugm), PANCAKE_V3_ROUTER, WBNB_USDT_FEE, address(oracle)
        );

        vm.label(address(factory), "StockpileBasketVaultFactory");
        vm.label(address(ugm), "MockUGM(sink)");
        vm.label(WBNB, "WBNB");
        vm.label(USDT, "USDT");
        vm.label(PANCAKE_V3_ROUTER, "PancakeV3Router");
    }

    // ── vaultData builder (the exact Rule-002 schema tuple) ─────────────────────

    function _stocks() internal pure returns (address[] memory s) {
        s = new address[](4);
        s[0] = SPCXB;
        s[1] = NVDAB;
        s[2] = AAPLB;
        s[3] = GMEON;
    }

    function _vaultData() internal view returns (bytes memory) {
        address[] memory stocks = _stocks();
        uint24[] memory fees = new uint24[](4);
        fees[0] = 2500;
        fees[1] = 2500;
        fees[2] = 2500;
        fees[3] = 2500;
        uint16[] memory weights = new uint16[](4);
        weights[0] = 2500;
        weights[1] = 2500;
        weights[2] = 2500;
        weights[3] = 2500; // sums to 10_000
        VaultDataV1 memory d = VaultDataV1({
            gridSize: GRID_SIZE,
            gridTaxRateBps: GRID_TAX_BPS,
            gridInitialPrice: GRID_INITIAL_PRICE,
            commissionBps: COMMISSION_BPS,
            treasury: treasury,
            minInterval: MIN_INTERVAL,
            stocksData: abi.encode(stocks, fees, weights)
        });
        return abi.encode(d);
    }

    /// @dev Launch the 7777 token through the REAL VaultPortal, bound to our factory. Returns the token.
    /// @dev The deterministic vanity grind can land on a 7777 address that is ALREADY a live token on
    ///      mainnet (a prior launcher used the same salt), which the Portal rejects with TokenAlreadyStaged.
    ///      So keep grinding for the NEXT 7777 whose predicted address is still codeless (unused).
    function _launch() internal returns (address token) {
        bytes32 salt;
        for (uint256 i = 0; i < 64; i++) {
            salt = _findVanitySalt(VanityType.VANITY_7777, TOKEN_IMPL_TAXED_V3, PORTAL);
            if (_predictAddress(TOKEN_IMPL_TAXED_V3, salt, PORTAL).code.length == 0) break;
        }
        IVaultPortalTypes.NewTokenV6WithVaultParams memory params =
            _buildV3TaxTokenParams("Stockpile Basket", "SPBK", salt, address(factory), _vaultData());

        // Launch from a fresh EOA (msg.sender AND tx.origin) — production launchers gate on both.
        vm.deal(launcher, 1 ether);
        vm.startPrank(launcher, launcher);
        token = IVaultPortal(VAULT_PORTAL).newTokenV6WithVault{value: params.quoteAmt}(params);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  Full end-to-end conformance proof.
    // ─────────────────────────────────────────────────────────────────────────
    function test_VaultBackedLaunch_EndToEnd() public {
        // ── 1-2. Launch through the real VaultPortal → our factory deploys+inits the vault. ──
        address token = _launch();
        assertTrue(token != address(0), "token launched");
        // 7777 vanity actually enforced by the portal.
        bytes20 tb = bytes20(token);
        assertTrue(tb[18] == 0x77 && tb[19] == 0x77, "token ends in 7777");

        address vaultAddr = factory.vaultOf(token);
        assertTrue(vaultAddr != address(0), "factory recorded the vault");
        assertEq(factory.allVaultsLength(), 1, "one vault created");

        // The real VaultPortal also resolves the same vault for this token.
        IVaultPortalTypes.VaultInfo memory info = IVaultPortal(VAULT_PORTAL).getVault(token);
        assertEq(info.vault, vaultAddr, "VaultPortal.getVault == factory.vaultOf");
        assertTrue(info.vault != address(0), "VaultPortal.getVault(token).vault != 0");
        assertEq(info.vaultFactory, address(factory), "VaultPortal records our factory");

        StockpileBasketVaultV2 vault = StockpileBasketVaultV2(payable(vaultAddr));
        vm.label(vaultAddr, "StockpileBasketVaultV2");

        // ── initialize wired the config (D18: taxToken stored, never called at init). ──
        assertEq(vault.taxToken(), token, "taxToken wired to the launched token");
        assertEq(vault.gridSize(), GRID_SIZE, "gridSize wired");
        assertEq(vault.gridTaxRateBps(), GRID_TAX_BPS, "gridTaxRateBps wired");
        assertEq(vault.gridInitialPrice(), GRID_INITIAL_PRICE, "gridInitialPrice wired");
        assertEq(vault.commissionBps(), COMMISSION_BPS, "commission wired");
        assertEq(vault.treasury(), treasury, "treasury wired");
        assertEq(vault.stocksLength(), 0, "stocks stay opaque until setupMarket (M1)");
        assertEq(vault.basket(), address(0), "no basket until setupMarket");

        // ── 3. setupMarket: basket + grid built. ──
        vault.setupMarket();
        address basketAddr = vault.basket();
        assertTrue(basketAddr != address(0), "basket deployed");
        assertTrue(vault.gridId() != 0, "grid created");
        assertEq(vault.stocksLength(), 4, "4 stock legs decoded");

        StockBasket basket = StockBasket(basketAddr);
        address[] memory bs = basket.getStocks();
        assertEq(bs.length, 4, "basket has 4 stocks");
        assertEq(bs[0], SPCXB, "basket stock 0 == SPCXB");
        assertEq(bs[1], NVDAB, "basket stock 1 == NVDAB");
        assertEq(bs[2], AAPLB, "basket stock 2 == AAPLB");
        assertEq(bs[3], GMEON, "basket stock 3 == GMEon");
        assertEq(basket.vault(), vaultAddr, "vault is the basket's sole minter");

        // ── 4. Wire the sink: guardian approves the vault as adapter, vault binds itself. ──
        ugm.setApprovedAdapter(vaultAddr, true);
        // Not strictly read by V2's single-grid path, but mirror a well-configured grid.
        ugm.setGridYieldToken(vault.gridId(), basketAddr);
        ugm.setGridTotalSeats(vault.gridId(), GRID_SIZE);
        vault.registerWithGrid();

        // ── 5. Fund with native BNB (the Flap fee path), then guardian-gated distribute. ──
        vm.deal(vaultAddr, FUND);
        assertEq(vault.pendingDistribute(), FUND, "pending counts native BNB");

        bytes32 assetHash = vault.assetHash();
        vm.prank(FLAP_GUARDIAN); // == _getGuardian() on chainid 56 // the mainnet Flap Guardian — proves guardian-gated distribute
        uint256 gasBefore = gasleft();
        uint256 basketMinted = vault.distributeUniform(0, block.timestamp + 300);
        uint256 distributeGas = gasBefore - gasleft();

        // Rule 008 §4: the Flap Trigger Service hard-caps every callback at 2,000,000 gas. This is the
        // REAL cost against live PancakeSwap V3 pools (the unit tests' mock router is far cheaper), so it
        // is the number that decides how many stock legs can run in one triggered distribute.
        emit log_named_uint("REAL distribute gas (4 legs, live V3, with oracle)", distributeGas);
        emit log_named_uint("REAL gas per stock leg (approx)", distributeGas / 4);
        assertLt(distributeGas, 2_000_000, "4-leg distribute must fit the Trigger Service 2M callback cap");

        // Commission skimmed to treasury in WBNB (>0, never above the 6% cap on the gross).
        uint256 commission = IERC20(WBNB).balanceOf(treasury);
        assertGt(commission, 0, "commission skimmed to treasury");
        assertLe(commission, (FUND * COMMISSION_BPS) / 10_000, "commission within the 6% cap");

        // Native BNB fully wrapped + consumed; basket shares minted.
        assertEq(vaultAddr.balance, 0, "native wrapped + spent");
        assertGt(basketMinted, 0, "basket shares minted");
        assertEq(basket.totalSupply(), basketMinted, "supply == minted");

        // ── Oracle sanity: the TWAP maths must agree with what the pools actually paid. ──
        //
        // This is the check that validates StockpileSlippageOracle's hand-transcribed TickMath /
        // FullMath against live pools. A transcription error would not revert — it would silently quote
        // an absurd price, making the floor either unreachable (every leg skips) or meaningless (a floor
        // near zero). Bounding realized-vs-quoted on BOTH sides catches either failure.
        {
            uint256 legIn = ((FUND - commission) * 2500) / 10_000; // SPCXB leg's WBNB input
            uint256 usdtLeg = oracle.quoteHop(WBNB, USDT, WBNB_USDT_FEE, uint128(legIn));
            uint256 quoted = oracle.quoteHop(USDT, SPCXB, 2500, uint128(usdtLeg));
            uint256 realized = IERC20(SPCXB).balanceOf(basketAddr);

            assertGt(quoted, 0, "oracle produced a quote");
            assertGt(realized, (quoted * 80) / 100, "realized within 20% below the TWAP quote");
            assertLt(realized, (quoted * 120) / 100, "realized within 20% above the TWAP quote");
        }

        // Real WBNB→USDT→stock swaps happened: the basket physically holds all 4 stocks.
        assertGt(IERC20(SPCXB).balanceOf(basketAddr), 0, "basket holds SPCXB");
        assertGt(IERC20(NVDAB).balanceOf(basketAddr), 0, "basket holds NVDAB");
        assertGt(IERC20(AAPLB).balanceOf(basketAddr), 0, "basket holds AAPLB");
        assertGt(IERC20(GMEON).balanceOf(basketAddr), 0, "basket holds GMEon");

        // Grid fed: the whole minted basket forwarded into the vault's single grid.
        assertEq(ugm.yieldByAsset(assetHash), basketMinted, "grid received all basket shares");
        assertEq(basket.balanceOf(vaultAddr), 0, "no basket left on the vault");

        // ── 6. A holder redeems basket shares → gets a pro-rata slice of ALL 4 real stocks. ──
        // The MockUGM custodies the shares it pulled; a seat holder would hold them in production.
        uint256 redeemShares = ugm.yieldByAsset(assetHash) / 2;
        assertGt(redeemShares, 0, "shares to redeem");
        address holder = makeAddr("seatHolder");
        vm.prank(address(ugm));
        uint256[] memory got = basket.redeem(redeemShares, holder);

        assertEq(got.length, 4, "4 stocks returned");
        assertGt(IERC20(SPCXB).balanceOf(holder), 0, "holder got SPCXB");
        assertGt(IERC20(NVDAB).balanceOf(holder), 0, "holder got NVDAB");
        assertGt(IERC20(AAPLB).balanceOf(holder), 0, "holder got AAPLB");
        assertGt(IERC20(GMEON).balanceOf(holder), 0, "holder got GMEon");
        assertEq(basket.totalSupply(), basketMinted - redeemShares, "supply burned by redeem");
        assertEq(IERC20(SPCXB).balanceOf(holder), got[0], "SPCXB out matches return value");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  distribute is Guardian/keeper-gated: a random caller cannot distribute.
    // ─────────────────────────────────────────────────────────────────────────
    function test_Distribute_IsGuardianOrKeeperGated() public {
        address token = _launch();
        StockpileBasketVaultV2 vault = StockpileBasketVaultV2(payable(factory.vaultOf(token)));
        vault.setupMarket();
        ugm.setApprovedAdapter(address(vault), true);
        vault.registerWithGrid();
        vm.deal(address(vault), FUND);

        vm.prank(makeAddr("rando"));
        vm.expectRevert(bytes(unicode"Not a keeper / 非keeper"));
        vault.distributeUniform(0, block.timestamp + 300);

        // The mainnet Guardian is always a permitted keeper (Rule 001).
        vm.prank(FLAP_GUARDIAN); // == _getGuardian() on chainid 56
        uint256 minted = vault.distributeUniform(0, block.timestamp + 300);
        assertGt(minted, 0, "guardian distribute works");
    }
}
