// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {UnifiedGridManager} from "../../src/core/UnifiedGridManager.sol";
import {CreateGridParams} from "../../src/libraries/GridTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract BuySeatGasTest is Test {
    UnifiedGridManager internal ugm;
    MockERC20 internal token;
    address internal creator = makeAddr("creator");
    address internal buyer = makeAddr("buyer");
    uint256 internal gridId;

    function setUp() public {
        token = new MockERC20("Mock", "MOCK");
        ugm = new UnifiedGridManager(address(this), 100, 200, 0);
        ugm.setAllowedTaxToken(address(token), true);
        for (uint256 i; i < 2; i++) {
            address a = i == 0 ? creator : buyer;
            token.mint(a, 1_000_000 ether);
            vm.prank(a);
            token.approve(address(ugm), type(uint256).max);
        }
        vm.prank(creator);
        gridId = ugm.createGrid(CreateGridParams({
            totalSeats: 100, taxRateBps: 500, forfeitureDuration: 0,
            taxToken: address(token), yieldToken: address(token), initialPrice: 1 ether
        }));
    }

    /// @dev Sequential single buys — there is no batch entrypoint, so this is what 30-40 seats costs.
    function test_BuySeat_SequentialCost() public {
        uint256[4] memory ns = [uint256(1), 10, 30, 40];
        uint256 seat;
        for (uint256 k; k < ns.length; k++) {
            uint256 n = ns[k];
            uint256 g = gasleft();
            for (uint256 i; i < n; i++) {
                vm.prank(buyer);
                ugm.buySeat(gridId, seat++, 1 ether, 0.1 ether, 0);
            }
            uint256 used = g - gasleft();
            console2.log(
                string.concat("buySeat x", vm.toString(n)),
                string.concat(vm.toString(used), " gas total  (", vm.toString(used / n), "/seat)")
            );
        }
    }
}
