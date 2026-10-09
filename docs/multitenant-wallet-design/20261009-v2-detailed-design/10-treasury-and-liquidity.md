# M10：金库、冷热钱包、流动性与资金调拨

返回 [设计总览](README.md)。关联需求：租户资金隔离、最优提现钱包选择、归集流动性驱动与 Gas 预算。

> 工程位置：`wallet-core::treasury`；资金预留/调拨与账本共用业务 UnitOfWork。

## 1. 职责与钱包角色

本模块拥有托管钱包角色、物理资金/Gas 预留、流动性预测和调拨计划。用户余额是 M05 的负债，不等于热钱包链上余额；链上资产不足时等待补仓，不能临时借其他租户资金。

| 钱包 | 目的 | 密钥/调拨规则 |
|---|---|---|
| 用户充值地址 | 收款及向金库归集 | DEPOSIT_HD，只签本租户白名单归集 |
| 热钱包池 | 日常外部提现 | 独立 HOT key，单钱包敞口/速率上限 |
| Gas 池 | 补充值地址网络原生币 | 独立 GAS_POOL key，关联归集预算 |
| 在线金库 | 聚集资产与受控补仓 | 独立 TREASURY key，登记目标及更严格审批 |
| 冷钱包 | 大额长期保管 | 本项目二进制人工离线签名，多人业务复核；不被在线调度器直接调用 |

每租户独立钱包。在线金库也属于在线风险资产，不能仅因名为 Treasury 就认为是冷存储。地址和用途登记由 M04 管理，密钥权限由 M03 管理。

若一期不启用离线操作，全部可在线解密的金库都按在线资金敞口控制，不能标为冷钱包。启用时在线仅登记冷地址/公钥，冷秘密及解锁材料不进入在线 Vault；同项目离线命令读取固定批准意图和 Nonce，导出的 signed bytes 由 M07 核对后导入/广播。没有外部冷签名平台、HSM 或 MPC 依赖；多人审批是运营流程，不是链上门限签名。

## 2. 数据模型

| 表 | 字段与约束 |
|---|---|
| `custody_wallets` | `id, tenant_id, chain_id, role, address, key_ref, state, hard_policy_version` |
| `wallet_balance_snapshots` | `wallet_id, asset_id, height, block_hash, amount, coverage_ref, observed_at` |
| `wallet_reservations` | `id, tenant_id, wallet_id, operation_id, execution_id?, asset_id, amount_cap, final_actual_amount?, final_effect_height?, state` |
| `liquidity_targets` | `tenant, chain, asset, horizon, low_watermark, target, high_watermark, max_hot_exposure, version` |
| `rebalance_orders` | `id, tenant, asset, from_wallet, to_wallet, amount, reason, approval_ref, execution_id, state` |
| `operating_funding_orders` | `tenant, chain, native_asset, expected_source, amount, capital_journal_id, state` |

同一操作/执行/资产预留唯一；一个 native 提现的 value 与 Gas 可以分行，但查询必须合计，不能遗漏或重复扣除。fee replacement 使用该 family 的最大批准费用预留，不把所有替代 hash 的费用相加。

## 3. 可用链上流动性公式

所有钱包余额使用最终、已核验的块 H。定义：

```text
available(wallet, asset, H)
  = finalized_snapshot_balance(H)
  - Σ尚未反映在 H 的出向资产/Gas 预留

未最终交易：扣 value/token 预留及费用上界。
已最终、但 effect_height > H：扣实际出向数额及实际费用。
已最终、且 effect_height <= H：不再扣，链余额已反映。
明确未签取消：释放业务 value，保留可能的填 Nonce 费用预算。
```

业务成功结算与钱包快照更新可能不同步。最终付款后不能删除预留记录，再用旧余额快照做新出款；应保存 final effect height/实际金额，直到快照覆盖它。失败交易 value 为零，但已发生 Gas 仍需在旧快照上扣除。

同一 Nonce family 只有一个最终生效成员，因此预留以可能生效成员的最大支出计算。新执行尝试在旧尝试最终结束后再分配独立预算。

创建预留时锁钱包资金行和相关预算，检查余额、用途、硬额度及快照有效期后提交。查询展示可以缓存，可出款判断必须依赖持久化预留。

## 4. Gas 必须由运营资本覆盖

用户原生币负债、未分配资金和运营资本单独记账。保守原生资产预算：

```text
operating_surplus_native
  = 已确认托管原生资产
  - 全部用户原生资产负债（含冻结）
  - 待分配原生资产负债
  - 其他必须保留的原生资产义务

new_gas_budget <= operating_surplus_native
               - 未执行完的费用预留
               - 批准的安全缓冲
```

上式使用一致联合检查点与账本序号，不能拼接不同高度的链余额和当前用户负债。网络手续费消耗原生币，代币服务费收入不会自动变成原生 Gas；需要实际补充原生运营资本。

平台投入原生币先登记 funding order，确认链事实后 `Dr CUSTODY / Cr OPERATING_CAPITAL`。未知来源的金库入款先放待分配负债，不自动假设是平台资本。即使某充值地址已有用户 ETH，仍要验证整体费用资本覆盖，用户余额不因该地址消耗 Gas 被偷偷减少。

## 5. 提现钱包选择

硬过滤：同租户、同网络、HOT 用途、非隔离状态、足够付款资产与原生费用、快照/覆盖有效、无未知 Nonce、单钱包暴露/出向限制满足。

合格钱包按以下信息排序：

| 因素 | 目的 |
|---|---|
| Nonce 队首年龄和 pending 深度 | 避免把所有付款排到堵塞钱包 |
| 剩余可用资产/原生预算 | 减少频繁小额补仓和资金碎片 |
| 当前网络费用及预计等待 | 满足批准的费用预算与 SLA |
| 钱包风险限额与分散程度 | 控制单密钥资产/付款暴露 |
| 租户内公平调度 | 防止一个用户占满全部通道 |

选中后立即以短事务持久预留；并发调度竞争失败则重新选择，不依赖本地缓存“抢占”。不要无上限增加热钱包数量：更多地址带来资金碎片、补仓费用和密钥管理成本。

## 6. 目标流动性与补仓

初期预测采用可解释的历史滑动窗口：

```text
target_free = 已批准但尚未创建物理钱包预留的净付款需求
            + 未来 horizon 尚未受理的新增提现预测
            + 网络拥堵/波动风险缓冲

available_hot 已扣全部现存付款/Gas/调拨预留。
available_hot < low_watermark → 补仓缺口 max(0, target_free - available_hot)。
available_hot > high_watermark 或暴露超限 → 批准回流金库。
```

预测输入为付款 P，不把仍留在托管资产中的服务费 F 当作外部流出；native 网络费用单独包含。已创建物理预留的已知订单只从 availability 扣，不再加入 target_free；只有尚未预留的已批准订单进入已知需求。规划中的入向补仓另从缺口扣除，避免重复生成调拨。

新租户无历史时采用经批准的固定小额目标和人工观察，不伪造 P95。策略记录 horizon、价格有效期和回测结果；预测只调节流动性，不改变用户权益或风控批准。

### 6.1 调拨流程

```text
生成补仓建议 → 检查本租户金库可用余额和目标白名单
→ 创建唯一 rebalance order/资金与费用预留
→ 按额度自动或双人审批 → M07/M03 执行
→ 最终内部转移与 Gas 分录 → 更新快照覆盖/释放预留
```

同一目标/资产的活跃补仓金额纳入预测，不能多个周期重复补足同一缺口。热钱包不足时可提高 M09 归集优先级，但归集先入金库再补仓；若将来支持直接归集至热钱包，必须作为新签名用途/白名单政策审批，不能临时改目标。

## 7. 冷钱包与资金分层

超过在线风险上限的余额转冷钱包，使用严格审批。冷钱包回补包含离线处理 SLA，提前触发库存预警，不把离线资金算作即时热钱包可用。

冷地址通过离线公钥/样本及链观察核验，无法自动在线签名；精确意图/Nonce/批准在导出离线包前登记并进入可能签名状态，回传后核对签名/raw hash 并纳入 M07 跟踪与 M12 对账。未回传或包过期不证明未签名，不能新建第二笔补仓。操作人员不得在线导入冷私钥绕过等待。

## 8. 接口、异常与验收

### 8.1 模块接口与 CustodyFinalizer

| 接口 | 输入与结果 |
|---|---|
| `ReserveWalletFunds` | 事务、租户、wallet、execution、各资产付款/Gas 上界 → 持久 reservation |
| `SelectWithdrawalWallet` | 批准订单、链/资产与最新预算 → 合格 HOT 候选；选中后原子预留 |
| `PlanRebalance` | 租户资产缺口、当前在途补仓、策略 → 幂等调拨建议/订单 |
| `ApplyInternalCustodyEffect` | 最终内部移动证明 → 同事务资产位置迁移、Gas 凭证及预留更新 |
| `PostNetworkFee` | 调用方 UnitOfWork、最终 execution/fee 证明 → 唯一实际费用凭证 |
| `AdvanceWalletSnapshot` | 规范检查点余额 → 原子更新快照并标记已反映预留 |

CustodyFinalizer 是 Wallet Core 内本模块的受限入口，不是新增公开服务。它按 M05 的规范效果键过账内部迁移和网络费；M08 的成功/安全失败事务调用它，Scanner/Tracker 仅提供证明。原生 Gas 的多次观测或多个替代 hash 不能重复生成费用凭证。

| 场景 | 处理 |
|---|---|
| token 充足而 native Gas 不足 | 等待原生补仓，不把 token 余额当作 Gas |
| 公司运营 Gas 不足 | 暂停新费用授权并告警，不侵蚀用户负债担保 |
| 补仓可能已签但结果未知 | 保留预留，恢复原家族，不再次补同缺口 |
| 快照陈旧/覆盖不足 | 暂停自动出款预留，继续链事实恢复 |
| 钱包链上发生未知出向 | 隔离钱包/通道并调查，不重置预留 |
| 租户余额不足 | 队列等待或安全失败，不跨租户垫款 |

监控流动性覆盖、最低 Gas 余额、运营资本盈余、热资产敞口、冷回补时延、预留陈旧、钱包通道阻塞和预测误差。

- 多调度器竞争同一钱包不能超额预留付款与 Gas。
- 快照滞后于最终付款时仍扣实际已支付金额，更新后不重复扣除。
- 替代 hash 不累加全额付款预留；失败与取消仍准确扣实际 Gas。
- token 费用收入不能自动补 native 资本；未知资金不得自动记资本。
- 补仓/回流只在本租户登记钱包内执行，且不改变用户余额。
- 热钱包暴露上限、冷钱包离线 SLA 和跨租户隔离均可验证。
