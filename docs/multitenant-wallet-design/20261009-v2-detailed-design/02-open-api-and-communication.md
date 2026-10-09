# M02：开放 API、安全集成与通信

返回 [设计总览](README.md)。关联需求：第三方通过加密 HTTP API 集成，资金指令可认证、可防重放、可幂等。

## 1. 职责与处理顺序

本模块负责请求身份、权限、传输/报文协议、业务幂等入口和错误契约。用户与权限事实来自 [M01](01-tenant-and-user.md)，资金操作调用 [M05](05-ledger-and-holds.md)/[M08](08-withdrawals-and-risk.md)，回调由 [M11](11-events-webhooks-and-jobs.md) 执行。

```text
连接限流与 TLS/mTLS → 大小/编码检查 → 获取本地已登记 kid
→ RFC 9421 验签与有效期检查 → 原始内容摘要校验
→ 防重放占用 → 可选 JWE 解密 → schema 校验与业务摘要
→ scope/租户/用户授权 → 数据库幂等事务 → 业务受理
```

公网 Gateway 不改变请求内容、路径或查询参数。Wallet API 中间件完成验签，从公钥所属主体产生 `TenantContext`；忽略公网传入的内部租户上下文头。内部跳转通过 mTLS 绑定服务身份，外部 URI 的重建只信任指定网关，防止伪造 forwarded 头。

## 2. 接入与密钥生命周期

1. 平台审批并建立租户，租户在自己的服务端生成 Ed25519 接入密钥；私钥不上传平台。
2. 登记公钥、允许 scope、来源约束和有效期，平台分配不可猜测但不视为秘密的 `kid`。
3. 为资金写接口登记 mTLS 客户端证书或可信 CA，并绑定同一租户主体。
4. 在测试环境验证签名向量、重复请求、Webhook 接收、订单查询和时钟偏差。
5. 经批准启用生产凭据；生产与测试密钥、域名、账本和链注册表分离。

密钥状态 `PENDING → ACTIVE → RETIRING → REVOKED`。轮换可允许旧新公钥短时并行，撤销立即禁止新请求；已受理订单仍按状态机处理。不能因撤销 API key 直接删除已签交易或解冻其余额。

`api_keys` 保存 `kid, tenant_id, principal_id, public_key, algorithm, scopes, state, not_before, expires_at, version`。算法绑定登记记录，客户端 `alg` 不得改变公钥用途。用户 API 密钥与平台 Webhook 签名、JWE 加密密钥分离。

## 3. 签名 Profile

采用 [RFC 9421](https://www.rfc-editor.org/rfc/rfc9421.html) 的 HTTP Message Signatures，内容摘要使用 [RFC 9530](https://www.rfc-editor.org/rfc/rfc9530.html)。固定 Profile，禁止客户端选择少签关键字段。

| 项目 | Profile 规则 |
|---|---|
| 算法 | 登记并固定 `ed25519`，单一签名标签 `wallet` |
| 派生组件 | `@method`、`@target-uri`，绑定网络域名及完整查询 |
| 有请求内容的组件 | `content-type`、`content-digest`，摘要使用 SHA-256 |
| 资金写组件 | `idempotency-key`、`x-wallet-request-id` |
| 签名参数 | `created, expires, keyid, nonce` 必需，算法与登记一致 |
| 有效窗口 | 建议上限 300 秒、未来偏差上限 30 秒，作为版本化部署参数 |
| nonce | 每次 HTTP 尝试独立的至少 128-bit 随机值 |
| 报文限制 | 一期建议最大 64 KiB，资金 API 不支持压缩内容和重复关键头 |

如下只展示头部结构；时间、摘要和签名均须由 SDK 真实计算：

```http
POST /v1/withdrawals HTTP/1.1
Host: wallet.example.invalid
Content-Type: application/json
Content-Digest: sha-256=:<base64-digest>:
Idempotency-Key: merchant-order-00001
X-Wallet-Request-Id: req-unique-00001
Signature-Input: wallet=("@method" "@target-uri" "content-type" "content-digest" "idempotency-key" "x-wallet-request-id");created=<unix-seconds>;expires=<unix-seconds>;keyid="kid-example";nonce="random-example";alg="ed25519"
Signature: wallet=:<base64-signature>:
```

无内容的 GET 使用独立 Profile，不要求伪造空 JSON。URI 按规范提取，不自行排序查询参数再验签。拒绝重复 JSON 键、歧义路径、重复签名标签和无法确定唯一语义的关键头。

## 4. 防重放与业务幂等

### 4.1 防重放

资金写请求在 PG 写入 `api_replay_nonces(kid, nonce, expires_at)`，`(kid, nonce)` 唯一。完成密码学和时效验证后才占用 nonce，避免未认证请求制造存储负载。nonce 保留到 `expires_at + clock_skew` 后清理。

PG 不可用时资金接口拒绝受理。Redis 可加速已使用 nonce 的拒绝，但不得成为资金接口的唯一防重放记录。一次请求的 nonce 即使业务事务失败也已使用；客户端重试应换 nonce 和 request ID，保留原业务幂等键。

### 4.2 幂等原子性

`api_idempotency` 字段：`tenant_id, operation, idem_key, business_hash, resource_id, original_status, response_schema_version, created_at`，唯一键 `(tenant_id, operation, idem_key)`。

```text
BEGIN
  尝试插入幂等记录；唯一冲突则读取既有记录。
  同 key 同 business_hash：返回既有 resource_id 与原受理响应。
  同 key 不同 business_hash：409 IDEMPOTENCY_CONFLICT。
  新请求：创建订单、Hold、额度预留和 Outbox。
  写入 resource_id/受理响应，COMMIT。
```

事务提交前不调用链上操作。订单的 `(tenant_id, external_order_id)` 再提供长期业务唯一性：不同幂等键重复同一商户订单，也不能创建第二笔付款。保留订单与幂等映射的期限须覆盖业务重试/审计周期；不得因短期缓存 TTL 到期复用外部订单号。

业务摘要基于校验后的业务 DTO：稳定 schema 版本、规范地址、规范整数金额、显式默认值，经 [JCS](https://www.rfc-editor.org/rfc/rfc8785) 规范化后 SHA-256。金额始终是字符串。时间戳、nonce、随机加密 IV 和 request ID 不进入业务摘要，付款地址、金额、资产、报价及订单号必须进入。

一期 `external_order_id` 与 `Idempotency-Key` 建议为 1–128 个 ASCII 字符，限定字母、数字及 `._:-`，区分大小写，不自动截断或规范化。稳定业务操作键使用带版本的结构化编码，禁止直接拼接无分界的 tenant/order 字符串。

## 5. 可选报文加密

TLS 提供所有接口的传输加密。需要降低 TLS 终止节点可见数据的租户，额外启用 [JWE](https://www.rfc-editor.org/rfc/rfc7516)；一期选择单一互操作 Profile，例如 `ECDH-ES+A256KW / A256GCM / P-256`，经库支持和测试向量验证后发布。

租户用平台独立报文加密公钥加密，签名覆盖实际传输的密文和其 Content-Digest。Wallet API 验签后解密。保护头绑定 `kid, alg, enc, cty`，拒绝算法降级、远程 `jku/x5u`、压缩和未知关键扩展。

解密后使用同一 schema 与幂等摘要。相同业务重试的 JWE 密文通常不同，不可用密文 hash 判断业务冲突。加密失败返回统一错误，不暴露细分密码学错误。响应可用租户独立加密公钥保护，并使用平台响应签名绑定请求标识。

## 6. 外部接口目录

| 方法与路径 | scope | 语义 |
|---|---|---|
| `POST /v1/users` | `users:write` | 幂等创建或获取用户；返回地址准备状态 |
| `GET /v1/users/{user_id}/addresses?chain_id=...` | `accounts:read` | 已激活网络地址，不暴露 xpub/派生秘密 |
| `GET /v1/users/{user_id}/balances` | `balances:read` | 可用、三类冻结、待确认及快照序号 |
| `GET /v1/assets` | `assets:read` | 精度、充值/提现开关、最低金额和网络信息 |
| `GET /v1/deposits` | `deposits:read` | cursor 分页；可按用户、状态筛选 |
| `POST /v1/holds` | `holds:business:write` | 创建业务冻结 |
| `POST /v1/holds/{hold_id}/releases` | `holds:business:write` | 引用具体 Hold 的幂等部分或全部释放 |
| `POST /v1/withdrawal-quotes` | `withdrawals:write` | 返回付款金额、服务费、总扣款和报价有效期 |
| `POST /v1/withdrawals` | `withdrawals:write` | 202 仅表示已受理并冻结，不表示上链成功 |
| `GET /v1/withdrawals/{id}` | `withdrawals:read` | 当前订单与交易确认状态 |
| `POST /v1/withdrawals/{id}/cancel` | `withdrawals:write` | 请求取消；不保证已签订单可撤销 |
| `POST /v1/internal-transfers` | `transfers:write` | 仅同租户、同网络、同资产的账本划转 |
| `GET /v1/events` | `events:read` | 回调遗漏时查询/补偿消费 |

公网没有 `sendRawTransaction`、任意合约 calldata、选择付款钱包、平台风控解冻或根密钥操作接口。

### 6.1 提现请求及响应

以下地址、合约均为示意占位，不是生产资产配置：

```json
{
  "external_order_id": "merchant-order-00001",
  "wallet_user_id": "00000000-0000-4000-8000-000000000001",
  "chain_id": "eip155:1",
  "asset_id": "eip155:1/erc20:0x1111111111111111111111111111111111111111",
  "send_amount": "10000000",
  "destination_address": "0x2222222222222222222222222222222222222222",
  "quote_id": "00000000-0000-4000-8000-000000000002"
}
```

```json
{
  "withdrawal_id": "00000000-0000-4000-8000-000000000003",
  "status": "REVIEW_PENDING",
  "send_amount": "10000000",
  "service_fee": "100000",
  "total_debit": "10100000",
  "asset_decimals": 6,
  "version": 1
}
```

报价绑定租户、用户、网络、资产、目标地址和金额；提交只引用有效报价，不接受客户端修改费用。整数金额必须规范编码、在链金额边界内，拒绝科学计数、负值和小数。

## 7. 错误与 SDK 行为

| HTTP/业务码 | 客户端行为 |
|---|---|
| `400 INVALID_ARGUMENT` | 修正参数；未创建资金指令 |
| `401 SIGNATURE_INVALID/REQUEST_EXPIRED/REPLAY_DETECTED` | 检查公钥、时钟和签名，重试使用新 nonce |
| `403 ACTION_FORBIDDEN` | 不重试，检查 scope/暂停策略 |
| `404 RESOURCE_NOT_FOUND` | 不区分不存在和跨租户资源 |
| `409 IDEMPOTENCY_CONFLICT/ORDER_CONFLICT` | 查询原订单，禁止修改参数后复用订单号 |
| `422 INSUFFICIENT_BALANCE/QUOTE_EXPIRED` | 更新余额或报价后新建业务指令 |
| `429 RATE_LIMITED` | 按 Retry-After 重试，保留幂等键 |
| `503 TEMPORARILY_UNAVAILABLE` 或连接超时 | 结果可能已提交；查询或同键同参数重试 |

SDK 只负责签名、规范金额、时间同步、查询与 HTTP 重试，不在超时后自动生成新的外部订单号。错误体带 `code, request_id, retriable`，不包含账户存在性、私钥引用或敏感风控规则。

## 8. 验收条件

- 修改 URL 查询、请求体、幂等键、目标网络任一关键项，验签或业务摘要检查失败。
- 同签名重放只能一次通过；同业务使用新签名重试只得到原订单。
- JSON 字段顺序改变、JWE 重新加密不改变规范业务摘要。
- 提交成功但响应丢失、幂等事务竞争、密钥轮换期间请求均无重复冻结或付款。
- API 凭据与 mTLS 主体不属于同一租户时拒绝；任何匿名内部上下文头均不生效。
- 文档示例、SDK 与服务端共用 Profile 测试向量和错误码契约。
