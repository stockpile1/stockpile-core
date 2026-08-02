// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { BscAddresses } from "../src/config/BscAddresses.sol";
import { TakeoverToken } from "../src/token/TakeoverToken.sol";
import { UnifiedGridManager } from "../src/core/UnifiedGridManager.sol";
import { PancakeV3YieldAdapter } from "../src/adapters/PancakeV3YieldAdapter.sol";
import { FlapYieldAdapter } from "../src/adapters/FlapYieldAdapter.sol";
import { GenericBuybackKeeper } from "../src/keeper/GenericBuybackKeeper.sol";
import { AntiSnipeHook } from "../src/hooks/AntiSnipeHook.sol";

/// @notice Deploys the full Takeover BNB port to BSC mainnet (chainId 56).
/// @dev Usage:
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url bsc --broadcast --verify -vvvv
///
///   Env: PRIVATE_KEY (deployer), GUARDIAN_ADDRESS (final owner; defaults to deployer).
contract Deploy is Script {
    uint256 constant TAKEOVER_SUPPLY = 1_000_000_000 ether; // 1B TAKEOVER
    uint16 constant PROTOCOL_SEAT_SALE_BPS = 100; // 1% protocol cut of every seat sale
    uint16 constant CREATOR_SEAT_SALE_BPS = 200; // 2% creator cut of secondary seat sales
    uint16 constant PROTOCOL_TAX_BPS = 2000; // 20% protocol cut of settled Harberger tax

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address guardian = vm.envOr("GUARDIAN_ADDRESS", deployer);

        require(block.chainid == BscAddresses.CHAIN_ID, "not BSC mainnet");

        vm.startBroadcast(pk);

        // 1. Token
        TakeoverToken token = new TakeoverToken(guardian, TAKEOVER_SUPPLY);

        // 2. Core (deployer is temporary guardian so it can wire everything)
        UnifiedGridManager ugm =
            new UnifiedGridManager(deployer, PROTOCOL_SEAT_SALE_BPS, CREATOR_SEAT_SALE_BPS, PROTOCOL_TAX_BPS);

        // 3. Adapters
        PancakeV3YieldAdapter v3 = new PancakeV3YieldAdapter(
            address(ugm),
            BscAddresses.PANCAKE_V3_POSITION_MANAGER,
            BscAddresses.PANCAKE_V3_SWAP_ROUTER,
            guardian
        );
        FlapYieldAdapter flap = new FlapYieldAdapter(
            address(ugm), BscAddresses.FLAP_PORTAL, BscAddresses.FLAP_VAULT_PORTAL, guardian
        );

        // 4. Buyback keeper (swaps revenue -> TAKEOVER -> guardian)
        GenericBuybackKeeper keeper = new GenericBuybackKeeper(
            BscAddresses.PANCAKE_V3_SWAP_ROUTER, address(token), guardian, guardian
        );

        // 5. Example governance module
        AntiSnipeHook hook = new AntiSnipeHook(guardian);

        // 6. Wiring (deployer still owns the UGM)
        ugm.setApprovedAdapter(address(v3), true);
        ugm.setApprovedAdapter(address(flap), true);
        ugm.setApprovedModule(address(hook), true);

        // Route the protocol fee bucket to the buyback keeper and allow the canonical tax tokens.
        ugm.setProtocolFeeReceiver(address(keeper));
        ugm.setAllowedTaxToken(BscAddresses.STOCK, true);
        ugm.setAllowedTaxToken(BscAddresses.WBNB, true);
        ugm.setAllowedTaxToken(BscAddresses.USDT, true);

        // 7. Hand the UGM over to the real guardian
        if (guardian != deployer) {
            ugm.transferOwnership(guardian);
        }

        vm.stopBroadcast();

        console2.log("== Takeover BNB deployment (chainId 56) ==");
        console2.log("Guardian:            ", guardian);
        console2.log("TAKEOVER token:      ", address(token));
        console2.log("UnifiedGridManager:  ", address(ugm));
        console2.log("PancakeV3YieldAdapter", address(v3));
        console2.log("FlapYieldAdapter:    ", address(flap));
        console2.log("GenericBuybackKeeper:", address(keeper));
        console2.log("AntiSnipeHook:       ", address(hook));

        // Emit the address book the backend indexer reads: deployments/<chainId>.json
        string memory obj = "takeover";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "guardian", guardian);
        vm.serializeAddress(obj, "unifiedGridManager", address(ugm));
        vm.serializeAddress(obj, "takeoverToken", address(token));
        vm.serializeAddress(obj, "pancakeV3YieldAdapter", address(v3));
        vm.serializeAddress(obj, "flapYieldAdapter", address(flap));
        vm.serializeAddress(obj, "genericBuybackKeeper", address(keeper));
        string memory json = vm.serializeAddress(obj, "antiSnipeHook", address(hook));
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), ".json"));
    }
}
