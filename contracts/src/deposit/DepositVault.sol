// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { RiskRegistry } from "../control/RiskRegistry.sol";
import { PoolRegistry } from "../control/PoolRegistry.sol";
import { ExactTransfer } from "../common/ExactTransfer.sol";
import { WalletTypes } from "../common/WalletTypes.sol";

/// @notice Immutable code and per-tenant bindings, delegatecalled by standard ERC-1167 clones.
contract DepositVault is ReentrancyGuard {
    address public immutable trustedFactory;
    address public immutable manager;
    address public immutable dispositionController;
    RiskRegistry public immutable risk;
    PoolRegistry public immutable pools;
    bytes32 public immutable tenantKey;
    bytes32 public immutable poolId;
    bool public initialized;

    error Unauthorized();
    error AlreadyInitialized();

    constructor(
        address factory_,
        address manager_,
        address controller_,
        RiskRegistry risk_,
        PoolRegistry pools_
    ) {
        trustedFactory = factory_;
        manager = manager_;
        dispositionController = controller_;
        risk = risk_;
        pools = pools_;
        tenantKey = pools_.tenantKey();
        poolId = pools_.poolId();
        initialized = true; // Disable initialization of the implementation itself.
    }

    function initialize() external {
        if (msg.sender != trustedFactory) revert Unauthorized();
        if (initialized) revert AlreadyInitialized();
        initialized = true;
    }

    function sweep(address token, address destination, uint256 amount) external nonReentrant {
        if (!initialized || msg.sender != manager) revert Unauthorized();
        if (!pools.authority().assets(token)) revert Unauthorized();
        pools.assertRoute(WalletTypes.RouteKind.Sweep, trustedFactory, destination);
        risk.assertOpen(destination, token);
        risk.assertSpendable(address(this), token, amount, 0);
        ExactTransfer.send(token, destination, amount);
    }

    function dispose(address token, address destination, uint256 amount) external nonReentrant {
        if (!initialized || msg.sender != dispositionController) revert Unauthorized();
        pools.assertRoute(WalletTypes.RouteKind.Disposition, trustedFactory, destination);
        risk.assertNoSecurityPause(address(this), token);
        risk.assertBalanceFloor(address(this), token, amount, 0);
        ExactTransfer.send(token, destination, amount);
    }

    receive() external payable { }
}
