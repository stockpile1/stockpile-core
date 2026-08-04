// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {MultiStockVault} from "../src/MultiStockVault.sol";
import {MockUGM} from "./mocks/MockUGM.sol";
import {MockWBNB} from "./mocks/MockWBNB.sol";
import {MockMintableERC20} from "./mocks/MockMintableERC20.sol";
import {MockFeeOnTransferERC20} from "./mocks/MockFeeOnTransferERC20.sol";
import {MockV3Router} from "./mocks/MockV3Router.sol";

/// @title MultiStockVault unit tests (no fork)
/// @notice Exercises the standalone 7-stock vault end-to-end against fully local
///         mocks: MockWBNB (accrued token), MockMintableERC20 (USDT hop + the 7
///         stocks), MockV3Router (deterministic 2-hop `exactInput`), and MockUGM
///         (grid sink with per-asset accumulation). The test contract is the vault
///         deployer, hence its `owner` (guardian); guardian-only paths are driven
///         directly, non-owner paths via `vm.prank`.
contract MultiStockVaultTest is Test {
    // ── Actors / infra ────────────────────────────────────────────────────────
    MockWBNB internal wbnb; // accrued token + first swap hop
    MockMintableERC20 internal usdt; // shared stable hop (never actually moved by the mock router)
    MockMintableERC20[7] internal stock; // the 7 target stock tokens
    MockV3Router internal router; // deterministic exactInput
    MockUGM internal ugm; // grid sink
    address internal treasury;

    uint24 internal constant WBNB_USDT_FEE = 100;

    function setUp() public {
        wbnb = new MockWBNB();
        usdt = new MockMintableERC20("Tether USD", "USDT", 18);
        router = new MockV3Router();
        ugm = new MockUGM();
        treasury = makeAddr("treasury");

        for (uint256 i = 0; i < 7; i++) {
            stock[i] = new MockMintableERC20(
                string(abi.encodePacked("Stock", vm.toString(i))),
                string(abi.encodePacked("STK", vm.toString(i))),
                18
            );
        }

        // Fund the test contract with plenty of native BNB so it can mint WBNB
        // (deposit) and send raw value in the receive()/emergency tests.
        vm.deal(address(this), 5_000_000 ether);
    }

    // ── Fixture helpers ───────────────────────────────────────────────────────

    /// @dev Default basket weights: [25%,25%,12.5%,12.5%,10%,10%,5%] == 10_000 bps.
    function _defaultWeights() internal pure returns (uint16[7] memory w) {
        w = [uint16(2500), 2500, 1250, 1250, 1000, 1000, 500];
    }

    /// @dev Build a BasketParams with distinct grid ids (1..7) and distinct fee tiers.
    function _basket(uint16[7] memory weights) internal view returns (MultiStockVault.BasketParams memory b) {
        uint24[7] memory fees = [uint24(100), 500, 2500, 10000, 3000, 400, 800];
        for (uint256 i = 0; i < 7; i++) {
            b.stocks[i] = address(stock[i]);
            b.gridIds[i] = i + 1;
            b.stockFees[i] = fees[i];
            b.weightsBps[i] = weights[i];
        }
    }

    function _deploy(uint16 commissionBps, uint256 minInterval_, uint16[7] memory weights)
        internal
        returns (MultiStockVault v)
    {
        v = new MultiStockVault(
            address(wbnb),
            address(usdt),
            address(ugm),
            address(router),
            WBNB_USDT_FEE,
            treasury,
            commissionBps,
            minInterval_,
            _basket(weights)
        );
    }

    /// @dev Seed each of the 7 grids' yieldToken to its leg's stock so the vault's F3
    ///      registration-time assert (`gridConfig(gridId).yieldToken == stock`) passes. Keyed on the
    ///      shared MockUGM by the standard-basket gridIds (1..7) / stocks (stock[0..6]); idempotent.
    function _setGridYieldTokens() internal {
        for (uint256 i = 0; i < 7; i++) {
            ugm.setGridYieldToken(i + 1, address(stock[i]));
        }
    }

    /// @dev Deploy, seed grid yieldTokens (F3), approve the vault as a UGM adapter, bind all 7 grids,
    ///      warp past the gate.
    function _deployRegistered(uint16 commissionBps, uint256 minInterval_, uint16[7] memory weights)
        internal
        returns (MultiStockVault v)
    {
        v = _deploy(commissionBps, minInterval_, weights);
        _setGridYieldTokens();
        ugm.setApprovedAdapter(address(v), true);
        v.registerAllGrids();
        vm.warp(block.timestamp + minInterval_ + 1);
    }

    /// @dev Mint `amount` WBNB and transfer it to `v` (simulates the fee ERC20 transfer, no hook).
    function _fundWbnb(MultiStockVault v, uint256 amount) internal {
        wbnb.deposit{value: amount}();
        require(wbnb.transfer(address(v), amount), "fund transfer");
    }

    function _assetHash(address v, uint256 gridId) internal pure returns (bytes32) {
        return keccak256(abi.encode("MultiStockVault", v, gridId));
    }

    /// @dev Re-implements the vault's exact weight split (dust on the last leg) so tests can
    ///      predict each leg's `amountIn` independent of the contract.
    function _expectedAmountsIn(uint256 net, uint16[7] memory weights) internal pure returns (uint256[7] memory amt) {
        uint256 allocated;
        for (uint256 i = 0; i < 7; i++) {
            if (i == 6) {
                amt[i] = net - allocated;
            } else {
                amt[i] = (net * weights[i]) / 10_000;
                allocated += amt[i];
            }
        }
    }

    function _zeros() internal pure returns (uint256[7] memory z) {
        // all-zero minOut
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 1. Happy path: full 7-leg distribute
    // ══════════════════════════════════════════════════════════════════════════

    function test_HappyPath_DistributesAllLegs() public {
        uint16 commissionBps = 500; // 5%
        uint16[7] memory weights = _defaultWeights();
        MultiStockVault v = _deployRegistered(commissionBps, 1 hours, weights);

        uint256 gross = 1_000 ether;
        _fundWbnb(v, gross);
        assertEq(v.pendingDistribute(), gross, "pendingDistribute == funded WBNB");

        uint256 commission = (gross * commissionBps) / 10_000; // 50 ether
        uint256 net = gross - commission; // 950 ether
        uint256[7] memory expIn = _expectedAmountsIn(net, weights);

        uint256[7] memory bought = v.distribute(_zeros(), block.timestamp + 300);

        // Commission skimmed to the treasury (in WBNB).
        assertEq(wbnb.balanceOf(treasury), commission, "treasury got commission");

        // Router 1:1 => stock out per leg == amountIn per leg; conservation across the split.
        uint256 sumIn;
        for (uint256 i = 0; i < 7; i++) {
            bytes32 ah = _assetHash(address(v), i + 1);
            assertEq(bought[i], expIn[i], "returned bought[i]");
            assertEq(ugm.yieldByAsset(ah), expIn[i], "grid received leg amount");
            assertEq(stock[i].balanceOf(address(ugm)), expIn[i], "UGM holds the stock");
            sumIn += expIn[i];
        }
        assertEq(sumIn, net, "sum(amountIn) == net (dust folded in)");
        assertEq(ugm.receiveYieldCallCount(), 7, "exactly 7 grid pushes");

        // Vault fully drained: net swapped away, commission sent, allowance reset.
        assertEq(wbnb.balanceOf(address(v)), 0, "vault WBNB drained");
        assertEq(wbnb.allowance(address(v), address(router)), 0, "router allowance reset");
        assertEq(v.lastDistribute(), block.timestamp, "lastDistribute advanced");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 2. Weight split + dust lands on the LAST leg
    // ══════════════════════════════════════════════════════════════════════════

    function test_WeightSplit_DustOnLastLeg() public {
        uint16[7] memory weights = _defaultWeights();
        // Zero commission so net == gross; pick a gross that does NOT divide evenly by
        // the leg weights, forcing rounding dust that must accumulate on the last leg.
        MultiStockVault v = _deployRegistered(0, 0, weights);

        uint256 gross = 1 ether + 3; // 1e18 + 3 wei
        _fundWbnb(v, gross);
        uint256 net = gross; // 0% commission

        uint256[7] memory expIn = _expectedAmountsIn(net, weights);
        uint256[7] memory bought = v.distribute(_zeros(), block.timestamp + 300);

        uint256 sumIn;
        for (uint256 i = 0; i < 6; i++) {
            // First 6 legs are the exact floored weight share.
            assertEq(expIn[i], (net * weights[i]) / 10_000, "leg i is floored weight share");
            assertEq(bought[i], expIn[i], "bought[i] matches split");
            sumIn += expIn[i];
        }
        // The last leg is the remainder: naive floored share PLUS all rounding dust.
        uint256 naiveLast = (net * weights[6]) / 10_000;
        uint256 dust = net - sumIn - naiveLast;
        assertGt(dust, 0, "dust is non-zero for this gross");
        assertEq(expIn[6], naiveLast + dust, "last leg absorbs the dust");
        assertEq(bought[6], expIn[6], "bought[6] is remainder incl. dust");
        assertEq(sumIn + expIn[6], net, "conservation: all legs sum to net");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 3. Time-gate (minInterval)
    // ══════════════════════════════════════════════════════════════════════════

    function test_TimeGate_RevertsBeforeInterval() public {
        MultiStockVault v = _deploy(0, 1 days, _defaultWeights());
        _setGridYieldTokens();
        ugm.setApprovedAdapter(address(v), true);
        v.registerAllGrids();
        _fundWbnb(v, 100 ether);
        // block.timestamp (1) < lastDistribute(0) + 1 days -> "Too soon".
        vm.expectRevert(bytes(unicode"Too soon / 时间未到"));
        v.distribute(_zeros(), block.timestamp + 300);
    }

    function test_TimeGate_SecondImmediateReverts() public {
        uint256 interval = 1 days;
        MultiStockVault v = _deployRegistered(0, interval, _defaultWeights()); // warped past interval

        _fundWbnb(v, 100 ether);
        v.distribute(_zeros(), block.timestamp + 300); // succeeds

        // Immediate second call is blocked by the freshly-advanced lastDistribute.
        _fundWbnb(v, 100 ether);
        vm.expectRevert(bytes(unicode"Too soon / 时间未到"));
        v.distribute(_zeros(), block.timestamp + 300);

        // After another full interval it works again.
        vm.warp(block.timestamp + interval + 1);
        uint256[7] memory bought = v.distribute(_zeros(), block.timestamp + 300);
        assertGt(bought[0], 0, "second distribute succeeds after warp");
    }

    function test_Distribute_NothingToDistributeReverts() public {
        MultiStockVault v = _deployRegistered(0, 0, _defaultWeights());
        // No WBNB funded -> gross == 0.
        vm.expectRevert(bytes(unicode"Nothing to distribute / 无可分配"));
        v.distribute(_zeros(), block.timestamp + 300);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 4. Commission: constructor cap, lower-only setter, zero-commission path
    // ══════════════════════════════════════════════════════════════════════════

    function test_Constructor_RevertsCommissionTooHigh() public {
        MultiStockVault.BasketParams memory b = _basket(_defaultWeights());
        vm.expectRevert(bytes(unicode"Commission too high / 佣金过高"));
        new MultiStockVault(
            address(wbnb), address(usdt), address(ugm), address(router), WBNB_USDT_FEE, treasury, 1001, 0, b
        );
    }

    function test_SetCommissionBps_OnlyLower() public {
        MultiStockVault v = _deploy(1000, 0, _defaultWeights()); // start at the 10% cap

        // Raising reverts (any value > current, incl. one above the cap).
        vm.expectRevert(bytes(unicode"Fee can only decrease / 费用只能降低"));
        v.setCommissionBps(1001);
        vm.expectRevert(bytes(unicode"Fee can only decrease / 费用只能降低"));
        v.setCommissionBps(1000 + 1);

        // Lowering works, repeatedly, down to zero.
        v.setCommissionBps(500);
        assertEq(v.commissionBps(), 500, "lowered to 500");
        v.setCommissionBps(0);
        assertEq(v.commissionBps(), 0, "lowered to 0");

        // Cannot climb back up from zero.
        vm.expectRevert(bytes(unicode"Fee can only decrease / 费用只能降低"));
        v.setCommissionBps(1);
    }

    function test_SetCommissionBps_NonOwnerReverts() public {
        MultiStockVault v = _deploy(500, 0, _defaultWeights());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        v.setCommissionBps(100);
    }

    function test_ZeroCommission_ForwardsFullNet() public {
        uint16[7] memory weights = _defaultWeights();
        MultiStockVault v = _deployRegistered(0, 0, weights);

        uint256 gross = 700 ether;
        _fundWbnb(v, gross);
        uint256[7] memory expIn = _expectedAmountsIn(gross, weights); // net == gross

        v.distribute(_zeros(), block.timestamp + 300);

        assertEq(wbnb.balanceOf(treasury), 0, "no commission at 0 bps");
        uint256 sum;
        for (uint256 i = 0; i < 7; i++) {
            sum += ugm.yieldByAsset(_assetHash(address(v), i + 1));
            assertEq(ugm.yieldByAsset(_assetHash(address(v), i + 1)), expIn[i], "leg got its full share");
        }
        assertEq(sum, gross, "entire gross forwarded to grids");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 5. Slippage: a leg whose out < minOut[i] is SKIPPED (best-effort), not batch-reverting
    // ══════════════════════════════════════════════════════════════════════════

    function test_Slippage_LegBelowMinOut_Skipped() public {
        uint16[7] memory weights = _defaultWeights();
        MultiStockVault v = _deployRegistered(0, 0, weights);

        uint256 gross = 1_000 ether;
        _fundWbnb(v, gross);
        uint256[7] memory expIn = _expectedAmountsIn(gross, weights);

        // Halve the price of leg-0's stock so its realized out is amountIn/2 ...
        router.setRate(address(stock[0]), router.RATE_DEN() / 2);

        // ... but demand the full 1:1 amount as the floor. The router reverts that ONE leg; under
        // best-effort (F2) it is caught+skipped and the other six still deliver.
        uint256[7] memory minOut;
        minOut[0] = expIn[0];

        uint256[7] memory bought = v.distribute(minOut, block.timestamp + 300);

        assertEq(bought[0], 0, "slippage-failing leg skipped");
        assertEq(ugm.yieldByAsset(_assetHash(address(v), 1)), 0, "grid 1 got nothing");
        assertEq(ugm.receiveYieldCallCount(), 6, "the other six legs delivered");
        assertEq(wbnb.balanceOf(address(v)), expIn[0], "skipped leg's WBNB retained (swap rolled back)");
        for (uint256 i = 1; i < 7; i++) {
            assertEq(bought[i], expIn[i], "healthy legs delivered their share");
            assertGt(bought[i], 0, "healthy legs positive");
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 6. Adapter binding at the UGM
    // ══════════════════════════════════════════════════════════════════════════

    function test_Distribute_BeforeRegistration_SkipsAllLegs() public {
        // Deploy but never register: every leg's UGM push reverts "asset". Under best-effort (F2)
        // each reverting leg is caught+skipped (not a batch revert), and because each swap rolls
        // back, all WBNB is retained for a later distribute (after registration).
        MultiStockVault v = _deploy(0, 0, _defaultWeights());
        _fundWbnb(v, 100 ether);

        uint256[7] memory bought = v.distribute(_zeros(), block.timestamp + 300);

        assertEq(ugm.receiveYieldCallCount(), 0, "no leg delivered");
        for (uint256 i = 0; i < 7; i++) {
            assertEq(bought[i], 0, "every unregistered leg skipped");
        }
        assertEq(wbnb.balanceOf(address(v)), 100 ether, "all WBNB retained (swaps rolled back)");
        assertEq(v.lastDistribute(), block.timestamp, "time-gate still advanced");
    }

    function test_Distribute_NotAdapterLeg_Skipped() public {
        MultiStockVault v = _deploy(0, 0, _defaultWeights());
        // Raw-poke leg-0's grid wiring WITHOUT binding the vault as adapter, so assetAdapter stays 0
        // -> that leg's push reverts "not adapter"; the others revert "asset". All caught+skipped (F2).
        ugm.setAssetToGrid(_assetHash(address(v), 1), 1);
        _fundWbnb(v, 100 ether);

        uint256[7] memory bought = v.distribute(_zeros(), block.timestamp + 300);

        assertEq(ugm.receiveYieldCallCount(), 0, "no leg delivered");
        for (uint256 i = 0; i < 7; i++) {
            assertEq(bought[i], 0, "leg skipped (not adapter / unregistered)");
        }
        assertEq(wbnb.balanceOf(address(v)), 100 ether, "all WBNB retained (swaps rolled back)");
    }

    function test_RegisterWithGrid_BindsAdapter() public {
        MultiStockVault v = _deploy(0, 0, _defaultWeights());
        _setGridYieldTokens();
        ugm.setApprovedAdapter(address(v), true);

        bytes32 ah0 = _assetHash(address(v), 1);
        v.registerWithGrid(0);

        assertEq(ugm.assetAdapter(ah0), address(v), "vault bound as adapter");
        assertEq(ugm.assetToGrid(ah0), 1, "asset wired to grid 1");
    }

    function test_RegisterWithGrid_DoubleRegisterReverts() public {
        MultiStockVault v = _deploy(0, 0, _defaultWeights());
        _setGridYieldTokens();
        ugm.setApprovedAdapter(address(v), true);
        v.registerWithGrid(0);
        vm.expectRevert(bytes("registered"));
        v.registerWithGrid(0);
    }

    function test_RegisterWithGrid_BadIndexReverts() public {
        MultiStockVault v = _deploy(0, 0, _defaultWeights());
        ugm.setApprovedAdapter(address(v), true);
        vm.expectRevert(bytes(unicode"Bad leg index / 无效腿索引"));
        v.registerWithGrid(7);
    }

    function test_RegisterAllGrids_RevertsWhenNotApprovedAdapter() public {
        MultiStockVault v = _deploy(0, 0, _defaultWeights());
        _setGridYieldTokens(); // pass the F3 yieldToken assert so the "adapter" gate is what fires
        // Vault not on the adapter allowlist -> UGM.registerAsset reverts "adapter".
        vm.expectRevert(bytes("adapter"));
        v.registerAllGrids();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 7. Emergency escape hatches (owner-only, full-balance sweep)
    // ══════════════════════════════════════════════════════════════════════════

    function test_EmergencyWithdrawToken_OnlyOwner() public {
        MultiStockVault v = _deploy(0, 0, _defaultWeights());
        stock[0].mint(address(v), 5 ether);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        v.emergencyWithdrawToken(address(stock[0]), makeAddr("attacker"));
    }

    function test_EmergencyWithdrawToken_MovesFullBalance() public {
        MultiStockVault v = _deploy(0, 0, _defaultWeights());
        stock[0].mint(address(v), 5 ether);
        address to = makeAddr("tokenRecipient");

        v.emergencyWithdrawToken(address(stock[0]), to);

        assertEq(stock[0].balanceOf(to), 5 ether, "recipient got the full balance");
        assertEq(stock[0].balanceOf(address(v)), 0, "vault token drained");
    }

    function test_EmergencyWithdrawNative_OnlyOwner() public {
        MultiStockVault v = _deploy(0, 0, _defaultWeights());
        vm.deal(address(v), 4 ether);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        v.emergencyWithdrawNative(makeAddr("attacker"));
    }

    function test_EmergencyWithdrawNative_MovesFullBalance() public {
        MultiStockVault v = _deploy(0, 0, _defaultWeights());
        vm.deal(address(v), 4 ether); // set native directly (bypasses receive()'s wrap)
        address to = makeAddr("nativeRecipient");

        v.emergencyWithdrawNative(to);

        assertEq(to.balance, 4 ether, "recipient got the native BNB");
        assertEq(address(v).balance, 0, "vault native drained");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 8. Zero handling: zero-weight leg skipped; zero-out swap skipped mid-batch
    // ══════════════════════════════════════════════════════════════════════════

    function test_ZeroWeightLeg_Skipped() public {
        // Leg 0 has weight 0; the rest still sum to 10_000.
        uint16[7] memory weights = [uint16(0), 3000, 2000, 2000, 1000, 1000, 1000];
        MultiStockVault v = _deployRegistered(0, 0, weights);

        uint256 gross = 500 ether;
        _fundWbnb(v, gross);
        uint256[7] memory expIn = _expectedAmountsIn(gross, weights);
        assertEq(expIn[0], 0, "leg 0 allotment is zero");

        uint256[7] memory bought = v.distribute(_zeros(), block.timestamp + 300);

        // Leg 0 never pushed; the other six delivered their shares.
        assertEq(bought[0], 0, "zero-weight leg bought nothing");
        assertEq(ugm.yieldByAsset(_assetHash(address(v), 1)), 0, "grid 1 got nothing");
        assertEq(ugm.receiveYieldCallCount(), 6, "only 6 legs pushed");
        for (uint256 i = 1; i < 7; i++) {
            assertEq(bought[i], expIn[i], "non-zero legs delivered");
            assertGt(bought[i], 0, "non-zero legs are positive");
        }
    }

    function test_ZeroSwapOut_LegSkippedBatchContinues() public {
        uint16[7] memory weights = _defaultWeights();
        MultiStockVault v = _deployRegistered(0, 0, weights);

        uint256 gross = 1_000 ether;
        _fundWbnb(v, gross);
        uint256[7] memory expIn = _expectedAmountsIn(gross, weights);

        // Force leg-2's swap to yield exactly 0: its grid push must be skipped, but
        // the batch must NOT revert and every other leg must still be delivered.
        router.setForceZero(address(stock[2]), true);

        uint256[7] memory bought = v.distribute(_zeros(), block.timestamp + 300);

        assertEq(bought[2], 0, "zero-out leg forwarded nothing");
        assertEq(ugm.yieldByAsset(_assetHash(address(v), 3)), 0, "grid 3 got nothing");
        assertEq(ugm.receiveYieldCallCount(), 6, "6 of 7 legs pushed");
        for (uint256 i = 0; i < 7; i++) {
            if (i == 2) continue;
            assertEq(bought[i], expIn[i], "other legs delivered their share");
            assertGt(bought[i], 0, "other legs positive");
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 9. receive(): accepts the native-BNB fee cheaply; distribute() wraps it to WBNB
    // ══════════════════════════════════════════════════════════════════════════

    function test_Receive_AcceptsBnbIncreasesPending() public {
        MultiStockVault v = _deploy(0, 0, _defaultWeights());
        assertEq(v.pendingDistribute(), 0, "starts empty");

        (bool ok,) = address(v).call{value: 3 ether}("");
        assertTrue(ok, "receive() should not revert");

        // The fee is held as NATIVE BNB (not wrapped in receive); pendingDistribute counts it.
        assertEq(address(v).balance, 3 ether, "native BNB held on the vault");
        assertEq(wbnb.balanceOf(address(v)), 0, "not wrapped until distribute()");
        assertEq(v.pendingDistribute(), 3 ether, "pendingDistribute counts native BNB");
    }

    /// @dev The fee delivery must never revert even under a 2300-gas `.transfer()` stipend — proving
    ///      receive() is gas-safe (the whole point of wrapping in distribute() instead of receive()).
    function test_Receive_LowGasStipendSucceeds() public {
        MultiStockVault v = _deploy(0, 0, _defaultWeights());
        (bool ok,) = address(v).call{value: 1 ether, gas: 2300}("");
        assertTrue(ok, "receive() must succeed within a 2300-gas stipend");
        assertEq(address(v).balance, 1 ether, "BNB accepted");
    }

    function test_Receive_ZeroValueNoop() public {
        MultiStockVault v = _deploy(0, 0, _defaultWeights());
        (bool ok,) = address(v).call{value: 0}("");
        assertTrue(ok, "zero-value receive() should not revert");
        assertEq(v.pendingDistribute(), 0, "nothing pending");
    }

    /// @dev End-to-end proof of the native-BNB fee path: fund the vault with NATIVE BNB (as Flap does),
    ///      then distribute() must wrap it to WBNB and route all 7 legs into their grids.
    function test_Distribute_WrapsNativeBnbFee() public {
        uint16 commissionBps = 500; // 5%
        uint16[7] memory weights = _defaultWeights();
        MultiStockVault v = _deployRegistered(commissionBps, 1 hours, weights);

        uint256 gross = 1_000 ether;
        (bool ok,) = address(v).call{value: gross}(""); // NATIVE BNB fee, not WBNB
        assertTrue(ok, "fund native");
        assertEq(v.pendingDistribute(), gross, "pending counts the native fee");

        uint256 commission = (gross * commissionBps) / 10_000;
        uint256 net = gross - commission;
        uint256[7] memory expIn = _expectedAmountsIn(net, weights);

        uint256[7] memory bought = v.distribute(_zeros(), block.timestamp + 300);

        // Native BNB was wrapped and fully consumed; commission (WBNB) went to treasury; each grid got its stock.
        assertEq(address(v).balance, 0, "native BNB wrapped + spent");
        assertEq(wbnb.balanceOf(address(v)), 0, "no WBNB dust");
        assertEq(wbnb.balanceOf(treasury), commission, "commission skimmed in WBNB");
        for (uint256 i = 0; i < 7; i++) {
            assertEq(bought[i], expIn[i], "leg bought == its wrapped share (1:1 mock)");
            (,, bytes32 ah,,) = v.legs(i);
            assertEq(ugm.yieldByAsset(ah), expIn[i], "grid received the stock");
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 10. Constructor validation
    // ══════════════════════════════════════════════════════════════════════════

    function test_Constructor_ZeroWbnbReverts() public {
        MultiStockVault.BasketParams memory b = _basket(_defaultWeights());
        vm.expectRevert(bytes(unicode"Zero address / 零地址"));
        new MultiStockVault(
            address(0), address(usdt), address(ugm), address(router), WBNB_USDT_FEE, treasury, 0, 0, b
        );
    }

    function test_Constructor_ZeroUsdtReverts() public {
        MultiStockVault.BasketParams memory b = _basket(_defaultWeights());
        vm.expectRevert(bytes(unicode"Zero address / 零地址"));
        new MultiStockVault(
            address(wbnb), address(0), address(ugm), address(router), WBNB_USDT_FEE, treasury, 0, 0, b
        );
    }

    function test_Constructor_ZeroUgmReverts() public {
        MultiStockVault.BasketParams memory b = _basket(_defaultWeights());
        vm.expectRevert(bytes(unicode"Zero address / 零地址"));
        new MultiStockVault(
            address(wbnb), address(usdt), address(0), address(router), WBNB_USDT_FEE, treasury, 0, 0, b
        );
    }

    function test_Constructor_ZeroRouterReverts() public {
        MultiStockVault.BasketParams memory b = _basket(_defaultWeights());
        vm.expectRevert(bytes(unicode"Zero address / 零地址"));
        new MultiStockVault(
            address(wbnb), address(usdt), address(ugm), address(0), WBNB_USDT_FEE, treasury, 0, 0, b
        );
    }

    function test_Constructor_ZeroTreasuryReverts() public {
        MultiStockVault.BasketParams memory b = _basket(_defaultWeights());
        vm.expectRevert(bytes(unicode"Zero address / 零地址"));
        new MultiStockVault(
            address(wbnb), address(usdt), address(ugm), address(router), WBNB_USDT_FEE, address(0), 0, 0, b
        );
    }

    function test_Constructor_ZeroStockReverts() public {
        MultiStockVault.BasketParams memory b = _basket(_defaultWeights());
        b.stocks[3] = address(0);
        vm.expectRevert(bytes(unicode"Zero address / 零地址"));
        new MultiStockVault(
            address(wbnb), address(usdt), address(ugm), address(router), WBNB_USDT_FEE, treasury, 0, 0, b
        );
    }

    function test_Constructor_ZeroGridReverts() public {
        MultiStockVault.BasketParams memory b = _basket(_defaultWeights());
        b.gridIds[2] = 0;
        vm.expectRevert(bytes(unicode"Zero grid / 网格为零"));
        new MultiStockVault(
            address(wbnb), address(usdt), address(ugm), address(router), WBNB_USDT_FEE, treasury, 0, 0, b
        );
    }

    function test_Constructor_WeightsSumReverts() public {
        // Sum == 9_999, not 10_000.
        uint16[7] memory weights = [uint16(2500), 2500, 1250, 1250, 1000, 1000, 499];
        MultiStockVault.BasketParams memory b = _basket(weights);
        vm.expectRevert(bytes(unicode"Weights must sum to 10000 / 权重总和须为10000"));
        new MultiStockVault(
            address(wbnb), address(usdt), address(ugm), address(router), WBNB_USDT_FEE, treasury, 0, 0, b
        );
    }

    function test_Constructor_IntervalTooLongReverts() public {
        MultiStockVault.BasketParams memory b = _basket(_defaultWeights());
        vm.expectRevert(bytes(unicode"Interval too long / 间隔过长"));
        new MultiStockVault(
            address(wbnb), address(usdt), address(ugm), address(router), WBNB_USDT_FEE, treasury, 0, 30 days + 1, b
        );
    }

    function test_Constructor_SetsConfigAndDerivesAssetHashes() public {
        uint16[7] memory weights = _defaultWeights();
        MultiStockVault v = _deploy(300, 2 hours, weights);

        assertEq(v.wbnb(), address(wbnb), "wbnb");
        assertEq(v.usdt(), address(usdt), "usdt");
        assertEq(v.ugm(), address(ugm), "ugm");
        assertEq(v.swapRouter(), address(router), "router");
        assertEq(v.wbnbUsdtFee(), WBNB_USDT_FEE, "fee");
        assertEq(v.treasury(), treasury, "treasury");
        assertEq(v.commissionBps(), 300, "commission");
        assertEq(v.minInterval(), 2 hours, "minInterval");
        assertEq(v.owner(), address(this), "deployer is guardian");

        for (uint256 i = 0; i < 7; i++) {
            (address st, uint256 gid, bytes32 ah,, uint16 w) = v.legs(i);
            assertEq(st, address(stock[i]), "leg stock");
            assertEq(gid, i + 1, "leg gridId");
            assertEq(ah, _assetHash(address(v), i + 1), "assetHash derived (vault,gridId)-bound");
            assertEq(w, weights[i], "leg weight");
            assertEq(v.stocks(i), address(stock[i]), "stocks(i) getter");
        }
    }

    function test_Views_BadLegIndexReverts() public {
        MultiStockVault v = _deploy(0, 0, _defaultWeights());
        vm.expectRevert(bytes(unicode"Bad leg index / 无效腿索引"));
        v.legs(7);
        vm.expectRevert(bytes(unicode"Bad leg index / 无效腿索引"));
        v.stocks(7);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 11. Guardian setters: treasury / minInterval
    // ══════════════════════════════════════════════════════════════════════════

    function test_SetTreasury_UpdatesRejectsZeroAndNonOwner() public {
        MultiStockVault v = _deploy(0, 0, _defaultWeights());

        address newT = makeAddr("newTreasury");
        v.setTreasury(newT);
        assertEq(v.treasury(), newT, "treasury updated");

        vm.expectRevert(bytes(unicode"Zero address / 零地址"));
        v.setTreasury(address(0));

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        v.setTreasury(makeAddr("x"));
    }

    function test_SetMinInterval_UpdatesRejectsTooLongAndNonOwner() public {
        MultiStockVault v = _deploy(0, 0, _defaultWeights());

        v.setMinInterval(6 hours);
        assertEq(v.minInterval(), 6 hours, "interval updated");

        vm.expectRevert(bytes(unicode"Interval too long / 间隔过长"));
        v.setMinInterval(30 days + 1);

        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        v.setMinInterval(1 hours);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 12. Fuzz: commission conservation + full drain across the input space
    // ══════════════════════════════════════════════════════════════════════════

    function testFuzz_Distribute_ConservesAndDrains(uint16 commissionBps, uint96 amount) public {
        commissionBps = uint16(bound(commissionBps, 0, 1_000)); // <= MAX_COMMISSION_BPS
        uint256 gross = bound(amount, 1, 1_000_000 ether);
        uint16[7] memory weights = _defaultWeights();

        MultiStockVault v = _deployRegistered(commissionBps, 0, weights);
        _fundWbnb(v, gross);

        uint256 commission = (gross * commissionBps) / 10_000;
        uint256 net = gross - commission;
        uint256[7] memory expIn = _expectedAmountsIn(net, weights);

        uint256[7] memory bought = v.distribute(_zeros(), block.timestamp + 300);

        assertEq(wbnb.balanceOf(treasury), commission, "treasury got exactly the commission");
        assertEq(wbnb.balanceOf(address(v)), 0, "vault WBNB fully drained");

        uint256 sum;
        for (uint256 i = 0; i < 7; i++) {
            assertEq(bought[i], expIn[i], "leg out == its amountIn (1:1)");
            sum += bought[i];
        }
        assertEq(sum, net, "sum of legs == net (conservation)");
        assertEq(commission + sum, gross, "commission + net == gross");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 13. F1 — keeper gating on distribute (owner always; keepers allowlisted)
    // ══════════════════════════════════════════════════════════════════════════

    function test_Distribute_NonKeeperReverts() public {
        MultiStockVault v = _deployRegistered(0, 0, _defaultWeights());
        _fundWbnb(v, 100 ether);

        vm.prank(makeAddr("rando"));
        vm.expectRevert(bytes(unicode"Not authorized keeper / 未授权的keeper"));
        v.distribute(_zeros(), block.timestamp + 300);
    }

    function test_Distribute_OwnerAlwaysAllowed() public {
        MultiStockVault v = _deployRegistered(0, 0, _defaultWeights());
        _fundWbnb(v, 100 ether);
        // owner == this test contract; it is a keeper implicitly, no allowlist entry required.
        uint256[7] memory bought = v.distribute(_zeros(), block.timestamp + 300);
        assertGt(bought[0], 0, "owner distribute succeeds");
    }

    function test_Distribute_AllowedKeeperCanCall() public {
        MultiStockVault v = _deployRegistered(0, 0, _defaultWeights());
        address keeper = makeAddr("keeper");
        v.setKeeper(keeper, true);
        assertTrue(v.keepers(keeper), "keeper allowlisted");

        _fundWbnb(v, 100 ether);
        vm.prank(keeper);
        uint256[7] memory bought = v.distribute(_zeros(), block.timestamp + 300);
        assertGt(bought[0], 0, "allowlisted keeper distribute succeeds");
    }

    function test_SetKeeper_ToggleOffRevokes() public {
        MultiStockVault v = _deployRegistered(0, 0, _defaultWeights());
        address keeper = makeAddr("keeper");
        v.setKeeper(keeper, true);
        v.setKeeper(keeper, false);
        assertFalse(v.keepers(keeper), "keeper revoked");

        _fundWbnb(v, 100 ether);
        vm.prank(keeper);
        vm.expectRevert(bytes(unicode"Not authorized keeper / 未授权的keeper"));
        v.distribute(_zeros(), block.timestamp + 300);
    }

    function test_SetKeeper_OnlyOwner() public {
        MultiStockVault v = _deploy(0, 0, _defaultWeights());
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        v.setKeeper(makeAddr("keeper"), true);
    }

    function test_SetKeeper_ZeroReverts() public {
        MultiStockVault v = _deploy(0, 0, _defaultWeights());
        vm.expectRevert(bytes(unicode"Zero address / 零地址"));
        v.setKeeper(address(0), true);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 14. F2 — best-effort: a REVERTING leg is skipped, the batch continues
    // ══════════════════════════════════════════════════════════════════════════

    function test_Distribute_ForcedRevertLeg_SkippedBatchContinues() public {
        uint16[7] memory weights = _defaultWeights();
        MultiStockVault v = _deployRegistered(0, 0, weights);

        uint256 gross = 1_000 ether;
        _fundWbnb(v, gross);
        uint256[7] memory expIn = _expectedAmountsIn(gross, weights);

        // Force leg-0's swap to REVERT at the router (dead pool). Best-effort must skip only it.
        router.setForceRevert(address(stock[0]), true);

        uint256[7] memory bought = v.distribute(_zeros(), block.timestamp + 300);

        assertEq(bought[0], 0, "reverting leg bought nothing");
        assertEq(ugm.yieldByAsset(_assetHash(address(v), 1)), 0, "its grid got nothing");
        assertEq(ugm.receiveYieldCallCount(), 6, "the other six delivered");
        // The failed leg's WBNB is retained on the vault (its swap rolled back atomically).
        assertEq(wbnb.balanceOf(address(v)), expIn[0], "failed leg's WBNB share retained for next round");
        for (uint256 i = 1; i < 7; i++) {
            assertEq(bought[i], expIn[i], "healthy legs delivered their share");
            assertGt(bought[i], 0, "healthy legs positive");
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 15. F3 — registration-time yieldToken assert (register, not distribute)
    // ══════════════════════════════════════════════════════════════════════════

    function test_RegisterAllGrids_YieldTokenMismatchReverts() public {
        MultiStockVault v = _deploy(0, 0, _defaultWeights());
        _setGridYieldTokens();
        // Corrupt ONE grid's yieldToken so it no longer equals its leg's stock (grid 3 == leg index 2).
        ugm.setGridYieldToken(3, address(usdt));
        ugm.setApprovedAdapter(address(v), true);

        vm.expectRevert(bytes(unicode"Grid yieldToken mismatch / 网格收益代币不匹配"));
        v.registerAllGrids();
    }

    function test_RegisterWithGrid_YieldTokenMismatchReverts() public {
        MultiStockVault v = _deploy(0, 0, _defaultWeights());
        _setGridYieldTokens();
        ugm.setGridYieldToken(1, address(usdt)); // leg 0 should map to stock[0]
        ugm.setApprovedAdapter(address(v), true);

        vm.expectRevert(bytes(unicode"Grid yieldToken mismatch / 网格收益代币不匹配"));
        v.registerWithGrid(0);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 16. F4 — constructor rejects duplicate gridId
    // ══════════════════════════════════════════════════════════════════════════

    function test_Constructor_DuplicateGridReverts() public {
        MultiStockVault.BasketParams memory b = _basket(_defaultWeights());
        b.gridIds[5] = b.gridIds[2]; // legs 2 and 5 now share a gridId => assetHash collision
        vm.expectRevert(bytes(unicode"Duplicate grid / 网格重复"));
        new MultiStockVault(
            address(wbnb), address(usdt), address(ugm), address(router), WBNB_USDT_FEE, treasury, 0, 0, b
        );
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 17. F5 — fee-on-transfer stock: forward the ACTUAL received delta, no revert
    // ══════════════════════════════════════════════════════════════════════════

    function test_Distribute_FeeOnTransferStock_CreditsActualDelta() public {
        uint16 feeBps = 500; // 5% fee-on-transfer output token
        MockFeeOnTransferERC20 fot = new MockFeeOnTransferERC20("FeeStock", "FOT", 18, feeBps);

        // Custom basket: leg 0 is the FoT token, legs 1..6 are the plain stocks. Grid ids 1..7.
        uint16[7] memory weights = _defaultWeights();
        uint24[7] memory fees = [uint24(100), 500, 2500, 10000, 3000, 400, 800];
        MultiStockVault.BasketParams memory b;
        b.stocks[0] = address(fot);
        b.gridIds[0] = 1;
        b.stockFees[0] = fees[0];
        b.weightsBps[0] = weights[0];
        for (uint256 i = 1; i < 7; i++) {
            b.stocks[i] = address(stock[i]);
            b.gridIds[i] = i + 1;
            b.stockFees[i] = fees[i];
            b.weightsBps[i] = weights[i];
        }

        MultiStockVault v = new MultiStockVault(
            address(wbnb), address(usdt), address(ugm), address(router), WBNB_USDT_FEE, treasury, 0, 0, b
        );

        // Seed yieldTokens: grid 1 -> FoT, grids 2..7 -> plain stocks; then approve + register.
        ugm.setGridYieldToken(1, address(fot));
        for (uint256 i = 1; i < 7; i++) {
            ugm.setGridYieldToken(i + 1, address(stock[i]));
        }
        ugm.setApprovedAdapter(address(v), true);
        v.registerAllGrids();

        uint256 gross = 1_000 ether;
        _fundWbnb(v, gross);
        uint256[7] memory expIn = _expectedAmountsIn(gross, weights); // net == gross (0 commission)

        uint256[7] memory bought = v.distribute(_zeros(), block.timestamp + 300);

        // Leg 0: the router "sold" the full amountIn, but the FoT skimmed 5% on delivery to the vault,
        // so the vault RECEIVED (and forwarded) less than the nominal — and that is exactly what the grid
        // is credited (proving the balance-delta push, not the router return).
        uint256 nominal = expIn[0];
        uint256 expectedGot = nominal - (nominal * feeBps) / 10_000;
        assertEq(bought[0], expectedGot, "leg 0 forwarded the actual received delta");
        assertLt(bought[0], nominal, "forwarded < router nominal (FoT skimmed the delivery)");
        assertEq(ugm.yieldByAsset(_assetHash(address(v), 1)), expectedGot, "grid credited the delta");
        assertEq(fot.balanceOf(address(v)), 0, "no FoT dust stranded on the vault");

        // Plain legs unaffected (full 1:1 delivery), and the whole batch pushed all 7 (no revert).
        for (uint256 i = 1; i < 7; i++) {
            assertEq(bought[i], expIn[i], "plain leg delivered its full share");
        }
        assertEq(ugm.receiveYieldCallCount(), 7, "all 7 legs pushed incl. the FoT leg");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 18. F6 — renounceOwnership disabled
    // ══════════════════════════════════════════════════════════════════════════

    function test_RenounceOwnership_Disabled() public {
        MultiStockVault v = _deploy(0, 0, _defaultWeights());
        vm.expectRevert(bytes(unicode"Renounce disabled / 禁止放弃所有权"));
        v.renounceOwnership();
        assertEq(v.owner(), address(this), "owner unchanged after blocked renounce");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 19. F10 — constructor rejects stock == wbnb or usdt
    // ══════════════════════════════════════════════════════════════════════════

    function test_Constructor_StockIsWbnbReverts() public {
        MultiStockVault.BasketParams memory b = _basket(_defaultWeights());
        b.stocks[4] = address(wbnb);
        vm.expectRevert(bytes(unicode"Stock cannot be wbnb/usdt / stock不能为wbnb或usdt"));
        new MultiStockVault(
            address(wbnb), address(usdt), address(ugm), address(router), WBNB_USDT_FEE, treasury, 0, 0, b
        );
    }

    function test_Constructor_StockIsUsdtReverts() public {
        MultiStockVault.BasketParams memory b = _basket(_defaultWeights());
        b.stocks[1] = address(usdt);
        vm.expectRevert(bytes(unicode"Stock cannot be wbnb/usdt / stock不能为wbnb或usdt"));
        new MultiStockVault(
            address(wbnb), address(usdt), address(ugm), address(router), WBNB_USDT_FEE, treasury, 0, 0, b
        );
    }
}
