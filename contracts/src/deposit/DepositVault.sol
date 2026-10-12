// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { TenantAuthority } from "../control/TenantAuthority.sol";
import { RiskRegistry } from "../control/RiskRegistry.sol";
import { MilonWithdrawalVerifier } from "../bridge/MilonWithdrawalVerifier.sol";
import { IDepositFactory, IHotVault, IHotPoolManager } from "../common/IWallet.sol";
import { WalletTypes as T } from "../common/WalletTypes.sol";
import { PermitHash } from "../common/PermitHash.sol";
import { WalletIds } from "../common/WalletIds.sol";
import { ExactTransfer } from "../common/ExactTransfer.sol";

/// @title 用户独立充值合约：双签自提、观察期归集与退役处置
/// @notice ACTIVE 状态的未归集余额可凭用户和平台双签提至指定外部地址，内部风控标黑不封锁此路径。
/// @dev 原始到账与来源分配由链下核验；合约不把实际余额等同于已生成的 Milon 权益。
contract DepositVault is EIP712, ReentrancyGuard {
    uint256 public constant MAX_ALLOCATIONS = 32;
    TenantAuthority public immutable authority;
    RiskRegistry public immutable riskRegistry;
    IHotPoolManager public immutable manager;
    /// @notice 部署实现合约的唯一 Factory；所有克隆共享此不可变地址，防止抢先初始化。
    address public immutable factory;
    /// @notice 当前克隆所属逻辑钱包，初始化后没有修改入口。
    bytes32 public walletKey;
    /// @notice 当前克隆的固定用户标识，用户签名地址只能通过 Factory 的双签身份轮换变更。
    bytes32 public userKey;
    /// @notice 该逻辑钱包的地址代际，仅用于路线与历史审计，不参与热池订单去重。
    uint64 public generation;
    /// @notice 永久退役标记。生效后禁止用户提现和归集，仍可能被动收到原生币/ERC20。
    bool public retired;
    /// @notice 地址轮换后永久关闭旧地址归集，旧地址在正式退役前仍允许双签自提。
    bool public sweepsDisabled;
    bool private _initialized;
    /// @notice 同一资产自提和归集共同消费此序号，先成功者使另一份旧授权失效。
    mapping(address => uint256) public assetStateNonce;
    /// @dev 已授权归集的同步回调上下文；任何其他调用不能从本合约拉取资产。
    address private _sweepTarget;
    address private _sweepToken;
    uint256 private _sweepAmount;

    error InvalidInitialization();
    error VaultRetired();
    error InvalidRefund();
    error InvalidUserSignature();
    error InvalidSweep();
    error ObservationIncomplete();
    error InvalidDisposition();

    event NativeDeposited(address indexed sender, bytes32 indexed walletKey, uint256 amount, bool retired);
    event UncollectedWithdrawn(
        bytes32 indexed refundId,
        bytes32 indexed walletKey,
        address indexed token,
        uint256 amount,
        address recipient,
        uint256 assetStateNonce,
        bytes32 permitDigest
    );
    event SweepExecuted(
        bytes32 indexed movementId,
        bytes32 indexed operationId,
        address indexed hotVault,
        bytes32 walletKey,
        address token,
        uint256 amount,
        uint256 assetStateNonce,
        bytes32 allocationsHash
    );
    event SweepSourceAllocated(bytes32 indexed operationId, bytes32 indexed depositId, uint256 amount);
    event SweepsDisabled();
    event VaultRetiredEvent(bytes32 indexed reason);
    event RetiredFundsDisposed(
        bytes32 indexed operationId,
        bytes32 indexed caseId,
        address indexed token,
        address receiver,
        uint256 amount
    );

    /// @dev 固定组件与 Factory 初始化权限，关闭实现本体初始化；EIP-712 在克隆上重算当前地址 domain。
    constructor(TenantAuthority tenantAuthority, RiskRegistry risks, IHotPoolManager poolManager)
        EIP712("DepositVault", "2")
    {
        authority = tenantAuthority;
        riskRegistry = risks;
        manager = poolManager;
        factory = msg.sender;
        _initialized = true;
    }

    /// @notice 原生币到账产生标准事件；退役地址仍可被动收款，但后端不能据此业务入账。
    receive() external payable {
        emit NativeDeposited(msg.sender, walletKey, msg.value, retired);
    }

    /// @notice Factory 在创建克隆的同一交易中写入不可变业务身份。
    function initialize(bytes32 wallet, bytes32 user, uint64 version) external {
        if (
            _initialized || msg.sender != factory || wallet == bytes32(0) || user == bytes32(0)
                || version == 0
        ) revert InvalidInitialization();
        _initialized = true;
        walletKey = wallet;
        userKey = user;
        generation = version;
    }

    /// @notice 用户和平台必须分别签署此完全相同的摘要；禁止 personal_sign 或裸业务 JSON 替代编码。
    function hashRefund(T.RefundPermit calldata p) external view returns (bytes32) {
        return _hashTypedDataV4(PermitHash.refund(p));
    }

    /// @notice 归集签名覆盖来源分配摘要、观察时间、目标池、nonce、余额及全部有效版本。
    function hashSweep(T.SweepPermit calldata p) external view returns (bytes32) {
        return _hashTypedDataV4(PermitHash.sweep(p));
    }

    /// @notice 为后端返回排序后来源分配的规范摘要。
    function hashAllocations(T.SourceAllocation[] calldata entries) external pure returns (bytes32) {
        return PermitHash.allocations(entries);
    }

    /// @notice 用户本人确认提现参数，平台认证归属后共同授权，任意 Gas 中继者均可提交该双签。
    /// @dev 不检查观察期、用户黑名单或热池暂停；只处理当前充值合约实际未归集资产。
    ///      钱包归属取 Factory，不能由 calldata 指定签名人；平台不能用自己一份签名同时满足两个身份。
    ///      先消费 nonce 后转账，失败全部回滚。事件只更新未归集余额，不生成 Milon 提现预留或权益。
    function withdraw(
        T.RefundPermit calldata p,
        bytes calldata userAuthorization,
        bytes calldata platformAuthorization
    ) external nonReentrant {
        _requireActive();
        authority.checkTime(p.validAfter, p.deadline);
        T.AssetConfig memory asset = manager.assetConfig(p.token);
        IDepositFactory registry = IDepositFactory(factory);
        if (
            p.tenantKey != authority.tenantKey() || p.userKey != userKey || p.walletKey != walletKey
                || !asset.registered || p.assetKey != asset.assetKey || p.amount == 0 || p.recipient == address(0)
                || manager.isCustodyAddress(p.recipient) || p.assetStateNonce != assetStateNonce[p.token]
                || p.userSignerEpoch != registry.userSignerEpoch(userKey)
                || p.amount > ExactTransfer.balance(p.token, address(this))
        ) revert InvalidRefund();
        bytes32 digest = _hashTypedDataV4(PermitHash.refund(p));
        address signer = registry.userSigner(userKey);
        (address platformSigner,) = authority.signers(authority.REFUND_SIGNER());
        if (
            signer == address(0) || signer == platformSigner || userAuthorization.length > 8192
                || !SignatureChecker.isValidSignatureNow(signer, digest, userAuthorization)
        ) revert InvalidUserSignature();
        authority.verify(authority.REFUND_SIGNER(), p.refundSignerEpoch, digest, platformAuthorization);
        ++assetStateNonce[p.token];
        ExactTransfer.send(p.token, p.recipient, p.amount);
        bytes32 refundId =
            WalletIds.refund(authority.chainKey(), address(this), p.assetKey, p.assetStateNonce);
        emit UncollectedWithdrawn(
            refundId, walletKey, p.token, p.amount, p.recipient, p.assetStateNonce, digest
        );
    }

    /// @notice 将审核通过且观察期结束的净剩余来源归集到本租户健康热钱包。
    /// @dev SWEEP_SIGNER 证明链下来源与分配正确，合约强制观察时间、各风险版本、余额和容量。
    ///      EVM 无法自行读取任意历史 ERC20 receipt，Milon 入账委员会还须独立验证来源及净归集。
    function sweep(
        T.SweepPermit calldata p,
        T.SourceAllocation[] calldata allocations,
        bytes calldata authorization
    ) external nonReentrant {
        _requireActive();
        authority.checkRelayer(msg.sender);
        authority.checkTime(p.validAfter, p.deadline);
        _checkSweep(p);
        if (
            allocations.length == 0 || allocations.length > MAX_ALLOCATIONS
                || p.allocationsHash != PermitHash.allocations(allocations)
        ) revert InvalidSweep();
        authority.verify(
            authority.SWEEP_SIGNER(), p.sweepSignerEpoch, _hashTypedDataV4(PermitHash.sweep(p)), authorization
        );
        _checkAllocations(p, allocations);
        manager.consumeMovement(p.operationId);
        ++assetStateNonce[p.token];
        _sweepTarget = p.hotVault;
        _sweepToken = p.token;
        _sweepAmount = p.amount;
        IHotVault(p.hotVault).acceptDeposit(p.token, p.amount, p.operationId);
        if (_sweepTarget != address(0)) revert InvalidSweep();
        bytes32 bridge = MilonWithdrawalVerifier(authority.withdrawalVerifier()).bridgeId();
        bytes32 movementId = WalletIds.movement(bridge, authority.chainKey(), p.operationId);
        emit SweepExecuted(
            movementId,
            p.operationId,
            p.hotVault,
            walletKey,
            p.token,
            p.amount,
            p.assetStateNonce,
            p.allocationsHash
        );
    }

    /// @notice 仅允许本次签名指定的热钱包领取预设金额；不提供通用授权或任意目标转账。
    /// @dev 这是外层 sweep 重入锁内的单次回调，先清空上下文再付款，二次调用必然失败。
    function releaseSweep(address token, uint256 amount) external {
        if (msg.sender != _sweepTarget || token != _sweepToken || amount != _sweepAmount || amount == 0) {
            revert InvalidSweep();
        }
        delete _sweepTarget;
        delete _sweepToken;
        delete _sweepAmount;
        ExactTransfer.send(token, msg.sender, amount);
    }

    /// @notice 地址轮换时 Factory 永久关闭旧代归集；不会取消该用户的双签自提权。
    function restrictSweeps() external nonReentrant {
        if (msg.sender != factory) revert InvalidSweep();
        sweepsDisabled = true;
        emit SweepsDisabled();
    }

    /// @notice Factory 完成余额检查或延时治理确认残留资产后，使旧地址永久退出正常业务。
    function retire(bytes32 reason) external nonReentrant {
        if (msg.sender != factory || retired || reason == bytes32(0)) revert InvalidDisposition();
        retired = true;
        sweepsDisabled = true;
        emit VaultRetiredEvent(reason);
    }

    /// @notice 退役后异常到账只能经延时治理移至专用处置地址，不能恢复为用户自提或正常归集。
    /// @dev 处置地址不得是当前内部托管地址；记录案件号，后端只做异常审计，不能产生 CreditDeposit。
    function disposeRetired(address token, uint256 amount, bytes32 operationId, bytes32 caseId)
        external
        nonReentrant
    {
        authority.checkGovernance(msg.sender);
        address receiver = authority.dispositionReceiver();
        if (!retired || receiver == address(0) || manager.isCustodyAddress(receiver) || caseId == bytes32(0))
        {
            revert InvalidDisposition();
        }
        manager.consumeMovement(operationId);
        ++assetStateNonce[token];
        ExactTransfer.send(token, receiver, amount);
        emit RetiredFundsDisposed(operationId, caseId, token, receiver, amount);
    }

    /// @dev 同时检查生命周期、组件就绪和 Factory 登记；未初始化克隆或实现本体都不能操作资产。
    function _requireActive() private view {
        if (retired) revert VaultRetired();
        if (!_initialized || !authority.ready() || !IDepositFactory(factory).isVault(address(this))) {
            revert InvalidInitialization();
        }
    }

    /// @dev 用户风险限制只约束归集；所有参与地址与资产都必须保持签名时的风险版本。
    function _checkSweep(T.SweepPermit calldata p) private view {
        T.AssetConfig memory asset = manager.assetConfig(p.token);
        if (
            sweepsDisabled || authority.sweepsPaused() || p.tenantKey != authority.tenantKey()
                || p.walletKey != walletKey || !asset.registered || p.assetKey != asset.assetKey
                || p.assetEpoch != asset.assetEpoch || p.amount == 0 || p.mappingEpoch != manager.mappingEpoch()
                || p.capVersion != manager.assetCap(p.token).capVersion
                || p.policyEpoch != manager.outflowPolicy(p.token).policyEpoch
                || p.authorityEpoch != authority.authorityEpoch() || !manager.isHotVault(p.hotVault)
                || p.assetStateNonce != assetStateNonce[p.token]
                || p.expectedBalance != ExactTransfer.balance(p.token, address(this))
                || p.amount > p.expectedBalance
        ) revert InvalidSweep();
        riskRegistry.check(riskRegistry.vaultScope(address(this)), p.vaultEpoch);
        riskRegistry.check(riskRegistry.assetScope(address(this), p.token), p.vaultAssetEpoch);
        riskRegistry.check(riskRegistry.userScope(userKey), p.userRiskEpoch);
        riskRegistry.check(riskRegistry.vaultScope(p.hotVault), p.hotEpoch);
        riskRegistry.check(riskRegistry.assetScope(p.hotVault, p.token), p.hotAssetEpoch);
        uint256 reserved = riskRegistry.state(riskRegistry.assetScope(address(this), p.token)).reservedRaw;
        if (reserved > p.expectedBalance || p.amount > p.expectedBalance - reserved) revert InvalidSweep();
    }

    /// @dev 来源严格按 depositId 递增，防止同一调用重复分配；每条都独立检查观察期和风险。
    function _checkAllocations(T.SweepPermit calldata p, T.SourceAllocation[] calldata allocations) private {
        uint256 total;
        bytes32 previous;
        for (uint256 i; i < allocations.length; ++i) {
            T.SourceAllocation calldata source = allocations[i];
            if (source.depositId <= previous || source.amount == 0) revert InvalidSweep();
            if (
                source.observedAt == 0
                    || uint256(source.observedAt) + authority.observationWindow() > block.timestamp
            ) revert ObservationIncomplete();
            riskRegistry.check(riskRegistry.sourceScope(source.depositId), source.sourceRiskEpoch);
            total += source.amount;
            previous = source.depositId;
            emit SweepSourceAllocated(p.operationId, source.depositId, source.amount);
        }
        if (total != p.amount) revert InvalidSweep();
    }
}
