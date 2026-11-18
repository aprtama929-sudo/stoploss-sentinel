// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";

/// @title StopLossSentinel — a "set it and forget it" stop-loss guardian.
/// @notice Deployed on Reactive Lasna. It watches one `SentinelVault` on the
///         origin chain. When the vault reports a position opened, the sentinel
///         arms itself with that position's floor price. When a later price
///         update falls below the floor, it requests exactly one callback that
///         closes the position on the origin chain and refunds the owner.
///         No keeper, no polling, no off-chain component: configure once and
///         the network does the rest.
contract StopLossSentinel is AbstractReactive {
    /// @notice topic0 of `SentinelVault.PositionOpened(address,uint256,uint256)`.
    uint256 public constant POSITION_OPENED_TOPIC =
        uint256(keccak256("PositionOpened(address,uint256,uint256)"));

    /// @notice topic0 of `SentinelVault.PriceUpdated(uint256)`.
    uint256 public constant PRICE_UPDATED_TOPIC = uint256(keccak256("PriceUpdated(uint256)"));

    /// @notice Gas limit requested for the close-position callback.
    /// @dev Well above the 100,000 minimum enforced by Reactive Network and
    ///      sized for the proxy's accounting overhead plus the vault's refund transfer.
    uint64 internal constant CALLBACK_GAS_LIMIT = 1_000_000;

    /// @notice The account that deployed (and may reconfigure) this sentinel.
    address public immutable owner;

    /// @notice Chain the vault lives on and events are read from (Ethereum Sepolia: 11155111).
    uint256 public immutable originChainId;

    /// @notice Chain callbacks are delivered to (same chain as the origin here).
    uint256 public immutable destinationChainId;

    /// @notice The vault being watched; also the callback recipient.
    address public vault;

    /// @notice Floor price of the currently armed position (0 when disarmed).
    uint256 public floor;

    /// @notice True between a PositionOpened event and its stop-loss trigger.
    bool public armed;

    /// @notice Most recent price reported by the vault.
    uint256 public lastPrice;

    /// @notice How many stop-loss callbacks this sentinel has requested.
    uint256 public triggerCount;

    event Configured(address indexed vault);
    event Armed(uint256 floor, uint256 amount);
    event StopLossTriggered(uint256 price, uint256 floor);

    error NotOwner(address sender);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    /// @param originChainId_ Chain hosting the vault (11155111 for Ethereum Sepolia).
    /// @param destinationChainId_ Chain receiving callbacks (11155111 for Ethereum Sepolia).
    /// @dev Payable so the contract can be funded with lREACT at deployment;
    ///      its balance pays for reactive executions.
    constructor(uint256 originChainId_, uint256 destinationChainId_) payable {
        owner = msg.sender;
        originChainId = originChainId_;
        destinationChainId = destinationChainId_;
    }

    /// @notice Point the sentinel at a vault and subscribe to its events.
    /// @dev Subscribing from a setter (not the constructor) breaks the deploy
    ///      cycle: the vault needs this contract's address at construction,
    ///      while this contract needs the vault's address to subscribe.
    ///      Reconfiguring first removes the previous vault's subscriptions.
    function configure(address vault_) external onlyOwner {
        require(vault_ != address(0), "vault is zero address");

        if (vault != address(0)) {
            SYSTEM.unsubscribe(originChainId, vault, POSITION_OPENED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            SYSTEM.unsubscribe(originChainId, vault, PRICE_UPDATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        }

        vault = vault_;
        armed = false;
        floor = 0;

        SYSTEM.subscribe(originChainId, vault_, POSITION_OPENED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        SYSTEM.subscribe(originChainId, vault_, PRICE_UPDATED_TOPIC, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);

        emit Configured(vault_);
    }

    /// @inheritdoc IReactive
    function react(LogRecord memory log_) external onlySystem {
        // Only the configured vault on the origin chain is of interest.
        if (log_.chainId != originChainId || log_.contractAddress != vault) {
            return;
        }

        if (log_.topic0 == POSITION_OPENED_TOPIC) {
            // data = abi.encode(amount, floor); user is indexed in topic1.
            (uint256 amount, uint256 floor_) = abi.decode(log_.data, (uint256, uint256));
            floor = floor_;
            armed = true;
            emit Armed(floor_, amount);
        } else if (log_.topic0 == PRICE_UPDATED_TOPIC) {
            uint256 price = abi.decode(log_.data, (uint256));
            lastPrice = price;

            if (armed && price < floor) {
                // Latch first: exactly one callback per arming, even if the
                // price keeps falling and more updates arrive.
                armed = false;
                triggerCount++;

                bytes memory payload = abi.encodeWithSignature(
                    "closePosition(address,uint256)",
                    address(0), // placeholder — the network injects this contract's address
                    price
                );

                SYSTEM.requestCallbackV_1_0(
                    ISystemContract.CallbackConfiguration_V_1_0({
                        chainId: destinationChainId,
                        recipient: vault,
                        gasLimit: CALLBACK_GAS_LIMIT,
                        payload: payload
                    })
                );

                emit StopLossTriggered(price, floor);
            }
        }
        // Unmatched logs fall through silently — reverting would still be billed.
    }

    /// @notice Settles outstanding debt from this contract's own balance.
    /// @dev Left public on purpose: anyone may fund and restart the sentinel.
    function coverDebt() external {
        _coverDebt();
    }
}
