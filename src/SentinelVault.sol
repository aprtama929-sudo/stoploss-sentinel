// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

/// @title SentinelVault — a position guarded by a Reactive stop-loss sentinel.
/// @notice Lives on the origin/destination chain (Ethereum Sepolia). The owner
///         deposits funds and sets a floor price once (`openPosition`), then
///         publishes price updates (`updatePrice` stands in for an oracle or
///         DEX TWAP feed in this testnet build). If the price breaches the
///         floor, the `StopLossSentinel` reactive contract on Lasna requests a
///         callback and `closePosition` — reachable only through the Reactive
///         callback proxy and only for that sentinel — unwinds the position
///         and refunds the owner automatically.
contract SentinelVault is AbstractCallback {
    /// @notice Native-token amount retained in the vault when a position is
    ///         closed, so the contract can pay the callback-delivery charge
    ///         that settles after `closePosition` executes. The owner can
    ///         reclaim it afterwards with `withdrawReserve`.
    uint256 internal constant FEE_RESERVE = 0.005 ether;

    /// @notice The position owner (deployer).
    address public immutable owner;

    /// @notice Floor price of the open position.
    uint256 public floor;

    /// @notice Most recent price published via `updatePrice`.
    uint256 public currentPrice;

    /// @notice Amount deposited with the open position.
    uint256 public positionAmount;

    /// @notice Whether a position is currently open.
    bool public positionOpen;

    /// @notice Price at which the position was closed by the sentinel.
    uint256 public closedAtPrice;

    /// @notice Amount refunded to the owner on close.
    uint256 public refundedAmount;

    /// @notice Emitted when a position is opened. The sentinel subscribes to
    ///         this event to arm itself with the floor (data: amount, floor).
    event PositionOpened(address indexed user, uint256 amount, uint256 floor);

    /// @notice Emitted on every price publication. The sentinel subscribes to
    ///         this event to watch for a floor breach (data: price).
    event PriceUpdated(uint256 price);

    /// @notice Emitted when the sentinel's callback closes the position.
    event PositionClosed(uint256 price, uint256 refunded);

    error NotOwner(address sender);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    /// @param callbackProxy_ Reactive callback proxy on this chain
    ///        (Ethereum Sepolia: 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4).
    /// @param callbackSender_ The StopLossSentinel contract on Lasna.
    /// @dev Payable so the vault can be funded at deployment; its balance pays
    ///      for callback deliveries.
    constructor(IPayable callbackProxy_, address callbackSender_)
        payable
        AbstractCallback(callbackProxy_, callbackSender_)
    {
        owner = msg.sender;
    }

    /// @notice Open a guarded position: deposit funds and set the floor once.
    function openPosition(uint256 floor_) external payable onlyOwner {
        require(!positionOpen, "position already open");
        require(msg.value > 0, "deposit required");
        require(floor_ > 0, "floor must be positive");

        floor = floor_;
        positionAmount = msg.value;
        positionOpen = true;

        emit PositionOpened(msg.sender, msg.value, floor_);
    }

    /// @notice Publish a new price. In production this would be an oracle or
    ///         TWAP read; here the feed operator is the owner so the demo can
    ///         drive a breach deterministically on testnet.
    function updatePrice(uint256 price_) external onlyOwner {
        currentPrice = price_;
        emit PriceUpdated(price_);
    }

    /// @notice Close the position and refund the owner. Callable ONLY by the
    ///         Reactive callback proxy, and only when the injected sender is
    ///         the authorized sentinel — both checks run before any state moves.
    /// @param reactive_ Injected by the network: the requesting reactive contract.
    /// @param price_ The breaching price reported by the sentinel.
    function closePosition(address reactive_, uint256 price_)
        external
        onlyServiceProvider
        onlyCallbackSender(reactive_)
    {
        require(positionOpen, "no open position");

        positionOpen = false;
        closedAtPrice = price_;

        uint256 balance = address(this).balance;
        uint256 payout = balance > FEE_RESERVE ? balance - FEE_RESERVE : 0;
        refundedAmount = payout;

        if (payout > 0) {
            (bool success,) = payable(owner).call{ value: payout }("");
            require(success, "refund failed");
        }

        emit PositionClosed(price_, payout);
    }

    /// @notice Reclaim the retained fee reserve after a position has closed.
    function withdrawReserve() external onlyOwner {
        require(!positionOpen, "position still open");
        uint256 balance = address(this).balance;
        require(balance > 0, "nothing to withdraw");
        (bool success,) = payable(owner).call{ value: balance }("");
        require(success, "withdraw failed");
    }

    /// @notice Settles outstanding debt from this contract's own balance.
    function coverDebt() external {
        _coverDebt();
    }
}
