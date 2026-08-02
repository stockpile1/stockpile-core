// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { UnifiedGridManager } from "../../src/core/UnifiedGridManager.sol";
import { GridConfig, Seat, CreateGridParams } from "../../src/libraries/GridTypes.sol";
import { IGridHooksV23 } from "../../src/interfaces/IGridHooksV23.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @notice Governance module that vetoes every claim (`beforeClaim` returns false) and allows
///         everything else. Used to prove a wired module stops firing once un-approved (F-11).
contract ClaimVetoHook is IGridHooksV23 {
    function beforeClaim(uint256, uint256, address, uint256) external pure override returns (bool) {
        return false; // veto all claims while active
    }

    function beforeBuyout(uint256, uint256, address, address, uint256) external pure override returns (bool) {
        return true;
    }

    function beforePriceChange(uint256, uint256, address, uint256, uint256)
        external
        pure
        override
        returns (bool)
    {
        return true;
    }

    function onSeatHolderChange(uint256, uint256, address, address) external override { }
    function onForfeit(uint256, uint256, address) external override { }
}

/// @title UnifiedGridManager access-control & pausing unit tests (NON-fork)
/// @notice Verifies the OpenZeppelin v5 `Ownable` guard on every admin function (adapter/module
///         approval, fee-split knobs, tax-token allowlist, protocol fee receiver, pause,
///         deprecation, revenue sweep), the bespoke auth on `setGridGovernanceModule`/
///         `registerAsset`, and the pause flags gating `buySeat`/`setPrice`/`createGrid`.
/// @dev The UGM is deployed with the guardian (Ownable owner) set to a DEDICATED `guardian`
///      address — NOT this test contract — so unauthorized-vs-authorized is a real distinction.
contract AccessControlTest is Test {
    UnifiedGridManager internal ugm;
    MockERC20 internal token; // single token: tax == yield

    uint16 internal constant PROT_SEAT_BPS = 100; // 1% protocol seat-sale cut
    uint16 internal constant TAX_BPS = 500;
    uint128 internal constant INIT_PRICE = 1 ether;
    uint32 internal constant SEATS = 4;

    address internal guardian = makeAddr("guardian");
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");
    address internal adapter = makeAddr("adapter");
    address internal module = makeAddr("module");
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        token = new MockERC20("Mock", "MOCK");
        ugm = new UnifiedGridManager(guardian, PROT_SEAT_BPS, 0, 0);
        vm.prank(guardian);
        ugm.setAllowedTaxToken(address(token), true);

        address[3] memory actors = [creator, alice, bob];
        for (uint256 i = 0; i < actors.length; ++i) {
            token.mint(actors[i], 1000 ether);
            vm.prank(actors[i]);
            token.approve(address(ugm), type(uint256).max);
        }
    }

    // ------------------------------------------------------------------ //
    //                              Helpers                               //
    // ------------------------------------------------------------------ //
    function _params(uint32 seats, uint16 taxBps, address tax, address yield, uint128 initPrice)
        internal
        pure
        returns (CreateGridParams memory)
    {
        return CreateGridParams({
            totalSeats: seats,
            taxRateBps: taxBps,
            forfeitureDuration: 0,
            taxToken: tax,
            yieldToken: yield,
            initialPrice: initPrice
        });
    }

    function _createDefaultGrid() internal returns (uint256 gridId) {
        vm.prank(creator);
        gridId = ugm.createGrid(_params(SEATS, TAX_BPS, address(token), address(token), INIT_PRICE));
    }

    function _expectUnauthorized(address caller) internal {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
    }

    // ================================================================== //
    //          1. onlyOwner admin functions: revert vs succeed          //
    // ================================================================== //

    function test_SetApprovedAdapter_OnlyOwner() public {
        vm.prank(attacker);
        _expectUnauthorized(attacker);
        ugm.setApprovedAdapter(adapter, true);

        vm.prank(guardian);
        ugm.setApprovedAdapter(adapter, true);
        assertTrue(ugm.approvedAdapters(adapter), "guardian approved the adapter");
    }

    function test_SetApprovedModule_OnlyOwner() public {
        vm.prank(attacker);
        _expectUnauthorized(attacker);
        ugm.setApprovedModule(module, true);

        vm.prank(guardian);
        ugm.setApprovedModule(module, true);
        assertTrue(ugm.approvedModules(module), "guardian approved the module");
    }

    function test_SetModuleDisabled_OnlyOwner() public {
        vm.prank(attacker);
        _expectUnauthorized(attacker);
        ugm.setModuleDisabled(module, true);

        vm.prank(guardian);
        ugm.setModuleDisabled(module, true);
        assertTrue(ugm.moduleDisabled(module), "guardian disabled the module");
    }

    /// @notice onlyOwner guard PLUS the MAX_PROTOCOL_BPS cap on the protocol seat-sale knob.
    function test_SetProtocolSeatSaleBps_OnlyOwnerAndMaxCap() public {
        vm.prank(attacker);
        _expectUnauthorized(attacker);
        ugm.setProtocolSeatSaleBps(200);

        uint16 tooHigh = uint16(ugm.MAX_PROTOCOL_BPS() + 1); // 5001
        vm.prank(guardian);
        vm.expectRevert(bytes("bps"));
        ugm.setProtocolSeatSaleBps(tooHigh);

        uint16 atCap = uint16(ugm.MAX_PROTOCOL_BPS()); // 5000
        vm.prank(guardian);
        ugm.setProtocolSeatSaleBps(atCap);
        assertEq(ugm.protocolSeatSaleBps(), atCap, "guardian updated the fee up to the cap");
    }

    function test_SetCreatorSeatSaleBps_OnlyOwner() public {
        vm.prank(attacker);
        _expectUnauthorized(attacker);
        ugm.setCreatorSeatSaleBps(200);

        vm.prank(guardian);
        ugm.setCreatorSeatSaleBps(300);
        assertEq(ugm.creatorSeatSaleBps(), 300, "guardian set the creator seat-sale cut");
    }

    function test_SetProtocolTaxBps_OnlyOwner() public {
        vm.prank(attacker);
        _expectUnauthorized(attacker);
        ugm.setProtocolTaxBps(2000);

        vm.prank(guardian);
        ugm.setProtocolTaxBps(2000);
        assertEq(ugm.protocolTaxBps(), 2000, "guardian set the protocol tax cut");
    }

    function test_SetAllowedTaxToken_OnlyOwner() public {
        vm.prank(attacker);
        _expectUnauthorized(attacker);
        ugm.setAllowedTaxToken(address(0xBEEF), true);

        vm.prank(guardian);
        ugm.setAllowedTaxToken(address(0xBEEF), true);
        assertTrue(ugm.allowedTaxTokens(address(0xBEEF)), "guardian allowed the tax token");
    }

    function test_SetProtocolFeeReceiver_OnlyOwner() public {
        vm.prank(attacker);
        _expectUnauthorized(attacker);
        ugm.setProtocolFeeReceiver(treasury);

        vm.prank(guardian);
        ugm.setProtocolFeeReceiver(treasury);
        assertEq(ugm.protocolFeeReceiver(), treasury, "guardian set the fee receiver");
    }

    function test_DeprecateGrid_OnlyOwner() public {
        uint256 gridId = _createDefaultGrid();

        vm.prank(attacker);
        _expectUnauthorized(attacker);
        ugm.deprecateGrid(gridId);

        vm.prank(guardian);
        ugm.deprecateGrid(gridId);
        assertTrue(ugm.gridDeprecated(gridId), "guardian deprecated the grid");
    }

    function test_PauseGrid_OnlyOwner() public {
        uint256 gridId = _createDefaultGrid();

        vm.prank(attacker);
        _expectUnauthorized(attacker);
        ugm.pauseGrid(gridId);

        vm.prank(guardian);
        ugm.pauseGrid(gridId);
        assertTrue(ugm.gridPaused(gridId), "guardian paused the grid");
    }

    function test_UnpauseGrid_OnlyOwner() public {
        uint256 gridId = _createDefaultGrid();
        vm.prank(guardian);
        ugm.pauseGrid(gridId);

        vm.prank(attacker);
        _expectUnauthorized(attacker);
        ugm.unpauseGrid(gridId);

        vm.prank(guardian);
        ugm.unpauseGrid(gridId);
        assertFalse(ugm.gridPaused(gridId), "guardian unpaused the grid");
    }

    function test_PauseGridCreation_OnlyOwner() public {
        vm.prank(attacker);
        _expectUnauthorized(attacker);
        ugm.pauseGridCreation();

        vm.prank(guardian);
        ugm.pauseGridCreation();
        assertTrue(ugm.gridCreationPaused(), "guardian paused grid creation");
    }

    function test_UnpauseGridCreation_OnlyOwner() public {
        vm.prank(guardian);
        ugm.pauseGridCreation();

        vm.prank(attacker);
        _expectUnauthorized(attacker);
        ugm.unpauseGridCreation();

        vm.prank(guardian);
        ugm.unpauseGridCreation();
        assertFalse(ugm.gridCreationPaused(), "guardian unpaused grid creation");
    }

    function test_WithdrawTaxRevenue_OnlyOwner() public {
        uint256 gridId = _createDefaultGrid();

        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 1 ether, 0);
        uint256 fee = (uint256(INIT_PRICE) * uint256(PROT_SEAT_BPS)) / ugm.BPS(); // 0.01
        assertEq(ugm.gridTaxRevenue(gridId), fee, "seat-sale fee accrued to protocol bucket");

        vm.prank(guardian);
        ugm.setProtocolFeeReceiver(treasury);

        // Unauthorized caller is rejected by onlyOwner.
        vm.prank(attacker);
        _expectUnauthorized(attacker);
        ugm.withdrawTaxRevenue(gridId);

        vm.prank(guardian);
        uint256 amount = ugm.withdrawTaxRevenue(gridId);
        assertEq(amount, fee, "returned swept amount");
        assertEq(token.balanceOf(treasury), fee, "fee receiver received the revenue");
        assertEq(ugm.gridTaxRevenue(gridId), 0, "grid revenue accounting zeroed");
    }

    // ================================================================== //
    //             2. Pausing gates buySeat / setPrice / create           //
    // ================================================================== //

    function test_PauseGrid_BlocksBuySeatThenUnpauseWorks() public {
        uint256 gridId = _createDefaultGrid();

        vm.prank(guardian);
        ugm.pauseGrid(gridId);

        vm.prank(alice);
        vm.expectRevert(bytes("paused"));
        ugm.buySeat(gridId, 0, 2 ether, 1 ether, 0);

        vm.prank(guardian);
        ugm.unpauseGrid(gridId);

        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 1 ether, 0);
        assertEq(ugm.seatInfo(gridId, 0).holder, alice, "alice holds seat 0 after unpause");
    }

    function test_PauseGrid_BlocksSetPriceThenUnpauseWorks() public {
        uint256 gridId = _createDefaultGrid();

        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 5 ether, 0);

        vm.prank(guardian);
        ugm.pauseGrid(gridId);

        vm.prank(alice);
        vm.expectRevert(bytes("paused"));
        ugm.setPrice(gridId, 0, 7 ether);

        vm.prank(guardian);
        ugm.unpauseGrid(gridId);

        // Clear the re-pricing cooldown before the (now-allowed) reprice.
        vm.warp(block.timestamp + 21 minutes);
        vm.prank(alice);
        ugm.setPrice(gridId, 0, 7 ether);
        assertEq(ugm.seatInfo(gridId, 0).price, 7 ether, "price updated after unpause");
    }

    function test_PauseGridCreation_BlocksCreateGridThenUnpauseWorks() public {
        vm.prank(guardian);
        ugm.pauseGridCreation();

        vm.prank(creator);
        vm.expectRevert(bytes("creation paused"));
        ugm.createGrid(_params(SEATS, TAX_BPS, address(token), address(token), INIT_PRICE));

        vm.prank(guardian);
        ugm.unpauseGridCreation();

        vm.prank(creator);
        uint256 gridId = ugm.createGrid(_params(SEATS, TAX_BPS, address(token), address(token), INIT_PRICE));
        assertEq(gridId, 1, "grid created after unpause");
        assertEq(ugm.gridCount(), 1, "grid count incremented");
    }

    // ================================================================== //
    //                       3. registerAsset guard                       //
    // ================================================================== //

    function test_RegisterAsset_RevertNonApprovedAdapter() public {
        uint256 gridId = _createDefaultGrid();
        bytes32 assetHash = keccak256("asset-1");

        vm.prank(alice);
        vm.expectRevert(bytes("adapter"));
        ugm.registerAsset(gridId, assetHash);
    }

    function test_RegisterAsset_ApprovedSucceedsThenDuplicateReverts() public {
        uint256 gridId = _createDefaultGrid();
        bytes32 assetHash = keccak256("asset-1");

        vm.prank(guardian);
        ugm.setApprovedAdapter(adapter, true);

        vm.prank(adapter);
        ugm.registerAsset(gridId, assetHash);
        assertEq(ugm.assetToGrid(assetHash), gridId, "asset wired to the grid");
        assertEq(ugm.assetAdapter(assetHash), adapter, "adapter recorded for the asset");

        vm.prank(adapter);
        vm.expectRevert(bytes("registered"));
        ugm.registerAsset(gridId, assetHash);
    }

    // ================================================================== //
    //                   4. setGridGovernanceModule guard                 //
    // ================================================================== //

    function test_SetGridGovernanceModule_RevertUnauthorized() public {
        uint256 gridId = _createDefaultGrid();

        vm.prank(guardian);
        ugm.setApprovedModule(module, true);

        vm.prank(bob);
        vm.expectRevert(bytes("auth"));
        ugm.setGridGovernanceModule(gridId, module);
    }

    function test_SetGridGovernanceModule_RevertModuleNotApproved() public {
        uint256 gridId = _createDefaultGrid();

        vm.prank(creator);
        vm.expectRevert(bytes("module"));
        ugm.setGridGovernanceModule(gridId, module);
    }

    function test_SetGridGovernanceModule_CreatorSetsAndClears() public {
        uint256 gridId = _createDefaultGrid();

        vm.prank(guardian);
        ugm.setApprovedModule(module, true);

        vm.prank(creator);
        ugm.setGridGovernanceModule(gridId, module);
        assertEq(ugm.gridGovernanceModule(gridId), module, "module wired by creator");

        vm.prank(creator);
        ugm.setGridGovernanceModule(gridId, address(0));
        assertEq(ugm.gridGovernanceModule(gridId), address(0), "module cleared to address(0)");
    }

    function test_SetGridGovernanceModule_OwnerCanSet() public {
        uint256 gridId = _createDefaultGrid();

        vm.prank(guardian);
        ugm.setApprovedModule(module, true);

        vm.prank(guardian);
        ugm.setGridGovernanceModule(gridId, module);
        assertEq(ugm.gridGovernanceModule(gridId), module, "module wired by owner");
    }

    // ================================================================== //
    //          5. Module revocation via un-approval (F-11 fix)           //
    // ================================================================== //

    /// @notice F-11: un-approving a module immediately deactivates it on ALREADY-wired grids.
    function test_UnapprovingModuleDeactivatesOnWiredGrids() public {
        uint256 gridId = _createDefaultGrid();
        ClaimVetoHook hook = new ClaimVetoHook();

        vm.prank(guardian);
        ugm.setApprovedModule(address(hook), true);
        vm.prank(creator);
        ugm.setGridGovernanceModule(gridId, address(hook));

        vm.prank(alice);
        vm.expectRevert(bytes("hook: claim vetoed"));
        ugm.buySeat(gridId, 0, 2 ether, 1 ether, 0);

        vm.prank(guardian);
        ugm.setApprovedModule(address(hook), false);

        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 1 ether, 0);
        assertEq(ugm.seatInfo(gridId, 0).holder, alice, "claim succeeds after module un-approval");
        assertEq(ugm.gridGovernanceModule(gridId), address(hook), "wiring unchanged, module just inactive");
    }
}
