# EVM 多租户托管钱包合约 V1

本目录实现[合约钱包设计](../docs/contract-multitenant-wallet-design/README.md)的链上业务：预计算充值地址、受控归集、观察期结算、提现、转冷、案件冻结、资金预留和隔离处置。每个租户、每条链部署一套独立合约；首版一套部署对应一个 `poolId` 风险域。

生产默认路径：`DepositVault → ClearingVault → TreasuryVault`；转冷使用本套 `ColdVault`。风险资金留在原址或通过案件授权转入 `QuarantineVault`。

## 1. 目录与工具链

```text
src/common/       精确转账、EIP-712 类型、一次性操作和通用权限
src/control/      权限、时间锁、风险、路由、限额和案件处置
src/deposit/      CREATE2 工厂、固定 ERC-1167 充值 Vault
src/sweep/        单笔/批量部署归集
src/pools/        Clearing、Treasury、Cold、Quarantine
script/           部署、公开 manifest、时间锁激活 calldata
test/             单元、fuzz 和状态 invariant
interfaces/       EIP-712 签名字段定义
deployments/      每环境公开配置与部署证据
```

Solidity **0.8.28**、Cancun、优化 200 次、via IR；OpenZeppelin **5.4.0**、forge-std **1.9.7**，commit 固定在 [dependencies.lock](dependencies.lock)。本次使用已有 Foundry `0.2.0 / 98ab45e`，复现参数见 [toolchain.lock](toolchain.lock)，未更换系统工具链。

从仓库根目录执行：

```bash
bash contracts/scripts/bootstrap.sh
forge build --root contracts
forge fmt --root contracts --check
forge test --root contracts
forge build --root contracts --sizes --skip test --skip script --deny-warnings
```

依赖保存在被忽略的 `lib/`。bootstrap 校验固定 commit 和工作区洁净状态，已有依赖不匹配时退出。构建后的 ABI 在 `out/<Contract>.sol/<Contract>.json` 的 `abi` 字段；也可在 `contracts/` 中执行 `forge inspect --root . VaultManager abi` 导出。

## 2. 业务入口

| 合约 | 主要入口 | 约束 |
|---|---|---|
| `VaultFactory` | `predictVault(walletKey)`、`salt(walletKey)` | 非零 walletKey，固定 chainId/tenant/version/实现 |
| `VaultManager` | `deployVault`、`sweep`、`batchDeployAndSweep` | Relayer 白名单；部署不解除冻结；逐笔风险签名 |
| `ClearingVault` | `settle(permit, lotIds, amounts, online, council)` | 普通结算到 Treasury；lot 到期且未重复释放；迁移必须离线共同批准 |
| `TreasuryVault` | `executeWithdrawal`、`cancelWithdrawal` | 一次性 requestId、收款限制、风险预留和租户共享额度 |
| `TreasuryVault` | `transferCustody` | 只允许登记的转冷/调拨/迁移；与提现共享风险及额度；迁移始终要求 Council |
| `ColdVault` | `returnToTreasury` | 所有金额均需在线和离线共同批准；只能回登记 Treasury；不提供外部付款 |
| `RiskRegistry` | `addHold`、`applyPoolAssetHold`、`setReserve` | Guardian 可冻结或提高预留；按案件独立控制 |
| `RiskRegistry` | `releaseHold`、`setSecurityPause` | Council 逐案解除 HOLD；安全暂停只由时间锁恢复 |
| `DispositionController` | `executeDisposition` | Council 签名绑定完整控制快照；默认只能转同租户 Quarantine |
| `PoolRegistry` | `registerPool`、`setRoute`、`setLimits` | 延迟治理；登记实际代码哈希；修改路由必须先暂停 |
| `PoolRegistry` | `setRoutesPaused`、`tightenLimits` | Guardian 可暂停路由/收紧额度，恢复路由需时间锁 |

`token = address(0)` 表示原生币；全资产冻结另用 `allAssets = true`，与原生币单资产冻结分开。ERC-20 必须在资产白名单中；允许无返回值的标准转账，拒绝 false、转账税、余额差额异常。资产升级、发行方冻结或 rebase 仍需运营侧监测。

ABI 枚举：`PoolKind = None(0)/Treasury(1)/Clearing(2)/Quarantine(3)/Cold(4)`；`RouteKind = Sweep(0)/Settlement(1)/Rebalance(2)/Migration(3)/Disposition(4)`。已部署 Clone 的原生币接收仍有 delegatecall 成本，固定 2,300 gas 的合约付款可能失败，充值方应正常估算 gas，并在目标链验证交易所/合约的付款方式。

所有流出均校验相应权限、签名/业务标识、源和目的地控制、当前版本及精确余额变化。合约没有通用 `call`、任意 `approve`、owner rescue、销毁或可升级入口。ERC-1167 实现锁定初始化，Clone 在 Factory 创建的同一事务内初始化。

### 批量归集

最多 50 项，单项 gas 上限 100,000～2,000,000，单签名最多 4,096 字节，总 calldata 上限 131,072 字节。拒绝批次内重复 operationId；只允许 Manager 自调用执行单项，回传数据最多复制 256 字节。

单项回滚发出 `ItemFailed`，成功项可保留；剩余 gas 不足则发出 `BatchStopped` 并停止。外层交易若最终回滚或 OOG，整个交易仍全部回滚。任务终态以规范链收据、成功事件和 `operationStatus` 为准，不能以外层 transaction success 推断所有项目成功。

归集授权的 `amount == expectedBalance == 实际余额`。签名后新增粉尘会使本项失败，重新评估整个资产余额再授权；不自动扩大授权金额。

## 3. 两种风险资金场景

### 尚未归集

1. 计算 Vault 地址；即使尚无代码，也可 `addHold(vault, token, false, caseId)`。
2. 撤销已签 operationId；链上 HOLD 改变 epoch，旧签名不能在解冻后恢复使用。
3. 资金默认留存原址；普通归集实时检查 HOLD、暂停、预留和版本。
4. 需要隔离时，Council 签署完整 `DispositionPermit`；设置 `walletKey`，Controller 可独立部署 Vault 并转入 Quarantine。

不能阻止第三方向预测地址或已部署合约打款；外部 ERC-20 转账不会调用接收合约的风控逻辑。

### 已归集到清算/热池/冷池

1. Guardian 调用 `applyPoolAssetHold(pool, token, caseId, minimumReserve)`，在一个事务中建立 HOLD 和最低预留。先停止受影响池/资产的全部普通流出。
2. 追溯资金流向，分别控制实际持有资金的池；冻结原 Vault 不会自动冻结下游池。提现、转冷、冷池回款、结算、迁移均检查当前控制。
3. `setReserve` 采用绝对金额和 CAS `version`；重复通知不会累计同一案件金额。不同案件预留相加；重叠义务的分配需运营去重。
4. 普通流出必须满足 `余额 - 转出金额 >= 其他/当前案件总预留 + Treasury 安全底线`。解除某一案件 HOLD 不解除其他案件，也不自动释放预留。
5. 隔离处置把批准的源案件预留迁移，并在 Quarantine 为**全部转入金额**建立预留与 HOLD；转账、预留和 lot 扣减原子提交。其他案件预留保留在源池。
6. 清算 lot 处置须签 `lotsHash = keccak256(abi.encode(lotIds, amounts))` 并同步扣减；无 lot 的直接转账只能从 `余额 - outstanding` 部分隔离，不能借此消耗已登记 lot。
7. Quarantine 释放只允许回登记 Treasury，需所有源/目标 HOLD 已清除、签 `preserveRestriction=false` 并释放相应预留。最终外部付款仍走 Treasury 授权流程。

`sourceControlDigest`、`destinationControlDigest` 绑定全资产/单资产 scope 的 epoch、HOLD 数量/摘要、安全暂停及预留总额；预留更新会提升资产 epoch。新增案件、调整分配或控制变化均使原处置授权失效。Council 审批必须列出快照包含的全部案件和批准范围；单个 caseId 不代表其他案件已批准例外。

处置可以经明确审批例外移动 HOLD 资金，不能绕过 `SECURITY_PAUSED` 或侵占剩余案件预留。隔离只改变保管位置，不证明源池风险已消除。已经外付的资产无法撤回；义务、可控余额和缺口由平台账本持续记录。链上预留超过余额时默认禁止流出，需 Council 根据可控量明确调整，不能静默扣减义务。

## 4. 签名与幂等协议

字段类型和顺序以 [WalletTypes.sol](src/common/WalletTypes.sol)、[PermitHash.sol](src/common/PermitHash.sol) 为准；接入方可读取 [interfaces/eip712.json](interfaces/eip712.json)。所有金额使用资产最小单位的整数；接入方用 BigInt 或十进制字符串编码 uint256，避免浮点读写；编码时 enum `kind` 使用 `uint8`。

| 授权 | Domain name / version | verifyingContract | 授权方 |
|---|---|---|---|
| SweepPermit | `Milon Sweep` / `1` | 本套 Manager | RISK_SIGNER |
| WithdrawalPermit | `Milon Treasury` / `1` | 具体 Treasury | WITHDRAWAL_SIGNER；高于阈值另需 Council |
| SettlementPermit | `Milon Clearing` / `1` | 具体 Clearing | SETTLEMENT_SIGNER；迁移另需 Council |
| TransferPermit | `Milon Treasury` / `1` | 具体 Treasury | TRANSFER_SIGNER；迁移/高额另需 Council |
| TransferPermit | `Milon Cold` / `1` | 具体 Cold | TRANSFER_SIGNER + Council，所有金额 |
| DispositionPermit | `Milon Disposition` / `1` | 本套 Controller | Council |

每个 Domain 都包含当前 `chainId` 和实际合约地址。可通过 `hashSweep/hashWithdrawal/hashSettlement/hashTransfer/hashDisposition` 比对客户端最终 digest。在线签名支持 EOA 或 ERC-1271；Council 必须是独立运营的 ERC-1271 多签，授权字节格式须按实际钱包验证，不等同于拼接若干 EOA 签名。

Permit 有效区间不得超过一小时，建议业务默认五分钟；未来生效和过期均拒绝。签名带 signerEpoch、相关 risk epoch、routeEpoch/policyEpoch；冻结、恢复、路由切换、资产停用再启用、签名者轮换都会撤销对应旧授权。

operationId/requestId 在**具体校验合约**中永久为 `Unused/Executed/Cancelled`；付款、预算消费和事件在同一事务，转账失败全部回滚。取消入口暂停时仍可用，已执行请求不能取消。撤销后重新受理必须生成新 ID。

合约不会识别两个不同 requestId 是否代表同一经济业务。平台必须固定租户归属、金额/资产/收款人及全局业务唯一键；迁移前终结旧 Treasury 的在途提现，禁止跨 Treasury 重新签同一活跃订单。`isInternal` 能识别已部署 Vault 和已登记池；尚未部署的发行地址须由平台发行 registry 拦截为提现目标。

UTC 日额度和保守的最近 25 个小时桶共享于同一 PoolRegistry 的所有 Treasury/Cold；普通提现、调拨、转冷、冷池回款共用计数，迁移不会清零。双向调拨会分别消费预算，需要在资金调度中计入。法定处置走独立授权，不消耗普通支付预算。

## 5. 部署与激活

1. 在支持 Cancun 的目标 EVM 网络选定租户/池标识、已部署的独立 Council、Guardian、Relayer、四类签名者及审核资产。复制 [.env.example](.env.example) 为 `contracts/.env`，填入**公开配置**；全零参数和零额度不会提供可用生产服务。Native limits 用 wei；token 数组顺序与 `APPROVED_TOKENS` 一致，分别使用各资产自己的 decimals。
2. 记录 `EXPECTED_CHAIN_ID` 和部署 EOA 的 `EXPECTED_DEPLOYER_NONCE`。部署专用账户须保持 nonce 不变；11 笔 CREATE 顺序固定，Factory 在第 7 笔，Controller 在第 5 笔，地址相互绑定。部署者不保留管理员权限。
3. 在 `contracts/` 目录使用已配置 keystore 或硬件钱包模拟部署：

```bash
forge script --root . script/DeployTenant.s.sol:DeployTenant \
  --rpc-url "$RPC_URL" --sender "$DEPLOYER" --account "$DEPLOYER_KEYSTORE"
```

审阅交易、配置和 gas 后，实际部署使用同一命令加 `--broadcast --slow`。若交易中途失败，按原广播记录和未占用的 nonce 恢复，不能重新跑脚本创造一套混合地址。秘密不得写入 `.env`、命令参数、manifest 或 Git。

4. 脚本输出 `deployments/$MANIFEST_NAME`，包括公开地址、runtime code hash、chain/tenant/pool/版本和编译参数。该文件标记为 **planned**，模拟与广播都会写入/覆盖；必须与实际收据、代码、固定 getter 和区块逐一核对后归档。新地址发行另需监听覆盖、发行证据和预充值恢复验收。
5. 初始路由暂停、池未登记、普通支付额度为零。核对实际部署后生成激活提案：

```bash
forge script --root . script/PrepareActivation.s.sol:PrepareActivation --rpc-url "$RPC_URL"
```

脚本校验 manifest 对应链、实际代码哈希和相互绑定，输出 `deployments/$ACTIVATION_NAME` 的 `operationId/targets/values/calls/scheduleCalldata/executeCalldata`，不广播治理交易。默认开启 Clearing 路径和内部冷池路径，直达 Treasury 归集默认关闭。

6. Council 以真实多签向文件中 `to` 提交 `scheduleCalldata`，等待至少两天，再提交 `executeCalldata`。整个激活批次原子登记四类池、路由和每资产额度，最后恢复路由。提案内容在等待期变更时须重新排队；不能只修改本地文件。`TenantTimelock` 禁止把延迟降到两天以下。
7. 日后换路由：Guardian 先 `setRoutesPaused(true)`，Council 排队修改和恢复。路由暂停覆盖所有需 route 的资金移动，但**不暂停直接外部提现**；冻结提现/所有池流出必须使用 RiskRegistry 的相应池/资产或全资产控制。

## 6. 验证与生产边界

验证证据及实现与设计的映射见 [06 合约实现与验收记录](../docs/contract-multitenant-wallet-design/20261010-06-solidity-implementation.md)。合约单元与状态验证使用合成密钥、mock ERC-1271 和本地链。

当前交付不包括 Rust 索引器、KYT/KYC 决策、账本、签名服务和租户 API。风险裁定/法律授权由平台形成证据并审批，合约执行控制和移动，不能从链上地址自行识别“黑钱”。资金同质化、交易排序、最终性及发行方冻结的限制仍适用。

上线仍需独立合约审计、实际 Council/ERC-1271 集成、目标链 fork/费用与容量报告、监控、故障和灾备演练。登记池必须是本套审计过的固定代码；不把未经适配的外部 EOA/Safe 当作 ColdVault，否则其直接出金不会受本 Registry 拦截。
