// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { TenantAuthority } from "../control/TenantAuthority.sol";
import { RiskRegistry } from "../control/RiskRegistry.sol";
import { WithdrawalBook } from "../bridge/WithdrawalBook.sol";
import { MilonWithdrawalVerifier } from "../bridge/MilonWithdrawalVerifier.sol";
import { IDepositFactory, IDepositVault, IHotVault, IHotPoolManager } from "../common/IWallet.sol";
import { WalletTypes as T } from "../common/WalletTypes.sol";
import { PermitHash } from "../common/PermitHash.sol";
import { WalletIds } from "../common/WalletIds.sol";
import { ExactTransfer } from "../common/ExactTransfer.sol";
import { OutflowBudget } from "../common/OutflowBudget.sol";

/// @title 租户热钱包：受控入金、Milon 审批付款与内部资产移动
/// @notice 所有热钱包共用同一 WithdrawalBook，付款先消费订单再转账，失败整体回滚。
/// @dev 通过不可升级的 EIP-1167 克隆部署；实现地址和租户组件永久绑定。没有任意 call 或 approve 入口。
contract HotVault is EIP712, ReentrancyGuard {
    using OutflowBudget for OutflowBudget.Budget;

    /// @notice 权限、风险、订单、验签和池配置均为本租户固定组件，不能由 Relayer 替换。
    TenantAuthority public immutable authority;
    RiskRegistry public immutable riskRegistry;
    WithdrawalBook public immutable withdrawalBook;
    MilonWithdrawalVerifier public immutable verifier;
    IHotPoolManager public immutable manager;

    /// @notice 池标识由管理器按租户、链、管理器地址与创建序号确定，只能初始化一次。
    bytes32 public poolId;
    /// @notice 每个币种的受控资金变更序号。内部调拨绑定该值，任何先执行的受控变更都会使旧调拨失效。
    mapping(address => uint256) public assetStateNonce;
    /// @dev 所有对外付款、转冷和热池调拨共用该币种的单笔、每日及滚动预算。
    mapping(address => OutflowBudget.Budget) private _budgets;
    /// @dev 实现合约构造时关闭初始化，克隆仅允许管理器在创建交易中初始化一次。
    bool private _initialized;
    /// @dev 仅在一次已授权调拨的同步回调期间存在；目标只能领取指定币种和金额一次。
    address private _movementTarget;
    address private _movementToken;
    uint256 private _movementAmount;

    error InvalidInitialization();
    error InvalidPermit();
    error OutflowUnavailable();
    error InvalidCertificate();
    error InvalidMovement();
    error InvalidFunding();

    event NativeReceived(address indexed sender, uint256 amount);
    event WithdrawalExecuted(
        bytes32 indexed requestId,
        bytes32 indexed userKey,
        address indexed token,
        address recipient,
        uint256 amount,
        bytes32 permitDigest,
        bytes32 certificateHash,
        uint256 assetStateNonce
    );
    event CustodyMovement(
        bytes32 indexed movementId,
        bytes32 indexed operationId,
        T.MovementKind kind,
        address source,
        address destination,
        address token,
        bytes32 assetKey,
        uint256 amount,
        uint256 assetStateNonce
    );

    /// @dev 固定绑定租户、风险、共享订单簿、桥验签器和池管理器，并关闭实现本体初始化；克隆只写入一次 poolId。
    constructor(
        TenantAuthority tenantAuthority,
        RiskRegistry risks,
        WithdrawalBook book,
        MilonWithdrawalVerifier bridgeVerifier,
        IHotPoolManager poolManager
    ) EIP712("HotVault", "2") {
        authority = tenantAuthority;
        riskRegistry = risks;
        withdrawalBook = book;
        verifier = bridgeVerifier;
        manager = poolManager;
        _initialized = true;
    }

    /// @notice 仅记录原生币到账；被动转入不能被视作新增用户权益。
    receive() external payable {
        emit NativeReceived(msg.sender, msg.value);
    }

    /// @notice 由管理器在 CREATE2 部署克隆的同一交易内设置池身份。
    function initialize(bytes32 id) external {
        if (
            _initialized || msg.sender != address(manager) || id == bytes32(0)
                || !manager.isHotVault(address(this))
        ) revert InvalidInitialization();
        _initialized = true;
        poolId = id;
    }

    /// @notice 返回后端与节点共同签署的完整 EIP-712 提现摘要，domain 绑定当前链及当前热钱包。
    function hashWithdrawal(T.WithdrawalPermit calldata p) external view returns (bytes32) {
        return _hashTypedDataV4(PermitHash.withdrawal(p));
    }

    /// @notice 返回内部调拨/转冷授权摘要；目标、用途、余额、nonce 与各配置版本均被签名绑定。
    function hashMovement(T.MovementPermit calldata p) external view returns (bytes32) {
        return _hashTypedDataV4(PermitHash.movement(p));
    }

    /// @notice 执行已归集权益的提现。Relayer 仅支付 Gas，不能自行批准放款。
    /// @param certificate abi.encode(WithdrawalAttestation, bytes[])，成员签名按恢复地址严格递增。
    /// @param councilAuthorization 达到 councilThreshold 时所需的独立 Council 对同一 Permit 的授权。
    /// @dev 检查链、租户、池、资产、风险、版本和预算后，原子消费共享订单并付款。
    ///      支付失败会回滚订单、预算和 nonce；后端须等此事件与共享状态终局才通知 Milon 结算。
    function executeWithdrawal(
        T.WithdrawalPermit calldata p,
        bytes calldata certificate,
        bytes calldata councilAuthorization
    ) external nonReentrant {
        authority.checkRelayer(msg.sender);
        authority.checkTime(p.validAfter, p.deadline);
        _checkWithdrawal(p);
        bytes32 digest = _hashTypedDataV4(PermitHash.withdrawal(p));
        if (verifier.isValidSignature(digest, certificate) != IERC1271.isValidSignature.selector) {
            revert InvalidCertificate();
        }
        T.OutflowPolicy memory policy = manager.outflowPolicy(p.token);
        _checkCouncil(digest, p.amount, policy, councilAuthorization);
        _consumeOutflow(p.token, p.amount, policy);
        bytes32 certificateHash = keccak256(certificate);
        bytes32 economicHash = keccak256(
            abi.encode(p.tenantKey, p.userKey, p.assetKey, p.token, p.to, p.amount, p.approvalDigest)
        );
        withdrawalBook.consume(p.requestId, economicHash, digest, certificateHash);
        uint256 nonce = assetStateNonce[p.token]++;
        ExactTransfer.send(p.token, p.to, p.amount);
        emit WithdrawalExecuted(
            p.requestId, p.userKey, p.token, p.to, p.amount, digest, certificateHash, nonce
        );
    }

    /// @notice 接收登记充值合约的归集；只有其当前已授权的同步回调可提供资产。
    /// @dev 先检查容量，再回调源合约付款，最后检查实际余额与上限，整个过程不使用 token approve。
    function acceptDeposit(address token, uint256 amount, bytes32 operationId) external nonReentrant {
        if (!authority.ready() || !IDepositFactory(authority.depositFactory()).isVault(msg.sender)) {
            revert InvalidFunding();
        }
        manager.checkIncoming(address(this), token, amount);
        uint256 beforeBalance = ExactTransfer.balance(token, address(this));
        IDepositVault(msg.sender).releaseSweep(token, amount);
        _finishIncoming(token, amount, beforeBalance, operationId, T.MovementKind.DepositSweep);
    }

    /// @notice 接收同租户另一个热钱包的调拨；此托管位置变化不能重复发行 Milon 权益。
    function acceptHotTransfer(address token, uint256 amount, bytes32 operationId) external nonReentrant {
        if (!manager.isHotVault(msg.sender) || msg.sender == address(this)) revert InvalidFunding();
        manager.checkIncoming(address(this), token, amount);
        uint256 beforeBalance = ExactTransfer.balance(token, address(this));
        IHotVault(msg.sender).releaseMovement(token, amount);
        _finishIncoming(token, amount, beforeBalance, operationId, T.MovementKind.HotTransfer);
    }

    /// @notice 将资产调拨到已登记的同租户健康热钱包。
    /// @dev 使用独立 TRANSFER_SIGNER；共享 movementId 防重复，目标仍强制执行按币种持仓上限。
    function moveToHot(
        T.MovementPermit calldata p,
        bytes calldata authorization,
        bytes calldata councilAuthorization
    ) external nonReentrant {
        if (
            p.requiredCapacity != 0 || p.coldAddressEpoch != 0 || !manager.isHotVault(p.destination)
                || p.destination == address(this)
        ) revert InvalidMovement();
        _authorizeMovement(p, authorization, councilAuthorization);
        _movementTarget = p.destination;
        _movementToken = p.token;
        _movementAmount = p.amount;
        IHotVault(p.destination).acceptHotTransfer(p.token, p.amount, p.operationId);
        if (_movementTarget != address(0)) revert InvalidMovement();
    }

    /// @notice 目标热钱包在 acceptHotTransfer 中领取本次已授权资金。
    /// @dev 故意不添加 nonReentrant：它是外层受锁方法的唯一受限回调；先清空暂存授权再转账。
    function releaseMovement(address token, uint256 amount) external {
        if (
            msg.sender != _movementTarget || token != _movementToken || amount != _movementAmount
                || amount == 0
        ) revert InvalidMovement();
        delete _movementTarget;
        delete _movementToken;
        delete _movementAmount;
        ExactTransfer.send(token, msg.sender, amount);
    }

    /// @notice 池数量已满且无健康池能接收指定金额时，将最旧可回收池的目标币种转至离线冷地址。
    /// @dev requiredCapacity 为待归集金额；只能释放链上计算的缺口。污染池、受限冷地址均不可参与。
    function sweepToCold(
        T.MovementPermit calldata p,
        bytes calldata authorization,
        bytes calldata councilAuthorization
    ) external nonReentrant {
        if (
            p.destination != manager.coldAddress() || p.coldAddressEpoch != manager.coldAddressEpoch()
                || p.requiredCapacity == 0 || manager.hotVaultCount() != manager.maxHotVaults()
                || manager.findCapacity(p.token, p.requiredCapacity) != address(0)
        ) revert InvalidMovement();
        (address oldest, uint256 needed) = manager.oldestRecyclable(p.token, p.requiredCapacity);
        if (oldest != address(this) || needed != p.amount) revert InvalidMovement();
        _authorizeMovement(p, authorization, councilAuthorization);
        ExactTransfer.send(p.token, p.destination, p.amount);
        _emitMovement(
            p.operationId, T.MovementKind.ColdSweep, address(this), p.destination, p.token, p.amount
        );
    }

    /// @notice 冷地址主动签交易补仓；私钥始终由线下冷钱包控制，合约只保存公开地址。
    /// @dev ERC20 由冷地址自行批准本热钱包拉取；原生币必须精确携带 amount。两种路径均检查容量和风险。
    function fundFromCold(address token, uint256 amount, bytes32 operationId) external payable nonReentrant {
        if (msg.sender != manager.coldAddress() || amount == 0 || !riskRegistry.healthy(msg.sender, token)) {
            revert InvalidFunding();
        }
        if (riskRegistry.state(riskRegistry.recipientScope(msg.sender)).restricted) revert InvalidFunding();
        if (token == address(0)) {
            if (msg.value != amount) revert InvalidFunding();
        } else {
            if (msg.value != 0) revert InvalidFunding();
            manager.checkIncoming(address(this), token, amount);
            ExactTransfer.pull(token, msg.sender, amount);
        }
        manager.checkFundedBalance(address(this), token);
        manager.consumeMovement(operationId);
        ++assetStateNonce[token];
        _emitMovement(operationId, T.MovementKind.ColdRefill, msg.sender, address(this), token, amount);
    }

    /// @notice 当前一次出金最多可使用的数量，扣除余额底线、风险预留以及单笔/累计预算。
    /// @dev 归零表示应继续排队；容量回收也调用此视图，避免选中无法安全转冷的池。
    function availableOutflow(address token) public view returns (uint256) {
        if (
            manager.mappingDigest() == bytes32(0) || authority.outflowsPaused()
                || !riskRegistry.healthy(address(this), token)
        ) return 0;
        T.OutflowPolicy memory policy = manager.outflowPolicy(token);
        if (!policy.withdrawalsEnabled && !policy.movementsEnabled) return 0;
        uint256 held = ExactTransfer.balance(token, address(this));
        uint256 reserved = riskRegistry.state(riskRegistry.assetScope(address(this), token)).reservedRaw;
        if (reserved >= held || policy.safetyFloor >= held - reserved) return 0;
        uint256 liquid = held - reserved - policy.safetyFloor;
        uint256 budget = _budgets[token].available(policy);
        return liquid < budget ? liquid : budget;
    }

    /// @notice 提供预算审计视图；滚动值包含最旧部分小时，因此比精确 24 小时窗口更保守。
    function spending(address token) external view returns (uint256 dailySpent, uint256 rollingSpent) {
        OutflowBudget.Budget storage budget = _budgets[token];
        dailySpent = budget.day == block.timestamp / 1 days ? budget.dailySpent : 0;
        rollingSpent = budget.rollingSpent();
    }

    /// @dev 付款参数与链上状态逐项比对；独立签名节点仍负责证明 Milon 审批和权益真实存在。
    function _checkWithdrawal(T.WithdrawalPermit calldata p) private view {
        T.AssetConfig memory asset = manager.assetConfig(p.token);
        T.OutflowPolicy memory policy = manager.outflowPolicy(p.token);
        if (
            !_initialized || !manager.isHotVault(address(this)) || p.tenantKey != authority.tenantKey()
                || p.poolId != poolId || p.requestId == bytes32(0) || p.userKey == bytes32(0)
                || p.to == address(0) || manager.isCustodyAddress(p.to) || p.amount == 0
                || p.approvalDigest == bytes32(0) || !asset.registered || p.assetKey != asset.assetKey
                || p.assetEpoch != asset.assetEpoch || p.mappingEpoch != manager.mappingEpoch()
                || p.policyEpoch != policy.policyEpoch || !policy.withdrawalsEnabled
                || p.authorityEpoch != authority.authorityEpoch()
                || p.signerEpoch != authority.withdrawalSignerEpoch()
        ) revert InvalidPermit();
        riskRegistry.check(riskRegistry.vaultScope(address(this)), p.poolEpoch);
        riskRegistry.check(riskRegistry.assetScope(address(this), p.token), p.poolAssetEpoch);
        riskRegistry.check(riskRegistry.userScope(p.userKey), p.userRiskEpoch);
        riskRegistry.check(riskRegistry.recipientScope(p.to), p.recipientRiskEpoch);
    }

    /// @dev 统一调拨验证和预算消费；调用方再执行热转热或转冷，任一失败均回滚所有效果。
    function _authorizeMovement(
        T.MovementPermit calldata p,
        bytes calldata authorization,
        bytes calldata councilAuthorization
    ) private {
        authority.checkRelayer(msg.sender);
        authority.checkTime(p.validAfter, p.deadline);
        T.AssetConfig memory asset = manager.assetConfig(p.token);
        T.OutflowPolicy memory policy = manager.outflowPolicy(p.token);
        if (
            p.tenantKey != authority.tenantKey() || p.operationId == bytes32(0) || p.destination == address(0)
                || p.assetKey != asset.assetKey || !asset.registered || p.assetEpoch != asset.assetEpoch
                || p.mappingEpoch != manager.mappingEpoch()
                || p.capVersion != manager.assetCap(p.token).capVersion || p.policyEpoch != policy.policyEpoch
                || !policy.movementsEnabled || p.authorityEpoch != authority.authorityEpoch()
                || p.assetStateNonce != assetStateNonce[p.token]
                || p.expectedBalance != ExactTransfer.balance(p.token, address(this))
        ) revert InvalidMovement();
        riskRegistry.check(riskRegistry.vaultScope(address(this)), p.sourceEpoch);
        riskRegistry.check(riskRegistry.assetScope(address(this), p.token), p.sourceAssetEpoch);
        riskRegistry.check(riskRegistry.vaultScope(p.destination), p.destinationEpoch);
        riskRegistry.check(riskRegistry.assetScope(p.destination, p.token), p.destinationAssetEpoch);
        riskRegistry.check(riskRegistry.recipientScope(p.destination), p.destinationRecipientEpoch);
        bytes32 digest = _hashTypedDataV4(PermitHash.movement(p));
        authority.verify(authority.TRANSFER_SIGNER(), p.transferSignerEpoch, digest, authorization);
        _checkCouncil(digest, p.amount, policy, councilAuthorization);
        _consumeOutflow(p.token, p.amount, policy);
        manager.consumeMovement(p.operationId);
        ++assetStateNonce[p.token];
    }

    /// @dev 大额门槛使用当前独立 Council 签名版本；门槛为零表示任何出金都需要这一附加批准。
    function _checkCouncil(
        bytes32 digest,
        uint256 amount,
        T.OutflowPolicy memory policy,
        bytes calldata authorization
    ) private view {
        if (amount >= policy.councilThreshold) {
            authority.verify(
                authority.COUNCIL_SIGNER(),
                authority.signerEpoch(authority.COUNCIL_SIGNER()),
                digest,
                authorization
            );
        }
    }

    /// @dev 同时核验物理流动性、风险预留、底线与共享累计预算，再在本事务中消费额度。
    function _consumeOutflow(address token, uint256 amount, T.OutflowPolicy memory policy) private {
        if (amount == 0 || amount > availableOutflow(token)) revert OutflowUnavailable();
        _budgets[token].consume(policy, amount);
    }

    /// @dev 同步回调结束后核验真实入账金额，并再次检查风险、上限；未知额外转账会使本次操作回滚。
    function _finishIncoming(
        address token,
        uint256 amount,
        uint256 beforeBalance,
        bytes32 operationId,
        T.MovementKind kind
    ) private {
        if (ExactTransfer.balance(token, address(this)) != beforeBalance + amount) revert InvalidFunding();
        manager.checkFundedBalance(address(this), token);
        ++assetStateNonce[token];
        _emitMovement(operationId, kind, msg.sender, address(this), token, amount);
    }

    /// @dev 记录内部移动类型和真实双方地址；后端不得用 HotTransfer/ColdSweep/ColdRefill 重复生成用户权益。
    function _emitMovement(
        bytes32 operationId,
        T.MovementKind kind,
        address source,
        address destination,
        address token,
        uint256 amount
    ) private {
        bytes32 movementId = WalletIds.movement(verifier.bridgeId(), authority.chainKey(), operationId);
        emit CustodyMovement(
            movementId,
            operationId,
            kind,
            source,
            destination,
            token,
            manager.assetConfig(token).assetKey,
            amount,
            assetStateNonce[token]
        );
    }
}
