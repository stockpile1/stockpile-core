// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Refund behaviour when a governance module force-transfers a seat.
///         Mirrors Takeover's `SeatTransferRefund` (None | Deposit).
enum SeatTransferRefund {
    None, // depositor forfeits remaining deposit
    Deposit // unspent deposit returned to previous holder
}

/// @notice Immutable-after-creation configuration of a grid.
/// @dev Reconstructed from Takeover's documented `gridConfig(gridId)` plus the v2.2
///      `forfeitureDuration` field that anchors the Dutch-auction decay of forfeited seats.
struct GridConfig {
    address creator; // grid creator; owns initial seats, tax-exempt yield
    uint64 createdAt; // creation timestamp
    uint32 totalSeats; // number of seats, bounded [MIN_TOTAL_SEATS, MAX_TOTAL_SEATS]
    uint16 taxRateBps; // Harberger tax rate per week, in basis points
    uint32 forfeitureDuration; // Dutch-auction decay window for forfeited seats, in seconds
    address taxToken; // token used for prices, deposits and tax
    address yieldToken; // token distributed to seat holders as yield
}

/// @notice Per-seat Harberger state.
/// @dev A seat with `holder == address(0)` is VACANT: it was forfeited (tax-underwater) or
///      abandoned and is in its Dutch-auction reclaim window. `price` is preserved to anchor
///      the decay and `forfeitedAt` marks when the window opened. `seatEverSold` flips true on
///      the first sale out of the creator's initial listing and never resets, so a creator who
///      later reclaims a seat is still taxable (only the untouched initial listing is exempt).
struct Seat {
    address holder; // current owner of the seat (address(0) == vacant / in Dutch auction)
    bool seatEverSold; // true once the seat has left the creator's initial listing
    uint128 price; // self-assessed price (in taxToken); preserved while vacant to anchor decay
    uint128 deposit; // remaining tax deposit (in taxToken)
    uint64 lastSettledAt; // last timestamp continuous tax was settled
    uint64 acquiredAt; // acquisition timestamp (anti-snipe / holder-since)
    uint64 lastPriceChangeTime; // last acquisition/reprice timestamp (PRICE_COOLDOWN anchor)
    uint64 forfeitedAt; // Dutch-auction start (0 == not forfeited)
}

/// @notice Parameters for creating a grid in a single transaction.
/// @dev Simplified vs. Takeover's `createGrid` / `createGridShell` chunked flow;
///      the BNB scaffold supports up to MAX_SINGLE_TX_CREATE_TOTAL_SEATS at once.
struct CreateGridParams {
    uint32 totalSeats; // number of seats to create, bounded [MIN_TOTAL_SEATS, MAX_SINGLE_TX_CREATE_TOTAL_SEATS]
    uint16 taxRateBps; // Harberger tax rate per week, in basis points
    uint32 forfeitureDuration; // Dutch decay window (seconds); 0 => DEFAULT_FORFEITURE_DURATION
    address taxToken; // token used for prices, deposits and tax (must be guardian-allowed)
    address yieldToken; // token distributed to seat holders as yield
    uint128 initialPrice; // uniform starting price for every creator-owned seat
}
