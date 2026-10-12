# M11：事务事件、持久任务与 Webhook

返回 [设计总览](README.md)。关联需求：第三方结果通知、故障重试和资金流程可靠调度。

> 工程位置：`wallet-core::events/jobs` 持久化，`wallet-app::runtime` 启动同进程消费者和 Webhook 任务；没有独立 Worker 部署。

## 1. 职责与交付语义

本模块拥有事务事件的投递、任务租约、回调订阅与重试。业务状态由原模块决定，M11 不因任务失败改变余额或判定链交易失败。

一期采用 PostgreSQL Outbox + 持久 jobs；至少一次交付，业务模块通过唯一键、状态版本和事实证明达到不重复资金效果。队列 ACK、Webhook 2xx 和租约到期都不是资金结算依据。

## 2. 数据模型

| 表 | 核心字段与约束 |
|---|---|
| `outbox_events` | `id, tenant_id, aggregate_type, aggregate_id, aggregate_version, event_type, schema_version, payload, ledger_seq?, occurred_at` |
| `event_dispatches` | `event_id, consumer, state, dispatched_job_id, attempts`；event+consumer 唯一 |
| `jobs` | `id, kind, semantic_key, payload_ref, state, available_at, lease_owner, lease_epoch, lease_until, attempts` |
| `job_attempts` | `job_id, epoch, worker, started_at, finished_at, result_class, trace_id` |
| `webhook_endpoints` | `id, tenant_id, version, verified_url, allowed_events, state, encryption_key_ref?, approved_change_id` |
| `webhook_deliveries` | `event_id, endpoint_id, endpoint_version, state, next_attempt_at, deadline, attempts`；event+endpoint+version 唯一 |
| `webhook_attempts` | `delivery_id, attempt_id, resolved_target, status_code?, timing, result_class` |

事件唯一性为 `(aggregate_type, aggregate_id, aggregate_version, event_type)`，允许一个状态版本产生不同业务事件。已生成的 payload 与 schema version 不在重试时修改；包含最小业务数据，不携带密钥引用和内部风控详情。

## 3. Outbox 原子边界

```text
业务事务：订单/凭证/Hold 更新 + INSERT outbox_events → COMMIT。
分发事务：领取 event/consumer → INSERT 幂等 job → 标记 dispatch → COMMIT。
执行任务：读取语义实体 → 调业务模块恢复同一流程 → 保存结果。
Webhook：创建 delivery → 对已提交事件签名/可选加密 → 外部 HTTP。
```

业务提交成功而分发器宕机时，Outbox 仍在。任务插入与 dispatch 标记必须同事务，否则会丢任务或重复；重复也由语义唯一键挡住。

不以 `published_at` 一个字段表示所有消费者都成功，不在 webhook 失败时重做充值入账。事件留存与归档策略支持补偿查询和审计，过期删除前确认所有必要消费者已处理。

## 4. 租约、fencing 与重试

任务领取在短事务内使用 `FOR UPDATE SKIP LOCKED`，更新 RUNNING、lease_until 并递增 lease_epoch。该机制用于任务队列，不能用来跳过资金行锁检查。[PostgreSQL SELECT 锁规则](https://www.postgresql.org/docs/current/sql-select.html)

```text
READY/RETRY_WAIT → RUNNING(epoch+1)
RUNNING → DONE：只有当前 epoch/owner 可完成。
RUNNING → RETRY_WAIT：明确可恢复错误与下次执行时间。
过期 RUNNING → READY：新 worker 接管同一个语义任务。
明确不可自动修复 → DEAD_LETTER：保留业务实体和工单。
```

本文 worker 是同进程任务实例。心跳续租与完成写入比较 lease_epoch，防止旧任务在长暂停后继续覆盖新状态。fencing 不能撤回已发出的 RPC；资金任务仍必须使用相同 execution/grant/tx family 的幂等协议，不因换任务实例新建付款。进程崩溃后新进程接管原持久任务。

错误分类为 `RETRYABLE_DEPENDENCY / WAITING_POLICY / UNCERTAIN_EXECUTION / PERMANENT_ARGUMENT / MANUAL_REQUIRED`。UNCERTAIN 不把业务标失败；转 tracker/recovery 任务。重试预算、抖动退避、每租户/链并发上限和失败队列防止故障时洪峰。

## 5. 事件契约

关键事件：`user.created`、`address.activated`、`deposit.observed`、`deposit.credited`、`deposit.exception`、`hold.created/released`、`withdrawal.accepted/review_required/submitted/succeeded/cancelled/failed`、`asset.paused`。

```json
{
  "event_id": "00000000-0000-4000-8000-000000000010",
  "event_type": "withdrawal.succeeded",
  "schema_version": 1,
  "tenant_id": "00000000-0000-4000-8000-000000000020",
  "occurred_at": "2026-10-09T08:00:00Z",
  "resource_type": "withdrawal",
  "resource_id": "00000000-0000-4000-8000-000000000003",
  "aggregate_version": 8,
  "ledger_seq": "100001",
  "payload": {
    "external_order_id": "merchant-order-00001",
    "status": "SUCCEEDED",
    "send_amount": "10000000",
    "service_fee": "100000"
  }
}
```

不同聚合之间不保证顺序。同一聚合按版本尽量顺序投递，但接收者必须处理重复和乱序。低版本事件不覆盖高版本状态，缺少版本可以查询资源获取当前事实；账本操作不能由租户重复消费事件执行。

## 6. Webhook 认证与消费

平台使用独立 Ed25519 Webhook key，签名 Profile 类似 M02，覆盖 method、target URI、content digest、content type、`x-wallet-event-id` 和 `x-wallet-delivery-id`。每次尝试使用新的 created/expires/nonce 与 attempt ID，业务 event_id 保持稳定。

Webhook key 封装在 M03 通信 Vault，发送任务仅使用通信签名端口，不能借此取得链签名或私钥。通信 Vault 未解锁时等待并积压告警，不发送无签名通知或明文降级；资金 Vault 锁定不必停止已经具备通信能力的投递。

租户从已认证控制面取得平台公钥及轮换版本，不根据请求里的任意 URL 获取公钥。验签、时效、内容摘要、tenant_id 与 endpoint 绑定全部通过后，接收端事务写入 event_id 去重记录和自身业务状态，再返回 2xx。

HTTP 超时后平台无法知道租户是否已提交；按同一 event_id 重试。租户响应 2xx 只表示接收成功，不改变平台已提交资金状态。需要报文保密的订阅可以用登记的租户加密公钥保护内容，原事件和明文业务身份不变。

## 7. 回调目标验证与 SSRF 防护

endpoint 创建/修改走授权控制面，进行域名校验和挑战确认。只允许 HTTPS，默认 443，拒绝 URL userinfo、未经批准端口和自动重定向。

DNS 解析结果逐个校验，禁止环回、私有、链路本地、云元数据、IPv4-mapped IPv6 绕过和其他保留目标。建立连接时使用已校验 IP，并保留正确 SNI/证书 hostname 校验；重试重新解析和检查，防止 DNS 重绑定。[OWASP SSRF 防护指南](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html)

Webhook 使用专用受限 HTTP client；主机网络规则只放行登记的 PG/RPC 等固定基础设施与必要公网目标。同一进程需要访问 PG，无法给通知 task 声明独立操作系统出站身份；逻辑 client 校验不等于主机被控制后的网络隔离。

投递绑定 endpoint version。修改 URL 不能让正在重试的旧 delivery 悄悄指向新位置；经审批重定向或重放创建新 delivery 并保留关联。回调服务器响应体只限量记录脱敏摘要，不执行其中指令。

## 8. 重试、补偿与订阅

2xx 成功；429/5xx/连接失败按限量指数退避与 Retry-After 调度，4xx 按错误类别进入配置检查或重试策略，不无限重试失效凭据。建议首期投递窗口 24 小时，具体期限与服务约定配置化。

超过期限进入 DEAD_LETTER 并告警；租户可调用事件查询或申请受控重放。重放保持原 event_id 和业务 payload，生成新的投递尝试。投递失败不删除原业务事件。

订阅只覆盖本租户允许事件与公开字段。新增事件类型/schema 不悄悄改变旧版本 payload，提供兼容窗口。endpoint 暂停期间保留可补偿事件，但限制积压容量并告警。

## 9. 模块接口、性能与验收

| 接口 | 输入与结果 |
|---|---|
| `AppendEvent` | 业务 UnitOfWork、aggregate/version、类型/schema、公开 payload → 稳定 event_id |
| `ClaimJob` | kind、worker 身份、租约配置 → job 与新的 fencing epoch |
| `CompleteJob/RetryJob` | job_id、epoch、结果分类 → 条件完成或安排重试，不决定资金终态 |
| `RegisterEndpoint` | 授权租户、URL、订阅范围 → 待验证 endpoint/version |
| `PlanDelivery` | 已提交 event、启用 endpoint/version → 幂等 delivery |
| `ReplayDelivery` | 原 event、批准目标版本与命令 ID → 保持业务身份的新投递尝试 |
| `ListTenantEvents` | TenantContext、cursor、筛选条件 → 本租户公开事件与下一 cursor |

Webhook 挑战和回调是受限外部 I/O；参数校验和 endpoint 版本提交之后执行，不持有业务资金锁。消费者不能把消息 payload 中的 tenant_id 当作新的授权身份。

使用按 kind/available_at/state 的任务索引、分批 claim、有界连接池和每目标并发限制。事件 payload 只编码一次；发送时借用持久字节，不为每次重试重建大业务对象。

监控 Outbox age、任务租约丢失、重试率、死信、Webhook 延迟/ACK、endpoint DNS/证书失败和每租户积压。

- 业务提交后立刻崩溃，事件与任务仍可恢复；重复分发不重复资金效果。
- 租约过期后旧 worker 无权写完成，但其外部调用仍由语义幂等保护。
- 接收端提交成功后响应丢失，重试同 event_id 无重复租户业务处理。
- 同聚合乱序、密钥轮换、旧事件重放都有可验证的接收规则。
- 私网 URL、DNS 重绑定、重定向和 IPv6 绕过均被阻断。
- 死信不改变账本/提现终态，查询和受控重放能补偿通知缺失。
