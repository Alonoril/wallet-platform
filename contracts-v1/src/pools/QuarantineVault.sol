// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TenantAuthority } from "../control/TenantAuthority.sol";
import { PoolRegistry } from "../control/PoolRegistry.sol";
import { RiskRegistry } from "../control/RiskRegistry.sol";
import { PoolBase } from "../common/PoolBase.sol";

/// @notice No normal payment/settlement functions. Only independently signed case dispositions may move funds.
contract QuarantineVault is PoolBase {
    constructor(TenantAuthority authority_, PoolRegistry pools_, RiskRegistry risk_)
        PoolBase(authority_, pools_, risk_)
    { }
}
