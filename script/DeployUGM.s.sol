// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {UnifiedGridManager} from "../src/core/UnifiedGridManager.sol";

/// @title DeployUGM — deploy a standalone UnifiedGridManager and allowlist its tax token
///
/// @notice `Deploy.s.sol` is the full mainnet bring-up: it is chain-gated to 56 and also deploys the
///         TAKEOVER token, both yield adapters, the buyback keeper and a governance hook. When all you
///         need is a grid engine for the vault stack — which is the case on testnet, and whenever an
///         existing UGM has drifted from source — that is far more than required.
///
/// @dev    Env: PRIVATE_KEY (deployer, becomes the UGM owner). Optional: TAX_TOKEN (defaults to WBNB /
///         tWBNB for the chain), PROTOCOL_SEAT_SALE_BPS, CREATOR_SEAT_SALE_BPS, PROTOCOL_TAX_BPS.
///
///           forge script script/DeployUGM.s.sol --rpc-url $RPC --broadcast --legacy
///
///         The deployer keeps ownership on purpose: every new vault needs
///         `setApprovedAdapter(vault, true)` before `registerWithGrid()` will bind it, and the tax token
///         must stay allowlisted or `setupMarket()`'s `createGrid` reverts `"taxToken"`.
contract DeployUGM is Script {
    address internal constant WBNB_56 = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant TWBNB_97 = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;

    // Same split as the mainnet bring-up in Deploy.s.sol, so a testnet UGM behaves like production.
    uint16 internal constant PROTOCOL_SEAT_SALE_BPS = 100; // 1% of every seat sale
    uint16 internal constant CREATOR_SEAT_SALE_BPS = 200; // 2% of secondary seat sales
    uint16 internal constant PROTOCOL_TAX_BPS = 2000; // 20% of settled Harberger tax

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address taxToken = vm.envOr("TAX_TOKEN", block.chainid == 56 ? WBNB_56 : TWBNB_97);
        require(taxToken.code.length > 0, "tax token is not a contract on this chain");

        uint16 protSeat = uint16(vm.envOr("PROTOCOL_SEAT_SALE_BPS", uint256(PROTOCOL_SEAT_SALE_BPS)));
        uint16 creatorSeat = uint16(vm.envOr("CREATOR_SEAT_SALE_BPS", uint256(CREATOR_SEAT_SALE_BPS)));
        uint16 protTax = uint16(vm.envOr("PROTOCOL_TAX_BPS", uint256(PROTOCOL_TAX_BPS)));

        vm.startBroadcast(pk);

        UnifiedGridManager ugm = new UnifiedGridManager(deployer, protSeat, creatorSeat, protTax);
        // Without this, every vault's setupMarket() reverts "taxToken" when it calls createGrid.
        ugm.setAllowedTaxToken(taxToken, true);

        vm.stopBroadcast();

        console2.log("== DeployUGM ==");
        console2.log("chainId:                ", block.chainid);
        console2.log("deployer / UGM owner:   ", deployer);
        console2.log("UGM:                    ", address(ugm));
        console2.log("  version:              ", ugm.ugmVersion());
        console2.log("  taxToken allowlisted: ", taxToken);
        console2.log("  protocolSeatSaleBps:  ", protSeat);
        console2.log("  creatorSeatSaleBps:   ", creatorSeat);
        console2.log("  protocolTaxBps:       ", protTax);
        console2.log("");
        console2.log("NEXT: deploy the factory against it, then approve each vault as an adapter:");
        console2.log("  UGM=", address(ugm));
        console2.log("  forge script script/DeployVaultFactory.s.sol --rpc-url $RPC --broadcast --legacy");
    }
}
