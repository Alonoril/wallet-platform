// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library BoundedCall {
    /// @notice Never copies an unbounded revert/return buffer from an isolated batch item.
    function invoke(address target, bytes memory payload, uint256 gasCap)
        internal
        returns (bool success, bytes32 resultDigest)
    {
        bytes memory result;
        assembly ("memory-safe") {
            success := call(gasCap, target, 0, add(payload, 32), mload(payload), 0, 0)
            let length := returndatasize()
            if gt(length, 256) { length := 256 }
            result := mload(0x40)
            mstore(result, length)
            returndatacopy(add(result, 32), 0, length)
            mstore(0x40, add(add(result, 32), and(add(length, 31), not(31))))
        }
        resultDigest = keccak256(result);
    }
}
