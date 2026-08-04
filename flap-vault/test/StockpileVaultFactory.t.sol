// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {StockpileVaultFactory} from "../src/StockpileVaultFactory.sol";
import {StockpileVault} from "../src/StockpileVault.sol";
import {VaultDataSchema} from "../src/flap/IVaultSchemasV1.sol";

import {MockWBNB} from "./mocks/MockWBNB.sol";
import {MockUGM} from "./mocks/MockUGM.sol";

/// @title StockpileVaultFactory unit tests (Cách B — stock-settled)
/// @notice Exercises the NEW beacon-backed factory: constructor wiring, the
///         PERMISSIONLESS `newVault` create path (grid creation with the stock as
///         tax==yield token, proxy deploy + init, registry, events, vaultData
///         decode/clamping), the approval bridge (`pendingApproval` /
///         `registerWithGrid`), the ERC20 stock money path (`flush`), the
///         guardian-only beacon administration + creator-revenue sweep, and the
///         discovery surface (`factorySpecVersion` / `isQuoteTokenSupported`).
contract StockpileVaultFactoryTest is Test {
    // Chain 56 (BNB Chain) so `_getGuardian()` resolves to its fixed address
    // instead of reverting UnsupportedChain (default foundry chainid 31337).
    uint256 internal constant CHAIN_ID = 56;
    address internal constant GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;

    uint16 internal constant DEFAULT_COMMISSION_BPS = 1_000; // 10% (== MAX_COMMISSION_BPS)

    // Mirrors of the factory events (needed to build vm.expectEmit expectations).
    // NOTE: VaultCreated's 2nd topic is the settlementToken now (not a taxToken).
    event VaultCreated(address indexed vault, address indexed settlementToken, uint256 indexed gridId, bytes32 assetHash);
    event VaultAwaitingApproval(address indexed vault, uint256 indexed gridId, bytes32 assetHash);
    event CreatorRevenueSwept(uint256 indexed gridId, address indexed to, uint256 amount);

    MockWBNB internal stock; // the ERC20 "stock" settlement token (mintable)
    MockUGM internal ugm; // the grid sink
    address internal treasury;
    address internal stranger; // a random non-guardian, non-portal caller
    StockpileVaultFactory internal factory;

    function setUp() public {
        // Pin the chain so the guardian gate resolves.
        vm.chainId(CHAIN_ID);

        stock = new MockWBNB();
        ugm = new MockUGM();
        treasury = makeAddr("treasury");
        stranger = makeAddr("stranger");

        factory = new StockpileVaultFactory(address(ugm), DEFAULT_COMMISSION_BPS);

        // Fund this test contract so it can mint the stock (deposit) to seed the vault/UGM.
        vm.deal(address(this), 1_000 ether);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    /// @notice Create a vault as a random (non-guardian) caller with the given vaultData.
    /// @dev    The 1st param is vestigial (taxToken is no longer a newVault input — the factory
    ///         always inits vaults with taxToken == 0). Internally this passes the stock as the
    ///         settlementToken and the test's `treasury` as the commission recipient.
    function _createVault(address, /* unused (was taxToken) */ bytes memory vaultData)
        internal
        returns (address vault)
    {
        vm.prank(stranger);
        vault = factory.newVault(address(stock), treasury, address(0), vaultData);
    }

    /// @notice Mint `amount` of the stock and transfer it into `vault`, simulating
    ///         a Flap TaxProcessor delivering ERC20 tax (no receive hook fires).
    function _fundVaultWithStock(address vault, uint256 amount) internal {
        stock.deposit{value: amount}();
        stock.transfer(vault, amount);
    }

    // ── 1. Constructor wiring + beacon deploy ─────────────────────────────────

    function test_Constructor_WiresConfigAndDeploysBeacon() public view {
        // settlementToken + treasury are NO LONGER factory immutables (they are chosen per-vault
        // at newVault time), so only the ugm + defaultCommissionBps are asserted here.
        assertEq(factory.ugm(), address(ugm), "ugm wired");
        assertEq(uint256(factory.defaultCommissionBps()), uint256(DEFAULT_COMMISSION_BPS), "defaultCommissionBps wired");

        // A beacon + a non-zero implementation were deployed, and upgrades start unlocked.
        assertTrue(factory.beacon() != address(0), "beacon deployed");
        assertTrue(factory.beaconImplementation() != address(0), "beacon has an implementation");
        assertFalse(factory.isVaultUpgradesLocked(), "upgrades start unlocked");
        assertEq(factory.allVaultsLength(), 0, "no vaults yet");
    }

    // ── 2. newVault is PERMISSIONLESS: create grid + init vault + events ───────

    function test_NewVault_Permissionless_CreatesGridInitsVaultAndEmits() public {
        // First grid on a fresh UGM gets id 1. The vault address + derived assetHash are
        // not known up front, so only the predictable topics are checked. The 2nd topic
        // is the settlementToken (the stock) now.
        vm.expectEmit(false, true, true, false, address(factory));
        emit VaultCreated(address(0), address(stock), 1, bytes32(0));
        vm.expectEmit(false, true, false, false, address(factory));
        emit VaultAwaitingApproval(address(0), 1, bytes32(0));

        // Called by a random non-guardian, non-portal address -> succeeds (permissionless).
        // Params are (settlementToken, treasury, unused, vaultData).
        vm.prank(stranger);
        address vault = factory.newVault(address(stock), treasury, address(0), "");
        assertTrue(vault != address(0), "vault deployed");

        // Vault config: taxToken is always 0 for factory-created vaults (reference-only, factory
        // passes 0); settlement token is the stock; treasury is the passed recipient; commission the default.
        StockpileVault v = StockpileVault(payable(vault));
        assertEq(v.taxToken(), address(0), "vault.taxToken is 0 (factory passes 0)");
        assertEq(v.ugm(), address(ugm), "vault.ugm");
        assertEq(v.settlementToken(), address(stock), "vault.settlementToken is the stock");
        assertEq(v.treasury(), treasury, "vault.treasury");
        assertEq(uint256(v.commissionBps()), uint256(DEFAULT_COMMISSION_BPS), "commission = factory default");

        // Factory registry. The 4th field is the settlementToken (not a taxToken).
        (address rVault, uint256 gid, bytes32 ah, address rSettle) = factory.vaultInfo(vault);
        assertEq(rVault, vault, "record.vault");
        assertEq(gid, 1, "record.gridId");
        assertEq(rSettle, address(stock), "record.settlementToken is the stock");
        assertEq(factory.allVaultsLength(), 1, "allVaultsLength");
        assertEq(factory.allVaults(0), vault, "allVaults[0]");

        // assetHash binds vault <-> grid and matches what the vault stored.
        bytes32 expectedHash = keccak256(abi.encode("StockpileVault", vault, gid));
        assertEq(ah, expectedHash, "record.assetHash");
        assertEq(v.assetHash(), expectedHash, "vault.assetHash");

        // Grid params recorded by the UGM: stock is BOTH tax + yield token; defaults applied.
        assertEq(ugm.createGridCallCount(), 1, "createGrid called once");
        (uint32 seats, uint16 taxRate, uint32 forfeiture, address gTax, address gYield, uint128 initialPrice) =
            ugm.lastGridParams();
        assertEq(gTax, address(stock), "grid taxToken == stock");
        assertEq(gYield, address(stock), "grid yieldToken == stock");
        assertEq(uint256(seats), 16, "default totalSeats");
        assertEq(uint256(taxRate), 100, "default taxRateBps");
        assertEq(uint256(forfeiture), 0, "forfeitureDuration -> UGM default");
        assertEq(uint256(initialPrice), 0, "default initialPrice");
    }

    // ── 3. vaultData commission: 0 -> default; else clamped to MAX (1000) ─────

    function test_NewVault_CommissionFromVaultData_DefaultAndClamped() public {
        // Explicit in-range commission is used verbatim.
        bytes memory dExplicit = abi.encode(uint16(500), uint16(0), uint256(0), uint256(0), uint256(0));
        address vExplicit = _createVault(makeAddr("t1"), dExplicit);
        assertEq(uint256(StockpileVault(payable(vExplicit)).commissionBps()), 500, "explicit commission used");

        // Over-max commission clamps to MAX_COMMISSION_BPS (1000 = 10%, audit v5 F8).
        bytes memory dClamp = abi.encode(uint16(20_000), uint16(0), uint256(0), uint256(0), uint256(0));
        address vClamp = _createVault(makeAddr("t2"), dClamp);
        assertEq(uint256(StockpileVault(payable(vClamp)).commissionBps()), 1_000, "commission clamped to 1000");

        // Zero commission falls back to the factory default (empty vaultData path).
        address vDefault = _createVault(makeAddr("t3"), "");
        assertEq(
            uint256(StockpileVault(payable(vDefault)).commissionBps()),
            uint256(DEFAULT_COMMISSION_BPS),
            "zero commission -> factory default"
        );
    }

    // ── 4. vaultData grid params clamp to their bounds ────────────────────────

    function test_NewVault_ClampsGridParams_LowAndHighBounds() public {
        // Below-min: seats 2 -> 4, taxRate 5 -> 10. forfeiture 0 -> UGM default.
        bytes memory low = abi.encode(uint16(0), uint16(5), uint256(2), uint256(0), uint256(0));
        _createVault(makeAddr("low"), low);
        (uint32 seatsLo, uint16 taxLo,,,,) = ugm.lastGridParams();
        assertEq(uint256(seatsLo), 4, "totalSeats clamped up to min 4");
        assertEq(uint256(taxLo), 10, "taxRateBps clamped up to min 10");

        // Above-max: seats 9999 -> 1024, taxRate 5000 -> 1000, forfeiture 60d -> 30d.
        bytes memory high = abi.encode(uint16(0), uint16(5000), uint256(9999), uint256(60 days), uint256(0));
        _createVault(makeAddr("high"), high);
        (uint32 seatsHi, uint16 taxHi, uint32 fdHi,,,) = ugm.lastGridParams();
        assertEq(uint256(seatsHi), 1024, "totalSeats clamped down to max 1024");
        assertEq(uint256(taxHi), 1000, "taxRateBps clamped down to max 1000");
        assertEq(uint256(fdHi), uint256(30 days), "forfeitureDuration clamped down to max 30d");
    }

    // ── 5. Approval bridge: pendingApproval flips once the vault self-registers ─

    function test_PendingApproval_TrueUntilVaultSelfRegisters() public {
        address vault = _createVault(makeAddr("tax"), "");
        (, uint256 gid,,) = factory.vaultInfo(vault);

        // Freshly created: the vault is not yet the registered adapter -> pending.
        assertTrue(factory.pendingApproval(vault), "pending right after creation");

        // Guardian approving the adapter alone is NOT enough: assetAdapter is still unset.
        ugm.setApprovedAdapter(vault, true);
        assertTrue(factory.pendingApproval(vault), "still pending until the vault registers itself");

        // The VAULT registers itself -> UGM binds assetAdapter[assetHash] = vault -> cleared.
        StockpileVault(payable(vault)).registerWithGrid(gid);
        assertFalse(factory.pendingApproval(vault), "cleared once the vault is the registered adapter");

        // Unknown vault never pends (and never reverts).
        assertFalse(factory.pendingApproval(makeAddr("nobody")), "unknown vault not pending");
    }

    // ── 6. registerWithGrid rejects a gridId that doesn't reproduce assetHash ──

    function test_RegisterWithGrid_WrongGridId_Reverts() public {
        address vault = _createVault(makeAddr("tax"), "");
        (, uint256 gid,,) = factory.vaultInfo(vault);
        ugm.setApprovedAdapter(vault, true);

        // A gridId that does not reproduce the stored assetHash is rejected in-vault,
        // before the UGM is ever touched.
        vm.expectRevert(bytes(unicode"Grid mismatch / 网格不匹配"));
        StockpileVault(payable(vault)).registerWithGrid(gid + 1);
    }

    // ── 7. Full money path: a factory vault flushes the stock into the grid ────

    function test_FactoryVault_FlushDeliversStockToGrid() public {
        address vault = _createVault(makeAddr("tax"), ""); // commission = default 10%
        (, uint256 gid, bytes32 ah,) = factory.vaultInfo(vault);

        // Simulate tax arrival: the stock accrues on the vault via a plain ERC20 transfer.
        uint256 gross = 10 ether;
        _fundVaultWithStock(vault, gross);
        assertEq(StockpileVault(payable(vault)).pendingFlush(), gross, "pendingFlush == stock balance");

        // Unwired: the asset is unregistered, so flush() reverts at the UGM gate.
        vm.expectRevert(bytes("asset"));
        StockpileVault(payable(vault)).flush();

        // Wire the vault: guardian approves it, then the vault self-registers as the adapter.
        ugm.setApprovedAdapter(vault, true);
        StockpileVault(payable(vault)).registerWithGrid(gid);
        assertEq(ugm.assetAdapter(ah), vault, "vault is the registered adapter");

        // Now flush() skims the commission to the treasury and forwards the rest to the grid.
        uint256 expectedFee = (gross * DEFAULT_COMMISSION_BPS) / 10_000; // 1 ether
        uint256 expectedNet = gross - expectedFee; // 9 ether

        uint256 net = StockpileVault(payable(vault)).flush();
        assertEq(net, expectedNet, "flush returns net forwarded");
        assertEq(stock.balanceOf(vault), 0, "vault stock drained");
        assertEq(stock.balanceOf(treasury), expectedFee, "commission skimmed to treasury");
        assertEq(stock.balanceOf(address(ugm)), expectedNet, "grid received the net yield");
        assertEq(ugm.lastYieldAmount(), expectedNet, "UGM recorded the yield amount");
        assertEq(ugm.lastYieldToken(), address(stock), "yield token is the stock");
        assertEq(ugm.lastYieldAssetHash(), ah, "yield tagged with the vault's assetHash");

        // Idempotent: a second flush with a zero balance forwards nothing and doesn't re-push.
        assertEq(StockpileVault(payable(vault)).flush(), 0, "empty flush is a no-op");
        assertEq(ugm.receiveYieldCallCount(), 1, "grid pushed exactly once");
    }

    // ── 8. Beacon administration is guardian-only ─────────────────────────────

    function test_UpgradeVaultImplementation_GuardianOnly() public {
        address newImpl = address(new StockpileVault());

        // Non-guardian is rejected.
        vm.prank(stranger);
        vm.expectRevert(bytes(unicode"Only Guardian / 仅限 Guardian"));
        factory.upgradeVaultImplementation(newImpl);

        // Guardian upgrades the shared implementation.
        vm.prank(GUARDIAN);
        factory.upgradeVaultImplementation(newImpl);
        assertEq(factory.beaconImplementation(), newImpl, "beacon points at new impl");
    }

    function test_LockVaultUpgrades_GuardianOnly() public {
        // Non-guardian cannot lock.
        vm.prank(stranger);
        vm.expectRevert(bytes(unicode"Only Guardian / 仅限 Guardian"));
        factory.lockVaultUpgrades();
        assertFalse(factory.isVaultUpgradesLocked(), "not locked yet");

        // Guardian permanently locks upgrades (renounces beacon ownership).
        vm.prank(GUARDIAN);
        factory.lockVaultUpgrades();
        assertTrue(factory.isVaultUpgradesLocked(), "locked");
    }

    // ── 9. Guardian-only creator-revenue sweep ────────────────────────────────

    function test_SweepCreatorRevenue_GuardianOnly() public {
        uint256[] memory seatIds = new uint256[](0);
        vm.prank(stranger);
        vm.expectRevert(bytes(unicode"Only Guardian / 仅限 Guardian"));
        factory.sweepCreatorRevenue(1, seatIds, address(stock), makeAddr("beneficiary"));
    }

    function test_SweepCreatorRevenue_ZeroBeneficiaryReverts() public {
        uint256[] memory seatIds = new uint256[](0);
        vm.prank(GUARDIAN);
        vm.expectRevert(bytes(unicode"Zero address / 零地址"));
        factory.sweepCreatorRevenue(1, seatIds, address(stock), address(0));
    }

    /// @dev The guardian settles unsold-seat yield, pulls the factory's stock creator payout
    ///      out of the UGM, and forwards it to the beneficiary.
    function test_SweepCreatorRevenue_ForwardsSweptStockToBeneficiary() public {
        // Seed a claimable creator payout: fund the UGM with real stock + record the amount.
        uint256 amount = 3 ether;
        stock.deposit{value: amount}();
        stock.transfer(address(ugm), amount);
        ugm.seedPayout(address(stock), amount);

        address beneficiary = makeAddr("beneficiary");
        uint256[] memory seatIds = new uint256[](2);
        seatIds[0] = 7;
        seatIds[1] = 9;

        vm.expectEmit(true, true, false, true, address(factory));
        emit CreatorRevenueSwept(1, beneficiary, amount);

        vm.prank(GUARDIAN);
        uint256 swept = factory.sweepCreatorRevenue(1, seatIds, address(stock), beneficiary);

        assertEq(swept, amount, "swept the full creator payout");
        assertEq(stock.balanceOf(beneficiary), amount, "beneficiary received the stock");
        assertEq(stock.balanceOf(address(factory)), 0, "factory retains nothing after the sweep");
        assertEq(stock.balanceOf(address(ugm)), 0, "UGM payout balance drained");
        assertEq(ugm.claimYieldBatchCallCount(), 1, "unsold-seat yield settled first");
        assertEq(ugm.lastClaimYieldGridId(), 1, "claimYieldBatch targeted the swept grid");
    }

    // ── 10. Discovery surface ─────────────────────────────────────────────────

    function test_FactorySpecVersion_IsStock() public view {
        assertEq(factory.factorySpecVersion(), "v3.0-stock", "spec version");
    }

    function test_IsQuoteTokenSupported_AlwaysTrue() public {
        assertTrue(factory.isQuoteTokenSupported(address(0)), "native BNB accepted");
        assertTrue(factory.isQuoteTokenSupported(address(stock)), "the stock accepted");
        assertTrue(factory.isQuoteTokenSupported(makeAddr("randomTokenA")), "any token accepted (A)");
        assertTrue(factory.isQuoteTokenSupported(makeAddr("randomTokenB")), "any token accepted (B)");
    }

    // Sanity: the schema still decodes as a single 5-field tuple (matches _buildCreateParams).
    function test_VaultDataSchema_ShapeMatchesDecode() public view {
        VaultDataSchema memory schema = factory.vaultDataSchema();
        assertEq(schema.fields.length, 5, "5 vaultData fields");
        assertFalse(schema.isArray, "single tuple");
    }
}
