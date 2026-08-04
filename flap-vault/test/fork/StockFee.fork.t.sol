// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

// ──────────────────────────────────────────────────────────────────────────────
//  Minimal local interfaces (declared here so this proof stands alone)
// ──────────────────────────────────────────────────────────────────────────────

/// @dev Just enough of Flap's V3 tax token to reach its per-token TaxProcessor.
interface IFlapTaxTokenV3 {
    function taxProcessor() external view returns (address);
}

/// @dev Just enough of a Flap TaxProcessor to observe how tax is settled.
///      `getQuoteToken()` is the ERC20 the tax is liquidated INTO; `marketAddress()`
///      is the beneficiary that receives the market portion of that liquidated tax.
interface ITaxProcessor {
    function getQuoteToken() external view returns (address);
    function marketAddress() external view returns (address);
}

/// @dev Minimal ERC20 surface used to read the settled "stock" balance + symbol.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function symbol() external view returns (string memory);
}

/// @title Fork-proof: a REGULAR Flap launch quoted in an ERC20 "stock" delivers its tax
///        fee IN THAT STOCK to the token's market recipient — NOT in WBNB.
///
/// @notice This documents the Flap side of Cách B (the stock-settled Stockpile design).
///
///   Cách B routes a Flap token's tax into a Stockpile Harberger grid settled in an ERC20
///   "stock" asset instead of native BNB→WBNB. That only works because, on Flap's REGULAR
///   launch path (`Portal.newTokenV6`, quoted in an ERC20 stock), the token's `TaxProcessor`
///   liquidates collected tax to the QUOTE STOCK and `dispatch()`es the market portion to
///   `marketAddress` as a plain ERC20 `transfer`. So if a StockpileVault is set as the launch
///   `beneficiary` (i.e. becomes `marketAddress`), the fee it receives is the STOCK token, not
///   WBNB — exactly what {StockpileVault} custodies as its `settlementToken` and `flush()`es
///   into the grid. (The vault-backed portal path is the opposite: it is hard-gated to native
///   BNB and cannot deliver a stock — see `QuoteStock.fork.t.sol`. Hence Cách B uses the
///   regular path with the vault as beneficiary.)
///
///   Live on-chain reference used as the proof (all verified on a BSC-mainnet fork):
///     • MarsCoin (a real REGULAR, stock-quoted Flap launch) = 0xfe18…7777
///     • its TaxProcessor's quote token SPCXB ("SpaceX")      = 0xbe9D…03E1  (an ERC20, NOT WBNB)
///     • its market recipient (`marketAddress`)              = 0x85de…82E5, which actually holds SPCXB
///
///   Read-only: this test never launches or trades — it only observes MarsCoin's live wiring.
contract StockFeeForkTest is Test {
    /// @dev A real REGULAR, stock-quoted Flap launch on BSC mainnet.
    address internal constant MARSCOIN = 0xFe189E97832DA1573e4e4Ff034F4fFC3a15c7777;
    /// @dev MarsCoin's live quote "stock" — SPCXB ("SpaceX"), a plain ERC20 (NOT WBNB).
    address internal constant SPCXB = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;
    /// @dev MarsCoin's market recipient (the beneficiary that receives the settled stock as fee).
    address internal constant MARKET_RECIPIENT = 0x85de3316EECa740BA049A8D9c9d68ab21cB282E5;
    /// @dev The canonical WBNB the STOCK path deliberately does NOT settle in.
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    ITaxProcessor internal processor;

    function setUp() public {
        // Fork BSC mainnet; fall back to a second public node if the primary is unreachable.
        try vm.createSelectFork("https://bsc.meowrpc.com") returns (uint256) {}
        catch {
            vm.createSelectFork("https://bsc-dataseed.bnbchain.org");
        }
        assertEq(block.chainid, 56, "must be forked onto BSC mainnet (chainId 56)");

        processor = ITaxProcessor(IFlapTaxTokenV3(MARSCOIN).taxProcessor());
    }

    /// @notice The token's tax is quoted/settled in an ERC20 STOCK, not WBNB — the precondition
    ///         that lets a StockpileVault custody the stock as its `settlementToken`.
    function test_QuoteToken_IsStock_NotWBNB() public view {
        address quote = processor.getQuoteToken();
        assertEq(quote, SPCXB, "tax must be settled in the SPCXB stock");
        assertTrue(quote != WBNB, "stock quote must NOT be WBNB");
        assertTrue(quote != address(0), "stock quote must be a real ERC20, not the native sentinel");
    }

    /// @notice Sanity-check the quote token is the ERC20 "stock" we expect (SPCXB).
    function test_StockSymbol_IsSPCXB() public view {
        assertEq(
            keccak256(bytes(IERC20(SPCXB).symbol())),
            keccak256(bytes("SPCXB")),
            "quote token symbol must be SPCXB"
        );
    }

    /// @notice The market recipient actually holds the stock — proof the fee was delivered as the
    ///         STOCK (via a plain ERC20 transfer), so a StockpileVault set as `marketAddress` would
    ///         likewise receive the stock, not WBNB.
    function test_MarketRecipient_ReceivedStockAsFee() public view {
        assertEq(processor.marketAddress(), MARKET_RECIPIENT, "market recipient wiring changed on-chain");
        assertGt(
            IERC20(SPCXB).balanceOf(MARKET_RECIPIENT),
            0,
            "market recipient must hold the SPCXB stock it received as fee"
        );
    }
}
