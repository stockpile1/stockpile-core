// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {StockpileBasketVaultFactory} from "../src/vault/StockpileBasketVaultFactory.sol";
import {MockMintableERC20} from "../test/vault/mocks/MockMintableERC20.sol";
import {MockV3Router} from "../test/vault/mocks/MockV3Router.sol";
import {MockSlippageOracle} from "../test/vault/mocks/MockSlippageOracle.sol";
import {StockConfig} from "./StockConfig.sol";
import {StockpileSlippageOracle} from "../src/vault/StockpileSlippageOracle.sol";
import {BscAddresses} from "../src/config/BscAddresses.sol";

/// @title DeployVaultFactory — deploy the Flap vault-backed {StockpileBasketVaultFactory}
///
/// @notice One re-runnable, chain-aware deploy for the factory the Flap `VaultPortal.newTokenV6WithVault`
///         calls. The factory's constructor SELF-DEPLOYS its {StockBasketDeployer}, the vault
///         implementation, and the {UpgradeableBeacon} — so this script only wires the five inputs
///         (wbnb, usdt, ugm, router, wbnbUsdtFee) and reads the rest back.
///
///         Chain defaults (override any of them with the env vars in [brackets]):
///           • BSC MAINNET (56): real WBNB, USDT, PancakeSwap V3 SwapRouter, and the live UGM.
///           • BSC TESTNET (97): the live, already-allowlisted tWBNB + live UGM, plus freshly deployed
///             mock USDT + {MockV3Router} + 3 mock "stock" tokens — real BSC-USD / V3 pools don't exist
///             on testnet, and the mock router mints swap proceeds 1:1 so `distribute()` works there.
///
///         Env: PRIVATE_KEY (required). Optional overrides: WBNB, USDT, UGM, ROUTER, WBNB_USDT_FEE.
///
///         ── Run (dry-run first; the caller adds --broadcast to actually send) ──────────────────────────
///           # TESTNET (97)
///           PRIVATE_KEY=0x… forge script script/DeployVaultFactory.s.sol \
///             --rpc-url https://data-seed-prebsc-1-s1.bnbchain.org:8545
///           # MAINNET (56) — add --broadcast --verify when ready
///           PRIVATE_KEY=0x… forge script script/DeployVaultFactory.s.sol \
///             --rpc-url $BSC_RPC_URL --broadcast --verify
contract DeployVaultFactory is Script {
    // The Stockpile UnifiedGridManager (grid sink) — same address on chain 56 and 97.
    address internal constant UGM_DEFAULT = 0xaA40Da4d2F81207196b16C29A9683ABA9d98Cbd1;

    // ── BSC mainnet (56) ──
    address internal constant WBNB_56 = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT_56 = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant PANCAKE_V3_ROUTER_56 = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;

    // ── BSC testnet (97) ──
    address internal constant TWBNB_97 = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;

    // WBNB→USDT first-hop V3 fee tier.
    uint24 internal constant WBNB_USDT_FEE_DEFAULT = 100;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address ugm = vm.envOr("UGM", UGM_DEFAULT);
        uint24 fee = uint24(vm.envOr("WBNB_USDT_FEE", uint256(WBNB_USDT_FEE_DEFAULT)));

        address wbnb;
        address usdt;
        address router;
        address[4] memory stocks; // populated on testnet (the 4-stock basket for a later LaunchVaultToken)

        vm.startBroadcast(pk);

        if (block.chainid == 56) {
            wbnb = vm.envOr("WBNB", WBNB_56);
            usdt = vm.envOr("USDT", USDT_56);
            router = vm.envOr("ROUTER", PANCAKE_V3_ROUTER_56);
        } else if (block.chainid == 97) {
            wbnb = vm.envOr("WBNB", TWBNB_97);
            // No real BSC-USD or PancakeSwap V3 pools on testnet → deploy mocks unless overridden.
            usdt = vm.envOr("USDT", address(0));
            if (usdt == address(0)) usdt = address(new MockMintableERC20("USDT-T", "USDT-T", 18));
            router = vm.envOr("ROUTER", address(0));
            if (router == address(0)) router = address(new MockV3Router());
            // The 4-stock basket (mock tokens on testnet), in canonical StockConfig order.
            stocks = [
                address(new MockMintableERC20("SPCXB-T", "SPCXB-T", 18)),
                address(new MockMintableERC20("NVDAB-T", "NVDAB-T", 18)),
                address(new MockMintableERC20("AAPLB-T", "AAPLB-T", 18)),
                address(new MockMintableERC20("GMEon-T", "GMEon-T", 18))
            ];
        } else {
            revert("unsupported chain: run on 56 or 97, or set WBNB/USDT/UGM/ROUTER explicitly");
        }

        // The slippage oracle every vault from this factory consults (AUDIT v9 Finding 2).
        //
        // MAINNET: the real {StockpileSlippageOracle}, reading PancakeSwap V3's TWAP.
        //
        // TESTNET: a stand-in. The real oracle would be wired to pools that do not exist there — USDT and
        // the four stocks are mocks deployed seconds earlier, so `getPool` returns 0 and every quote
        // reverts. That is fail-closed by design, but it means EVERY leg would be skipped and a triggered
        // distribute would move nothing: the deployment would look healthy and quietly do nothing. The
        // stand-in returns a reachable floor (90% of the hop input, matching MockV3Router's 1:1 rate), so
        // the testnet flow exercises the same code path end-to-end. Override with ORACLE=0x… to point at
        // a real oracle if you have seeded real pools.
        address oracle = vm.envOr("ORACLE", address(0));
        if (oracle == address(0)) {
            oracle = block.chainid == 56
                ? address(new StockpileSlippageOracle(BscAddresses.PANCAKE_V3_FACTORY, wbnb, usdt, fee))
                : address(new MockSlippageOracle());
        }

        StockpileBasketVaultFactory factory =
            new StockpileBasketVaultFactory(wbnb, usdt, ugm, router, fee, oracle);

        vm.stopBroadcast();

        console2.log("== DeployVaultFactory ==");
        console2.log("chainId:           ", block.chainid);
        console2.log("deployer:          ", deployer);
        console2.log("factory:           ", address(factory));
        console2.log("  beacon:          ", factory.beacon());
        console2.log("  impl:            ", factory.beaconImplementation());
        console2.log("  basketDeployer:  ", factory.basketDeployer());
        console2.log("  slippageOracle:  ", factory.slippageOracle());
        console2.log("  oracle kind:     ", block.chainid == 56 ? "StockpileSlippageOracle (real TWAP)" : "MockSlippageOracle (testnet stand-in)");
        console2.log("-- constructor inputs --");
        console2.log("  wbnb:            ", wbnb);
        console2.log("  usdt:            ", usdt);
        console2.log("  ugm:             ", ugm);
        console2.log("  router:          ", router);
        console2.log("  wbnbUsdtFee:     ", uint256(fee));

        if (block.chainid == 97) {
            string[4] memory syms = ["SPCXB-T", "NVDAB-T", "AAPLB-T", "GMEon-T"];
            console2.log("-- testnet mock stocks (basket order) --");
            for (uint256 i = 0; i < 4; i++) {
                console2.log(string.concat("  STOCK", vm.toString(i), " (", syms[i], "):"), stocks[i]);
            }
            console2.log("");
            console2.log("NEXT (LaunchVaultTokenTestnet), export:");
            console2.log("  export FACTORY=", address(factory));
            for (uint256 i = 0; i < 4; i++) {
                console2.log(string.concat("  export STOCK", vm.toString(i), "="), stocks[i]);
            }
        } else {
            // Mainnet: the launch's VaultDataV1 basket uses these 4 real stocks (see StockConfig).
            address[4] memory real = StockConfig.mainnetStocks();
            string[4] memory syms = ["SPCXB", "NVDAB", "AAPLB", "GMEon"];
            console2.log("-- basket stocks for the launch (StockConfig, mainnet) --");
            for (uint256 i = 0; i < 4; i++) {
                console2.log(string.concat("  ", syms[i], ":"), real[i]);
            }
        }
    }
}
