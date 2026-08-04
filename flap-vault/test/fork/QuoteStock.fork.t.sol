// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {FlapBSCFixture} from "../FlapBSCFixture.sol";
import {IVaultPortalTypes} from "../../src/flap/IVaultPortal.sol";
import {IFlapTaxTokenV3} from "../../src/flap/IFlapTaxTokenV3.sol";
import {ITaxProcessor} from "../../src/flap/ITaxProcessor.sol";
import {StockpileVaultFactory} from "../../src/StockpileVaultFactory.sol";
import {MockUGM} from "../mocks/MockUGM.sol";

/// @title Proof: the fee the Stockpile vault receives is WBNB — NOT the launched token, and NOT an
///        arbitrary "stock" ERC20 — because Flap's VaultPortal only accepts NATIVE BNB as the quote.
///
/// @dev  Findings (all on a live BSC-mainnet fork):
///        1. Flap's `newTokenV6WithVault` reverts `UnsupportedQuoteToken` for ANY non-native quote —
///           an ERC20 "stock" (BSC-USD) AND even WBNB are rejected, at ~1.5k gas, BEFORE our factory
///           is consulted. So a TOKEN/stock (or TOKEN/WBNB) pair is impossible through the vault portal.
///        2. With the only allowed quote (native BNB), the FlapTaxTokenV3 collects tax in the token,
///           the TaxProcessor liquidates it to the quote (BNB) — see `marketQuoteBalance()` /
///           `getQuoteToken()` — and `dispatch()` sends native BNB to `marketAddress` (the vault).
///           The vault's `receive()` wraps that BNB to WBNB. => fee == WBNB, always.
///        3. Consequence: our `StockpileVaultFactory` MUST keep `wbnb` = a real BNB wrapper (WBNB);
///           it cannot be swapped for a "stock" ERC20. The factory's quote allowlist that advertises
///           WBNB/USDT/USDC/BUSD is misleading — Flap accepts none of them; only native BNB.
contract QuoteStockForkTest is FlapBSCFixture {
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    /// @dev BSC-USD (USDT on BSC) — a real ERC20 standing in for any "stock" quote.
    address internal constant STOCK = 0x55d398326f99059fF775485246999027B3197955;

    MockUGM internal ugm;
    StockpileVaultFactory internal factory;

    function setUp() public {
        _forkBSCMainnet();
        ugm = new MockUGM();
        factory = new StockpileVaultFactory(address(ugm), 1000);
    }

    /// @dev A precomputed fresh 7777 vanity salt for (TOKEN_IMPL_TAXED_V3, PORTAL) — predicts
    ///      0x521338b234116bd8646865e0a0b7c185975c7777 (empty on mainnet). Hardcoded so the test
    ///      runs fast enough to finish before a non-archive fork node prunes the pinned block.
    bytes32 internal constant VANITY_SALT = bytes32(uint256(987754003));

    /// @dev Returns true iff Flap's VaultPortal accepts `quote` for a vault-backed launch.
    ///      Rejected launches revert before deploying anything, so the salt stays reusable.
    function _launches(bytes32 salt, address quote) internal returns (bool ok) {
        IVaultPortalTypes.NewTokenV6WithVaultParams memory p =
            _buildV3TaxTokenParams("Q", "Q", salt, address(factory), "");
        p.quoteToken = quote;
        p.quoteAmt = 0;
        vm.prank(makeAddr("creator"));
        try vaultPortal.newTokenV6WithVault(p) returns (address) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    /// @notice Flap's VaultPortal rejects ANY non-native quote → a TOKEN/stock (or TOKEN/WBNB) pair
    ///         is impossible, so the tax can only ever settle in native BNB. The vault then wraps that
    ///         BNB to WBNB (proven by LaunchFlow's `test_EndToEnd_RealLaunch_TradeDispatchReceiveFlush`
    ///         and `test_RealLaunch_CreatesBoundVault`). => the fee the vault receives is ALWAYS WBNB.
    function test_FlapVaultLaunch_RejectsAnyNonNativeQuote() public {
        assertFalse(_launches(VANITY_SALT, STOCK), "ERC20 'stock' quote must be REJECTED by Flap");
        assertFalse(_launches(VANITY_SALT, WBNB), "even WBNB quote must be REJECTED by Flap");
        // (native BNB quote is accepted — see LaunchFlow — and its tax reaches the vault as BNB->WBNB.)
    }

    /// @dev SPCXB (0xbe9D…, "SpaceX") IS a Flap-whitelisted stock quote — it is the live quote of
    ///      MarsCoin (0xfe18…7777). So Flap DOES support ERC20 stock quotes... but only for REGULAR
    ///      launches (Portal.newTokenV6): MarsCoin's fee recipient is a plain EOA, not a vault, and
    ///      VaultPortal.getVault(MarsCoin) reverts. The VAULT-BACKED path (VaultPortal.newTokenV6-
    ///      WithVault, which Stockpile uses) rejects SPCXB at 1513 gas inside the VaultPortal, BEFORE
    ///      our factory is consulted — i.e. vault-backed launches are hard-gated to native BNB only.
    function test_VaultBacked_RejectsEvenWhitelistedStockQuote() public {
        address SPCXB = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1; // Flap-whitelisted, used by MarsCoin
        assertFalse(_launches(VANITY_SALT, SPCXB), "vault-backed launch must reject even a whitelisted stock quote");
    }
}
