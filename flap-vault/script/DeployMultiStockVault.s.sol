// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {MultiStockVault} from "../src/MultiStockVault.sol";

/// @title Deploy MultiStockVault on BSC mainnet (chainId 56) — VAULT ONLY, no factory.
///
/// @notice MultiStockVault is the WBNB fee `marketAddress` of a Flap token launched with a WBNB quote.
///         A keeper periodically calls {MultiStockVault.distribute}, which skims a commission and swaps
///         the accrued WBNB into the 7 stock tokens (2-hop PancakeSwap V3 through USDT), forwarding each
///         into its own Stockpile grid via the UGM.
///
///         This script only DEPLOYS + LOGS the vault. The 7 Stockpile grids are a product concern and
///         are assumed to ALREADY EXIST (each created on the UGM with `yieldToken == its stock`); their
///         ids are supplied via env (GRID_ID_1..GRID_ID_7). After deploy, two out-of-band steps wire it:
///           1. the UGM guardian approves this vault as an adapter (`setApprovedAdapter(vault, true)`), then
///           2. anyone calls `vault.registerAllGrids()` (the vault binds itself as adapter for all 7 grids;
///              the vault's F3 assert requires each grid's yieldToken to equal its leg's stock).
///
///         Run (simulate first, then broadcast):
///           forge script script/DeployMultiStockVault.s.sol --tc DeployMultiStockVault \
///             --rpc-url $BSC_MAINNET --broadcast --legacy
///
///         REQUIRED env (real value at stake — confirm before broadcasting):
///           PRIVATE_KEY    deployer key (becomes the vault owner/guardian)
///           UGM_ADDRESS    the audited Stockpile UnifiedGridManager on mainnet (0xB7156E69…)
///           GRID_ID_1..GRID_ID_7   the 7 pre-created grid ids (grid i must have yieldToken == stock i, in the
///                                  fixed order SPCXB,QQQB,NVDAB,SPYB,TSLAB,AAPLB,XAUt)
///         OPTIONAL env:
///           TREASURY        commission recipient (default: the deployer)
///           COMMISSION_BPS  commission in bps, <= 1000 (default 600 = 6%)
///           MIN_INTERVAL    distribute time-gate in seconds (default 3600 = 1h)
///           WBNB / USDT / PANCAKE_V3_ROUTER / WBNB_USDT_FEE  routing overrides (default: BSC mainnet)
contract DeployMultiStockVault is Script {
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

    function run() external {
        require(block.chainid == 56, "run on BSC mainnet (chainId 56)");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address ugm = vm.envAddress("UGM_ADDRESS");
        require(ugm.code.length > 0, "UGM_ADDRESS not a contract");

        address treasury = vm.envOr("TREASURY", deployer);
        uint16 commissionBps = uint16(vm.envOr("COMMISSION_BPS", uint256(600))); // 6%
        uint256 minInterval = vm.envOr("MIN_INTERVAL", uint256(3600)); // 1h

        address wbnb = vm.envOr("WBNB", WBNB_DEFAULT);
        address usdt = vm.envOr("USDT", USDT_DEFAULT);
        address router = vm.envOr("PANCAKE_V3_ROUTER", ROUTER_DEFAULT);
        uint24 wbnbUsdtFee = uint24(vm.envOr("WBNB_USDT_FEE", uint256(WBNB_USDT_FEE_DEFAULT)));

        // The 7 pre-created grid ids, in the fixed stock order. Each grid MUST have yieldToken == its stock,
        // or vault.registerAllGrids() will revert (F3 assert). Defaults 1..7 are ONLY for simulation.
        uint256[7] memory gridIds;
        for (uint256 i = 0; i < 7; i++) {
            gridIds[i] = vm.envOr(string.concat("GRID_ID_", vm.toString(i + 1)), uint256(i + 1));
        }

        MultiStockVault.BasketParams memory basket = MultiStockVault.BasketParams({
            stocks: [SPCXB, QQQB, NVDAB, SPYB, TSLAB, AAPLB, XAUt],
            gridIds: gridIds,
            stockFees: [uint24(2500), 100, 2500, 100, 2500, 2500, 2500],
            // Equal-ish split summing to exactly 10_000 (edit here for a weighted basket).
            weightsBps: [uint16(1429), 1429, 1429, 1429, 1429, 1429, 1426]
        });

        vm.startBroadcast(pk);
        MultiStockVault vault =
            new MultiStockVault(wbnb, usdt, ugm, router, wbnbUsdtFee, treasury, commissionBps, minInterval, basket);
        vm.stopBroadcast();

        console2.log("== MultiStockVault mainnet deploy (chainId 56) ==");
        console2.log("MultiStockVault:      ", address(vault));
        console2.log("owner/guardian:       ", deployer);
        console2.log("ugm:                  ", ugm);
        console2.log("treasury:             ", treasury);
        console2.log("commissionBps:        ", commissionBps);
        console2.log("minInterval (s):      ", minInterval);
        console2.log("router:               ", router);
        console2.log("-- per-leg (stock / gridId / assetHash) --");
        for (uint256 i = 0; i < 7; i++) {
            (address stock, uint256 gridId, bytes32 assetHash,,) = vault.legs(i);
            console2.log(i, stock, gridId);
            console2.logBytes32(assetHash);
        }
        console2.log("NEXT 1) UGM guardian: setApprovedAdapter(vault, true)");
        console2.log("NEXT 2) anyone: vault.registerAllGrids()  (each grid yieldToken must == its stock)");
        console2.log("NEXT 3) set the token launch marketAddress = vault; keeper calls distribute(minOut[7], deadline)");
    }
}
