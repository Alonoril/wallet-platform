# 05 工程落地、成本、运维和验收

返回 [总览](README.md)。本文描述整个平台的交付要求；Solidity 合约端 V1 已在 `contracts/` 落地，实际模块、部署和验证见 [06](20261010-06-solidity-implementation.md)，Rust 服务、账本和目标链生产验证仍待实施。

## 1. 工程形态与模块职责

沿用 [M14 单进程基线](../multitenant-wallet-design/20261009-v2-detailed-design/14-engineering-and-acceptance.md)。一个 Rust workspace、一个 wallet-platform 在线二进制；app/core/vault/chain-evm/types 五个 crate，普通业务拆 module。新增 Solidity 工程独立编译，但不新增常驻 Worker/Signer 服务。

```text
contracts/
  src/deposit/        DepositVault、VaultFactory
  src/sweep/          VaultManager、受限批量调用
  src/pools/          TreasuryVault、ClearingVault、QuarantineVault
  src/control/        RiskRegistry、PoolRegistry、DispositionController
  test/               单元、fuzz、invariant、真实 token fork 场景
  script/             可复核部署、验真、角色交接
  deployments/        每环境每链非秘密 manifest、ABI、代码哈希
crates/wallet-core/
  registry/           地址分配与发行门槛
  risk/               KYT、风险决策、案件和控制期望状态
  sweep/              精确授权候选与批处理调度
  authorization/      授权签名、撤销、消费生命周期
  treasury/           Clearing lot、流动性、风险预留
  execution/          EOA nonce、交易族及跟踪
crates/wallet-vault/   受限 typed permit 与 EOA 签名、证据
crates/wallet-chain-evm/
  contracts/          ABI、CREATE2、EIP-712、事件和控制状态
  scan/               logs、native trace、覆盖与最终性
migrations/           统一 PostgreSQL 迁移
ops/                  部署、恢复、事故与演练手册
```

逻辑端口：`ContractAddressPredictor`、`RestrictedPermitSigner`、`RestrictedTransactionSigner`、`RiskEvidenceProvider`、`ChainEffectVerifier`；这里只定义职责，不引入未经编译验证的 Rust 类型补丁。core 拥有账务/状态，chain-evm 提供链事实，vault 复核受限载荷，app 组装。所有签名入口保留可能签名状态和结果持久证据，EIP-712 不能走通用消息签名捷径。

## 2. 性能、资源与容量

地址分配无链写入，仍需要数据库唯一性、监听覆盖和发行证据 ACK。百万地址不应每轮逐地址 eth_getBalance；ERC-20 按资产合约、块区间及接收地址分片索引，原生币使用完整区块/trace 流与本地地址集合匹配。利用有界缓存和增量 registry version；漏掉新缓存地址的事件用出生高度回填弥补。RPC logs 分页和节点限制必须实测。

归集只查询候选脏地址，余额多调用批量化但限制返回体。按 chain/tenant/pool/token/version 分队列；每 vault/token 在途授权唯一。KYT、扫描、RPC、签名、fsync、通知独立有界配额，Guardian 不共享普通批处理队列。大批量反序列化采用借用或 ownership 转移，避免无必要 clone 和中间集合；不把秘密放入通用共享缓存。

Rust 2024、tabs、导入排序、单 .rs≤500 行、函数≤120 行、精确整数。重计算/KDF/fsync 进受控阻塞池，资金锁期间不做外部调用。PG job 租约和 fencing 只解决任务 ownership，最终幂等仍由数据库唯一键与合约消费状态兜底。

建议初次容量验收档：100 万注册地址、每秒 100 次地址/余额请求、每秒 20 次充提业务受理、24 小时持续运行。它是待测负载，不是承诺的 TPS；链上吞吐另按块 Gas、token 成本和确认时延估算。验收至少记录 p50/p95/p99、DB 锁等待、RPC 配额、积压恢复速度、内存上限和证据 fsync；正式 SLA 由实测和业务输入冻结。

## 3. Gas 成本与归集调度

比较必须包含：租户级合约固定部署、用户首次部署、后续归集、Clearing 二次结算、原生/token 提现、失败/重试、Governance 控制交易及 Relayer 补充。用户充值侧 Gas 也要单独测量，已部署 Clone 收原生币可能比未部署地址昂贵。

```text
C_new = C_tenant_suite / active_addresses
        + C_deploy / successful_sweeps_per_address
        + C_sweep_item + C_batch_fixed / batch_items
        + C_clearing_settlement_share + C_failure_and_control_share

C_old = C_eoa_token_transfer + amortized_C_gas_funding
        + C_recovery_of_gas_dust
```

统一以网络实际费用币计价，再用明确报价时刻展示法币成本；Gas 数量与支付价格分别报告。L2 需区分 L2 执行和 L1 数据等额外费用，避免已包含收费被重复累加。ERC-1167 部署节省相对于完整合约的字节码成本，不代表首笔归集一定比 EOA 便宜。

| 基准维度 | 必测组合 |
|---|---|
| 生命周期 | 地址无充值、仅一次、5 次、20 次重复充值 |
| 部署 | 未部署预充 native/token/多资产、已部署 |
| 批次 | 1/5/20/50 项及实际链上限附近，混合新旧地址 |
| 资产行为 | native、批准 token、返回 false/no-return、暂停/黑名单、Gas 异常 |
| 路由 | 直接 Treasury、经 Clearing、专用风险域 |
| 链 | 每个计划启用网络分别测，不能从 Ethereum 推断其他链 |
| 故障 | 子项 revert、外层 OOG、RPC 超时、费率突升、浅重组 |

预留费用以模拟 gasLimit×批准 fee cap 加链额外费用上界和缓冲计算。原生运营盈余需覆盖所有费用预留与安全缓冲，token 服务费不能直接充当 ETH 资本。Relayer 只存有限运营原生币；补充从同租户明确运营资本来，补充自身也要记费用。

调度优先级：风险 gate → 热池流动性/敞口硬上限 → 最大等待时间 → 经济性与批量。KYT 未通过不能因缺流动性强行归集。未归集但已记可用的余额占用本租户垫付额度；额度不足时提现进入透明等待状态，不借其他租户资金。小额长期低于成本阈值的入款必须有人工/运营预算处理 SLA，不能永远沉默搁置。

## 4. 部署与权限交接

1. 固定 Solidity 编译器精确版本、OpenZeppelin release/commit、Foundry 工具链、优化和 EVM target，输出 lockfile、源码、ABI、creation/runtime hash 和测试向量。不能依赖浮动 latest。
2. 先部署并验证离线治理/时间锁和 Guardian，再按封存计划部署 Risk/Pool Registry、池、Manager、Factory/Implementation、DispositionController。存在地址依赖时使用明确的部署者 nonce 预计算，或已验证的固定部署器计划；不得用循环依赖的 CREATE2 init code 随意猜地址。
3. 对 Implementation trustedFactory 的依赖，可先固定专用部署 EOA 的交易序列及 Factory 将使用的 nonce，预计算其 CREATE 地址，再部署 Implementation 与 Factory；任何前序交易变化即废弃未发行计划、重新生成。上线工具必须校验每步实际地址。
4. 逐合约核对代码、构造/getter、tenant/pool、角色、阈值、时间锁、资产白名单、所有旁路入口；交接后撤销部署者临时权限，验证无残留管理员或未初始化代理。
5. 小额真实预充值→部署→归集→Clearing→提现→撤销演练，扫描、账务、授权消费与余额核对后才允许发行地址。此步骤是未来上线工作，不在本次文档任务中广播交易。

构建可复现、浏览器源码验证有助于核对部署，但不能替代合约审计。治理密钥与线上签名密钥分别备份和分持；原始秘密不入部署 manifest、日志或示例配置。

## 5. 运维监控与应急动作

| 信号 | 默认动作 |
|---|---|
| Factory/Implementation/固定绑定不符 | 关闭该版本地址发行和新签名，保留扫描 |
| logs/trace 覆盖缺口、RPC 不一致 | 暂停受影响链入账放行和授权，回填核验 |
| 风险提供方超时/版本过期 | UNKNOWN，停止新 Permit，审查现存授权风险 |
| HOLD 请求长时间未包含 | 升级告警，独立 Guardian lane/备用 RPC，目标池控制 |
| permit 已消费但无本地订单终态 | 禁止重签，回放效果并幂等结算 |
| Treasury/Relayer 未知出金或 nonce 消费 | 暂停相关域，调查所有已签凭据 |
| 原生运营资本不足 | 禁止新费用承诺，明确用户订单等待状态 |
| Batch 单项连续失败 | 隔离资产/任务，停止无限重试与 Gas 消耗 |
| 池遭发行方冻结 | 标记实际不可用流动性，暂停该资产并建立案件 |
| 证据 ACK/完整性失败 | 不交付新签名/地址，RECOVERY_LOCKED |
| 实例锁丢失 | 停新受理及签名，不启动第二在线实例抢执行 |

监控至少涵盖未归集金额/年龄、未部署且有余额、各池在线敞口、签名不确定、授权即将过期、期望与链上 HOLD 差异、KYT 延迟、风险事件到控制包含/最终的时延、金额预留与余额差异、归集单位成本、未知入款及恢复水位。告警不能只看 HTTP 服务存活。

暂停顺序：先本地签名 gate 和调度，再独立链上控制，跟踪未决授权/交易，核对实际去向，最后宣布作用域已控制。恢复顺序：查明原因、核对资产和授权、审批、链上新 epoch 解除最终确认、重建授权、逐级开额度。禁止先恢复任务再补审批。

## 6. 灾备和历史版本

备份包括 PG 完整账本/地址映射、全部 CREATE2 材料、部署 artifacts、角色路由历史、加密平台密钥及离线恢复材料、授权/raw 证据、KYT/案件证据和共同 checkpoint。本地磁盘与 PG 不是原子双写，也不是独立灾难域；异地加密备份、恢复凭据分持和实测恢复演练决定真实 RPO/RTO。

地址材料丢失可能导致无法找到对应用户或无法恢复预计算参数；平台私钥丢失可按治理角色轮换，但治理阈值全部丢失或不可变逻辑损坏未必可恢复。不同故障不能用“换一个 Factory”一概解决：旧地址由原 Factory/init code 决定，新 Factory 无法部署到相同旧地址。

恢复过程首先停止出金，确认数据库和证据水位，恢复映射，回放全部链事实，核对链上授权状态、nonce、控制 epoch 和账链余额，处理未知事实后再开新签名。RPO/RTO 必须按进程崩溃、数据库回退、整机毁损分别实测；未确定并演练前不得声明零丢失或分钟级恢复。

## 7. 旧 EOA 和新合约迁移

如有已发行 EOA：冻结新 EOA 分配 → 导入永久归属和余额基线 → 启用新合约地址 → 对外返回新 current 地址并保留历史 → 双轨监听 → 旧 EOA 通过旧签名/补 Gas 路径归集。旧地址仍可收到充值，不能删除旧密钥或停止监控。

每个旧地址收款事件保留原 scheme，资产移动与新合约记账共享唯一经济效果层；不能导入余额同时又从历史事件全量加余额。切换联合 checkpoint 明确哪些历史已计入。

合约 V1→V2：先部署并验收 V2，只给新发行使用；旧地址逐步经批准 route 或恢复路径迁移，未部署 V1 地址仍依赖原 V1 Factory。活跃提现先在 V1 最终取消或成功结算，再启 V2，绝不能在两个 Treasury 并行签同一笔可付款业务。事故后的程序回滚只回滚二进制，不回滚已发生链/账/授权事实。

## 8. 分阶段实施

| 阶段 | 必须交付 | 完成门槛 |
|---|---|---|
| P0 协议与约束 | 链/资产清单、权限图、ABI/签名向量、部署清单、软件 Vault 威胁模型 | 地址/初始化/路由/恢复依赖无未定义路径 |
| P1 合约闭环 | Factory/Vault/Manager/Risk/Pool/Treasury，批量与限额 | 预充值可回收、越权失败、授权不可重放、取消有效 |
| P2 账务与执行 | PG 约束、索引、两层签名、Hold、最终结算 | 崩溃/重组/重试无重复经济效果 |
| P3 风险闭环 | KYT、案件、Clearing/Disposition、历史重分类和敞口 | 未归集/已归集/已付款三场景完整演练 |
| P4 生产验证 | Gas/容量报告、独立合约审计及修复复审、灾备演练 | 阻断项清零，配置/值班/预算/恢复目标冻结 |
| P5 小额灰度 | 单链少量租户、低限额、真实端到端验收 | 连续对账无未解释差异后分批提高限额 |

Clearing 或 Quarantine 不启用的部署必须在 manifest 明确其路由不可用；不得暴露空地址、未部署目标或“以后实现”的资金入口。首期默认 Clearing 启用；特殊处置能力必须在接收生产资金前经过验收。

## 9. 安全不变量与验收矩阵

| 验收项 | 必须证明的结果 |
|---|---|
| 预测/真实部署 | Rust、Factory、实际地址逐字节一致；提前 native/token 打款不改变归属 |
| 初始化抢跑/伪造 Factory | 任意调用者不能改变 manager/pool，重复初始化失败 |
| 原生接收 | 未部署/已部署、合约发送、2300 Gas 限制行为明确；无自动转发依赖 |
| 归集边界 | 每一笔普通流出都有有效 Permit，目的地属于同租户批准 route |
| 风险竞态 | HOLD 先执行则拒绝，Sweep 先执行则建立池事故，不宣称无条件阻断 |
| 全部资金入口 | 冻结后转冷/rescue/migrate 普通流出也失败；不能仅封提现 |
| 多原因冻结 | 同一 scope 两个案件，解除/特殊处置一个不绕过另一个；重复控制不重复预留 |
| 恶意余额变化 | 新入款/dust/强制转入使普通余额校验失败；不自动扩大授权 |
| 部分失败 | 子项失败不改变该项 consumed；外层回滚时全批无资金效果 |
| Gas/返回数据攻击 | 单项耗尽、巨量 returndata、重入不能绕过边界或无界耗内存 |
| 提现防重放 | 换 Relayer、nonce、签名版本最多一次付款；跨链/合约/类型签名无效 |
| 双层撤销 | 仅取消外层不退款；requestId 最终取消或充分失效证明才释放 Hold |
| 额度/预留 | 同时提交、周期边界、风险底线、原生本金与 Gas 分账户均正确 |
| Clearing | 未成熟/未复审/已释放 lot 不结算，未知直投不获得 lot，HOLD 不被结算绕过 |
| 事后告警 | 能定位原入款→归集→结算→池→下游事件和敞口，保留分摊不确定性 |
| 特殊处置 | 普通 Risk/Relayer 密钥不能调用；阈值、案件、目的、限额、消费均有效 |
| 隔离保管 | 目标控制、预留移动、转账原子提交；受限负债不因移入 Quarantine 减少 |
| 同租户与跨租户 | 数据库关联、链上 pool、凭据域均拒绝错绑；不借另一租户资本 |
| 资产异常 | false/no-return、暂停、黑名单、升级行为有 profile；税/rebase 不被误记 |
| 账本不变量 | 每凭证同资产借贷平衡；归集不增用户负债；Hold 不负，费用仅一次 |
| 恢复与重组 | 签名前后/证据 ACK/广播/结算各点断电，原事实恢复；深重组走冲正案件 |
| 历史版本 | 老地址/未部署地址仍可发现并受控处理；新池不使旧授权重复付款 |
| 权限与运行 | 部署者撤权、离线阈值分持、独立 Guardian 应急路径实际可用 |

实现时使用 Foundry 单元/fuzz/invariant、目标链固定块 fork、PostgreSQL 集成和全流程故障注入；Rust 按仓库 fmt/clippy/test 要求运行。每项交付测试报告、部署哈希、复现步骤和批准记录。性能数字必须来自报告，文档中的示例不构成验证结果。

## 10. 上线配置清单

上线负责人必须签定：网络/genesis/chainId、token 精确地址和 profile、最终性/trace 能力、KYT 来源及故障策略、治理阈值与延迟、Guardian 独立渠道、每资产/池/时间窗额度、热资产与未归集敞口、Permit TTL、Clearing 观察期、Gas/费用预算、用户 SLA、备份保留和实测 RPO/RTO、事故值班与法律处置规则。任何仍为占位值的关键资金参数均阻断生产发行。
