// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/proxy/ERC1967/ERC1967Proxy.sol";

import {StockpileVault} from "../src/StockpileVault.sol";
import {VaultUISchema} from "../src/flap/IVaultSchemasV1.sol";
import {MockUGM} from "./mocks/MockUGM.sol";
import {MockWBNB} from "./mocks/MockWBNB.sol";

/// @title StockpileVault unit tests (Cách B — ERC20 stock-settled vault)
/// @notice Exercises the rewritten vault behind an ERC1967 proxy. The vault no
///         longer wraps native BNB or reads a tax rate: its settlement token is a
///         plain ERC20 ("stock") that accrues on the vault by ordinary transfer,
///         and `flush()` skims a flat `commissionBps` to the treasury before
///         forwarding the remainder into the Stockpile grid (the MockUGM sink).
contract StockpileVaultTest is Test {
    // Chain 56 (BNB Chain) so VaultBase._getGuardian() resolves the fixed guardian
    // below instead of reverting UnsupportedChain on foundry's default 31337.
    uint256 internal constant CHAIN_ID = 56;
    address internal constant GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;

    // Grid the vault feeds. Bound into `assetHash` and re-derived by
    // registerWithGrid(); must be non-zero so the UGM's `assetToGrid` wiring
    // (0 == unregistered) reads as registered after binding.
    uint256 internal constant GRID_ID = 7;

    MockUGM internal ugm; // grid sink (UnifiedGridManager stand-in)
    MockWBNB internal stock; // the ERC20 "stock" settlement token (mintable)
    address internal treasury;
    address internal taxTokenRef; // reference-only tax token metadata
    StockpileVault internal impl;

    function setUp() public {
        vm.chainId(CHAIN_ID);

        ugm = new MockUGM();
        stock = new MockWBNB();
        treasury = makeAddr("treasury");
        taxTokenRef = makeAddr("taxTokenRef");
        impl = new StockpileVault();

        // Fund this test contract so it can mint stock (deposit, up to the fuzz
        // ceiling of 1,000,000 ether) and send native BNB.
        vm.deal(address(this), 2_000_000 ether);
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    /// @notice Deploy a fresh proxy vault (empty init) then initialize it, so the
    ///         proxy address is known before `assetHash` is derived from it.
    function _deployVault(uint16 commissionBps) internal returns (StockpileVault vault, bytes32 assetHash) {
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
        vault = StockpileVault(payable(address(proxy)));
        assetHash = keccak256(abi.encode("StockpileVault", address(vault), GRID_ID));
        vault.initialize(taxTokenRef, address(ugm), assetHash, address(stock), commissionBps, treasury);
    }

    /// @notice Approve the vault as a UGM adapter and bind it to its grid so flush() delivers.
    function _makeFlushable(StockpileVault vault) internal {
        ugm.setApprovedAdapter(address(vault), true);
        vault.registerWithGrid(GRID_ID);
    }

    /// @notice Mint `amount` stock and transfer it to `vault`, simulating tax arrival (no hook).
    function _fundStock(StockpileVault vault, uint256 amount) internal {
        stock.deposit{value: amount}();
        stock.transfer(address(vault), amount);
    }

    // ── 1. initialize() sets every configuration field ──────────────────────

    function test_Initialize_SetsFields() public {
        (StockpileVault vault, bytes32 assetHash) = _deployVault(500);

        assertEq(vault.taxToken(), taxTokenRef, "taxToken");
        assertEq(vault.ugm(), address(ugm), "ugm");
        assertEq(vault.assetHash(), assetHash, "assetHash");
        assertEq(vault.settlementToken(), address(stock), "settlementToken");
        assertEq(vault.commissionBps(), 500, "commissionBps");
        assertEq(vault.treasury(), treasury, "treasury");
        // Rescue redirect defaults off.
        assertFalse(vault.autoForwardEnabled(), "autoForward off by default");
        assertEq(vault.forwardAddress(), address(0), "forwardAddress unset");
    }

    // ── 2. flush(): skim commission to treasury, forward net into the grid ───

    function test_Flush_SkimsCommissionAndForwardsNet() public {
        uint16 commissionBps = 500; // 5%
        (StockpileVault vault,) = _deployVault(commissionBps);
        _makeFlushable(vault);

        uint256 gross = 1_000 ether;
        _fundStock(vault, gross);
        assertEq(vault.pendingFlush(), gross, "pendingFlush == funded stock");

        uint256 fee = (gross * commissionBps) / 10_000; // 50 ether
        uint256 net = gross - fee; // 950 ether

        uint256 forwarded = vault.flush();

        assertEq(forwarded, net, "flush returns net forwarded");
        assertEq(stock.balanceOf(treasury), fee, "treasury received commission");
        assertEq(ugm.lastYieldToken(), address(stock), "grid yield token is the stock");
        assertEq(ugm.lastYieldAmount(), net, "grid received net");
        assertEq(ugm.receiveYieldCallCount(), 1, "grid pushed exactly once");
        assertEq(stock.balanceOf(address(ugm)), net, "UGM pulled net in");
        assertEq(stock.balanceOf(address(vault)), 0, "vault stock drained to zero");
        assertEq(vault.pendingFlush(), 0, "nothing pending after flush");
    }

    // ── 3. flush() with a zero balance returns 0 and touches nothing ─────────

    function test_Flush_ZeroBalanceReturnsZeroNoop() public {
        (StockpileVault vault,) = _deployVault(500);
        _makeFlushable(vault);

        assertEq(vault.pendingFlush(), 0, "starts empty");
        uint256 forwarded = vault.flush();

        assertEq(forwarded, 0, "empty flush returns zero");
        assertEq(ugm.receiveYieldCallCount(), 0, "grid never called");
        assertEq(stock.balanceOf(treasury), 0, "no commission on empty flush");
    }

    // ── 4. flush() before registration is rejected by the UGM adapter gate ───

    function test_Flush_BeforeRegistrationReverts() public {
        (StockpileVault vault,) = _deployVault(500);
        // Deliberately NOT registered: assetToGrid[assetHash] == 0 → UGM reverts "asset".
        _fundStock(vault, 100 ether);

        vm.expectRevert(bytes("asset"));
        vault.flush();
    }

    // ── 5. pendingFlush() mirrors the vault's stock balance ──────────────────

    function test_PendingFlush_EqualsStockBalance() public {
        (StockpileVault vault,) = _deployVault(500);

        assertEq(vault.pendingFlush(), 0, "empty");
        _fundStock(vault, 42 ether);
        assertEq(vault.pendingFlush(), 42 ether, "pendingFlush tracks stock balance");
        assertEq(vault.pendingFlush(), stock.balanceOf(address(vault)), "== balanceOf(vault)");
    }

    // ── 6. registerWithGrid() cryptographically binds the grid id ────────────

    function test_RegisterWithGrid_WrongGridReverts() public {
        (StockpileVault vault,) = _deployVault(500);
        ugm.setApprovedAdapter(address(vault), true);

        vm.expectRevert(bytes(unicode"Grid mismatch / 网格不匹配"));
        vault.registerWithGrid(GRID_ID + 1);
    }

    // ── 7. receive(): holds native BNB by default ────────────────────────────

    function test_Receive_HoldsBnbByDefault() public {
        (StockpileVault vault,) = _deployVault(500);

        (bool ok,) = address(vault).call{value: 3 ether}("");
        assertTrue(ok, "receive() should not revert");

        assertEq(address(vault).balance, 3 ether, "vault holds the BNB");
        assertEq(stock.balanceOf(address(vault)), 0, "no stock minted - BNB is not the tax path");
        assertEq(vault.pendingFlush(), 0, "nothing accrued for flush()");
    }

    // ── 8. receive(): auto-forwards native BNB once the guardian arms it ──────

    function test_Receive_AutoForwardsWhenArmed() public {
        (StockpileVault vault,) = _deployVault(500);
        address dest = makeAddr("forwardDest");

        vm.prank(GUARDIAN);
        vault.setAutoForward(true, dest);
        assertTrue(vault.autoForwardEnabled(), "auto-forward armed");
        assertEq(vault.forwardAddress(), dest, "forwardAddress set");

        (bool ok,) = address(vault).call{value: 2 ether}("");
        assertTrue(ok, "receive() should not revert");

        assertEq(dest.balance, 2 ether, "BNB forwarded to destination");
        assertEq(address(vault).balance, 0, "vault retained nothing");
    }

    // ── 9. Emergency withdrawals are Guardian-gated and recover funds ────────

    function test_EmergencyWithdrawToken_RevertsForNonGuardian() public {
        (StockpileVault vault,) = _deployVault(500);
        _fundStock(vault, 3 ether);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(bytes(unicode"Only Guardian / 仅限 Guardian"));
        vault.emergencyWithdrawToken(address(stock), attacker);
    }

    function test_EmergencyWithdrawToken_SucceedsForGuardian() public {
        (StockpileVault vault,) = _deployVault(500);
        _fundStock(vault, 3 ether);
        assertEq(stock.balanceOf(address(vault)), 3 ether, "vault holds stuck stock");

        address recipient = makeAddr("tokenRecipient");
        vm.prank(GUARDIAN);
        vault.emergencyWithdrawToken(address(stock), recipient);

        assertEq(stock.balanceOf(recipient), 3 ether, "guardian recovered stock");
        assertEq(stock.balanceOf(address(vault)), 0, "vault stock drained");
    }

    function test_EmergencyWithdrawNative_RevertsForNonGuardian() public {
        (StockpileVault vault,) = _deployVault(500);
        vm.deal(address(vault), 5 ether);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(bytes(unicode"Only Guardian / 仅限 Guardian"));
        vault.emergencyWithdrawNative(attacker);
    }

    function test_EmergencyWithdrawNative_SucceedsForGuardian() public {
        (StockpileVault vault,) = _deployVault(500);
        vm.deal(address(vault), 5 ether);

        address recipient = makeAddr("nativeRecipient");
        vm.prank(GUARDIAN);
        vault.emergencyWithdrawNative(recipient);

        assertEq(recipient.balance, 5 ether, "guardian recovered native BNB");
        assertEq(address(vault).balance, 0, "vault native drained");
    }

    // ── 10. setAutoForward: Guardian-only + rejects a zero destination ───────

    function test_SetAutoForward_RevertsForNonGuardian() public {
        (StockpileVault vault,) = _deployVault(500);
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(bytes(unicode"Only Guardian / 仅限 Guardian"));
        vault.setAutoForward(true, makeAddr("dest"));
    }

    function test_SetAutoForward_EnableWithZeroDestReverts() public {
        (StockpileVault vault,) = _deployVault(500);
        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Zero address / 零地址"));
        vault.setAutoForward(true, address(0));
    }

    // ── 11. Commission arithmetic holds across the whole input space ─────────

    /// @dev Property: for ANY commission rate and gross balance, flush() skims
    ///      exactly `gross * commissionBps / 10000` to the treasury and forwards
    ///      the remainder into the grid — the vault is always fully drained.
    function testFuzz_Commission_FeeAndNet(uint16 commissionBps, uint96 amount) public {
        commissionBps = uint16(bound(commissionBps, 0, 1_000)); // MAX_COMMISSION_BPS = 10% (audit v5 F8)
        uint256 gross = bound(amount, 1, 1_000_000 ether);

        (StockpileVault vault,) = _deployVault(commissionBps);
        _makeFlushable(vault);
        _fundStock(vault, gross);

        uint256 fee = (gross * commissionBps) / 10_000;
        uint256 net = gross - fee;

        uint256 forwarded = vault.flush();

        assertEq(forwarded, net, "flush returns net");
        assertEq(fee + net, gross, "fee + net == gross (conservation)");
        assertEq(stock.balanceOf(treasury), fee, "treasury got exactly the fee");
        assertEq(stock.balanceOf(address(vault)), 0, "vault fully drained");
        if (net > 0) {
            assertEq(ugm.lastYieldAmount(), net, "grid received net");
            assertEq(ugm.lastYieldToken(), address(stock), "grid token is stock");
        }
    }

    // ── 12. vaultUISchema(): three reads then the single flush() write ───────

    function test_VaultUISchema_Shape() public view {
        VaultUISchema memory schema = impl.vaultUISchema();

        assertEq(schema.vaultType, "StockpileVault", "vaultType");
        assertEq(schema.methods.length, 4, "4 methods");

        assertEq(schema.methods[0].name, "pendingFlush");
        assertFalse(schema.methods[0].isWriteMethod, "pendingFlush is a read");
        assertEq(schema.methods[1].name, "commissionBps");
        assertFalse(schema.methods[1].isWriteMethod, "commissionBps is a read");
        assertEq(schema.methods[2].name, "settlementToken");
        assertFalse(schema.methods[2].isWriteMethod, "settlementToken is a read");

        // [3] flush — the single write: no inputs, no outputs, no approvals.
        assertEq(schema.methods[3].name, "flush");
        assertTrue(schema.methods[3].isWriteMethod, "last method (flush) is the write");
        assertEq(schema.methods[3].inputs.length, 0, "flush no inputs");
        assertEq(schema.methods[3].outputs.length, 0, "flush no outputs");
        assertEq(schema.methods[3].approvals.length, 0, "flush needs no approval");
    }
}
