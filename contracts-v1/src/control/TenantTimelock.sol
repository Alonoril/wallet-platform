// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Delayed governance cannot subsequently reduce its delay below the immutable two-day floor.
contract TenantTimelock is TimelockController {
    uint256 public constant DELAY_FLOOR = 2 days;

    error DelayBelowFloor();

    constructor(address council)
        TimelockController(DELAY_FLOOR, _members(council), _members(council), address(0))
    { }

    function _execute(address target, uint256 value, bytes calldata payload) internal override {
        if (
            target == address(this) && payload.length >= 4 && bytes4(payload[:4]) == this.updateDelay.selector
                && abi.decode(payload[4:], (uint256)) < DELAY_FLOOR
        ) revert DelayBelowFloor();
        super._execute(target, value, payload);
    }

    function _members(address council) private pure returns (address[] memory members) {
        require(council != address(0), "invalid council");
        members = new address[](1);
        members[0] = council;
    }
}
