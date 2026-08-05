// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {UnifiedGridManager} from "../../src/core/UnifiedGridManager.sol";
import {CreateGridParams} from "../../src/libraries/GridTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Measures what the UGM's two seat-batch entrypoints actually cost, to answer "can we sweep
///         30-40 seats in one transaction?" with a number rather than a guess.
/// @dev    Both loop over `seatIds` and do per-seat storage work, so cost is linear in the batch size.
///         Yield is pushed in first so `claimYieldBatch` does real work per seat (a seat with nothing
///         accrued short-circuits and would understate the cost).
contract BatchSweepGasTest is Test {
    UnifiedGridManager internal ugm;
    MockERC20 internal token;

    address internal creator = makeAddr("creator");
    address internal adapter = makeAddr("adapter");
    uint32 internal constant SEATS = 100; // matches the production grid size
    uint256 internal gridId;
    bytes32 internal constant ASSET = keccak256("asset");

    function setUp() public {
        token = new MockERC20("Mock", "MOCK");
        ugm = new UnifiedGridManager(address(this), 100, 0, 0);
        ugm.setAllowedTaxToken(address(token), true);

        token.mint(creator, 1_000_000 ether);
        vm.prank(creator);
        token.approve(address(ugm), type(uint256).max);

        vm.prank(creator);
        gridId = ugm.createGrid(
            CreateGridParams({
                totalSeats: SEATS,
                taxRateBps: 500,
                forfeitureDuration: 0,
                taxToken: address(token),
                yieldToken: address(token),
                initialPrice: 1 ether
            })
        );

        // Wire an adapter and push yield so every seat has something to settle.
        ugm.setApprovedAdapter(adapter, true);
        vm.prank(adapter);
        ugm.registerAsset(gridId, ASSET);

        token.mint(adapter, 1_000 ether);
        vm.startPrank(adapter);
        token.approve(address(ugm), type(uint256).max);
        ugm.receiveYieldERC20(ASSET, address(token), 100 ether);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days); // accrue tax so pokeTaxBatch does real work too
    }

    function _ids(uint256 from, uint256 n) internal pure returns (uint256[] memory a) {
        a = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            a[i] = from + i;
        }
    }

    /// @dev Each size runs from a FRESH state (forge re-runs setUp per test function) over seats that
    ///      have never been settled. Reusing already-settled seats hits a short-circuit and would report a
    ///      cost an order of magnitude too low.
    function _measureClaim(uint256 n) internal {
        uint256[] memory ids = _ids(0, n);
        uint256 g = gasleft();
        ugm.claimYieldBatch(gridId, ids);
        uint256 used = g - gasleft();
        console2.log(
            string.concat("claimYieldBatch seats=", vm.toString(n)),
            string.concat(vm.toString(used), " gas  (", vm.toString(used / n), "/seat)")
        );
    }

    function _measurePoke(uint256 n) internal {
        uint256[] memory ids = _ids(0, n);
        uint256 g = gasleft();
        ugm.pokeTaxBatch(gridId, ids);
        uint256 used = g - gasleft();
        console2.log(
            string.concat("pokeTaxBatch   seats=", vm.toString(n)),
            string.concat(vm.toString(used), " gas  (", vm.toString(used / n), "/seat)")
        );
    }

    function test_Claim_01() public { _measureClaim(1); }
    function test_Claim_10() public { _measureClaim(10); }
    function test_Claim_30() public { _measureClaim(30); }
    function test_Claim_40() public { _measureClaim(40); }
    function test_Claim_50() public { _measureClaim(50); }
    function test_Claim_100() public { _measureClaim(100); }

    function test_Poke_30() public { _measurePoke(30); }
    function test_Poke_40() public { _measurePoke(40); }
    function test_Poke_100() public { _measurePoke(100); }
}
