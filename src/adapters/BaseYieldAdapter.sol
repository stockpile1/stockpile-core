// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IYieldAdapter } from "../interfaces/IYieldAdapter.sol";
import { IGrid } from "../interfaces/IGrid.sol";

/// @title BaseYieldAdapter
/// @notice Shared plumbing for yield adapters: asset registration with the UGM and
///         forwarding realized yield. Concrete adapters implement `collect`.
abstract contract BaseYieldAdapter is IYieldAdapter, Ownable {
    using SafeERC20 for IERC20;

    /// @notice Per-asset registration record tracked by the adapter.
    struct AssetInfo {
        uint256 gridId; // grid the asset's yield is distributed to
        address yieldToken; // token this asset's yield is denominated in
        bool registered; // whether the asset is currently wired to a grid
    }

    /// @notice The Unified Grid Manager this adapter reports to (satisfies IYieldAdapter.ugm()).
    address public immutable ugm;

    mapping(bytes32 => AssetInfo) public assets;

    /// @notice Deploy the adapter, binding it to a UGM and an owner.
    /// @param ugm_ The Unified Grid Manager this adapter forwards yield to.
    /// @param owner_ The owner authorized to register/withdraw assets.
    constructor(address ugm_, address owner_) Ownable(owner_) {
        require(ugm_ != address(0), "ugm");
        ugm = ugm_;
    }

    /// @notice The yield token distributed for a registered asset.
    /// @param assetHash Canonical handle of the asset.
    /// @return The asset's yield token (zero if unregistered).
    function yieldToken(bytes32 assetHash) external view returns (address) {
        return assets[assetHash].yieldToken;
    }

    /// @notice Whether an asset is currently wired to a grid through this adapter.
    /// @param assetHash Canonical handle of the asset.
    /// @return True if the asset is registered.
    function isAssetRegistered(bytes32 assetHash) public view returns (bool) {
        return assets[assetHash].registered;
    }

    // -------------------- Internal helpers --------------------
    function _registerAsset(bytes32 assetHash, uint256 gridId, address yieldToken_) internal {
        require(!assets[assetHash].registered, "registered");
        require(yieldToken_ != address(0), "yieldToken");
        assets[assetHash] = AssetInfo({ gridId: gridId, yieldToken: yieldToken_, registered: true });
        IGrid(ugm).registerAsset(gridId, assetHash);
    }

    function _withdrawAsset(bytes32 assetHash) internal {
        AssetInfo storage a = assets[assetHash];
        require(a.registered, "not registered");
        a.registered = false;
        IGrid(ugm).withdrawAsset(a.gridId, assetHash);
    }

    /// @notice Approve and push `amount` of the asset's yield token into the UGM.
    function _forward(bytes32 assetHash, uint256 amount) internal returns (uint256) {
        if (amount == 0) return 0;
        address token = assets[assetHash].yieldToken;
        IERC20(token).forceApprove(ugm, amount);
        IGrid(ugm).receiveYieldERC20(assetHash, token, amount);
        return amount;
    }
}
