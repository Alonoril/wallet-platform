// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { TenantAuthority } from "../control/TenantAuthority.sol";
import { RiskRegistry } from "../control/RiskRegistry.sol";
import { PoolRegistry } from "../control/PoolRegistry.sol";
import { PoolBase } from "../common/PoolBase.sol";
import { OperationBook } from "../common/OperationBook.sol";
import { WalletTypes } from "../common/WalletTypes.sol";
import { PermitHash } from "../common/PermitHash.sol";
import { ExactTransfer } from "../common/ExactTransfer.sol";

contract TreasuryVault is PoolBase, OperationBook, EIP712 {
    event WithdrawalExecuted(
        bytes32 indexed requestId,
        address indexed token,
        address indexed to,
        uint256 amount,
        bytes32 approvalDigest
    );
    event TreasuryTransferred(
        bytes32 indexed operationId,
        address indexed token,
        address indexed destination,
        uint256 amount,
        WalletTypes.RouteKind kind
    );

    constructor(TenantAuthority authority_, PoolRegistry pools_, RiskRegistry risk_)
        PoolBase(authority_, pools_, risk_)
        EIP712("Milon Treasury", "1")
    { }

    function hashWithdrawal(WalletTypes.WithdrawalPermit calldata p) public view returns (bytes32) {
        return _hashTypedDataV4(PermitHash.withdrawal(p));
    }

    function hashTransfer(WalletTypes.TransferPermit calldata p) public view returns (bytes32) {
        return _hashTypedDataV4(PermitHash.transfer(p));
    }

    function requestStatus(bytes32 requestId) external view returns (WalletTypes.OperationStatus) {
        return operationStatus[requestId];
    }

    function cancelWithdrawal(bytes32 requestId) external {
        cancelOperation(requestId);
    }

    function executeWithdrawal(
        WalletTypes.WithdrawalPermit calldata p,
        bytes calldata authorization,
        bytes calldata councilAuthorization
    ) external onlyExecutor nonReentrant {
        _validateTime(p.validAfter, p.deadline);
        _validateAsset(p.token);
        if (
            p.tenantKey != tenantKey || p.poolId != poolId || p.approvalDigest == bytes32(0)
                || p.policyEpoch != pools.policyEpoch() || p.to == address(0) || p.to == address(this)
                || pools.isInternal(p.to) || pools.blockedRecipients(p.to)
        ) revert InvalidPermit();
        bytes32 digest = hashWithdrawal(p);
        authority.verify(authority.WITHDRAWAL_SIGNER(), p.signerEpoch, digest, authorization);
        if (pools.councilRequired(p.token, p.amount)) authority.verifyCouncil(digest, councilAuthorization);
        risk.assertEpochs(address(this), p.token, p.poolEpoch, p.poolAssetEpoch);
        risk.assertSpendable(address(this), p.token, p.amount, pools.safetyFloor(p.token));
        _consume(p.requestId);
        pools.consumeLimit(p.token, p.amount);
        ExactTransfer.send(p.token, p.to, p.amount);
        emit WithdrawalExecuted(p.requestId, p.token, p.to, p.amount, p.approvalDigest);
    }

    /// @notice Internal rebalancing/migration shares risk checks and tenant-wide limits with withdrawals.
    function transferCustody(
        WalletTypes.TransferPermit calldata p,
        bytes calldata authorization,
        bytes calldata councilAuthorization
    ) external onlyExecutor nonReentrant {
        _validateTime(p.validAfter, p.deadline);
        _validateAsset(p.token);
        if (p.kind != WalletTypes.RouteKind.Rebalance && p.kind != WalletTypes.RouteKind.Migration) {
            revert InvalidPermit();
        }
        if (
            p.tenantKey != tenantKey || p.poolId != poolId || p.approvalDigest == bytes32(0)
                || p.routeEpoch != pools.routeEpoch() || p.policyEpoch != pools.policyEpoch()
        ) revert InvalidPermit();
        bytes32 digest = hashTransfer(p);
        authority.verify(authority.TRANSFER_SIGNER(), p.signerEpoch, digest, authorization);
        // Every migration and high-value rebalance needs independent council co-approval.
        if (p.kind == WalletTypes.RouteKind.Migration || pools.councilRequired(p.token, p.amount)) {
            authority.verifyCouncil(digest, councilAuthorization);
        }
        pools.assertRoute(p.kind, address(this), p.destination);
        risk.assertEpochs(address(this), p.token, p.sourceEpoch, p.sourceAssetEpoch);
        risk.assertEpochs(p.destination, p.token, p.destinationEpoch, p.destinationAssetEpoch);
        risk.assertOpen(p.destination, p.token);
        risk.assertSpendable(address(this), p.token, p.amount, pools.safetyFloor(p.token));
        _consume(p.operationId);
        pools.consumeLimit(p.token, p.amount);
        ExactTransfer.send(p.token, p.destination, p.amount);
        emit TreasuryTransferred(p.operationId, p.token, p.destination, p.amount, p.kind);
    }
}
