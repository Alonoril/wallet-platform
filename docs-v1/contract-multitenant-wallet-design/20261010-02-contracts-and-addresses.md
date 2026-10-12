# 02 地址、合约与授权协议

返回 [总览](README.md)。本章是实现契约，不是已审计 Solidity 源码。

## 1. 确定性地址与发行

地址按 [EIP-1014](https://eips.ethereum.org/EIPS/eip-1014) 计算：

```text
walletKey = 平台 CSPRNG 生成的 32 字节随机标识
salt = keccak256(abi.encode(
  ADDRESS_DOMAIN_V1, chainId, tenantKey, walletKey, uint32(vaultVersion)
))
address = last20(keccak256(0xff || factory || salt || keccak256(cloneInitCode)))
```

`tenantKey` 是不含用户身份的固定租户链上标识；walletKey、salt 不作为秘密或权限。必须保存实际字节，不靠未来代码重新推导恢复。Factory 使用 CREATE2，不能在 Rust 中误用 Implementation 的创建字节码代替 **Clone 的完整 init code**。标准 Clone 的 init code 包含实现地址；初始化 storage 参数本身不自动进入地址哈希，因此下面的 Factory 固定绑定至关重要。

每个 Factory 构造时固定 `chainId、tenantKey、version、implementation、manager、poolId`；没有可由调用者传入的 owner、manager、treasury 参数，也没有改变这些绑定的 setter。`predictVault(walletKey)` 与 `deployVault(walletKey)` 使用相同编码。Factory 校验实际 chainId，拒绝错误网络配置。

发行步骤：

1. 注册部署清单：chainId/genesis 标识、部署区块、Factory/Implementation/Manager/Registry/池地址、runtime code hash、编译器/优化/EVM target、依赖版本、ABI、init code 哈希。
2. 原子幂等分配 walletKey、用户和池，永久保存地址材料；双重核对 Rust 本地预测和 Factory.eth_call 预测。
3. 在批准网络检查代码、固定 getter、角色/路由、Factory 部署能力。发行前该版本已完成真实预充值再部署演练。
4. 保存出生高度，启用监控并回填注册前安全窗口；登记被其他平台用途占用的地址冲突。
5. 发行映射写 PG、加密证据持久 ACK 后设为 `ISSUED`，才允许 API 返回。失败返回 provisioning，重试复用原分配。

区分 `issuance=ALLOCATED/ISSUED/RETIRED`、`deployment=UNDEPLOYED/DEPLOYING/DEPLOYED/ANOMALY`、`risk=CLEAR/HOLD/...`，避免一个 ACTIVE 同时代表已发行、已部署和风控通过。地址有余额而代码为空是正常预充值状态；目标非零 nonce 或已有代码会影响 CREATE2 部署，不能仅依据余额断言冲突。

## 2. DepositVault 与 Factory

采用固定实现的标准 [ERC-1167](https://eips.ethereum.org/EIPS/eip-1167)，一期不使用 Beacon/UUPS 或自定义可变 delegatecall。Implementation 构造器固定 `trustedFactory` 会妨碍跨租户复用，因此本版选择**每租户部署对应 Implementation**，构造器绑定该租户预先确定的 Factory 地址；共享的是源码和发布版本。Factory 地址由已封存部署计划确定并验证，避免循环部署依赖。实现初始化入口仅允许 trustedFactory，Implementation 自身禁用初始化；Clone storage 只写 manager、poolId 与 initialized。RiskRegistry、PoolRegistry 和 DispositionController 作为该租户 Implementation 的固定依赖，恢复入口不经可能损坏的 Manager 查询它们；这些地址同样进入部署清单。

Factory 部署的同一次调用内完成初始化和 getter 校验；任何步骤失败整次 revert，不留可抢占实例。`deployVault` 仅 Manager 或构造时固定的 DispositionController 可调用；同 walletKey 已存在时校验代码和绑定后返回原地址，异常时拒绝。登记 `isVault` 与 walletKey→address，避免用任意传入地址冒充本厂实例。部署可由独立运维任务经 Manager 发起；Manager 失效时可由特殊处置控制器部署，绑定仍为原固定值。部署本身不转移资产，也不赋予执行者资金权力。

最小接口语义：

| 合约入口 | 校验与效果 |
|---|---|
| Factory.predictVault(walletKey) | 只读、可公开查询 |
| Factory.deployVault(walletKey) | onlyManagerOrDispositionController，固定参数原子部署初始化，发 VaultDeployed |
| DepositVault.receive() | 尽量空逻辑，只收原生币；不自动转发、记账或查询风控 |
| DepositVault.sweep(token, destination, amount) | onlyManager、重入保护；再次校验本 pool 当前批准普通路由及 HOLD；仅精确转账 |
| DepositVault.dispose(disposition, signatures) | 特殊处置入口；通过独立 DispositionController 验证，不由普通 Manager 签名替代 |
| DepositVault getters | manager、poolId、初始化标记用于验真 |

`sweep` 参数由已验证 Permit 提供，Vault 再校验 route，不能仅信任任意 destination。它没有 execute、approve、任意 delegatecall、销毁或 owner 提币入口。ERC-20 使用 [SafeERC20](https://docs.openzeppelin.com/contracts/5.x/api/token/erc20) 的安全返回值处理，同时核对源余额减少量和目标增加量均等于 amount；不相等整项回滚。SafeERC20 不替代资产白名单和行为审查。

原生转账用检查返回值的 call，禁止固定 2300 Gas 假设。ERC-1167 的代理跳转可能使上游仅给 2300 Gas 的发送失败，空 receive 也不能保证兼容；准入验收必须测试交易所/合约来源。未部署和已部署地址的接收行为不同，API 说明兼容范围。NFT/复杂回调资产误转不承诺可取回。

## 3. 归集授权

Manager 的 EIP-712 domain 固定 `name=Milon Sweep、version=1、chainId、verifyingContract=Manager`。结构字段顺序与宽度由 ABI 清单封存；Rust/Solidity 共享测试向量。[EIP-712](https://eips.ethereum.org/EIPS/eip-712) 本身不提供防重放，业务必须实现消费和撤销。

```text
SweepPermit {
  bytes32 operationId, tenantKey, poolId, walletKey;
  address factory, vault, token, destination;
  uint256 amount, expectedBalance;
  bytes32 riskDecisionId, evidenceDigest;
  uint256 vaultEpoch, vaultAssetEpoch, poolEpoch, poolAssetEpoch;
  uint256 routeEpoch, signerEpoch;
  uint256 validAfter, deadline;
}
```

`token=address(0)` 代表该链原生币。operationId 是不可复用的随机业务键；`consumed[operationId]` 是此协议的无序业务 nonce，不再增加易混淆的全局顺序 nonce。风险证据摘要绑定链下事实集合，不表示合约验证了 KYT。四个风险 epoch 分别绑定整个 Vault、Vault 本资产、整个池、池本资产，全部须与链上当前值一致，不能遗漏上级作用域撤销。

Manager 每项在同一原子子调用内执行：

1. 校验租户、pool、Factory、walletKey 预测地址以及部署实例；需要时原子部署。
2. 校验 RiskAuthorizer 签名、当前 signerEpoch、时间窗口及未消费 operationId。
3. 查询 RiskRegistry：vault/token、vault 全局、pool/token、pool 全局的 HOLD 和 epoch，任何阻断都拒绝。
4. 校验 PoolRegistry 的同租户普通 route、routeEpoch、目标池未关闭入金，资产准入。
5. 校验实时余额 `== expectedBalance`，一期普通归集规定 `amount == expectedBalance > 0`，该地址此资产的已知全部余额都已最终确认且审查通过。
6. 先标记 consumed，调用 Vault 精确转账、验证余额变化、发 SweepExecuted；失败则子调用全部回滚，消费标记也回滚。

同 `(vault, token)` 仅允许一个在途有效授权，之后新增充值使旧 expectedBalance 不匹配，必须重新扫描和审查，不能自动扩张 amount。余额相等不能证明来源相同，参见 03 的竞态限制。审查通过金额和当前余额不一致时不签名；强制转入、遗漏事件进入对账案件。

## 4. 批量执行与失败隔离

`batchDeployAndSweep(permits, signatures, itemGasCaps)` 入口只允许登记执行者。每项通过 `address(this).call` 调用 `executeSweepItem`；该子入口 onlySelf。批量入口加重入保护，子入口不能重复套用同一 nonReentrant 锁导致必然失败；Vault 有自己的锁。签名、部署、消费和转账都放在子调用内。

每项给固定上界 Gas，受审计的低层调用封装限制返回数据复制长度，例如最多 256 字节的错误摘要，正常结果固定长度。不能直接捕获无限 `bytes reason`，避免 returndata bomb。入口限制总项数、calldata 字节、单项上限、重复 operationId；预留循环和事件开销，考虑 EIP-150 的转发余量，Gas 不足时停止并记录未执行项。

| 结果 | 恢复语义 |
|---|---|
| 单项成功 | SweepExecuted 及 consumed=true；不得再次签新 ID 重做该效果 |
| 单项失败 | ItemFailed 只含错误分类/有限摘要；该项部署也回滚；原授权可能仍可执行 |
| 因 Gas 余量停止 | 未执行项无成功效果；保持原授权与任务关联 |
| 外层整体回滚 | 全部子项成功也回滚；不存在有效成功事件，Gas 仍发生 |
| 已经部署、另次归集失败 | 已部署状态保留，重试只执行归集 |

Batch 不是资金业务键。每个 operationId 独立确认和过账；一批只记一次实际网络费。并行批次按 tenant/chain/pool/token/version 分组，失败资产隔离退避，防止毒任务无限占满队列。调度大小由模拟与链 Gas 上限决定，不能固定“每批 100”。

## 5. RiskRegistry、PoolRegistry 与 Clearing

RiskRegistry 默认无 HOLD，但没有有效 Permit 仍不可归集。存储按 scope/caseId 区分的稀疏 HOLD、活跃原因计数，维护 vault/token 和 pool 级 epoch；不能只用会被单案审批覆盖的一个 bool。设置 HOLD、撤销、解除均单调提升对应 epoch；解除不得恢复旧授权。Guardian 可立即设置 HOLD/提高 epoch，只有满足该冻结原因要求的独立阈值批准可解除指定原因，其他原因继续有效。合约直接调用和运维入口也必须经过相同检查。

`applyPoolAssetHold(pool, token, caseId, minimumReserve)` 同一事务添加原因、提升 epoch 并增加该案件已有预留的下限；重复命令不能重复增加金额，预留按有版本的绝对量保存。相关事件包含 controlId/caseId、scope、epoch、状态和预留。源/目标、全局/资产的所有适用作用域都被检查；完整控制模型见 [03 第 9 节](20261010-03-risk-isolation.md#9-必须落到合约的控制契约)。

PoolRegistry 固定 tenantKey、风险域、普通路由和应急目的地注册。改路由需离线阈值 + 时间锁，变更前暂停，变更时 routeEpoch++；不接受在线 Manager 任意指定目标。目标须属于同租户、批准代码版本、正确池身份；“同租户”由注册表约束，不能只相信目标自报 getter。

ClearingVault 只接受归集资产，不提供用户提现。每项已验证归集调用 Clearing 的受限 `recordLot(operationId, token, amount)`，与转账同一子调用提交，记录入池时间、未释放量。ERC-20 直接打入不会生成 lot。SettlementPermit 绑定确切 lotIds、各释放金额、lot 集合 hash、来源 Clearing 和目标 Treasury 的全局/本资产 risk epochs、route/signer epoch、有效期、operationId；合约同时检查来源和目标当前 HOLD、观察期、未释放余额和资金下限。一次 lot 可以分批释放，但累计不超过登记金额。未知直接入款不增加 lot 或可结算额度。

Clearing 各 lot 在同一地址混合，记录只提供数量和时间控制。发现一项严重风险时默认暂停该池/资产的所有结算，不能宣称其他 lot 对应物理干净资产。观察期按风险域配置且改短需延迟治理；建议先以 30 分钟作为压测和运营评估起点，不作为最终性或安全保证。

## 6. Treasury 提现协议

```text
WithdrawalPermit {
  bytes32 requestId, tenantKey, poolId;
  address token, to;
  uint256 amount;
  bytes32 approvalDigest;
  uint256 poolEpoch, poolAssetEpoch, policyEpoch, signerEpoch;
  uint256 validAfter, deadline;
}
```

Domain 为 `Milon Treasury/1/chainId/具体 Treasury`。Treasury 固定租户/池，提供 `requestStatus(requestId) = UNUSED/EXECUTED/CANCELLED`，底层操作状态在本合约永久保存。不同签名版本或 Relayer 不改变 requestId；平台必须永久绑定金额、资产、收款人，经济参数变更须结束原订单并另行受理。C1.2 实现的 policyEpoch 是本租户/链 PoolRegistry 的共享出金政策版本，限额、安全底线和收款限制变更均提升它；poolEpoch、poolAssetEpoch 另绑定 RiskRegistry 当前值，Registry 设置或解除 HOLD/安全暂停均提升对应版本。执行时所有版本必须匹配并实时检查 HOLD，保证恢复后旧授权不会重新有效。实际字段和 domain 以 [06](20261010-06-solidity-implementation.md) 及源代码为准。

executeWithdrawal 校验当前签名集合、epoch、时间、requestId 未使用、资产/池未暂停、收款人规则、金额以及原生/ERC-20 余额；先记录 EXECUTED、扣额度，再转账验证效果，最后发事件。转账失败整项回滚，原授权仍可能再用。拒绝 to 为零、Treasury 自身或本租户已登记内部托管地址；内部调拨走专门入口。

链上设置每资产单笔上限、UTC 日累计上限及滚动窗口上限，防止日边界双倍突发。限额计数覆盖提现和普通对外流出，跨池迁移不得重置风险域总预算；上线一期禁止活跃提现跨 Treasury 换池。额度提高、窗口缩短和角色扩权须时间锁；Guardian 可降低/暂停。高额提现要求在线授权与独立离线签名共同满足，不能把两把同机在线密钥当成独立审批。

所有普通流出检查 `balanceAfter >= restrictedReserve + safetyFloor`；restrictedReserve 为受治理约束的链上风险/未知入款保留额，Guardian 可增加，减少须有案件/对账批准。特殊处置只能消费签名明确覆盖的预留分配，剩余资产仍覆盖全部其他预留和缓冲，不能套用无条件减预留。链下另外扣除在途物理预留。直接打入的陌生资产在发现到链上预留生效之前存在窗口，因此上限不能仅依赖这一余额检查。

提现、转冷、资产恢复、治理迁移等全部普通资产流出使用同一 Registry 检查与限额/资金底线，不给高权限角色保留绕过风险 HOLD 的迁移入口。不得存在 token approve 或通用调用旁路。

一期提现逐笔执行；批量提现作为后续优化，启用前复用逐项 requestId、授权、额度、失败隔离和恢复验收，不能仅复用归集循环。

## 7. 撤销、特殊处置和不可变版本恢复

`cancelWithdrawal(requestId)` 由限定 CancelController/Guardian 调用，将 UNUSED 变为 CANCELLED；若已 EXECUTED 则拒绝撤销并按成功处理。Manager 对归集 operationId 提供对应永久撤销标记，取消与 consumed 互斥；取消入口在普通暂停时仍可调用。合约检查和付款在链上顺序执行，以最终规范链结果为准。普通 permit 的 deadline、链上 cancellation、epoch 撤销都不能仅靠本地数据库标记代替。

DispositionController 是固定窄接口，仅执行 `caseId + source + token + amount + destination + evidenceDigest + holdSetDigest + scopeEpochs + reserveAllocationsDigest + deadline + operationId` 的离线阈值授权。所有被例外处理的当前 HOLD 和预留分配都须在签名内明确绑定并取得相应批准；单案件处置不能绕过另一案件的冻结。普通 HOLD 可在该明确处置入口下例外移动，但不得绕过 `SECURITY_PAUSED`、其他未获批准预留、资产余额校验、一次性操作和目的地注册；安全暂停的恢复须独立治理流程。默认目的地为同租户 Quarantine，退款/外部指令需逐案登记，禁止通用 call 或 approve。未部署地址也可受控部署后执行处置；Factory 部署不等于解除 HOLD。转隔离池时目标控制、预留位置调整、精确转账在同一链上事务提交；Quarantine 不开放普通支付。

不可变 Manager 缺陷可能阻断归集，预先审计的 DispositionController 路径可以从旧 Vault 向登记恢复池迁移，随后为用户发行新地址。它必须独立校验 RiskRegistry 并在明确案件规则下处理 HOLD，不能成为在线紧急提币后门。若 Vault 实现本身两条路径都损坏，或 token 冻结，不能承诺可恢复。若路由 Registry 缺陷造成两条路径共同失效，同样可能永久锁定；必须作为共享依赖重点审计。

Treasury/Clearing 使用独立治理迁移入口迁往同租户批准新池；先撤销全部出金授权、等待链上最终确认并对账，迁移后才启用新池。旧 requestId 不得直接在新合约重新签发，因为去重映射不会自动跨合约继承。旧地址仍收款，旧版只保留受控收款/迁移能力。禁止依赖 SELFDESTRUCT 原址升级；[EIP-6780](https://eips.ethereum.org/EIPS/eip-6780) 下尤其不能据此设计恢复。
