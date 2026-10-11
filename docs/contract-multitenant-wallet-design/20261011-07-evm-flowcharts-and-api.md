# EVM 合约流程图与后端 API 接入说明

日期：2026-10-11。合约基准提交：`23b031f feat: implement EVM contract wallet suite`。

本文对应当前 Solidity V1 入口。Rust/PostgreSQL 后端、HTTP API、索引器、KYT 接入、签名任务和 Webhook **尚未实现**。泳道图仅表达系统角色与交互流程；各组件的实际交付状态以本文说明为准。治理与运营泳道表示参与者及合约能力，不表示完整运营系统已经交付。

## 1. 图册入口

- [彩色可缩放图册](swimlanes/index.html)：13 张泳道图（含合约功能详图）与 10 张原方块图，支持切换、缩放、查看图外重点及 Mermaid 源码。
- [Mermaid 泳道图合集](swimlanes/README.md)：每张图的彩色预览、源码和详细说明。
- [EVM 合约详细功能图](20261011-08-evm-contract-functions.md)：单张合约泳道，集中展开重要 Solidity 实现，链外仅保留调用触发说明。
- [全部 12 图的可编辑 Excalidraw 画布](swimlanes/20261011-evm-wallet-all-flows.excalidraw)。
- [原方块图目录](flows/README.md)：保留原 SVG 和 MCP 原始场景；另提供包含绑定文字的标准 Excalidraw 文件。

新图用短动作、短判断表达流程，把接口路径、签名字段、限额、竞态和例外移到本文与每张图的图外说明。Mermaid flowchart 使用责任子图；经 Excalidraw MCP 转换后重排为固定泳道。不同 Mermaid 渲染器的自动位置可能不同，固定职责列以 SVG/Excalidraw 为准。

| 颜色 | 含义 |
|---|---|
| 蓝色框与蓝色文字 | 租户调用、公网 API、查询和通知 |
| 紫色框与紫色文字 | 后端业务、签名器和 Relayer |
| 绿色框与绿色文字 | EVM 合约执行与资产移动 |
| 青色框与青色文字 | 索引、账本、最终事实与对账 |
| 红色框与红色文字 | Guardian/Council、冻结、隔离、阻断和缺口 |
| 黄色判断、橙色文字/连线 | 条件判断、待确认、异步事件 |

实线表示调用、批准或步骤推进；虚线表示链事件、异步通知或独立后续流程。颜色之外保留角色标题、动作和分支标签。

## 2. 推荐阅读顺序

| 图 | 重点 |
|---|---|
| [00 业务全景](swimlanes/20261011-00-overview.svg) | 地址、充值、归集、结算、付款、事故隔离 |
| [01 地址发行](swimlanes/20261011-01-address-issuance.svg) | 幂等分配、预测验真、监控覆盖和发行门槛 |
| [02 充值与归集](swimlanes/20261011-02-deposit-sweep.svg) | 最终性/KYT 分离、全余额授权、逐项批次恢复 |
| [03 Clearing 结算](swimlanes/20261011-03-clearing-settlement.svg) | 观察期、lot 释放、迁移保留 maturity |
| [04 提现](swimlanes/20261011-04-withdrawal.svg) | 受理 Hold、资金授权、实时风险检查、最终过账 |
| [05 取消](swimlanes/20261011-05-cancellation.svg) | 取消与付款竞争、未签证明、安全释放 Hold |
| [06 风险资金未归集](swimlanes/20261011-06-risk-before-sweep.svg) | 预测地址冻结、原址留存、撤销和竞态追踪 |
| [07 风险资金已归集](swimlanes/20261011-07-risk-after-sweep.svg) | 实际持有池控制、预留、多案件和已外付缺口 |
| [08 专项处置](swimlanes/20261011-08-disposition.svg) | 完整控制快照、隔离原子性、Quarantine 释放 |
| [09 冷热调度](swimlanes/20261011-09-cold-custody.svg) | 转冷阈值、每笔回款共同批准、共享预算 |
| [10 治理与迁移](swimlanes/20261011-10-governance.svg) | 部署验真、至少两天时间锁、旧域终结 |
| [11 事件与恢复](swimlanes/20261011-11-events-recovery.svg) | 最终事实、唯一经济效果、Outbox、恢复锁定 |

每个租户、每条链独立部署一套合约；V1 一套对应一个 `poolId`。默认路径为 Deposit → Clearing → Treasury，Cold 和 Quarantine 由独立批准的内部调度进入。

## 3. 公网 API 与合约的交互

以下均为规划接口。资源地址以 [04 合约模式 API](20261010-04-flows-ledger-and-storage.md#6-api-与异步通知) 为准；通信、报价、Business Hold、事件补拉等沿用 [M02](../multitenant-wallet-design/20261009-v2-detailed-design/02-open-api-and-communication.md)。旧设计的用户资源路径与新的 wallet 资源路径尚未实现兼容映射。

| 方法与路径 | 后端事务/动作 | 合约交互 | 完成与通知依据 |
|---|---|---|---|
| `POST /v1/wallets` | 幂等创建用户账务主体 | 不部署 Vault | 持久事务提交 |
| `POST /v1/wallets/{id}/addresses` | 分配永久 walletKey；校验 USER/ORDER 归属与发行证据 | `VaultFactory.predictVault`；需要演练时用受限部署任务 | 发行门槛通过后 ISSUED；准备中返回可查询状态 |
| `GET /v1/wallets/{id}/addresses` | 查询当前/历史地址与接收资产范围 | 不发资金交易 | 永久映射；retired 地址继续监听 |
| `GET /v1/deposits` | 查询确认、风控、入账三个维度 | 读取索引结果；内部归集由任务触发 | 最终入款事实及 journal；风险单独变化 |
| `GET /v1/balances` | 返回 available、risk_pending、各类 held、pending_chain、ledger_seq | 不把单个池余额直接作为用户余额 | 同一账本快照与对应序号 |
| `POST /v1/withdrawal-quotes` | 固定付款本金 P、服务费 F、资产、有效期 | 不签资金 Permit | 报价提交；不表示付款受理 |
| `POST /v1/withdrawals` | 同事务写幂等、订单唯一、P+F 用户 Hold、额度预留、Outbox | 审批后内部签名；Relayer 调 `Treasury.executeWithdrawal` | 202 仅受理；最终 `WithdrawalExecuted` 与 requestStatus 匹配后 paid |
| `GET /v1/withdrawals/{id}` | 查询订单、各交易尝试、确认与取消状态 | 可交叉核验 `requestStatus` | 规范链最终事实；不只看 txHash |
| `POST /v1/withdrawals/{id}/cancel` | 永久关闭再授权 gate；建立取消任务 | 有签名可能时调用 `cancelWithdrawal` | 最终 Cancelled 且未付款才释放；已付则按 paid 处理 |
| `POST /v1/holds` | 同租户作用域内创建 BUSINESS Hold | 不直接建立链上风险冻结 | 幂等账务事务 |
| `POST /v1/holds/{hold_id}/releases` | 幂等部分/全部释放具体 BUSINESS Hold | 不能解除 RiskRegistry HOLD 或在途付款 Hold | 授权账务事务 |
| `POST /v1/internal-transfers` | 同租户、同网络、同资产账本划转 | 不等同于池间 `transferCustody` | 账本唯一分录；不可跨租户 |
| `GET /v1/events` | 游标补拉稳定事件 | 不发链交易 | 与 Webhook 相同 eventId/语义版本 |

### 3.1 请求和受理边界

1. TLS/mTLS、HTTP 报文验签、内容摘要与有效期 → 持久 nonce 防重放 → schema → 租户/scope/用户授权 → PG 幂等事务。
2. 租户上下文来自已登记通信公钥，不信任请求体自行指定的内部 tenant/pool/签名器/付款池。
3. 每次 HTTP 尝试换 nonce 和通信 request ID；重试保留业务 Idempotency-Key 与 external_order_id。同键不同业务摘要返回冲突；不同幂等键也不能重复同一商户订单。
4. 资产金额采用最小单位整数字符串；链编码使用 uint256/BigInt。原生币 `token=address(0)`，全资产冻结另用 `allAssets=true`。
5. 短 PG 事务提交后才进行 RPC、KYT、签名和广播。超时返回可跟踪状态，不能假定资金业务未发生。

### 3.2 资金签名与 Relayer

通信签名、EIP-712 资金授权、EOA 外层交易分别使用独立密钥、域和状态机：

| 层 | 绑定内容 | 持久状态重点 |
|---|---|---|
| API 通信 | method、URI、内容摘要、业务幂等键、通信 nonce | 身份、防重放、原受理响应 |
| EIP-712 Permit | chainId、实际 verifyingContract、租户/池、经济 ID、资产/金额/目标、批准摘要、epoch、有效期 | AUTHORIZATION_POSSIBLE 先提交；授权凭据加密保存并获得证据 ACK |
| EOA 交易 | to、value、calldata、chain、EOA nonce、Gas 参数 | 独立 nonce lane；raw/签名凭据受控保存；替换尝试可追踪 |

提现外层 `to=Treasury`、`value=0`；本金从 Treasury 出，Relayer 只付 Gas。高额条件为 `amount > councilThreshold`，另需独立 ERC-1271 Council。Permit 有效区间最多一小时，建议默认五分钟；字段顺序和 Domain 以 [eip712.json](../../contracts/interfaces/eip712.json) 为准。

后端必须自己选择已批准池和路由，固定完整经济参数。公网租户不能提交任意 calldata、digest、salt、签名 key 或自选 Treasury。

## 4. 内部任务与最终事实

以下命令名称是建议的 typed command，**不是已实现 HTTP 路由**。Guardian/Council/Timelock 与在线签名者按当前合约权限分别执行。

| 内部业务 | 合约入口/授权 | 后端完成判定与约束 |
|---|---|---|
| DeployDeposit / Sweep | Manager.deployVault / sweep / batchDeployAndSweep；RISK_SIGNER + executor | 逐项最终 `SweepExecuted`、operationStatus；部署不解除 HOLD |
| SettleLots | Clearing.settle；SETTLEMENT_SIGNER | `SettlementExecuted`、`LotReleased`、lot 余额；成熟、无重复、lotsHash |
| TransferCustody | Treasury.transferCustody；TRANSFER_SIGNER，高额/迁移另需 Council | `TreasuryTransferred`；内部迁移，不增加用户充值 |
| ReturnCold | Cold.returnToTreasury；在线 + 每笔 Council | `ColdReturned`；只能回登记 Treasury |
| ApplyRiskControl | Risk.addHold / applyPoolAssetHold / setSecurityPause | desired、广播、包含、最终 observed 分开；HOLD/epoch/预留 getter 核验 |
| SetCaseReserve | Risk.setReserve；收紧/恢复权限按角色 | 绝对量 + version CAS；通知重试不重复累加 |
| ReleaseCaseHold | Risk.releaseHold；仅 Council | 逐案件解除；其他 HOLD、SECURITY_PAUSED、reserve 仍独立存在 |
| DisposeCase | Controller.executeDisposition；Council | `DispositionExecuted`、控制快照、预留/lot/资产变化一致 |
| CancelOperation | Manager/Pool/Controller 的 OperationBook.cancelOperation | 最终 Cancelled + 未执行经济效果；Guardian/Council/Timelock |
| GovernSuite | Council → Timelock.scheduleBatch / executeBatch | 至少两天；真实代码/getter 与提案一致，最后恢复路由 |

链上只校验约束和已批准授权，不做 KYT，不解释链下法律事实，也不自动建立用户账本。

### 4.1 批次与精确资金移动

- 归集 `amount == expectedBalance == 实时全部余额`；新增充值/粉尘导致差异时重新扫描整个余额并审批。
- 批次至多 50 项；单项 Gas 100,000–2,000,000；单签名不超过 4,096 字节；总 calldata 不超过 131,072 字节。
- ItemFailed 只回滚该项，BatchStopped 后未执行项续排；外层 revert/OOG 回滚整个批次。外层成功不等于每项成功。
- Clearing 普通结算最多 50 个无重复 lot；到期且剩余额度覆盖；迁移另需 Council，并保留原 maturity。
- 直接打入 Clearing 的未知资金没有 lot；只能按专项批准使用 `balance-outstanding` 的未归属超额，不能冒充可结算 lot。
- 普通提现、转冷、回款、调拨共用单笔、UTC 日和最近 25 小时桶预算；普通流出还需覆盖总风险预留及 Treasury 安全底线。后端另扣在途物理资金预留。

### 4.2 取消与退款

优先使用“最终 requestStatus=Cancelled，匹配撤销事实且无付款经济效果”的证明。完整未签证明路径必须先永久关闭所有再授权 gate；授权过期/epoch 终结路径需要最终链时间/控制与全部授权和执行覆盖证明，见图 05 及 [04 取消判定](20261010-04-flows-ledger-and-storage.md#31-取消与退款判定)。

外层 revert、RPC 查不到、txHash 丢失、换 Relayer、EOA nonce 替换或本地时钟超过 deadline 均不能直接释放用户 Hold。若付款已最终执行，取消失败并按已付款过账。迁移 Treasury 前终结旧域活跃授权，旧去重映射不自动迁移。

## 5. 重点场景 A：风险资金尚未归集

见 [06 原址控制泳道](swimlanes/20261011-06-risk-before-sweep.svg)。

1. 在同一 PG 事务建立案件、关闭相关签名 gate、冻结可追回用户负债、记录控制期望与紧急 Outbox。
2. Guardian 通过专用应急 nonce lane 调 `addHold(predictedVault, token, false, caseId)`，未部署地址同样可控制。
3. 撤销相关已签 operationId；HOLD/解除提升 epoch。后续部署、解除后恢复都需要新批准和新授权。
4. 到控制最终生效块回填实际移动；若归集抢先执行，立即进入场景 B，不能以原址 HOLD 证明下游已经冻结。
5. 默认原址留存。需隔离时由 Council 明确批准进入图 08；解除时逐案审批，不自动清除其他限制。

**混合余额例子：** 同地址有正常 100 与风险 20，默认该资产 120 全部禁止普通归集。ERC-20/原生余额无法按来源挑选物理“干净币”。若批准专项隔离金额 20，其含义是控制批准金额，来源风险与剩余 100 的恢复仍需独立复核。

冻结不能阻止第三方继续向预测地址/已部署地址转入资产。风险供应商不可用和扫描缺口保持 pending/受限，不伪造失败或 ALLOW。

## 6. 重点场景 B：风险资金已经归集

见 [07 逐池控制与缺口泳道](swimlanes/20261011-07-risk-after-sweep.svg)。

1. 从 movement/lot/最终交易追溯实际持有池和在途授权；分别控制 Clearing、Treasury、Cold 及其他实际下游。
2. Guardian 调 `applyPoolAssetHold(pool, token, caseId, minimumReserve)`，同一事务建立案件 HOLD、预留下限并改变 epoch；先停止受影响池/资产全部普通流出。
3. 回填到控制生效块，继续追加下游控制。逐 scope 核验最终状态，保留“控制请求/广播/包含/最终生效”的差别。
4. 预留使用绝对量 + CAS version。不同案件预留相加；重叠义务的去重和分配在后端明示，不能用重复通知重复累计。
5. Council 决定继续 HOLD、批准隔离，或逐案解除 HOLD 并保留/调整预留。任何剩余 HOLD 继续阻断普通出口。
6. 已外付资产无法由合约撤回。持续记风险义务、可控量、不可用量和缺口；损失/追偿/运营注资另外审批记账，不静默冲用户债权、不用其他租户垫付。

**有限恢复例子：** 池余额 1,000，A 预留 100，B 预留 150，Treasury 安全底线 50。仅当全部适用 HOLD 已解除，且其他控制开放时，链上普通可转出上限为 700；还受支付预算与后端在途物理预留约束。解除 A 不解除 B，也不自动减少任何预留。

链上预留超过余额时普通出口保持阻断；Council 可按实际可控量明确调整链上预留，后端案件义务与缺口仍完整保留。仅冻结原 DepositVault 不能控制下游资金；`routesPaused` **不阻断直接 Treasury 提现**，全面出金控制必须使用 RiskRegistry 或额度。

## 7. 隔离与恢复的原子边界

见 [08 专项处置泳道](swimlanes/20261011-08-disposition.svg)。

- Council 审阅源/目标完整 controlDigest 对应的全部案件与批准范围，签署精确 DispositionPermit。控制变化使旧快照签名失效。
- `preserveRestriction=true`：源本案减少 reserveToMove；该值不得超过 amount 或源本案预留；目标 Quarantine 为**全部 amount**建立 reserve/HOLD，其他案件预留留在源池。
- Deposit 源可由 Controller 独立懒部署；Clearing 登记 lot 需 lotsHash 并原子扣释放量；无 lot 仅消耗未归属超额。
- 处置可在明确批准下例外移动 HOLD 资金，但不能绕过 SECURITY_PAUSED 或侵占剩余案件预留。消费 ID、lot、预留和精确转账全部原子回滚。
- `preserveRestriction=false` 只允许 Quarantine 回登记 Treasury；双边全部适用 HOLD 清除、释放相应预留后另签授权，仍需满足剩余预留底线。
- 隔离和释放只改变保管位置；源池风险、用户受限负债、案件义务不自动解除。最终外部付款继续使用图 04 的 Treasury 提现流程。

## 8. 账本、通知与恢复

最终充值先记真实托管资产与待审查负债；ALLOW 才转用户可用。归集、结算、转冷、回款、迁移和隔离只改变资产位置，不重复增加用户余额。

事件身份包含链、实际执行合约、经济 ID 和规范链证据。最终事件与 requestStatus/operationStatus、金额/资产/目标交叉核验后，同一事务写 journal、业务状态与 Outbox。Gas 作为实际网络资产费用独立记账。

Webhook 使用稳定 eventId、版本、平台签名，至少一次投递；接收方事务去重，遗漏通过 GET /v1/events 补拉。查询返回可披露状态及快照序号，不向租户泄漏名单来源或调查材料。

数据库恢复/深重组先进入 RECOVERY_LOCKED。恢复永久地址归属、配置与批准/签名证据，从共同 checkpoint 回放并对账全部执行域；链日志不能重建全部用户归属。深重组通过审批后的冲正 cycle 处理，控制不确定期间本地 gate 保持关闭。

## 9. 源码与协议依据

| 范围 | 当前源码 |
|---|---|
| 地址、懒部署、批量归集 | [VaultFactory](../../contracts/src/deposit/VaultFactory.sol)、[DepositVault](../../contracts/src/deposit/DepositVault.sol)、[VaultManager](../../contracts/src/sweep/VaultManager.sol) |
| 清算、付款、冷热调度 | [ClearingVault](../../contracts/src/pools/ClearingVault.sol)、[TreasuryVault](../../contracts/src/pools/TreasuryVault.sol)、[ColdVault](../../contracts/src/pools/ColdVault.sol) |
| 风险、预留、隔离 | [RiskRegistry](../../contracts/src/control/RiskRegistry.sol)、[DispositionController](../../contracts/src/control/DispositionController.sol) |
| 角色、路由、额度、时间锁 | [TenantAuthority](../../contracts/src/control/TenantAuthority.sol)、[PoolRegistry](../../contracts/src/control/PoolRegistry.sol)、[TenantTimelock](../../contracts/src/control/TenantTimelock.sol) |
| 一次性状态、签名字段与编码 | [OperationBook](../../contracts/src/common/OperationBook.sol)、[WalletTypes](../../contracts/src/common/WalletTypes.sol)、[PermitHash](../../contracts/src/common/PermitHash.sol)、[EIP-712 schema](../../contracts/interfaces/eip712.json) |
| 部署、激活 | [DeployTenant](../../contracts/script/DeployTenant.s.sol)、[PrepareActivation](../../contracts/script/PrepareActivation.s.sol)、[ActivationPlan](../../contracts/script/ActivationPlan.sol) |

完整业务与运行边界继续见 [03 风险隔离](20261010-03-risk-isolation.md)、[04 账本与存储](20261010-04-flows-ledger-and-storage.md)、[合约接入 README](../../contracts/README.md)。
