// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { StopLossSentinel } from "../src/StopLossSentinel.sol";
import { SentinelVault } from "../src/SentinelVault.sol";
import { MockSystemContract } from "./mocks/MockSystemContract.sol";
import { MockCallbackProxy } from "./mocks/MockCallbackProxy.sol";

contract StopLossTest is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    uint256 internal constant SEPOLIA = 11155111;
    uint256 internal constant FLOOR = 100;
    uint256 internal constant POSITION = 2 ether;

    MockSystemContract internal system;
    MockCallbackProxy internal proxy;
    StopLossSentinel internal sentinel;
    SentinelVault internal vault;
    address internal stranger = address(0xBEEF);

    function setUp() public {
        vm.deal(address(this), 100 ether);

        MockSystemContract impl = new MockSystemContract();
        vm.etch(SYSTEM_ADDR, address(impl).code);
        system = MockSystemContract(payable(SYSTEM_ADDR));

        vm.deal(stranger, 10 ether);
        proxy = new MockCallbackProxy();

        sentinel = new StopLossSentinel{ value: 5 ether }(SEPOLIA, SEPOLIA);
        vault = new SentinelVault{ value: 0.1 ether }(IPayable(payable(address(proxy))), address(sentinel));

        sentinel.configure(address(vault));
    }

    receive() external payable {}

    // ---------- helpers ----------

    function _log(uint256 topic0, bytes memory data) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chainId: SEPOLIA,
            contractAddress: address(vault),
            topic0: topic0,
            topic1: 0,
            topic2: 0,
            topic3: 0,
            data: data,
            blockNumber: 1,
            opCode: 1,
            blockHash: 0,
            txHash: 0,
            logIndex: 0
        });
    }

    function _react(IReactive.LogRecord memory log) internal {
        // The log must be fully built before pranking: any external call
        // (even a constant getter) would consume the prank first.
        vm.prank(SYSTEM_ADDR);
        sentinel.react(log);
    }

    function _arm() internal {
        vault.openPosition{ value: POSITION }(FLOOR);
        _react(_log(sentinel.POSITION_OPENED_TOPIC(), abi.encode(POSITION, FLOOR)));
    }

    function _priceUpdate(uint256 price) internal {
        _react(_log(sentinel.PRICE_UPDATED_TOPIC(), abi.encode(price)));
    }

    // ---------- sentinel: configuration & arming ----------

    function testConfigureSubscribesToBothVaultEvents() public view {
        assertEq(system.subscribeCount(), 2);
        assertEq(system.lastSubChainId(), SEPOLIA);
        assertEq(system.lastSubContract(), address(vault));
        assertEq(sentinel.vault(), address(vault));
    }

    function testPositionOpenedArmsSentinel() public {
        _arm();
        assertTrue(sentinel.armed());
        assertEq(sentinel.floor(), FLOOR);
    }

    function testReactRevertsForNonSystemCaller() public {
        IReactive.LogRecord memory log = _log(sentinel.PRICE_UPDATED_TOPIC(), abi.encode(uint256(1)));
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, SYSTEM_ADDR)
        );
        sentinel.react(log);
    }

    function testReactIgnoresOtherContractsLogs() public {
        IReactive.LogRecord memory log = _log(sentinel.POSITION_OPENED_TOPIC(), abi.encode(POSITION, FLOOR));
        log.contractAddress = stranger;
        vm.prank(SYSTEM_ADDR);
        sentinel.react(log);
        assertFalse(sentinel.armed());
    }

    // ---------- sentinel: trigger logic ----------

    function testNoCallbackWhilePriceAboveFloor() public {
        _arm();
        _priceUpdate(FLOOR); // equal is not a breach
        _priceUpdate(FLOOR + 50);
        assertEq(system.callbackCount(), 0);
        assertTrue(sentinel.armed());
        assertEq(sentinel.lastPrice(), FLOOR + 50);
    }

    function testBreachRequestsExactlyOneCallback() public {
        _arm();
        _priceUpdate(FLOOR - 1);

        assertEq(system.callbackCount(), 1);
        assertEq(system.lastCallbackChainId(), SEPOLIA);
        assertEq(system.lastCallbackRecipient(), address(vault));
        assertEq(system.lastCallbackGasLimit(), 1_000_000);
        assertFalse(sentinel.armed());
        assertEq(sentinel.triggerCount(), 1);

        bytes memory expected =
            abi.encodeWithSignature("closePosition(address,uint256)", address(0), FLOOR - 1);
        assertEq(system.lastCallbackPayload(), expected);

        // Further falls must not fire again — the latch holds.
        _priceUpdate(FLOOR - 50);
        assertEq(system.callbackCount(), 1);
    }

    function testNoTriggerBeforeArming() public {
        _priceUpdate(1); // crash before any position was opened
        assertEq(system.callbackCount(), 0);
    }

    // ---------- vault: position lifecycle ----------

    function testOpenPositionGuards() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SentinelVault.NotOwner.selector, stranger));
        vault.openPosition{ value: 1 ether }(FLOOR);

        vm.expectRevert("deposit required");
        vault.openPosition(0);

        vault.openPosition{ value: POSITION }(FLOOR);
        vm.expectRevert("position already open");
        vault.openPosition{ value: 1 ether }(FLOOR);
    }

    function testClosePositionRejectsDirectCall() public {
        _arm();
        vm.expectRevert(
            abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, address(this), address(proxy))
        );
        vault.closePosition(address(sentinel), FLOOR - 1);
    }

    function testClosePositionRejectsWrongReactiveSender() public {
        _arm();
        vm.expectRevert(
            abi.encodeWithSelector(
                AbstractCallback.CallbackNotAuthorized.selector, stranger, address(sentinel)
            )
        );
        proxy.deliver(
            address(vault),
            abi.encodeWithSignature("closePosition(address,uint256)", address(0), FLOOR - 1),
            stranger
        );
    }

    // ---------- the full loop, end to end ----------

    function testFullLoopClosesPositionAndRefundsOwner() public {
        uint256 ownerBefore = address(this).balance;

        _arm();
        _priceUpdate(FLOOR - 25);
        assertEq(system.callbackCount(), 1);

        // Deliver exactly what the sentinel requested, through the proxy.
        proxy.deliver(address(vault), system.lastCallbackPayload(), address(sentinel));

        assertFalse(vault.positionOpen());
        assertEq(vault.closedAtPrice(), FLOOR - 25);

        // Vault held 0.1 ether of fee funding + the 2 ether position; the
        // close retains a 0.005 ether fee reserve and refunds the rest.
        uint256 expectedPayout = 0.1 ether + POSITION - 0.005 ether;
        assertEq(vault.refundedAmount(), expectedPayout);
        assertEq(address(this).balance, ownerBefore - POSITION + expectedPayout);
        assertEq(address(vault).balance, 0.005 ether);

        // The retained reserve is reclaimable once the position is closed.
        vault.withdrawReserve();
        assertEq(address(vault).balance, 0);
    }
}
