// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {StockpileVaultFactory} from "../src/StockpileVaultFactory.sol";
import {UpgradeableBeacon} from "@openzeppelin/proxy/beacon/UpgradeableBeacon.sol";

/// @title Deploy the Cách B stock-settled Stockpile factory on BSC mainnet (chainId 56).
/// @notice Deploying the factory creates all THREE artifacts the audit/mainnet re-deploy needs:
///           1. StockpileVaultFactory   — the deployed contract itself.
///           2. StockpileVault (impl)    — `new StockpileVault()` in the factory constructor.
///           3. UpgradeableBeacon        — `new UpgradeableBeacon(impl)` in the constructor (factory-owned).
///
///         This script only DEPLOYS + LOGS; it does not create any vault or touch the UGM. Set the four
///         params via env before broadcasting, then:
///           forge script script/DeployFactoryMainnet.s.sol --tc DeployFactoryMainnet \
///             --rpc-url $BSC_MAINNET --broadcast --legacy --verify
///
///         The settlement "stock" token and the commission treasury are chosen PER VAULT (at newVault),
///         so the factory deploy itself only needs the UGM + a default commission cap.
///
///         REQUIRED env (confirm before broadcasting — real value at stake):
///           PRIVATE_KEY        deployer key
///           UGM_ADDRESS        the audited Stockpile UnifiedGridManager on mainnet (0xB7156E69…)
///         OPTIONAL:
///           DEFAULT_COMMISSION_BPS  default commission cap in bps (default 1000 = 10%)
contract DeployFactoryMainnet is Script {
    function run() external {
        require(block.chainid == 56, "run on BSC mainnet (chainId 56)");

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address ugm = vm.envAddress("UGM_ADDRESS");
        uint16 commissionBps = uint16(vm.envOr("DEFAULT_COMMISSION_BPS", uint256(1000)));
        require(ugm.code.length > 0, "UGM_ADDRESS not a contract");

        vm.startBroadcast(pk);
        StockpileVaultFactory factory = new StockpileVaultFactory(ugm, commissionBps);
        vm.stopBroadcast();

        address beacon = factory.beacon();
        address impl = UpgradeableBeacon(beacon).implementation();

        console2.log("== Cach B mainnet deploy (chainId 56) ==");
        console2.log("1) StockpileVaultFactory:", address(factory));
        console2.log("2) StockpileVault (impl): ", impl);
        console2.log("3) UpgradeableBeacon:     ", beacon);
        console2.log("   ugm:                   ", ugm);
        console2.log("   defaultCommissionBps:  ", commissionBps);
        console2.log("   factorySpecVersion:    ", factory.factorySpecVersion());
        console2.log("Per vault: creators call newVault(settlementToken, treasury(=0 -> caller), 0, vaultData).");
        console2.log("NEXT: guardian setAllowedTaxToken(<stock>,true) on the UGM for each stock before its newVault.");
    }
}
