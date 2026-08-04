// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {StockBasket} from "../src/StockBasket.sol";
import {StockpileBasketVault} from "../src/StockpileBasketVault.sol";

/// @title Deploy the {StockBasket, StockpileBasketVault} pair on BSC mainnet (chainId 56) — VAULT+BASKET ONLY.
///
/// @notice The basket vault is the WBNB fee `marketAddress` of a Flap token launched with a WBNB quote.
///         A keeper periodically calls {StockpileBasketVault.distribute}, which skims a commission, swaps
///         the accrued WBNB into the 7 stock tokens (2-hop PancakeSwap V3 through USDT), DEPOSITS the bought
///         stocks into the single {StockBasket} index token (minting shares sized to the WBNB value spent),
///         and forwards those basket shares into a set of Stockpile grids seat-proportionally. Every grid
///         therefore pays out the SAME yield token — the basket — and a seat holder redeems one share for a
///         pro-rata slice of ALL 7 stocks at once.
///
///         This script only DEPLOYS + WIRES + LOGS the pair (basket → vault → `basket.setVault(vault)`). The
///         Stockpile grids are a product concern and are assumed to ALREADY EXIST — each created on the UGM
///         with `yieldToken == the basket`; their ids are supplied via env (GRID_ID_1..GRID_ID_7). Two
///         out-of-band steps then activate it:
///           1. the UGM guardian approves this vault as an adapter (`setApprovedAdapter(vault, true)`), then
///           2. anyone calls `vault.registerAllGrids()` (the vault binds itself as adapter for every grid;
///              its assert requires each grid's `yieldToken` to equal the basket).
///
///         Because the grids' yieldToken must equal the basket address (unknown until the basket is
///         deployed), the grids are expected to be created AFTER this deploy (or updated to point at the
///         basket) — hence no `createGrid` here. Run (simulate first, then broadcast):
///           cd contracts/vault
///           forge script script/DeployBasketVault.s.sol --tc DeployBasketVault \
///             --rpc-url $BSC_MAINNET --broadcast --legacy
///
///         REQUIRED env (real value at stake — confirm before broadcasting):
///           PRIVATE_KEY    deployer key (becomes the basket owner + vault owner/guardian)
///           UGM_ADDRESS    the audited Stockpile UnifiedGridManager on mainnet
///           GRID_ID_1..GRID_ID_7   the 7 pre-created grid ids (each grid's yieldToken must == the basket)
///         OPTIONAL env:
///           TREASURY        commission recipient (default: the deployer)
///           COMMISSION_BPS  commission in bps, <= 1000 (default 600 = 6%)
///           MIN_INTERVAL    distribute time-gate in seconds (default 3600 = 1h)
///           WBNB / USDT / PANCAKE_V3_ROUTER / WBNB_USDT_FEE  routing overrides (default: BSC mainnet)
contract DeployBasketVault is Script {
    // ── BSC mainnet routing defaults (see DECISIONS.md D20) ──────────────────────
    address internal constant WBNB_DEFAULT = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT_DEFAULT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant ROUTER_DEFAULT = 0x1b81D678ffb9C0263b24A97847620C99d213eB14; // PancakeSwap V3 SwapRouter
    uint24 internal constant WBNB_USDT_FEE_DEFAULT = 100;

    // ── The 7 stocks (verified from the reference vault's `stocks(i)`) + their USDT→stock V3 fee tiers ──
    address internal constant SPCXB = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;
    address internal constant QQQB = 0x205812CdBed920aFf76C6580abD681a46D11efc7;
    address internal constant NVDAB = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436;
    address internal constant SPYB = 0x7138b48df7D98D7e3cc221BfE7192D0a178182D8;
    address internal constant TSLAB = 0x5b1910eAaD6450E50f816082Aa078C41F10C292f;
    address internal constant AAPLB = 0x431a3BEE82E2ca41e49895CbECE5bB0F76A89b7A;
    address internal constant XAUt = 0x21cAef8A43163Eea865baeE23b9C2E327696A3bf;

    /// @dev Bundles the routing + tunable config so the deploy helper stays within the (non-via-ir) stack limit.
    struct Cfg {
        address wbnb;
        address usdt;
        address router;
        uint24 wbnbUsdtFee;
        address ugm;
        address treasury;
        uint16 commissionBps;
        uint256 minInterval;
    }

    function run() external {
        require(block.chainid == 56, "run on BSC mainnet (chainId 56)");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address ugm = vm.envAddress("UGM_ADDRESS");
        require(ugm.code.length > 0, "UGM_ADDRESS not a contract");

        Cfg memory c = Cfg({
            wbnb: vm.envOr("WBNB", WBNB_DEFAULT),
            usdt: vm.envOr("USDT", USDT_DEFAULT),
            router: vm.envOr("PANCAKE_V3_ROUTER", ROUTER_DEFAULT),
            wbnbUsdtFee: uint24(vm.envOr("WBNB_USDT_FEE", uint256(WBNB_USDT_FEE_DEFAULT))),
            ugm: ugm,
            treasury: vm.envOr("TREASURY", deployer),
            commissionBps: uint16(vm.envOr("COMMISSION_BPS", uint256(600))), // 6%
            minInterval: vm.envOr("MIN_INTERVAL", uint256(3600)) // 1h
        });

        address[] memory stocks = _stocks();
        uint256[] memory gridIds = _gridIds();

        vm.startBroadcast(pk);
        (address basket, address vault) = _deployPair(stocks, gridIds, c);
        vm.stopBroadcast();

        _report(basket, vault, deployer, c);
    }

    // ── Helpers (kept small so no single stack frame overflows under the non-via-ir optimizer) ──

    /// @dev The 7 real stock tokens, in the fixed order SPCXB,QQQB,NVDAB,SPYB,TSLAB,AAPLB,XAUt. The vault's
    ///      stock-leg order MUST equal the basket's stock order (deposit pulls positionally) — both derive
    ///      from THIS list, so they line up by construction.
    function _stocks() internal pure returns (address[] memory s) {
        s = new address[](7);
        s[0] = SPCXB;
        s[1] = QQQB;
        s[2] = NVDAB;
        s[3] = SPYB;
        s[4] = TSLAB;
        s[5] = AAPLB;
        s[6] = XAUt;
    }

    /// @dev The 7 pre-created grid ids, in the fixed stock order. Each grid MUST have `yieldToken == the
    ///      basket`, or `vault.registerAllGrids()` will revert. Defaults 1..7 are ONLY for simulation.
    function _gridIds() internal view returns (uint256[] memory gridIds) {
        gridIds = new uint256[](7);
        for (uint256 i = 0; i < 7; i++) {
            gridIds[i] = vm.envOr(string.concat("GRID_ID_", vm.toString(i + 1)), uint256(i + 1));
        }
    }

    /// @dev The 7 stock legs: USDT→stock fee tier per stock + an equal-ish weight split summing to exactly
    ///      10_000. `stocks` fixes the ORDER (must equal the basket's). Edit here for a weighted basket.
    function _legs(address[] memory stocks) internal pure returns (StockpileBasketVault.StockLeg[] memory legs) {
        uint24[7] memory fees = [uint24(2500), 100, 2500, 100, 2500, 2500, 2500];
        uint16[7] memory weights = [uint16(1429), 1429, 1429, 1429, 1429, 1429, 1426]; // sums to 10_000
        legs = new StockpileBasketVault.StockLeg[](7);
        for (uint256 i = 0; i < 7; i++) {
            legs[i] =
                StockpileBasketVault.StockLeg({stock: stocks[i], stockFee: fees[i], swapWeightBps: weights[i]});
        }
    }

    function _deployPair(address[] memory stocks, uint256[] memory gridIds, Cfg memory c)
        internal
        returns (address basket, address vault)
    {
        StockBasket b = new StockBasket("Stockpile Basket", "SPB", stocks);
        vault = _newVault(address(b), stocks, gridIds, c);
        b.setVault(vault); // one-shot: bind the vault as the basket's sole minter
        return (address(b), vault);
    }

    /// @dev Build the stock legs into a local first (avoids a stack-too-deep on the 11-arg constructor under
    ///      the non-via-ir optimizer), then deploy the vault over the basket + supplied grid ids.
    function _newVault(address basket, address[] memory stocks, uint256[] memory gridIds, Cfg memory c)
        internal
        returns (address)
    {
        StockpileBasketVault.StockLeg[] memory legs = _legs(stocks);
        StockpileBasketVault v = new StockpileBasketVault(
            c.wbnb,
            c.usdt,
            c.ugm,
            c.router,
            c.wbnbUsdtFee,
            basket,
            c.treasury,
            c.commissionBps,
            c.minInterval,
            legs,
            gridIds
        );
        return address(v);
    }

    function _report(address basket, address vault, address deployer, Cfg memory c) internal view {
        StockpileBasketVault v = StockpileBasketVault(payable(vault));
        console2.log("== StockBasket + StockpileBasketVault mainnet deploy (chainId 56) ==");
        console2.log("StockBasket (SPB):    ", basket);
        console2.log("StockpileBasketVault: ", vault);
        console2.log("owner/guardian:       ", deployer);
        console2.log("ugm:                  ", c.ugm);
        console2.log("treasury:             ", c.treasury);
        console2.log("commissionBps:        ", uint256(c.commissionBps));
        console2.log("minInterval (s):      ", c.minInterval);
        console2.log("router:               ", c.router);
        console2.log("-- per-leg (i / stock / gridId) + grid assetHash --");
        for (uint256 i = 0; i < 7; i++) {
            (address stock,,) = v.stockAt(i);
            (uint256 gridId, bytes32 assetHash) = v.gridAt(i);
            console2.log(i, stock, gridId);
            console2.logBytes32(assetHash);
        }
        console2.log("NEXT 1) create/point each of the 7 grids so its yieldToken == the basket above");
        console2.log("NEXT 2) UGM guardian: setApprovedAdapter(vault, true)");
        console2.log("NEXT 3) anyone: vault.registerAllGrids()  (asserts each grid yieldToken == basket)");
        console2.log("NEXT 4) set the token launch marketAddress = vault; keeper calls distribute(minOut[7], deadline)");
    }
}
