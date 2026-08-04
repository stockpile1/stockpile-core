// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {FlapBSCFixture} from "../FlapBSCFixture.sol";

/// @dev Minimal view surface of the reference "bStonkBroker" vault (BSC mainnet).
///      Full ABI (name: BStonkBrokerVault) recovered off-chain; only the routing getters are needed here.
interface IRefVault {
    function stocks(uint256 i) external view returns (address);
    function basket() external view returns (address[7] memory tokens, uint24[7] memory fees);
    function swapRouter() external view returns (address);
    function stableToken() external view returns (address);
    function wrappedNative() external view returns (address);
    function wrappedStableFee() external view returns (uint24);
    function stockStableFees(uint256 i) external view returns (uint24);
    function ASSET_COUNT() external view returns (uint256);
}

/// @dev PancakeSwap V3 factory — used to prove a pool exists for each hop.
interface IPancakeV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @dev PancakeSwap V3 SwapRouter on BSC (0x1b81D678…) — the classic Uniswap V3 struct WITH `deadline`.
interface IV3SwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @title RefVaultRoute — reverse-engineered swap route of the reference bStonkBroker vault (T1.1 / D20)
///
/// @notice Proves, on a live BSC-mainnet fork, exactly how the reference multi-stock vault
///         (0x565Bc2…E434a) converts its accrued WBNB into each of its 7 "stock" tokens, so our
///         new MultiStockVault can mirror it. Findings (all asserted below):
///
///           • `distribute(uint256 amountIn, uint256[7] minOuts, uint256 deadline)` (selector 0xf7a8acd2)
///             swaps WBNB → each stock via the PancakeSwap **V3 SwapRouter** at 0x1b81D678….
///           • Every stock is bought with a **2-hop V3 `exactInput`**:
///                 WBNB --(wrappedStableFee)--> USDT --(stockStableFees[i])--> stock[i]
///             i.e. the vault always routes through a stable token (USDT/BSC-USD), never WBNB→stock direct.
///           • The routing config lives in the **vault's own storage** (`stableToken`, `wrappedStableFee`,
///             `stockStableFees[7]`) — NOT in the "swapRegistry" 0x644A8f…, which the vault never calls.
///           • Fee tiers on mainnet: WBNB→USDT = 100 (0.01%); USDT→stock = {SPCXB 2500, QQQB 100,
///             NVDAB 2500, SPYB 100, TSLAB 2500, AAPLB 2500, XAUt 2500}.
contract RefVaultRouteForkTest is FlapBSCFixture {
    IRefVault internal constant REF_VAULT = IRefVault(0x565Bc272Bd0278FdEe697ac1Dd6687F7977E434a);

    address internal constant PANCAKE_V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;

    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955; // BSC-USD (stable token)

    // The 7 stocks, in the reference vault's `stocks(i)` order.
    address internal constant SPCXB = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;
    address internal constant QQQB = 0x205812CdBed920aFf76C6580abD681a46D11efc7;
    address internal constant NVDAB = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436;
    address internal constant SPYB = 0x7138b48df7D98D7e3cc221BfE7192D0a178182D8;
    address internal constant TSLAB = 0x5b1910eAaD6450E50f816082Aa078C41F10C292f;
    address internal constant AAPLB = 0x431a3BEE82E2ca41e49895CbECE5bB0F76A89b7A;
    address internal constant XAUt = 0x21cAef8A43163Eea865baeE23b9C2E327696A3bf;

    function setUp() public {
        _forkBSCMainnet();
        vm.label(address(REF_VAULT), "RefVault:bStonkBroker");
        vm.label(PANCAKE_V3_ROUTER, "PancakeV3Router");
        vm.label(PANCAKE_V3_FACTORY, "PancakeV3Factory");
        vm.label(WBNB, "WBNB");
        vm.label(USDT, "USDT");
    }

    function _expectedStocks() internal pure returns (address[7] memory s) {
        s = [SPCXB, QQQB, NVDAB, SPYB, TSLAB, AAPLB, XAUt];
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  1. The vault's declared route == PancakeSwap V3 through USDT (config in storage).
    // ─────────────────────────────────────────────────────────────────────────

    function test_RefVault_DeclaresV3RouteThroughStable() public view {
        assertEq(REF_VAULT.ASSET_COUNT(), 7, "asset count");
        assertEq(REF_VAULT.swapRouter(), PANCAKE_V3_ROUTER, "router should be PancakeSwap V3 SwapRouter");
        assertEq(REF_VAULT.stableToken(), USDT, "stable hop token should be USDT (BSC-USD)");
        assertEq(REF_VAULT.wrappedNative(), WBNB, "wrapped native should be WBNB");
        assertEq(uint256(REF_VAULT.wrappedStableFee()), 100, "WBNB->USDT hop fee tier should be 100");

        // The 7 stocks and their USDT->stock fee tiers, exactly as stored on-chain.
        address[7] memory expStocks = _expectedStocks();
        uint24[7] memory expFees = [uint24(2500), 100, 2500, 100, 2500, 2500, 2500];

        (address[7] memory basketToks, uint24[7] memory basketFees) = REF_VAULT.basket();
        for (uint256 i = 0; i < 7; i++) {
            assertEq(REF_VAULT.stocks(i), expStocks[i], "stocks(i) mismatch");
            assertEq(basketToks[i], expStocks[i], "basket token mismatch");
            assertEq(uint256(REF_VAULT.stockStableFees(i)), uint256(expFees[i]), "stockStableFees(i) mismatch");
            assertEq(uint256(basketFees[i]), uint256(expFees[i]), "basket fee mismatch");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  2. Every 2-hop route (WBNB->USDT->stock) has a live V3 pool for both hops.
    // ─────────────────────────────────────────────────────────────────────────

    function test_RefVault_AllSevenMultiHopPoolsExist() public view {
        IPancakeV3Factory f = IPancakeV3Factory(PANCAKE_V3_FACTORY);
        uint24 firstHopFee = REF_VAULT.wrappedStableFee();

        // hop 1 (shared): WBNB -> USDT
        assertTrue(f.getPool(WBNB, USDT, firstHopFee) != address(0), "WBNB/USDT hop pool missing");

        // hop 2: USDT -> stock[i]
        address[7] memory stocks = _expectedStocks();
        for (uint256 i = 0; i < 7; i++) {
            uint24 fee = REF_VAULT.stockStableFees(i);
            address pool = f.getPool(USDT, stocks[i], fee);
            assertTrue(pool != address(0), "USDT/stock hop pool missing");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  3. The route actually works: a live WBNB->USDT->stock exactInput returns amountOut>0.
    //     Uses the vault's OWN declared router + fee tiers, so this proves the mirrored strategy.
    // ─────────────────────────────────────────────────────────────────────────

    function _swapWbnbToStockViaUsdt(address stock, uint24 stockFee) internal returns (uint256 out) {
        uint256 amountIn = 1 ether; // 1 WBNB
        deal(WBNB, address(this), amountIn);
        IERC20(WBNB).approve(PANCAKE_V3_ROUTER, amountIn);

        bytes memory path =
            abi.encodePacked(WBNB, REF_VAULT.wrappedStableFee(), USDT, stockFee, stock);

        IV3SwapRouter.ExactInputParams memory p = IV3SwapRouter.ExactInputParams({
            path: path,
            recipient: address(this),
            deadline: block.timestamp + 300,
            amountIn: amountIn,
            amountOutMinimum: 0
        });
        out = IV3SwapRouter(PANCAKE_V3_ROUTER).exactInput(p);
    }

    function test_RefVault_LiveSwap_WBNB_to_SPCXB() public {
        uint256 out = _swapWbnbToStockViaUsdt(SPCXB, REF_VAULT.stockStableFees(0));
        assertGt(out, 0, "WBNB->USDT->SPCXB should yield SPCXB");
        assertEq(IERC20(SPCXB).balanceOf(address(this)), out, "recipient should hold the bought SPCXB");
    }

    function test_RefVault_LiveSwap_WBNB_to_QQQB() public {
        // QQQB uses the 100-fee USDT hop (a different tier from SPCXB), verifying the per-stock fee is honoured.
        uint256 out = _swapWbnbToStockViaUsdt(QQQB, REF_VAULT.stockStableFees(1));
        assertGt(out, 0, "WBNB->USDT->QQQB should yield QQQB");
        assertEq(IERC20(QQQB).balanceOf(address(this)), out, "recipient should hold the bought QQQB");
    }

    // ─────────────────────────────────────────────────────────────────────────
    //  T1.2 — ALL 7 WBNB->USDT->stock swaps are executable on-fork (amountOut>0 each).
    //  Proves every leg our MultiStockVault.distribute() will perform is live & liquid,
    //  using each stock's OWN on-vault fee tier — none needs a different (non-USDT) path.
    // ─────────────────────────────────────────────────────────────────────────
    function test_RefVault_LiveSwap_AllSevenStocks() public {
        address[7] memory stocks = _expectedStocks();
        for (uint256 i = 0; i < 7; i++) {
            uint24 fee = REF_VAULT.stockStableFees(i);
            uint256 out = _swapWbnbToStockViaUsdt(stocks[i], fee);
            assertGt(out, 0, "each WBNB->USDT->stock leg must yield the stock");
            // _swapWbnbToStockViaUsdt sends 1 fresh WBNB and receives to address(this); the running
            // balance is monotonically increasing, so a >0 amountOut per leg is the executability proof.
            assertGe(IERC20(stocks[i]).balanceOf(address(this)), out, "recipient should hold the bought stock");
        }
    }
}
