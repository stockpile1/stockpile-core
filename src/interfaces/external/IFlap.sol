// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Flap launchpad minimal interfaces (BNB Chain)
/// @notice Flap (flap.sh) is the BNB-Chain analogue of Base's Flaunch: a bonding-curve
///         memecoin launchpad that graduates tokens to PancakeSwap V3 at ~16 BNB market
///         cap. Tokens can be "tax tokens" (fee-on-transfer) whose trading-tax revenue
///         accrues to a fee vault — the yield stream the FlapYieldAdapter partitions.
/// @dev These signatures are RECONSTRUCTED from Flap's public developer docs and MUST be
///      confirmed against the verified on-chain contracts (Portal
///      0xe2cE6ab8..., VaultPortal 0x90497450...) during fork testing before mainnet use.

/// @notice Flap portal: bonding-curve and token-management surface used by the port.
interface IFlapPortal {
    /// @notice Whether `token` has graduated from the bonding curve to a DEX pool.
    /// @param token The Flap-launched token to query.
    /// @return True once the token has graduated to a PancakeSwap V3 pool, false while still on the curve.
    function isGraduated(address token) external view returns (bool);
}

/// @notice A Flap tax token (fee-on-transfer). Trading tax is swapped to the token's `quoteToken`
///         (the pair token, e.g. STOCK) and funded into a per-token `dividendContract`, which then
///         distributes it pro-rata to the token's HOLDERS. Verified on-chain against a live Flap
///         tax token (e.g. MarsCoin 0xfe189e…7777) on BSC.
interface IFlapTaxToken {
    /// @notice The per-token DividendPayingToken that accrues and distributes this token's fee revenue.
    /// @return The dividend contract address for this Flap token.
    function dividendContract() external view returns (address);

    /// @notice The pair/quote token the trading tax is converted into before distribution (e.g. STOCK).
    /// @return The quote token address in which dividends are denominated.
    function quoteToken() external view returns (address);
}

/// @notice Standard DividendPayingToken accruing a Flap token's fee revenue to its HOLDERS.
/// @dev An address is entitled to dividends by HOLDING the underlying Flap token; it realizes them
///      by calling the claim function on this contract. The canonical claim selector is
///      `withdrawDividend()`; it is NOT 100% confirmed on-chain and MUST be called best-effort
///      (try/catch). `withdrawableDividendOf` / `accumulativeDividendOf` / `totalDividendsDistributed`
///      are the standard DividendPayingToken view surface.
interface IDividendPayingToken {
    /// @notice Dividends currently withdrawable by `account` (accumulated minus already withdrawn).
    /// @param account The holder whose withdrawable dividends are queried.
    /// @return The amount of quote-token dividends `account` can withdraw right now.
    function withdrawableDividendOf(address account) external view returns (uint256);

    /// @notice Withdraw the caller's withdrawable dividends to the caller.
    /// @dev Canonical selector; called best-effort by the adapter (try/catch) since it is unconfirmed.
    function withdrawDividend() external;

    /// @notice Total dividends ever allocated to `account` (withdrawn + still withdrawable).
    /// @param account The holder whose accumulative dividends are queried.
    /// @return The lifetime dividends allocated to `account`.
    function accumulativeDividendOf(address account) external view returns (uint256);

    /// @notice Total dividends distributed to all holders over the contract's lifetime.
    /// @return The cumulative amount of quote-token dividends distributed.
    function totalDividendsDistributed() external view returns (uint256);
}

/// @notice VaultPortal manages per-token fee/revenue vaults for launched tokens.
interface IFlapVaultPortal {
    /// @notice Fees currently claimable for `token` by `account`.
    /// @param token The Flap token whose fee vault is queried.
    /// @param account The address whose claimable balance is returned.
    /// @return amount Fees currently claimable by `account`, in the vault's fee token.
    function claimable(address token, address account) external view returns (uint256 amount);

    /// @notice Claim accrued fees for `token` to the caller; returns amount transferred.
    /// @param token The Flap token whose accrued fees are claimed.
    /// @return amount Fees transferred to the caller by this claim.
    function claim(address token) external returns (uint256 amount);
}
