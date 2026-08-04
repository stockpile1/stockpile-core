// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {StockBasket} from "./StockBasket.sol";

/// @title StockBasketDeployer
/// @author The Stockpile Team
/// @notice Tiny shared helper that deploys a {StockBasket} on behalf of a vault. It exists ONLY to keep
///         the {StockpileBasketVaultV2} implementation under the EIP-170 24 KB runtime-code limit: were the
///         vault to `new StockBasket(...)` directly, the basket's entire creation code would be embedded in
///         the vault's runtime bytecode (pushing it well over 24 KB). By delegating the `new` to this
///         separate contract, that bytecode lives here instead.
///
/// @dev    Stateless and permissionless. {deployBasket} creates a basket, binds `vault` as its sole minter
///         via {StockBasket.setVault}, and hands the basket's ownership to `vault`, so the vault owns and
///         solely mints its own basket — exactly as if it had deployed it itself. Anyone may call this
///         (it only mints orphan baskets when misused), so it holds no funds and no privileged state.
contract StockBasketDeployer {
    /// @notice Deploy a fresh {StockBasket} over `stocks`, set `vault` as its minter, and transfer the
    ///         basket's ownership to `vault`.
    /// @param  name   ERC-20 name of the basket share token.
    /// @param  symbol ERC-20 symbol of the basket share token.
    /// @param  stocks The underlying stock tokens (non-empty, each non-zero, all distinct).
    /// @param  vault  The vault that will solely mint (and own) the basket.
    /// @return basket The deployed {StockBasket} address.
    function deployBasket(string calldata name, string calldata symbol, address[] calldata stocks, address vault)
        external
        returns (address basket)
    {
        StockBasket b = new StockBasket(name, symbol, stocks);
        b.setVault(vault); // vault becomes the sole minter (one-shot)
        b.transferOwnership(vault); // vault becomes the owner (this deployer keeps nothing)
        basket = address(b);
    }
}
