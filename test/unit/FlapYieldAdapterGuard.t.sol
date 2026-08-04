// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";

import { UnifiedGridManager } from "../../src/core/UnifiedGridManager.sol";
import { FlapYieldAdapter } from "../../src/adapters/FlapYieldAdapter.sol";
import { CreateGridParams } from "../../src/libraries/GridTypes.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @notice Unit tests (no fork) for the FlapYieldAdapter yield-token-uniqueness guard that resolves
///         the "collectYield whole-balance sweep comingles across grids" finding. Because
///         `collectYield` sweeps the adapter's WHOLE yield-token balance, two assets sharing one
///         yield token would let one grid's sweep steal the other's balance; `registerFlapToken` now
///         rejects a second asset that reuses an already-registered yield token, so every sweep is
///         fully attributable to a single grid. Also proves the chain-fixed Flap Guardian is a
///         permanent backup caller for registration (SYS-REQ-GUARDIAN-ACCESS).
contract FlapYieldAdapterGuardTest is Test {
    UnifiedGridManager internal ugm;
    FlapYieldAdapter internal adapter;
    MockERC20 internal tax;

    address internal owner = address(this);
    address internal flapA = makeAddr("flapA");
    address internal flapB = makeAddr("flapB");
    address internal flapC = makeAddr("flapC");
    address internal yieldY = makeAddr("yieldY");
    address internal yieldZ = makeAddr("yieldZ");

    uint256 internal gridId;

    function setUp() public {
        ugm = new UnifiedGridManager(owner, 0, 0, 0); // guardian = this
        adapter = new FlapYieldAdapter(address(ugm), address(0), address(0), owner);

        tax = new MockERC20("Tax", "TAX");
        ugm.setAllowedTaxToken(address(tax), true);
        tax.mint(owner, 1_000 ether);
        tax.approve(address(ugm), type(uint256).max);

        gridId = ugm.createGrid(
            CreateGridParams({
                totalSeats: 4,
                taxRateBps: 500,
                forfeitureDuration: 0,
                taxToken: address(tax),
                yieldToken: address(tax),
                initialPrice: 1 ether
            })
        );

        ugm.setApprovedAdapter(address(adapter), true);
    }

    /// @dev A second Flap token that reuses an already-registered yield token is rejected, so the
    ///      whole-balance sweep can never comingle two grids' yield.
    function test_RejectsDuplicateYieldToken() public {
        adapter.registerFlapToken(gridId, flapA, yieldY);
        assertTrue(adapter.yieldTokenInUse(yieldY), "Y is now in use");

        vm.expectRevert(bytes("yieldToken in use"));
        adapter.registerFlapToken(gridId, flapB, yieldY);
    }

    /// @dev Distinct yield tokens are still allowed on one adapter — the guard only blocks reuse.
    function test_DistinctYieldTokensAllowed() public {
        adapter.registerFlapToken(gridId, flapA, yieldY);
        adapter.registerFlapToken(gridId, flapB, yieldZ); // different yield token → OK
        assertTrue(adapter.yieldTokenInUse(yieldZ), "Z registered");
    }

    /// @dev Withdrawing a stream frees its yield token for a later re-registration.
    function test_WithdrawFreesYieldToken() public {
        bytes32 assetHash = adapter.registerFlapToken(gridId, flapA, yieldY);
        adapter.withdrawFlapToken(assetHash);
        assertFalse(adapter.yieldTokenInUse(yieldY), "Y freed on withdraw");

        // Y can be reused by a different Flap token now.
        adapter.registerFlapToken(gridId, flapC, yieldY);
        assertTrue(adapter.yieldTokenInUse(yieldY), "Y re-registered");
    }

    /// @dev SYS-REQ-GUARDIAN-ACCESS: the chain-fixed Flap Guardian is a permanent backup for
    ///      register/withdraw even though it is not the adapter owner.
    function test_GuardianIsBackupForRegisterAndWithdraw() public {
        address g = adapter.guardian();
        assertEq(g, 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b, "guardian == chain-fixed Flap Guardian");

        vm.prank(g);
        bytes32 assetHash = adapter.registerFlapToken(gridId, flapA, yieldY);
        assertTrue(adapter.isAssetRegistered(assetHash), "guardian registered the stream");

        vm.prank(g);
        adapter.withdrawFlapToken(assetHash);
        assertFalse(adapter.isAssetRegistered(assetHash), "guardian withdrew the stream");
    }

    /// @dev A caller that is neither owner nor Guardian cannot register.
    function test_RegisterRejectsStranger() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(bytes("not owner/guardian"));
        adapter.registerFlapToken(gridId, flapA, yieldY);
    }
}
