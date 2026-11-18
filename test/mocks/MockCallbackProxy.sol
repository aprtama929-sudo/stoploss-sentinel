// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Test double for the Reactive callback proxy on the destination
///         chain. `deliver` reproduces the real proxy's signature move: it
///         overwrites the first argument of the payload (a 160-bit slot the
///         requester leaves as address(0)) with the requesting reactive
///         contract's address before calling the target.
contract MockCallbackProxy {
    mapping(address => uint256) public debts;
    mapping(address => uint256) public reserveBalances;

    receive() external payable {}

    function depositTo(address target_) external payable {
        reserveBalances[target_] += msg.value;
    }

    function debt(address contract_) external view returns (uint256) {
        return debts[contract_];
    }

    function setDebt(address contract_, uint256 amount_) external {
        debts[contract_] = amount_;
    }

    /// @notice Deliver a callback payload to `target_`, injecting `rsc_` as
    ///         the first argument exactly like the production proxy does.
    function deliver(address target_, bytes memory payload_, address rsc_) external {
        // payload_ layout: [selector (4 bytes)] [arg0 word (32 bytes)] ...
        // Overwrite the arg0 word with the reactive contract's address.
        assembly {
            mstore(add(payload_, 0x24), rsc_)
        }
        (bool success, bytes memory result) = target_.call(payload_);
        if (!success) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
    }
}
