// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {StockpileVaultFactory} from "../src/StockpileVaultFactory.sol";
import {StockpileVault} from "../src/StockpileVault.sol";

interface IUGMAdmin {
    function setAllowedTaxToken(address token, bool allowed) external;
    function setApprovedAdapter(address adapter, bool approved) external;
    function allowedTaxTokens(address token) external view returns (bool);
    function owner() external view returns (address);
}

/// @notice Minimal mintable ERC20 standing in for a "stock" settlement token on testnet.
contract TestStock is ERC20 {
    constructor() ERC20("Stockpile Test Stock", "TSTOCK") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Deploy the Cách B stock-settled Stockpile stack on BSC testnet and wire it up so the vault
///         can flush, then print the vault address to bind into the manifest (no-factory Vault mode).
///           forge script script/DeployStockVault.s.sol --rpc-url $TN --broadcast --legacy
contract DeployStockVault is Script {
    address internal constant UGM = 0xaA40Da4d2F81207196b16C29A9683ABA9d98Cbd1; // testnet UGM

    function run() external {
        require(block.chainid == 97, "run on BSC testnet");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // 1. Deploy a stock settlement token (mintable ERC20) and allow it on the UGM.
        TestStock stock = new TestStock();
        IUGMAdmin(UGM).setAllowedTaxToken(address(stock), true);

        // 2. Deploy the factory (10% default commission; settlement + treasury are per-vault).
        StockpileVaultFactory factory = new StockpileVaultFactory(UGM, 1000);

        // 3. Create a vault + grid: settlementToken = the stock, treasury = deployer (creator).
        address vault = factory.newVault(address(stock), deployer, address(0), "");
        (, uint256 gridId,,) = factory.vaultInfo(vault);

        // 4. Approve the vault as a UGM adapter (deployer == UGM owner) and register it so flush() works.
        IUGMAdmin(UGM).setApprovedAdapter(vault, true);
        StockpileVault(payable(vault)).registerWithGrid(gridId);

        // 5. Seed the vault with some stock to demonstrate a non-zero pendingFlush for the UI.
        stock.mint(vault, 5 ether);

        vm.stopBroadcast();

        console2.log("TestStock (settlement):", address(stock));
        console2.log("StockpileVaultFactory:", address(factory));
        console2.log("StockpileVault (bind this):", vault);
        console2.log("gridId:", gridId);
        console2.log("vault.settlementToken:", StockpileVault(payable(vault)).settlementToken());
        console2.log("vault.pendingFlush:", StockpileVault(payable(vault)).pendingFlush());
        console2.log("vault.commissionBps:", StockpileVault(payable(vault)).commissionBps());
    }
}
