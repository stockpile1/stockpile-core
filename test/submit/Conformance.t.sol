// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ForkBase } from "../fork/ForkBase.t.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { BscAddresses } from "../../src/config/BscAddresses.sol";
import { UnifiedGridManager } from "../../src/core/UnifiedGridManager.sol";
import { IYieldAdapter } from "../../src/interfaces/IYieldAdapter.sol";
import { ProtocolYieldAdapter } from "../../src/adapters/ProtocolYieldAdapter.sol";
import { FlapYieldAdapter } from "../../src/adapters/FlapYieldAdapter.sol";
import { PancakeV3YieldAdapter } from "../../src/adapters/PancakeV3YieldAdapter.sol";
import { AntiSnipeHook } from "../../src/hooks/AntiSnipeHook.sol";
import { IGridHooksV23 } from "../../src/interfaces/IGridHooksV23.sol";
import { IHookDescriptor, HookCallbacks } from "../../src/interfaces/IHookDescriptor.sol";
import { CreateGridParams } from "../../src/libraries/GridTypes.sol";
import {
    INonfungiblePositionManager,
    IPancakeV3SwapRouter,
    IPancakeV3Factory,
    IPancakeV3Pool
} from "../../src/interfaces/external/IPancakeV3.sol";

/// @title AdapterConformanceTest
/// @notice Submit-flow conformance harness for every IYieldAdapter, run against the REAL BSC
///         mainnet dependencies (fork). Mirrors the hard constraints in docs/SUBMIT-FLOW.md that
///         an adapter must satisfy before a guardian will `setApprovedAdapter(addr, true)`:
///           - `pendingYield` NEVER reverts (bogus hash AND registered asset);
///           - `collectYield` is idempotent (a 2nd call with no activity forwards 0);
///           - `collectYield` fits the ADAPTER_COLLECT_GAS_CAP (< 600,000 gas);
///           - `collectYield` on an unregistered asset reverts with a decodable string/custom
///             error (never a bare `revert()`).
contract AdapterConformanceTest is ForkBase {
    /// @dev The submit-flow adapter collect-gas cap (UGM.ADAPTER_COLLECT_GAS_CAP).
    uint256 internal constant COLLECT_GAS_CAP = 600_000;

    UnifiedGridManager internal ugm;

    // --- Pancake V3 handles (real BSC contracts) ---
    INonfungiblePositionManager internal npm =
        INonfungiblePositionManager(BscAddresses.PANCAKE_V3_POSITION_MANAGER);
    IPancakeV3SwapRouter internal router = IPancakeV3SwapRouter(BscAddresses.PANCAKE_V3_SWAP_ROUTER);
    IPancakeV3Factory internal factory = IPancakeV3Factory(BscAddresses.PANCAKE_V3_FACTORY);

    uint24 internal constant V3_FEE = 10_000; // 1% tier, tickSpacing 200
    int24 internal constant TICK_LOWER = -887_200;
    int24 internal constant TICK_UPPER = 887_200;
    uint160 internal constant SQRT_P_1TO1 = 79_228_162_514_264_337_593_543_950_336; // 2^96

    function setUp() public {
        _forkBsc();
        ugm = new UnifiedGridManager(address(this), 0, 0, 0);
        ugm.setAllowedTaxToken(BscAddresses.WBNB, true);
    }

    // --------------------------------------------------------------------- //
    //                         Per-adapter conformance                       //
    // --------------------------------------------------------------------- //

    /// @notice ProtocolYieldAdapter: fees accrue directly to the adapter's balance.
    function test_Conformance_ProtocolAdapter() public {
        ProtocolYieldAdapter adapter = new ProtocolYieldAdapter(address(ugm), address(this));
        ugm.setApprovedAdapter(address(adapter), true);

        uint256 gridId = _createWbnbGrid();
        bytes32 assetHash = adapter.registerFeeStream(gridId, BscAddresses.WBNB);

        // Accrue yield: simulate protocol fees routed to the adapter (the fee recipient).
        _mintWBNB(address(adapter), 3 ether);

        _runAdapterConformance(IYieldAdapter(address(adapter)), assetHash, "ProtocolYieldAdapter");
    }

    /// @notice FlapYieldAdapter: EOA stand-in token (no dividendContract) -> collectYield runs the
    ///         best-effort claim try/catches then the authoritative balance sweep. Matches the
    ///         fee-recipient model proven in test/fork/FlapAdapter.fork.t.sol (see DECISIONS D12).
    function test_Conformance_FlapAdapter() public {
        FlapYieldAdapter adapter = new FlapYieldAdapter(
            address(ugm), BscAddresses.FLAP_PORTAL, BscAddresses.FLAP_VAULT_PORTAL, address(this)
        );
        ugm.setApprovedAdapter(address(adapter), true);

        uint256 gridId = _createWbnbGrid();
        address flapToken = makeAddr("flapTaxToken");
        bytes32 assetHash = adapter.registerFlapToken(gridId, flapToken, BscAddresses.WBNB);

        // Accrue yield: Flap tax revenue routed to the adapter (as the dividend/fee recipient).
        _mintWBNB(address(adapter), 3 ether);

        _runAdapterConformance(IYieldAdapter(address(adapter)), assetHash, "FlapYieldAdapter");
    }

    /// @notice PancakeV3YieldAdapter: an isolated real Pancake V3 pool where the adapter's position
    ///         is the sole liquidity; round-trip swaps accrue real fees, then collectYield forwards
    ///         the WBNB (yield) side via a real `positionManager.collect`.
    function test_Conformance_PancakeV3Adapter() public {
        MockERC20 myt = new MockERC20("MockYield", "MYT");
        PancakeV3YieldAdapter adapter =
            new PancakeV3YieldAdapter(address(ugm), address(npm), address(router), address(this));
        ugm.setApprovedAdapter(address(adapter), true);

        // Fund + approve for pool creation and swaps.
        _mintWBNB(address(this), 500 ether);
        myt.mint(address(this), 1_000_000 ether);
        IERC20(address(WBNB)).approve(address(npm), type(uint256).max);
        myt.approve(address(npm), type(uint256).max);
        IERC20(address(WBNB)).approve(address(router), type(uint256).max);
        myt.approve(address(router), type(uint256).max);

        // Isolated pool with the adapter as the sole LP.
        (address token0, address token1) =
            address(myt) < BscAddresses.WBNB ? (address(myt), BscAddresses.WBNB) : (BscAddresses.WBNB, address(myt));
        address pool = factory.createPool(token0, token1, V3_FEE);
        IPancakeV3Pool(pool).initialize(SQRT_P_1TO1);

        (uint256 tokenId,,,) = npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: V3_FEE,
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                amount0Desired: 200 ether,
                amount1Desired: 200 ether,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(adapter),
                deadline: block.timestamp
            })
        );

        // Accrue real fees on BOTH sides (WBNB->MYT legs accrue the WBNB yield side).
        _swap(address(myt), BscAddresses.WBNB, 20 ether);
        _swap(BscAddresses.WBNB, address(myt), 20 ether);
        _swap(address(myt), BscAddresses.WBNB, 20 ether);
        _swap(BscAddresses.WBNB, address(myt), 20 ether);

        uint256 gridId = _createWbnbGrid();
        bytes32 assetHash = adapter.registerPosition(gridId, tokenId, BscAddresses.WBNB, V3_FEE);

        _runAdapterConformance(IYieldAdapter(address(adapter)), assetHash, "PancakeV3YieldAdapter");
    }

    // --------------------------------------------------------------------- //
    //                     Shared adapter conformance body                   //
    // --------------------------------------------------------------------- //
    /// @dev `assetHash` must be registered AND have yield already accrued so the measured
    ///      `collectYield` is a realistic (non-empty) worst case.
    function _runAdapterConformance(IYieldAdapter adapter, bytes32 assetHash, string memory label) internal {
        bytes32 bogus = keccak256(abi.encode("bogus", label));

        // (1) pendingYield NEVER reverts — bogus hash AND registered asset.
        assertTrue(_pendingYieldSafe(adapter, bogus), "pendingYield(bogus) must never revert");
        assertTrue(_pendingYieldSafe(adapter, assetHash), "pendingYield(registered) must never revert");

        // (2) collectYield on an unregistered asset reverts with a decodable string (not bare revert()).
        //     All adapters guard with `require(registered, "not registered")` before any external call.
        vm.expectRevert(bytes("not registered"));
        adapter.collectYield(bogus);

        // (3) collectYield gas budget: measure the real, yield-forwarding call (< 600,000).
        uint256 g0 = gasleft();
        uint256 forwarded = adapter.collectYield(assetHash);
        uint256 used = g0 - gasleft();
        console2.log(string.concat(label, ": collectYield gas ="), used);
        console2.log(string.concat(label, ": collectYield forwarded ="), forwarded);
        assertGt(forwarded, 0, "measured collectYield should forward accrued yield");
        assertLt(used, COLLECT_GAS_CAP, "collectYield must fit ADAPTER_COLLECT_GAS_CAP");

        // (4) Idempotency: a 2nd collectYield with no new activity forwards 0.
        uint256 forwarded2 = adapter.collectYield(assetHash);
        assertEq(forwarded2, 0, "2nd collectYield with no activity must forward 0");
    }

    /// @dev Returns true iff `pendingYield` returned without reverting.
    function _pendingYieldSafe(IYieldAdapter adapter, bytes32 assetHash) internal view returns (bool ok) {
        try adapter.pendingYield(assetHash) returns (uint256) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    // --------------------------------------------------------------------- //
    //                                Helpers                                //
    // --------------------------------------------------------------------- //
    function _createWbnbGrid() internal returns (uint256 gridId) {
        gridId = ugm.createGrid(
            CreateGridParams({
                totalSeats: 4,
                taxRateBps: 500,
                forfeitureDuration: 0,
                taxToken: BscAddresses.WBNB,
                yieldToken: BscAddresses.WBNB,
                initialPrice: 1 ether
            })
        );
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn) internal {
        router.exactInputSingle(
            IPancakeV3SwapRouter.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: V3_FEE,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }
}

/// @title HookConformanceTest
/// @notice Submit-flow conformance harness for governance hook modules (AntiSnipeHook). No fork
///         needed — a UGM + MockERC20 grid is enough. Mirrors docs/SUBMIT-FLOW.md:
///           - every callback fits the GOVERNANCE_HOOK_GAS_CAP (< 150,000 gas);
///           - a veto surfaces as a decodable revert reason at the UGM ("hook: claim vetoed");
///           - observer callbacks (onForfeit / onSeatHolderChange) NEVER revert;
///           - IHookDescriptor returns sane values.
contract HookConformanceTest is Test {
    /// @dev The submit-flow hook callback-gas cap (UGM.GOVERNANCE_HOOK_GAS_CAP).
    uint256 internal constant HOOK_GAS_CAP = 150_000;

    UnifiedGridManager internal ugm;
    AntiSnipeHook internal hook;
    MockERC20 internal token;

    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    uint256 internal gridId;

    function setUp() public {
        ugm = new UnifiedGridManager(address(this), 0, 0, 0); // guardian = this
        hook = new AntiSnipeHook(address(this)); // hook owner = this
        token = new MockERC20("Tax", "TAX");
        ugm.setAllowedTaxToken(address(token), true);

        token.mint(creator, 1000 ether);
        token.mint(alice, 1000 ether);
        vm.prank(creator);
        token.approve(address(ugm), type(uint256).max);
        vm.prank(alice);
        token.approve(address(ugm), type(uint256).max);

        vm.prank(creator);
        gridId = ugm.createGrid(
            CreateGridParams({
                totalSeats: 4,
                taxRateBps: 500,
                forfeitureDuration: 0,
                taxToken: address(token),
                yieldToken: address(token),
                initialPrice: 1 ether
            })
        );

        ugm.setApprovedModule(address(hook), true); // guardian approves module
        vm.prank(creator);
        ugm.setGridGovernanceModule(gridId, address(hook)); // creator wires it
    }

    /// @notice Every IGridHooksV23 callback must fit the 150k governance-hook gas cap.
    function test_Conformance_HookCallbacksUnder150k() public {
        // Exercise the gated path too: a future open time makes beforeClaim take its SLOAD branch.
        hook.setClaimOpenAt(gridId, uint64(block.timestamp + 1 hours));

        _assertCallbackUnderCap("beforeClaim", _gasBeforeClaim());
        _assertCallbackUnderCap("beforeBuyout", _gasBeforeBuyout());
        _assertCallbackUnderCap("beforePriceChange", _gasBeforePriceChange());
        _assertCallbackUnderCap("onSeatHolderChange", _gasOnSeatHolderChange());
        _assertCallbackUnderCap("onForfeit", _gasOnForfeit());
    }

    /// @notice The gating veto must surface as a decodable revert reason at the UGM.
    function test_Conformance_VetoIsDecodableAtUGM() public {
        hook.setClaimOpenAt(gridId, uint64(block.timestamp + 1 hours));
        vm.prank(alice);
        vm.expectRevert(bytes("hook: claim vetoed"));
        ugm.buySeat(gridId, 0, 1 ether, 10 ether, 0);
    }

    /// @notice Observer callbacks must NEVER revert (the UGM calls them post-state-change and only
    ///         try/catches them; a reverting observer would still be bad-citizen behaviour).
    function test_Conformance_ObserversNeverRevert() public {
        bool ok1;
        try hook.onForfeit(gridId, 0, alice) {
            ok1 = true;
        } catch {
            ok1 = false;
        }
        assertTrue(ok1, "onForfeit must never revert");

        bool ok2;
        try hook.onSeatHolderChange(gridId, 0, alice, creator) {
            ok2 = true;
        } catch {
            ok2 = false;
        }
        assertTrue(ok2, "onSeatHolderChange must never revert");
    }

    /// @notice IHookDescriptor returns sane, decodable identity metadata.
    function test_Conformance_HookDescriptorSaneValues() public view {
        IHookDescriptor d = IHookDescriptor(address(hook));

        assertEq(d.hookKind(), keccak256("ANTI_SNIPE"), "hookKind == keccak256(ANTI_SNIPE)");
        assertTrue(d.hookKind() != bytes32(0), "hookKind must be non-zero");
        assertEq(uint256(d.hookVersion()), 1, "hookVersion == 1");

        uint256 cbs = d.supportedCallbacks();
        assertEq(cbs, HookCallbacks.BEFORE_CLAIM, "supportedCallbacks == BEFORE_CLAIM bit");
        assertTrue(cbs & HookCallbacks.BEFORE_CLAIM != 0, "advertises beforeClaim");

        assertGt(bytes(d.description()).length, 0, "description must be non-empty");
    }

    // --------------------------------------------------------------------- //
    //                          Gas-metering helpers                         //
    // --------------------------------------------------------------------- //
    function _assertCallbackUnderCap(string memory name, uint256 used) internal {
        console2.log(string.concat("AntiSnipeHook.", name, " gas ="), used);
        assertLt(used, HOOK_GAS_CAP, string.concat(name, " must fit GOVERNANCE_HOOK_GAS_CAP"));
    }

    function _gasBeforeClaim() internal returns (uint256 used) {
        uint256 g0 = gasleft();
        IGridHooksV23(address(hook)).beforeClaim(gridId, 0, alice, 1 ether);
        used = g0 - gasleft();
    }

    function _gasBeforeBuyout() internal returns (uint256 used) {
        uint256 g0 = gasleft();
        IGridHooksV23(address(hook)).beforeBuyout(gridId, 0, alice, creator, 1 ether);
        used = g0 - gasleft();
    }

    function _gasBeforePriceChange() internal returns (uint256 used) {
        uint256 g0 = gasleft();
        IGridHooksV23(address(hook)).beforePriceChange(gridId, 0, alice, 1 ether, 2 ether);
        used = g0 - gasleft();
    }

    function _gasOnSeatHolderChange() internal returns (uint256 used) {
        uint256 g0 = gasleft();
        IGridHooksV23(address(hook)).onSeatHolderChange(gridId, 0, alice, creator);
        used = g0 - gasleft();
    }

    function _gasOnForfeit() internal returns (uint256 used) {
        uint256 g0 = gasleft();
        IGridHooksV23(address(hook)).onForfeit(gridId, 0, alice);
        used = g0 - gasleft();
    }
}
