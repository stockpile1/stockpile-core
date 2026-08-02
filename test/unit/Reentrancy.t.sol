// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { UnifiedGridManager } from "../../src/core/UnifiedGridManager.sol";
import { IGridHooksV23 } from "../../src/interfaces/IGridHooksV23.sol";
import { Seat, CreateGridParams } from "../../src/libraries/GridTypes.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

// ===================================================================== //
//                          Malicious mocks                              //
// ===================================================================== //

/// @notice ERC20 that re-enters the UGM from inside `transfer`/`transferFrom`.
/// @dev When armed, the token calls back into a `nonReentrant` UGM entry point
///      (buySeat or claimPayout) while the UGM is mid-transfer. The reentrancy
///      guard must revert that inner call; SafeERC20 bubbles the revert data, so
///      the whole outer action aborts. The ONLY difference between the passing
///      and reverting cases is the `attack` flag -> the guard is isolated as the
///      sole cause.
contract ReentrantToken is ERC20 {
    enum Target {
        BuySeat,
        ClaimPayout
    }

    UnifiedGridManager public ugm;
    bool public attack;
    Target public target;
    uint256 public reGrid;
    uint256 public reSeat;

    constructor() ERC20("Reentrant", "REENT") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setUGM(UnifiedGridManager u) external {
        ugm = u;
    }

    function arm(bool on, Target t, uint256 gridId, uint256 seatId) external {
        attack = on;
        target = t;
        reGrid = gridId;
        reSeat = seatId;
    }

    function _tryReenter() internal {
        if (!attack || address(ugm) == address(0)) return;
        // Re-enter a nonReentrant function. No try/catch here: the guard's revert
        // must propagate and abort the outer call.
        if (target == Target.ClaimPayout) {
            ugm.claimPayout(address(this));
        } else {
            ugm.buySeat(reGrid, reSeat, 1, 1, 0);
        }
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _tryReenter();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _tryReenter();
        return super.transferFrom(from, to, amount);
    }
}

/// @notice Governance module whose OBSERVER hooks (`onSeatHolderChange`,
///         `onForfeit`) grief — either revert or burn far more than the 150k gas
///         cap. The `before*` gates return `true` so the action under test can
///         proceed; only the swallow-on-failure observer paths are hostile.
contract GriefObserverHook is IGridHooksV23 {
    enum Mode {
        Revert,
        GasBomb
    }

    Mode public mode;

    function setMode(Mode m) external {
        mode = m;
    }

    // --- Gating hooks: always allow, so buySeat / forfeit reach the observers. ---
    function beforeClaim(uint256, uint256, address, uint256) external pure override returns (bool) {
        return true;
    }

    function beforeBuyout(uint256, uint256, address, address, uint256) external pure override returns (bool) {
        return true;
    }

    function beforePriceChange(uint256, uint256, address, uint256, uint256)
        external
        pure
        override
        returns (bool)
    {
        return true;
    }

    // --- Observer hooks: hostile. The UGM invokes these under {gas: 150000}
    //     inside an empty try/catch, so their failure must be swallowed. ---
    function onSeatHolderChange(uint256, uint256, address, address) external view override {
        _grief();
    }

    function onForfeit(uint256, uint256, address) external view override {
        _grief();
    }

    function _grief() internal view {
        if (mode == Mode.Revert) revert("grief: observer reverts");
        // GasBomb: attempt to burn orders of magnitude more than the 150k cap.
        // Under the {gas: 150000} sub-call cap this OOGs long before finishing.
        bytes32 h = keccak256("grief-seed");
        for (uint256 i = 0; i < 1_000_000; ++i) {
            h = keccak256(abi.encodePacked(h, i));
        }
        require(h != bytes32(0), "unreachable"); // stop the optimizer eliding the loop
    }
}

/// @notice Governance module that vetoes buyouts — either by reverting outright
///         or by trying to re-enter the UGM mid-action. Both are converted by the
///         UGM's try/catch into the `"hook: buyout reverted"` string, and neither
///         can corrupt state: the hook can only block its own action.
contract VetoHook is IGridHooksV23 {
    enum Mode {
        Revert,
        Reenter
    }

    UnifiedGridManager public ugm;
    Mode public mode;

    function configure(UnifiedGridManager u, Mode m) external {
        ugm = u;
        mode = m;
    }

    // Allow claims / price changes so a seat can be set up for the buyout test.
    function beforeClaim(uint256, uint256, address, uint256) external pure override returns (bool) {
        return true;
    }

    function beforePriceChange(uint256, uint256, address, uint256, uint256)
        external
        pure
        override
        returns (bool)
    {
        return true;
    }

    function beforeBuyout(uint256 gridId, uint256 seatId, address, address, uint256)
        external
        override
        returns (bool)
    {
        if (mode == Mode.Reenter) {
            // Try to re-enter and mutate UGM state mid-buyout. The nonReentrant
            // guard reverts the inner call; that revert bubbles out of this hook,
            // and the UGM's try/catch turns it into "hook: buyout reverted".
            ugm.buySeat(gridId, seatId, 1, 1, 0);
        }
        revert("veto: buyout blocked"); // Revert mode (Reenter never reaches here)
    }

    function onSeatHolderChange(uint256, uint256, address, address) external override { }
    function onForfeit(uint256, uint256, address) external override { }
}

/// @notice Probe module: from inside its observer callbacks it re-enters a
///         guarded UGM function (`claimPayout` with no balance) and records
///         whether the reentrancy guard blocked the inner call. Used to
///         characterize which hook-dispatch paths actually run under the guard.
contract GuardProbeHook is IGridHooksV23 {
    UnifiedGridManager public ugm;
    address public probeToken;
    bool public holderChangeProbed;
    bool public forfeitProbed;
    bool public holderChangeReentryGuardBlocked;
    bool public forfeitReentryGuardBlocked;

    function configure(UnifiedGridManager u, address t) external {
        ugm = u;
        probeToken = t;
    }

    function beforeClaim(uint256, uint256, address, uint256) external pure override returns (bool) {
        return true;
    }

    function beforeBuyout(uint256, uint256, address, address, uint256) external pure override returns (bool) {
        return true;
    }

    function beforePriceChange(uint256, uint256, address, uint256, uint256)
        external
        pure
        override
        returns (bool)
    {
        return true;
    }

    function onSeatHolderChange(uint256, uint256, address, address) external override {
        holderChangeProbed = true;
        holderChangeReentryGuardBlocked = _probe();
    }

    function onForfeit(uint256, uint256, address) external override {
        forfeitProbed = true;
        forfeitReentryGuardBlocked = _probe();
    }

    /// @dev Re-enters a nonReentrant function and returns true iff it reverted
    ///      with the reentrancy-guard error. `claimPayout` with a zero balance
    ///      otherwise reverts with Error("nothing"), so a `false` result proves
    ///      the inner call got PAST the guard (i.e. the guard was not engaged).
    function _probe() internal returns (bool blocked) {
        try ugm.claimPayout(probeToken) returns (uint256) {
            return false;
        } catch (bytes memory err) {
            return err.length == 4 && bytes4(err) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
        }
    }
}

// ===================================================================== //
//                                Tests                                  //
// ===================================================================== //

/// @title Reentrancy + hook-griefing unit tests (NON-fork)
/// @notice Proves (a) `nonReentrant` blocks reentrancy driven by a malicious
///         ERC20, and (b) the 150k governance-hook gas cap + try/catch mean a
///         malicious module cannot grief the protocol. Self-contained: a normal
///         MockERC20 backs the observer/veto grids; the malicious ReentrantToken
///         backs only the reentrancy grid. The test contract is the guardian.
contract ReentrancyTest is Test {
    UnifiedGridManager internal ugm;
    MockERC20 internal token; // normal token: tax == yield
    ReentrantToken internal rtoken; // malicious token, reentrancy grid only

    uint16 internal constant FEE_BPS = 100; // 1% tile-sale (buyout) fee
    uint16 internal constant TAX_BPS = 500; // 5% / week Harberger tax
    uint128 internal constant INIT_PRICE = 1 ether;
    uint32 internal constant SEATS = 4;

    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        ugm = new UnifiedGridManager(address(this), FEE_BPS, 0, 0); // this == guardian/owner
        token = new MockERC20("Mock", "MOCK");
        rtoken = new ReentrantToken();
        rtoken.setUGM(ugm);
        ugm.setAllowedTaxToken(address(token), true);
        ugm.setAllowedTaxToken(address(rtoken), true);

        address[3] memory actors = [creator, alice, bob];
        for (uint256 i = 0; i < actors.length; ++i) {
            token.mint(actors[i], 1000 ether);
            rtoken.mint(actors[i], 1000 ether);
            vm.startPrank(actors[i]);
            token.approve(address(ugm), type(uint256).max);
            rtoken.approve(address(ugm), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------------------------ //
    //                              Helpers                               //
    // ------------------------------------------------------------------ //
    function _createGrid(address t) internal returns (uint256 id) {
        vm.prank(creator);
        id = ugm.createGrid(
            CreateGridParams({
                totalSeats: SEATS,
                taxRateBps: TAX_BPS,
                forfeitureDuration: 0,
                taxToken: t,
                yieldToken: t,
                initialPrice: INIT_PRICE
            })
        );
    }

    function _wireModule(uint256 gridId, address hook) internal {
        ugm.setApprovedModule(hook, true); // guardian approves
        vm.prank(creator);
        ugm.setGridGovernanceModule(gridId, hook); // creator wires it to the grid
    }

    // ================================================================== //
    //     (a) nonReentrant blocks reentrancy via a malicious ERC20        //
    // ================================================================== //

    /// @notice Baseline: with the attack flag OFF the exact same buySeat that the
    ///         next test exercises succeeds. Isolates the guard as the cause.
    function test_Reentrancy_AttackOff_BuySeatSucceeds() public {
        uint256 gridId = _createGrid(address(rtoken));
        rtoken.arm(false, ReentrantToken.Target.BuySeat, gridId, 1);

        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 1 ether, 0);

        Seat memory s = ugm.seatInfo(gridId, 0);
        assertEq(s.holder, alice, "seat claimed when attack is off");
        assertEq(s.price, 2 ether, "new price");
        assertEq(s.deposit, 1 ether, "deposit posted");
    }

    /// @notice With the attack flag ON, the token re-enters buySeat from inside
    ///         transferFrom; the reentrancy guard reverts with the OZ custom error
    ///         (bubbled verbatim through SafeERC20), aborting the whole action.
    function test_Reentrancy_AttackOn_BuySeatReverts() public {
        uint256 gridId = _createGrid(address(rtoken));
        rtoken.arm(true, ReentrantToken.Target.BuySeat, gridId, 1);

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        ugm.buySeat(gridId, 0, 2 ether, 1 ether, 0);

        // No partial state change: the seat is still creator-owned.
        assertEq(ugm.seatInfo(gridId, 0).holder, creator, "state untouched after blocked reentry");
    }

    /// @notice Reentry into a DIFFERENT nonReentrant entry point (claimPayout) is
    ///         equally blocked, showing the guard protects every guarded function.
    function test_Reentrancy_AttackOn_ClaimPayoutReverts() public {
        uint256 gridId = _createGrid(address(rtoken));
        rtoken.arm(true, ReentrantToken.Target.ClaimPayout, gridId, 1);

        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        ugm.buySeat(gridId, 0, 2 ether, 1 ether, 0);

        assertEq(ugm.seatInfo(gridId, 0).holder, creator, "state untouched after blocked reentry");
    }

    // ================================================================== //
    //  (b1) Malicious OBSERVER hook cannot grief buySeat (swallowed)      //
    // ================================================================== //

    function test_ObserverRevert_DoesNotBlockBuySeat() public {
        uint256 gridId = _createGrid(address(token));
        GriefObserverHook hook = new GriefObserverHook();
        hook.setMode(GriefObserverHook.Mode.Revert);
        _wireModule(gridId, address(hook));

        // onSeatHolderChange reverts, but the UGM's empty try/catch swallows it.
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 1 ether, 0);

        assertEq(ugm.seatInfo(gridId, 0).holder, alice, "buySeat succeeds despite reverting observer");
    }

    function test_ObserverGasBomb_DoesNotBlockBuySeat() public {
        uint256 gridId = _createGrid(address(token));
        GriefObserverHook hook = new GriefObserverHook();
        hook.setMode(GriefObserverHook.Mode.GasBomb);
        _wireModule(gridId, address(hook));

        // onSeatHolderChange OOGs under the 150k cap; the try/catch swallows it.
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 1 ether, 0);

        assertEq(ugm.seatInfo(gridId, 0).holder, alice, "buySeat succeeds despite gas-bomb observer");
    }

    // ================================================================== //
    //  (b2) Malicious OBSERVER hook cannot grief a tax forfeit (swallowed)//
    // ================================================================== //

    function test_ObserverRevert_DoesNotBlockForfeit() public {
        _forfeitWithObserver(GriefObserverHook.Mode.Revert);
    }

    function test_ObserverGasBomb_DoesNotBlockForfeit() public {
        _forfeitWithObserver(GriefObserverHook.Mode.GasBomb);
    }

    function _forfeitWithObserver(GriefObserverHook.Mode m) internal {
        uint256 gridId = _createGrid(address(token));
        GriefObserverHook hook = new GriefObserverHook();
        hook.setMode(m);
        _wireModule(gridId, address(hook));

        // Alice claims a thinly-deposited seat (the claim's observer grief is swallowed).
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 10 ether, 0.1 ether, 0);

        // Tax outgrows the 0.1e18 deposit within ~2 days -> forfeiture on poke.
        vm.warp(block.timestamp + 2 days);
        ugm.pokeTax(gridId, 0); // triggers _onForfeit (hostile) -> swallowed

        // Forfeit sends the seat into its Dutch window (vacant), price preserved, deposit consumed.
        assertEq(ugm.seatInfo(gridId, 0).holder, address(0), "forfeit completes despite hostile observer");
        assertEq(ugm.seatInfo(gridId, 0).deposit, 0, "deposit consumed on forfeit");
    }

    // ================================================================== //
    //  (b3) A gating hook can veto ONLY its own action, never corrupt it  //
    // ================================================================== //

    function test_VetoHook_Revert_BlocksBuyoutNoCorruption() public {
        _vetoBuyout(VetoHook.Mode.Revert);
    }

    function test_VetoHook_Reenter_BlocksBuyoutNoCorruption() public {
        _vetoBuyout(VetoHook.Mode.Reenter);
    }

    function _vetoBuyout(VetoHook.Mode m) internal {
        uint256 gridId = _createGrid(address(token));
        VetoHook hook = new VetoHook();
        hook.configure(ugm, m);
        _wireModule(gridId, address(hook));

        // beforeClaim allows, so alice sets up the seat.
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 5 ether, 0);

        uint256 bobBefore = token.balanceOf(bob);

        // beforeBuyout reverts (or its reentry is guard-blocked); the UGM re-reverts
        // with its own hook-revert string. The hook cannot mutate state. Buyouts are not
        // cooldown-gated, so no warp is needed to reach the buyout path.
        vm.prank(bob);
        vm.expectRevert(bytes("hook: buyout reverted"));
        ugm.buySeat(gridId, 0, 3 ether, 5 ether, 0);

        Seat memory s = ugm.seatInfo(gridId, 0);
        assertEq(s.holder, alice, "seat still belongs to alice (no corruption)");
        assertEq(s.price, 2 ether, "alice's price unchanged");
        assertEq(token.balanceOf(bob), bobBefore, "bob spent nothing");
    }

    // ================================================================== //
    //  Hook dispatch is now uniformly guarded (AUDIT-1 F-03 / KI2 fixed). //
    //  pokeTax/pokeTaxBatch carry `nonReentrant` like every other mutator. //
    // ================================================================== //

    /// @notice Every externally-callable state mutator — INCLUDING `pokeTax`/`pokeTaxBatch`,
    ///         which reach an external module call (`onForfeit`) on forfeiture — is now
    ///         `nonReentrant`. This proves the symmetry after the F-03 fix: a hook invoked from
    ///         the `buySeat` path AND the same hook invoked from the `pokeTax` forfeit path both
    ///         hit the reentrancy guard when they try to re-enter a guarded function. Previously
    ///         (KI2) the pokeTax forfeit path was unguarded; this test characterized that gap and
    ///         now locks in the remediation.
    function test_PokeTaxForfeitHookIsReentrancyGuarded() public {
        uint256 gridId = _createGrid(address(token));
        GuardProbeHook hook = new GuardProbeHook();
        hook.configure(ugm, address(token));
        _wireModule(gridId, address(hook));

        // Guarded path: buySeat is nonReentrant -> its onSeatHolderChange hook cannot re-enter.
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 10 ether, 0.1 ether, 0);
        assertTrue(hook.holderChangeProbed(), "observer ran on claim");
        assertTrue(hook.holderChangeReentryGuardBlocked(), "buySeat path: reentry blocked by guard");

        // Fixed path: pokeTax is now nonReentrant -> its onForfeit hook is ALSO blocked from
        // re-entering a guarded function (mirrors the buySeat-path assertion above).
        vm.warp(block.timestamp + 2 days);
        ugm.pokeTax(gridId, 0);
        assertTrue(hook.forfeitProbed(), "observer ran on forfeit");
        assertTrue(hook.forfeitReentryGuardBlocked(), "pokeTax path: reentry now blocked by guard");
    }
}
