// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";

import {IPortalTypes, IPortalCommonTypes} from "../src/vault/flap/IPortal.sol";
import {IVaultPortal, IVaultPortalTypes} from "../src/vault/flap/IVaultPortal.sol";

import {StockpileBasketVaultFactory, VaultDataV1} from "../src/vault/StockpileBasketVaultFactory.sol";
import {StockpileBasketVaultV2} from "../src/vault/StockpileBasketVaultV2.sol";
import {StockBasket} from "../src/vault/StockBasket.sol";

import {MockMintableERC20} from "../test/vault/mocks/MockMintableERC20.sol";
import {MockV3Router} from "../test/vault/mocks/MockV3Router.sol";
import {VanityHelper} from "../test/vault/lib/VanityHelper.sol";
import {StockConfig} from "./StockConfig.sol";

/// @notice Minimal control surface of the LIVE testnet UGM this script needs (the deployer is its owner).
interface ITestnetUGM {
    function setAllowedTaxToken(address token, bool allowed) external;
    function setApprovedAdapter(address adapter, bool approved) external;
}

/// @title LaunchVaultTokenTestnet — TRUE Flap vault-backed launch on BSC TESTNET (chainId 97)
///
/// @notice Launches a real 7777-vanity Flap V3 tax token through the LIVE testnet Flap
///         `VaultPortal.newTokenV6WithVault` (native-BNB quote), bound to OUR
///         {StockpileBasketVaultFactory} — the true conforming vault-backed path. The VaultPortal calls
///         `factory.newVault(...)`, which deploys + initializes the per-token BeaconProxy vault; the vault
///         is then read back via `VaultPortal.getVault(token).vault`. Post-launch it runs the permissionless
///         `setupMarket()` (deploys the vault's basket + creates its UGM grid — gas MEASURED + logged),
///         binds the grid (`ugm.setApprovedAdapter(vault,true)` as the testnet UGM owner +
///         `vault.registerWithGrid()`), and funds the vault with 0.02 native BNB (the Flap fee path).
///
///         `distribute` is NOT called here: on the live testnet the vault gates it to the Flap Guardian
///         (`_getGuardian()` = 0x76Fa…6950) or an allowlisted keeper — a key WE DO NOT CONTROL. The full
///         guardian-gated distribute (commission skim → real swaps → basket mint → grid feed → redeem) is
///         proven instead on a mainnet fork in test/fork/FlapVaultBackedLaunch.fork.t.sol.
///
///         ── TWO-STEP ORDER (real broadcast) ────────────────────────────────────────────────────────────
///           1. Run DeployVaultFactory (broadcast) → note the logged factory + 7 mock stock addrs.
///           2. Export them and run this script:
///                export FACTORY=0x…  STOCK0=0x… STOCK1=0x… STOCK2=0x… STOCK3=0x…
///           If FACTORY is unset, this script BOOTSTRAPS a throwaway factory + 7 mocks inline (so the DRY-RUN
///           can fully exercise the launch path) — do NOT broadcast the bootstrap path for a real launch.
///
///         ── DRY-RUN (no broadcast — the user broadcasts) ─────────────────────────────────────────────────
///           cd contracts/vault && set -a && . ./.env && set +a   # loads PRIVATE_KEY (never echo the key)
///           forge script script/LaunchVaultTokenTestnet.s.sol --tc LaunchVaultTokenTestnet \
///             --rpc-url https://data-seed-prebsc-1-s1.bnbchain.org:8545
///         Add --broadcast --legacy to actually send.
contract LaunchVaultTokenTestnet is Script, VanityHelper {
    // Live BSC-testnet Flap + Stockpile infrastructure.
    address internal constant VAULT_PORTAL = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
    address internal constant PORTAL = 0x5bEacaF7ABCbB3aB280e80D007FD31fcE26510e9; // CREATE2 deployer for clones
    address internal constant TOKEN_IMPL_V3 = 0xE6Ff967a887084c16D0fD71548CF709542cc1557; // testnet V3 impl
    address internal constant UGM = 0xaA40Da4d2F81207196b16C29A9683ABA9d98Cbd1;
    address internal constant TWBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
    uint24 internal constant WBNB_USDT_FEE = 100;

    // VaultDataV1 config.
    uint16 internal constant GRID_SIZE = 100;
    uint16 internal constant GRID_TAX_BPS = 100;
    uint128 internal constant GRID_INITIAL_PRICE = 1e15;
    uint16 internal constant COMMISSION_BPS = 600;
    uint256 internal constant MIN_INTERVAL = 0;
    /// @dev Native-BNB seeded into the vault (the Flap fee path). Defaults to 0.02 BNB; override with
    ///      env FUND_WEI (e.g. for a dry-run when the deployer wallet holds < 0.02 tBNB).
    uint256 internal constant DEFAULT_FUND = 0.02 ether;

    // Resolved deployment (from env, or bootstrapped for the dry-run).
    address internal factory;
    address[4] internal stocks; // the 4-stock basket (SPCXB, NVDAB, AAPLB, GMEon) — see {StockConfig}
    bool internal bootstrapped;

    function run() external {
        require(block.chainid == 97, "run on BSC testnet (chainId 97)");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // Grind an UNUSED 7777 vanity salt (skip addresses already deployed on testnet). View-only.
        bytes32 salt = _grindUnusedVanity();

        vm.startBroadcast(pk);

        _resolveDeployment(); // env FACTORY/STOCK0-2, or bootstrap a throwaway factory + mocks for the dry-run
        bytes memory vaultData = _vaultData(deployer);

        // 1. Launch through the REAL VaultPortal, bound to our factory (native BNB, quoteAmt 0).
        IVaultPortalTypes.NewTokenV6WithVaultParams memory params = _params(salt, vaultData);
        address token = IVaultPortal(payable(VAULT_PORTAL)).newTokenV6WithVault{value: 0}(params);

        // 2. Resolve the created vault (both ways agree).
        address vault = IVaultPortal(payable(VAULT_PORTAL)).getVault(token).vault;
        require(vault == StockpileBasketVaultFactory(factory).vaultOf(token), "vault mismatch");
        require(vault != address(0), "vault not created");

        // 3. Allowlist the grid tax token (tWBNB) so setupMarket's createGrid succeeds (deployer = UGM owner).
        ITestnetUGM(UGM).setAllowedTaxToken(TWBNB, true);

        // 4. setupMarket (deploy basket + create grid) — MEASURE its gas on the live testnet UGM.
        uint256 g0 = gasleft();
        StockpileBasketVaultV2(payable(vault)).setupMarket();
        uint256 setupGas = g0 - gasleft();

        // 5. Bind the grid: guardian-approve the vault as adapter, then the vault binds itself.
        ITestnetUGM(UGM).setApprovedAdapter(vault, true);
        StockpileBasketVaultV2(payable(vault)).registerWithGrid();

        // 6. Fund the vault with native BNB (the Flap fee path). NOTE: distribute() is intentionally NOT
        //    called — it is Flap-Guardian/keeper-gated on the live testnet (key not controlled here).
        uint256 fund = vm.envOr("FUND_WEI", DEFAULT_FUND);
        (bool ok,) = payable(vault).call{value: fund}("");
        require(ok, "native fund failed");

        vm.stopBroadcast();

        _report(token, vault, setupGas, fund);
    }

    // ── Vanity ─────────────────────────────────────────────────────────────────

    /// @dev Grind a 7777 salt whose predicted clone address (impl=TOKEN_IMPL_V3, deployer=testnet PORTAL)
    ///      is still codeless — a used address is rejected by the Portal with TokenAlreadyStaged.
    function _grindUnusedVanity() internal returns (bytes32 salt) {
        for (uint256 i = 0; i < 128; i++) {
            salt = _findVanitySalt(VanityType.VANITY_7777, TOKEN_IMPL_V3, PORTAL);
            if (_predictAddress(TOKEN_IMPL_V3, salt, PORTAL).code.length == 0) break;
        }
    }

    // ── Deployment resolution (env or bootstrap) ────────────────────────────────

    function _resolveDeployment() internal {
        factory = vm.envOr("FACTORY", address(0));
        if (factory != address(0)) {
            // The 4 basket stocks, in canonical order, from env (STOCK0..STOCK3).
            stocks[0] = vm.envAddress("STOCK0");
            stocks[1] = vm.envAddress("STOCK1");
            stocks[2] = vm.envAddress("STOCK2");
            stocks[3] = vm.envAddress("STOCK3");
            return;
        }
        // Bootstrap: no FACTORY env → deploy a throwaway factory + 4 mock stocks so the dry-run runs
        // the full 4-stock launch path end-to-end.
        bootstrapped = true;
        MockV3Router router = new MockV3Router();
        MockMintableERC20 usdt = new MockMintableERC20("USDT-T", "USDT-T", 18);
        stocks[0] = address(new MockMintableERC20("SPCXB-T", "SPCXB-T", 18));
        stocks[1] = address(new MockMintableERC20("NVDAB-T", "NVDAB-T", 18));
        stocks[2] = address(new MockMintableERC20("AAPLB-T", "AAPLB-T", 18));
        stocks[3] = address(new MockMintableERC20("GMEon-T", "GMEon-T", 18));
        factory =
            address(new StockpileBasketVaultFactory(TWBNB, address(usdt), UGM, address(router), WBNB_USDT_FEE));
    }

    // ── VaultDataV1: 4-stock basket (fees + weights from StockConfig; weights sum to 10_000) ────

    function _vaultData(address treasury) internal view returns (bytes memory) {
        uint24[4] memory F = StockConfig.fees();
        uint16[4] memory W = StockConfig.weights();
        address[] memory st = new address[](4);
        uint24[] memory fees = new uint24[](4);
        uint16[] memory w = new uint16[](4);
        for (uint256 i = 0; i < 4; i++) {
            st[i] = stocks[i];
            fees[i] = F[i];
            w[i] = W[i];
        }
        VaultDataV1 memory d = VaultDataV1({
            gridSize: GRID_SIZE,
            gridTaxRateBps: GRID_TAX_BPS,
            gridInitialPrice: GRID_INITIAL_PRICE,
            commissionBps: COMMISSION_BPS,
            treasury: treasury,
            minInterval: MIN_INTERVAL,
            stocksData: abi.encode(st, fees, w)
        });
        return abi.encode(d);
    }

    function _params(bytes32 salt, bytes memory vaultData)
        internal
        view
        returns (IVaultPortalTypes.NewTokenV6WithVaultParams memory p)
    {
        p = IVaultPortalTypes.NewTokenV6WithVaultParams({
            name: "Stockpile Basket",
            symbol: "SPBK",
            meta: "",
            dexThresh: IPortalCommonTypes.DexThreshType.FOUR_FIFTHS,
            salt: salt,
            migratorType: IPortalTypes.MigratorType.V2_MIGRATOR,
            quoteToken: address(0), // native BNB → fee arrives as native BNB
            quoteAmt: 0,
            permitData: "",
            extensionID: bytes32(0),
            extensionData: "",
            dexId: IPortalTypes.DEXId.DEX0,
            lpFeeProfile: IPortalTypes.V3LPFeeProfile.LP_FEE_PROFILE_STANDARD,
            buyTaxRate: 500,
            sellTaxRate: 500,
            taxDuration: uint64(100 * 365 days),
            antiFarmerDuration: uint64(1 days),
            mktBps: 10000, // 100% of the market split → our vault
            deflationBps: 0,
            dividendBps: 0,
            lpBps: 0,
            minimumShareBalance: 0,
            dividendToken: address(0),
            commissionReceiver: address(0),
            tokenVersion: IPortalTypes.TokenVersion.TOKEN_TAXED_V3,
            vaultFactory: factory,
            vaultData: vaultData
        });
    }

    function _report(address token, address vault, uint256 setupGas, uint256 fund) internal view {
        StockpileBasketVaultV2 v = StockpileBasketVaultV2(payable(vault));
        console2.log("== LaunchVaultTokenTestnet (chainId 97) ==");
        if (bootstrapped) console2.log("(BOOTSTRAPPED throwaway factory + mocks -- set FACTORY/STOCK0-2 for a real launch)");
        console2.log("factory:      ", factory);
        console2.log("token (7777): ", token);
        console2.log("vault:        ", vault);
        console2.log("basket:       ", v.basket());
        console2.log("gridId:       ", v.gridId());
        console2.log("stocks in basket:", StockBasket(v.basket()).stocksLength());
        console2.log("setupMarket() gas used:", setupGas);
        console2.log("funded (native BNB, wei):", fund);
        console2.log("distribute(): intentionally SKIPPED (Flap-Guardian/keeper-gated on live testnet).");
    }
}
