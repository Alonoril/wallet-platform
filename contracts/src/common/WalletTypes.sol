// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title 钱包 v2 的共用状态与签名结构
/// @notice 所有 amount/limit/balance 为 uint256 币种最小单位；uint48 时间为 EVM 秒，uint64 epoch 只能递增。
library WalletTypes {
    /// @notice 经济订单只允许从 Unused 转为 Executed 或 Cancelled，终态不复用。
    enum OrderStatus {
        Unused,
        Executed,
        Cancelled
    }
    /// @notice 只有 DepositSweep 对应首次净归集；其他类型仅表示托管位置移动或异常处置。
    enum MovementKind {
        DepositSweep,
        HotTransfer,
        ColdSweep,
        ColdRefill,
        RetiredDisposition
    }

    /// @notice 不可变资产身份与显示精度；assetEpoch 使旧资产审核版本的授权失效。
    struct AssetConfig {
        /// @notice 链实例、币种种类与 token 地址派生的固定资产标识；同名代币不能据此跨链合并。
        bytes32 assetKey;
        /// @notice 资产语义重新审核的递增版本，旧版本授权必须重新核验。
        uint64 assetEpoch;
        /// @notice 只用于显示的注册精度；不参与金额换算或合约限额计算。
        uint8 decimals;
        /// @notice 是否已由治理登记为支持的资产；未登记资产不能参与正常业务。
        bool registered;
    }

    /// @notice 每个热钱包分别应用的币种持仓上限；capVersion 是管理 API 的并发更新条件。
    struct AssetCap {
        /// @notice 每个 HotVault 的该币种最大持仓，使用 uint256 最小单位数量。
        uint256 maxBalanceRaw;
        /// @notice 持仓上限配置的并发版本；修改接口要求 expectedCapVersion 精确匹配。
        uint64 capVersion;
        /// @notice 是否允许该币种受控入池；禁用不销毁已有资金，也不修改用户权益。
        bool enabled;
    }

    /// @notice 单笔、日、滚动出金预算，余额底线与独立 Council 审批门槛，分别控制提现与调拨。
    struct OutflowPolicy {
        /// @notice 一次热池出金最多使用的原始数量；为零时禁止出金。
        uint256 singleLimit;
        /// @notice 单个热池、该币种的 UTC 当日累计出金上限，包含提现、调拨和转冷。
        uint256 dailyLimit;
        /// @notice 单个热池、该币种的保守滚动 24 小时累计出金上限。
        uint256 rollingLimit;
        /// @notice 任何热池出金后必须保留的该币种原始余额，不可借用支付。
        uint256 safetyFloor;
        /// @notice 金额达到此值必须有独立 Council 授权；为零时所有出金均要求 Council。
        uint256 councilThreshold;
        /// @notice 该币种出金策略版本，签名绑定后禁止在旧策略下继续执行。
        uint64 policyEpoch;
        /// @notice 是否启用热池外部用户付款；与受控入金开关相互独立。
        bool withdrawalsEnabled;
        /// @notice 是否允许热池内部调拨及容量回收转冷；不会授权任意外部目标。
        bool movementsEnabled;
    }

    /// @notice restricted 决定是否停用业务范围；reservedRaw 在地址+币种范围扣减可出金额。
    struct RiskState {
        /// @notice 地址+币种范围的风险预留数量，从可出金额中扣除，不改变资产物理余额。
        uint256 reservedRaw;
        /// @notice 风险状态单调版本，限制与解除均递增，防止旧授权解冻后重新生效。
        uint64 epoch;
        /// @notice 是否冻结该风险范围的归集或热池流转；未归集双签自提独立处理。
        bool restricted;
    }

    /// @notice 用户与 REFUND_SIGNER 对完全相同的正文分别签名；允许指定外部收款地址。
    struct RefundPermit {
        /// @notice 不可变租户标识，必须与目标合约固定租户一致。
        bytes32 tenantKey;
        /// @notice 租户下的固定用户标识；退款时必须与 Factory 对当前钱包记录的归属一致。
        bytes32 userKey;
        /// @notice 逻辑钱包标识，充值地址换代后仍保持同一用户归属。
        bytes32 walletKey;
        /// @notice 链实例、币种种类与 token 地址派生的固定资产标识；同名代币不能据此跨链合并。
        bytes32 assetKey;
        /// @notice 原生币使用零地址；ERC20 使用已登记合约地址，不能用 symbol 替代。
        address token;
        /// @notice 用户指定的外部收款地址，双签必须覆盖此字段；无原路返回限制。
        address recipient;
        /// @notice 本次资金转移原始数量，必须大于零，不含单独账本处理的服务费。
        uint256 amount;
        /// @notice 目标业务合约该币种的预期状态序号；资金变更先消费，失败全部回滚。
        uint256 assetStateNonce;
        /// @notice Factory 保存的用户签名身份版本；地址轮换不改变，用户密钥轮换递增。
        uint64 userSignerEpoch;
        /// @notice 专用平台退款签名者版本，避免平台换钥后旧签名继续有效。
        uint64 refundSignerEpoch;
        /// @notice 授权开始的 EVM 秒时间戳；执行时必须已到达。
        uint48 validAfter;
        /// @notice 授权到期的 EVM 秒时间戳；与 validAfter 之差最多一小时。
        uint48 deadline;
    }

    /// @notice 用户确认平台分配的身份与逻辑钱包绑定，domain 为 DepositFactory。
    struct WalletBinding {
        /// @notice 不可变租户标识，必须与目标合约固定租户一致。
        bytes32 tenantKey;
        /// @notice 租户下的固定用户标识；退款时必须与 Factory 对当前钱包记录的归属一致。
        bytes32 userKey;
        /// @notice 用户下的稳定逻辑钱包编号，与租户和 userKey 一起派生 walletKey。
        bytes32 logicalWalletId;
        /// @notice 用户独立持有的 EOA 或 ERC1271 授权账户；不能与平台退款签名者相同。
        address userSigner;
        /// @notice 授权开始的 EVM 秒时间戳；执行时必须已到达。
        uint48 validAfter;
        /// @notice 授权到期的 EVM 秒时间戳；与 validAfter 之差最多一小时。
        uint48 deadline;
    }

    /// @notice 用户签名地址变更：原用户、新用户密钥持有证明和平台签名必须绑定同一正文。
    struct UserSignerRotation {
        /// @notice 不可变租户标识，必须与目标合约固定租户一致。
        bytes32 tenantKey;
        /// @notice 租户下的固定用户标识；退款时必须与 Factory 对当前钱包记录的归属一致。
        bytes32 userKey;
        /// @notice 当前用户签名地址，必须与 Factory 登记值完全匹配且亲自批准轮换。
        address oldSigner;
        /// @notice 待生效的新用户签名地址，必须提供持有权签名，不能由平台单方面替换。
        address newSigner;
        /// @notice Factory 保存的用户签名身份版本；地址轮换不改变，用户密钥轮换递增。
        uint64 userSignerEpoch;
        /// @notice 专用平台退款签名者版本，避免平台换钥后旧签名继续有效。
        uint64 refundSignerEpoch;
        /// @notice 授权开始的 EVM 秒时间戳；执行时必须已到达。
        uint48 validAfter;
        /// @notice 授权到期的 EVM 秒时间戳；与 validAfter 之差最多一小时。
        uint48 deadline;
    }

    /// @notice 归集来源分配：SWEEP_SIGNER 证明来源、净金额及到账时间，合约核验逐笔观察期和风险版本。
    struct SourceAllocation {
        /// @notice 稳定充值来源编号，关联真实 receipt 定位；同一来源的净归集额度由跨链记账端累计核验。
        bytes32 depositId;
        /// @notice 本次资金转移原始数量，必须大于零，不含单独账本处理的服务费。
        uint256 amount;
        /// @notice SWEEP_SIGNER 核验的来源到账秒时间，合约对每条分配检查完整观察期。
        uint48 observedAt;
        /// @notice 该 depositId 风险范围的版本，冻结/解除后旧来源授权无效。
        uint64 sourceRiskEpoch;
    }

    /// @notice 归集授权绑定当前余额、共享资产 nonce、来源摘要与目标池，防止退款后继续执行旧任务。
    struct SweepPermit {
        /// @notice 租户范围内唯一资金移动号，成功后不可复用，失败交易回滚消费。
        bytes32 operationId;
        /// @notice 不可变租户标识，必须与目标合约固定租户一致。
        bytes32 tenantKey;
        /// @notice 逻辑钱包标识，充值地址换代后仍保持同一用户归属。
        bytes32 walletKey;
        /// @notice 链实例、币种种类与 token 地址派生的固定资产标识；同名代币不能据此跨链合并。
        bytes32 assetKey;
        /// @notice 原生币使用零地址；ERC20 使用已登记合约地址，不能用 symbol 替代。
        address token;
        /// @notice 签名固定的归集目标热钱包，必须属于当前租户且健康、容量充足。
        address hotVault;
        /// @notice 本次资金转移原始数量，必须大于零，不含单独账本处理的服务费。
        uint256 amount;
        /// @notice 签名时源合约该币种实际余额；新到账或其他付款使余额变化后旧授权失效。
        uint256 expectedBalance;
        /// @notice 目标业务合约该币种的预期状态序号；资金变更先消费，失败全部回滚。
        uint256 assetStateNonce;
        /// @notice 按 depositId 严格排序的来源分配 structHash 拼接摘要，防止篡改来源/金额/观察时间。
        bytes32 allocationsHash;
        /// @notice 当前两链映射的链上发布版本；后端还须核对两端最终生效配置。
        uint64 mappingEpoch;
        /// @notice 资产语义重新审核的递增版本，旧版本授权必须重新核验。
        uint64 assetEpoch;
        /// @notice 持仓上限配置的并发版本；修改接口要求 expectedCapVersion 精确匹配。
        uint64 capVersion;
        /// @notice 充值地址级风险版本，污染后关闭归集；用户自提无需该版本。
        uint64 vaultEpoch;
        /// @notice 充值地址+币种风险版本与当前预留，约束该币种归集。
        uint64 vaultAssetEpoch;
        /// @notice 用户归集/已归集提现风险版本；不限制 ACTIVE 充值地址的双签自提。
        uint64 userRiskEpoch;
        /// @notice 目标热钱包地址级风险版本，防止把资产归集至污染池。
        uint64 hotEpoch;
        /// @notice 目标热钱包+币种风险版本，必须健康并与签名快照匹配。
        uint64 hotAssetEpoch;
        /// @notice 该币种出金策略版本，签名绑定后禁止在旧策略下继续执行。
        uint64 policyEpoch;
        /// @notice 全局运营配置版本，配置或暂停改变后旧热池/归集授权必须重签。
        uint64 authorityEpoch;
        /// @notice 专用归集审核签名者的当前版本。
        uint64 sweepSignerEpoch;
        /// @notice 授权开始的 EVM 秒时间戳；执行时必须已到达。
        uint48 validAfter;
        /// @notice 授权到期的 EVM 秒时间戳；与 validAfter 之差最多一小时。
        uint48 deadline;
    }

    /// @notice 已归集权益付款授权；approvalDigest 绑定 Milon 用户授权、预留与费用等业务上下文。
    struct WithdrawalPermit {
        /// @notice 稳定经济提现订单号；所有热池共享消费和取消状态，换池不生成新订单。
        bytes32 requestId;
        /// @notice 不可变租户标识，必须与目标合约固定租户一致。
        bytes32 tenantKey;
        /// @notice 租户下的固定用户标识；退款时必须与 Factory 对当前钱包记录的归属一致。
        bytes32 userKey;
        /// @notice 链实例、币种种类与 token 地址派生的固定资产标识；同名代币不能据此跨链合并。
        bytes32 assetKey;
        /// @notice 固定付款池标识，必须与当前 HotVault 初始化身份匹配。
        bytes32 poolId;
        /// @notice 原生币使用零地址；ERC20 使用已登记合约地址，不能用 symbol 替代。
        address token;
        /// @notice 已审批的外部付款地址；不能改成另一个收款人或已知内部托管地址。
        address to;
        /// @notice 本次资金转移原始数量，必须大于零，不含单独账本处理的服务费。
        uint256 amount;
        /// @notice Milon 预留、用户授权、费用及审批策略等先确定业务上下文的摘要，不包含未来批准块形成循环。
        bytes32 approvalDigest;
        /// @notice 当前两链映射的链上发布版本；后端还须核对两端最终生效配置。
        uint64 mappingEpoch;
        /// @notice 资产语义重新审核的递增版本，旧版本授权必须重新核验。
        uint64 assetEpoch;
        /// @notice 付款热池的地址级风险版本，池冻结或解除后旧 Permit 不复活。
        uint64 poolEpoch;
        /// @notice 付款热池的资产级风险版本，执行时还要扣除当前风险数量预留。
        uint64 poolAssetEpoch;
        /// @notice 用户归集/已归集提现风险版本；不限制 ACTIVE 充值地址的双签自提。
        uint64 userRiskEpoch;
        /// @notice 外部收款人风险版本，冻结和解除都使历史付款授权失效。
        uint64 recipientRiskEpoch;
        /// @notice 该币种出金策略版本，签名绑定后禁止在旧策略下继续执行。
        uint64 policyEpoch;
        /// @notice 全局运营配置版本，配置或暂停改变后旧热池/归集授权必须重签。
        uint64 authorityEpoch;
        /// @notice Authority 保存的热池付款授权撤销版本，不等同于 committeeEpoch 或 bridgeEpoch。
        uint64 signerEpoch;
        /// @notice 授权开始的 EVM 秒时间戳；执行时必须已到达。
        uint48 validAfter;
        /// @notice 授权到期的 EVM 秒时间戳；与 validAfter 之差最多一小时。
        uint48 deadline;
    }

    /// @notice 内部移动授权；requiredCapacity>0 表示容量回收转冷，为零表示热转热，二者不可互换。
    struct MovementPermit {
        /// @notice 租户范围内唯一资金移动号，成功后不可复用，失败交易回滚消费。
        bytes32 operationId;
        /// @notice 不可变租户标识，必须与目标合约固定租户一致。
        bytes32 tenantKey;
        /// @notice 链实例、币种种类与 token 地址派生的固定资产标识；同名代币不能据此跨链合并。
        bytes32 assetKey;
        /// @notice 原生币使用零地址；ERC20 使用已登记合约地址，不能用 symbol 替代。
        address token;
        /// @notice 内部移动目标；热转热只允许登记热池，转冷只能使用当前公开冷地址。
        address destination;
        /// @notice 本次资金转移原始数量，必须大于零，不含单独账本处理的服务费。
        uint256 amount;
        /// @notice 签名时源合约该币种实际余额；新到账或其他付款使余额变化后旧授权失效。
        uint256 expectedBalance;
        /// @notice 目标业务合约该币种的预期状态序号；资金变更先消费，失败全部回滚。
        uint256 assetStateNonce;
        /// @notice 容量回收所需的新入金额；非零时必须池已满、无健康空位并选择最旧安全候选。
        uint256 requiredCapacity;
        /// @notice 当前两链映射的链上发布版本；后端还须核对两端最终生效配置。
        uint64 mappingEpoch;
        /// @notice 资产语义重新审核的递增版本，旧版本授权必须重新核验。
        uint64 assetEpoch;
        /// @notice 持仓上限配置的并发版本；修改接口要求 expectedCapVersion 精确匹配。
        uint64 capVersion;
        /// @notice 源热池地址级风险版本，污染源禁止出金和转冷。
        uint64 sourceEpoch;
        /// @notice 源热池+币种风险版本，执行还必须保留安全底线和数量预留。
        uint64 sourceAssetEpoch;
        /// @notice 目标热池/冷地址的地址级风险版本。
        uint64 destinationEpoch;
        /// @notice 目标地址+币种的风险版本，阻止资产迁入受限位置。
        uint64 destinationAssetEpoch;
        /// @notice 目标收款地址风险版本，解冻后旧移动授权也不能重新生效。
        uint64 destinationRecipientEpoch;
        /// @notice 冷地址配置版本；热转热必须为零，转冷必须匹配当前配置。
        uint64 coldAddressEpoch;
        /// @notice 该币种出金策略版本，签名绑定后禁止在旧策略下继续执行。
        uint64 policyEpoch;
        /// @notice 全局运营配置版本，配置或暂停改变后旧热池/归集授权必须重签。
        uint64 authorityEpoch;
        /// @notice 独立 TRANSFER_SIGNER 当前版本，不能用退款或付款委员会授权替代。
        uint64 transferSignerEpoch;
        /// @notice 授权开始的 EVM 秒时间戳；执行时必须已到达。
        uint48 validAfter;
        /// @notice 授权到期的 EVM 秒时间戳；与 validAfter 之差最多一小时。
        uint48 deadline;
    }

    /// @notice 委员会证明指定 Permit 已在固定 Milon App 审批成功且终局；定位真实性依赖门限成员独立验证。
    struct WithdrawalAttestation {
        /// @notice HotVault 重算的完整 EIP-712 付款摘要，证书不得指向不同付款参数。
        bytes32 permitDigest;
        /// @notice 部署固定的 Milon 来源链 ID，跨链编码使用 uint256。
        uint256 sourceChainId;
        /// @notice 部署固定的可信来源 genesis hash，防止同链 ID 的另一实例伪装来源。
        bytes32 sourceGenesisHash;
        /// @notice 固定 Milon 提现业务 App 的 uint8 编号，不接受其他应用审批。
        uint8 withdrawalAppId;
        /// @notice 当前治理安装的业务委员会标识，必须与节点核验的来源审批策略一致。
        bytes32 committeeId;
        /// @notice 固定委员会成员配置版本；换届后旧证书直接失效。
        uint64 committeeEpoch;
        /// @notice 节点独立核验的 Milon 成功业务终局高度；非零不等于 EVM 自行证明终局。
        uint64 approvedHeight;
        /// @notice Milon 成功业务所属终局块 hash，所有签名必须指向同一定位。
        bytes32 approvedBlockHash;
        /// @notice Milon 已执行成功业务交易 hash，不能仅用投票 ready 代替。
        bytes32 approvedTxHash;
        /// @notice EVM 桥授权撤销版本，紧急暂停、撤销、换届和恢复都会递增。
        uint64 bridgeEpoch;
        /// @notice 严格用途码：付款批准=1，取消批准=2；类型哈希同时隔离用途。
        uint8 action;
    }

    /// @notice 独立取消证书；使用不同类型哈希且 action=2，付款证书的签名无法用于取消。
    struct CancellationAttestation {
        /// @notice WithdrawalBook 重算的取消摘要，与付款签名类型和用途分离。
        bytes32 cancelDigest;
        /// @notice 部署固定的 Milon 来源链 ID，跨链编码使用 uint256。
        uint256 sourceChainId;
        /// @notice 部署固定的可信来源 genesis hash，防止同链 ID 的另一实例伪装来源。
        bytes32 sourceGenesisHash;
        /// @notice 固定 Milon 提现业务 App 的 uint8 编号，不接受其他应用审批。
        uint8 withdrawalAppId;
        /// @notice 当前治理安装的业务委员会标识，必须与节点核验的来源审批策略一致。
        bytes32 committeeId;
        /// @notice 固定委员会成员配置版本；换届后旧证书直接失效。
        uint64 committeeEpoch;
        /// @notice 节点独立核验的 Milon 成功业务终局高度；非零不等于 EVM 自行证明终局。
        uint64 approvedHeight;
        /// @notice Milon 成功业务所属终局块 hash，所有签名必须指向同一定位。
        bytes32 approvedBlockHash;
        /// @notice Milon 已执行成功业务交易 hash，不能仅用投票 ready 代替。
        bytes32 approvedTxHash;
        /// @notice EVM 桥授权撤销版本，紧急暂停、撤销、换届和恢复都会递增。
        uint64 bridgeEpoch;
        /// @notice 严格用途码：付款批准=1，取消批准=2；类型哈希同时隔离用途。
        uint8 action;
    }

    /// @notice 取消共享经济订单的正文；取消成功最终确认前不得在 Milon 释放预留。
    struct CancelPermit {
        /// @notice 稳定经济提现订单号；所有热池共享消费和取消状态，换池不生成新订单。
        bytes32 requestId;
        /// @notice 不可变租户标识，必须与目标合约固定租户一致。
        bytes32 tenantKey;
        /// @notice 独立取消业务上下文摘要；Milon 必须等 EVM 禁付最终确认才释放预留。
        bytes32 cancellationContext;
        /// @notice Authority 保存的热池付款授权撤销版本，不等同于 committeeEpoch 或 bridgeEpoch。
        uint64 signerEpoch;
        /// @notice 授权开始的 EVM 秒时间戳；执行时必须已到达。
        uint48 validAfter;
        /// @notice 授权到期的 EVM 秒时间戳；与 validAfter 之差最多一小时。
        uint48 deadline;
    }
}
