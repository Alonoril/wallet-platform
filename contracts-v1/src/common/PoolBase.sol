// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { TenantComponent } from "./TenantComponent.sol";
import { ExactTransfer } from "./ExactTransfer.sol";
import { WalletTypes } from "./WalletTypes.sol";
import { TenantAuthority } from "../control/TenantAuthority.sol";
import { PoolRegistry } from "../control/PoolRegistry.sol";
import { RiskRegistry } from "../control/RiskRegistry.sol";

abstract contract PoolBase is TenantComponent, ReentrancyGuard {
    bytes32 public immutable poolId;
    PoolRegistry public immutable pools;
    RiskRegistry public immutable risk;
    address public immutable dispositionController;

    constructor(TenantAuthority authority_, PoolRegistry pools_, RiskRegistry risk_)
        TenantComponent(authority_)
    {
        if (
            address(pools_.authority()) != address(authority_)
                || address(risk_.authority()) != address(authority_)
        ) revert InvalidConfiguration();
        poolId = pools_.poolId();
        pools = pools_;
        risk = risk_;
        dispositionController = risk_.dispositionController();
    }

    function dispose(address token, address destination, uint256 amount) external nonReentrant {
        if (msg.sender != dispositionController) revert Unauthorized();
        pools.assertRoute(WalletTypes.RouteKind.Disposition, address(this), destination);
        risk.assertNoSecurityPause(address(this), token);
        uint256 safetyFloor =
            pools.poolKind(address(this)) == WalletTypes.PoolKind.Treasury ? pools.safetyFloor(token) : 0;
        risk.assertBalanceFloor(address(this), token, amount, safetyFloor);
        ExactTransfer.send(token, destination, amount);
    }

    receive() external payable { }
}
