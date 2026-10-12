// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { TenantAuthority } from "../control/TenantAuthority.sol";
import { RiskRegistry } from "../control/RiskRegistry.sol";
import { MilonWithdrawalVerifier } from "../bridge/MilonWithdrawalVerifier.sol";
import { WithdrawalBook } from "../bridge/WithdrawalBook.sol";
import { IDepositFactory, IHotVault, IHotPoolManager } from "../common/IWallet.sol";
import { WalletTypes as T } from "../common/WalletTypes.sol";
import { WalletIds } from "../common/WalletIds.sol";
import { ExactTransfer } from "../common/ExactTransfer.sol";
import { HotVault } from "./HotVault.sol";

/// @title 动态热钱包池与按币种托管配置
/// @notice 单租户单链最多 20 或 50 个不可升级 HotVault；持仓上限逐币种应用于每个池。
/// @dev 外部直接转账无法阻断，因此始终读取实际余额；超额时停止新增受控入金，不自动搬走未知资产。
contract HotPoolManager {
    /// @notice 限制可枚举资产数，确保退役检查与管理查询成本有界。
    uint256 public constant MAX_ASSETS = 64;
    /// @notice 固定租户组件与实现地址，所有克隆使用同一个共享订单簿和跨链验签器。
    TenantAuthority public immutable authority;
    RiskRegistry public immutable riskRegistry;
    WithdrawalBook public immutable withdrawalBook;
    MilonWithdrawalVerifier public immutable verifier;
    address public immutable implementation;
    /// @notice 允许的热池总数，只能治理在 20/50 之间调整，不能小于已经创建的数量。
    uint256 public maxHotVaults;
    /// @notice 两链映射发布的链上版本与摘要；后端仍必须核验 Milon 对应配置已终局。
    uint64 public mappingEpoch = 1;
    bytes32 public mappingDigest;
    /// @notice 当前离线冷钱包公开地址及版本；合约和配置不保存其私钥。
    address public coldAddress;
    uint64 public coldAddressEpoch;
    /// @dev 按创建先后永久排序，容量回收按此顺序选择最旧的合格健康池。
    address[] private _vaults;
    /// @dev 已登记币种列表，原生币用 address(0)，ERC20 使用固定合约地址。
    address[] private _assets;
    mapping(address => bool) public isHotVault;
    /// @notice 历史冷地址永久保留内部托管身份，换冷地址不能把历史内部资产移动伪装成用户付款。
    mapping(address => bool) public isColdAddress;
    mapping(address => uint64) public sequenceOf;
    mapping(address => uint48) public createdAt;
    /// @notice 固定资产键和显示精度，assetEpoch 用于重新审核资产语义后废止旧授权。
    mapping(address => T.AssetConfig) private _assetConfigs;
    /// @notice 每币种持仓上限及乐观并发版本；配置缺失、禁用或上限为零都拒绝新增受控入金。
    mapping(address => T.AssetCap) private _caps;
    /// @notice 单笔/累计出金限额、底线与 Council 门槛，与持仓上限分别配置。
    mapping(address => T.OutflowPolicy) private _policies;
    /// @notice 全租户 movement 操作去重；失败交易回滚消费，不依赖后端 txHash 去重。
    mapping(bytes32 => bool) public movementConsumed;

    error InvalidConfiguration();
    error InvalidVersion();
    error PoolLimitReached();
    error IncomingNotAllowed();
    error CapacityExceeded();
    error MovementAlreadyConsumed();

    event HotVaultCreated(address indexed vault, bytes32 indexed poolId, uint64 sequence, uint48 createdAt);
    event AssetRegistered(address indexed token, bytes32 indexed assetKey, uint8 decimals, uint64 assetEpoch);
    event AssetEpochUpdated(address indexed token, uint64 assetEpoch, bytes32 reason);
    event AssetCapUpdated(address indexed token, uint256 maxBalanceRaw, bool enabled, uint64 capVersion);
    event OutflowPolicyUpdated(address indexed token, T.OutflowPolicy policy);
    event MappingUpdated(uint64 mappingEpoch, bytes32 mappingDigest);
    event ColdAddressUpdated(address indexed coldAddress, uint64 coldAddressEpoch);
    event PoolLimitUpdated(uint256 maxHotVaults);
    event MovementConsumed(bytes32 indexed operationId, address indexed initiator);

    /// @dev 校验池上限必须为 20/50，全部组件指向同一租户与验证器，再部署不可升级热钱包实现。
    constructor(
        TenantAuthority tenantAuthority,
        RiskRegistry risks,
        WithdrawalBook book,
        MilonWithdrawalVerifier bridgeVerifier,
        uint256 maximum
    ) {
        if (
            (maximum != 20 && maximum != 50) || address(risks.authority()) != address(tenantAuthority)
                || address(book.authority()) != address(tenantAuthority)
                || address(bridgeVerifier.authority()) != address(tenantAuthority)
                || address(book.verifier()) != address(bridgeVerifier)
        ) revert InvalidConfiguration();
        authority = tenantAuthority;
        riskRegistry = risks;
        withdrawalBook = book;
        verifier = bridgeVerifier;
        maxHotVaults = maximum;
        implementation = address(
            new HotVault(tenantAuthority, risks, book, bridgeVerifier, IHotPoolManager(address(this)))
        );
    }

    /// @notice 中继在池不足时按确定序号创建新池；上限达到后只能回收容量或排队。
    function createHotVault() external returns (address vault) {
        authority.checkRelayer(msg.sender);
        if (_vaults.length >= maxHotVaults) revert PoolLimitReached();
        uint64 sequence = uint64(_vaults.length + 1);
        bytes32 poolId = keccak256(
            abi.encode(
                keccak256("HOT_POOL_V2"), authority.tenantKey(), authority.chainKey(), address(this), sequence
            )
        );
        vault = Clones.cloneDeterministic(implementation, poolId);
        isHotVault[vault] = true;
        sequenceOf[vault] = sequence;
        createdAt[vault] = uint48(block.timestamp);
        _vaults.push(vault);
        IHotVault(vault).initialize(poolId);
        emit HotVaultCreated(vault, poolId, sequence, uint48(block.timestamp));
    }

    /// @notice 预测指定序号的 CREATE2 热池地址，身份同时绑定租户、链和管理器。
    function predictHotVault(uint64 sequence) external view returns (address) {
        bytes32 poolId = keccak256(
            abi.encode(
                keccak256("HOT_POOL_V2"), authority.tenantKey(), authority.chainKey(), address(this), sequence
            )
        );
        return Clones.predictDeterministicAddress(implementation, poolId, address(this));
    }

    /// @notice 治理调整池数量上限；不删除已有池或重置历史订单。
    function setMaxHotVaults(uint256 maximum) external {
        authority.checkGovernance(msg.sender);
        if ((maximum != 20 && maximum != 50) || maximum < _vaults.length) revert InvalidConfiguration();
        maxHotVaults = maximum;
        emit PoolLimitUpdated(maximum);
    }

    /// @notice 治理登记支持的资产与精度，资产身份永久由链实例、种类及 token 地址派生。
    /// @dev 注册不自动启用入金/付款。扣税、rebase 等非精确转账语义不属于支持范围。
    function registerAsset(address token, uint8 decimals) external {
        authority.checkGovernance(msg.sender);
        if (
            _assetConfigs[token].registered || _assets.length >= MAX_ASSETS
                || (token != address(0) && token.code.length == 0) || (token == address(0) && decimals != 18)
        ) revert InvalidConfiguration();
        bytes32 key = WalletIds.asset(authority.chainKey(), token);
        _assetConfigs[token] = T.AssetConfig(key, 1, decimals, true);
        _assets.push(token);
        emit AssetRegistered(token, key, decimals, 1);
    }

    /// @notice 资产重新审核后递增版本，并记录原因；旧归集、调拨及热池付款材料须重签。
    function refreshAssetEpoch(address token, uint64 expectedEpoch, bytes32 reason) external {
        authority.checkGovernance(msg.sender);
        T.AssetConfig storage asset = _assetConfigs[token];
        if (!asset.registered || asset.assetEpoch != expectedEpoch || reason == bytes32(0)) {
            revert InvalidVersion();
        }
        ++asset.assetEpoch;
        emit AssetEpochUpdated(token, asset.assetEpoch, reason);
    }

    /// @notice 管理 API 最终执行的链上入口，校验 expectedCapVersion 防止并发覆盖。
    /// @dev 金额为 uint256 原始最小单位；允许下调至已有余额以下，但不会强制转账或改变用户权益。
    function setAssetCap(address token, uint256 maximum, bool enabled, uint64 expectedCapVersion) external {
        authority.checkGovernance(msg.sender);
        T.AssetCap storage cap = _caps[token];
        if (!_assetConfigs[token].registered || cap.capVersion != expectedCapVersion) revert InvalidVersion();
        cap.maxBalanceRaw = maximum;
        cap.enabled = enabled;
        ++cap.capVersion;
        emit AssetCapUpdated(token, maximum, enabled, cap.capVersion);
    }

    /// @notice 治理修改出金预算并递增策略版本；未花完预算不因改配置而清空。
    function setOutflowPolicy(address token, T.OutflowPolicy calldata next, uint64 expectedPolicyEpoch)
        external
    {
        authority.checkGovernance(msg.sender);
        if (!_assetConfigs[token].registered || _policies[token].policyEpoch != expectedPolicyEpoch) {
            revert InvalidVersion();
        }
        _policies[token] = next;
        _policies[token].policyEpoch = expectedPolicyEpoch + 1;
        emit OutflowPolicyUpdated(token, _policies[token]);
    }

    /// @notice 治理发布两链映射摘要并递增版本；第一份映射发布前受控热池业务保持关闭。
    function publishMapping(bytes32 digest, uint64 expectedEpoch) external {
        authority.checkGovernance(msg.sender);
        if (digest == bytes32(0) || mappingEpoch != expectedEpoch) revert InvalidVersion();
        mappingDigest = digest;
        ++mappingEpoch;
        emit MappingUpdated(mappingEpoch, digest);
    }

    /// @notice 延时治理修改冷钱包公开地址，递增版本使旧转冷签名失效。
    function setColdAddress(address cold, uint64 expectedEpoch) external {
        authority.checkGovernance(msg.sender);
        if (
            cold == address(0) || cold.code.length != 0 || isHotVault[cold]
                || (authority.ready() && IDepositFactory(authority.depositFactory()).isVault(cold))
                || coldAddressEpoch != expectedEpoch
        ) revert InvalidConfiguration();
        coldAddress = cold;
        isColdAddress[cold] = true;
        ++coldAddressEpoch;
        emit ColdAddressUpdated(cold, coldAddressEpoch);
    }

    /// @notice 判断已知托管地址，防止把内部移动伪装成外部用户付款。
    function isCustodyAddress(address account) public view returns (bool) {
        return isHotVault[account] || isColdAddress[account]
            || (authority.ready() && IDepositFactory(authority.depositFactory()).isVault(account));
    }

    /// @notice 查询资产注册信息，供签名服务及后端 assetKey 映射使用。
    function assetConfig(address token) external view returns (T.AssetConfig memory) {
        return _assetConfigs[token];
    }
    /// @notice 管理 GET API 读取的权威上限；后端必须等链终局后更新 Effective 投影。

    function assetCap(address token) external view returns (T.AssetCap memory) {
        return _caps[token];
    }
    /// @notice 查询当前资产出金策略；所有数量与金额比较均使用同一资产的最小单位。

    function outflowPolicy(address token) external view returns (T.OutflowPolicy memory) {
        return _policies[token];
    }
    /// @notice 当前已创建池数量，不将风险池删除来绕过总数上限。

    function hotVaultCount() external view returns (uint256) {
        return _vaults.length;
    }
    /// @notice 按创建顺序枚举所有热钱包，包括已被限制的池。

    function hotVaultAt(uint256 index) external view returns (address) {
        return _vaults[index];
    }
    /// @notice 已登记资产数量，用于有界枚举与正常退役余额检查。

    function assetCount() external view returns (uint256) {
        return _assets.length;
    }
    /// @notice 按注册顺序读取某个资产地址。

    function assetAt(uint256 index) external view returns (address) {
        return _assets[index];
    }

    /// @notice 转账前断言目标健康、路由启用且实际余额加本次转入不超过当前币种上限。
    function checkIncoming(address target, address token, uint256 amount) external view {
        if (
            mappingDigest == bytes32(0) || authority.sweepsPaused() || !isHotVault[target]
                || !_assetConfigs[token].registered || !riskRegistry.healthy(target, token)
                || !_caps[token].enabled || _caps[token].maxBalanceRaw == 0 || amount == 0
        ) revert IncomingNotAllowed();
        if (amount > capacityOf(target, token)) revert CapacityExceeded();
    }

    /// @notice 验证已到账后的最终持仓；原生币补仓的 msg.value 在进入函数时已经计入余额。
    /// @dev 同时检查风险与路由暂停，防止转账回调期间配置变化后仍接受受控入金。
    function checkFundedBalance(address target, address token) external view {
        if (
            mappingDigest == bytes32(0) || authority.sweepsPaused() || !isHotVault[target]
                || !_assetConfigs[token].registered || !riskRegistry.healthy(target, token)
                || !_caps[token].enabled || _caps[token].maxBalanceRaw == 0
        ) revert IncomingNotAllowed();
        if (ExactTransfer.balance(token, target) > _caps[token].maxBalanceRaw) revert CapacityExceeded();
    }

    /// @notice 返回单池指定币种的实时可用容量；污染、暂停或超额时返回零。
    function capacityOf(address vault, address token) public view returns (uint256) {
        T.AssetCap memory cap = _caps[token];
        if (
            mappingDigest == bytes32(0) || authority.sweepsPaused() || !isHotVault[vault] || !cap.enabled
                || !riskRegistry.healthy(vault, token)
        ) return 0;
        uint256 held = ExactTransfer.balance(token, vault);
        return held < cap.maxBalanceRaw ? cap.maxBalanceRaw - held : 0;
    }

    /// @notice 在已创建健康池中寻找可接收整笔金额的最早池；返回零时由后端创建池或安排转冷。
    function findCapacity(address token, uint256 amount) public view returns (address) {
        if (amount == 0) return address(0);
        for (uint256 i; i < _vaults.length; ++i) {
            if (capacityOf(_vaults[i], token) >= amount) return _vaults[i];
        }
        return address(0);
    }

    /// @notice 选择最旧、持有目标币种且出金预算足以释放容量的健康池，并返回最小需转冷数量。
    /// @dev 不会清空其他币种代替目标币种；没有安全候选时返回零地址而不是强制超额。
    function oldestRecyclable(address token, uint256 amount)
        external
        view
        returns (address candidate, uint256 releaseAmount)
    {
        T.AssetCap memory cap = _caps[token];
        if (
            mappingDigest == bytes32(0) || authority.sweepsPaused() || authority.outflowsPaused()
                || !cap.enabled || amount == 0 || amount > cap.maxBalanceRaw || coldAddress == address(0)
                || !riskRegistry.healthy(coldAddress, token)
                || riskRegistry.state(riskRegistry.recipientScope(coldAddress)).restricted
        ) return (address(0), 0);
        for (uint256 i; i < _vaults.length; ++i) {
            address vault = _vaults[i];
            if (!riskRegistry.healthy(vault, token)) continue;
            uint256 held = ExactTransfer.balance(token, vault);
            uint256 capacity = held < cap.maxBalanceRaw ? cap.maxBalanceRaw - held : 0;
            if (held == 0 || capacity >= amount) continue;
            uint256 needed = held >= cap.maxBalanceRaw ? held - cap.maxBalanceRaw + amount : amount - capacity;
            if (_policies[token].movementsEnabled && IHotVault(vault).availableOutflow(token) >= needed) {
                return (vault, needed);
            }
        }
    }

    /// @notice 只有已登记充值合约/热钱包能在资金事务中消费操作号；整个租户范围内唯一。
    function consumeMovement(bytes32 operationId) external {
        if (
            !authority.ready()
                || (!isHotVault[msg.sender] && !IDepositFactory(authority.depositFactory()).isVault(msg.sender))
                || operationId == bytes32(0)
        ) revert InvalidConfiguration();
        if (movementConsumed[operationId]) revert MovementAlreadyConsumed();
        movementConsumed[operationId] = true;
        emit MovementConsumed(operationId, msg.sender);
    }
}
