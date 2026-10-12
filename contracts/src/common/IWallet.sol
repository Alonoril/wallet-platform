// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { WalletTypes as T } from "./WalletTypes.sol";

/// @notice 组件的固定租户归属检查接口，供一次性部署绑定使用。
interface ITenantBound {
    /// @notice 固定租户权限根地址，用于验证组件不能跨租户混搭。
    function authority() external view returns (address);
}

/// @notice 引导时核对 Factory、池、验证器和订单簿的交叉绑定，不允许混搭两套组件。
interface IFactoryConfiguration {
    /// @notice Factory/充值实现固定绑定的池管理器地址。
    function manager() external view returns (address);
    /// @notice 组件固定引用的同租户风险登记器。
    function riskRegistry() external view returns (address);
}

/// @notice 管理器及订单簿的不可变组件地址查询。
interface IPoolConfiguration {
    /// @notice 管理器固定共享订单簿，不能随付款目标或 attempt 改变。
    function withdrawalBook() external view returns (address);
    /// @notice 固定来源与委员会验证器，用于验签和一次性部署关系核对。
    function verifier() external view returns (address);
    /// @notice 组件固定引用的同租户风险登记器。
    function riskRegistry() external view returns (address);
}

/// @notice 用于阻止平台角色与当前跨链委员会成员共用同一签名地址。
interface IBridgeMembership {
    /// @notice 某地址登记的委员会版本，仅与当前 committeeEpoch 相等时为当前成员。
    function memberEpoch(address account) external view returns (uint64);
    /// @notice 当前委员会成员配置版本，换届时只能递增。
    function committeeEpoch() external view returns (uint64);
}

/// @notice 充值归属与用户签名身份只读接口；调用方不得接受 calldata 指定的替代签名人。
interface IDepositFactory {
    /// @notice 历史已登记充值地址标记，退役后也不删除，防止内部地址被当作外部来源。
    function isVault(address vault) external view returns (bool);
    /// @notice 由 Factory 永久记录的充值地址用户归属，不能提现时另指定用户。
    function userOf(address vault) external view returns (bytes32);
    /// @notice 用户本人持有的授权账户，退款调用必须从这里读取而不是接受调用方传入地址。
    function userSigner(bytes32 userKey) external view returns (address);
    /// @notice 用户身份版本，密钥轮换后该用户全部充值地址的旧退款签名失效。
    function userSignerEpoch(bytes32 userKey) external view returns (uint64);
}

/// @notice Factory 生命周期控制与唯一归集回调接口，均由实现合约检查严格调用权限。
interface IDepositVault {
    /// @notice Factory 地址轮换时永久关闭旧代归集，保留退役前的双签自提。
    function restrictSweeps() external;
    /// @notice Factory 已清零检查或治理确认残留后永久退役旧地址。
    function retire(bytes32 reason) external;
    /// @notice 查询不可逆生命周期标记，后端不能为退役地址继续记业务入账。
    function retired() external view returns (bool);
    /// @notice 仅释放当前外层已授权归集的同步回调金额一次。
    function releaseSweep(address token, uint256 amount) external;
}

/// @notice 池间受控资金转移接口；接收方校验容量，发送方只释放当前已授权的同步回调金额。
interface IHotVault {
    /// @notice 管理器部署克隆的同一交易内设置池身份，禁止重复初始化。
    function initialize(bytes32 poolId) external;
    /// @notice 扣除风险预留、底线及单笔/累计预算后的安全可出数量。
    function availableOutflow(address token) external view returns (uint256);
    /// @notice 受控接收登记充值合约归集，转账前后均校验真实容量。
    function acceptDeposit(address token, uint256 amount, bytes32 operationId) external;
    /// @notice 受控接收同租户热池内部调拨，不形成新用户权益。
    function acceptHotTransfer(address token, uint256 amount, bytes32 operationId) external;
    /// @notice 仅供当前调拨目标在同步回调内领取固定币种和数量一次。
    function releaseMovement(address token, uint256 amount) external;
}

/// @notice 业务合约查询当前资产、限额、路由与冷地址的权威接口，金额全部使用原始数量。
interface IHotPoolManager {
    /// @notice 查询管理器永久登记的热池地址，拒绝任意外部池冒领订单消费权限。
    function isHotVault(address vault) external view returns (bool);
    /// @notice 识别充值地址、热池和当前/历史冷地址，阻止内部移动伪装外部付款。
    function isCustodyAddress(address account) external view returns (bool);
    /// @notice 查询固定 assetKey、显示精度与资产审核版本。
    function assetConfig(address token) external view returns (T.AssetConfig memory);
    /// @notice 查询该币种每池持仓上限、启用标记与并发配置版本。
    function assetCap(address token) external view returns (T.AssetCap memory);
    /// @notice 查询该币种出金预算、底线、Council 门槛与策略版本。
    function outflowPolicy(address token) external view returns (T.OutflowPolicy memory);
    /// @notice 当前两链映射发布版本，签名和后端查询必须保持一致。
    function mappingEpoch() external view returns (uint64);
    /// @notice 治理发布的两链映射快照摘要，首份发布前受控热池业务保持关闭。
    function mappingDigest() external view returns (bytes32);
    /// @notice 当前离线冷钱包公开地址，接口不涉及任何私钥。
    function coldAddress() external view returns (address);
    /// @notice 冷地址配置版本，地址变更后旧转冷授权失效。
    function coldAddressEpoch() external view returns (uint64);
    /// @notice 转账前检查目标健康、路由启用且实际余额加转入数量不超上限。
    function checkIncoming(address target, address token, uint256 amount) external view;
    /// @notice 转账后再次检查实际余额与配置；原生补仓进入函数时 msg.value 已计入余额。
    function checkFundedBalance(address target, address token) external view;
    /// @notice 由登记业务合约在资金事务中消费租户全局唯一操作号，失败一起回滚。
    function consumeMovement(bytes32 operationId) external;
    /// @notice 返回健康热池的该币种实际剩余容量，禁用、污染、超额或暂停时为零。
    function capacityOf(address vault, address token) external view returns (uint256);
    /// @notice 按创建顺序查找能接收整笔指定数量的健康池；返回零表示需要创建/回收/排队。
    function findCapacity(address token, uint256 amount) external view returns (address);
    /// @notice 寻找持有目标币种且预算/风险允许释放缺口的最旧健康池。
    function oldestRecyclable(address token, uint256 amount) external view returns (address, uint256);
    /// @notice 已经创建的池总数，受限池不会删除以绕过上限。
    function hotVaultCount() external view returns (uint256);
    /// @notice 当前治理允许的热池最大数量，仅为 20 或 50。
    function maxHotVaults() external view returns (uint256);
    /// @notice 登记资产总数，用于正常退役的有界完整余额检查。
    function assetCount() external view returns (uint256);
    /// @notice 按登记顺序枚举资产地址；原生币用零地址。
    function assetAt(uint256 index) external view returns (address);
}
