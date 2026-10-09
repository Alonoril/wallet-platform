# M04：HD 地址分配、地址归属与链/资产注册

返回 [设计总览](README.md)。关联需求：唯一账户地址、EVM 多网络、未来链扩展和准确资产识别。

## 1. 职责与边界

本模块管理永久索引分配、当前充值地址、历史地址归属、托管钱包地址注册，以及链/资产的版本化策略。用户身份来自 M01，公共派生材料来自 M03，监听激活依赖 M06。地址服务没有私钥和签名能力。

用户身份、充值地址和资金账户分开：一个用户可以持有多项资产账户；一个 EVM 地址可以在多个启用网络使用；每个网络上的地址归属均须单独注册。

## 2. 数据模型与唯一性

| 表 | 字段 | 关键约束 |
|---|---|---|
| `address_domains` | `id, tenant_id, chain_family, isolation_mode, chain_id?, scheme_version` | 地址隔离模式一经发行不可静默改变 |
| `key_roots` | M03 元数据 | 指向租户及地址域，根版本不可变 |
| `derivation_allocators` | `key_root_id, next_index, version` | 根一行；`next_index <= 2147483648` |
| `wallet_allocations` | `id, tenant_id, user_id, domain_id, key_root_id, address_index, path, public_key_hash, address_bytes, state` | 根+路径唯一；租户用户+根唯一 |
| `user_address_bindings` | `tenant_id, user_id, domain_id, current_allocation_id, version` | 用户+地址域唯一，指向当前版本 |
| `chain_address_registry` | `chain_id, address_bytes, tenant_id, role, owner_ref, key_ref, monitor_from_height, state` | `(chain_id, address_bytes)` 全平台唯一归属/角色 |
| `address_monitor_coverage` | `allocation_id, chain_id, from_height, through_height, through_hash, scanner_version, state` | 每个发行网络独立覆盖状态 |

`role` 为 `USER_DEPOSIT / HOT / GAS_POOL / TREASURY / COLD`。同一网络同一地址不得同时作为用户充值地址和平台 Gas 钱包。旧地址轮换后仍保留原用户归属；`current_allocation_id` 变化不迁移旧地址所有权。

所有租户资源引用用组合外键绑定租户。地址注册表跨租户唯一约束用于阻止错误碰撞；对外不得通过冲突错误泄露其他租户地址资料。

## 3. 索引预留与派生

```text
BEGIN
  锁定 tenant/user/domain 绑定，读取当前 allocation。
  已有且非显式轮换：返回原 allocation。
  选择该地址域 ACTIVE 根；锁定 derivation_allocators 行。
  检查 next_index < 2^31，取索引并单调 +1。
  写 RESERVED allocation 和 current binding；写地址任务 Outbox。
COMMIT
  受控公钥派生 → 校验描述符 hash 和完整路径 → 保存 DERIVED。
  注册每个启用网络的地址归属 → 完成监听与历史回填。
  将用户映射与 allocation 写入独立发行清单并取得持久确认。
  网络覆盖和发行清单均就绪后 → 该网络 ACTIVE → 可对外返回。
```

EVM 路径：`m/44'/60'/0'/0/index`。同一租户用户重复调用不会换索引。失效任务、取消开户或派生错误不回收索引；重试引用原 allocation。

极少数 BIP32 无效子密钥情况必须由派生模块显式报告，旧索引标记 `SKIPPED`，事务内分配下一个，并记录实际路径。不得让库静默跳到下一索引而数据库仍记录原索引。[BIP32 派生规则](https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki)

根接近索引耗尽时告警并准备新根版本。不得越界进入硬化索引，因为公开派生服务无法用 xpub 派生该路径。

显式轮换已有用户地址时，先预留 replacement allocation，保留原 current binding；只有新地址监听和发行清单完成后，才以版本条件切换当前指针。常规开户不会替已有用户自动换根。

### 3.1 防止地址已发出但扫描未就绪

先持久注册，再确认监听覆盖，最后发行地址。为根在每个网络登记保守的出生高度；新网络启用也要确定历史回填起点。回填可利用已有事件索引，或由链适配器针对目标地址重新扫描；不能仅从请求时的 latest 高度开始。

对长寿命根，历史回填可能昂贵：使用受控预派生地址池、提前注册监听、复用已保存的事件事实降低延迟。地址尚未就绪时开户返回 `202/address_status=PROVISIONING`，而不是未经保证地公布地址。

覆盖水位包含块哈希和 scanner version；链扫描推进与地址列表版本切换有确认协议。即使地址在扫描器缓存更新间隙收到入款，也能通过回填补到。未启用网络不承诺自动入账，不把其他链余额合并到当前链。

## 4. 根轮换与多 EVM 网络

| 场景 | 处理规则 |
|---|---|
| 默认公共 EVM 地址域 | 同一 allocation 在各启用网络登记相同 20 字节地址 |
| 租户网络隔离模式 | 每个网络对应独立地址域/根，发行前确定 |
| 根常规轮换 | 新开户选择新根；既有用户保持稳定地址，除非明确发起地址迁移 |
| 用户显式地址迁移 | 建立新 allocation，激活后切换 current binding，旧地址继续监听 |
| 根疑似泄露 | 暂停发行，按 M03/M13 执行应急轮换，不只改数据库指针 |
| 注销用户 | 旧地址永久归属该用户，进入关闭/清算策略 |

多个根历史版本意味着一个用户可能有多个仍可收到资金的地址；API 区分 `current` 与 `historical`，充值匹配覆盖全部历史已发行地址。

## 5. 链注册

`chains` 保存：`chain_id, family, evm_chain_id?, genesis_hash, native_asset_id, fee_model, rpc_pool_ref, trace_capability, finality_policy_version, scanner_policy_version, state`。

| 配置 | 要求 |
|---|---|
| 链身份 | EVM RPC 返回的 chain ID 与登记值相同；必要时核对创世/受信检查点 |
| RPC 能力 | 区块/回执/日志、历史状态、trace、限流与返回长度逐项验证 |
| 最终性 | `FINALIZED_TAG` 或批准的 `DEPTH` 策略；L2 独立包含 L1 锚定条件 |
| 支持的原生充值路径 | 普通转账、内部 CALL、协议特殊转移的覆盖范围显式登记 |
| 费用模型 | EIP-1559、Legacy 或 L2 扩展，不能一套估价覆盖全部 EVM |
| 运行状态 | 查询/观察、充值入账、提现授权可分别暂停 |

外部网络标识采用 [CAIP-2](https://standards.chainagnostic.org/CAIPs/caip-2)，如 `eip155:1`；内部不用机器整数强行代表未来所有链身份。

## 6. 资产注册与行为适配

外部资产标识采用 [CAIP-19](https://standards.chainagnostic.org/CAIPs/caip-19) Profile，例如 Ethereum 原生资产 `eip155:1/slip44:60`，代币为该网络与完整合约地址。内部另有稳定资产 UUID，symbol 只用于展示。

| 表/配置 | 字段 |
|---|---|
| `assets` | `id, chain_id, kind, contract_bytes?, native_key?, canonical_asset_id` |
| `asset_policy_versions` | `asset_id, version, decimals, display_symbol, adapter_profile, code_hash, proxy_info, effective_from_block, policy_hash` |
| 充提参数 | `min_deposit, min_withdrawal, max_transfer_amount, deposit_enabled, withdrawal_enabled` |
| 行为 Profile | `transfer_selector, expected_logs, return_behavior, fee_on_transfer=false, rebasing=false, paused/blacklist_observation` |

同链合约唯一；原生资产使用独立唯一键，避免 SQL 中 NULL 合约使重复注册绕过唯一约束。金额与合约地址校验使用字节值，EVM 展示可采用校验和编码。

一期拒绝费税型和重基准资产；允许经审核的明确兼容例外，例如 transfer 无返回值的特定合约。不可因为 symbol 为 USDT 就假设所有网络合约行为相同。黑名单、暂停和代理升级能力应登记并监控，而非将常用稳定币视作没有这些能力。

精度不可静默改变历史金额解释。发现实现升级、事件/余额不一致或代币暂停时，停止相关新入账/付款授权，保留原始事件，待新版资产 Profile 审批后按有效区间处理。

## 7. 接口

| 内部接口 | 结果 |
|---|---|
| `ReserveAddress(tx, tenant, user, domain)` | 永久 allocation ID；不执行外部 RPC |
| `DeriveAllocation(allocation_id)` | 公钥/地址及描述符验证证据 |
| `ActivateNetworkAddress(allocation_id, coverage)` | 只有覆盖满足策略才激活 |
| `ResolveAddress(chain_id, address_bytes)` | 唯一 tenant、role、owner_ref、key_ref |
| `GetCurrentAddress(tenant, user, chain_id)` | 当前网络就绪地址或 provisioning 状态 |
| `ResolveAsset(chain_id, contract_or_native, at_block)` | 当时有效的策略与解析 Profile |

扫描器可以读取分片/版本化地址快照；遇到未知地址先持久事实，不凭 symbol 或单独地址字符串猜测租户。

## 8. 异常、性能与验收

- 地址注册碰撞或公钥描述符校验失败进入隔离状态，不用另一个随机地址掩盖异常。
- 多节点并发开户、派生任务重复和进程崩溃，保持同一 allocation 或显式记录的跳过索引。
- 新网络开启前回填已有地址历史，不跨网络复用充值事件或余额。
- 地址在缓存版本切换瞬间收款，通过回填恢复且仅一次有效入账。
- 用户、根版本、地址角色组合外键验证通过；同链同地址无法被两个租户登记。
- 资产升级后旧区块仍用历史 Profile 解析；同名假币事件不能触发真实资产入账。

热点查询使用链 ID 与规范地址的索引。地址列表采用增量快照，不为每个区块重新装载全部用户。索引预留事务短且无外部调用；公钥派生可批处理，但每个结果仍绑定永久 allocation。
