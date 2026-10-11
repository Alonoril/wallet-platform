// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { TenantAuthority } from "./TenantAuthority.sol";
import { PoolRegistry } from "./PoolRegistry.sol";
import { RiskRegistry } from "./RiskRegistry.sol";
import { OperationBook } from "../common/OperationBook.sol";
import { TenantComponent } from "../common/TenantComponent.sol";
import { WalletTypes } from "../common/WalletTypes.sol";
import { PermitHash } from "../common/PermitHash.sol";
import { VaultFactory } from "../deposit/VaultFactory.sol";
import { ClearingVault } from "../pools/ClearingVault.sol";

interface IDispositionSource {
    function dispose(address token, address destination, uint256 amount) external;
}

contract DispositionController is OperationBook, EIP712, ReentrancyGuard {
    RiskRegistry public immutable risk;
    PoolRegistry public immutable pools;
    VaultFactory public immutable factory;
    bytes32 public immutable poolId;

    event DispositionExecuted(
        bytes32 indexed operationId,
        bytes32 indexed caseId,
        address indexed source,
        address token,
        address destination,
        uint256 amount,
        bool preserveRestriction
    );

    constructor(TenantAuthority authority_, RiskRegistry risk_, PoolRegistry pools_, VaultFactory factory_)
        TenantComponent(authority_)
        EIP712("Milon Disposition", "1")
    {
        if (
            risk_.dispositionController() != address(this) || pools_.factory() != address(factory_)
                || address(risk_.authority()) != address(authority_)
                || address(pools_.authority()) != address(authority_)
        ) revert InvalidConfiguration();
        risk = risk_;
        pools = pools_;
        factory = factory_;
        poolId = pools_.poolId();
    }

    function hashDisposition(WalletTypes.DispositionPermit calldata p) public view returns (bytes32) {
        return _hashTypedDataV4(PermitHash.disposition(p));
    }

    function executeDisposition(
        WalletTypes.DispositionPermit calldata p,
        bytes32[] calldata lotIds,
        uint256[] calldata amounts,
        bytes calldata councilAuthorization
    ) external onlyExecutor nonReentrant {
        _validateTime(p.validAfter, p.deadline);
        _validateAsset(p.token);
        if (
            p.tenantKey != tenantKey || p.poolId != poolId || p.amount == 0 || p.caseId == bytes32(0)
                || p.evidenceDigest == bytes32(0) || p.routeEpoch != pools.routeEpoch()
                || p.sourceControlDigest != risk.controlDigest(p.source, p.token)
                || p.destinationControlDigest != risk.controlDigest(p.destination, p.token)
        ) revert InvalidPermit();
        authority.verifyCouncil(hashDisposition(p), councilAuthorization);
        bool deposit = p.walletKey != bytes32(0);
        if (deposit) {
            if (p.source != factory.predictVault(p.walletKey)) revert InvalidPermit();
        } else if (pools.poolKind(p.source) == WalletTypes.PoolKind.None) {
            revert InvalidPermit();
        }
        if (p.preserveRestriction) {
            if (pools.poolKind(p.destination) != WalletTypes.PoolKind.Quarantine) revert InvalidPermit();
        } else if (
            pools.poolKind(p.source) != WalletTypes.PoolKind.Quarantine
                || pools.poolKind(p.destination) != WalletTypes.PoolKind.Treasury
        ) {
            revert InvalidPermit();
        }
        pools.assertRoute(
            WalletTypes.RouteKind.Disposition, deposit ? address(factory) : p.source, p.destination
        );
        _consume(p.operationId);
        risk.relocateReserve(
            p.source,
            p.destination,
            p.token,
            p.caseId,
            p.amount,
            p.reserveToMove,
            p.reserveVersion,
            p.preserveRestriction
        );
        if (deposit) factory.deployVault(p.walletKey);
        if (!deposit && pools.poolKind(p.source) == WalletTypes.PoolKind.Clearing) {
            if (p.lotsHash == bytes32(0) && lotIds.length == 0 && amounts.length == 0) {
                ClearingVault(payable(p.source)).assertUnattributedDisposition(p.token, p.amount);
            } else if (
                p.lotsHash != keccak256(abi.encode(lotIds, amounts))
                    || ClearingVault(payable(p.source)).prepareDisposition(
                        p.operationId, p.token, lotIds, amounts
                    ) != p.amount
            ) {
                revert InvalidPermit();
            }
        } else if (lotIds.length != 0 || amounts.length != 0 || p.lotsHash != bytes32(0)) {
            revert InvalidPermit();
        }
        IDispositionSource(p.source).dispose(p.token, p.destination, p.amount);
        emit DispositionExecuted(
            p.operationId, p.caseId, p.source, p.token, p.destination, p.amount, p.preserveRestriction
        );
    }
}
