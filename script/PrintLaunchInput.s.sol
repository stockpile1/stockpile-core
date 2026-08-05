// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {VaultDataV1} from "../src/vault/StockpileBasketVaultFactory.sol";
import {StockConfig} from "./StockConfig.sol";

/// @title PrintLaunchInput — print every value the Flap "Custom Vault" launch form needs
///
/// @notice The launch form is generated from the factory's `vaultDataSchema()`, so it renders the six
///         scalar `VaultDataV1` fields as plain inputs — but `stocksData` is a raw `bytes` blob it cannot
///         build for you. This prints it as ONE continuous hex string, ready to select and paste, plus the
///         fully-encoded `vaultData` tuple for anyone launching programmatically instead of through the UI.
///
/// @dev    Read-only: no broadcast, no `PRIVATE_KEY` needed.
///
///           # mainnet basket (StockConfig — the single source of truth)
///           forge script script/PrintLaunchInput.s.sol
///
///           # testnet basket (defaults to the mocks deployed 2026-08-05)
///           forge script script/PrintLaunchInput.s.sol --sig 'testnet()'
///
///           # override any leg, and/or the scalars
///           STOCK0=0x… STOCK1=0x… STOCK2=0x… STOCK3=0x… \
///           GRID_SIZE=144 COMMISSION_BPS=300 TREASURY=0x… \
///             forge script script/PrintLaunchInput.s.sol --sig 'testnet()'
///
///         The stock set comes from {StockConfig} on mainnet, so this script and the deploy scripts can
///         never disagree about which four tokens the basket holds.
contract PrintLaunchInput is Script {
    // Testnet mocks from the 2026-08-05 deploy; override with STOCK0..STOCK3.
    address internal constant T_SPCXB = 0xF46fa89166ee71D9d9704266DeEE18C958dA6e57;
    address internal constant T_NVDAB = 0x338cB5799B098f14b5375503A2cf7149d59188AC;
    address internal constant T_AAPLB = 0xFC72F4bFa7ED7735E893704608eBb477034bFaE4;
    address internal constant T_GMEON = 0x6787167b8722f6e86a25AF0bc1c7Bc77B362188d;

    /// @notice Print the MAINNET basket (the four real stocks in {StockConfig}).
    function run() external view {
        address[4] memory s = StockConfig.mainnetStocks();
        uint24[4] memory f = StockConfig.fees();
        uint16[4] memory w = StockConfig.weights();
        _print("MAINNET (chainId 56) - StockConfig", _dyn(s), _dynFees(f), _dynWeights(w));
    }

    /// @notice Print the TESTNET basket (mock stocks; override any leg with STOCK0..STOCK3).
    function testnet() external view {
        address[] memory s = new address[](4);
        s[0] = vm.envOr("STOCK0", T_SPCXB);
        s[1] = vm.envOr("STOCK1", T_NVDAB);
        s[2] = vm.envOr("STOCK2", T_AAPLB);
        s[3] = vm.envOr("STOCK3", T_GMEON);

        uint24[] memory f = new uint24[](4);
        uint16[] memory w = new uint16[](4);
        for (uint256 i = 0; i < 4; i++) {
            f[i] = 2500;
            w[i] = 2500;
        }
        _print("TESTNET (chainId 97) - mock stocks", s, f, w);
    }

    // ── Internals ─────────────────────────────────────────────────────────────

    function _print(string memory label, address[] memory stocks, uint24[] memory fees, uint16[] memory weights)
        internal
        view
    {
        // Fail loudly here rather than letting a bad blob through: the six scalar fields are validated at
        // launch by initialize(), but stocksData is stored OPAQUE and only decoded later in setupMarket().
        // A malformed blob therefore launches fine and only fails afterwards, leaving a live token whose
        // vault has no basket and no grid.
        require(stocks.length == fees.length && stocks.length == weights.length, "array length mismatch");
        uint256 sum;
        for (uint256 i = 0; i < weights.length; i++) {
            require(stocks[i] != address(0), "zero stock");
            for (uint256 j = i + 1; j < stocks.length; j++) {
                require(stocks[i] != stocks[j], "duplicate stock");
            }
            sum += weights[i];
        }
        require(sum == 10_000, "weights must sum to 10000");

        uint16 gridSize = uint16(vm.envOr("GRID_SIZE", uint256(100)));
        uint16 gridTaxRateBps = uint16(vm.envOr("GRID_TAX_BPS", uint256(100)));
        uint128 gridInitialPrice = uint128(vm.envOr("GRID_INITIAL_PRICE", uint256(1e15)));
        uint16 commissionBps = uint16(vm.envOr("COMMISSION_BPS", uint256(600)));
        address treasury = vm.envOr("TREASURY", address(0));
        uint256 minInterval = vm.envOr("MIN_INTERVAL", uint256(3600));

        require(gridSize >= 4 && gridSize <= 1024, "gridSize out of 4..1024");
        require(gridTaxRateBps >= 10 && gridTaxRateBps <= 1000, "gridTaxRateBps out of 10..1000");
        require(gridInitialPrice > 0, "gridInitialPrice must be > 0");
        require(commissionBps <= 1000, "commissionBps > 1000");
        require(minInterval <= 30 days, "minInterval > 30 days");

        bytes memory stocksData = abi.encode(stocks, fees, weights);

        console2.log("");
        console2.log("=====================================================================");
        console2.log(label);
        console2.log("=====================================================================");
        console2.log("");
        console2.log("-- paste these into the six scalar fields --");
        console2.log("  gridSize          ", gridSize);
        console2.log("  gridTaxRateBps    ", gridTaxRateBps);
        console2.log("  gridInitialPrice  ", gridInitialPrice);
        console2.log("  commissionBps     ", commissionBps);
        console2.log("  treasury          ", treasury == address(0) ? "<SET TREASURY=0x...>" : vm.toString(treasury));
        console2.log("  minInterval       ", minInterval);
        console2.log("");

        console2.log("-- basket legs --");
        for (uint256 i = 0; i < stocks.length; i++) {
            console2.log(
                string.concat("  [", vm.toString(i), "] ", vm.toString(stocks[i])),
                string.concat("fee=", vm.toString(uint256(fees[i])), " weight=", vm.toString(uint256(weights[i])))
            );
        }
        if (stocks.length > 4) {
            console2.log("");
            console2.log("  WARNING: more than 4 legs. scheduleDistribute() will revert 'Too many legs' --");
            console2.log("  the callback no longer fits the Trigger Service's 2,000,000 gas budget, so this");
            console2.log("  basket can only be driven by a Guardian/keeper, not permissionlessly.");
        }
        console2.log("");

        console2.log("-- stocksData (ONE line, copy the whole thing incl. 0x) --");
        console2.logBytes(stocksData);
        console2.log("");

        console2.log("-- vaultData (only if you launch programmatically, not via the form) --");
        console2.logBytes(
            abi.encode(
                VaultDataV1({
                    gridSize: gridSize,
                    gridTaxRateBps: gridTaxRateBps,
                    gridInitialPrice: gridInitialPrice,
                    commissionBps: commissionBps,
                    treasury: treasury,
                    minInterval: minInterval,
                    stocksData: stocksData
                })
            )
        );
        console2.log("");
    }

    function _dyn(address[4] memory a) internal pure returns (address[] memory out) {
        out = new address[](4);
        for (uint256 i = 0; i < 4; i++) {
            out[i] = a[i];
        }
    }

    function _dynFees(uint24[4] memory a) internal pure returns (uint24[] memory out) {
        out = new uint24[](4);
        for (uint256 i = 0; i < 4; i++) {
            out[i] = a[i];
        }
    }

    function _dynWeights(uint16[4] memory a) internal pure returns (uint16[] memory out) {
        out = new uint16[](4);
        for (uint256 i = 0; i < 4; i++) {
            out[i] = a[i];
        }
    }
}
