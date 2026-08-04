// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";

import {StockpileBasketVaultFactory} from "../src/StockpileBasketVaultFactory.sol";
import {MockMintableERC20} from "../test/mocks/MockMintableERC20.sol";
import {MockV3Router} from "../test/mocks/MockV3Router.sol";

/// @title DeployFlapFactoryTestnet — stand up the TRUE Flap vault-backed factory on BSC TESTNET (chainId 97)
///
/// @notice Deploys OUR {StockpileBasketVaultFactory} (the VaultPortal-gated, beacon-backed factory whose
///         `newVault` the Flap `VaultPortal.newTokenV6WithVault` calls) wired to:
///           • tWBNB   0xae13d989…a7cd (the live, already-allowlisted testnet WBNB / grid tax token),
///           • a fresh mock USDT (the real BSC-USD + its PancakeSwap V3 pools don't exist on testnet),
///           • the live testnet UGM 0xaA40Da…Cbd1 (grid sink; the deployer is its owner/guardian),
///           • a fresh {MockV3Router} (mints swap proceeds 1:1 — no real V3 liquidity on testnet), fee 100.
///         It also deploys 3 mintable mock "stock" tokens so a later {LaunchFlapVaultTestnet} can build a
///         valid VaultDataV1 basket over them.
///
///         The factory's constructor SELF-DEPLOYS its {StockBasketDeployer} + vault impl + UpgradeableBeacon
///         (5-arg ctor: wbnb, usdt, ugm, router, fee) — so the "basket deployer" is read back via
///         `factory.basketDeployer()` and logged, not passed in.
///
///         ── DRY-RUN (no broadcast — the user broadcasts) ──────────────────────────────────────────────
///           cd contracts/vault && set -a && . ./.env && set +a   # loads PRIVATE_KEY (never echo the key)
///           forge script script/DeployFlapFactoryTestnet.s.sol --tc DeployFlapFactoryTestnet \
///             --rpc-url https://data-seed-prebsc-1-s1.bnbchain.org:8545
///         Add --broadcast --legacy to actually send. After a REAL deploy, copy the logged factory + the 3
///         mock stock addresses into the env vars {LaunchFlapVaultTestnet} reads (FACTORY / STOCK0-2 / …).
contract DeployFlapFactoryTestnet is Script {
    // Live BSC-testnet infrastructure (verified).
    address internal constant UGM = 0xaA40Da4d2F81207196b16C29A9683ABA9d98Cbd1;
    address internal constant TWBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd; // WETH9-style wrapper
    uint24 internal constant WBNB_USDT_FEE = 100;

    function run() external {
        require(block.chainid == 97, "run on BSC testnet (chainId 97)");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // Mock swap infra + 3 mock stocks + a mock USDT (no real testnet stock pools exist).
        MockV3Router router = new MockV3Router();
        MockMintableERC20 usdt = new MockMintableERC20("USDT-T", "USDT-T", 18);
        address[3] memory stocks = [
            address(new MockMintableERC20("SPCXB-T", "SPCXB-T", 18)),
            address(new MockMintableERC20("QQQB-T", "QQQB-T", 18)),
            address(new MockMintableERC20("NVDAB-T", "NVDAB-T", 18))
        ];

        // Our factory (5-arg; self-deploys StockBasketDeployer + vault impl + beacon).
        StockpileBasketVaultFactory factory =
            new StockpileBasketVaultFactory(TWBNB, address(usdt), UGM, address(router), WBNB_USDT_FEE);

        vm.stopBroadcast();

        console2.log("== DeployFlapFactoryTestnet (chainId 97) ==");
        console2.log("deployer:            ", deployer);
        console2.log("factory:             ", address(factory));
        console2.log("  beacon:            ", factory.beacon());
        console2.log("  impl:              ", factory.beaconImplementation());
        console2.log("  basketDeployer:    ", factory.basketDeployer());
        console2.log("UGM (live sink):     ", UGM);
        console2.log("tWBNB (wbnb):        ", TWBNB);
        console2.log("mockUSDT:            ", address(usdt));
        console2.log("mockV3Router:        ", address(router));
        console2.log("wbnbUsdtFee:         ", uint256(WBNB_USDT_FEE));
        console2.log("-- mock stocks (order == intended basket order) --");
        console2.log("  STOCK0 (SPCXB-T):  ", stocks[0]);
        console2.log("  STOCK1 (QQQB-T):   ", stocks[1]);
        console2.log("  STOCK2 (NVDAB-T):  ", stocks[2]);
        console2.log("");
        console2.log("NEXT: export these for LaunchFlapVaultTestnet, e.g.:");
        console2.log("  export FACTORY=", address(factory));
        console2.log("  export STOCK0=", stocks[0]);
        console2.log("  export STOCK1=", stocks[1]);
        console2.log("  export STOCK2=", stocks[2]);
    }
}
