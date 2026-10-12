// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { TenantAuthority } from "../control/TenantAuthority.sol";
import { MilonWithdrawalVerifier } from "./MilonWithdrawalVerifier.sol";
import { IHotPoolManager } from "../common/IWallet.sol";
import { WalletTypes as T } from "../common/WalletTypes.sol";
import { PermitHash } from "../common/PermitHash.sol";

/// @title 全租户热钱包共享的提现订单终态簿
/// @notice requestId 的 Unused → Executed/Cancelled 转换不可逆，换热池或重签 Permit 不会清除历史。
contract WithdrawalBook is EIP712 {
    /// @notice 保留最终状态、实际付款池、经济参数摘要与授权引用，供节点独立核验跨链结果。
    struct Order {
        T.OrderStatus status;
        address vault;
        bytes32 economicHash;
        bytes32 permitDigest;
        bytes32 authorizationHash;
    }

    /// @notice 固定租户权限根与来源验证器；不提供迁移或清空消费状态的入口。
    TenantAuthority public immutable authority;
    MilonWithdrawalVerifier public immutable verifier;
    /// @notice 以来源链、genesis、App、租户和 requestId 派生的订单键保存永久终态。
    mapping(bytes32 => Order) private _orders;

    error OrderAlreadyFinalized();
    error InvalidOrder();
    error InvalidCancellation();

    event OrderExecuted(
        bytes32 indexed orderKey,
        bytes32 indexed requestId,
        address indexed vault,
        bytes32 economicHash,
        bytes32 permitDigest,
        bytes32 authorizationHash
    );
    event OrderCancelled(
        bytes32 indexed orderKey,
        bytes32 indexed requestId,
        bytes32 cancelDigest,
        bytes32 authorizationHash,
        bool emergency
    );

    /// @dev 固定同租户权限根和来源验证器，后续不提供更换或删除历史订单的入口。
    constructor(TenantAuthority tenantAuthority, MilonWithdrawalVerifier bridgeVerifier)
        EIP712("WithdrawalBook", "2")
    {
        authority = tenantAuthority;
        verifier = bridgeVerifier;
    }

    /// @notice 经济订单的唯一键不包含付款池、attempt 或 Permit digest，因此跨池重新签名也无法重复付款。
    function orderKey(bytes32 requestId) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("WITHDRAWAL_ORDER_V2"),
                verifier.bridgeId(),
                verifier.sourceChainId(),
                verifier.sourceGenesisHash(),
                verifier.withdrawalAppId(),
                authority.tenantKey(),
                requestId
            )
        );
    }

    /// @notice 后端恢复、付款回执和安全取消必须查询的权威状态；查询结果仍需等待链终局。
    function order(bytes32 requestId) external view returns (Order memory) {
        return _orders[orderKey(requestId)];
    }

    /// @notice 只有本租户登记热钱包能在放款事务内消费订单。
    /// @dev 先写入 Executed，再由热钱包转账；付款失败会一起回滚，不能把这一中间调用当作最终回执。
    function consume(bytes32 requestId, bytes32 economicHash, bytes32 permitDigest, bytes32 authorizationHash)
        external
    {
        if (
            !authority.ready() || !IHotPoolManager(authority.hotPoolManager()).isHotVault(msg.sender)
                || requestId == bytes32(0) || economicHash == bytes32(0) || permitDigest == bytes32(0)
        ) revert InvalidOrder();
        bytes32 key = orderKey(requestId);
        if (_orders[key].status != T.OrderStatus.Unused) revert OrderAlreadyFinalized();
        _orders[key] =
            Order(T.OrderStatus.Executed, msg.sender, economicHash, permitDigest, authorizationHash);
        emit OrderExecuted(key, requestId, msg.sender, economicHash, permitDigest, authorizationHash);
    }

    /// @notice 取消有独立 EIP-712 类型和本订单簿 domain，不能拿付款 Permit 签名替代。
    function hashCancel(T.CancelPermit calldata p) external view returns (bytes32) {
        return _hashTypedDataV4(PermitHash.cancel(p));
    }

    /// @notice 中继经委员会签署的取消证书，将仍未付款的订单永久禁付。
    /// @dev 和付款争夺同一个状态；只有取消在 EVM 最终确认后，Milon 才能释放预留。
    function cancel(T.CancelPermit calldata p, bytes calldata certificate) external {
        authority.checkRelayer(msg.sender);
        authority.checkTime(p.validAfter, p.deadline);
        if (
            p.requestId == bytes32(0) || p.tenantKey != authority.tenantKey()
                || p.cancellationContext == bytes32(0) || p.signerEpoch != authority.withdrawalSignerEpoch()
        ) revert InvalidCancellation();
        bytes32 digest = _hashTypedDataV4(PermitHash.cancel(p));
        bool valid;
        try verifier.verifyCancellation(digest, certificate) returns (bool accepted) {
            valid = accepted;
        } catch {
            valid = false;
        }
        if (!valid) revert InvalidCancellation();
        _cancel(p.requestId, digest, keccak256(certificate), false);
    }

    /// @notice 桥故障时的应急禁付，不依赖桥验签器在线；Guardian 只能取消未执行订单，不能出金。
    function cancelByGuardian(bytes32 requestId, bytes32 reason) external {
        authority.checkGuardian(msg.sender);
        if (!authority.ready() || requestId == bytes32(0) || reason == bytes32(0)) {
            revert InvalidCancellation();
        }
        _cancel(requestId, reason, bytes32(0), true);
    }

    /// @dev 统一写入不可逆 Cancelled 终态并保存取消证据引用；已付款或已取消的经济订单不能重新修改。
    function _cancel(bytes32 requestId, bytes32 digest, bytes32 authorizationHash, bool emergency) private {
        bytes32 key = orderKey(requestId);
        if (_orders[key].status != T.OrderStatus.Unused) revert OrderAlreadyFinalized();
        _orders[key] = Order(T.OrderStatus.Cancelled, address(0), bytes32(0), digest, authorizationHash);
        emit OrderCancelled(key, requestId, digest, authorizationHash, emergency);
    }
}
