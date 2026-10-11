# EVM 合约多租户托管钱包生产方案

日期：2026-10-10。版本：C1.2。状态：Solidity 合约端 V1 已实现，接入和部署说明见 [contracts/README](../../contracts/README.md)，验证记录见 06；后台实现、目标链费用/容量报告和独立安全审计仍需完成，满足验收门槛后才能用于生产资金。

采用 **CREATE2 预计算地址 + 固定 ERC-1167 DepositVault + 风控授权批量归集 + 租户独立合约资金池 + PostgreSQL 双重记账**。每个用户充值地址不再需要助记词派生或独立私钥；平台 Relayer 支付部署、归集、提现费用。归集仍然发生链上资产转移，只是取消了向每个充值地址补原生币的步骤。

## 重点：风险资金尚未归集与已经归集

具体实施见 [03 风险资金隔离与事故处置](20261010-03-risk-isolation.md)。风险控制属于首版 P0：

| 状态 | 选定处理方案 |
|---|---|
| 尚在用户地址 | 原址留存；受限入账/账务 Hold + 链上 Vault 本资产 HOLD + 旧授权撤销；包括未部署地址 |
| 已在清算/热池 | 先暂停受影响池本资产的全部普通流出，追溯下游和在途授权；按批准建立预留，决定继续控制或部分恢复 |
| 已有外部付款 | 控制剩余资产、记录义务/可控量/缺口，按案件处理；不重复付款、不让其他租户承担垫付 |

归集、结算、提现、转冷、迁移和恢复共用冻结约束；多案件分别管理 HOLD，解除一个案件不会解除其他原因。资金转入 Quarantine 只改变保管位置，不证明原池风险已消除。

## 阅读顺序

| 文档 | 覆盖内容 |
|---|---|
| [01 总体架构与决策](20261010-01-architecture.md) | 方案选择、旧方案映射、安全边界、资金路径 |
| [02 地址与合约协议](20261010-02-contracts-and-addresses.md) | CREATE2、部署、权限、授权、批量执行、治理恢复 |
| [03 风险资金隔离](20261010-03-risk-isolation.md) | 两种场景的执行步骤、混合余额、池暂停/预留、多案件、特殊处置及闭环验收 |
| [04 业务、账本与数据](20261010-04-flows-ledger-and-storage.md) | 充值、提现、幂等、表约束、对账、API |
| [05 工程、运维与验收](20261010-05-delivery-and-operations.md) | Rust 工程、成本模型、上线门槛、迁移、故障恢复 |
| [06 合约实现与验收记录](20261010-06-solidity-implementation.md) | 已落地模块、签名/控制协议、部署激活、本地验证和生产待办 |

## 依据及采用范围

已读取用户提供的[在线讨论](https://chatgpt.com/share/6ac9da27-8c68-83ee-9caa-b4b6e12084f5)，包括初版合约钱包方案以及后续“风险资金未归集、已经归集”的补充讨论。原始需求保留在[需求和设想](需求和设想.md)。本目录是对讨论的工程化细化，协议、参数选择和验收要求属于本设计新增决策。

保留仓库 [V2.2 基线](../multitenant-wallet-design/web3_multitenant_custodial_wallet_phase1_architecture_v2.md) 的单在线应用、项目内软件 Vault、独立租户资金核算和持久执行恢复；在线讨论中 HSM/MPC、多个 Worker 进程、共享租户池、跨租户内部转账不作为本期依赖。具体差异见 01。旧文档描述 EOA 模式，新合约模式涉及冲突时以本目录为准，未变更的接入、账本基础和通知契约继续引用旧设计。

## 关键生产约束

- 新地址必须在 Factory 已部署且验证通过、扫描覆盖和发行证据持久化后才能公开；预计算不代表可安全收款。
- 普通归集必须有逐笔风险授权、链上 HOLD/epoch 校验、固定路由及精确金额；禁止无条件扫余额。
- 一期每租户、每链独立资金池和在线签名密钥。共享实现代码仍然存在共同漏洞风险。
- EIP-712 授权与 EOA 交易是两类可执行凭据，取消外层交易不能撤销内层授权。
- 原生币和审核通过的 ERC-20 才能入账；未知资产、费税、rebase、带复杂回调资产不自动支持。
- 风险冻结覆盖资产移动；不能阻止外部打款，也不能保证同质化资产按来源物理分离。
- 保留软件 Vault 的主机故障域事实：在线授权密钥在解锁进程内可用，整机失陷可能危及所有已解锁租户。离线治理、链上限额与在线敞口控制必须实际部署。

## 技术核验来源

以下为 2026-10-10 核验的官方资料；标准支持技术机制，不替本项目证明实现安全。

| 来源 | 本方案使用点 |
|---|---|
| [EIP-1014](https://eips.ethereum.org/EIPS/eip-1014) | CREATE2 地址公式、部署冲突条件 |
| [ERC-1167](https://eips.ethereum.org/EIPS/eip-1167) | 固定实现克隆；不等于可升级代理 |
| [OpenZeppelin Proxy](https://docs.openzeppelin.com/contracts/5.x/api/proxy) | Clones 部署/预测与初始化边界 |
| [ERC-20](https://eips.ethereum.org/EIPS/eip-20) / [SafeERC20](https://docs.openzeppelin.com/contracts/5.x/api/token/erc20) | 转账返回值、事件和兼容性限制 |
| [EIP-712](https://eips.ethereum.org/EIPS/eip-712) | 结构化签名及显式防重放要求 |
| [EIP-6780](https://eips.ethereum.org/EIPS/eip-6780) | 不依赖销毁合约后原址重建 |
| [OpenZeppelin Access Control](https://docs.openzeppelin.com/contracts/5.x/access-control) | 角色和延迟治理的实现基础 |
| [Ethereum JSON-RPC](https://ethereum.org/developers/docs/apis/json-rpc/) | 区块、收据、余额和最终性标记 |

适用司法辖区、法定冻结/报告条件由运营方形成法律处置规则；本方案定义证据、审批和执行机制，不从风险分数推导法律结论。
