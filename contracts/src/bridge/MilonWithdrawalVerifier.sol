// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { TenantAuthority } from "../control/TenantAuthority.sol";
import { WalletTypes as T } from "../common/WalletTypes.sol";
import { PermitHash } from "../common/PermitHash.sol";

/// @title Milon 跨链委员会证书验证器
/// @notice EVM 验证独立 secp256k1 委员会的门限声明，不直接验证 Milon 原生共识 QC。
/// @dev 部署固定来源链/genesis/App；审批证书与取消证书采用不同的 EIP-712 类型和 action。
contract MilonWithdrawalVerifier is IERC1271, EIP712 {
    /// @notice 签名验证循环最多 64 个成员；等权门限必须严格大于 2N/3，且至少 4 个成员。
    uint256 public constant MAX_MEMBERS = 64;
    /// @notice 限制动态证书总字节数，避免无界解码或签名列表占用资源。
    uint256 public constant MAX_CERTIFICATE_BYTES = 12_288;
    uint8 public constant WITHDRAWAL_ACTION = 1;
    uint8 public constant CANCELLATION_ACTION = 2;
    /// @notice 本租户权限根，委员会安装与恢复由治理负责，Guardian 仅可暂停和撤销。
    TenantAuthority public immutable authority;
    /// @notice 固定桥实例标识，链下 movementId/订单关联使用它区分不同部署。
    bytes32 public immutable bridgeId;
    /// @notice 固定 Milon 来源身份；相同链 ID 不同 genesis 也视为不同来源。
    uint256 public immutable sourceChainId;
    bytes32 public immutable sourceGenesisHash;
    /// @notice 已治理确认的 Milon 提现业务 App 编号，不能接受任意 App 的投票结果。
    uint8 public immutable withdrawalAppId;
    /// @notice 当前批准的业务委员会及其版本；旧成员版本不能继续签发本合约可接受的证书。
    bytes32 public committeeId;
    uint64 public committeeEpoch;
    /// @notice EVM 桥授权撤销版本，与 Milon 共识 epoch 和 committeeEpoch 相互独立。
    uint64 public bridgeEpoch = 1;
    /// @notice 同一完整证书需要的不同成员签名数量，重复或乱序地址不计数而是直接拒绝。
    uint256 public threshold;
    bool public paused = true;
    address[] private _members;
    /// @notice 地址最后登记的委员会版本，免于遍历删除旧成员，版本不等即不是当前成员。
    mapping(address => uint64) public memberEpoch;

    error InvalidCommittee();
    error InvalidBridgeConfiguration();

    event CommitteeInstalled(
        bytes32 indexed committeeId,
        uint64 committeeEpoch,
        uint64 bridgeEpoch,
        uint256 threshold,
        address[] members
    );
    event BridgePaused(bool paused, uint64 bridgeEpoch);
    event BridgeRevoked(uint64 bridgeEpoch);

    /// @dev 固定桥实例、Milon 链 ID/genesis/App 身份与 EIP-712 域；缺少可信来源参数时拒绝部署。
    constructor(
        TenantAuthority tenantAuthority,
        bytes32 bridge,
        uint256 sourceChain,
        bytes32 genesis,
        uint8 app
    ) EIP712("MilonWithdrawalVerifier", "2") {
        if (bridge == bytes32(0) || sourceChain == 0 || genesis == bytes32(0) || app == 0) {
            revert InvalidBridgeConfiguration();
        }
        authority = tenantAuthority;
        bridgeId = bridge;
        sourceChainId = sourceChain;
        sourceGenesisHash = genesis;
        withdrawalAppId = app;
    }

    /// @notice 延时治理安装排序且不重复的等权成员集，拒绝较弱门限和平台在线角色混用。
    /// @dev 每次安装同时提升 committeeEpoch 与 bridgeEpoch，所有旧证书立即失效。
    function installCommittee(bytes32 id, address[] calldata newMembers, uint256 quorum, uint64 expectedEpoch)
        external
    {
        authority.checkGovernance(msg.sender);
        uint256 count = newMembers.length;
        if (
            id == bytes32(0) || expectedEpoch != committeeEpoch || count < 4 || count > MAX_MEMBERS
                || quorum <= (2 * count) / 3 || quorum > count
        ) revert InvalidCommittee();
        address previous;
        ++committeeEpoch;
        ++bridgeEpoch;
        delete _members;
        for (uint256 i; i < count; ++i) {
            address member = newMembers[i];
            if (
                member <= previous || member.code.length != 0 || authority.relayers(member)
                    || authority.operators(member) || authority.riskOperators(member)
                    || member == authority.guardian() || _isPlatformSigner(member)
            ) revert InvalidCommittee();
            memberEpoch[member] = committeeEpoch;
            _members.push(member);
            previous = member;
        }
        committeeId = id;
        threshold = quorum;
        emit CommitteeInstalled(id, committeeEpoch, bridgeEpoch, quorum, newMembers);
    }

    /// @notice 返回当前成员，供独立节点核对两链委员会配置并按地址排序提交签名。
    function members() external view returns (address[] memory) {
        return _members;
    }

    /// @notice Guardian 可立即暂停并提升桥版本；恢复不会复活历史签名。
    function pause() external {
        authority.checkGuardian(msg.sender);
        paused = true;
        ++bridgeEpoch;
        emit BridgePaused(true, bridgeEpoch);
    }

    /// @notice 治理解除/设置暂停，校验预期桥版本；没有有效委员会时不能开启验签。
    function setPaused(bool value, uint64 expectedEpoch) external {
        authority.checkGovernance(msg.sender);
        if (expectedEpoch != bridgeEpoch || (!value && threshold == 0)) revert InvalidBridgeConfiguration();
        paused = value;
        ++bridgeEpoch;
        emit BridgePaused(value, bridgeEpoch);
    }

    /// @notice 无需更换成员即可让所有旧证书失效，适用于在途授权应急撤销。
    function revoke() external {
        authority.checkGuardian(msg.sender);
        ++bridgeEpoch;
        emit BridgeRevoked(bridgeEpoch);
    }

    /// @notice 返回付款证书的 EIP-712 摘要，domain 绑定目标 EVM 链和本验签器地址。
    function hashAttestation(T.WithdrawalAttestation calldata attestation) external view returns (bytes32) {
        return _hashTypedDataV4(PermitHash.attestation(attestation));
    }

    /// @notice 返回取消证书的独立摘要，不能与付款证书互换。
    function hashCancellation(T.CancellationAttestation calldata attestation)
        external
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(PermitHash.cancellationAttestation(attestation));
    }

    /// @notice ERC1271 只读验签入口，成功返回标准 magic value，畸形材料返回无效值。
    /// @dev 不消费订单；订单必须由 HotVault 在实际付款事务内写入共享簿。
    function isValidSignature(bytes32 digest, bytes calldata certificate) external view returns (bytes4) {
        if (certificate.length > MAX_CERTIFICATE_BYTES || !authority.ready()) return bytes4(0xffffffff);
        // Malformed ABI and invalid ECDSA data return an invalid ERC1271 result.
        try this.verifyWithdrawal(digest, certificate) returns (bool valid) {
            return valid ? IERC1271.isValidSignature.selector : bytes4(0xffffffff);
        } catch {
            return bytes4(0xffffffff);
        }
    }

    /// @notice 解码并验证固定来源、用途、终局定位、版本和同一证书的门限签名。
    /// @dev 定位字段的链上真实性由委员会保证；非零字段本身不构成 Milon 轻客户端证明。
    function verifyWithdrawal(bytes32 digest, bytes calldata certificate) external view returns (bool) {
        if (paused || certificate.length > MAX_CERTIFICATE_BYTES) return false;
        (T.WithdrawalAttestation memory a, bytes[] memory signatures) =
            abi.decode(certificate, (T.WithdrawalAttestation, bytes[]));
        if (
            a.permitDigest != digest || a.sourceChainId != sourceChainId
                || a.sourceGenesisHash != sourceGenesisHash || a.withdrawalAppId != withdrawalAppId
                || a.committeeId != committeeId || a.committeeEpoch != committeeEpoch
                || a.bridgeEpoch != bridgeEpoch || a.action != WITHDRAWAL_ACTION || a.approvedHeight == 0
                || a.approvedBlockHash == bytes32(0) || a.approvedTxHash == bytes32(0)
        ) return false;
        return _verifySignatures(_hashTypedDataV4(PermitHash.attestation(a)), signatures);
    }

    /// @notice 对取消摘要验证独立类型证书；调用者负责业务订单和时间窗校验。
    function verifyCancellation(bytes32 digest, bytes calldata certificate) external view returns (bool) {
        if (paused || certificate.length > MAX_CERTIFICATE_BYTES) return false;
        (T.CancellationAttestation memory a, bytes[] memory signatures) =
            abi.decode(certificate, (T.CancellationAttestation, bytes[]));
        if (
            a.cancelDigest != digest || a.sourceChainId != sourceChainId
                || a.sourceGenesisHash != sourceGenesisHash || a.withdrawalAppId != withdrawalAppId
                || a.committeeId != committeeId || a.committeeEpoch != committeeEpoch
                || a.bridgeEpoch != bridgeEpoch || a.action != CANCELLATION_ACTION || a.approvedHeight == 0
                || a.approvedBlockHash == bytes32(0) || a.approvedTxHash == bytes32(0)
        ) return false;
        return _verifySignatures(_hashTypedDataV4(PermitHash.cancellationAttestation(a)), signatures);
    }

    /// @dev 验证每份签名的标准长度、low-s/v、当前成员身份及恢复地址严格递增，拒绝重复、乱序和非成员。达到门限仍需所有提交签名均合法。
    function _verifySignatures(bytes32 digest, bytes[] memory signatures) private view returns (bool) {
        if (threshold == 0 || signatures.length < threshold || signatures.length > _members.length) {
            return false;
        }
        address previous;
        for (uint256 i; i < signatures.length; ++i) {
            if (signatures[i].length != 65) return false;
            (address signer, ECDSA.RecoverError error,) = ECDSA.tryRecover(digest, signatures[i]);
            if (
                error != ECDSA.RecoverError.NoError || signer <= previous
                    || memberEpoch[signer] != committeeEpoch
            ) return false;
            previous = signer;
        }
        return true;
    }

    /// @dev 防止安装委员会时与平台退款、归集、调拨或独立 Council 签名地址共用身份。
    function _isPlatformSigner(address account) private view returns (bool) {
        (address refund,) = authority.signers(authority.REFUND_SIGNER());
        (address sweep,) = authority.signers(authority.SWEEP_SIGNER());
        (address transfer,) = authority.signers(authority.TRANSFER_SIGNER());
        (address council,) = authority.signers(authority.COUNCIL_SIGNER());
        return account == refund || account == sweep || account == transfer || account == council;
    }
}
