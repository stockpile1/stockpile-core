// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {MultiStockVault} from "../src/MultiStockVault.sol";
import {MockMintableERC20} from "../test/mocks/MockMintableERC20.sol";
import {MockV3Router} from "../test/mocks/MockV3Router.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/// @dev The UGM's grid-creation params (mirrors core GridTypes.CreateGridParams — field order/types must match).
struct CreateGridParams {
    uint32 totalSeats;
    uint16 taxRateBps;
    uint32 forfeitureDuration;
    address taxToken; // must be guardian-allowed (setAllowedTaxToken)
    address yieldToken;
    uint128 initialPrice;
}

/// @dev The UGM control surface this script needs beyond MultiStockVault's IGridSink.
///      On testnet the deployer IS the UGM owner+guardian, so it may call the guardian setters directly.
interface ITestnetUGM {
    function createGrid(CreateGridParams calldata p) external returns (uint256 gridId);
    function setAllowedTaxToken(address token, bool allowed) external;
    function setApprovedAdapter(address adapter, bool approved) external;
    function gridCount() external view returns (uint256);
}

interface IWBNBDeposit {
    function deposit() external payable;
}

/// @title Deploy + prove MultiStockVault on BSC TESTNET (chainId 97) — self-contained mock swap path.
///
/// @notice The 7 real stock tokens and their PancakeSwap V3 pools DO NOT exist on testnet, so this script
///         stands up a hermetic, deterministic swap path: 7 mintable mock stocks, a mock USDT, and a
///         MockV3Router that mints proceeds 1:1 (no pre-fund). It then runs the WHOLE money path live:
///         allowlist each stock → create a grid per stock (yieldToken == stock) → deploy the vault →
///         approve it as adapter → registerAllGrids → fund it with real tWBNB → distribute().
///
///         The live UGM `0xaA40…Cbd1` is REUSED (the deployer is its owner+guardian). Grid ids are captured
///         from each createGrid return (not assumed), then baked into the vault so its derived assetHashes
///         match. Everything runs in ONE broadcast because the deployer is also the UGM owner.
///
///         Run (simulate first — DROP --broadcast — then broadcast):
///           cd contracts/vault
///           set -a && . ./.env && set +a        # loads PRIVATE_KEY + RPC (never echo the key)
///           forge script script/DeployMultiStockVaultTestnet.s.sol --tc DeployMultiStockVaultTestnet \
///             --rpc-url "$RPC" --broadcast --legacy
///
///         Requires env PRIVATE_KEY (the testnet deployer/guardian). Testnet-only mocks — never for mainnet.
contract DeployMultiStockVaultTestnet is Script {
    // ── Live BSC-testnet infrastructure (verified) ───────────────────────────────
    address internal constant UGM = 0xaA40Da4d2F81207196b16C29A9683ABA9d98Cbd1;
    address internal constant TWBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd; // WETH9-style wrapper (deposit())

    // ── Vault config ─────────────────────────────────────────────────────────────
    uint24 internal constant WBNB_USDT_FEE = 100; // mock router ignores fee tiers; kept for parity with mainnet
    uint16 internal constant COMMISSION_BPS = 600; // 6%
    uint256 internal constant MIN_INTERVAL = 0; // no time-gate on testnet so repeat distributes are easy
    uint256 internal constant FUND_WBNB = 0.05 ether; // tWBNB seeded into the vault for the proof distribute

    function run() external {
        require(block.chainid == 97, "run on BSC testnet (chainId 97)");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        (address[7] memory stocks, address usdt, address router) = _deployMocks();
        uint256[7] memory gridIds = _allowlistAndCreateGrids(stocks);
        MultiStockVault vault = _newVault(usdt, router, deployer, stocks, gridIds);
        ITestnetUGM(UGM).setApprovedAdapter(address(vault), true);
        vault.registerAllGrids();
        IWBNBDeposit(TWBNB).deposit{value: FUND_WBNB}();
        IERC20(TWBNB).transfer(address(vault), FUND_WBNB);
        uint256[7] memory bought = vault.distribute(_zeros(), block.timestamp + 3600);
        vm.stopBroadcast();

        _report(address(vault), router, usdt, deployer, stocks, gridIds, bought);
    }

    // ── Helpers (kept small so no single stack frame overflows under the non-via-ir optimizer) ──

    function _names() internal pure returns (string[7] memory n) {
        n[0] = "SPCXB";
        n[1] = "QQQB";
        n[2] = "NVDAB";
        n[3] = "SPYB";
        n[4] = "TSLAB";
        n[5] = "AAPLB";
        n[6] = "XAUt";
    }

    function _zeros() internal pure returns (uint256[7] memory z) {}

    function _deployMocks() internal returns (address[7] memory stocks, address usdt, address router) {
        string[7] memory names = _names();
        for (uint256 i = 0; i < 7; i++) {
            stocks[i] = address(new MockMintableERC20(names[i], names[i], 18));
        }
        usdt = address(new MockMintableERC20("USDT", "USDT", 18));
        router = address(new MockV3Router());
    }

    function _allowlistAndCreateGrids(address[7] memory stocks) internal returns (uint256[7] memory gridIds) {
        ITestnetUGM ugm = ITestnetUGM(UGM);
        for (uint256 i = 0; i < 7; i++) {
            ugm.setAllowedTaxToken(stocks[i], true); // stock is the grid taxToken → must be allowlisted
            gridIds[i] = ugm.createGrid(
                CreateGridParams({
                    totalSeats: 16,
                    taxRateBps: 100,
                    forfeitureDuration: 0,
                    taxToken: stocks[i],
                    yieldToken: stocks[i],
                    initialPrice: 1e15
                })
            );
        }
    }

    function _newVault(
        address usdt,
        address router,
        address treasury,
        address[7] memory stocks,
        uint256[7] memory gridIds
    ) internal returns (MultiStockVault) {
        uint24[7] memory stockFees = [uint24(2500), 100, 2500, 100, 2500, 2500, 2500];
        uint16[7] memory weights = [uint16(1429), 1429, 1429, 1429, 1429, 1429, 1426]; // sums to 10_000
        return new MultiStockVault(
            TWBNB,
            usdt,
            UGM,
            router,
            WBNB_USDT_FEE,
            treasury,
            COMMISSION_BPS,
            MIN_INTERVAL,
            MultiStockVault.BasketParams({stocks: stocks, gridIds: gridIds, stockFees: stockFees, weightsBps: weights})
        );
    }

    function _report(
        address vault,
        address router,
        address usdt,
        address treasury,
        address[7] memory stocks,
        uint256[7] memory gridIds,
        uint256[7] memory bought
    ) internal view {
        string[7] memory names = _names();
        console2.log("== MultiStockVault TESTNET deploy + proof (chainId 97) ==");
        console2.log("vault:        ", vault);
        console2.log("mockRouter:   ", router);
        console2.log("mockUSDT:     ", usdt);
        console2.log("ugm(reused):  ", UGM);
        console2.log("treasury:     ", treasury);
        console2.log("commissionBps:", uint256(COMMISSION_BPS));
        console2.log("-- per leg: name / stock / gridId / bought (into grid) --");
        for (uint256 i = 0; i < 7; i++) {
            console2.log(names[i]);
            console2.log("  stock: ", stocks[i]);
            console2.log("  gridId:", gridIds[i]);
            console2.log("  bought:", bought[i]);
        }
        console2.log("tWBNB commission to treasury (approx):", (FUND_WBNB * COMMISSION_BPS) / 10_000);
    }
}
