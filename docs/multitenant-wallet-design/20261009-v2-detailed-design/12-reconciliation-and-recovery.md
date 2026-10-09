# M12：账链对账、异常修复与灾备恢复

返回 [设计总览](README.md)。关联需求：资金可证明、重组恢复、签名不确定与密钥/数据库灾备。

## 1. 职责与检查层次

本模块拥有对账检查点、差异工单和恢复流程。它只能提出/审批明确的修复指令，不能直接修改账本余额、订单或签名日志。修复执行由 M05/M07/M08/M13 各自负责。

| 层次 | 验证 |
|---|---|
| 账本结构 | 每资产借贷平衡、已过账不可变、投影与历史一致 |
| 业务占用 | Hold open 合计等于对应冻结负债；提现/归集与预留一致 |
| 链上资产 | 同块同 hash 的地址余额等于对应托管资产账 |
| 权益担保 | 托管资产足以覆盖用户与待分配负债，费用由运营资本承担 |
| 执行事实 | 每个可能签名许可、Nonce、raw transaction、订单都有闭环 |

## 2. 联合检查点

不能把 current 链余额与不同高度账本直接相减。联合检查点字段：

`chain_id, height H, block_hash, scanner_policy_version, address_registry_version, all_coverage_refs, ledger_applied_seq, snapshot_id`。

生成条件：所有承诺的区块/日志/trace 扫描覆盖至 H；H 已满足网络最终性；该范围的入向、出向、内部转移和费用事实均被分类、过账或明确列为隔离差异；账本在确定序号形成一致投影快照。

链来源的 journal 保存 `source_chain_fact_id`，可追溯到高度与 hash。finalizer 和 snapshot 协调水位，避免在检查点生成时混入尚未对齐的更高块资产效果。快照不要求暂停全部用户查询，但必须具有确定事务视图和处理序号。

RPC 在 H 查询原生余额和 token balanceOf；支持 [EIP-1898](https://eips.ethereum.org/EIPS/eip-1898) 时绑定 blockHash/规范要求。不支持时，按高度查询前后核对 hash 和供应商结果，发现变化废弃此次比较。历史状态不可用时不能用 latest 代替 H。

## 3. 对账数据与公式

| 表 | 字段 |
|---|---|
| `reconciliation_runs` | `id, tenant_id, chain_id, checkpoint_id, state, started_at, completed_at` |
| `reconciliation_items` | `run_id, wallet_id, asset_id, chain_amount, ledger_amount, diff, classification` |
| `reconciliation_issues` | `id, severity, affected_scope, evidence_refs, root_cause, state, owner, pause_ref` |
| `correction_plans` | `issue_id, proposal_hash, journals_to_post, affected_holds/orders, approval_ref, executed_at` |
| `recovery_sessions` | `id, environment, recovered_checkpoint, signer_log_watermark, manifest_watermark, state, approvals` |

```text
wallet_diff = chain_balance(wallet, asset, H) - ledger_custody(wallet, asset, seq)
tenant_diff = Σ本租户各托管钱包 wallet_diff
backing_surplus = Σ托管资产 - Σ用户 AVAILABLE/HELD 负债 - 待分配负债
projection_diff = 已提交投影 - 从不可变分录重建结果
hold_diff = 对应 HELD 投影 - Σ同类型 Hold.open_amount
```

内部归集在最终链事实入账时同时迁移资产位置；对账不再把 pending 归集额加作第二份资产。M10 出款可用性计算需要扣预留，但真实链资产对账不额外减用户提现 Hold，避免混淆资产位置与资金占用。

普通最小单位金额差异容忍为零。RPC 精度、代币 rebase 或未支持协议变化不是自动调整余额的理由，应成为分类差异。

## 4. 调度与差异处置

出款前检查相关钱包快照、资本和预留；持续增量对账每个最终块；定期全量对账与投影重建的频率依容量确定。先单链验证，再扩大地址/租户范围；检查点和未覆盖清单必须可查看。

| 差异 | 自动处理边界 |
|---|---|
| 已保存链事实但凭证未完成 | 调用原业务模块按同记账键幂等完成 |
| 扫描范围缺失 | 从可靠水位补扫，不先改余额 |
| Webhook/任务积压 | 重试/重放，不回滚账本 |
| 未知入向资金 | 隔离归属，核验后记待分配或明确用户负债 |
| 未知出向/重复付款疑点 | 暂停相关授权，保全签名与链证据，人工调查 |
| 代币行为变化 | 暂停该资产自动入账/出款，重新评估 Profile |
| 账本投影损坏 | 只读/暂停资金写入，重建后与凭证及订单核对 |

差异不能由“账本少就加余额”或“链余额少就扣用户”自动消除。修复计划保存前后检查点、每个凭证、业务影响和审批 hash，幂等执行后重新对账关闭工单。

## 5. 深重组资金处理

1. 暂停相关链/资产的新提现与普通签名授权，仍继续扫描和追踪已有签名。
2. 找共同祖先并保存两分支证据，重建入款、内部迁移、出款和费用的规范链效果。
3. 区分仅地址位置变化、真正资产短缺、付款效果消失和原交易仍可能再执行。
4. 未使用资金可反向凭证冲正；已消耗资金先冻结可追回部分，不制造负 AVAILABLE。
5. 经财务/风险审批记损失或明确可执行债权，并处理有关 Hold/内部转账关联。
6. 重新包含的经济效果按 M06 credit cycle 处理，避免原信用未冲正却再加一遍。

例如原充值 100 已有 40 支付，仅剩 60 可追回，若最终确认托管资产短缺 100：可借记可追回用户负债 60、重组损失 40，贷记经核验的托管资产差额 100。实际修复还须重建资产位置并调整关联 Hold；不能把原已清空充值钱包简单扣成负资产。

若一笔已结算提现在新分支消失，旧 raw transaction 可能仍可生效，不应立即再用新 Nonce 付款。恢复同一交易族、Nonce 证明与业务结算由 M07/M08 联合处理；最终性已破坏时的例外需独立审批。

## 6. 备份对象与持久性目标

| 对象 | 要求 |
|---|---|
| 业务 PostgreSQL | WAL/PITR、加密备份、故障域隔离；验证完整凭证和业务状态恢复 |
| 地址发行清单 | 独立持久记录 tenant/user/external ID、root/path/index/address、网络出生高度；发行地址前确认清单落存 |
| Vault/密钥恢复包 | 离线加密副本，passphrase/解封权限分离，双人恢复 |
| 独立签名/许可日志 | 不丢失已生成签名、业务身份、精确载荷和许可消费；可校验远程审计水位 |
| raw transactions | 受控加密备份，可恢复完整同 Nonce 交易族 |
| 配置及审计 | 版本化链/资产/风险/钱包政策、审批、暂停 epoch 与远程审计检查点 |

生产正常故障模型目标为已确认账本事务 RPO=0，需要 WAL 同步持久化、同步副本和禁止提升陈旧副本的配置及演练证明。跨地域全毁等超出该故障模型的恢复能力另行定义，异步备份不能宣称天然 RPO=0。

先以查询恢复 30 分钟、安全出款恢复 4 小时作为演练目标，实测后批准；安全检查未完成不能因 RTO 到点强行开启提现。若不可恢复的账本窗口存在，保持人工差异处理，不能仅靠链扫描重建没有上链的内部转账。

## 7. 冷启动/灾备恢复屏障

```text
RECOVERY_LOCKED：禁止资金受理和新签名许可。
→ 恢复 PG/Vault/config 与最后可靠审计检查点。
→ 核对独立签名日志，导入备份之后已签 execution/业务订单。
→ 核对地址发行清单，恢复用户映射，索引游标取所有证据最大值+1。
→ 按各根/网络出生高度补扫，恢复规范链与执行家族。
→ 核对钱包最终 Nonce、未知消费、余额、Hold 和账本投影。
→ 完成联合检查点与差异处置，独立审批解除恢复屏障。
```

只拥有 HD 种子不等于能恢复“某索引属于哪位租户用户”；不能仅用 BIP44 gap limit 发现法重建平台地址映射。已发行清单必须在 M04 激活地址前持久备份。

签名日志保存稳定业务操作键，恢复时对同租户商户订单不能因重新生成 UUID 又签一次付款。旧签名许可和 raw bytes 在链上是否仍可生效，是恢复判断的一部分。

## 8. 密钥泄露响应

按 scope 暂停许可、撤销受影响机器身份、隔离 key version，记录最后可靠签名/链事实水位。经独立授权把可控制资金转往新安全地址，轮换根与热钱包，继续监测旧地址入款。

更换 KMS KEK 不废止已泄露链私钥；用户旧地址无法通过数据库修改使攻击者失去控制。应明确通知地址切换及旧地址风险，并保留可审计应急迁移。

## 9. 接口、性能、告警与验收

### 9.1 模块接口

| 接口 | 输入与结果 |
|---|---|
| `CreateCheckpoint` | 链覆盖/最终性、registry version、ledger seq → 可核验联合快照或未满足原因 |
| `RunReconciliation` | 租户/链/资产范围、checkpoint → 差异条目和工单，不直接改余额 |
| `ProposeCorrection` | 工单、链/业务证据 → 不可变修复计划和凭证/Hold 影响 |
| `ExecuteApprovedCorrection` | 审批 ID、计划 hash、预期版本 → 调用各事实所有者幂等执行 |
| `StartRecovery/UnlockRecovery` | 备份水位、独立日志、发行清单与审批 → 恢复屏障状态 |

地址/资产分片读取，复用区块检查点和增量分录，不每次对所有历史凭证求和。大规模投影重建在隔离快照/影子表完成，验证后受控切换。

P0 告警：未知出向、投影或 Hold 差异、用户负债担保不足、深重组、签名日志缺口、恢复时未知 Nonce。扫描迟滞、通知积压等有独立告警等级。

- 同高度同 hash 比较无差异，混用高度时主动拒绝生成通过报告。
- 包含归集/补 Gas/失败 Gas 的检查点资产与总账一致，不重复算在途金额。
- 投影/任务/回调故障分别恢复，不修改已过账历史。
- 恢复旧 PG 后能够发现独立日志中的已签交易，不能重新付款。
- 地址发行清单恢复后索引不回退，旧用户地址归属正确。
- 深重组损失处理不生成负可用余额，再次包含不会重复净入账。
