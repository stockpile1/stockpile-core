// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {
    VaultUISchema,
    VaultMethodSchema,
    FieldDescriptor,
    ApproveAction
} from "./flap/IVaultSchemasV1.sol";

import {Initializable} from "@openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

// ──────────────────────────────────────────────────────────────────────────────
//  Minimal local interface
// ──────────────────────────────────────────────────────────────────────────────

/// @notice Stockpile grid sink (UnifiedGridManager). The vault forwards realized
///         ERC20 yield (the settlement token) into a grid via `receiveYieldERC20`.
///         The caller MUST be the registered adapter for `assetHash`, and the pushed
///         amount MUST be > 0 (the UGM reverts on a zero amount — see `flush()`).
interface IGridSink {
    function receiveYieldERC20(bytes32 assetHash, address token, uint256 amount) external;
    /// @notice Bind `assetHash` to `gridId` with the CALLER as its adapter. The UGM sets
    ///         `assetAdapter[assetHash] = msg.sender`, so the vault MUST call this itself
    ///         (see `registerWithGrid`) to become the adapter `receiveYieldERC20` accepts.
    ///         Reverts unless the caller is a guardian-approved adapter and the asset is unregistered.
    function registerAsset(uint256 gridId, bytes32 assetHash) external;
}

/// @title StockpileVault
/// @author The Stockpile Team
/// @notice Vault that bridges a Flap token's **ERC20 tax revenue** (the token's quote
///         "stock" asset) into a Stockpile Harberger grid.
///
/// @dev  ── WHY ERC20 (not native BNB) ──────────────────────────────────────────
///
///   A Flap token launched with an ERC20 quote (e.g. SPCXB) collects tax in the
///   token, its `TaxProcessor` liquidates that tax to the **quote token**, and the
///   market portion is sent to this vault (set as the launch `beneficiary`) as a
///   plain ERC20 `transfer`. An ERC20 transfer fires NO receive hook, so — unlike a
///   native-BNB vault — there is no per-receipt entry point: the settlement token
///   simply accumulates on the vault's balance.
///
///   ── FLOW ────────────────────────────────────────────────────────────────────
///
///   1. Tax (settlement token) accrues on `address(this)` via ERC20 transfers. No
///      code runs on receipt.
///   2. Anyone calls `flush()` (permissionless, idempotent): it skims the commission
///      to the treasury and forwards the remainder into the Stockpile grid through
///      the UGM, where it is distributed to seat holders as yield.
///
///   Deployed behind a `BeaconProxy` (upgradeable). The Guardian-controlled beacon
///   upgrade is the primary emergency mechanism; the `emergencyWithdraw*` helpers
///   below are additional, strictly Guardian-gated escape hatches.
contract StockpileVault is Initializable, VaultBaseV2, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // ── Configuration (set once in `initialize`) ──────────────────────────────

    /// @notice The Flap tax token whose tax revenue feeds this vault. Reference-only
    ///         metadata (the vault is agnostic to which token pays it) and may be the
    ///         zero address when a vault is created before its token launches.
    address public taxToken;
    /// @notice Stockpile UnifiedGridManager (grid sink) the vault forwards yield to.
    address public ugm;
    /// @notice Canonical handle of the grid asset this vault feeds.
    bytes32 public assetHash;
    /// @notice The ERC20 settlement token the vault receives as tax and forwards as
    ///         grid yield (the launched token's quote "stock" asset). Also the grid's
    ///         `taxToken`/`yieldToken`.
    address public settlementToken;
    /// @notice Commission skimmed from each `flush()`, in basis points. Capped at {MAX_COMMISSION_BPS}.
    uint16 public commissionBps;
    /// @notice Recipient of the commission skim.
    address public treasury;

    /// @notice Hard cap on `commissionBps` (audit v5 F8): guarantees `flush()` always forwards at least
    ///         90% of every receipt to the grid, so seat holders can never be starved of yield.
    uint16 public constant MAX_COMMISSION_BPS = 1_000; // 10%

    // ── Guardian incident-rescue redirect (facet b — see receive()) ─────────────
    // Appended after the once-set config above to preserve the upgradeable storage
    // layout. Toggled ONLY by the Guardian via `setAutoForward` — never on init.

    /// @notice When true, `receive()` forwards any incoming native BNB straight to
    ///         `forwardAddress` instead of holding it (rescue facet b).
    bool public autoForwardEnabled;
    /// @notice Destination for the incident-rescue native-BNB redirect on `receive()`.
    address public forwardAddress;

    // ── Events ─────────────────────────────────────────────────────────────────

    event Initialized(address indexed taxToken, address indexed ugm, bytes32 assetHash, address settlementToken);
    /// @notice Emitted on each `flush()`: gross balance flushed, commission skimmed, net forwarded to the grid.
    event Flushed(address indexed caller, uint256 gross, uint256 commission, uint256 net);
    event EmergencyWithdrawNative(address indexed to, uint256 amount);
    event EmergencyWithdrawToken(address indexed token, address indexed to, uint256 amount);
    /// @notice Emitted when the Guardian toggles the `receive()` native-BNB auto-forward redirect.
    event AutoForwardSet(bool enabled, address to);
    /// @notice Emitted for each incoming native-BNB amount redirected by the auto-forward switch.
    event NativeForwarded(address to, uint256 amount);

    /// @dev Only the chain Guardian may call. The Guardian address is fixed by the
    ///      chain (see `VaultBase._getGuardian`) and cannot be revoked by any account.
    ///      Per Rule 004 (UI-01) reverts use literal bilingual `require` strings — not
    ///      custom errors — so the generic Flap UI can render the reason as-is.
    modifier onlyGuardian() {
        require(msg.sender == _getGuardian(), unicode"Only Guardian / 仅限 Guardian");
        _;
    }

    /// @dev Disables initializers on the implementation contract so it cannot be
    ///      initialized directly — only proxies pointing at it can.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initialize a freshly deployed `BeaconProxy` of this vault.
    /// @param  _taxToken        Flap tax token feeding this vault (reference-only; may be 0).
    /// @param  _ugm             Stockpile UnifiedGridManager (grid sink).
    /// @param  _assetHash       Canonical handle of the grid asset.
    /// @param  _settlementToken ERC20 settlement token the vault receives + forwards as yield.
    /// @param  _commissionBps   Commission skimmed from each flush, in basis points (<= 10000).
    /// @param  _treasury        Commission recipient.
    function initialize(
        address _taxToken,
        address _ugm,
        bytes32 _assetHash,
        address _settlementToken,
        uint16 _commissionBps,
        address _treasury
    ) external initializer {
        __ReentrancyGuard_init();

        require(
            _ugm != address(0) && _settlementToken != address(0) && _treasury != address(0),
            unicode"Zero address / 零地址"
        );
        require(_commissionBps <= MAX_COMMISSION_BPS, unicode"Commission too high / 佣金过高");

        taxToken = _taxToken;
        ugm = _ugm;
        assetHash = _assetHash;
        settlementToken = _settlementToken;
        commissionBps = _commissionBps;
        treasury = _treasury;

        emit Initialized(_taxToken, _ugm, _assetHash, _settlementToken);
    }

    // ── Native-BNB intake (rescue only; the tax path is ERC20, not native) ──────

    /// @notice Accept stray native BNB. NOT the tax path — the tax settlement token is
    ///         an ERC20 that arrives via plain `transfer` (no hook). When the Guardian
    ///         has armed `setAutoForward`, incoming BNB is best-effort redirected to
    ///         `forwardAddress`; otherwise it is simply held for `emergencyWithdrawNative`.
    receive() external payable {
        if (msg.value == 0) return;
        if (autoForwardEnabled) {
            (bool ok,) = forwardAddress.call{value: msg.value}("");
            ok; // best-effort: never revert an incoming transfer
            emit NativeForwarded(forwardAddress, msg.value);
        }
        // else: hold the BNB; the Guardian can sweep it via emergencyWithdrawNative.
    }

    // ── Grid forwarding (the whole money path — commission is skimmed here) ──────

    /// @notice Skim the commission and push the remaining settlement-token balance into
    ///         the Stockpile grid. Permissionless and idempotent (a zero balance does
    ///         nothing). Unlike a native-BNB vault, ERC20 tax fires no receive hook, so
    ///         the commission is applied here, once, over the balance accrued since the
    ///         last flush — `commission = balance * commissionBps / 10000` to the
    ///         treasury, the remainder to the grid.
    /// @dev    Requires this vault to already be the registered adapter for `assetHash`
    ///         (call `registerWithGrid` once, after the guardian approves it), otherwise
    ///         the UGM rejects the push. `nonReentrant`; CEI-ordered.
    /// @return net Amount of settlement token forwarded to the grid (after commission).
    function flush() external nonReentrant returns (uint256 net) {
        address _tok = settlementToken;
        uint256 bal = IERC20(_tok).balanceOf(address(this));
        if (bal == 0) return 0;

        uint256 fee = (bal * commissionBps) / 10_000;
        net = bal - fee;

        if (fee > 0) IERC20(_tok).safeTransfer(treasury, fee);

        if (net > 0) {
            IERC20(_tok).forceApprove(ugm, net);
            IGridSink(ugm).receiveYieldERC20(assetHash, _tok, net);
        }

        emit Flushed(msg.sender, bal, fee, net);
    }

    /// @notice Bind this vault as the UGM adapter for its grid so `flush()` can deliver yield.
    /// @dev    PERMISSIONLESS one-shot binding (a second call reverts "registered" at the UGM once
    ///         bound). Calls `ugm.registerAsset(gridId, assetHash)`, which sets the UGM's
    ///         `assetAdapter[assetHash]` to THIS vault (the `msg.sender` of that call) — the exact
    ///         identity `receiveYieldERC20` checks inside `flush()`. Because the UGM binds the adapter
    ///         to its own caller, the vault MUST perform the registration itself; a guardian/factory
    ///         calling `registerAsset` would bind the wrong address and permanently break `flush()`.
    ///
    ///         Preconditions enforced by the UGM: the Stockpile guardian must have first approved this
    ///         vault via `ugm.setApprovedAdapter(vault, true)` (else "adapter"), and the asset must be
    ///         unregistered (a second call reverts "registered").
    ///
    ///         `_gridId` is caller-supplied but cryptographically bound: it must reproduce the stored
    ///         `assetHash = keccak256(abi.encode("StockpileVault", vault, gridId))`, so a wrong grid
    ///         reverts here before the UGM is touched — no privileged check is needed.
    /// @param  _gridId The UGM grid this vault feeds, as returned by the factory at creation.
    function registerWithGrid(uint256 _gridId) external {
        require(
            keccak256(abi.encode("StockpileVault", address(this), _gridId)) == assetHash,
            unicode"Grid mismatch / 网格不匹配"
        );
        IGridSink(ugm).registerAsset(_gridId, assetHash);
    }

    /// @notice Settlement token currently accumulated and awaiting `flush()` (gross of commission).
    /// @dev    Never reverts — safe for the UI to poll.
    function pendingFlush() external view returns (uint256) {
        return IERC20(settlementToken).balanceOf(address(this));
    }

    // ── Emergency controls (Guardian-only; never on the receive path) ───────────

    /// @notice Guardian escape hatch to recover native BNB (normally none, since the tax path is ERC20).
    function emergencyWithdrawNative(address to) external onlyGuardian nonReentrant {
        require(to != address(0), unicode"Zero address / 零地址");
        uint256 bal = address(this).balance;
        if (bal > 0) {
            (bool ok,) = to.call{value: bal}("");
            require(ok, unicode"Native transfer failed / 原生转账失败");
            emit EmergencyWithdrawNative(to, bal);
        }
    }

    /// @notice Guardian escape hatch to recover any ERC-20 stuck in the vault (incl. the settlement token).
    function emergencyWithdrawToken(address token, address to) external onlyGuardian nonReentrant {
        require(token != address(0) && to != address(0), unicode"Zero address / 零地址");
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(to, bal);
            emit EmergencyWithdrawToken(token, to, bal);
        }
    }

    /// @notice Arm/disarm the Guardian incident-rescue redirect on `receive()` (facet b).
    /// @dev    Guardian-only. While enabled, incoming native BNB is forwarded to `to` by `receive()`
    ///         (best-effort, non-reverting). Enabling requires a non-zero destination; disabling ignores `to`.
    function setAutoForward(bool enabled, address to) external onlyGuardian {
        if (enabled) require(to != address(0), unicode"Zero address / 零地址");
        autoForwardEnabled = enabled;
        forwardAddress = to;
        emit AutoForwardSet(enabled, to);
    }

    // ── Metadata / UI schema ────────────────────────────────────────────────────

    /// @notice Legacy status string. The UI relies on `vaultUISchema()` for rendering.
    function description() public pure override returns (string memory) {
        return unicode"StockpileVault: bridges a Flap token's ERC20 (stock) tax into a Stockpile grid. Call flush() to forward the accumulated stock."
            unicode" / StockpileVault：将 Flap 代币的 ERC20（stock）税收桥接到 Stockpile 网格。调用 flush() 转发累积的 stock。";
    }

    /// @notice On-chain UI schema describing this vault's runtime actions.
    /// @dev    Reads first, then the single write:
    ///           • `pendingFlush`    (read)  — settlement token accumulated, awaiting flush.
    ///           • `commissionBps`   (read)  — commission skimmed to the treasury (bps).
    ///           • `settlementToken` (read)  — the ERC20 the vault settles + pays yield in.
    ///           • `flush`           (write) — skim commission + forward the rest into the grid.
    ///         `flush` needs no ApproveAction: the vault already custodies the settlement token and
    ///         approves the UGM itself. The token uses decimals 18 for display (see manifest).
    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "StockpileVault";
        schema.description =
            unicode"Bridges a Flap token's ERC20 (stock) tax into a Stockpile Harberger grid. Tax accrues on the vault "
            unicode"as the settlement token; anyone can call flush() to skim the commission and forward the remainder "
            unicode"into the grid, where it is distributed to seat holders as yield."
            unicode" / 将 Flap 代币的 ERC20（stock）税收桥接到 Stockpile Harberger 网格。税收以结算代币形式在金库累积；"
            unicode"任何人都可以调用 flush() 抽取佣金并将其余部分转发到网格，在那里作为收益分配给席位持有者。";

        schema.methods = new VaultMethodSchema[](4);

        // Read: pendingFlush() — the actionable live number driving flush().
        schema.methods[0].name = "pendingFlush";
        schema.methods[0].description =
            unicode"Settlement token currently accumulated in the vault, awaiting flush() to the grid."
            unicode" / 当前在金库中累积、等待通过 flush() 转发到网格的结算代币。";
        schema.methods[0].inputs = new FieldDescriptor[](0);
        schema.methods[0].outputs = new FieldDescriptor[](1);
        schema.methods[0].outputs[0] =
            FieldDescriptor("pending", "uint256", unicode"Pending settlement token awaiting flush() / 等待 flush() 的待处理结算代币", 18);
        schema.methods[0].approvals = new ApproveAction[](0);

        // Read: commissionBps() — the commission cap skimmed to the treasury.
        schema.methods[1].name = "commissionBps";
        schema.methods[1].description =
            unicode"Commission skimmed from each flush() to the treasury, in basis points (100 = 1%)."
            unicode" / 每次 flush() 抽取给国库的佣金，以基点计（100 = 1%）。";
        schema.methods[1].inputs = new FieldDescriptor[](0);
        schema.methods[1].outputs = new FieldDescriptor[](1);
        schema.methods[1].outputs[0] =
            FieldDescriptor("commissionBps", "uint16", unicode"Commission in basis points / 佣金（基点）", 0);
        schema.methods[1].approvals = new ApproveAction[](0);

        // Read: settlementToken() — the ERC20 the vault settles + pays yield in.
        schema.methods[2].name = "settlementToken";
        schema.methods[2].description =
            unicode"The ERC20 settlement token the vault receives as tax and forwards to the grid as yield."
            unicode" / 金库作为税收接收、并作为收益转发到网格的 ERC20 结算代币。";
        schema.methods[2].inputs = new FieldDescriptor[](0);
        schema.methods[2].outputs = new FieldDescriptor[](1);
        schema.methods[2].outputs[0] =
            FieldDescriptor("settlementToken", "address", unicode"Settlement/yield token address / 结算/收益代币地址", 0);
        schema.methods[2].approvals = new ApproveAction[](0);

        // Write: flush() — no inputs, no approvals (vault approves the UGM internally).
        schema.methods[3].name = "flush";
        schema.methods[3].description =
            unicode"Skim the commission and forward the remaining settlement token into the Stockpile grid. Permissionless and idempotent (does nothing when the balance is zero)."
            unicode" / 抽取佣金并将其余结算代币转发到 Stockpile 网格。无需许可且幂等（余额为零时不执行任何操作）。";
        schema.methods[3].inputs = new FieldDescriptor[](0);
        schema.methods[3].outputs = new FieldDescriptor[](0);
        schema.methods[3].approvals = new ApproveAction[](0);
        schema.methods[3].isWriteMethod = true;
    }
}
