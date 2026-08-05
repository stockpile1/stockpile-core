// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title MockSlippageOracle
/// @notice Stand-in for {StockpileSlippageOracle} in the unit tests, which run against {MockV3Router}
///         and therefore have no real V3 pools to read a TWAP from.
/// @dev    Defaults to a floor of 0 for every leg, i.e. the pre-oracle behaviour, so the existing suite
///         exercises the same paths as before. Tests that care about the floor set one explicitly:
///           • `setFloor(stock, amount)` — return a fixed floor for one stock.
///           • `setRevert(true)`         — mirror the real oracle's FAIL-CLOSED behaviour (missing pool /
///                                         window too young), so the vault's leg-skip path is exercised.
contract MockSlippageOracle {
    /// @notice Fixed floor returned for a given stock; 0 means "no floor".
    mapping(address => uint256) public floorOf;
    /// @notice When true every quote reverts, mirroring an unusable pool.
    bool public reverts;

    /// @notice Last arguments received, so a test can assert what the vault asked for.
    address public lastStock;
    uint256 public lastAmountIn;
    uint16 public lastMaxSlippageBps;
    uint256 public callCount;

    function setFloor(address stock, uint256 amount) external {
        floorOf[stock] = amount;
    }

    function setRevert(bool r) external {
        reverts = r;
    }

    /// @dev Matches `ISlippageOracle.minOutFor`. Not a `view` in spirit — it records the call — but the
    ///      interface declares `view`, so the recording writes are done through a self-call-free trick:
    ///      the vault calls this via STATICCALL, so state writes here would revert. Recording is therefore
    ///      only performed by `probe`, which tests call directly.
    function minOutFor(address stock, uint24, uint256, uint16) external view returns (uint256) {
        require(!reverts, "MockSlippageOracle: no pool");
        return floorOf[stock];
    }

    /// @notice Shared WBNB→USDT hop. Quotes 1:1, matching {MockV3Router}'s default rate, so the per-leg
    ///         USDT notional the vault derives is simply that leg's WBNB input.
    function quoteWbnbForUsdt(uint256 wbnbIn) external view returns (uint256) {
        require(!reverts, "MockSlippageOracle: no pool");
        return wbnbIn;
    }

    /// @notice Hop-2 floor. Mirrors {minOutFor}; the default 0 keeps the pre-oracle behaviour.
    function minOutForUsdtIn(address stock, uint24, uint256, uint16) external view returns (uint256) {
        require(!reverts, "MockSlippageOracle: no pool");
        return floorOf[stock];
    }

    /// @notice Non-view twin used by tests that want to record the arguments of a quote.
    function probe(address stock, uint24 fee, uint256 amountIn, uint16 maxSlippageBps) external returns (uint256) {
        lastStock = stock;
        lastAmountIn = amountIn;
        lastMaxSlippageBps = maxSlippageBps;
        callCount += 1;
        return this.minOutFor(stock, fee, amountIn, maxSlippageBps);
    }
}
