# EVM Wallet Platform v2 合约

本目录按 `docs-v2` 实现独立 v2 合约。2026-10-12 的业务调整以[提现约定](../docs-v2/提现.md)为准：**未归集提现必须同时具备绑定用户签名与平台 `REFUND_SIGNER` 签名，可以指定外部收款地址，不要求原路返回。** 两份签名覆盖同一个 EIP-712 摘要。

实现和后端对接规范见 [EVM v2 实现说明](../docs-v2/evm-wallet-platform-contract-design/20261012-evm-contract-implementation.md)。`contracts-v1` 不参与本目录构建、部署或业务调用。

## 合约组成

| 合约 | 责任 |
|---|---|
| [TenantTimelock](src/control/TenantTimelock.sol) | Council 提案、至少两天的治理等待；没有部署者治理管理员 |
| [TenantAuthority](src/control/TenantAuthority.sol) | 固定租户边界、角色分离、签名版本、全局暂停和一次性组件绑定 |
| [RiskRegistry](src/control/RiskRegistry.sol) | 地址/币种/用户/收款人/来源风险、数量预留和不可回退的风险版本 |
| [DepositFactory](src/deposit/DepositFactory.sol) | 用户签名身份、CREATE2 充值地址、地址轮换、余额检查和退役 |
| [DepositVault](src/deposit/DepositVault.sol) | 用户+平台双签自提、逐来源观察期归集、共享资产 nonce、退役异常资金处置 |
| [HotPoolManager](src/pools/HotPoolManager.sol) | 20/50 个热池、每币种持仓上限、配置 CAS、容量选择和最旧健康池回收 |
| [HotVault](src/pools/HotVault.sol) | 受控入金、Milon 门限提现、独立大额 Council 审批、调拨、转冷和冷地址补仓 |
| [MilonWithdrawalVerifier](src/bridge/MilonWithdrawalVerifier.sol) | 固定 Milon 来源和 App、等权门限证书、换届/紧急撤销及 ERC-1271 验签 |
| [WithdrawalBook](src/bridge/WithdrawalBook.sol) | 所有热池共享经济订单消费/禁付，付款和取消的原子竞态 |

## 构建与验证

从仓库根目录执行：

```bash
rtk proxy bash contracts/scripts/bootstrap.sh
rtk proxy forge build --root contracts --sizes
rtk proxy forge fmt --root contracts --check
rtk proxy forge test --root contracts
rtk proxy python3 contracts/scripts/export_interfaces.py
```

编译器、EVM 与 Foundry 基线见 [toolchain.lock](toolchain.lock)，依赖按 [dependencies.lock](dependencies.lock) 的确切 commit 安装。`lib/`、构建产物、广播记录、`.env` 及本地部署清单不入库。

导出协议包含 [9 份 ABI](interfaces/abi)、[EIP-712 字段与 domain](interfaces/eip712.json)、[跨语言摘要向量](interfaces/vectors.json)。Python 导出器使用标准库及固定版本 `cast`，不依赖另一套 Keccak 包。协议向量测试校验静态 ABI 字段顺序、位宽、domain 与实际 Solidity 摘要。

## 部署与首次激活

1. 在 `contracts` 目录复制 `.env.example` 为本地 `.env`，替换公开标识、链参数、治理账户和角色地址。`GOVERNANCE_COUNCIL` 必须是已部署的治理多签合约。所有币种限额均使用整数最小单位，原生币用零地址。
2. 通过 Foundry 外部账户、硬件钱包或已有安全签名流程签部署交易。脚本不接收助记词、私钥或私钥环境变量。先在目标链 fork 模拟，再广播；部署检查 chainId 和部署者 nonce。
3. 部署输出本地公开清单，包括 Authority、Factory、Manager、两个克隆实现、Verifier、共享 Book 与 Timelock。初始保持归集、出金和桥暂停，没有已启用币种。
4. 将清单中的 Authority 填入激活配置。角色地址与委员会成员必须分离；委员会至少四人、门限严格大于 `2N/3`、地址按数值升序且不重复。币种配置数组严格按 `ASSET_TOKENS` 顺序对应。
5. `PrepareActivation` 生成完整 `scheduleBatchCalldata`、`executeBatchCalldata` 和 `operationId`，先本地模拟全部操作并恢复状态。生成计划不会广播或提前解锁。
6. Council 审阅完整批次后提交 schedule；等待至少两天，再执行原批次。组件配置、成员、币种上限、策略与解除暂停在一笔治理批次中生效，版本过期则整体回滚。
7. 后端和独立节点核对部署代码、配置、Milon 映射摘要及两链终局后，才发布充值地址、发行净归集权益或签发热池付款证书。

在 `contracts` 目录的模拟命令如下。`deployer-account` 表示本地安全账户名称，RPC 从调用方环境提供：

```bash
rtk proxy forge script script/DeployTenant.s.sol:DeployTenant --rpc-url "$EVM_RPC_URL" --account deployer-account
rtk proxy forge script script/PrepareActivation.s.sol:PrepareActivation --rpc-url "$EVM_RPC_URL"
```

实际部署在检查模拟结果后，为第一条命令加入 `--broadcast`。第二条仅导出治理材料，由治理账户按原 calldata 提案。部署不导入冷地址私钥；冷地址只通过独立线下流程签补仓交易。

## 关键资金边界

- 未归集自提：用户签名地址来自 Factory，平台签名只能作为第二份授权；普通 Relayer 不拥有用户签名或平台批准权。EOA 与 ERC-1271 用户均支持。用户私钥须由用户独立控制。
- 地址污染：ACTIVE 充值地址禁归集但保留双签自提。地址轮换不改变用户签名身份，正式 Retired 后禁止自提和归集。正常退役检查全部登记资产，残留强制退役和异常处置属于延时治理权限。
- 归集后污染：冻结受影响热池，停止其受控流入、用户付款、内部调拨和转冷。不能把污染资金自动移入健康热池或冷地址来释放容量。已完成的冷地址转账无法由合约撤销。
- 用户密钥轮换：旧用户、新用户密钥持有证明和平台对同一轮换正文签名；用户 epoch 递增后该用户所有充值地址的旧自提授权失效。没有管理员单方重置用户签名地址的入口。
- 自动归集仍由独立 `SWEEP_SIGNER` 批准，并不要求用户对每次归集再次签名；双签保护自提路径，不覆盖全部平台治理权限。
- 热池付款：跨链委员会独立验证 Milon 成功审批和终局，EVM 验门限、风险、金额与共享订单簿。高额出金另需 Council。EVM 验证的是委员会声明，没有实现 Milon 轻客户端。
- 资产语义：支持原生币及精确转账 ERC20，拒绝扣税/rebase 造成的数量差额；代币发行方冻结无法绕过。外部直接转入可能超额，只停止新增受控入金，不能撤销被动到账。
- 源链事实：EVM 无法读取任意历史 ERC20 receipt。归集来源、到账时间和净分配由 `SWEEP_SIGNER` 认证，独立入账节点再核验；未知来源不自动记入 Milon 权益。

本次交付为 Solidity、测试、公开接口、部署/治理脚本和说明。Milon 权益 App、独立节点签名服务、Rust 桥接 API 与实际链部署仍需在各自系统对接。
