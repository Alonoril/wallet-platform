# 04 业务流程、账本与持久模型

返回 [总览](README.md)。基础借贷/Hold 约束沿用 [M05](../multitenant-wallet-design/20261009-v2-detailed-design/05-ledger-and-holds.md)，本章给出合约模式的覆盖规则。

## 1. 充值发现与入账

```text
链观测 → 验证网络/资产/永久地址归属 → 去重与覆盖检查
→ 链特定最终性 + 风险评估（独立状态）
→ 最终托管入账至待审查负债
→ ALLOW 转可用；REVIEW/UNKNOWN 保持待审查；HOLD/BLOCK 转风险冻结
→ 独立创建归集候选 → 授权 → 批量执行 → 内部资产迁移
```

未最终事件只作为待确认业务记录，不进入最终资产和可用负债。达到最终性即确认实际托管资产与受限负债，避免因 KYT 故障把真实资产遗漏在账外；ALLOW 与最终性同时满足时可在同一数据库事务完成待审查到可用的两步凭证。未知身份归属使用待认领负债。

ERC-20 监听精确 token 地址的 Transfer，并根据白名单行为核验；不能靠 symbol、第三方网页或任意事件认定到账。原生币需顶层转入和成功执行 trace，排除祖先回滚的内部调用；未部署地址不会发 DepositVault 事件。强制原生余额变化以链适配器可提供的 trace/state diff 与对账识别，无法归因时保留待认领，不杜撰充值事件。

归集、Clearing 结算、金库补仓、Gas 补充全是内部移动；以控制地址注册表和 movement 证据分类，不能在收款侧再记用户充值。用户从本平台提到另一个本平台登记地址应拒绝该外部提现请求，提示使用允许的同租户内部转账；跨租户另立真实结算流程。

采用持久 blockHash/parentHash/canonical 观测与回填游标。ERC-20 经济事件定位以 `(chain, txHash, logIndex)` 为基础，blockHash 保存证据版本；原生转账以规范化 call path 定位，顶层和 trace 去重。重新打包可能改变日志索引/执行结果，必须先撤销旧观测的有效性，再激活新规范事件；不能声称跨重组 event key 天然不变。只有最终事实驱动正式过账，深重组以受审查冲正 cycle 恢复。

每链配置 finality profile：Ethereum safe/finalized 与 L2 的排序器确认、L1 发布及结算条件不得混用；[JSON-RPC](https://ethereum.org/developers/docs/apis/json-rpc/) 暴露标记不代表所有网络有同样保证。trace 缺失、RPC 交叉核验分歧或扫描缺口时暂停受影响资产可用入账及新归集授权。

## 2. 账务模板与数值

| 事件 | 借方 | 贷方 |
|---|---|---|
| 最终充值 100 | Deposit 托管资产 100 | 用户待审查负债 100 |
| 审查 ALLOW | 用户待审查负债 100 | 用户可用负债 100 |
| 审查 HOLD | 用户待审查负债 100 | 用户风险冻结负债 100 |
| Deposit → Clearing | Clearing 托管资产 100 | Deposit 托管资产 100 |
| Clearing → Treasury | Treasury 托管资产 100 | Clearing 托管资产 100 |
| 受理提现 P、服务费 F | 用户可用负债 P+F | 用户提现冻结负债 P+F |
| 最终付款 | 用户提现冻结负债 P+F | Treasury 托管资产 P；服务费收入 F |
| 安全取消 | 用户提现冻结负债 P+F | 用户可用负债 P+F，仍受风险限制时转风险 Hold |
| 链上实际费用 G | 原生币网络费 G | Relayer 原生托管资产 G |
| 未知直接入款 U | 对应地址托管资产 U | 待认领负债 U |
| 同租户金库给 Relayer 补 G | Relayer 原生托管资产 G | 金库原生托管资产 G |

部署费用、失败交易费用和归集费用均是运营成本，不减少用户 token 负债。费用按实际链收费记录；不把 Relayer 补币本金当费用。分配到各 batch item 的成本只用于分析，不能再过一份总账。

例：最终充值 100，风险通过后可用 100；归集两次内部迁移后仍可用 100；提 40、费 1，冻结 41、可用 59；最终成功释放提现 Hold 并减少托管资产 40、确认收入 1。若 20 风险入款另进入同 Vault，用户该 20 记受限负债，链上普通归集按整地址同资产 HOLD。已通过的 100 是否仍可提现由用户/池风控及本租户可用流动性决定，不因账面可用而自动垫付。

金额使用最小单位整数字符串、链金额 U256、PG 使用有显式整数/上界 CHECK 的 NUMERIC；不靠 NUMERIC(p,0) 隐式舍入。资产主键是 `(chain, native/tokenAddress)`。一个凭证限同租户、同资产且借贷相等，分录不可修改；服务费与原生 Gas 为不同资产凭证。

## 3. 两层签名与提现状态机

沿用 [M07](../multitenant-wallet-design/20261009-v2-detailed-design/07-transaction-execution.md) 的 EOA nonce 族和 `SIGNING_POSSIBLE`，但增加独立的 Authorization 事实：

```text
业务：RECEIVED → HELD → APPROVED → AUTHORIZATION_POSSIBLE
      → AUTHORIZED → EXECUTING → FINAL_PAID
                             → CANCELLING → FINAL_CANCELLED

授权：PREPARED → SIGNING_POSSIBLE → SIGNED/UNCERTAIN
      → ONCHAIN_EXECUTED / ONCHAIN_CANCELLED / INVALIDATED_FINAL

外层交易：PREPARED → SIGNING_POSSIBLE → SIGNED → BROADCAST
          → INCLUDED → FINAL_SUCCESS / FINAL_REVERT / UNCERTAIN
```

受理事务一次完成 API 幂等、商户订单唯一、用户 Hold、限额预留及 Outbox。风控通过后锁定精确经济参数，预留 Treasury 物理资金和 Relayer 费用。授权签名前提交 AUTHORIZATION_POSSIBLE；受限签名器重载订单/批准/资产/池/epoch 并独立编码核验，授权密文与证据 ACK 后才交给执行器。

Relayer 外层 `to` 固定为 Treasury，native 提现的外层 `value=0`，付款本金从 Treasury 出；calldata 精确绑定订单授权。Relayer 只预留 Gas，不把用户提现本金误预留在 EOA。软件 Vault 不提供任意 digest 签名接口。

每 EOA/chain 独立 nonce lane，租户之间不共用 Relayer。Guardian 紧急交易使用专用 lane，避免被普通提现低 nonce 卡住；另备独立人工应急广播渠道。签名结果、raw、授权及 permit hash 都是可执行凭据，必须受控加密保存，日志只记引用。

### 3.1 取消与退款判定

| 事实 | 是否可直接释放用户 Hold |
|---|---|
| 在任何授权签名可能发生前，永久撤销本地签名准入 | 可以，事务内确认无其他授权 |
| 外层交易未广播、超时、RPC 查不到、Relayer 被换掉 | 不可以 |
| 外层 nonce barrier 最终上链 | 不可以；相同 EIP-712 授权仍可能被另一交易提交 |
| 外层 revert | 不可以据此证明业务终结；授权未消费，仍可能再执行 |
| Treasury 的 requestId 已最终 CANCELLED | 可以；同时确认无已付款经济效果，停止重签 |
| 已最终 EXECUTED 且效果一致 | 按成功结算，不退款 |
| 已过期/epoch 撤销 | 最终链时间/状态已越过边界、覆盖全部执行记录且未执行、无其他有效授权后可释放 |

优先使用按 requestId 链上撤销作为退款证明。链上取消与付款竞争时谁先生效决定结果。若只用过期，需要最终链的时间已超过 deadline，不能用服务器时钟；重组或事件覆盖不全时保留 Hold。授权取消时永久关闭该业务再授权准入，防止本地任务稍后重签。

同一 Treasury 下的失败重试使用相同 requestId、相同经济参数，可在旧尝试处理清楚后续签；不同 EOA nonce 不是新付款请求。一期对仍可能生效的外层族保持单活执行，费用替换保持经济参数。换 Treasury 必须先在旧域最终撤销、确认未付款并完成迁移审批，不能仅依赖新合约空的 consumed 映射。

## 4. 归集业务状态

`CANDIDATE → SCREENING → PERMIT_POSSIBLE → AUTHORIZED → BATCHED → INCLUDED → FINAL_MOVED`，并列 `BLOCKED_RISK / UNCERTAIN / RETRYABLE / CANCEL_PENDING`。

授权失败或单项 revert 并不证明 Permit 永久不可执行。业务不再需要时撤销 operationId 或相应 epoch，并跟踪最终结果。即使重复归集不会额外减少用户负债，也不能以此忽略风险、资产位置和费用重复执行。后续新充值必须形成新 operationId，不能重用成功授权。

## 5. 数据表与约束

沿用基础租户、账户、journal、Hold、job/Outbox、nonce/tx family 表，新增或扩展：

| 表 | 关键字段及数据库约束 |
|---|---|
| contract_releases | chain、version、部署 manifest、代码哈希、ABI/hash、验收状态；发行后不可改部署材料 |
| custody_pools | tenant、chain、poolKey、riskDomain、各合约地址、routeEpoch；唯一(chain,address)，组合外键绑定 tenant |
| contract_addresses | tenant/user/walletKey/orderId?、chain、factory、salt、initCodeHash、address、pool、version、发行/部署状态、出生高度；唯一(chain,address)、唯一(chain,factory,salt) |
| address_bindings | 永久用户/订单归属、历史版本；长期模式的 current 有条件唯一键，订单模式唯一(tenant,chain,orderId) |
| contract_controls | scope、desired/observed 状态、各 epoch、控制 tx、finality；observed 不被本地请求直接覆盖 |
| deposit_risk_assessments | deposit、provider/version、decision、证据、有效期、扫描 checkpoint；历史追加 |
| risk_cases / case_events | 作用域、责任人、批准 hash、状态、追加事件；跨租户案件以显式多个子案件连接 |
| authorizations | operation/requestId、kind、domain、payloadHash、cipherRef、signingState、epochs、deadline、链上消费证明 |
| authorization_versions | 同业务不同有效期/签名版本；经济 hash 恒定，唯一(domain,businessId,version) |
| sweep_jobs / batch_items | vault/token、operationId、batch/tx family、子项结果；同地址资产只一个可能生效任务 |
| clearing_lots | operationId、asset、amount、released、maturity、risk version；released≤amount |
| custody_movements / movement_links | 实际链上移动、唯一经济效果键、来源事件/分摊量、上下游、确认与冲正 cycle |
| pool_reservations | 资金/风险/未知入款/费用预留、引用、状态、快照水位；不同集合不得重复扣减 |
| incidents / dispositions | 受影响池、资产敞口、处置目的、批准、链上结果 |

全局唯一需求不能被按日期分区稀释；必要时使用独立不分区 registry 保存地址、订单、业务效果唯一键。组合外键 `(tenant_id,pool_id)`、`(tenant_id,user_id)` 防止误绑；应用授权再加 PG RLS 纵深防御。新增 `RISK_PENDING` 是负债科目；原业务 BUSINESS、RISK、WITHDRAWAL Hold 保留，并用 reason 区分法律/风控，不把 SETTLED 当余额科目。

过账事务统一锁序：作用域控制 → 业务聚合 → 按 ID 排序账户 → 额度/预留；唯一 post_journal 校验借贷、租户、资产和非负限制。RPC、KYT、签名、fsync 在短事务外执行，返回后 CAS 版本重校验。关联状态、账务与 Outbox 同事务提交。

## 6. API 与异步通知

延续 [M02](../multitenant-wallet-design/20261009-v2-detailed-design/02-open-api-and-communication.md) 的 TLS/mTLS、请求签名、nonce 与幂等 profile；通信密钥和资金签名密钥分域。

| 接口 | 合约模式行为 |
|---|---|
| POST /v1/wallets | 建用户与账务主体，无需部署合约 |
| POST /v1/wallets/{id}/addresses | 参数 chain、mode=USER/ORDER、订单键；幂等分配并等待发行门槛 |
| GET /v1/wallets/{id}/addresses | 返回 chain/address、current/retired、接收资产范围；明确历史地址仍可能收款 |
| GET /v1/deposits | 分开返回链确认、风控、入账状态及可披露原因 |
| GET /v1/balances | available、risk_pending、各类 held、pending_chain、ledger_seq |
| POST /v1/withdrawals | 返回受理订单，不把 txHash 当最终成功 |
| POST /v1/withdrawals/{id}/cancel | 返回 cancellation_requested；最终结果异步查询/通知 |
| POST /v1/holds 与 release | 仅允许作用域内 BUSINESS Hold，不解除风险或可能付款 Hold |

租户不能传 salt、Manager、路由、calldata、签名 key 或自选 Treasury。KYT 上游不可用时返回可追踪的 pending，不伪造“充值失败”。地址模式发行后不能将旧地址用途重绑给另一个订单。

Webhook 采用持久至少一次投递、稳定 eventId、版本及平台签名，接收方事务去重；包含 `deposit.risk_pending/credited/held`、`withdrawal.paid/cancelled`、`address.replaced` 等语义。不得向业务租户暴露敏感名单源、其他租户信息或调查材料。

## 7. 对账与恢复

联合检查点绑定 chain height/hash、logs/trace 覆盖、registry version、ledger_seq；只在同一规范高度比较 Deposit、Clearing、Treasury、Cold、Relayer 各资产。检查资产总额 = 客户可用与各类受限负债 + 待认领/其他负债 + 运营权益，扣除已确认费用/损失。原生运营资本不能由用户原生负债冒充。

还需对账：预测地址与部署代码、固定参数/角色、Pool 路由与 epoch、链上已消费授权与业务终态、Clearing lot 释放、用户 Hold 剩余量、未知出入款、Relayer nonce、费用只记一次。未知消费或异常 code hash 立即关闭签名 gate。

恢复旧 PG 后先 `RECOVERY_LOCKED`。恢复发行映射、签名证据和配置版本，从共同可靠检查点回放区块并核对链上 requestStatus/consumed；链日志不会包含完整用户映射或链下批准，不能仅靠链恢复这些事实。数据不完整时不开放新地址和出金。深重组对已用余额形成风险缺口，按案件冲正/损失流程处理，不直接改余额。
