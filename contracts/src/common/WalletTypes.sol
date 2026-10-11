// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library WalletTypes {
    enum PoolKind {
        None,
        Treasury,
        Clearing,
        Quarantine,
        Cold
    }
    enum RouteKind {
        Sweep,
        Settlement,
        Rebalance,
        Migration,
        Disposition
    }
    enum OperationStatus {
        Unused,
        Executed,
        Cancelled
    }

    struct SweepPermit {
        bytes32 operationId;
        bytes32 tenantKey;
        bytes32 poolId;
        bytes32 walletKey;
        address factory;
        address vault;
        address token;
        address destination;
        uint256 amount;
        uint256 expectedBalance;
        bytes32 riskDecisionId;
        bytes32 evidenceDigest;
        uint256 vaultEpoch;
        uint256 vaultAssetEpoch;
        uint256 poolEpoch;
        uint256 poolAssetEpoch;
        uint256 routeEpoch;
        uint256 signerEpoch;
        uint256 validAfter;
        uint256 deadline;
    }

    struct WithdrawalPermit {
        bytes32 requestId;
        bytes32 tenantKey;
        bytes32 poolId;
        address token;
        address to;
        uint256 amount;
        bytes32 approvalDigest;
        uint256 poolEpoch;
        uint256 poolAssetEpoch;
        uint256 policyEpoch;
        uint256 signerEpoch;
        uint256 validAfter;
        uint256 deadline;
    }

    struct SettlementPermit {
        bytes32 operationId;
        bytes32 tenantKey;
        bytes32 poolId;
        address token;
        address destination;
        bytes32 lotsHash;
        bytes32 evidenceDigest;
        uint256 sourceEpoch;
        uint256 sourceAssetEpoch;
        uint256 destinationEpoch;
        uint256 destinationAssetEpoch;
        uint256 routeEpoch;
        uint256 signerEpoch;
        uint256 validAfter;
        uint256 deadline;
    }

    struct TransferPermit {
        bytes32 operationId;
        bytes32 tenantKey;
        bytes32 poolId;
        RouteKind kind;
        address token;
        address destination;
        uint256 amount;
        bytes32 approvalDigest;
        uint256 sourceEpoch;
        uint256 sourceAssetEpoch;
        uint256 destinationEpoch;
        uint256 destinationAssetEpoch;
        uint256 routeEpoch;
        uint256 policyEpoch;
        uint256 signerEpoch;
        uint256 validAfter;
        uint256 deadline;
    }

    struct DispositionPermit {
        bytes32 operationId;
        bytes32 tenantKey;
        bytes32 poolId;
        bytes32 caseId;
        bytes32 walletKey;
        address source;
        address token;
        address destination;
        uint256 amount;
        uint256 reserveToMove;
        bytes32 evidenceDigest;
        bytes32 sourceControlDigest;
        bytes32 destinationControlDigest;
        uint256 reserveVersion;
        uint256 routeEpoch;
        bytes32 lotsHash;
        bool preserveRestriction;
        uint256 validAfter;
        uint256 deadline;
    }

    struct Limits {
        uint256 single;
        uint256 daily;
        uint256 rolling;
        uint256 councilThreshold;
        uint256 safetyFloor;
    }
}
