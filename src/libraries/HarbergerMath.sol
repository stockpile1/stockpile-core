// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title HarbergerMath
/// @notice Continuous self-assessed (Harberger) tax accounting.
/// @dev Tax accrues per the Takeover whitepaper formula:
///      owed = price * taxRateBps * elapsedSeconds / (SECONDS_PER_WEEK * BPS)
library HarbergerMath {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant SECONDS_PER_WEEK = 7 days; // 604800

    /// @notice Tax owed on a seat over `elapsed` seconds at the given weekly rate.
    /// @param price The seat's self-assessed price, in the grid's taxToken.
    /// @param taxRateBps The weekly Harberger tax rate, in basis points.
    /// @param elapsed Seconds elapsed since the seat was last settled.
    /// @return The tax accrued over the interval (0 if any input is 0).
    function taxOwed(uint256 price, uint256 taxRateBps, uint256 elapsed)
        internal
        pure
        returns (uint256)
    {
        if (price == 0 || taxRateBps == 0 || elapsed == 0) return 0;
        return (price * taxRateBps * elapsed) / (SECONDS_PER_WEEK * BPS);
    }

    /// @notice Instantaneous tax accrual rate, in taxToken per second (floored).
    /// @dev Used by `timeUntilForfeiture` to project the runway of a seat's deposit.
    /// @param price The seat's self-assessed price, in the grid's taxToken.
    /// @param taxRateBps The weekly Harberger tax rate, in basis points.
    /// @return The tax accrued per second (0 for dust prices where it rounds down).
    function taxPerSecond(uint256 price, uint256 taxRateBps) internal pure returns (uint256) {
        if (price == 0 || taxRateBps == 0) return 0;
        return (price * taxRateBps) / (SECONDS_PER_WEEK * BPS);
    }
}
