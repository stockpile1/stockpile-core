// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IGridHooksV23
/// @notice Optional external logic that can gate/observe seat economics.
/// @dev Reconstructed from Takeover UGM v2.3's `IGridHooksV23`. Every callback
///      is invoked by the UGM within GOVERNANCE_HOOK_GAS_CAP (150,000 gas).
///      `before*` callbacks return `false` (or revert) to veto the action.
interface IGridHooksV23 {
    /// @notice Gate an initial seat claim / acquisition.
    /// @param gridId The grid the seat belongs to.
    /// @param seatId The seat being claimed.
    /// @param buyer The address attempting to claim the seat.
    /// @param newPrice The self-assessed price the buyer intends to set.
    /// @return allow True to permit the claim, false to veto it.
    function beforeClaim(uint256 gridId, uint256 seatId, address buyer, uint256 newPrice)
        external
        returns (bool allow);

    /// @notice Gate a seat buyout (transfer via paying the declared price).
    /// @param gridId The grid the seat belongs to.
    /// @param seatId The seat being bought out.
    /// @param from The current holder being displaced.
    /// @param to The address attempting the buyout.
    /// @param price The declared price being paid.
    /// @return allow True to permit the buyout, false to veto it.
    function beforeBuyout(uint256 gridId, uint256 seatId, address from, address to, uint256 price)
        external
        returns (bool allow);

    /// @notice Gate a self-assessed price change.
    /// @param gridId The grid the seat belongs to.
    /// @param seatId The seat whose price is changing.
    /// @param holder The current holder requesting the change.
    /// @param oldPrice The seat's price before the change.
    /// @param newPrice The seat's proposed new price.
    /// @return allow True to permit the price change, false to veto it.
    function beforePriceChange(
        uint256 gridId,
        uint256 seatId,
        address holder,
        uint256 oldPrice,
        uint256 newPrice
    ) external returns (bool allow);

    /// @notice Observe a seat holder change (post-state-change, non-vetoing).
    /// @param gridId The grid the seat belongs to.
    /// @param seatId The seat that changed hands.
    /// @param from The previous holder.
    /// @param to The new holder.
    function onSeatHolderChange(uint256 gridId, uint256 seatId, address from, address to) external;

    /// @notice Observe a tax-driven forfeiture (post-state-change, non-vetoing).
    /// @param gridId The grid the seat belongs to.
    /// @param seatId The seat that was forfeited.
    /// @param from The holder that lost the seat.
    function onForfeit(uint256 gridId, uint256 seatId, address from) external;
}
