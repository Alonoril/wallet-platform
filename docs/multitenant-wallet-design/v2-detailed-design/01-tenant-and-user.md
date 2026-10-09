# M01：租户、用户与访问隔离

返回 [设计总览](README.md)。关联需求：安全接入、租户与用户唯一账户。

## 1. 职责与边界

本模块拥有租户、租户用户、接入主体和版本化业务策略。负责生成可信 `TenantContext` 所需的身份事实，不拥有资产余额、私钥或交易执行状态。地址映射由 [M04](04-address-and-asset-registry.md) 管理，资金状态由 [M05](05-ledger-and-holds.md) 管理。

一个租户用户只属于一个租户。同一外部用户 ID 在不同租户下产生不同的内部用户。平台运营人员身份与租户 API 身份独立，管理操作走 [M13](13-admin-and-audit.md) 的授权入口。

## 2. 数据模型

| 表 | 主要字段 | 约束与语义 |
|---|---|---|
| `tenants` | `id, external_code, status, active_policy_version, version, created_at` | `external_code` 唯一；策略切换带版本 |
| `tenant_users` | `id, tenant_id, external_user_id, status, version, created_at, closed_at` | `(tenant_id, external_user_id)` 唯一；注销后保留映射 |
| `tenant_principals` | `id, tenant_id, kind, status, allowed_scopes` | API 公钥与该主体绑定；无跨租户 scope |
| `tenant_policy_versions` | `tenant_id, version, content_hash, policy, effective_at, approved_change_id` | 版本不可变；策略变化可追溯 |
| `tenant_asset_permissions` | `tenant_id, asset_id, deposit_enabled, withdrawal_enabled, freeze_enabled` | 只能启用 M04 白名单内资产 |
| `user_restrictions` | `tenant_id, user_id, action, reason, issuer, starts_at, ends_at` | 限制开户、提现等动作，不替代金额 Hold |

用户表使用以下身份约束；其他模块对用户引用使用组合外键：

```sql
UNIQUE (tenant_id, external_user_id)
UNIQUE (tenant_id, id)
FOREIGN KEY (tenant_id, user_id)
  REFERENCES tenant_users (tenant_id, id)
```

这样即使程序传入了另一租户的 `user_id`，资金订单也无法建立错误归属。全局唯一 UUID 不能代替租户归属校验。

### 2.1 外部用户 ID 规则

一期建议长度为 1–128 字节、UTF-8、区分大小写，拒绝控制字符和前后空白。接受后按原始字符串持久化，不自动 trim、改大小写或合并 Unicode 等价表示。产品若选择更窄字符集，须作为 API schema 明确发布。

客户注销不释放外部 ID。重新创建该 ID 返回既有关闭状态，防止历史地址、余额和新用户混淆。展示名称可修改，身份键不可修改。

## 3. 状态与动作权限

| 租户状态 | 允许行为 |
|---|---|
| `PROVISIONING` | 配置接入公钥、初始化密钥和钱包；拒绝资金写入 |
| `ACTIVE` | 按权限进行业务；仍受用户、链、资产限制 |
| `OUTBOUND_PAUSED` | 查询、扫描充值、对账继续；禁止新提现、签名许可和出向内部转账 |
| `SUSPENDED` | 禁止租户业务写入；平台继续链监听和事件记录 |
| `CLOSING` | 只允许经批准的清算流程，不新增用户或地址 |
| `CLOSED` | 留存历史、旧地址监听和审计；无常规资金出款 |

用户状态为 `ACTIVE / RESTRICTED / CLOSING / CLOSED`。用户标记为 `RESTRICTED` 时禁止新增提现，实际资金冻结需另创建明确 Hold。一个状态字段不能代替冻结金额与释放权限。

租户暂停后仍可能收到链上充值。扫描事实不得丢弃；能确认归属的资金进入用户风险冻结或待分配负债，具体由已批准策略决定，并通知平台运营。不能将不可阻止的链上入款返回为“系统已拒绝”。

## 4. 接口契约

| 接口 | 参数 | 结果与条件 |
|---|---|---|
| `CreateOrGetUser` | `TenantContext, external_user_id, metadata` | 返回稳定 `wallet_user_id` 与状态；新建可用 201，已有用 200 |
| `GetUser` | `TenantContext, wallet_user_id` | 只返回本租户用户；越权与不存在统一为 404 |
| `ResolveExternalUser` | `tenant_id, external_user_id` | 内部接口，不自动创建用户 |
| `CheckActionAllowed` | `tenant_id, user_id?, action, asset_id?` | 返回策略版本与允许/拒绝原因 |
| `SetTenantState` | 管理命令、理由、审批 ID、预期版本 | 条件更新并产生审计/失效事件 |

`metadata` 有长度与字段白名单，不参与唯一性，不存明文凭据。对于重复请求，不因为 metadata 不同修改身份；更新元信息应使用单独接口和审计。

## 5. 并发开户流程

```text
1. 验证可信 TenantContext，检查租户允许创建用户。
2. BEGIN；锁定租户控制行并确认状态/策略版本。
3. INSERT 用户 ON CONFLICT (tenant_id, external_user_id) DO NOTHING。
4. 在后续语句中读取该唯一用户，锁定需要分配地址的用户行。
5. 调用 M04 的事务内预留接口；需要的资金账户由 M05 幂等创建。
6. 写 user.created/address.requested Outbox；COMMIT。
7. 地址模块异步派生并完成监听准备；查询返回 provisioning 或已激活地址。
```

采用 `READ COMMITTED` 时，发生并发唯一冲突后重新查询已提交记录。不要在一个快照 CTE 中假设冲突的另一事务记录一定可见。已有用户直接返回，不再分配索引。

开户与暂停都按同一租户控制行同步，保证暂停提交后不能有新的开户事务继续通过旧检查。钱包出款还需在签名前复查最新暂停状态。

## 6. SQL 与连接池隔离

所有业务查询显式包含 `tenant_id`；API 使用非表所有者、无 `BYPASSRLS` 的数据库角色。重要租户表启用 RLS，并按需 `FORCE ROW LEVEL SECURITY`。表所有者和高权限角色可绕过 RLS，需要单独约束。[PostgreSQL RLS 文档](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)

```sql
BEGIN;
SELECT set_config('app.tenant_id', $1, true);
-- 参数绑定的租户上下文只存在于当前事务。
SELECT id, status FROM tenant_users
WHERE tenant_id = $1::uuid AND id = $2::uuid;
COMMIT;
```

RLS 规则读取 `current_setting('app.tenant_id', true)`，上下文不存在时不允许返回租户记录。只使用事务级上下文，不在连接上长期 `SET`。Worker 和后台使用不同角色及显式作用域；普通 API 不可选择这些角色。RLS 不能防止持有数据库管理员权限的攻击者。

## 7. 配置和缓存

策略包含：启用网络/资产、地址隔离模式、提现最低金额、手续费策略、限额、审批规则、Webhook 订阅范围。策略只通过审批后切换不可变版本，不在 JSON 中静默覆盖现有值。

低风险查询可缓存租户信息。资金受理在事务内读取权威控制行；签名前复查限制和熔断版本。缓存失效事件是优化，不能作为暂停生效的唯一条件。一个租户策略更新不会改变已批准提现的金额和费用；硬暂停则阻止其后续新签名。

## 8. 异常与性能

| 场景 | 处理 |
|---|---|
| 同用户并发创建 | 唯一键返回同一用户；只产生一次创建事件 |
| 外部 ID 被复用 | 返回已关闭状态，不把旧地址转给新身份 |
| 请求携带其他 tenant_id | 拒绝该字段或校验与认证主体一致；不据此切换作用域 |
| 租户策略缓存不可用 | 资金写入读取 PG；若 PG 不可用则拒绝受理 |
| 租户关闭但仍有入款 | 保留地址归属和链扫描，进入受控清算处理 |

索引以 `(tenant_id, external_user_id)` 和 `(tenant_id, status, id)` 支撑定位与分页。避免查询时加载所有用户或复制完整策略对象；业务请求持有轻量上下文和策略版本。

## 9. 验收条件

- 同一租户同一外部 ID 并发 100 次创建，只有一个用户及当前地址预留。
- 两个租户使用相同外部 ID，内部身份、地址和余额均独立。
- 越权 UUID、连接池复用、缺失租户上下文都不能读取其他租户记录。
- 注销、暂停和策略变更与开户/提现并发时，结果符合已提交控制状态。
- 删除缓存或重放开户任务不改变用户身份与原有地址。
