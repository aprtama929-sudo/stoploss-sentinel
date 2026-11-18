// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/// @notice Test double for the Reactive system contract. Etched onto the real
///         system contract address (0x8888...8888) in tests so the sentinel's
///         hardcoded SYSTEM constant talks to this mock. Records every
///         subscription and callback request for assertions.
contract MockSystemContract {
    uint256 public subscribeCount;
    uint256 public unsubscribeCount;
    uint256 public lastSubChainId;
    address public lastSubContract;
    uint256 public lastSubTopic0;

    uint256 public callbackCount;
    uint256 public lastCallbackChainId;
    address public lastCallbackRecipient;
    uint64 public lastCallbackGasLimit;
    bytes public lastCallbackPayload;

    mapping(address => uint256) public debts;
    mapping(address => uint256) public reserveBalances;

    receive() external payable {}

    function subscribe(uint256 chainId_, address contract_, uint256 topic0_, uint256, uint256, uint256) external {
        subscribeCount++;
        lastSubChainId = chainId_;
        lastSubContract = contract_;
        lastSubTopic0 = topic0_;
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        unsubscribeCount++;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        callbackCount++;
        lastCallbackChainId = config_.chainId;
        lastCallbackRecipient = config_.recipient;
        lastCallbackGasLimit = config_.gasLimit;
        lastCallbackPayload = config_.payload;
    }

    function requestCallback(ISystemContract.CallbackVersion, bytes memory) external {
        callbackCount++;
    }

    function depositTo(address target_) external payable {
        reserveBalances[target_] += msg.value;
    }

    function debt(address contract_) external view returns (uint256) {
        return debts[contract_];
    }

    function setDebt(address contract_, uint256 amount_) external {
        debts[contract_] = amount_;
    }
}
