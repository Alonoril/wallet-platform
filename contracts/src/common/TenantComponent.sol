// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TenantAuthority } from "../control/TenantAuthority.sol";

abstract contract TenantComponent {
    TenantAuthority public immutable authority;
    bytes32 public immutable tenantKey;

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidPermit();
    error OperationUnavailable();

    constructor(TenantAuthority authority_) {
        if (address(authority_).code.length == 0) revert InvalidConfiguration();
        authority = authority_;
        tenantKey = authority_.tenantKey();
    }

    modifier onlyGovernor() {
        if (msg.sender != authority.governor()) revert Unauthorized();
        _;
    }

    modifier onlyCouncil() {
        if (msg.sender != authority.council()) revert Unauthorized();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != authority.guardian() && msg.sender != authority.governor()) revert Unauthorized();
        _;
    }

    modifier onlyExecutor() {
        if (!authority.executors(msg.sender)) revert Unauthorized();
        _;
    }

    function _validateTime(uint256 validAfter, uint256 deadline) internal view {
        if (
            validAfter > deadline || deadline - validAfter > 1 hours || block.timestamp < validAfter
                || block.timestamp > deadline
        ) revert InvalidPermit();
    }

    function _validateAsset(address token) internal view {
        if (!authority.assets(token)) revert InvalidPermit();
    }
}
