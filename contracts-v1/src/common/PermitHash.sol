// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { WalletTypes } from "./WalletTypes.sol";

/// @dev All permit members are static ABI types; abi.encode(typeHash, tuple) has the EIP-712 field layout.
library PermitHash {
    bytes32 internal constant SWEEP = keccak256(
        "SweepPermit(bytes32 operationId,bytes32 tenantKey,bytes32 poolId,bytes32 walletKey,address factory,address vault,address token,address destination,uint256 amount,uint256 expectedBalance,bytes32 riskDecisionId,bytes32 evidenceDigest,uint256 vaultEpoch,uint256 vaultAssetEpoch,uint256 poolEpoch,uint256 poolAssetEpoch,uint256 routeEpoch,uint256 signerEpoch,uint256 validAfter,uint256 deadline)"
    );
    bytes32 internal constant WITHDRAWAL = keccak256(
        "WithdrawalPermit(bytes32 requestId,bytes32 tenantKey,bytes32 poolId,address token,address to,uint256 amount,bytes32 approvalDigest,uint256 poolEpoch,uint256 poolAssetEpoch,uint256 policyEpoch,uint256 signerEpoch,uint256 validAfter,uint256 deadline)"
    );
    bytes32 internal constant SETTLEMENT = keccak256(
        "SettlementPermit(bytes32 operationId,bytes32 tenantKey,bytes32 poolId,address token,address destination,bytes32 lotsHash,bytes32 evidenceDigest,uint256 sourceEpoch,uint256 sourceAssetEpoch,uint256 destinationEpoch,uint256 destinationAssetEpoch,uint256 routeEpoch,uint256 signerEpoch,uint256 validAfter,uint256 deadline)"
    );
    bytes32 internal constant TRANSFER = keccak256(
        "TransferPermit(bytes32 operationId,bytes32 tenantKey,bytes32 poolId,uint8 kind,address token,address destination,uint256 amount,bytes32 approvalDigest,uint256 sourceEpoch,uint256 sourceAssetEpoch,uint256 destinationEpoch,uint256 destinationAssetEpoch,uint256 routeEpoch,uint256 policyEpoch,uint256 signerEpoch,uint256 validAfter,uint256 deadline)"
    );
    bytes32 internal constant DISPOSITION = keccak256(
        "DispositionPermit(bytes32 operationId,bytes32 tenantKey,bytes32 poolId,bytes32 caseId,bytes32 walletKey,address source,address token,address destination,uint256 amount,uint256 reserveToMove,bytes32 evidenceDigest,bytes32 sourceControlDigest,bytes32 destinationControlDigest,uint256 reserveVersion,uint256 routeEpoch,bytes32 lotsHash,bool preserveRestriction,uint256 validAfter,uint256 deadline)"
    );

    function sweep(WalletTypes.SweepPermit calldata p) internal pure returns (bytes32) {
        return keccak256(abi.encode(SWEEP, p));
    }

    function withdrawal(WalletTypes.WithdrawalPermit calldata p) internal pure returns (bytes32) {
        return keccak256(abi.encode(WITHDRAWAL, p));
    }

    function settlement(WalletTypes.SettlementPermit calldata p) internal pure returns (bytes32) {
        return keccak256(abi.encode(SETTLEMENT, p));
    }

    function transfer(WalletTypes.TransferPermit calldata p) internal pure returns (bytes32) {
        return keccak256(abi.encode(TRANSFER, p));
    }

    function disposition(WalletTypes.DispositionPermit calldata p) internal pure returns (bytes32) {
        return keccak256(abi.encode(DISPOSITION, p));
    }
}
