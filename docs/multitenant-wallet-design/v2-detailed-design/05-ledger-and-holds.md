# M05：双重记账、余额、冻结与解冻

返回 [设计总览](README.md)。关联需求：资金余额权威、充值、提现、冻结/解冻与内部划转。

## 1. 职责与计量规则

本模块是资金权威，拥有不可变凭证、分录、事务内余额投影和 Hold。业务模块提出明确记账指令，不直接改余额。链事件提供资产变动事实，消息和 Redis 不提供余额真相。

每项账户属于一个 `tenant_id + chain_id + asset_id`，一张凭证只处理一种资产和一个租户。跨资产 Gas 与服务费分成独立凭证，通过 `operation_id` 关联。没有隐含汇率换算，也没有跨租户余额划转。

API 与链转账金额是最小单位十进制整数，禁止浮点和科学计数。链上单笔金额受 EVM U256 边界限制；多个地址汇总的账本余额可能超过 U256，账本整数类型不能直接复用链金额类型。

## 2. 账户分类

| 类别/账户 | 正常余额方向 | 含义 |
|---|---|---|
| `CUSTODY_ASSET`，按钱包/位置分户 | 借 D | 用户充值地址、热钱包、金库、Gas 池和冷钱包中的资产 |
| `USER_AVAILABLE` | 贷 C | 用户可用负债余额 |
| `USER_HELD_WITHDRAWAL` | 贷 C | 提现付款额与服务费占用 |
| `USER_HELD_BUSINESS` | 贷 C | 租户发行的业务冻结 |
| `USER_HELD_RISK` | 贷 C | 平台风险冻结 |
| `SUSPENSE_UNASSIGNED` | 贷 C | 已收到但不能确认最终受益人的资金 |
| `OPERATING_CAPITAL` | 贷 C | 平台在本租户资金域投入的自有运营资金 |
| `FEE_REVENUE` | 贷 C | 已实现的提现服务费 |
| `GAS_EXPENSE`、`REORG_LOSS` | 借 D | 已发生的网络成本、批准后的链重组损失 |

用户负债：`normal_balance = Σcredit - Σdebit`；托管资产/费用：`normal_balance = Σdebit - Σcredit`。可用与三种冻结负债不得为负。

`PENDING_DEPOSIT` 从充值观测视图计算，未纳入可用负债或正式托管资产账。不得把待确认展示额加到可提现余额。已最终收到但有用户限制的资金可直接贷记风险冻结，并同时创建关联 Hold。

## 3. 表与数据库约束

| 表 | 关键字段 | 约束 |
|---|---|---|
| `ledger_accounts` | `id, tenant_id, asset_id, owner_kind, owner_id, bucket, normal_side, allow_negative` | 所有身份字段非 NULL；账户业务身份唯一；租户+资产+ID 唯一 |
| `journals` | `id, tenant_id, asset_id, business_type, business_id, action, cycle, payload_hash, source_chain_fact_id?, reversal_of?, posted_at, ledger_seq` | 业务记账键唯一；已过账不可变 |
| `journal_entries` | `journal_id, line_no, account_id, tenant_id, asset_id, side, amount` | 行号唯一；组合 FK 保证租户/资产一致 |
| `balance_projections` | `account_id, normal_balance, version, last_ledger_seq` | 与凭证同事务更新，可从历史重建 |
| `holds` | `id, tenant_id, user_id, asset_id, kind, original_amount, open_amount, consumed_amount, released_amount, issuer, linked_order_id, expires_at?, release_policy_version, state, version` | 分解金额相加等于 original；金额非负 |
| `hold_actions` | `hold_id, action_id, kind, amount, journal_id, actor, reason` | `action_id` 唯一，释放/消费幂等 |

`owner_id` 为确定 UUID，不用 NULL 表示系统账户。身份、金额、方向和必需版本字段均为 NOT NULL。组合 FK 将分录与凭证、账户的 `tenant_id + asset_id` 绑定，阻止把另一资产账户放进同一凭证。

金额域建议使用带界限的无固定小数 scale 的 PostgreSQL `NUMERIC`；如下是迁移设计片段，不是完整迁移：

```sql
CREATE DOMAIN ledger_units AS NUMERIC
  CHECK (VALUE >= 0 AND VALUE < power(10::numeric, 96)
         AND scale(VALUE) = 0);

-- journal_entries.amount 为 ledger_units，并加 CHECK (amount > 0)。
-- 交易输入校验在转换/插入前完成，拒绝小数，不能靠 NUMERIC(p,0) 四舍五入。
-- side IN ('D', 'C')；posted journal 至少有两行。
```

链转账还需明确检查 `amount <= 2^256-1`。96 位是工程存储上界，可按容量决策调整；数据库与 Rust 账本整数实现必须使用同一边界，API 输入长度受限以避免超大整数解析消耗。

`post_journal` 是唯一过账入口：验证分录、锁账户、检查借贷平衡、写凭证及投影。数据库提供提交时的平衡/同资产约束与已过账防修改机制。应用角色无直接 UPDATE/DELETE 已过账分录权限；迁移角色不用于线上请求。

## 4. 过账事务与并发

```text
BEGIN
  查业务记账键；存在则比较 payload_hash，完全一致返回原凭证。
  按 account_id 稳定顺序锁定涉及的余额投影行。
  校验 tenant/asset/正常方向，计算整数净变化。
  校验每个受限账户变化后非负，校验本资产 ΣD = ΣC。
  插入不可变 journal 与 entries，更新投影版本。
  同事务更新 Hold/业务订单/额度状态并写 Outbox。
COMMIT
```

没有“先查余额后另一个事务扣款”。同账户并发提现由行锁串行化。重复请求必须验证凭证内容，不能同一业务键不同金额却返回成功。新建账户也用唯一约束幂等，并按稳定顺序取锁。

存储隔离级别初期采用 `READ COMMITTED + 显式行锁 + 唯一键`；遇到死锁或 serialization failure 做有限事务重试，外部调用不在重试事务内。

## 5. 记账模板

以下 `P` 为向外付款金额、`F` 为同资产服务费、`G` 为实际原生币网络费，均为最小单位整数。

| 动作 | 借 D | 贷 C |
|---|---|---|
| 最终充值 D | 用户充值钱包托管资产 D | 用户可用负债 D |
| 新提现占用 P+F | 用户可用负债 P+F | 用户提现冻结负债 P+F |
| 提现成功 | 用户提现冻结负债 P+F | 热钱包托管资产 P；手续费收入 F |
| 安全取消/拒绝 | 用户提现冻结负债 P+F | 用户可用负债 P+F |
| 业务/风险冻结 H | 用户可用负债 H | 对应业务/风险冻结负债 H |
| 引用 Hold 解冻 R | 对应冻结负债 R | 用户可用负债 R |
| 同租户内部转账 T | 来源用户可用负债 T | 目标用户可用负债 T |
| 充值地址归集 S | 金库托管资产 S | 充值钱包托管资产 S |
| Gas 池补原生币 B | 充值钱包原生托管资产 B | Gas 池原生托管资产 B |
| 金库补热钱包 B | 热钱包托管资产 B | 金库托管资产 B |
| 实际网络费 G | Gas 费用 G | 发起钱包原生托管资产 G |
| 平台投入运营资本 C | 相应钱包托管资产 C | 运营资本 C |

归集、补 Gas 和补仓不改变用户负债。发送端与接收端的内部迁移必须在同一凭证确认，不在扫链接收路径再创建用户充值。网络费无论交易成功或链上回滚，都在最终确认后按实际成本独立记录；费用重试只记最终生效的交易族成员。

### 5.1 数值例子

资产精度 6：用户最终充值 `100000000`（100 单位），提现 `40000000`，服务费 `1000000`。冻结后 AVAILABLE 为 `59000000`，WITHDRAWAL 为 `41000000`；成功后冻结归零、用户剩余 59、外部付款 40、平台收入 1。

若支付交易最终失败且未转出资产，释放全部 `41000000`，用户回到 100；原生币 Gas 由平台运营资本承担并记账，不能默默从代币余额扣除 ETH 成本。

## 6. Hold 类型与释放权限

| Hold 类型 | 创建者 | 释放/消费者 | 到期规则 |
|---|---|---|---|
| `WITHDRAWAL` | 提现模块 | 提现状态机 | 不按 TTL 自动解冻，须证明安全 |
| `BUSINESS` | 有冻结 scope 的租户主体 | 同租户且符合发行者权限的主体 | 可配置到期任务，仍需事务内释放 |
| `RISK` | 平台风控/审批模块 | 平台授权审批 | 默认无自动解冻；租户无释放权限 |

`CreateHold(user, asset, amount, kind, issuer, reason, business_id)` 只转移指定用户可用余额。`ReleaseHold(hold_id, release_amount, action_id)` 校验 `release_amount <= open_amount`、发行者权限和状态，写唯一动作及对应凭证。

支持部分释放，Hold 状态为 `OPEN / PARTIALLY_RELEASED / CLOSED`；关闭原因再区分 `RELEASED / CONSUMED / MIXED`。约束：`original = open + consumed + released`。重复动作返回原结果，不新增资金迁移。

### 6.1 账户冻结与金额冻结

账户级提现禁用属于 M01/M08 限制标记；金额冻结属于 Hold。用户被全局风险限制后，新充值应按规则进入风险冻结；已有已签提现不能因账户被限制而直接撤销。待签订单可拒绝并释放到风险冻结而非可用账户，保证限制不被绕过。

业务冻结和风控冻结互不覆盖。需要把业务 Hold 迁到风险 Hold 时，使用明确的迁移凭证并更新两笔 Hold，保留来源与审计，不能只修改 `kind`。

## 7. 凭证纠错与重组

普通未使用资金可用反向凭证冲正，引用原 journal 且幂等。已被提现、内部转账或其他 Hold 消耗的充值发生深重组，不能机械地扣到负用户余额。由 [M12](12-reconciliation-and-recovery.md) 创建差异工单，冻结可追回资金，并对不可追回差额记经审批的损失或其他明确科目。

原凭证保留；冲正和再次确认通过 `cycle` 区分，保证当前规范链事件只有一次有效净入账。任何人工修复必须同时满足资金平衡、Hold 剩余金额和订单关联，不允许单独 UPDATE 投影余额。

## 8. 查询、性能与验收

余额接口从已提交投影读，返回 AVAILABLE、三种 HELD、PENDING 和 `ledger_seq`。资金决策读取主库；读取副本只用于允许延迟的展示，并返回快照序号。列表使用 cursor 分页；用户流水不扫描全租户分录。

账本 Rust 整数实现与数据库 `NUMERIC` 精确转换，避免经 `f64` 中转。热点行锁期间不序列化大事件、不进行 RPC/KMS/HTTP；预构建经过验证的轻量分录，事务后执行外部任务。

- 并发提现与冻结不能使 AVAILABLE 为负；跨租户/跨资产分录无法提交。
- 任意不平衡凭证、重复键不同金额、更新已过账分录均被拒绝。
- 100→冻结 41→成功、拒绝、部分解冻、重复解冻结果与模板一致。
- 三类 Hold 独立统计；租户业务凭据无法释放平台风险 Hold。
- 归集和 Gas 补充改变资产位置/成本，不增加用户余额。
- 投影全量重建与原投影一致；用户冻结投影等于所有未关闭 Hold 的 open 合计。
