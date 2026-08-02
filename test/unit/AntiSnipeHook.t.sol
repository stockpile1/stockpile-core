// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { UnifiedGridManager } from "../../src/core/UnifiedGridManager.sol";
import { AntiSnipeHook } from "../../src/hooks/AntiSnipeHook.sol";
import { CreateGridParams, Seat } from "../../src/libraries/GridTypes.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @notice Unit test for the AntiSnipeHook governance module: claims are vetoed until
///         the per-grid `claimOpenAt` timestamp, then allowed.
contract AntiSnipeHookTest is Test {
    UnifiedGridManager internal ugm;
    AntiSnipeHook internal hook;
    MockERC20 internal token;

    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    uint256 internal gridId;

    function setUp() public {
        ugm = new UnifiedGridManager(address(this), 0, 0, 0); // guardian = this
        hook = new AntiSnipeHook(address(this)); // hook owner = this
        token = new MockERC20("Tax", "TAX");
        ugm.setAllowedTaxToken(address(token), true);

        token.mint(creator, 1000 ether);
        token.mint(alice, 1000 ether);
        vm.prank(creator);
        token.approve(address(ugm), type(uint256).max);
        vm.prank(alice);
        token.approve(address(ugm), type(uint256).max);

        vm.prank(creator);
        gridId = ugm.createGrid(
            CreateGridParams({
                totalSeats: 4,
                taxRateBps: 500,
                forfeitureDuration: 0,
                taxToken: address(token),
                yieldToken: address(token),
                initialPrice: 1 ether
            })
        );

        ugm.setApprovedModule(address(hook), true); // guardian approves module
        vm.prank(creator);
        ugm.setGridGovernanceModule(gridId, address(hook)); // creator wires it
    }

    function test_ClaimVetoedBeforeOpen() public {
        hook.setClaimOpenAt(gridId, uint64(block.timestamp + 1 hours));
        vm.prank(alice);
        vm.expectRevert(bytes("hook: claim vetoed"));
        ugm.buySeat(gridId, 0, 1 ether, 10 ether, 0);
    }

    function test_ClaimAllowedAfterOpen() public {
        uint64 openAt = uint64(block.timestamp + 1 hours);
        hook.setClaimOpenAt(gridId, openAt);
        vm.warp(openAt);

        vm.prank(alice);
        ugm.buySeat(gridId, 0, 1 ether, 10 ether, 0);
        assertEq(ugm.seatInfo(gridId, 0).holder, alice);
    }

    function test_NoOpenAtSet_ClaimAllowed() public {
        // claimOpenAt defaults to 0 → always open
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 1 ether, 10 ether, 0);
        assertEq(ugm.seatInfo(gridId, 0).holder, alice);
    }

    function test_SetClaimOpenAt_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        hook.setClaimOpenAt(gridId, 123);
    }
}
