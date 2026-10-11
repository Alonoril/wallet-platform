// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { TenantAuthority } from "../control/TenantAuthority.sol";
import { PoolRegistry } from "../control/PoolRegistry.sol";
import { RiskRegistry } from "../control/RiskRegistry.sol";
import { PoolBase } from "../common/PoolBase.sol";
import { OperationBook } from "../common/OperationBook.sol";
import { WalletTypes } from "../common/WalletTypes.sol";
import { PermitHash } from "../common/PermitHash.sol";
import { ExactTransfer } from "../common/ExactTransfer.sol";

/// @notice Offline co-approval is mandatory for every return; no external payment or arbitrary execution.
contract ColdVault is PoolBase, OperationBook, EIP712 {
    event ColdReturned(
        bytes32 indexed operationId, address indexed token, address indexed treasury, uint256 amount
    );

    constructor(TenantAuthority authority_, PoolRegistry pools_, RiskRegistry risk_)
        PoolBase(authority_, pools_, risk_)
        EIP712("Milon Cold", "1")
    { }

    function hashTransfer(WalletTypes.TransferPermit calldata p) public view returns (bytes32) {
        return _hashTypedDataV4(PermitHash.transfer(p));
    }

    function returnToTreasury(
        WalletTypes.TransferPermit calldata p,
        bytes calldata authorization,
        bytes calldata councilAuthorization
    ) external onlyExecutor nonReentrant {
        _validateTime(p.validAfter, p.deadline);
        _validateAsset(p.token);
        if (
            p.kind != WalletTypes.RouteKind.Rebalance || p.tenantKey != tenantKey || p.poolId != poolId
                || p.approvalDigest == bytes32(0) || p.routeEpoch != pools.routeEpoch()
                || p.policyEpoch != pools.policyEpoch()
                || pools.poolKind(p.destination) != WalletTypes.PoolKind.Treasury
        ) revert InvalidPermit();
        bytes32 digest = hashTransfer(p);
        authority.verify(authority.TRANSFER_SIGNER(), p.signerEpoch, digest, authorization);
        authority.verifyCouncil(digest, councilAuthorization);
        pools.assertRoute(WalletTypes.RouteKind.Rebalance, address(this), p.destination);
        risk.assertEpochs(address(this), p.token, p.sourceEpoch, p.sourceAssetEpoch);
        risk.assertEpochs(p.destination, p.token, p.destinationEpoch, p.destinationAssetEpoch);
        risk.assertOpen(p.destination, p.token);
        risk.assertSpendable(address(this), p.token, p.amount, 0);
        _consume(p.operationId);
        pools.consumeLimit(p.token, p.amount);
        ExactTransfer.send(p.token, p.destination, p.amount);
        emit ColdReturned(p.operationId, p.token, p.destination, p.amount);
    }
}
