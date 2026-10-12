// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { WalletTypes as T } from "./WalletTypes.sol";

/// @title v2 EIP-712 正文哈希协议
/// @notice 字段顺序与位宽是跨端 ABI，任何修改都必须同步 interfaces/eip712.json 与摘要向量。
/// @dev 这里只产生 structHash，最终签名摘要由具体合约加入链 ID、版本及自身地址 domain。
library PermitHash {
    bytes32 internal constant REFUND = keccak256(
        "RefundPermit(bytes32 tenantKey,bytes32 userKey,bytes32 walletKey,bytes32 assetKey,address token,address recipient,uint256 amount,uint256 assetStateNonce,uint64 userSignerEpoch,uint64 refundSignerEpoch,uint48 validAfter,uint48 deadline)"
    );
    bytes32 internal constant WALLET_BINDING = keccak256(
        "WalletBinding(bytes32 tenantKey,bytes32 userKey,bytes32 logicalWalletId,address userSigner,uint48 validAfter,uint48 deadline)"
    );
    bytes32 internal constant USER_ROTATION = keccak256(
        "UserSignerRotation(bytes32 tenantKey,bytes32 userKey,address oldSigner,address newSigner,uint64 userSignerEpoch,uint64 refundSignerEpoch,uint48 validAfter,uint48 deadline)"
    );
    bytes32 internal constant ALLOCATION = keccak256(
        "SourceAllocation(bytes32 depositId,uint256 amount,uint48 observedAt,uint64 sourceRiskEpoch)"
    );
    bytes32 internal constant SWEEP = keccak256(
        "SweepPermit(bytes32 operationId,bytes32 tenantKey,bytes32 walletKey,bytes32 assetKey,address token,address hotVault,uint256 amount,uint256 expectedBalance,uint256 assetStateNonce,bytes32 allocationsHash,uint64 mappingEpoch,uint64 assetEpoch,uint64 capVersion,uint64 vaultEpoch,uint64 vaultAssetEpoch,uint64 userRiskEpoch,uint64 hotEpoch,uint64 hotAssetEpoch,uint64 policyEpoch,uint64 authorityEpoch,uint64 sweepSignerEpoch,uint48 validAfter,uint48 deadline)"
    );
    bytes32 internal constant WITHDRAWAL = keccak256(
        "WithdrawalPermit(bytes32 requestId,bytes32 tenantKey,bytes32 userKey,bytes32 assetKey,bytes32 poolId,address token,address to,uint256 amount,bytes32 approvalDigest,uint64 mappingEpoch,uint64 assetEpoch,uint64 poolEpoch,uint64 poolAssetEpoch,uint64 userRiskEpoch,uint64 recipientRiskEpoch,uint64 policyEpoch,uint64 authorityEpoch,uint64 signerEpoch,uint48 validAfter,uint48 deadline)"
    );
    bytes32 internal constant MOVEMENT = keccak256(
        "MovementPermit(bytes32 operationId,bytes32 tenantKey,bytes32 assetKey,address token,address destination,uint256 amount,uint256 expectedBalance,uint256 assetStateNonce,uint256 requiredCapacity,uint64 mappingEpoch,uint64 assetEpoch,uint64 capVersion,uint64 sourceEpoch,uint64 sourceAssetEpoch,uint64 destinationEpoch,uint64 destinationAssetEpoch,uint64 destinationRecipientEpoch,uint64 coldAddressEpoch,uint64 policyEpoch,uint64 authorityEpoch,uint64 transferSignerEpoch,uint48 validAfter,uint48 deadline)"
    );
    bytes32 internal constant ATTESTATION = keccak256(
        "WithdrawalAttestation(bytes32 permitDigest,uint256 sourceChainId,bytes32 sourceGenesisHash,uint8 withdrawalAppId,bytes32 committeeId,uint64 committeeEpoch,uint64 approvedHeight,bytes32 approvedBlockHash,bytes32 approvedTxHash,uint64 bridgeEpoch,uint8 action)"
    );
    bytes32 internal constant CANCEL_ATTESTATION = keccak256(
        "CancellationAttestation(bytes32 cancelDigest,uint256 sourceChainId,bytes32 sourceGenesisHash,uint8 withdrawalAppId,bytes32 committeeId,uint64 committeeEpoch,uint64 approvedHeight,bytes32 approvedBlockHash,bytes32 approvedTxHash,uint64 bridgeEpoch,uint8 action)"
    );
    bytes32 internal constant CANCEL = keccak256(
        "CancelPermit(bytes32 requestId,bytes32 tenantKey,bytes32 cancellationContext,uint64 signerEpoch,uint48 validAfter,uint48 deadline)"
    );

    // Every tuple here is static; abi.encode(typeHash, tuple) encodes fields in the declared order.
    /// @dev 按固定字段顺序产生用户与平台共同签署的退款正文 structHash；domain 由 DepositVault 加入。
    function refund(T.RefundPermit calldata p) internal pure returns (bytes32) {
        return keccak256(abi.encode(REFUND, p));
    }

    /// @dev 产生用户确认身份和逻辑钱包绑定的正文 hash，不能与退款签名互换。
    function walletBinding(T.WalletBinding calldata p) internal pure returns (bytes32) {
        return keccak256(abi.encode(WALLET_BINDING, p));
    }

    /// @dev 产生原用户、新用户密钥证明与平台共同签署的独立轮换正文 hash。
    function userRotation(T.UserSignerRotation calldata p) internal pure returns (bytes32) {
        return keccak256(abi.encode(USER_ROTATION, p));
    }

    /// @dev 产生绑定当前余额、nonce、来源数组摘要和所有有效版本的归集正文 hash。
    function sweep(T.SweepPermit calldata p) internal pure returns (bytes32) {
        return keccak256(abi.encode(SWEEP, p));
    }

    /// @dev 产生包含经济订单、池身份、付款参数和 Milon 审批上下文的正文 hash。
    function withdrawal(T.WithdrawalPermit calldata p) internal pure returns (bytes32) {
        return keccak256(abi.encode(WITHDRAWAL, p));
    }

    /// @dev 产生固定源状态、目标和用途的内部移动正文 hash，目标不能由交易中继改写。
    function movement(T.MovementPermit calldata p) internal pure returns (bytes32) {
        return keccak256(abi.encode(MOVEMENT, p));
    }

    /// @dev 产生委员共同签署的付款证书正文 hash；所有成员必须认证同一来源定位。
    function attestation(T.WithdrawalAttestation memory p) internal pure returns (bytes32) {
        return keccak256(abi.encode(ATTESTATION, p));
    }

    /// @dev 产生与付款批准完全独立的取消证书正文 hash，隔离证书用途。
    function cancellationAttestation(T.CancellationAttestation memory p) internal pure returns (bytes32) {
        return keccak256(abi.encode(CANCEL_ATTESTATION, p));
    }

    /// @dev 产生共享订单禁付正文 hash，最终由 WithdrawalBook 加入自身 EIP-712 domain。
    function cancel(T.CancelPermit calldata p) internal pure returns (bytes32) {
        return keccak256(abi.encode(CANCEL, p));
    }

    /// @notice 按 EIP-712 数组规则拼接每个来源的 structHash 再 Keccak，顺序必须与归集正文一致。
    function allocations(T.SourceAllocation[] calldata entries) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](entries.length);
        for (uint256 i; i < entries.length; ++i) {
            hashes[i] = keccak256(abi.encode(ALLOCATION, entries[i]));
        }
        return keccak256(abi.encodePacked(hashes));
    }
}
