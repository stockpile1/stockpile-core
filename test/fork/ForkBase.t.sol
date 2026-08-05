// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { BscAddresses } from "../../src/config/BscAddresses.sol";
import { IWBNB } from "../../src/interfaces/external/IWBNB.sol";

/// @notice Base for BSC-mainnet fork tests. Selects a fork of chain 56 and provides
///         helpers to obtain real WBNB deterministically.
abstract contract ForkBase is Test {
    IWBNB internal constant WBNB = IWBNB(BscAddresses.WBNB);

    function _forkBsc() internal {
        string memory rpc = vm.envOr("BSC_RPC_URL", string("https://bsc-dataseed.bnbchain.org"));
        vm.createSelectFork(rpc);
        assertEq(block.chainid, BscAddresses.CHAIN_ID, "fork is not BSC mainnet");
    }

    /// @notice Give `to` `amount` of real WBNB by wrapping native BNB.
    function _mintWBNB(address to, uint256 amount) internal {
        vm.deal(to, amount);
        vm.prank(to);
        WBNB.deposit{ value: amount }();
    }
}
