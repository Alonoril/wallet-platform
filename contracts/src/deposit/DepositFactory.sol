// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { TenantAuthority } from "../control/TenantAuthority.sol";
import { RiskRegistry } from "../control/RiskRegistry.sol";
import { IHotPoolManager, ITenantBound } from "../common/IWallet.sol";
import { WalletTypes as T } from "../common/WalletTypes.sol";
import { PermitHash } from "../common/PermitHash.sol";
import { WalletIds } from "../common/WalletIds.sol";
import { ExactTransfer } from "../common/ExactTransfer.sol";
import { DepositVault } from "./DepositVault.sol";

/// @title 用户身份绑定与独立充值地址工厂
/// @notice CREATE2 地址按逻辑钱包逐代创建；地址轮换继承用户签名身份，历史归属永久保留。
/// @dev 平台不能单方面重置已绑定用户的签名地址。用户丢失签名能力时，本版本没有管理员绕过入口。
contract DepositFactory is EIP712, ReentrancyGuard {
    struct WalletRecord {
        bytes32 userKey;
        uint64 generation;
        address current;
    }

    TenantAuthority public immutable authority;
    RiskRegistry public immutable riskRegistry;
    IHotPoolManager public immutable manager;
    /// @notice 固定实现地址；克隆不可升级，新版本业务需要另行部署并保留旧地址审计。
    address public immutable implementation;
    uint64 public constant FACTORY_VERSION = 2;
    mapping(bytes32 => WalletRecord) public wallets;
    mapping(address => bool) public isVault;
    mapping(address => bytes32) public userOf;
    mapping(address => bytes32) public walletOf;
    /// @notice 同一 userKey 的全部钱包代际共享签名身份。epoch 递增使所有旧退款授权失效。
    mapping(bytes32 => address) public userSigner;
    mapping(bytes32 => uint64) public userSignerEpoch;

    error InvalidBinding();
    error InvalidRotation();
    error ResidualBalance(address token, uint256 amount);
    error InvalidRetirement();

    event WalletCreated(
        bytes32 indexed walletKey,
        bytes32 indexed userKey,
        address indexed vault,
        uint64 generation,
        address userSigner
    );
    event WalletRotated(
        bytes32 indexed walletKey,
        address indexed previousVault,
        address indexed newVault,
        uint64 generation,
        bytes32 reason
    );
    event UserSignerRotated(
        bytes32 indexed userKey, address oldSigner, address newSigner, uint64 userSignerEpoch
    );
    event VaultRetired(address indexed vault, bytes32 indexed reason, bool residualAcknowledged);

    /// @dev 校验风险与池管理器属于同一租户，部署 Factory 独占初始化权的充值实现。
    constructor(TenantAuthority tenantAuthority, RiskRegistry risks, IHotPoolManager poolManager)
        EIP712("DepositFactory", "2")
    {
        if (
            address(risks.authority()) != address(tenantAuthority)
                || ITenantBound(address(poolManager)).authority() != address(tenantAuthority)
        ) revert InvalidBinding();
        authority = tenantAuthority;
        riskRegistry = risks;
        manager = poolManager;
        implementation = address(new DepositVault(tenantAuthority, risks, poolManager));
    }

    /// @notice 用户首次绑定逻辑钱包时签署此摘要，防止绑定材料跨工厂或跨链复用。
    function hashBinding(T.WalletBinding calldata p) external view returns (bytes32) {
        return _hashTypedDataV4(PermitHash.walletBinding(p));
    }

    /// @notice 用户签名地址轮换采用独立消息类型，不能拿提现签名代替。
    function hashUserRotation(T.UserSignerRotation calldata p) external view returns (bytes32) {
        return _hashTypedDataV4(PermitHash.userRotation(p));
    }

    /// @notice 由平台登记人员提交用户确认的绑定材料，创建第一代充值地址。
    /// @dev 首次 userKey 绑定依赖平台身份认证；绑定后同一 userKey 不得通过另建钱包替换签名身份。
    function createWallet(T.WalletBinding calldata p, bytes calldata userAuthorization)
        external
        nonReentrant
        returns (address)
    {
        authority.checkOperator(msg.sender);
        authority.checkTime(p.validAfter, p.deadline);
        if (
            p.tenantKey != authority.tenantKey() || p.userKey == bytes32(0) || p.logicalWalletId == bytes32(0)
        ) revert InvalidBinding();
        _checkSigner(p.userSigner);
        if (
            userAuthorization.length > 8192
                || !SignatureChecker.isValidSignatureNow(
                    p.userSigner, _hashTypedDataV4(PermitHash.walletBinding(p)), userAuthorization
                )
        ) revert InvalidBinding();
        address existing = userSigner[p.userKey];
        if (existing != address(0) && existing != p.userSigner) revert InvalidBinding();
        if (existing == address(0)) {
            userSigner[p.userKey] = p.userSigner;
            userSignerEpoch[p.userKey] = 1;
        }
        bytes32 key = WalletIds.wallet(p.tenantKey, p.userKey, p.logicalWalletId);
        if (wallets[key].current != address(0)) return wallets[key].current;
        return _deploy(key, p.userKey, 1);
    }

    /// @notice 轮换被污染或需停用的充值地址。先关闭旧地址归集，新地址使用同一用户签名身份。
    /// @dev 轮换不自动退役旧地址，也不迁移余额；后端须完成两链映射发布后再发放新地址。
    function rotateWallet(bytes32 key, uint64 expectedGeneration, bytes32 reason)
        external
        nonReentrant
        returns (address next)
    {
        authority.checkOperator(msg.sender);
        WalletRecord memory current = wallets[key];
        if (current.current == address(0) || current.generation != expectedGeneration || reason == bytes32(0))
        {
            revert InvalidRotation();
        }
        DepositVault(payable(current.current)).restrictSweeps();
        next = _deploy(key, current.userKey, current.generation + 1);
        emit WalletRotated(key, current.current, next, current.generation + 1, reason);
    }

    /// @notice 只有原用户、平台共同批准，且新密钥证明持有权后，才允许修改用户签名地址。
    /// @dev epoch 是用户级别，影响该用户全部充值合约；无单方面管理员恢复/降级接口。
    function rotateUserSigner(
        T.UserSignerRotation calldata p,
        bytes calldata oldAuthorization,
        bytes calldata newAuthorization,
        bytes calldata platformAuthorization
    ) external nonReentrant {
        authority.checkTime(p.validAfter, p.deadline);
        if (
            p.tenantKey != authority.tenantKey() || p.oldSigner != userSigner[p.userKey]
                || p.oldSigner == address(0) || p.oldSigner == p.newSigner
                || p.userSignerEpoch != userSignerEpoch[p.userKey]
        ) revert InvalidRotation();
        _checkSigner(p.newSigner);
        (address platformSigner,) = authority.signers(authority.REFUND_SIGNER());
        if (p.oldSigner == platformSigner) revert InvalidRotation();
        bytes32 digest = _hashTypedDataV4(PermitHash.userRotation(p));
        if (
            oldAuthorization.length > 8192 || newAuthorization.length > 8192
                || !SignatureChecker.isValidSignatureNow(p.oldSigner, digest, oldAuthorization)
                || !SignatureChecker.isValidSignatureNow(p.newSigner, digest, newAuthorization)
        ) revert InvalidRotation();
        authority.verify(authority.REFUND_SIGNER(), p.refundSignerEpoch, digest, platformAuthorization);
        userSigner[p.userKey] = p.newSigner;
        ++userSignerEpoch[p.userKey];
        emit UserSignerRotated(p.userKey, p.oldSigner, p.newSigner, userSignerEpoch[p.userKey]);
    }

    /// @notice 正常退役只接受已经轮换且所有登记资产余额清零的旧地址。
    /// @dev 检查原生币及全部已登记 ERC20，不能只传入一份可遗漏币种的调用方列表。
    function retireVault(address vault, bytes32 reason) external nonReentrant {
        authority.checkOperator(msg.sender);
        _checkRetirable(vault, reason);
        if (vault.balance != 0) revert ResidualBalance(address(0), vault.balance);
        uint256 count = manager.assetCount();
        for (uint256 i; i < count; ++i) {
            address token = manager.assetAt(i);
            if (token == address(0)) continue;
            uint256 held = ExactTransfer.balance(token, vault);
            if (held != 0) revert ResidualBalance(token, held);
        }
        DepositVault(payable(vault)).retire(reason);
        emit VaultRetired(vault, reason, false);
    }

    /// @notice 已知冻结/残留资产无法清零时，由延时治理明确确认后退役。
    /// @dev 这是高权限处置边界，会终止旧地址自提；必须先保留案件证据，不能作为常规提现入口。
    function retireWithResidual(address vault, bytes32 reason) external nonReentrant {
        authority.checkGovernance(msg.sender);
        _checkRetirable(vault, reason);
        DepositVault(payable(vault)).retire(reason);
        emit VaultRetired(vault, reason, true);
    }

    /// @notice 预测某逻辑钱包的指定代地址，包含链、租户与工厂协议版本。
    function predictVault(bytes32 key, uint64 generation) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _salt(key, generation), address(this));
    }

    /// @dev 先登记归属再初始化克隆，所有代地址历史保留；不跨代转移资金或修改用户签名身份。
    function _deploy(bytes32 key, bytes32 user, uint64 generation) private returns (address vault) {
        vault = Clones.cloneDeterministic(implementation, _salt(key, generation));
        isVault[vault] = true;
        userOf[vault] = user;
        walletOf[vault] = key;
        wallets[key] = WalletRecord(user, generation, vault);
        DepositVault(payable(vault)).initialize(key, user, generation);
        emit WalletCreated(key, user, vault, generation, userSigner[user]);
    }

    /// @dev CREATE2 salt 明确绑定租户、链实例、Factory 版本、逻辑钱包与 generation。
    function _salt(bytes32 key, uint64 generation) private view returns (bytes32) {
        return keccak256(
            abi.encode(authority.tenantKey(), authority.chainKey(), FACTORY_VERSION, key, generation)
        );
    }

    /// @dev 用户签名地址不能为空、平台退款签名者或已登记在线操作账户。
    function _checkSigner(address signer) private view {
        (address platformSigner,) = authority.signers(authority.REFUND_SIGNER());
        if (
            signer == address(0) || signer == platformSigner || authority.relayers(signer)
                || authority.operators(signer)
        ) revert InvalidBinding();
    }

    /// @dev 只允许已轮换的历史地址进入退役，不能把当前用户发放地址直接废弃。
    function _checkRetirable(address vault, bytes32 reason) private view {
        if (
            !isVault[vault] || reason == bytes32(0) || wallets[walletOf[vault]].current == vault
                || DepositVault(payable(vault)).retired()
        ) revert InvalidRetirement();
    }
}
