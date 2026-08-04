// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";

interface IUGM {
    function buySeat(uint256 gridId, uint256 seatId, uint128 newPrice, uint256 depositAmount, uint128 maxPrice) external;
    function seatInfo(uint256, uint256)
        external
        view
        returns (address holder, bool everSold, uint128 price, uint128 deposit, uint64, uint64, uint64, uint64);
    function totalSeats(uint256) external view returns (uint256);
}

interface IWBNB {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Fork-proof that the Harberger seat takeover works on the live testnet grid 2
///         (created by the STKP vault launch). Wraps tBNB->tWBNB, buys seat 0 from the creator,
///         sets a self-assessed price + posts a tax deposit.
contract TestnetBuySeatForkTest is Test {
    address internal constant UGM = 0xaA40Da4d2F81207196b16C29A9683ABA9d98Cbd1;
    address internal constant WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
    uint256 internal constant GRID = 2;
    uint256 internal constant SEAT = 0;
    uint128 internal constant NEW_PRICE = 1e15; // 0.001 tWBNB self-assessed
    uint256 internal constant DEPOSIT = 1e15; // 0.001 tWBNB tax deposit

    string internal constant TEST_RPC = "https://data-seed-prebsc-1-s1.bnbchain.org:8545";

    function setUp() public {
        vm.createSelectFork(TEST_RPC);
        assertEq(block.chainid, 97, "testnet fork");
    }

    function test_BuySeatFromCreator() public {
        address buyer = makeAddr("seatBuyer");
        vm.deal(buyer, 1 ether);

        (address h0,,,,,,,) = IUGM(UGM).seatInfo(GRID, SEAT);
        console2.log("seat 0 holder BEFORE (creator):", h0);

        vm.startPrank(buyer);
        IWBNB(WBNB).deposit{value: 0.003 ether}(); // wrap tBNB -> tWBNB
        IWBNB(WBNB).approve(UGM, type(uint256).max);
        IUGM(UGM).buySeat(GRID, SEAT, NEW_PRICE, DEPOSIT, 0); // maxPrice 0 = no slippage bound
        vm.stopPrank();

        (address h, bool everSold, uint128 price, uint128 deposit,,,,) = IUGM(UGM).seatInfo(GRID, SEAT);
        console2.log("seat 0 holder AFTER (buyer):", h);
        console2.log("self-assessed price:", price);
        console2.log("tax deposit posted:", deposit);
        assertEq(h, buyer, "seat now held by buyer");
        assertTrue(everSold, "seat left the creator listing");
        assertEq(price, NEW_PRICE, "buyer's self-assessed price recorded");
        assertGt(deposit, 0, "tax deposit posted");
    }
}
