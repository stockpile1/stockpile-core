// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/// @notice Grid-creation parameters. Copied EXACTLY (field order + types) from
///         `StockpileVaultFactory.sol` so the ABI-encoded `createGrid` call the
///         factory makes decodes cleanly against this stand-in.
struct CreateGridParams {
    uint32 totalSeats;
    uint16 taxRateBps;
    uint32 forfeitureDuration;
    address taxToken;
    address yieldToken;
    uint128 initialPrice;
}

/// @notice Immutable grid configuration returned by `gridConfig`. Field order + types are copied
///         EXACTLY from `contracts/core/src/libraries/GridTypes.sol` (and mirrored by
///         `MultiStockVault`'s own `GridConfig`) so `IGridSink.gridConfig` ABI-decodes cleanly.
///         The mock only populates `yieldToken` (from `gridYieldToken`); the rest stay default.
struct GridConfig {
    address creator;
    uint64 createdAt;
    uint32 totalSeats;
    uint16 taxRateBps;
    uint32 forfeitureDuration;
    address taxToken;
    address yieldToken;
}

/// @title MockUGM
/// @notice Minimal stand-in for the Stockpile UnifiedGridManager (UGM) that the
///         {StockpileVaultFactory} and {StockpileVault} call. It:
///           • `createGrid`         — hands out monotonically increasing grid ids
///                                     and records the last params passed in.
///           • `approvedAdapters`   — guardian-managed adapter allowlist (public getter).
///           • `assetToGrid`        — asset->grid wiring, 0 == unregistered (public getter).
///           • `receiveYieldERC20`  — pulls the pushed WBNB from the approved
///                                     adapter (via transferFrom, mirroring the
///                                     real UGM) and records the last yield push.
///         Exposes `setApprovedAdapter` / `setAssetToGrid` so tests can flip the
///         approval-bridge state that {StockpileVaultFactory.pendingApproval} reads.
contract MockUGM {
    // ── createGrid bookkeeping ──────────────────────────────────────────────
    /// @notice Monotonic grid-id counter; first created grid has id 1.
    uint256 public gridCounter;
    /// @notice Number of times `createGrid` was called.
    uint256 public createGridCallCount;
    /// @notice Grid id returned by the most recent `createGrid`.
    uint256 public lastGridId;
    /// @notice Params supplied to the most recent `createGrid`.
    CreateGridParams public lastGridParams;
    /// @notice grid -> creator (the `createGrid` caller), mirroring the real UGM. The factory is
    ///         the creator of every grid it launches, so creator-side revenue accrues to it.
    mapping(uint256 => address) public gridCreator;

    // ── Creator-payout bookkeeping (facet for StockpileVaultFactory.sweepCreatorRevenue) ─
    /// @notice Claimable creator payout per token, seedable by tests via `seedPayout`.
    mapping(address => uint256) public payoutOf;
    /// @notice Number of times `claimYieldBatch` was called.
    uint256 public claimYieldBatchCallCount;
    /// @notice gridId supplied to the most recent `claimYieldBatch`.
    uint256 public lastClaimYieldGridId;
    /// @notice seatIds supplied to the most recent `claimYieldBatch`.
    uint256[] public lastClaimYieldSeatIds;

    // ── Approval-bridge state (guardian-managed on the real UGM) ─────────────
    /// @notice Adapter allowlist probed by `pendingApproval`.
    mapping(address => bool) public approvedAdapters;
    /// @notice asset -> grid wiring probed by `pendingApproval` (0 == unregistered).
    mapping(bytes32 => uint256) public assetToGrid;
    /// @notice asset -> registered adapter. Set by `registerAsset` to its own caller, exactly
    ///         like the real UGM; `receiveYieldERC20` requires `msg.sender` to equal this.
    mapping(bytes32 => address) public assetAdapter;
    /// @notice grid -> configured yieldToken, seeded by tests via `setGridYieldToken`. Surfaced by
    ///         `gridConfig` so `MultiStockVault.registerWithGrid`'s F3 assert (grid.yieldToken == stock)
    ///         can be exercised. 0 (unset) makes the assert fail, mirroring a misconfigured grid.
    mapping(uint256 => address) public gridYieldToken;
    /// @notice grid -> configured `totalSeats`, seeded by tests via `setGridTotalSeats`. Surfaced by
    ///         `gridConfig` so `StockpileBasketVault.distribute`'s seat-proportional grid split can be
    ///         exercised across grids of DIFFERENT sizes. 0 (unset) keeps the field at its default.
    mapping(uint256 => uint32) public gridTotalSeats;

    /// @notice Per-assetHash kill switch: when true, `receiveYieldERC20` REVERTS for that asset (mirrors a
    ///         failing / hijacked / paused grid). Lets the `StockpileBasketVault` suite exercise the
    ///         best-effort per-grid push (audit S6) — a reverting grid must be SKIPPED, not brick the batch.
    mapping(bytes32 => bool) public forceReceiveRevertOf;

    // ── receiveYieldERC20 bookkeeping ───────────────────────────────────────
    uint256 public receiveYieldCallCount;
    bytes32 public lastYieldAssetHash;
    address public lastYieldToken;
    uint256 public lastYieldAmount;
    /// @notice ACCUMULATED yield received per asset hash. Additive to the "last push"
    ///         fields above so a multi-leg pusher (e.g. MultiStockVault, 7 legs in one
    ///         `distribute`) can be asserted leg-by-leg, not just on the final push.
    mapping(bytes32 => uint256) public yieldByAsset;

    /// @notice Permissionless grid creation. Records params + the caller as the grid
    ///         `creator` (mirroring the real UGM), returns a fresh id.
    function createGrid(CreateGridParams calldata p) external returns (uint256 gridId) {
        gridCounter += 1;
        gridId = gridCounter;
        lastGridId = gridId;
        lastGridParams = p;
        gridCreator[gridId] = msg.sender;
        createGridCallCount += 1;
    }

    /// @notice Test helper: seed a claimable creator payout in `token` (units of that token).
    /// @dev    The test MUST also fund this contract with the matching token balance so
    ///         `claimPayout` can actually transfer it out (the real UGM already custodies it).
    function seedPayout(address token, uint256 amount) external {
        payoutOf[token] += amount;
    }

    /// @notice Faithful-enough mirror of `UnifiedGridManager.claimPayout`: pay the CALLER its
    ///         entire accrued payout in `token` and return the amount. The factory is the grid
    ///         creator, so this is how it pulls creator-side revenue to itself.
    function claimPayout(address token) external returns (uint256 amount) {
        amount = payoutOf[token];
        if (amount != 0) {
            payoutOf[token] = 0;
            IERC20(token).transfer(msg.sender, amount);
        }
    }

    /// @notice Mirror of `UnifiedGridManager.claimYieldBatch`: in the real UGM this settles
    ///         unsold-seat yield into the creator's claimable payouts. Here it just records the
    ///         call so the factory sweep test can assert it ran (the payout is seeded directly).
    function claimYieldBatch(uint256 gridId, uint256[] calldata seatIds) external {
        lastClaimYieldGridId = gridId;
        lastClaimYieldSeatIds = seatIds;
        claimYieldBatchCallCount += 1;
    }

    /// @notice Test/guardian setter to flip an adapter's allowlist status.
    function setApprovedAdapter(address adapter, bool approved) external {
        approvedAdapters[adapter] = approved;
    }

    /// @notice Test setter for a grid's configured yieldToken (read back via `gridConfig`).
    function setGridYieldToken(uint256 gridId, address token) external {
        gridYieldToken[gridId] = token;
    }

    /// @notice Test setter to force `receiveYieldERC20` to REVERT for a given asset (audit S6): simulates
    ///         a failing / hijacked / paused grid so the vault's best-effort per-grid skip can be asserted.
    function setForceReceiveRevert(bytes32 assetHash, bool r) external {
        forceReceiveRevertOf[assetHash] = r;
    }

    /// @notice Test setter for a grid's configured `totalSeats` (read back via `gridConfig`). Lets the
    ///         `StockpileBasketVault` suite give each grid a distinct seat count so the seat-proportional
    ///         split can be asserted.
    function setGridTotalSeats(uint256 gridId, uint32 seats) external {
        gridTotalSeats[gridId] = seats;
    }

    /// @notice Faithful-enough mirror of `UnifiedGridManager.gridConfig`: returns a `GridConfig`
    ///         whose layout matches the real UGM, with `yieldToken` filled from `gridYieldToken` and
    ///         `totalSeats` from `gridTotalSeats` (other fields default). Enough for both
    ///         `MultiStockVault`'s F3 yieldToken assert and `StockpileBasketVault`'s seat split.
    function gridConfig(uint256 gridId) external view returns (GridConfig memory c) {
        c.yieldToken = gridYieldToken[gridId];
        c.totalSeats = gridTotalSeats[gridId];
    }

    /// @notice Test/guardian setter to register (or clear) an asset -> grid wiring.
    /// @dev    Raw poke that does NOT set `assetAdapter` — kept for constructing arbitrary
    ///         states. The faithful bind path is `registerAsset` (called BY the adapter).
    function setAssetToGrid(bytes32 assetHash, uint256 gridId) external {
        assetToGrid[assetHash] = gridId;
    }

    /// @notice Faithful mirror of `UnifiedGridManager.registerAsset`: binds `assetHash` to
    ///         `gridId` with the CALLER as its adapter. The caller must be a guardian-approved
    ///         adapter and the asset must be unregistered — the same requires the real UGM makes.
    ///         This is what `StockpileVault.registerWithGrid` invokes so the vault becomes the
    ///         adapter `receiveYieldERC20` accepts.
    function registerAsset(uint256 gridId, bytes32 assetHash) external {
        require(approvedAdapters[msg.sender], "adapter");
        require(assetToGrid[assetHash] == 0, "registered");
        assetToGrid[assetHash] = gridId;
        assetAdapter[assetHash] = msg.sender;
    }

    /// @notice Records a yield push (the vault forwards WBNB here via `flush`) and
    ///         pulls the tokens in, mirroring the real UGM.
    /// @dev    The vault force-approves this contract in `flush()` before calling,
    ///         so `transferFrom` succeeds. Reverts on a zero amount, exactly like
    ///         the real UGM (the vault's `flush()` guards against ever calling with
    ///         zero). Pulling the tokens is what drains the vault's WBNB to zero.
    function receiveYieldERC20(bytes32 assetHash, address token, uint256 amount) external {
        // Test-only fault injection (audit S6): simulate a failing / hijacked / paused grid so the
        // vault's best-effort per-grid push must skip this one and still feed the others.
        require(!forceReceiveRevertOf[assetHash], "forced yield revert");
        // Mirror the real UnifiedGridManager adapter gate (same require order + strings) so
        // `flush()` tests exercise the TRUE flushability condition: the asset must be registered
        // ("asset") and only its registered adapter may push yield ("not adapter").
        require(assetToGrid[assetHash] != 0, "asset");
        require(msg.sender == assetAdapter[assetHash], "not adapter");
        require(amount > 0, "amount");

        // Pull the yield in — the vault (the registered adapter) force-approved us in flush().
        IERC20(token).transferFrom(msg.sender, address(this), amount);

        lastYieldAssetHash = assetHash;
        lastYieldToken = token;
        lastYieldAmount = amount;
        yieldByAsset[assetHash] += amount;
        receiveYieldCallCount += 1;
    }
}
