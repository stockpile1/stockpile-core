// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {StockBasket} from "../src/StockBasket.sol";
import {StockpileBasketVault} from "../src/StockpileBasketVault.sol";
import {MockMintableERC20} from "../test/mocks/MockMintableERC20.sol";
import {MockV3Router} from "../test/mocks/MockV3Router.sol";

/// @dev The UGM's grid-creation params (mirrors core GridTypes.CreateGridParams — field order/types must match).
struct CreateGridParams {
    uint32 totalSeats;
    uint16 taxRateBps;
    uint32 forfeitureDuration;
    address taxToken; // must be guardian-allowed (setAllowedTaxToken)
    address yieldToken; // here: the StockBasket index token (every grid pays out the SAME basket)
    uint128 initialPrice;
}

/// @dev Immutable-after-creation grid config (mirrors core GridTypes.GridConfig — field order/types must match)
///      so `gridConfig(uint256)` ABI-decodes cleanly. Only `totalSeats` is read here (the seat-proportional split).
struct GridConfigView {
    address creator;
    uint64 createdAt;
    uint32 totalSeats;
    uint16 taxRateBps;
    uint32 forfeitureDuration;
    address taxToken;
    address yieldToken;
}

/// @dev The UGM control surface this script needs. On testnet the deployer IS the UGM owner+guardian, so it
///      may call the guardian setters directly.
interface ITestnetUGM {
    function createGrid(CreateGridParams calldata p) external returns (uint256 gridId);
    function setAllowedTaxToken(address token, bool allowed) external;
    function setApprovedAdapter(address adapter, bool approved) external;
    function gridConfig(uint256 gridId) external view returns (GridConfigView memory);
    function gridCount() external view returns (uint256);
}

/// @title Deploy + prove the {StockBasket, StockpileBasketVault} pair on BSC TESTNET (chainId 97) — self-contained.
///
/// @notice The 3 real stock tokens and their PancakeSwap V3 pools DO NOT exist on testnet, so this script
///         stands up a hermetic, deterministic swap path: 3 mintable mock stocks, a mock USDT, and a
///         MockV3Router that mints proceeds 1:1 (no pre-fund). It then runs the WHOLE money path live:
///         deploy the basket over the 3 mock stocks → create a grid PER seat-tier (yieldToken == the basket,
///         taxToken == the already-allowlisted tWBNB) → deploy the vault (basket + captured grid ids) →
///         `basket.setVault(vault)` → approve the vault as a UGM adapter → `registerAllGrids()` → fund the
///         vault with real native BNB → `distribute()` (wrap→swap→basket mint→seat-proportional grid feed).
///
///         The live UGM `0xaA40…Cbd1` is REUSED (the deployer is its owner+guardian). CHICKEN-EGG ORDER: the
///         vault needs the grid ids at construction AND each grid's `yieldToken` must equal the basket (which
///         needs the basket address), so the order is: deploy mocks+basket → create grids (yieldToken=basket)
///         → deploy vault(basket, gridIds) → setVault → setApprovedAdapter(vault) → registerAllGrids. Grid ids
///         are captured from each createGrid return (not assumed). Everything runs in ONE broadcast.
///
///         Run (simulate first — DROP --broadcast — then broadcast):
///           cd contracts/vault
///           set -a && . ./.env && set +a        # loads PRIVATE_KEY (never echo the key)
///           forge script script/DeployBasketVaultTestnet.s.sol --tc DeployBasketVaultTestnet \
///             --rpc-url https://data-seed-prebsc-1-s1.bnbchain.org:8545 --broadcast --legacy
///
///         Requires env PRIVATE_KEY (the testnet deployer/guardian). Testnet-only mocks — never for mainnet.
contract DeployBasketVaultTestnet is Script {
    // ── Live BSC-testnet infrastructure (verified) ───────────────────────────────
    address internal constant UGM = 0xaA40Da4d2F81207196b16C29A9683ABA9d98Cbd1;
    address internal constant TWBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd; // WETH9-style wrapper (deposit())

    // ── Vault config ─────────────────────────────────────────────────────────────
    uint24 internal constant WBNB_USDT_FEE = 100; // mock router ignores fee tiers; kept for parity with mainnet
    uint16 internal constant COMMISSION_BPS = 600; // 6%
    uint256 internal constant MIN_INTERVAL = 0; // no time-gate on testnet so repeat distributes are easy
    uint256 internal constant FUND_BNB = 0.03 ether; // native BNB seeded into the vault for the proof distribute

    // ── Grid seat tiers (DIFFERENT so the seat-proportional split is visibly exercised) ──
    uint32 internal constant SEATS_0 = 8;
    uint32 internal constant SEATS_1 = 24;
    uint32 internal constant SEATS_2 = 48;

    /// @dev Bundle the deployed handles so run() stays within the (non-via-ir) stack limit.
    struct Deployed {
        address[] stocks; // 3 mock stocks (order == basket's stock order)
        address usdt; // mock USDT (mid hop; the mock router ignores it)
        address router; // MockV3Router
        address basket; // StockBasket over the 3 mock stocks
        uint256[] gridIds; // the 3 created grid ids (seats 8/24/48)
        address vault; // StockpileBasketVault
    }

    function run() external {
        require(block.chainid == 97, "run on BSC testnet (chainId 97)");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        Deployed memory d = _deployAndWire(deployer);
        uint256 basketMinted = _fundAndDistribute(d.vault);
        vm.stopBroadcast();

        _report(d, deployer, basketMinted);
    }

    // ── Helpers (kept small so no single stack frame overflows under the non-via-ir optimizer) ──

    function _names() internal pure returns (string[3] memory n) {
        n[0] = "SPCXB-T";
        n[1] = "QQQB-T";
        n[2] = "NVDAB-T";
    }

    /// @dev Deploy the 3 mock stocks + a mock USDT + the mock router.
    function _deployMocks() internal returns (address[] memory stocks, address usdt, address router) {
        string[3] memory names = _names();
        stocks = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            stocks[i] = address(new MockMintableERC20(names[i], names[i], 18));
        }
        usdt = address(new MockMintableERC20("USDT-T", "USDT-T", 18));
        router = address(new MockV3Router());
    }

    /// @dev Create the 3 grids on the live UGM: `yieldToken == basket`, `taxToken == tWBNB` (already
    ///      allowlisted — re-allowlisted defensively; the guardian setter is idempotent), DIFFERENT seat
    ///      counts. Ids are captured from each createGrid return.
    function _createGrids(address basket) internal returns (uint256[] memory gridIds) {
        ITestnetUGM ugm = ITestnetUGM(UGM);
        ugm.setAllowedTaxToken(TWBNB, true); // tWBNB is the tax token for every basket grid
        uint32[3] memory seats = [SEATS_0, SEATS_1, SEATS_2];
        gridIds = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            gridIds[i] = ugm.createGrid(
                CreateGridParams({
                    totalSeats: seats[i],
                    taxRateBps: 100,
                    forfeitureDuration: 0,
                    taxToken: TWBNB,
                    yieldToken: basket,
                    initialPrice: 1e15
                })
            );
        }
    }

    /// @dev The 3 stock legs: fees 2500/100/2500, weights 3400/3300/3300 (sum 10_000). `stocks` (the basket's
    ///      canonical order) fixes the ORDER, which the vault requires to equal the basket's.
    function _legs(address[] memory stocks) internal pure returns (StockpileBasketVault.StockLeg[] memory legs) {
        uint24[3] memory fees = [uint24(2500), 100, 2500];
        uint16[3] memory weights = [uint16(3400), 3300, 3300]; // sums to 10_000
        legs = new StockpileBasketVault.StockLeg[](3);
        for (uint256 i = 0; i < 3; i++) {
            legs[i] =
                StockpileBasketVault.StockLeg({stock: stocks[i], stockFee: fees[i], swapWeightBps: weights[i]});
        }
    }

    /// @dev Deploy the vault over the basket + captured grid ids. Legs are built in a separate helper first
    ///      (avoids a stack-too-deep on the 11-arg constructor under the non-via-ir optimizer).
    function _newVault(address usdt, address router, address basket, uint256[] memory gridIds, address treasury)
        internal
        returns (address)
    {
        StockpileBasketVault.StockLeg[] memory legs = _legs(StockBasket(basket).getStocks());
        StockpileBasketVault v = new StockpileBasketVault(
            TWBNB, usdt, UGM, router, WBNB_USDT_FEE, basket, treasury, COMMISSION_BPS, MIN_INTERVAL, legs, gridIds
        );
        return address(v);
    }

    /// @dev Full deploy + wiring in dependency order (see the chicken-egg note on the contract).
    function _deployAndWire(address deployer) internal returns (Deployed memory d) {
        (d.stocks, d.usdt, d.router) = _deployMocks();
        d.basket = address(new StockBasket("Stockpile Basket TEST", "SPBT", d.stocks));
        d.gridIds = _createGrids(d.basket); // grids created with yieldToken == basket
        d.vault = _newVault(d.usdt, d.router, d.basket, d.gridIds, deployer);
        StockBasket(d.basket).setVault(d.vault); // one-shot: bind vault as the basket's sole minter
        ITestnetUGM(UGM).setApprovedAdapter(d.vault, true); // guardian: approve vault as a UGM adapter
        StockpileBasketVault(payable(d.vault)).registerAllGrids(); // asserts each grid yieldToken == basket
    }

    /// @dev Fund the vault with NATIVE BNB (the Flap fee path) then run the proof distribute (zeros minOut;
    ///      the mock router is 1:1 so every leg clears).
    function _fundAndDistribute(address vault) internal returns (uint256 basketMinted) {
        (bool ok,) = payable(vault).call{value: FUND_BNB}("");
        require(ok, "native fund failed");
        basketMinted = StockpileBasketVault(payable(vault)).distribute(new uint256[](3), block.timestamp + 3600);
    }

    /// @dev Recompute a grid's seat-proportional basket share EXACTLY as {StockpileBasketVault._feedGrids}
    ///      does (dust on the LAST grid), reading the live on-chain seats back so the report proves the split.
    function _gridShare(uint256 basketMinted, uint256[] memory seats, uint256 idx) internal pure returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < seats.length; i++) {
            total += seats[i];
        }
        if (idx == seats.length - 1) {
            uint256 allocated;
            for (uint256 i = 0; i < seats.length - 1; i++) {
                allocated += (basketMinted * seats[i]) / total;
            }
            return basketMinted - allocated;
        }
        return (basketMinted * seats[idx]) / total;
    }

    function _report(Deployed memory d, address deployer, uint256 basketMinted) internal view {
        string[3] memory names = _names();
        console2.log("== StockBasket + StockpileBasketVault TESTNET deploy + proof (chainId 97) ==");
        console2.log("StockBasket (SPBT):   ", d.basket);
        console2.log("StockpileBasketVault: ", d.vault);
        console2.log("mockRouter:           ", d.router);
        console2.log("mockUSDT:             ", d.usdt);
        console2.log("ugm(reused):          ", UGM);
        console2.log("treasury:             ", deployer);
        console2.log("commissionBps:        ", uint256(COMMISSION_BPS));
        console2.log("fund (native BNB):    ", FUND_BNB);
        console2.log("basketMinted (shares):", basketMinted);

        console2.log("-- stocks (order == basket order) --");
        for (uint256 i = 0; i < 3; i++) {
            console2.log(names[i], d.stocks[i]);
        }

        // Read live seats back from the UGM to prove the split matches the created grids.
        uint256[] memory seats = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            seats[i] = ITestnetUGM(UGM).gridConfig(d.gridIds[i]).totalSeats;
        }
        console2.log("-- per grid: gridId / seats / basket share (seat-proportional, dust on last) --");
        for (uint256 i = 0; i < 3; i++) {
            console2.log("  gridId:", d.gridIds[i]);
            console2.log("    seats:", seats[i]);
            console2.log("    share:", _gridShare(basketMinted, seats, i));
        }
        console2.log("commission to treasury (approx):", (FUND_BNB * COMMISSION_BPS) / 10_000);
    }
}
