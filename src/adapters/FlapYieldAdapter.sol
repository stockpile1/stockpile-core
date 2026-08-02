// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BaseYieldAdapter } from "./BaseYieldAdapter.sol";
import { IFlapPortal, IFlapVaultPortal, IFlapTaxToken, IDividendPayingToken } from "../interfaces/external/IFlap.sol";

/// @title FlapYieldAdapter
/// @notice BNB-Chain replacement for Takeover's FlaunchYieldAdapter. Streams a Flap
///         (flap.sh) launched token's trading-fee / tax revenue into a grid.
/// @dev Flap fee distribution (verified on-chain, e.g. MarsCoin 0xfe189e…7777 on BSC): a Flap
///      tax token routes its trading tax → the tax processor swaps it into the token's
///      `quoteToken` (the pair token, e.g. STOCK) → that funds the token's per-token
///      `dividendContract` (a standard DividendPayingToken) → which distributes it PRO-RATA to
///      the token's HOLDERS. An address therefore earns fees by HOLDING the Flap token and
///      realizes them by claiming on the dividendContract.
///
///      IMPORTANT: for this adapter to be entitled to any dividends it MUST HOLD the registered
///      Flap token (the Flap position/allocation should be transferred to this adapter). Fee
///      revenue then accrues to the adapter's holder balance in the `dividendContract` and is
///      swept into the UGM on `collectYield`.
///
///      `collectYield` is a best-effort claim followed by an authoritative BALANCE SWEEP: it
///      forwards whatever `yieldToken` balance the adapter holds regardless of whether the
///      claim selector matched, so it keeps working even if `withdrawDividend()` (the canonical,
///      unconfirmed selector) reverts or the token uses a different claim path. See DECISIONS D12.
contract FlapYieldAdapter is BaseYieldAdapter {
    IFlapPortal public immutable portal;
    IFlapVaultPortal public immutable vaultPortal;

    mapping(bytes32 => address) public flapTokenOf;
    /// @notice Per-asset DividendPayingToken read from the Flap token at registration (0 if the
    ///         token did not expose `dividendContract()` — the balance-sweep path still works).
    mapping(bytes32 => address) public dividendContractOf;

    /// @notice Emitted when a Flap token's fee stream is wired to a grid.
    /// @param assetHash Canonical handle assigned to the stream.
    /// @param gridId The grid the fees are distributed to.
    /// @param flapToken The Flap token whose fees are streamed.
    /// @param yieldToken The token the forwarded fees are denominated in.
    /// @param dividendContract The token's DividendPayingToken (0 if not exposed).
    event FlapTokenRegistered(
        bytes32 indexed assetHash, uint256 indexed gridId, address flapToken, address yieldToken, address dividendContract
    );

    /// @notice Emitted when accrued fees are realized and forwarded to the UGM.
    /// @param assetHash Canonical handle of the harvested stream.
    /// @param forwarded Amount of yield token forwarded to the UGM.
    event Harvested(bytes32 indexed assetHash, uint256 forwarded);

    /// @notice Deploy the adapter with its Flap portal dependencies.
    /// @param ugm_ The Unified Grid Manager this adapter forwards yield to.
    /// @param portal_ The Flap portal (graduation / token management queries).
    /// @param vaultPortal_ The Flap VaultPortal (retained for the graduated-LP vault-fee path;
    ///        claimed best-effort alongside the primary dividendContract path).
    /// @param owner_ The owner authorized to register/withdraw Flap tokens.
    constructor(address ugm_, address portal_, address vaultPortal_, address owner_)
        BaseYieldAdapter(ugm_, owner_)
    {
        portal = IFlapPortal(portal_);
        vaultPortal = IFlapVaultPortal(vaultPortal_);
    }

    /// @notice Canonical asset hash for a Flap token's fee stream.
    /// @param flapToken The Flap token to derive the handle for.
    /// @return The deterministic asset hash for the stream.
    function assetHashFor(address flapToken) public pure returns (bytes32) {
        return keccak256(abi.encode("Flap", flapToken));
    }

    /// @notice Wire a Flap token's fee stream to a grid, recording its dividendContract.
    /// @dev Reads and stores `flapToken.dividendContract()` best-effort (try/catch): a token that
    ///      does not expose it (or an EOA in tests) still registers, and `collectYield`'s balance
    ///      sweep keeps working. `yieldToken` should equal the token's `quoteToken()` (the token
    ///      dividends are paid in, e.g. STOCK).
    /// @param gridId The grid the fees are distributed to.
    /// @param flapToken The Flap token whose fee stream is registered.
    /// @param yieldToken The token fees are denominated in (the Flap token's quote/pair token,
    ///        e.g. STOCK).
    /// @return assetHash Canonical handle assigned to the registered stream.
    function registerFlapToken(uint256 gridId, address flapToken, address yieldToken)
        external
        onlyOwner
        returns (bytes32 assetHash)
    {
        require(flapToken != address(0), "flapToken");
        assetHash = assetHashFor(flapToken);
        flapTokenOf[assetHash] = flapToken;

        // Read the per-token DividendPayingToken best-effort; 0 if unavailable. Guard on code
        // length first: a high-level call to an EOA raises an uncatchable "non-contract" error,
        // so try/catch alone is not enough (the Flap token may be an EOA stand-in in tests).
        address divc;
        if (flapToken.code.length > 0) {
            try IFlapTaxToken(flapToken).dividendContract() returns (address d) {
                divc = d;
            } catch {}
        }
        dividendContractOf[assetHash] = divc;

        _registerAsset(assetHash, gridId, yieldToken);
        emit FlapTokenRegistered(assetHash, gridId, flapToken, yieldToken, divc);
    }

    /// @notice Unwire a previously registered Flap fee stream from its grid.
    /// @param assetHash Canonical handle of the stream to withdraw.
    function withdrawFlapToken(bytes32 assetHash) external onlyOwner {
        _withdrawAsset(assetHash);
    }

    /// @notice Realize pending Flap fees for `assetHash` and forward them to the UGM.
    /// @dev Best-effort claim, then authoritative balance sweep (idempotent — a sweep of 0 forwards
    ///      nothing). Steps: (1) claim the adapter's dividends from the token's `dividendContract`
    ///      via `withdrawDividend()` (the canonical, unconfirmed selector — try/catch); (2) claim
    ///      any graduated-LP vault fees via the retained `vaultPortal` (try/catch); (3) forward the
    ///      adapter's entire `yieldToken` balance to the UGM. The sweep is what makes the adapter
    ///      robust to an unmatched claim selector. Forwarding uses `forceApprove` (via `_forward`).
    /// @param assetHash Canonical handle of the stream to harvest.
    /// @return forwarded Amount of yield token forwarded to the UGM.
    function collectYield(bytes32 assetHash) external returns (uint256 forwarded) {
        require(assets[assetHash].registered, "not registered");

        // (1) Primary, real mechanism: pull this adapter's holder dividends from the token's
        //     per-token DividendPayingToken. Best-effort — the selector is unconfirmed on-chain.
        address divc = dividendContractOf[assetHash];
        if (divc != address(0) && divc.code.length > 0) {
            try IDividendPayingToken(divc).withdrawDividend() {} catch {}
        }

        // (2) Retained secondary: graduated-LP vault fees (unconfirmed selector, best-effort).
        try vaultPortal.claim(flapTokenOf[assetHash]) returns (uint256) {} catch {}

        // (3) Authoritative: forward whatever yield-token balance actually landed here.
        address y = assets[assetHash].yieldToken;
        forwarded = _forward(assetHash, IERC20(y).balanceOf(address(this)));
        emit Harvested(assetHash, forwarded);
    }

    /// @notice Best-effort estimate of the Flap dividends currently claimable by this adapter.
    /// @dev Reads `dividendContract.withdrawableDividendOf(address(this))`. Never reverts
    ///      (try/catch -> 0): returns 0 when the token exposed no dividendContract, when the
    ///      asset is unregistered, or on any read failure. Advisory only — the authoritative
    ///      amount is whatever `collectYield` sweeps.
    /// @param assetHash Canonical handle of the stream to query.
    /// @return Estimated withdrawable dividend for this adapter (0 if unavailable).
    function pendingYield(bytes32 assetHash) external view returns (uint256) {
        address divc = dividendContractOf[assetHash];
        // Code-length guard: a high-level call to a non-contract raises an uncatchable error, so
        // check for code before the try (which then catches any in-contract revert) -> 0.
        if (divc == address(0) || divc.code.length == 0) return 0;
        try IDividendPayingToken(divc).withdrawableDividendOf(address(this)) returns (uint256 amt) {
            return amt;
        } catch {
            return 0;
        }
    }

    /// @notice View helper: whether the underlying Flap token has graduated to a DEX.
    /// @param assetHash Canonical handle of the registered stream.
    /// @return True if the underlying Flap token has graduated to a PancakeSwap V3 pool.
    function isGraduated(bytes32 assetHash) external view returns (bool) {
        return portal.isGraduated(flapTokenOf[assetHash]);
    }
}
