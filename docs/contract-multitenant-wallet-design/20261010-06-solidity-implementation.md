# 06 Solidity 合约实现与验收记录

日期：2026-10-10。对应 C1.2；实现位于 [contracts](../../contracts/README.md)。此记录区分已实现、已验证与生产前待完成事项，不代表安全审计结论。

## 1. 交付范围

| 设计能力 | 实现 | 当前行为 |
|---|---|---|
| 预计算充值地址 | [VaultFactory](../../contracts/src/deposit/VaultFactory.sol) | 固定 chain/tenant/walletKey/version 的 CREATE2 盐；ERC-1167；预充值后部署；原子初始化 |
| 无助记词充值地址 | [DepositVault](../../contracts/src/deposit/DepositVault.sol) | 固定 Factory/Manager/Controller/Risk/Pool；空 receive；不自动转发 |
| 风险授权归集 | [VaultManager](../../contracts/src/sweep/VaultManager.sol) | 全额精确授权；逐项风险/版本校验；最多 50 项、有界 gas/返回数据 |
| 观察期清算 | [ClearingVault](../../contracts/src/pools/ClearingVault.sol) | lot 数量、部分释放、到期控制；迁移保留原到期时间；隔离时同步扣减 |
| 提现与普通调拨 | [TreasuryVault](../../contracts/src/pools/TreasuryVault.sol) | EIP-712、一次性 requestId、永久取消、收款限制、预留/底线、共享预算和高额离线批准 |
| 离线冷池 | [ColdVault](../../contracts/src/pools/ColdVault.sol) | 回 Treasury 的所有金额必须在线/离线共同批准；无通用执行或外部支付 |
| 案件控制 | [RiskRegistry](../../contracts/src/control/RiskRegistry.sol) | 全资产/单资产、多案件 HOLD、安全暂停、epoch、绝对预留和 CAS version |
| 特殊隔离 | [DispositionController](../../contracts/src/control/DispositionController.sol) | 完整源/目标控制快照、离线授权、案件预留原子迁移、未部署 Vault 的独立恢复入口 |
| 隔离保管 | [QuarantineVault](../../contracts/src/pools/QuarantineVault.sol) | 无普通付款；经解除控制和批准后只可回 Treasury |
| 路由和预算 | [PoolRegistry](../../contracts/src/control/PoolRegistry.sol) | 同套 authority/registry/risk 身份、登记代码哈希、暂停后改路由、共享日/滚动预算 |
| 授权与治理 | [TenantAuthority](../../contracts/src/control/TenantAuthority.sol)、[TenantTimelock](../../contracts/src/control/TenantTimelock.sol) | 四类 signer epoch、Relayer/资产白名单、紧急撤权、至少两天的治理延迟 |
| 部署与激活 | [部署脚本](../../contracts/script/DeployTenant.s.sol)、[激活脚本](../../contracts/script/PrepareActivation.s.sol) | chain/nonce 校验、公开 manifest、实际代码比对、可审阅 schedule/execute calldata |

## 2. 实现中的明确决策

1. 每租户/链一套、一个 poolId 风险域；共享额度放在本套 PoolRegistry，普通提现、调拨、转冷和冷池回款合计。仅部署多个 Suite 不会产生跨 Suite 的共享预算。
2. 原生币用 token 零地址；全资产 scope 用独立 bool 区分。冻结和预留可在 Vault 尚未部署时创建。资金转移后必须另外控制下游池。
3. 默认经 Clearing；生产部署脚本要求观察期至少 30 分钟，这只是初始运营基线，不表示最终性保证。直达 Treasury 由显式 `ALLOW_DIRECT_SWEEP` 提案开启。
4. `routesPaused` 初始为 true；Guardian 可暂停，时间锁可恢复。路线改变和暂停/恢复提升 routeEpoch。直接外部提现不走 route，须用 RiskRegistry 控制 Treasury 流出。
5. 注册池须同时匹配 tenant、poolId、authority、PoolRegistry 和 Factory 实现绑定的 RiskRegistry；登记 runtime code hash，并在路由执行时核对。治理仍须批准实际固定代码版本，不能只根据 getter 自报身份批准任意合约或可升级代理。
6. Cold 使用本套受控合约，回款始终要求 Council；未经守卫适配的外部 EOA/Safe 不作为本协议 Cold 地址登记。Council 自身是独立 ERC-1271 多签，合约不能证明签名者实际离线或分持。
7. Treasury 安全底线只限制 Treasury 流出；清算/冷池/隔离池保留全部案件预留，但不套用 Treasury 的运营底线。否则已批准的隔离释放会被热池底线锁住。
8. 特殊处置默认只允许转 Quarantine，解除后只回 Treasury。首版不提供原路退款、外部法院收款人、任意恢复地址、通用 call 或 approve；这些能力需另行协议、治理和审计。
9. 请求/操作消费记录按具体校验合约保存。全局经济幂等、不同 requestId 的同一业务、迁移后的在途订单终结和未部署内部地址拦截属于平台强制责任。
10. `controlDigest` 包含全部 HOLD scope、epoch 和预留状态；预留改变提升资产 epoch，因此控制快照同时约束预留分配变化。审批证据需列出涉及的全部案件，而非只有 permit 的 caseId。

## 3. 风险资金闭环

### 未归集

`识别风险 → 原址 HOLD/账务限制 → 链上撤销 operationId → 留存/离线批准隔离`。

未部署地址同样受控；恢复 HOLD 后 epoch 不倒退，旧归集授权仍失败。Controller 独立于 Manager 部署受控 Vault，转入 Quarantine 时为全部转入量建立 HOLD 和预留。外部可以继续转入，新的余额会使全额旧授权失效。

### 已归集

`受影响池/资产 HOLD + 最低预留 → 追溯其他池和外付 → 案件批准 → 隔离/有预留的部分恢复`。

多案件 HOLD 分别解除、预留分别计量；普通付款不能侵占剩余预留。控制快照变化撤销原处置授权，安全暂停不能被处置签名绕过。转 Quarantine 不自动解除源池风险。

Clearing 处置已登记资产时扣减指定 lot；无 lot 的直接转账可从余额超出 outstanding 的部分隔离，既不自动入账，也不消耗已登记 lot。余额不足、发行方冻结或已有外付均不能由合约逆转；义务和缺口继续记在账本。

## 4. 验证记录

### 工具与构建

- Solidity 0.8.28、Cancun、via IR、优化 200 次，bytecode hash none。
- Foundry 本机基准为 `forge 0.2.0 (98ab45e)`；工具和依赖参数已记录在 `contracts/toolchain.lock`、`dependencies.lock`。
- `bootstrap.sh` 固定 commit 校验通过；`bash -n` 通过。
- `forge fmt --root contracts --check` 通过。
- 检查 10 个相关 Markdown 文档的代码围栏和 48 个相对文件链接，以及五种导出 EIP-712 类型与源代码的字段一致性，均通过。
- 所有手写 Solidity 源文件与脚本均完成编译；生产合约 runtime 均低于 24,576 字节。

`forge build --root contracts --sizes --skip test --skip script --deny-warnings` 通过，部署合约 runtime 大小如下；这是字节码大小，不是运行 gas：

| 合约 | 字节 |
|---|---:|
| VaultFactory / DepositVault | 2,117 / 2,758 |
| VaultManager | 7,385 |
| ClearingVault | 9,883 |
| TreasuryVault / ColdVault / QuarantineVault | 8,994 / 6,593 / 1,922 |
| RiskRegistry / PoolRegistry | 5,539 / 6,859 |
| DispositionController | 6,748 |
| TenantAuthority / TenantTimelock | 3,142 / 5,586 |

### 自动验证

`forge test --root contracts`：**57 项通过，0 失败，0 跳过**。

| 套件 | 项数 | 主要覆盖 |
|---|---:|---|
| DepositAndSweep | 10 | Token 无原生余额预充值部署、原生币、初始化越权、未部署 HOLD、粉尘、失效授权、金额守恒 |
| Batch | 4 | 大返回数据、单项 OOG、重复 ID、外层 gas 安全停止及 self-only 入口 |
| RiskRegistry | 6 | 多案件独立、全资产控制、Guardian 边界、绝对预留/CAS、重复通知 |
| ClearingAndDisposition | 12 | 观察期、迁移保留到期、lot 释放、未知余额隔离、完整快照、预留迁移、安全暂停、Quarantine 释放 |
| Treasury | 11 | 单次付款、取消终态、共用额度、跨日窗口、余额/预留/底线、重入、失败原子回滚、发行方冻结 |
| GovernanceAndCustody | 8 | 真正 schedule/execute 延迟、禁止降延迟、原子激活、身份隔离、受控迁移、独立 EIP-712 编码、跨链防重放 |
| Cold | 3 | 转冷与回款、所有回款离线批准、冷池 HOLD/隔离、原生币和拒绝外部收款 |
| WalletInvariant | 3 | 资金守恒/付款累计、多案件和预留、失败原子性、至多一次与永久取消 |

两个 fuzz 属性各 256 轮；三个状态 invariant 各 128 轮 × 深度 32，即各 **4,096 次状态操作**，handler 未发生未捕获回滚。状态验证交错充值、案件冻结/解除、预留变更、取消、提现和时间推进，不等同于全系统或目标链验证。

本地 Anvil（chainId 31337）脚本演练通过：

- `DeployTenant` 成功发送 11 笔部署交易，并创建固定 DepositVault 实现，输出公开 manifest。
- `PrepareActivation` 成功按实际代码/绑定生成 16 项激活 calldata（本次只配原生币，未配置 ERC-20）。
- schedule 收据 status `0x1`；时间未到时 execute 的 `eth_call` 被拒绝。
- 本地推进 172,800 秒后 execute 收据 status `0x1`；`routesPaused=false`、Cold 已登记、`isOperationDone=true`。
- 本地操作 ID：`0x88516b31a8cff7060f88bbb0c196258d51425a5607754d094066431cf478e868`。本地 JSON、广播收据和环境配置被 Git 忽略，不作为生产部署记录。
- 演练结束已停止本次启动的本地 Anvil 进程。

测试 Council 是仅用于验证的单签 mock，不能用于生产；本地 RPC 的 impersonation 不代表真实多签流程。未向公网链广播。

## 5. 生产前剩余验收

- 独立审计及修复复审，覆盖时间锁自调用、ERC-1167 初始化、EIP-712/1271、批次 gas、有界返回数据、预留/lot/多案件及所有资金出口。
- 实际离线 Council 的签名格式、门限、角色、恢复和部署治理集成；验证每资产限额、观察期、金额单位及紧急控制。
- 批准目标链的固定块 fork、真实审核 token、预充值后部署、原生接收行为、费用和容量报告；本文本地测试 gas 不是目标链报价。
- Rust/PG 账本、发行 registry、监听与重组恢复、KYT/KYC 决策、案件证据/审批、唯一经济效果和授权撤销服务。
- 部署收据和代码核对、源代码验证、上线监控、冻结竞态、密钥轮换/撤权、故障及灾备演练。

实现接入、签名字段、公开配置、实际部署和时间锁激活步骤统一见 [contracts/README](../../contracts/README.md)。
