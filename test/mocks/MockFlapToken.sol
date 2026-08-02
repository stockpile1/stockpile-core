// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal stand-in for a Flap tax token, exposing just the surface the
///         `FlapYieldAdapter` reads at registration: `dividendContract()` and `quoteToken()`. Unlike
///         the EOA stand-in used elsewhere, this IS a contract, so the adapter's `code.length > 0`
///         guard passes and it actually stores the returned dividendContract — letting us prove our
///         {DividendVault} is interface-compatible with the real Flap dividendContract path.
contract MockFlapToken {
    /// @notice The per-token DividendPayingToken (our {DividendVault} clone in tests).
    address public dividendContract;
    /// @notice The token dividends are denominated in (e.g. WBNB / STOCK).
    address public quoteToken;

    constructor(address dividendContract_, address quoteToken_) {
        dividendContract = dividendContract_;
        quoteToken = quoteToken_;
    }
}
