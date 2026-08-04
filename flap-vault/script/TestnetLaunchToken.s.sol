// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {IPortal, IPortalTypes, IPortalCommonTypes} from "../src/flap/IPortal.sol";

/// @notice Launch a REGULAR Flap tax token on BSC testnet (chainId 97) through the Flap regular
///         Portal (`newTokenV6`), whose tax FEE beneficiary is our already-deployed standalone
///         StockpileVault. Because quoteToken == address(0) (native BNB), the tax stream arrives
///         at the beneficiary as NATIVE BNB — exactly what the vault's receive() expects.
///
///         DRY-RUN (no broadcast):
///           cd contracts/vault && set -a && . ./.env && set +a
///           forge script script/TestnetLaunchToken.s.sol --tc TestnetLaunchToken \
///             --rpc-url https://data-seed-prebsc-1-s1.bnbchain.org:8545
///         Add --broadcast (and --legacy) to actually send.
contract TestnetLaunchToken is Script {
    // Testnet regular Portal — also the CREATE2 deployer for newTokenV6 clones.
    address internal constant PORTAL = 0x5bEacaF7ABCbB3aB280e80D007FD31fcE26510e9;
    // Testnet V3 taxed-token implementation that a TOKEN_TAXED_V3 launch clones.
    address internal constant TOKEN_IMPL_V3 = 0xE6Ff967a887084c16D0fD71548CF709542cc1557;
    // OUR fee recipient: standalone StockpileVault (takes native BNB, splits into 7 grids).
    address internal constant BENEFICIARY = 0x986F7170983d70c4b03FaD5fEA96393766d44C8b;

    // Fresh 7777-vanity salt (grinded; predicted token != the already-used 0x8AEa..7777).
    bytes32 internal constant VANITY_SALT = bytes32(uint256(1110659)); // 0x10f283
    address internal constant EXPECTED = 0x77C0ca4AFB2823DDe85B92e30C7468Ea75bE7777;

    function _params(bytes32 salt) internal pure returns (IPortalTypes.NewTokenV6Params memory p) {
        p = IPortalTypes.NewTokenV6Params({
            name: "Stockpile Stock",
            symbol: "SPST",
            meta: "",
            dexThresh: IPortalCommonTypes.DexThreshType.FOUR_FIFTHS,
            salt: salt,
            migratorType: IPortalTypes.MigratorType.V2_MIGRATOR, // tax token MUST use a V2 migrator
            quoteToken: address(0), // native BNB reserve -> tax paid to beneficiary as native BNB
            quoteAmt: 0, // no initial dev buy
            beneficiary: BENEFICIARY, // <-- tax fees go here (our StockpileVault)
            permitData: "",
            extensionID: bytes32(0),
            extensionData: "",
            dexId: IPortalTypes.DEXId.DEX0, // PancakeSwap on BSC
            lpFeeProfile: IPortalTypes.V3LPFeeProfile.LP_FEE_PROFILE_STANDARD,
            buyTaxRate: 500, // 5%
            sellTaxRate: 500, // 5%
            taxDuration: uint64(100 * 365 days),
            antiFarmerDuration: uint64(1 days),
            mktBps: 10000, // 100% of the tax split -> beneficiary (our vault)
            deflationBps: 0,
            dividendBps: 0,
            lpBps: 0,
            minimumShareBalance: 0,
            dividendToken: address(0), // unused (dividendBps == 0)
            commissionReceiver: address(0), // no extra commission
            tokenVersion: IPortalTypes.TokenVersion.TOKEN_TAXED_V3
        });
    }

    function run() external {
        require(block.chainid == 97, "must run on BSC testnet (chainId 97)");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        console2.log("Portal (create2 deployer):", PORTAL);
        console2.log("token impl (TOKEN_TAXED_V3):", TOKEN_IMPL_V3);
        console2.log("beneficiary (StockpileVault):", BENEFICIARY);
        console2.log("expected 7777 token:", EXPECTED);

        vm.startBroadcast(pk);
        address token = IPortal(PORTAL).newTokenV6{value: 0}(_params(VANITY_SALT));
        vm.stopBroadcast();

        console2.log("LAUNCHED token:", token);
        require(token == EXPECTED, "launched token != expected 7777 vanity");
        bytes20 b = bytes20(token);
        require(b[18] == 0x77 && b[19] == 0x77, "token does not end in 7777");
        console2.log("OK: token ends in 7777 and matches prediction");
    }
}
