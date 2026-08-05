// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { IGrid } from "../interfaces/IGrid.sol";
import { IGridHooksV23 } from "../interfaces/IGridHooksV23.sol";
import { IFeeReceiver } from "../interfaces/IFeeReceiver.sol";
import { GridConfig, Seat, CreateGridParams } from "../libraries/GridTypes.sol";
import { HarbergerMath } from "../libraries/HarbergerMath.sol";

/// @title UnifiedGridManager (Takeover BNB port)
/// @notice Minimal, self-contained reimplementation of Takeover's UnifiedGridManagerV22
///         Harberger-seat engine, targeted at BNB Smart Chain.
/// @dev This is a scaffold: it implements the core mechanics documented in the Takeover
///      whitepaper (self-assessed pricing, continuous weekly tax, permissionless buyouts,
///      Dutch-auction forfeiture, protocol/creator fee splits, per-seat equal yield
///      distribution, adapter yield sink, governance hooks) in a SINGLE contract. The
///      production Base deployment splits logic into a delegatecall library (`UGMV22Linked`)
///      to fit EIP-170; that split, chunked grid creation above 1024 seats, per-seat initial
///      price vectors, lazy materialization and the flETH/WETH native-yield path are left as
///      documented extensions (see docs/DECISIONS.md D5/D11).
contract UnifiedGridManager is IGrid, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using HarbergerMath for uint256;

    // --------------------------------------------------------------------- //
    //                               Constants                               //
    // --------------------------------------------------------------------- //
    uint256 public constant MIN_TOTAL_SEATS = 4;
    /// @dev Absolute per-grid seat ceiling, enforced in `createGrid` (F-06 / KI1). Today it is
    ///      subsumed by the 1024 single-tx cap below, so it is a self-documenting bound that
    ///      never binds in the single-tx flow; it becomes the effective ceiling for any future
    ///      chunked/`createGridShell` flow that raises `MAX_SINGLE_TX_CREATE_TOTAL_SEATS`, keeping
    ///      the per-seat loops (createGrid, pendingYield) bounded.
    uint256 public constant MAX_TOTAL_SEATS = 4096;
    uint256 public constant MAX_SINGLE_TX_CREATE_TOTAL_SEATS = 1024;
    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_TAX_BPS = 10; // 0.1% / week
    uint256 public constant MAX_TAX_BPS = 1000; // 10% / week
    /// @dev Hard cap on every guardian-set protocol/creator BPS knob (10% each). The seat-sale
    ///      knobs (protocol + creator + forfeiture penalty) must also sum to strictly < BPS so a
    ///      seller is never zeroed out.
    uint256 public constant MAX_PROTOCOL_BPS = 5000;
    uint256 public constant ADAPTER_COLLECT_GAS_CAP = 600_000;
    uint256 public constant GOVERNANCE_HOOK_GAS_CAP = 150_000;
    /// @dev Friction on the FREE re-pricing path: {setPrice} is refused within this window of acquiring
    ///      the seat or of its last price change. Buyouts are NEVER gated by it — seats remain buyable at
    ///      the stated price at any time.
    ///
    ///      NOT an absolute invariant, and deliberately so. A holder in a hurry can still re-price by
    ///      {abandonSeat} + {buySeat} on the now-vacant seat: at `elapsed == 0` the Dutch clearing price
    ///      is the full preserved price, and {_routeDutchClearing} pays it back to them minus
    ///      `protocolSeatSaleBps + creatorSeatSaleBps`. So the cooldown is not bypassed for free — it is
    ///      bought out, at those bps of the seat's own self-assessed price, every time.
    ///
    ///      That is the intended shape: no counterparty can be harmed by an early re-price (buyouts are
    ///      never cooldown-gated and carry a `maxPrice` slippage bound), the seat must transit a publicly
    ///      claimable vacancy at its full price, and the escape hatch is priced rather than free.
    uint256 public constant PRICE_COOLDOWN = 20 minutes;
    /// @dev Default Dutch decay window applied when a grid is created with forfeitureDuration 0.
    uint32 public constant DEFAULT_FORFEITURE_DURATION = 10 minutes;
    /// @dev Hard cap on a grid's Dutch decay window.
    uint32 public constant MAX_FORFEITURE_DURATION = 30 days;
    uint256 internal constant ACC_PRECISION = 1e18;

    // --------------------------------------------------------------------- //
    //                                Storage                                //
    // --------------------------------------------------------------------- //
    uint256 public gridCount; // grids are 1-indexed

    mapping(uint256 => GridConfig) internal _configs;
    mapping(uint256 => mapping(uint256 => Seat)) internal _seats;

    /// @dev Prior holder snapshotted at every forfeit entry (tax-underwater or voluntary
    ///      abandon). `_claimVacantSeat` pays the Dutch clearing price back to them; cleared on
    ///      reassignment.
    mapping(uint256 => mapping(uint256 => address)) public forfeitedFrom;
    /// @dev True when a seat entered its Dutch window via tax-underwater forfeit (not a voluntary
    ///      abandon); makes `_claimVacantSeat` apply the extra `forfeiturePenaltyBps` cut.
    mapping(uint256 => mapping(uint256 => bool)) internal forfeitedByTax;

    // Equal-share yield accounting: cumulative yield per seat (scaled by ACC_PRECISION).
    mapping(uint256 => uint256) internal _accYieldPerSeat;
    mapping(uint256 => mapping(uint256 => uint256)) internal _seatYieldPaid;

    // Claimable balances: token => user => amount. Yield, tax creator-share, creator seat-sale
    // cut and Dutch-reclaim seller proceeds all land here and are pulled via `claimPayout`.
    mapping(address => mapping(address => uint256)) public payouts;

    /// @notice Protocol fee bucket per grid (in the grid's taxToken): the protocol cut of settled
    ///         Harberger tax + the protocol cut of every seat sale + Dutch forfeiture penalties.
    ///         Swept to `protocolFeeReceiver` by the guardian via `withdrawTaxRevenue`.
    mapping(uint256 => uint256) public gridTaxRevenue;

    /// @notice Buyback/fee sink the protocol fee bucket is routed to (guardian-set).
    address public protocolFeeReceiver;

    // Adapter registry and asset wiring.
    mapping(address => bool) public approvedAdapters;
    mapping(bytes32 => uint256) public assetToGrid; // 0 = unregistered
    mapping(bytes32 => address) public assetAdapter;

    // Governance hook modules.
    mapping(address => bool) public approvedModules;
    mapping(uint256 => address) public gridGovernanceModule;
    mapping(address => bool) public moduleDisabled;

    // Guardian safety controls.
    bool public gridCreationPaused;
    mapping(uint256 => bool) public gridPaused;
    mapping(uint256 => bool) public gridDeprecated;
    /// @notice Guardian allowlist of tokens permitted as a grid's taxToken.
    mapping(address => bool) public allowedTaxTokens;

    // Fee split knobs (guardian-set, each <= MAX_PROTOCOL_BPS).
    uint16 public protocolSeatSaleBps; // protocol cut of every seat sale
    uint16 public creatorSeatSaleBps; // creator cut of secondary (buyout / Dutch) seat sales
    uint16 public protocolTaxBps; // protocol cut of settled Harberger tax (remainder -> creator)
    uint16 public forfeiturePenaltyBps; // extra protocol cut on tax-underwater Dutch reclaims

    // --------------------------------------------------------------------- //
    //                                Events                                 //
    // --------------------------------------------------------------------- //
    /// @notice Emitted when a new grid is created.
    event GridCreated(uint256 indexed gridId, address indexed creator, uint32 totalSeats, address taxToken, address yieldToken);

    /// @notice Emitted when a seat is claimed, bought out, or reclaimed via Dutch auction.
    /// @param seller The previous holder; the creator for an initial claim, `address(0)` for a
    ///        Dutch reclaim of a vacant seat (see `forfeitedFrom` for the compensated party).
    /// @param pricePaid The price paid to the seller (declared price, or Dutch clearing price).
    event SeatBought(uint256 indexed gridId, uint256 indexed seatId, address indexed buyer, address seller, uint256 pricePaid, uint256 newPrice);

    /// @notice Emitted when a holder changes a seat's self-assessed price.
    event PriceChanged(uint256 indexed gridId, uint256 indexed seatId, uint256 oldPrice, uint256 newPrice);

    /// @notice Emitted when a holder tops up a seat's tax deposit.
    event DepositAdded(uint256 indexed gridId, uint256 indexed seatId, uint256 amount);

    /// @notice Emitted when a holder withdraws unspent tax deposit.
    event DepositWithdrawn(uint256 indexed gridId, uint256 indexed seatId, uint256 amount);

    /// @notice Emitted when accrued tax is settled from a seat's deposit.
    event TaxSettled(uint256 indexed gridId, uint256 indexed seatId, uint256 taxPaid);

    /// @notice Emitted when a seat's deposit is exhausted by tax and it enters its Dutch window.
    /// @param formerHolder The holder that lost the seat (snapshotted into `forfeitedFrom`).
    /// @param taxPaid The remaining deposit consumed as final tax.
    event Forfeited(uint256 indexed gridId, uint256 indexed seatId, address indexed formerHolder, uint256 taxPaid);

    /// @notice Emitted when a holder voluntarily abandons a seat into its Dutch window.
    event SeatAbandoned(uint256 indexed gridId, uint256 indexed seatId, address indexed formerHolder);

    /// @notice Emitted when a vacant (forfeited/abandoned) seat is reclaimed via Dutch auction.
    event SeatReclaimed(uint256 indexed gridId, uint256 indexed seatId, address indexed buyer, address forfeitedFrom, uint256 clearingPrice);

    /// @notice Emitted when realized yield is delivered by an adapter and distributed across seats.
    event YieldReceived(uint256 indexed gridId, bytes32 indexed assetHash, address token, uint256 amount);

    /// @notice Emitted when a user withdraws a claimable token balance.
    event PayoutClaimed(address indexed token, address indexed user, uint256 amount);

    /// @notice Emitted when an adapter wires an asset to a grid.
    event AssetRegistered(uint256 indexed gridId, bytes32 indexed assetHash, address indexed adapter);

    /// @notice Emitted when an adapter unwires an asset from a grid.
    event AssetWithdrawn(uint256 indexed gridId, bytes32 indexed assetHash);

    /// @notice Emitted when an adapter's approval status is changed by the owner.
    event AdapterApprovalSet(address indexed adapter, bool approved);

    /// @notice Emitted when a governance module's approval status is changed by the owner.
    event ModuleApprovalSet(address indexed module, bool approved);

    /// @notice Emitted when a grid's active governance module is set.
    event GridModuleSet(uint256 indexed gridId, address indexed module);

    /// @notice Emitted when a grid's accrued protocol revenue is swept to the fee receiver.
    event TaxRevenueWithdrawn(uint256 indexed gridId, address indexed to, uint256 amount);

    /// @notice Emitted when the guardian updates a tax-token's allow status.
    event AllowedTaxTokenUpdated(address indexed token, bool allowed);

    /// @notice Emitted when the guardian sets the protocol fee receiver.
    event ProtocolFeeReceiverUpdated(address indexed receiver);

    /// @notice Emitted when a guardian fee-split knob changes.
    event FeeBpsUpdated(string indexed knob, uint16 oldBps, uint16 newBps);

    /// @notice Emitted when the guardian deprecates a grid (blocks new acquisitions).
    event GridDeprecated(uint256 indexed gridId);

    // --------------------------------------------------------------------- //
    //                              Constructor                              //
    // --------------------------------------------------------------------- //
    /// @notice Deploy the grid manager under a guardian owner with the initial fee-split knobs.
    /// @param guardian_ The guardian multisig set as contract owner.
    /// @param protocolSeatSaleBps_ Protocol cut of every seat sale (<= MAX_PROTOCOL_BPS).
    /// @param creatorSeatSaleBps_ Creator cut of secondary seat sales (<= MAX_PROTOCOL_BPS).
    /// @param protocolTaxBps_ Protocol cut of settled Harberger tax (<= MAX_PROTOCOL_BPS).
    constructor(address guardian_, uint16 protocolSeatSaleBps_, uint16 creatorSeatSaleBps_, uint16 protocolTaxBps_)
        Ownable(guardian_)
    {
        require(
            protocolSeatSaleBps_ <= MAX_PROTOCOL_BPS && creatorSeatSaleBps_ <= MAX_PROTOCOL_BPS
                && protocolTaxBps_ <= MAX_PROTOCOL_BPS,
            "bps"
        );
        require(uint256(protocolSeatSaleBps_) + creatorSeatSaleBps_ < BPS, "combined bps");
        protocolSeatSaleBps = protocolSeatSaleBps_;
        creatorSeatSaleBps = creatorSeatSaleBps_;
        protocolTaxBps = protocolTaxBps_;
    }

    /// @notice The guardian multisig (owner) controlling emergency/admin operations.
    function guardian() external view returns (address) {
        return owner();
    }

    /// @notice Human-readable version string of this UGM implementation.
    function ugmVersion() external pure returns (string memory) {
        return "TakeoverBNB-UGM-v0.2.0";
    }

    // --------------------------------------------------------------------- //
    //                            Grid creation                              //
    // --------------------------------------------------------------------- //
    /// @notice Create a grid, minting all seats to the caller (the creator) at a uniform price.
    /// @param p Creation parameters (seats, tax rate, forfeiture window, tokens, initial price).
    /// @return gridId The id assigned to the newly created grid.
    function createGrid(CreateGridParams calldata p) external returns (uint256 gridId) {
        require(!gridCreationPaused, "creation paused");
        require(p.totalSeats <= MAX_TOTAL_SEATS, "maxSeats");
        require(p.totalSeats >= MIN_TOTAL_SEATS && p.totalSeats <= MAX_SINGLE_TX_CREATE_TOTAL_SEATS, "seats");
        require(p.taxToken != address(0) && p.yieldToken != address(0), "token");
        require(allowedTaxTokens[p.taxToken], "taxToken");
        require(p.taxRateBps >= MIN_TAX_BPS && p.taxRateBps <= MAX_TAX_BPS, "taxRate");

        uint32 fd = p.forfeitureDuration == 0 ? DEFAULT_FORFEITURE_DURATION : p.forfeitureDuration;
        require(fd <= MAX_FORFEITURE_DURATION, "forfeitureDuration");

        gridId = ++gridCount;
        _configs[gridId] = GridConfig({
            creator: msg.sender,
            createdAt: uint64(block.timestamp),
            totalSeats: p.totalSeats,
            taxRateBps: p.taxRateBps,
            forfeitureDuration: fd,
            taxToken: p.taxToken,
            yieldToken: p.yieldToken
        });

        uint64 nowTs = uint64(block.timestamp);
        for (uint256 i = 0; i < p.totalSeats; ++i) {
            _seats[gridId][i] = Seat({
                holder: msg.sender,
                seatEverSold: false,
                price: p.initialPrice,
                deposit: 0,
                lastSettledAt: nowTs,
                acquiredAt: nowTs,
                lastPriceChangeTime: 0,
                forfeitedAt: 0
            });
        }
        emit GridCreated(gridId, msg.sender, p.totalSeats, p.taxToken, p.yieldToken);
    }

    // --------------------------------------------------------------------- //
    //                            Seat operations                            //
    // --------------------------------------------------------------------- //

    /// @notice Acquire a seat at its current price, set your own price, and post a tax deposit.
    /// @dev Dispatches to one of three paths after settling outstanding tax:
    ///        - VACANT (holder 0, in Dutch window): pay the decaying clearing price to the
    ///          forfeited holder (minus protocol/creator/penalty cuts); free once the window ends.
    ///        - CREATOR-held & unsold: buy from the creator (protocol cut only).
    ///        - held by another holder: buy them out (protocol + creator cuts, deposit refunded).
    ///      `maxPrice` is a slippage bound (revert if the current price/clearing price exceeds it;
    ///      0 disables it) and `depositAmount` must be non-zero so the seat cannot be acquired
    ///      already tax-underwater. Seller/creator/protocol/deposit-refund transfers are covered
    ///      by `nonReentrant` + CEI ordering (the seat is reassigned only after payouts settle).
    /// @param gridId The grid the seat belongs to.
    /// @param seatId The seat to acquire.
    /// @param newPrice The buyer's new self-assessed price (must be non-zero).
    /// @param depositAmount Tax deposit to post alongside the purchase (must be non-zero).
    /// @param maxPrice Slippage bound on the price/clearing price paid (0 = no bound).
    function buySeat(uint256 gridId, uint256 seatId, uint128 newPrice, uint256 depositAmount, uint128 maxPrice)
        external
        nonReentrant
    {
        GridConfig memory c = _configs[gridId];
        require(c.totalSeats != 0, "grid");
        require(!gridPaused[gridId], "paused");
        require(!gridDeprecated[gridId], "deprecated");
        require(seatId < c.totalSeats, "seatId");
        require(newPrice > 0, "newPrice");
        require(depositAmount > 0, "deposit");

        // Settle any outstanding tax first (may forfeit the seat into its Dutch window).
        _settleTax(gridId, seatId, c);

        address holder = _seats[gridId][seatId].holder;

        if (holder == address(0)) {
            _claimVacantSeat(gridId, seatId, newPrice, depositAmount, maxPrice, c);
        } else if (holder == c.creator && !_seats[gridId][seatId].seatEverSold) {
            require(msg.sender != holder, "own seat");
            _buyFromCreator(gridId, seatId, newPrice, depositAmount, maxPrice, c);
        } else {
            require(msg.sender != holder, "own seat");
            _buyout(gridId, seatId, newPrice, depositAmount, maxPrice, c);
        }
    }

    /// @dev Buy a seat from the creator's initial listing. Protocol cut -> protocol bucket,
    ///      the remainder is pushed to the creator; no creator seat-sale cut (they ARE the seller).
    function _buyFromCreator(
        uint256 gridId,
        uint256 seatId,
        uint128 newPrice,
        uint256 depositAmount,
        uint128 maxPrice,
        GridConfig memory c
    ) internal {
        Seat storage s = _seats[gridId][seatId];
        uint256 price = s.price;
        require(maxPrice == 0 || price <= maxPrice, "maxPrice");

        _beforeClaim(gridId, seatId, msg.sender, newPrice);
        // Credit the creator's accrued yield on this seat before it leaves them.
        _settleYield(gridId, seatId, c.yieldToken, c.creator);

        IERC20 tax = IERC20(c.taxToken);
        if (price > 0) {
            tax.safeTransferFrom(msg.sender, address(this), price);
            uint256 protocolFee = (price * protocolSeatSaleBps) / BPS;
            if (protocolFee > 0) gridTaxRevenue[gridId] += protocolFee;
            uint256 creatorReceives = price - protocolFee;
            if (creatorReceives > 0) payouts[c.taxToken][c.creator] += creatorReceives; // pull-based (claimPayout)
        }
        tax.safeTransferFrom(msg.sender, address(this), depositAmount);

        _assignSeat(s, newPrice, depositAmount);
        s.seatEverSold = true;

        _onSeatHolderChange(gridId, seatId, c.creator, msg.sender);
        emit SeatBought(gridId, seatId, msg.sender, c.creator, price, newPrice);
    }

    /// @dev Buy out another holder at their declared price. Protocol cut -> protocol bucket,
    ///      creator cut -> creator claimable, remainder + the seller's unspent deposit -> seller claimable
    ///      (pull-based: credited to `payouts`, withdrawn by the seller via `claimPayout`).
    function _buyout(
        uint256 gridId,
        uint256 seatId,
        uint128 newPrice,
        uint256 depositAmount,
        uint128 maxPrice,
        GridConfig memory c
    ) internal {
        Seat storage s = _seats[gridId][seatId];
        address seller = s.holder;
        uint256 price = s.price;
        require(maxPrice == 0 || price <= maxPrice, "maxPrice");

        _beforeBuyout(gridId, seatId, seller, msg.sender, price);
        _settleYield(gridId, seatId, c.yieldToken, seller);

        IERC20 tax = IERC20(c.taxToken);
        tax.safeTransferFrom(msg.sender, address(this), price);
        _routeBuyout(gridId, price, seller, s.deposit, c); // seller's deposit refund + fee split
        tax.safeTransferFrom(msg.sender, address(this), depositAmount);

        _assignSeat(s, newPrice, depositAmount);

        _onSeatHolderChange(gridId, seatId, seller, msg.sender);
        emit SeatBought(gridId, seatId, msg.sender, seller, price, newPrice);
    }

    /// @dev Split a buyout price: protocol cut -> protocol bucket, creator cut -> creator claimable,
    ///      remainder + the seller's unspent deposit -> the seller's claimable payout (pull-based,
    ///      credited to `payouts` and withdrawn via `claimPayout` — no push in the buyout path).
    function _routeBuyout(uint256 gridId, uint256 price, address seller, uint256 sellerDeposit, GridConfig memory c)
        internal
    {
        uint256 protocolFee = (price * protocolSeatSaleBps) / BPS;
        uint256 creatorFee = (price * creatorSeatSaleBps) / BPS;
        if (protocolFee > 0) gridTaxRevenue[gridId] += protocolFee;
        if (creatorFee > 0) payouts[c.taxToken][c.creator] += creatorFee;
        uint256 sellerTotal = (price - protocolFee - creatorFee) + sellerDeposit;
        if (sellerTotal > 0) payouts[c.taxToken][seller] += sellerTotal; // pull-based (claimPayout)
    }

    /// @dev Reclaim a vacant seat during its Dutch window. The clearing price decays linearly
    ///      from the forfeited holder's last price to 0 over `forfeitureDuration`; it is split
    ///      protocol + creator(+penalty) with the remainder credited to the forfeited holder.
    ///      After the window it is 0 and the seat is a free claim.
    function _claimVacantSeat(
        uint256 gridId,
        uint256 seatId,
        uint128 newPrice,
        uint256 depositAmount,
        uint128 maxPrice,
        GridConfig memory c
    ) internal {
        Seat storage s = _seats[gridId][seatId];
        uint256 clearingPrice = _dutchPrice(s.price, s.forfeitedAt, c.forfeitureDuration);
        require(maxPrice == 0 || clearingPrice <= maxPrice, "maxPrice");

        _beforeClaim(gridId, seatId, msg.sender, newPrice);
        // Yield accrued while the seat sat vacant is captured to the creator (stranded-fee sweep).
        _settleYield(gridId, seatId, c.yieldToken, c.creator);

        address seller = forfeitedFrom[gridId][seatId];
        IERC20 tax = IERC20(c.taxToken);
        if (clearingPrice > 0) {
            tax.safeTransferFrom(msg.sender, address(this), clearingPrice);
            _routeDutchClearing(gridId, seatId, clearingPrice, seller, c);
        }
        tax.safeTransferFrom(msg.sender, address(this), depositAmount);

        delete forfeitedFrom[gridId][seatId];
        delete forfeitedByTax[gridId][seatId];

        _assignSeat(s, newPrice, depositAmount);
        s.seatEverSold = true;

        _onSeatHolderChange(gridId, seatId, address(0), msg.sender);
        emit SeatReclaimed(gridId, seatId, msg.sender, seller, clearingPrice);
        emit SeatBought(gridId, seatId, msg.sender, address(0), clearingPrice, newPrice);
    }

    /// @dev Split a Dutch clearing price: protocol(+penalty) cut -> protocol bucket, creator cut ->
    ///      creator claimable, remainder -> the forfeited holder's claimable (or the creator when
    ///      the forfeited party IS the creator / a voluntary creator abandon). Reads `forfeitedByTax`
    ///      before it is cleared by the caller.
    function _routeDutchClearing(
        uint256 gridId,
        uint256 seatId,
        uint256 clearingPrice,
        address seller,
        GridConfig memory c
    ) internal {
        uint256 protocolFee = (clearingPrice * protocolSeatSaleBps) / BPS;
        bool sellerIsCreator = seller == address(0) || seller == c.creator;
        uint256 creatorFee = sellerIsCreator ? 0 : (clearingPrice * creatorSeatSaleBps) / BPS;
        uint256 penaltyFee = forfeitedByTax[gridId][seatId] ? (clearingPrice * forfeiturePenaltyBps) / BPS : 0;
        uint256 sellerReceives = clearingPrice - protocolFee - creatorFee - penaltyFee;

        if (protocolFee + penaltyFee > 0) gridTaxRevenue[gridId] += protocolFee + penaltyFee;
        if (creatorFee > 0) payouts[c.taxToken][c.creator] += creatorFee;
        if (sellerReceives > 0) payouts[c.taxToken][sellerIsCreator ? c.creator : seller] += sellerReceives;
    }

    /// @dev Write the buyer's ownership onto a seat: new holder = msg.sender, fresh price/deposit,
    ///      reset settlement/acquisition/cooldown clocks and clear any Dutch state.
    function _assignSeat(Seat storage s, uint128 newPrice, uint256 depositAmount) internal {
        uint64 nowTs = uint64(block.timestamp);
        s.holder = msg.sender;
        s.price = newPrice;
        s.deposit = _toU128(depositAmount);
        s.lastSettledAt = nowTs;
        s.acquiredAt = nowTs;
        s.lastPriceChangeTime = nowTs;
        s.forfeitedAt = 0;
    }

    /// @notice Update a seat's self-assessed price (holder only).
    /// @dev Gated by `PRICE_COOLDOWN`: this FREE re-pricing path is refused within the window of
    ///      acquiring the seat or its last price change. Buyouts are never cooldown-gated. The window is
    ///      friction, not an invariant — see {PRICE_COOLDOWN} for the priced escape hatch.
    function setPrice(uint256 gridId, uint256 seatId, uint128 newPrice) external nonReentrant {
        require(newPrice > 0, "newPrice");
        GridConfig memory c = _configs[gridId];
        require(!gridPaused[gridId], "paused");
        _settleTax(gridId, seatId, c);

        Seat storage s = _seats[gridId][seatId];
        require(s.holder == msg.sender, "not holder");
        require(
            s.lastPriceChangeTime == 0 || block.timestamp >= uint256(s.lastPriceChangeTime) + PRICE_COOLDOWN,
            "cooldown"
        );

        _beforePriceChange(gridId, seatId, msg.sender, s.price, newPrice);
        uint256 old = s.price;
        s.price = newPrice;
        s.lastPriceChangeTime = uint64(block.timestamp);
        emit PriceChanged(gridId, seatId, old, newPrice);
    }

    /// @notice Top up a seat's tax deposit (holder only).
    function addDeposit(uint256 gridId, uint256 seatId, uint256 amount) external nonReentrant {
        require(amount > 0, "amount");
        GridConfig memory c = _configs[gridId];
        _settleTax(gridId, seatId, c);

        Seat storage s = _seats[gridId][seatId];
        require(s.holder == msg.sender, "not holder");

        IERC20(c.taxToken).safeTransferFrom(msg.sender, address(this), amount);
        s.deposit = _toU128(uint256(s.deposit) + amount);
        emit DepositAdded(gridId, seatId, amount);
    }

    /// @notice Withdraw unspent tax deposit (holder only). Always available, even when deprecated.
    function withdrawDeposit(uint256 gridId, uint256 seatId, uint256 amount) external nonReentrant {
        require(amount > 0, "amount");
        GridConfig memory c = _configs[gridId];
        _settleTax(gridId, seatId, c);

        Seat storage s = _seats[gridId][seatId];
        require(s.holder == msg.sender, "not holder");
        require(amount <= s.deposit, "exceeds deposit");

        s.deposit = uint128(uint256(s.deposit) - amount);
        IERC20(c.taxToken).safeTransfer(msg.sender, amount);
        emit DepositWithdrawn(gridId, seatId, amount);
    }

    /// @notice Voluntarily give up a seat into its Dutch window and reclaim any unspent deposit.
    /// @dev The seat's `price` is PRESERVED to anchor the Dutch decay and the holder is snapshotted
    ///      into `forfeitedFrom` so a later reclaim pays them the clearing price. No penalty applies
    ///      (voluntary exit). Always available, even when the grid is deprecated.
    function abandonSeat(uint256 gridId, uint256 seatId) external nonReentrant {
        GridConfig memory c = _configs[gridId];
        _settleTax(gridId, seatId, c);

        Seat storage s = _seats[gridId][seatId];
        address holder = s.holder;
        require(holder == msg.sender, "not holder");

        _settleYield(gridId, seatId, c.yieldToken, holder);

        uint256 refund = s.deposit;
        s.deposit = 0;
        s.holder = address(0);
        s.forfeitedAt = uint64(block.timestamp);
        s.lastSettledAt = uint64(block.timestamp);
        forfeitedFrom[gridId][seatId] = holder;
        // forfeitedByTax stays false: voluntary exits skip the tax-underwater penalty.

        if (refund > 0) IERC20(c.taxToken).safeTransfer(holder, refund);
        _onSeatHolderChange(gridId, seatId, holder, address(0));
        emit SeatAbandoned(gridId, seatId, holder);
    }

    /// @notice Permissionlessly settle continuous tax on a seat (may trigger forfeiture).
    /// @dev `nonReentrant` so the forfeiture path (`_settleTax -> _onForfeit`) that calls an
    ///      external governance module cannot re-enter guarded UGM mutators (AUDIT-1 F-03 / KI2).
    function pokeTax(uint256 gridId, uint256 seatId) public nonReentrant {
        _settleTax(gridId, seatId, _configs[gridId]);
    }

    /// @notice Permissionlessly settle continuous tax on several seats of one grid.
    function pokeTaxBatch(uint256 gridId, uint256[] calldata seatIds) external nonReentrant {
        GridConfig memory c = _configs[gridId];
        for (uint256 i = 0; i < seatIds.length; ++i) {
            _settleTax(gridId, seatIds[i], c);
        }
    }

    // --------------------------------------------------------------------- //
    //                            Yield: claiming                            //
    // --------------------------------------------------------------------- //

    /// @notice Settle a seat's accrued yield to its holder's claimable balance.
    /// @dev Yield accrued on a vacant seat is captured to the grid creator (it never belongs to
    ///      `address(0)`), mirroring the stranded-fee sweep on Dutch reclaim.
    function claimYield(uint256 gridId, uint256 seatId) public {
        GridConfig memory c = _configs[gridId];
        Seat storage s = _seats[gridId][seatId];
        address to = s.holder == address(0) ? c.creator : s.holder;
        _settleYield(gridId, seatId, c.yieldToken, to);
    }

    /// @notice Settle accrued yield for several seats of one grid to their holders.
    function claimYieldBatch(uint256 gridId, uint256[] calldata seatIds) external {
        GridConfig memory c = _configs[gridId];
        for (uint256 i = 0; i < seatIds.length; ++i) {
            Seat storage s = _seats[gridId][seatIds[i]];
            address to = s.holder == address(0) ? c.creator : s.holder;
            _settleYield(gridId, seatIds[i], c.yieldToken, to);
        }
    }

    /// @notice Withdraw a claimable token balance accrued from yield, tax, or sale proceeds.
    function claimPayout(address token) external nonReentrant returns (uint256 amount) {
        amount = payouts[token][msg.sender];
        require(amount > 0, "nothing");
        payouts[token][msg.sender] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit PayoutClaimed(token, msg.sender, amount);
    }

    // --------------------------------------------------------------------- //
    //                       Yield sink (adapter-facing)                     //
    // --------------------------------------------------------------------- //
    /// @notice Wire an asset to a grid. Callable only by an approved adapter.
    function registerAsset(uint256 gridId, bytes32 assetHash) external {
        require(approvedAdapters[msg.sender], "adapter");
        require(gridId != 0 && gridId <= gridCount, "grid");
        require(assetToGrid[assetHash] == 0, "registered");
        assetToGrid[assetHash] = gridId;
        assetAdapter[assetHash] = msg.sender;
        emit AssetRegistered(gridId, assetHash, msg.sender);
    }

    /// @notice Unwire an asset from a grid. Callable only by the owning adapter.
    function withdrawAsset(uint256 gridId, bytes32 assetHash) external {
        require(assetAdapter[assetHash] == msg.sender, "not adapter");
        require(assetToGrid[assetHash] == gridId, "grid");
        delete assetToGrid[assetHash];
        delete assetAdapter[assetHash];
        emit AssetWithdrawn(gridId, assetHash);
    }

    /// @notice Receive realized ERC20 yield from the owning adapter and spread it equally across
    ///         the grid's seats. Credits the ACTUAL received amount (balance delta) so fee-on-
    ///         transfer / rebasing yield tokens cannot over-credit the shared pool (AUDIT-1 F-01).
    function receiveYieldERC20(bytes32 assetHash, address token, uint256 amount) external nonReentrant {
        uint256 gridId = assetToGrid[assetHash];
        require(gridId != 0, "asset");
        require(msg.sender == assetAdapter[assetHash], "not adapter");
        require(amount > 0, "amount");

        GridConfig memory c = _configs[gridId];
        require(token == c.yieldToken, "yieldToken");

        IERC20 t = IERC20(token);
        uint256 balBefore = t.balanceOf(address(this));
        t.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = t.balanceOf(address(this)) - balBefore;
        require(received > 0, "received");

        _accYieldPerSeat[gridId] += (received * ACC_PRECISION) / c.totalSeats;
        emit YieldReceived(gridId, assetHash, token, received);
    }

    /// @notice Native-BNB yield sink — always reverts (unsupported on this port).
    /// @dev Adapters must wrap BNB to WBNB before forwarding, keeping payout accounting to a
    ///      single ERC20 per grid.
    function receiveYieldETH(bytes32, uint256) external payable {
        require(false, "native unsupported: wrap to WBNB");
    }

    // --------------------------------------------------------------------- //
    //                          Internal accounting                          //
    // --------------------------------------------------------------------- //
    /// @dev Settle continuous tax on a seat. Consumes tax from the deposit and, when it runs dry,
    ///      forfeits the seat into its Dutch window (holder cleared, price preserved). When any tax is
    ///      owed, `lastSettledAt` advances to the current block time (the floored `owed` is a sub-unit
    ///      under-charge in the holder's favour, never re-charged); it is left untouched when the
    ///      rounded tax is 0 — closing the dust-price tax-immunity hole without over-charging.
    function _settleTax(uint256 gridId, uint256 seatId, GridConfig memory c) internal {
        Seat storage s = _seats[gridId][seatId];
        uint64 nowTs = uint64(block.timestamp);

        address holder = s.holder;
        if (holder == address(0)) return; // vacant seat: nothing to settle while in Dutch window

        // Creator's untouched initial listing is tax-exempt.
        if (holder == c.creator && !s.seatEverSold) {
            s.lastSettledAt = nowTs;
            return;
        }

        uint256 elapsed = nowTs - s.lastSettledAt;
        if (elapsed == 0) return;

        uint256 owed = HarbergerMath.taxOwed(s.price, c.taxRateBps, elapsed);
        // Dust fix: when the integer tax rounds to 0, do NOT advance the clock — let the residue
        // keep accruing until it rounds up to >= 1, so dust-priced seats can't sit tax-immune.
        if (owed == 0) return;

        if (s.deposit >= owed) {
            s.deposit = uint128(uint256(s.deposit) - owed);
            // Advance the clock the full elapsed interval. `owed` is floored (a sub-unit
            // under-charge in the holder's favour). Advancing only by the exact seconds `owed`
            // represents would leave a rounding residue that is re-charged on the next settle —
            // over-taxing the holder and enabling gas-bounded forced-forfeiture griefing via
            // repeated pokes. The dust-price hole (taxOwed rounds to 0) stays closed by the
            // `owed == 0` guard above, which returns without advancing the clock.
            s.lastSettledAt = nowTs;
            _routeTax(gridId, c, owed);
            emit TaxSettled(gridId, seatId, owed);
        } else {
            // Deposit exhausted -> book the remainder as tax and forfeit into the Dutch window.
            uint256 paid = s.deposit;
            _settleYield(gridId, seatId, c.yieldToken, holder);

            s.deposit = 0;
            s.holder = address(0);
            s.forfeitedAt = nowTs;
            s.lastSettledAt = nowTs;
            // price preserved to anchor the Dutch decay.
            forfeitedFrom[gridId][seatId] = holder;
            forfeitedByTax[gridId][seatId] = true;

            _routeTax(gridId, c, paid);
            emit Forfeited(gridId, seatId, holder, paid);
            _onForfeit(gridId, seatId, holder);
        }
    }

    /// @dev Split settled tax: protocol cut -> protocol bucket, remainder -> creator claimable.
    function _routeTax(uint256 gridId, GridConfig memory c, uint256 amount) internal {
        if (amount == 0) return;
        uint256 protocolShare = (amount * protocolTaxBps) / BPS;
        if (protocolShare > 0) gridTaxRevenue[gridId] += protocolShare;
        uint256 creatorShare = amount - protocolShare;
        if (creatorShare > 0) payouts[c.taxToken][c.creator] += creatorShare;
    }

    /// @dev Linear Dutch decay from the seat's preserved price to 0 over `duration`.
    function _dutchPrice(uint256 price, uint64 forfeitedAt, uint32 duration) internal view returns (uint256) {
        if (forfeitedAt == 0) return 0;
        uint256 elapsed = block.timestamp - forfeitedAt;
        if (duration == 0 || elapsed >= duration) return 0;
        return (price * (uint256(duration) - elapsed)) / uint256(duration);
    }

    function _settleYield(uint256 gridId, uint256 seatId, address yieldToken, address to) internal {
        uint256 acc = _accYieldPerSeat[gridId];
        uint256 paid = _seatYieldPaid[gridId][seatId];
        if (acc <= paid) return;
        uint256 owed = (acc - paid) / ACC_PRECISION;
        // Advance `paid` by exactly what was credited (owed * ACC_PRECISION), NOT the full `acc`,
        // so the truncated sub-unit remainder stays in the gap and accumulates into a future
        // settlement instead of being stranded as unowned dust (COM-ROUNDING).
        _seatYieldPaid[gridId][seatId] = paid + owed * ACC_PRECISION;
        if (owed > 0) payouts[yieldToken][to] += owed;
    }

    // --------------------------------------------------------------------- //
    //                            Hook dispatch                              //
    // --------------------------------------------------------------------- //
    /// @dev A wired module is only "active" while it remains approved AND not disabled, so BOTH
    ///      `setApprovedModule(m, false)` and `setModuleDisabled(m, true)` are effective
    ///      revocations that immediately stop the module firing on already-wired grids (F-11).
    function _activeModule(uint256 gridId) internal view returns (address m) {
        m = gridGovernanceModule[gridId];
        if (m != address(0) && (moduleDisabled[m] || !approvedModules[m])) m = address(0);
    }

    function _beforeClaim(uint256 gridId, uint256 seatId, address buyer, uint256 newPrice) internal {
        address m = _activeModule(gridId);
        if (m == address(0)) return;
        try IGridHooksV23(m).beforeClaim{ gas: GOVERNANCE_HOOK_GAS_CAP }(gridId, seatId, buyer, newPrice) returns (bool ok) {
            require(ok, "hook: claim vetoed");
        } catch {
            require(false, "hook: claim reverted");
        }
    }

    function _beforeBuyout(uint256 gridId, uint256 seatId, address from, address to, uint256 price) internal {
        address m = _activeModule(gridId);
        if (m == address(0)) return;
        try IGridHooksV23(m).beforeBuyout{ gas: GOVERNANCE_HOOK_GAS_CAP }(gridId, seatId, from, to, price) returns (bool ok) {
            require(ok, "hook: buyout vetoed");
        } catch {
            require(false, "hook: buyout reverted");
        }
    }

    function _beforePriceChange(uint256 gridId, uint256 seatId, address holder, uint256 oldP, uint256 newP) internal {
        address m = _activeModule(gridId);
        if (m == address(0)) return;
        try IGridHooksV23(m).beforePriceChange{ gas: GOVERNANCE_HOOK_GAS_CAP }(gridId, seatId, holder, oldP, newP) returns (bool ok) {
            require(ok, "hook: price vetoed");
        } catch {
            require(false, "hook: price reverted");
        }
    }

    function _onSeatHolderChange(uint256 gridId, uint256 seatId, address from, address to) internal {
        address m = _activeModule(gridId);
        if (m == address(0)) return;
        try IGridHooksV23(m).onSeatHolderChange{ gas: GOVERNANCE_HOOK_GAS_CAP }(gridId, seatId, from, to) {} catch {}
    }

    function _onForfeit(uint256 gridId, uint256 seatId, address from) internal {
        address m = _activeModule(gridId);
        if (m == address(0)) return;
        try IGridHooksV23(m).onForfeit{ gas: GOVERNANCE_HOOK_GAS_CAP }(gridId, seatId, from) {} catch {}
    }

    // --------------------------------------------------------------------- //
    //                                 Admin                                 //
    // --------------------------------------------------------------------- //
    /// @notice Approve or revoke an adapter allowed to register yield assets.
    function setApprovedAdapter(address adapter, bool approved) external onlyOwner {
        approvedAdapters[adapter] = approved;
        emit AdapterApprovalSet(adapter, approved);
    }

    /// @notice Approve or revoke a governance module eligible to be wired to grids.
    function setApprovedModule(address module, bool approved) external onlyOwner {
        approvedModules[module] = approved;
        emit ModuleApprovalSet(module, approved);
    }

    /// @notice Globally disable (kill-switch) or re-enable a governance module.
    function setModuleDisabled(address module, bool disabled) external onlyOwner {
        moduleDisabled[module] = disabled;
    }

    /// @notice Set (or detach) the active governance module for a grid.
    /// @dev Callable by the grid creator or the owner; a non-zero module must be approved.
    function setGridGovernanceModule(uint256 gridId, address module) external {
        require(msg.sender == _configs[gridId].creator || msg.sender == owner(), "auth");
        require(module == address(0) || approvedModules[module], "module");
        gridGovernanceModule[gridId] = module;
        emit GridModuleSet(gridId, module);
    }

    /// @notice Allow or disallow a token as a grid's taxToken (checked in `createGrid`).
    function setAllowedTaxToken(address token, bool allowed) external onlyOwner {
        allowedTaxTokens[token] = allowed;
        emit AllowedTaxTokenUpdated(token, allowed);
    }

    /// @notice Set the protocol cut of every seat sale, in bps (<= MAX_PROTOCOL_BPS).
    function setProtocolSeatSaleBps(uint16 bps) external onlyOwner {
        require(bps <= MAX_PROTOCOL_BPS, "bps");
        require(uint256(bps) + creatorSeatSaleBps + forfeiturePenaltyBps < BPS, "combined bps");
        emit FeeBpsUpdated("protocolSeatSale", protocolSeatSaleBps, bps);
        protocolSeatSaleBps = bps;
    }

    /// @notice Set the creator cut of secondary (buyout / Dutch) seat sales, in bps.
    function setCreatorSeatSaleBps(uint16 bps) external onlyOwner {
        require(bps <= MAX_PROTOCOL_BPS, "bps");
        require(uint256(protocolSeatSaleBps) + bps + forfeiturePenaltyBps < BPS, "combined bps");
        emit FeeBpsUpdated("creatorSeatSale", creatorSeatSaleBps, bps);
        creatorSeatSaleBps = bps;
    }

    /// @notice Set the protocol cut of settled Harberger tax, in bps (remainder -> creator).
    function setProtocolTaxBps(uint16 bps) external onlyOwner {
        require(bps <= MAX_PROTOCOL_BPS, "bps");
        emit FeeBpsUpdated("protocolTax", protocolTaxBps, bps);
        protocolTaxBps = bps;
    }

    /// @notice Set the extra protocol cut charged on tax-underwater Dutch reclaims, in bps.
    function setForfeiturePenaltyBps(uint16 bps) external onlyOwner {
        require(bps <= MAX_PROTOCOL_BPS, "bps");
        require(uint256(protocolSeatSaleBps) + creatorSeatSaleBps + bps < BPS, "combined bps");
        emit FeeBpsUpdated("forfeiturePenalty", forfeiturePenaltyBps, bps);
        forfeiturePenaltyBps = bps;
    }

    /// @notice Set the sink the protocol fee bucket is swept to by `withdrawTaxRevenue`.
    function setProtocolFeeReceiver(address receiver) external onlyOwner {
        require(receiver != address(0), "receiver");
        protocolFeeReceiver = receiver;
        emit ProtocolFeeReceiverUpdated(receiver);
    }

    /// @notice Pause seat operations on a grid.
    function pauseGrid(uint256 gridId) external onlyOwner {
        gridPaused[gridId] = true;
    }

    /// @notice Unpause seat operations on a grid.
    function unpauseGrid(uint256 gridId) external onlyOwner {
        gridPaused[gridId] = false;
    }

    /// @notice Pause creation of new grids.
    function pauseGridCreation() external onlyOwner {
        gridCreationPaused = true;
    }

    /// @notice Resume creation of new grids.
    function unpauseGridCreation() external onlyOwner {
        gridCreationPaused = false;
    }

    /// @notice Deprecate a grid: blocks ALL `buySeat` — both new acquisitions and the Dutch reclaim
    ///         of a forfeited/abandoned seat. Every ALREADY-SETTLED balance stays fully withdrawable:
    ///         `withdrawDeposit` (your own unspent deposit), `claimYield` (your accrued yield), and
    ///         `claimPayout` (proceeds already credited to you). Intentional consequence of a full
    ///         wind-down: a seat still in its Dutch window at deprecation stays frozen (no reclaim
    ///         buyer is admitted), so a forfeited holder's *contingent* clearing payout — which only
    ///         settles when someone reclaims the seat — will not accrue. Deprecation stops new
    ///         activity; it does not guarantee in-flight auctions complete.
    function deprecateGrid(uint256 gridId) external onlyOwner {
        require(gridId != 0 && gridId <= gridCount, "grid");
        gridDeprecated[gridId] = true;
        emit GridDeprecated(gridId);
    }

    /// @notice Sweep a grid's accrued protocol revenue (in taxToken) to the fee receiver.
    /// @dev Guardian-gated. The protocol bucket holds the protocol tax cut + protocol seat-sale
    ///      cut + forfeiture penalties; the creator's tax/sale shares are claimable separately via
    ///      the normal `claimPayout` path. Best-effort notifies an `IFeeReceiver` (e.g. the keeper).
    function withdrawTaxRevenue(uint256 gridId) external onlyOwner nonReentrant returns (uint256 amount) {
        address recv = protocolFeeReceiver;
        require(recv != address(0), "receiver");
        amount = gridTaxRevenue[gridId];
        require(amount > 0, "nothing");
        gridTaxRevenue[gridId] = 0;
        address token = _configs[gridId].taxToken;
        IERC20(token).safeTransfer(recv, amount);
        _notifyFeeReceiver(recv, token, amount);
        emit TaxRevenueWithdrawn(gridId, recv, amount);
    }

    function _notifyFeeReceiver(address recv, address token, uint256 amount) internal {
        if (recv.code.length > 0) {
            try IFeeReceiver(recv).receiveFees(token, amount) {} catch {}
        }
    }

    // --------------------------------------------------------------------- //
    //                                 Views                                 //
    // --------------------------------------------------------------------- //
    /// @notice Immutable configuration of a grid.
    function gridConfig(uint256 gridId) external view returns (GridConfig memory) {
        return _configs[gridId];
    }

    /// @notice Current Harberger state of a single seat.
    function seatInfo(uint256 gridId, uint256 seatId) external view returns (Seat memory) {
        return _seats[gridId][seatId];
    }

    /// @notice Number of seats configured for a grid.
    function totalSeats(uint256 gridId) external view returns (uint256) {
        return _configs[gridId].totalSeats;
    }

    /// @notice Tax liability accrued on a seat since its last settlement (uncapped).
    /// @return Tax owed since last settlement (0 for vacant or creator-held-unsold seats).
    function taxDue(uint256 gridId, uint256 seatId) external view returns (uint256) {
        GridConfig memory c = _configs[gridId];
        Seat memory s = _seats[gridId][seatId];
        if (s.holder == address(0)) return 0;
        if (s.holder == c.creator && !s.seatEverSold) return 0;
        uint256 elapsed = block.timestamp - s.lastSettledAt;
        return HarbergerMath.taxOwed(s.price, c.taxRateBps, elapsed);
    }

    /// @notice Seconds until a seat's deposit is exhausted by tax at its current price.
    /// @return type(uint256).max when the seat can never be forfeited (creator-unsold, price 0, or
    ///         dust price with a zero per-second rate); 0 when it is already underwater / vacant.
    function timeUntilForfeiture(uint256 gridId, uint256 seatId) external view returns (uint256) {
        GridConfig memory c = _configs[gridId];
        Seat memory s = _seats[gridId][seatId];
        if (s.holder == address(0)) return 0;
        if (s.holder == c.creator && !s.seatEverSold) return type(uint256).max;
        if (s.price == 0) return type(uint256).max;
        uint256 tps = HarbergerMath.taxPerSecond(s.price, c.taxRateBps);
        if (tps == 0) return type(uint256).max;
        uint256 elapsed = block.timestamp - s.lastSettledAt;
        uint256 accrued = HarbergerMath.taxOwed(s.price, c.taxRateBps, elapsed);
        if (accrued >= s.deposit) return 0;
        return (uint256(s.deposit) - accrued) / tps;
    }

    /// @notice The current Dutch-auction clearing price of a (possibly vacant) seat.
    /// @return The decaying reclaim price; 0 if the seat is not in a Dutch window or it has ended.
    function dutchAuctionPrice(uint256 gridId, uint256 seatId) external view returns (uint256) {
        Seat memory s = _seats[gridId][seatId];
        return _dutchPrice(s.price, s.forfeitedAt, _configs[gridId].forfeitureDuration);
    }

    /// @notice Seconds remaining on a seat's re-pricing cooldown (0 if it can be re-priced now).
    function cooldownRemaining(uint256 gridId, uint256 seatId) external view returns (uint256) {
        Seat memory s = _seats[gridId][seatId];
        if (s.lastPriceChangeTime == 0) return 0;
        uint256 end = uint256(s.lastPriceChangeTime) + PRICE_COOLDOWN;
        return block.timestamp >= end ? 0 : end - block.timestamp;
    }

    /// @notice Yield claimable for a single seat's current holder.
    function pendingYieldSeat(uint256 gridId, uint256 seatId) public view returns (uint256) {
        uint256 acc = _accYieldPerSeat[gridId];
        uint256 paid = _seatYieldPaid[gridId][seatId];
        if (acc <= paid) return 0;
        return (acc - paid) / ACC_PRECISION;
    }

    /// @notice Aggregate yield claimable by `holder` across all seats they hold.
    /// @dev Loops over every seat (up to MAX_TOTAL_SEATS). Intended for OFF-CHAIN reads; avoid
    ///      calling on-chain from another contract on large grids (AUDIT-1 F-12, Accepted).
    function pendingYield(uint256 gridId, address holder) external view returns (uint256 total) {
        uint256 n = _configs[gridId].totalSeats;
        for (uint256 i = 0; i < n; ++i) {
            if (_seats[gridId][i].holder == holder) {
                total += pendingYieldSeat(gridId, i);
            }
        }
    }

    // --------------------------------------------------------------------- //
    //                                Helpers                                //
    // --------------------------------------------------------------------- //
    function _toU128(uint256 x) internal pure returns (uint128) {
        require(x <= type(uint128).max, "overflow u128");
        return uint128(x);
    }
}
