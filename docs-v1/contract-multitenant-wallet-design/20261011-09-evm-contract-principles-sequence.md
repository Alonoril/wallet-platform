# EVM 合约原理与时序图

日期：2026-10-11。本章从合约开发前的协议设计出发，定义职责、权限、状态和资金交互。图中的入口名称表达接口意图，参数阈值由部署配置和治理政策确定。

本章采用 **独立 Mermaid `sequenceDiagram`**：从上到下是调用顺序，横向是责任边界。后端只以签名者或 Relayer 参与提交授权，业务账本、API 和通知不展开。

[打开独立时序图册](sequences/index.html) · [全部源码与 SVG](sequences/README.md)

## 1. 协议的资金路径与核心约束

正常路径为 `DepositVault → ClearingVault → TreasuryVault → 外部收款人`。Treasury 可按固定路由转入 Cold；Cold 只能经逐笔离线批准回 Treasury。案件资金通过 `DispositionController` 从批准的来源转入 Quarantine；解除后只能受控回 Treasury，再按独立提现授权对外支付。治理可显式配置直归 Treasury 的路径，其含义是该路线不经过链上观察期，应作为独立风险决策审核。

每套资金合约绑定同一链、租户和治理域。租户分别持有资金、权限、风险状态与预算；可以复用经过核验的逻辑实现代码，但不能共享可被其他租户支配的余额。治理多签、业务签名者和 Relayer 的能力不同：多签批准高权限操作，业务签名者批准用途明确的资金请求，Relayer 只提交请求，合约依据当前链上状态作最后校验。

| 必须保持的约束 | 协议含义 |
|---|---|
| 当前控制优先于历史签名 | 有效签名还必须满足当前权限、HOLD、pause、预留、路由与预算 |
| 单笔原子提交 | 请求消费、lot、预留、限额、资产转移和成功事件一并成功或回滚 |
| 所有资金出口受控 | 普通出口查全资产与单资产限制；专项隔离也不能越过安全暂停 |
| 精确资产移动 | 源减 amount，目标加 amount；Native 与受支持 ERC20 分别执行 |
| 预留限制可支付余额 | 普通流出后余额覆盖 totalReserve，热池还覆盖 safetyFloor |
| 案件独立 | HOLD 和预留均按 caseId 管理；解除一案不清除其他案件 |
| 迁移不产生新支付能力 | 不重置租户预算，不缩短 lot 的 maturity，不清空风险或业务证据 |
| 地址身份连续 | 无代码地址可先被冻结，部署后仍按同一地址读取 Registry |

同质化资产进入资金池后只能按金额和权利约束流出，不能通过合约给每个代币单位贴来源标签。风险识别、来源证据和法律处置决定需要控制的案件及数量；链上负责执行批准的限制。未知资产、收费代币、变基代币及存在不受支持回调语义的资产，均需独立兼容性和风险审核。

## 2. 各合约的功能重点

下列是建议的合约职责划分。共有校验和工具可以复用为内部模块；不需要为了每个校验再部署一个合约。

| 合约 | 持有的状态 / 资产 | 核心功能与安全边界 | 主要时序图 |
|---|---|---|---|
| TenantAuthority | 租户标识、用途角色、Executor、资产白名单、signerEpoch / policyEpoch | 区分风险、结算、付款、调拨等签名用途；校验操作者；轮换和禁用使旧授权失效；不保管业务资金 | 00、02、13 |
| TenantTimelock | 治理队列、精确 payloadHash、延迟、执行/取消状态 | 管理扩大权限与政策放宽；拒绝提前、重复及内容替换执行；时间锁不能被普通资金签名绕过 | 00、13 |
| Council 多签合约 | 多签门限、治理审批状态 | 为高额付款、冷池回款、迁移和专项处置逐笔批准；批准绑定完整请求及控制快照；可采用 ERC1271 签名校验 | 02、07、08、11、12、13 |
| PoolRegistry | 池类型、租户绑定、代码身份、资产路由、共享预算、routeEpoch | 限制允许的源/目标；仅登记资金入口可消费预算；普通与受限路由分开；共享预算跨池/版本生效；登记不代替代码审计 | 00、03、06、07、08、13 |
| RiskRegistry | 按地址/资产 scope 的 HOLD、pause、epoch；按案件的绝对预留及 CAS version | 记录多案件风险；既能控制预测地址，也能控制已归集池；维护完整控制摘要；原子迁移预留；不自动判定入金风险 | 09、10、11、12、13 |
| VaultFactory | 固定实现、地址域、Vault 登记 | CREATE2 预测并部署 ERC1167 Clone；同事务初始化；限制部署调用来源；禁止通过可变实现改变既有地址行为 | 00、01、03 |
| DepositVault | 固定租户/Manager/Controller 绑定及用户地址余额 | 接收 Native / ERC20；只向允许的归集目标移动资金；普通出口限 Manager，专项出口限 Controller；无任意转账、approve 或升级能力 | 01、03、09、11 |
| VaultManager | 归集授权消费状态、Factory 与目标绑定 | 校验逐地址精确归集授权；编排懒部署、转账和 lot；有界批次通过受限子调用隔离单项失败；不拥有无限扫款权 | 03、04 |
| ClearingVault | 观察期资产、lot、released、maturity、outstanding | 仅基于真实到账登记 lot；普通结算只释放成熟剩余份额；迁移继承 maturity；专项处置退休 lot，直接入金不能侵占 outstanding | 05、06、10、11 |
| TreasuryVault | 热池余额、付款与调拨请求状态、safetyFloor | 精确外部付款；核验收款政策、必要共签、预留和共享预算；内部调拨走独立用途及登记路由；取消不撤回已付款资产 | 07、08、10、12 |
| ColdVault | 冷池托管余额、回款请求状态 | 限制在线敞口；仅逐笔在线授权加 Council 批准回指定 Treasury；无普通任意对外支付入口；保留案件预留 | 08、10、11 |
| DispositionController | 隔离/释放授权消费状态和固定治理绑定 | 编排 Council 批准的例外路径；检查完整双端控制摘要；迁移预留、处理 lot、调用源 dispose；拒绝任意外部目的地 | 11、12 |
| QuarantineVault | 全额受限的案件资金及固定 Controller 绑定 | Controller 隔离转入的全额登记受限；任何直接入金都不自动产生付款权；释放只能回指定 Treasury；多案件限制和剩余预留继续生效 | 11、12 |

内部公共模块应统一实现 Permit 编码与签名校验、请求状态机、当前风险断言、精确转账、执行锁和有界返回数据处理。`EntryContract`、`ItemSubcall`、`ContractSet`、`SourceVault`、`资产余额` 是图中的角色或抽象，不要求额外部署这些同名合约。

资产转移抽象包含两种路径：Native 通过 EVM 的带 value 调用移动余额，ERC20 通过代币合约转账。收款合约或代币回调可能执行外部代码，因此检查、状态消费、执行锁和双端余额差校验必须共同保护转账边界；转账成功返回值本身不足以证明目标已收到精确金额。

请求状态为 `Unused → Executed` 或 `Unused → Cancelled`；成功之后不能恢复成 Unused。请求 ID 的域规则必须明确到合约和用途。链上防重放防止同一许可重复执行，链外业务订单唯一性防止同一笔业务换新 ID 再次签名；二者共同约束经济业务重复。

## 3. 风险控制和专项处置的权限规则

| 操作 | 批准者 | 不可绕过的条件 |
|---|---|---|
| 普通归集、结算、提现与调拨 | 相应用途签名者；Executor 提交；敏感金额按政策另需 Council | 当前双端/源风险开放，精确金额，适用的路由和预算，请求未消费 |
| 冷池回热池 | 用途签名者 + Council，逐笔批准 | 固定 Treasury 目标，源预留底线及当前风险，共享预算 |
| 增加 HOLD、增加预留、设置安全暂停、禁用执行者、收紧额度 | Guardian 或有权限的治理 | 租户及资产 scope 正确；预留使用绝对量与 CAS，防止并发覆盖和重复累计 |
| 解除指定案件 HOLD、减少案件预留 | Council 或按政策经 Timelock 的治理；两类操作分别批准 | 不影响其他案件；变化提升相关控制版本；预留减少保留处置证据 |
| 解除 SECURITY_PAUSED、恢复执行权限、开放路由或放宽额度 | Timelock 延迟治理 | 精确治理参数及最小延迟；不自动清空 HOLD 或预留 |
| HOLD 下专项隔离 | Council 对全部当前约束及精确操作批准，Executor 提交 | 源/目标无安全暂停；仅转同租户 Quarantine；保留其他案件及安全底线 |
| Quarantine 受控释放 | Council 对解除后的新快照重新批准，Executor 提交 | 双端全部 HOLD / pause 均已解除；仅回同租户 Treasury；剩余预留有余额覆盖 |

`allAssets` 与单资产 scope 分开编码，原生币使用 `token=0` 的单资产 scope。每次执行同时检查全资产与当前资产 scope。`controlDigest` 应包含两类 scope 的 epoch、全部 HOLD 集合摘要/数量、安全暂停，以及资产 totalReserve；处置签名还绑定源案件 reserveVersion。批准一个案件的操作不能隐含允许忽略其他案件。

预留是链上出口约束，案件义务是处置证据中的责任金额，两者不能混为一谈。`totalReserve` 大于当前余额时表示该地址没有普通可支付余额，不应自动调低预留。需要隔离一部分时，必须明确可控制的金额、保留的其他案件预留及剩余缺口，不能把缺口转嫁给其他租户。

专项隔离例子：源该案预留 100，批准转出 100 并迁移预留 100，则源该案预留减为 0，Quarantine 增加预留 100 和 HOLD。如果源该案预留仅 40，却批准将 100 全部送入隔离，源只减记 40，目标仍对完整 100 建立预留和 HOLD。其他案件预留留在原地址，源剩余余额必须足够覆盖它们。

Quarantine 同样无法阻止第三方直接打入资产。这部分未归属余额不自动计入任何可释放案件金额；需要先通过证据及治理批准确定归属，建立对应案件预留与限制，再按独立受控释放流程处置。不能因为池中实际余额变大，就放大某份原有释放授权。

## 4. 独立时序图

每张图控制在一个主要业务主题内。彩色 `box` 表示职责，彩色 `rect` 表示执行阶段；橙色分支/注释说明约束。实线箭头是调用或动作，虚线是返回或确认，带叉箭头表示拒绝/失败；资产到账在标注的转移步骤发生。`break` 表示该条件下本次交互结束，`alt` 是互斥分支，`opt` 是可选步骤，`loop` 只用于有界批次或逐池操作。对链外参与者的事件箭头表达可观察结果，不表示合约主动调用后端。

批次图中出现单项隔离和外层回滚两个边界。其他涉及资金的单笔图均遵守整笔事务回滚语义；签名产生、交易提交、查询以及后续另外发起的治理动作不属于同一事务。图中的余额和版本读取仅是执行时快照，不能把签名时的读取当成未来执行的保证。

### 00. 租户隔离、部署与激活

每个租户、每条链拥有独立权限、风险状态和资金池；先形成不可变的绑定关系，再开放执行权限。

功能重点：

- 初始化不能被抢占，所有固定绑定必须在对外开放前核对。
- 登记合约类型、租户、资产路由和代码身份；登记动作不能替代代码审计。
- Factory 的新版本形成新地址域，旧地址继续由其原合约管理。

[SVG 放大预览](sequences/20261011-00-bootstrap.svg) · [Mermaid 源码](sequences/20261011-00-bootstrap.mmd) · [图册定位](sequences/index.html#20261011-00-bootstrap)

<details>
<summary>展开 Mermaid sequenceDiagram</summary>

```mermaid
%%{init: {"theme":"base","themeVariables":{"fontFamily":"Arial, PingFang SC, Microsoft YaHei, sans-serif","fontSize":"18px","primaryColor":"#edf2ff","primaryTextColor":"#243b75","primaryBorderColor":"#5c7cfa","lineColor":"#345995","actorBkg":"#edf2ff","actorBorder":"#5c7cfa","actorTextColor":"#243b75","actorLineColor":"#94a3b8","signalColor":"#345995","signalTextColor":"#17345b","labelBoxBkgColor":"#fff4d6","labelBoxBorderColor":"#f59f00","labelTextColor":"#8a4b08","loopTextColor":"#8a4b08","noteBkgColor":"#fff8db","noteTextColor":"#724713","noteBorderColor":"#e0b64f","activationBkgColor":"#dbeafe","activationBorderColor":"#4c6ef5","sequenceNumberColor":"#ffffff"},"sequence":{"useMaxWidth":false,"wrap":false,"mirrorActors":true,"actorMargin":65,"width":175,"height":70,"boxMargin":14,"boxTextMargin":12,"messageMargin":42,"noteMargin":14,"diagramMarginX":30,"diagramMarginY":25}}}%%
sequenceDiagram
    autonumber
actor C as Council<br/>离线治理多签
actor D as Deployer<br/>部署事务发起者
box rgb(235,242,255) 租户治理
  participant T as TenantTimelock<br/>延迟执行
  participant A as TenantAuthority<br/>权限与签名版本
end
box rgb(255,235,238) 风险控制
  participant R as RiskRegistry<br/>案件与预留
end
box rgb(232,250,241) 资金与路由
  participant P as PoolRegistry<br/>池登记与限额
  participant V as ContractSet<br/>Factory及各资金合约
end
rect rgb(235,242,255)
  Note over C,V: 准备阶段：执行者和资金路由保持关闭<br/>链 / tenantKey / poolId 是整套协议的隔离边界
  D->>D: 预计算固定互绑地址，核对租户部署清单
  D->>T: 部署时间锁，绑定治理多签及最小延迟
  D->>A: 部署租户权限，设置不可变租户标识
  D->>R: 部署风险状态，绑定 Authority
  D->>P: 部署路由和共享预算，绑定租户及 RiskRegistry
  D->>V: 部署资金池、Manager、Factory、Controller
  V->>V: 原子初始化固定地址互绑，锁定重复初始化
  D->>P: 在受限初始化阶段登记池类型、地址及代码身份
  P->>V: 读取并核对固定绑定与资金出口类型
  V-->>P: 返回租户、治理、风险及池绑定
  P->>P: 仅记录通过核对的池，路由仍未激活
  D->>A: 封闭初始化权限；后续配置仅按治理角色执行
end
rect rgb(232,250,241)
  C->>T: 排队激活参数，绑定 payloadHash 和执行时间
  T->>T: 等待治理延迟，拒绝重复或提前执行
  C->>T: execute(精确激活参数)
  T->>A: 设置用途隔离的签名者、资产、Executor
  T->>P: 配置观察期、限额、目标路由与安全底线
  T->>P: 开放已核对路由，递增配置版本
  A-->>C: 发出权限配置事件
  P-->>C: 发出路由激活事件
  Note over A,V: 资金合约每次执行仍检查当前权限和风险<br/>部署成功或登记成功不等于获得任意转账权限
end
```

</details>

### 01. CREATE2 预测地址、预充值与原子部署

充值地址是固定代码和固定地址域的计算结果，用户地址无需独立私钥；收款能力与主动移动资金的权限分开。

功能重点：

- CREATE2 地址由 Factory、salt、initCodeHash 共同决定；Clone 的 initCode 固定实现地址。
- salt 绑定链、租户、用户标识和地址版本，不复用跨租户或跨版本的地址域。
- 未部署地址也能接收资产；部署不会清除已在 RiskRegistry 中登记的限制。

[SVG 放大预览](sequences/20261011-01-address.svg) · [Mermaid 源码](sequences/20261011-01-address.mmd) · [图册定位](sequences/index.html#20261011-01-address)

<details>
<summary>展开 Mermaid sequenceDiagram</summary>

```mermaid
%%{init: {"theme":"base","themeVariables":{"fontFamily":"Arial, PingFang SC, Microsoft YaHei, sans-serif","fontSize":"18px","primaryColor":"#edf2ff","primaryTextColor":"#243b75","primaryBorderColor":"#5c7cfa","lineColor":"#345995","actorBkg":"#edf2ff","actorBorder":"#5c7cfa","actorTextColor":"#243b75","actorLineColor":"#94a3b8","signalColor":"#345995","signalTextColor":"#17345b","labelBoxBkgColor":"#fff4d6","labelBoxBorderColor":"#f59f00","labelTextColor":"#8a4b08","loopTextColor":"#8a4b08","noteBkgColor":"#fff8db","noteTextColor":"#724713","noteBorderColor":"#e0b64f","activationBkgColor":"#dbeafe","activationBorderColor":"#4c6ef5","sequenceNumberColor":"#ffffff"},"sequence":{"useMaxWidth":false,"wrap":false,"mirrorActors":true,"actorMargin":65,"width":175,"height":70,"boxMargin":14,"boxTextMargin":12,"messageMargin":42,"noteMargin":14,"diagramMarginX":30,"diagramMarginY":25}}}%%
sequenceDiagram
    autonumber
actor U as 用户 / 外部转账者
actor L as Relayer<br/>仅提交交易
box rgb(228,249,252) 充值地址体系
  participant M as VaultManager<br/>授权部署入口
  participant F as VaultFactory<br/>地址计算与部署
  participant I as DepositImplementation<br/>固定逻辑实现
  participant V as DepositVault<br/>用户合约地址
end
box rgb(255,235,238) 独立风险状态
  participant R as RiskRegistry<br/>可记录无代码地址
end
participant X as 资产余额<br/>Native / ERC20
rect rgb(228,249,252)
  L->>F: predict(chain, tenantKey, walletKey, addressVersion)
  F->>F: 计算域隔离 salt 和固定 Clone initCodeHash
  F-->>L: predictedAddress<br/>keccak256(0xff, Factory, salt, initCodeHash) 的后20字节
  Note over F,I: ERC-1167 Clone 的 delegatecall 目标固定<br/>用户余额和存储位于 Clone，逻辑实现本身不托管充值
  U->>X: 将 Native 或 ERC20 转入 predictedAddress
  X-->>U: 资产层确认转账；此时 Vault 可以尚未部署
  Note over V,X: 未部署地址无法自行发出合约充值事件<br/>原生币由交易/余额识别，ERC20 由代币事件识别
end
rect rgb(235,242,255)
  L->>M: deploy(walletKey)
  M->>M: 校验 Executor，禁止任意地址获得部署权限
  M->>F: 请求部署已绑定用户地址
  F->>F: 只允许 Manager / Controller；核对地址域和固定实现
  alt 地址尚无代码
    F->>V: CREATE2 部署固定实现 Clone
    F->>V: 同一事务 initialize(租户、Manager、Controller、Risk)
    V->>I: delegatecall 固定实现的初始化逻辑
    I->>I: 在 Clone 上下文校验 Factory 来源和一次性初始化
    I-->>V: 绑定写入 Clone 存储；返回初始化结果
    V->>V: 永久锁定重复初始化
    V-->>F: 返回初始化完成状态
  else 地址已经部署
    F->>V: 核对本 Factory 登记、固定绑定和初始化状态
    V-->>F: 返回已登记 Vault
  end
  F-->>M: VaultDeployed / 已存在地址
  M-->>L: 返回用户 Vault 地址
  V->>R: 后续主动转账前读取当前限制
  R-->>V: 返回该地址的 HOLD、pause、reserve 和 epoch
  Note over I,V: delegatecall 保持原调用者，address(this) 和余额属于 Clone<br/>实现自身应锁定初始化，不替任何用户持有余额
  Note over V,R: 风险按地址登记，部署前后的身份连续<br/>不能用部署、重部署或版本切换绕过冻结
end
```

</details>

### 02. 资金授权、防重放与原子执行

执行者负责送交易，签名者批准具体业务，合约按当前链上状态作最终裁决；许可消费、预算和资金转移组成一个原子事务。

功能重点：

- EIP-712 Domain 绑定 chainId、校验合约和协议版本；业务结构体绑定租户、用途、资产、金额、目标、证据、有效期及版本。
- 签名有效不等于请求可执行；当前 HOLD、暂停、路由、额度和请求状态仍必须满足。
- 请求 ID 按合约及用途定义命名空间，业务订单在链外保持全局唯一；同一笔订单不能换 ID 重复授权。

[SVG 放大预览](sequences/20261011-02-authorization.svg) · [Mermaid 源码](sequences/20261011-02-authorization.mmd) · [图册定位](sequences/index.html#20261011-02-authorization)

<details>
<summary>展开 Mermaid sequenceDiagram</summary>

```mermaid
%%{init: {"theme":"base","themeVariables":{"fontFamily":"Arial, PingFang SC, Microsoft YaHei, sans-serif","fontSize":"18px","primaryColor":"#edf2ff","primaryTextColor":"#243b75","primaryBorderColor":"#5c7cfa","lineColor":"#345995","actorBkg":"#edf2ff","actorBorder":"#5c7cfa","actorTextColor":"#243b75","actorLineColor":"#94a3b8","signalColor":"#345995","signalTextColor":"#17345b","labelBoxBkgColor":"#fff4d6","labelBoxBorderColor":"#f59f00","labelTextColor":"#8a4b08","loopTextColor":"#8a4b08","noteBkgColor":"#fff8db","noteTextColor":"#724713","noteBorderColor":"#e0b64f","activationBkgColor":"#dbeafe","activationBorderColor":"#4c6ef5","sequenceNumberColor":"#ffffff"},"sequence":{"useMaxWidth":false,"wrap":false,"mirrorActors":true,"actorMargin":65,"width":175,"height":70,"boxMargin":14,"boxTextMargin":12,"messageMargin":42,"noteMargin":14,"diagramMarginX":30,"diagramMarginY":25}}}%%
sequenceDiagram
    autonumber
actor S as 业务签名者<br/>用途隔离的密钥
actor L as Relayer<br/>Executor
box rgb(235,242,255) 通用执行约束
  participant E as EntryContract<br/>资金入口合约
  participant A as TenantAuthority<br/>角色与 signerEpoch
  participant P as PoolRegistry<br/>路由与预算
end
box rgb(255,235,238) 当前风险状态
  participant R as RiskRegistry<br/>双端控制快照
end
participant X as 资产转移<br/>Native / ERC20
S->>S: 构造精确业务 Permit，签署 EIP-712 digest
S-->>L: Permit + 在线签名 + 必要的 Council 批准
L->>E: execute(Permit, signatures)
activate E
E->>A: 查询 Executor、用途签名者、资产及当前版本
A-->>E: 返回当前权限与配置
E->>E: 校验 Domain、用途、租户、金额、目标、证据和有效期
E->>E: 验证 EOA 或 ERC1271 签名；按政策核验 Council
E->>R: 查询源与目标全资产/单资产控制状态
R-->>E: 返回 HOLD、pause、预留及当前 epoch
E->>P: 查询当前路由、池类型和政策版本
P-->>E: 返回固定路由与共享限额
break 任一授权或状态检查不满足
  E-->>L: revert；授权和资金均未消费
end
rect rgb(232,250,241)
  E->>E: 拒绝重入；检查请求状态 Unused
  E->>E: 请求状态写入 Executed，更新本次业务状态
  E->>P: 消费适用的共享支付预算
  P->>P: 只接受登记资金入口；记录预算，与执行同事务
  E->>X: 按签名金额精确转账
  X-->>E: 返回转账结果；核验源减量和目标增量
  alt 任一步失败或余额变化不符
    E-->>L: revert：请求、预算、业务状态和转账全部回滚
  else 全部成功
    E-->>L: 发出业务成功事件，携带 ID、金额、目标及证据摘要
  end
end
deactivate E
Note over E,X: 所有普通出口共用当前风险和预留底线<br/>外部回调不能绕过执行锁，收费或变基代币不能冒充精确转账
```

</details>

### 03. 单地址授权归集与风险二次检查

Manager 负责验证逐笔授权并编排交易，DepositVault 只执行有限的固定出口；Clearing 的 lot 在收到真实资产后登记。

功能重点：

- 采用全余额精确授权：amount = expectedBalance = 执行时余额；新入金导致旧授权失配，应重新评估并签署。
- Manager 和 Vault 都检查风险及目标绑定，不能只在链外风控或上游合约检查一次。
- 归集和 lot 登记同事务提交，避免资金已移动却没有对应的清算额度。

[SVG 放大预览](sequences/20261011-03-sweep.svg) · [Mermaid 源码](sequences/20261011-03-sweep.mmd) · [图册定位](sequences/index.html#20261011-03-sweep)

<details>
<summary>展开 Mermaid sequenceDiagram</summary>

```mermaid
%%{init: {"theme":"base","themeVariables":{"fontFamily":"Arial, PingFang SC, Microsoft YaHei, sans-serif","fontSize":"18px","primaryColor":"#edf2ff","primaryTextColor":"#243b75","primaryBorderColor":"#5c7cfa","lineColor":"#345995","actorBkg":"#edf2ff","actorBorder":"#5c7cfa","actorTextColor":"#243b75","actorLineColor":"#94a3b8","signalColor":"#345995","signalTextColor":"#17345b","labelBoxBkgColor":"#fff4d6","labelBoxBorderColor":"#f59f00","labelTextColor":"#8a4b08","loopTextColor":"#8a4b08","noteBkgColor":"#fff8db","noteTextColor":"#724713","noteBorderColor":"#e0b64f","activationBkgColor":"#dbeafe","activationBorderColor":"#4c6ef5","sequenceNumberColor":"#ffffff"},"sequence":{"useMaxWidth":false,"wrap":false,"mirrorActors":true,"actorMargin":65,"width":175,"height":70,"boxMargin":14,"boxTextMargin":12,"messageMargin":42,"noteMargin":14,"diagramMarginX":30,"diagramMarginY":25}}}%%
sequenceDiagram
    autonumber
actor L as Relayer<br/>提交 SweepPermit
box rgb(228,249,252) 充值与归集
  participant M as VaultManager<br/>授权编排
  participant F as VaultFactory<br/>确定性部署
  participant V as DepositVault<br/>有限资金出口
end
box rgb(255,235,238) 风险与路由
  participant R as RiskRegistry<br/>实时限制
  participant P as PoolRegistry<br/>允许的归集目标
end
box rgb(242,235,255) 接收资金
  participant C as Clearing / Treasury<br/>同租户登记池
end
participant X as 资产余额<br/>Native / ERC20
L->>M: sweep(Permit, riskSignature)
M->>M: 核验 Executor、用途签名、租户、证据、金额和有效期
M->>F: 查询 walletKey 对应的预测地址
F-->>M: 返回唯一 DepositVault 地址
M->>R: 检查 Vault 和目标的当前限制及 riskEpoch
R-->>M: 无 HOLD / 安全暂停，版本匹配
M->>P: 检查固定归集目标及 routeEpoch
P-->>M: 同租户 Clearing 或 Treasury，路由开放
M->>X: 查询 Vault 当前资产余额
X-->>M: balance
break 余额不等于授权 amount 和 expectedBalance
  M-->>L: revert；重新评估新增入金后再签名
end
rect rgb(232,250,241)
  M->>M: 原子消费归集 ID
  M->>F: ensureDeployed(walletKey)
  F->>V: 必要时同事务部署并初始化
  F-->>M: 返回固定 Vault
  M->>V: sweep(固定目标, token, 精确 amount)
  V->>V: 只允许绑定的 Manager 调用
  V->>P: 二次核对允许的归集目标
  V->>R: 再查双端限制，核验源余额扣除后覆盖预留
  V->>X: 精确移动资产至登记目标
  X-->>C: 到账 amount
  V-->>M: 归集完成，源减量与目标增量匹配
  opt 目标是 Clearing
    M->>C: recordLot(归集 ID, token, amount, 入池时间)
    C->>C: 检查 Manager 来源和余额覆盖，生成 maturity
    C-->>M: LotRecorded
  end
  M-->>L: SweepExecuted(ID, Vault, 目标, token, amount)
end
Note over M,X: 部署、转账或 lot 登记任一步失败，整个单笔归集回滚<br/>主动归集不替未知代币或第三方入金自动背书
```

</details>

### 04. 批量归集的单项隔离与交易边界

批次是多份独立授权的容器，不能把多个地址合并成一份无限扫款授权；单项失败和外层失败采用不同恢复语义。

功能重点：

- 执行前限制项目数量、calldata、签名长度和单项 gas，并检查重复 ID。
- 子调用失败只撤销当前项；外层 OOG 或最终回滚仍撤销所有已成功项。
- 只以逐项成功事件和请求状态判断执行结果；未执行项保留原 ID 并重新检查有效期和当前版本。

[SVG 放大预览](sequences/20261011-04-batch.svg) · [Mermaid 源码](sequences/20261011-04-batch.mmd) · [图册定位](sequences/index.html#20261011-04-batch)

<details>
<summary>展开 Mermaid sequenceDiagram</summary>

```mermaid
%%{init: {"theme":"base","themeVariables":{"fontFamily":"Arial, PingFang SC, Microsoft YaHei, sans-serif","fontSize":"18px","primaryColor":"#edf2ff","primaryTextColor":"#243b75","primaryBorderColor":"#5c7cfa","lineColor":"#345995","actorBkg":"#edf2ff","actorBorder":"#5c7cfa","actorTextColor":"#243b75","actorLineColor":"#94a3b8","signalColor":"#345995","signalTextColor":"#17345b","labelBoxBkgColor":"#fff4d6","labelBoxBorderColor":"#f59f00","labelTextColor":"#8a4b08","loopTextColor":"#8a4b08","noteBkgColor":"#fff8db","noteTextColor":"#724713","noteBorderColor":"#e0b64f","activationBkgColor":"#dbeafe","activationBorderColor":"#4c6ef5","sequenceNumberColor":"#ffffff"},"sequence":{"useMaxWidth":false,"wrap":false,"mirrorActors":true,"actorMargin":65,"width":175,"height":70,"boxMargin":14,"boxTextMargin":12,"messageMargin":42,"noteMargin":14,"diagramMarginX":30,"diagramMarginY":25}}}%%
sequenceDiagram
    autonumber
actor L as Relayer<br/>批量交易发起者
box rgb(228,249,252) 批次与单项事务
  participant M as VaultManager<br/>外层批次
  participant I as ItemSubcall<br/>Manager的仅自调用入口
  participant V as DepositVault<br/>第 i 个地址
end
participant R as RiskRegistry<br/>每项实时核验
participant C as Clearing / Treasury<br/>接收池
L->>M: batchSweep(逐项 Permit / signature / gasCap)
M->>M: 预检数组边界、重复 ID、签名大小和单项 gas 上限
M->>M: 建立外层执行锁，预留收尾事件的 gas
loop 逐项执行，不能越过批次上限
  alt 剩余 gas 足够执行当前项和收尾
    M->>I: 有 gas 上限的 self-call executeItem(i)
    activate I
    Note over M,I: 内层入口只允许 Manager 自调用<br/>锁的设计必须允许这条受限内部路径，拒绝其他重入
    I->>I: 独立验证当前项签名、版本、金额和请求状态
    I->>R: 检查当前源与目标的风险状态
    I->>V: 执行当前项部署 / 固定出口 / 精确转账
    alt 当前项成功
      V-->>I: 返回到账结果
      I->>C: 必要时登记当前项 lot
      I-->>M: success + 当前项成功事件
    else 子调用 revert 或耗尽其 gas
      I--xM: 子调用失败，当前项所有效果回滚
      M->>M: 截断返回数据，记录有限长度错误摘要
      M-->>L: ItemFailed(i, requestId, errorDigest)
    end
    deactivate I
  else gas 不足
    M-->>L: BatchStopped(firstUnexecuted)
    Note over M,C: 停止循环，不执行后续项
  end
end
alt 外层正常结束
  M-->>L: 返回逐项结果；成功项可在同一交易中保留
else 外层 OOG 或最终 revert
  M--xL: 整批回滚，包括先前成功项、lot 和事件
end
Note over L,C: 外层交易成功不代表每一项成功<br/>重试失败/未执行项，不重签已成功业务的新 ID
```

</details>

### 05. 观察期 lot、部分结算与余额覆盖

Clearing 将可结算权利记录为 lot，以余额覆盖 outstanding；观察期和逐 lot 释放共同约束普通资金出口。

功能重点：

- lot 由有效归集产生，记录资产、原始金额、已释放金额和 maturity；直接打入池的资产不自动生成 lot。
- 普通结算只使用成熟且尚未释放的 lot，签名同时绑定 lot 列表和逐项金额。
- 释放状态、outstanding 扣减和精确转账同事务变化，部分释放不会产生第二份权利。

[SVG 放大预览](sequences/20261011-05-clearing.svg) · [Mermaid 源码](sequences/20261011-05-clearing.mmd) · [图册定位](sequences/index.html#20261011-05-clearing)

<details>
<summary>展开 Mermaid sequenceDiagram</summary>

```mermaid
%%{init: {"theme":"base","themeVariables":{"fontFamily":"Arial, PingFang SC, Microsoft YaHei, sans-serif","fontSize":"18px","primaryColor":"#edf2ff","primaryTextColor":"#243b75","primaryBorderColor":"#5c7cfa","lineColor":"#345995","actorBkg":"#edf2ff","actorBorder":"#5c7cfa","actorTextColor":"#243b75","actorLineColor":"#94a3b8","signalColor":"#345995","signalTextColor":"#17345b","labelBoxBkgColor":"#fff4d6","labelBoxBorderColor":"#f59f00","labelTextColor":"#8a4b08","loopTextColor":"#8a4b08","noteBkgColor":"#fff8db","noteTextColor":"#724713","noteBorderColor":"#e0b64f","activationBkgColor":"#dbeafe","activationBorderColor":"#4c6ef5","sequenceNumberColor":"#ffffff"},"sequence":{"useMaxWidth":false,"wrap":false,"mirrorActors":true,"actorMargin":65,"width":175,"height":70,"boxMargin":14,"boxTextMargin":12,"messageMargin":42,"noteMargin":14,"diagramMarginX":30,"diagramMarginY":25}}}%%
sequenceDiagram
    autonumber
actor L as Relayer<br/>提交结算授权
participant M as VaultManager<br/>归集编排
box rgb(242,235,255) 观察期资金池
  participant C as ClearingVault<br/>lot 与 outstanding
end
participant R as RiskRegistry<br/>源与目标风控
participant P as PoolRegistry<br/>结算路由
box rgb(232,250,241) 可支付资金池
  participant T as TreasuryVault<br/>接收已结算资金
end
participant X as 资产余额<br/>Native / ERC20
rect rgb(242,235,255)
  M->>C: 资产已到账后 recordLot(ID, token, amount)
  C->>X: 查询当前余额
  X-->>C: balance
  C->>C: 检查 lot 唯一，balance >= outstanding + amount
  C->>C: 存储 amount / released=0 / maturity；增加 outstanding
  C-->>M: LotRecorded
end
Note over C,T: 观察期未满时不得普通结算<br/>观察期降低不能追溯缩短已有 lot 的 maturity
L->>C: settle(Permit, lotIds, amounts, settlementSignature)
C->>C: 核验 Executor、签名、有效期和 lotsHash
C->>C: 检查列表有界、无重复、同资产、成熟及剩余额度
C->>R: 检查双端无 HOLD / pause，源扣除后仍覆盖预留
R-->>C: 当前风险版本匹配，允许普通流出
C->>P: 核验允许的 Treasury 目标和 routeEpoch
P-->>C: 固定目标、同租户、开放路由
break 未成熟 / 超额 / 重复 / 任一限制不满足
  C-->>L: revert；lot 和资金均保持原状态
end
rect rgb(232,250,241)
  C->>C: 消费结算 ID；released += 本次金额
  C->>C: outstanding -= 本次总额
  C->>X: 精确转账本次总额至 Treasury
  X-->>T: 收到相同金额
  C->>X: 核验转账差额及剩余余额覆盖 outstanding
  C-->>L: SettlementExecuted + 逐 lot 释放事件
end
Note over C,X: lot 不是用户链上账户，也不表示物理区分同质化币<br/>任何失败必须连同 released / outstanding 一起回滚
```

</details>

### 06. Clearing 迁移与观察期继承

迁移搬动保管位置和剩余 lot 权利，不制造已成熟状态；来源退休和目标导入必须一次提交。

功能重点：

- 迁移由离线治理批准，并绑定源、目标、lot 明细、金额和当前风险快照。
- 只迁移尚未释放的份额，目标 lot 继承原 maturity，并记录原池和原 lot 来源。
- 目标导入入口只接受登记的同租户 Clearing，复核资产到账和迁移 ID。

[SVG 放大预览](sequences/20261011-06-lot-migration.svg) · [Mermaid 源码](sequences/20261011-06-lot-migration.mmd) · [图册定位](sequences/index.html#20261011-06-lot-migration)

<details>
<summary>展开 Mermaid sequenceDiagram</summary>

```mermaid
%%{init: {"theme":"base","themeVariables":{"fontFamily":"Arial, PingFang SC, Microsoft YaHei, sans-serif","fontSize":"18px","primaryColor":"#edf2ff","primaryTextColor":"#243b75","primaryBorderColor":"#5c7cfa","lineColor":"#345995","actorBkg":"#edf2ff","actorBorder":"#5c7cfa","actorTextColor":"#243b75","actorLineColor":"#94a3b8","signalColor":"#345995","signalTextColor":"#17345b","labelBoxBkgColor":"#fff4d6","labelBoxBorderColor":"#f59f00","labelTextColor":"#8a4b08","loopTextColor":"#8a4b08","noteBkgColor":"#fff8db","noteTextColor":"#724713","noteBorderColor":"#e0b64f","activationBkgColor":"#dbeafe","activationBorderColor":"#4c6ef5","sequenceNumberColor":"#ffffff"},"sequence":{"useMaxWidth":false,"wrap":false,"mirrorActors":true,"actorMargin":65,"width":175,"height":70,"boxMargin":14,"boxTextMargin":12,"messageMargin":42,"noteMargin":14,"diagramMarginX":30,"diagramMarginY":25}}}%%
sequenceDiagram
    autonumber
actor C as Council<br/>迁移独立批准
actor L as Relayer<br/>提交迁移授权
box rgb(242,235,255) 原子迁移
  participant S as SourceClearing<br/>退休剩余份额
  participant D as TargetClearing<br/>继承观察期
end
participant P as PoolRegistry<br/>同类迁移路由
participant R as RiskRegistry<br/>双端限制与预留
participant X as 资产余额<br/>Native / ERC20
C->>C: 审核目标绑定、来源 lot、maturity 和迁移金额
C-->>L: 签署精确迁移内容及当前控制版本
L->>S: migrateLots(迁移 Permit, 在线签名, Council 批准)
S->>S: 核验授权、唯一迁移 ID 和有界 lot 列表
S->>P: 检查同租户 Clearing → Clearing 路由
P-->>S: 目标类型、代码身份和 routeEpoch 匹配
S->>R: 检查双方限制，计算源剩余预留底线
R-->>S: 当前控制状态满足迁移条件
S->>S: 校验每个 lot 剩余份额；迁移不要求先成熟
rect rgb(232,250,241)
  S->>S: 消费迁移 ID；退休本次份额，减少 outstanding
  S->>X: 精确转账总额至目标 Clearing
  X-->>D: 资产到账
  S->>D: importLots(迁移 ID, 源 lot, 份额, 原 maturity)
  D->>P: 再查源登记身份、同类路由及当前版本
  D->>R: 再查源和目标风险约束
  D->>X: 确认到账余额覆盖新增 outstanding
  D->>D: 生成含来源域的新 lot ID，拒绝重复迁移导入
  D->>D: 导入剩余份额，继承每个原 maturity
  D-->>S: LotsImported(来源映射)
  S-->>L: MigrationExecuted(源 / 目标 / 总额)
end
Note over S,D: 目标拒绝导入则整笔迁移回滚，源份额恢复<br/>新 ID 不重新开始或缩短观察期，也不增加可支付权利
```

</details>

### 07. Treasury 提现、共享限额与取消竞争

Treasury 是普通对外付款的唯一热池入口；链上按确切收款对象、预留底线和共享预算限制签名者的支付能力。

功能重点：

- 外部提现、内部调拨使用不同授权用途；内部资产移动必须走登记路由。
- balance - amount 必须覆盖案件总预留与安全底线；无 HOLD 也不等于余额可以全部支付。
- 取消和付款以链上顺序裁决，已执行不能撤销；暂停和版本变化也能阻断仍有效的旧签名。

[SVG 放大预览](sequences/20261011-07-withdrawal.svg) · [Mermaid 源码](sequences/20261011-07-withdrawal.mmd) · [图册定位](sequences/index.html#20261011-07-withdrawal)

<details>
<summary>展开 Mermaid sequenceDiagram</summary>

```mermaid
%%{init: {"theme":"base","themeVariables":{"fontFamily":"Arial, PingFang SC, Microsoft YaHei, sans-serif","fontSize":"18px","primaryColor":"#edf2ff","primaryTextColor":"#243b75","primaryBorderColor":"#5c7cfa","lineColor":"#345995","actorBkg":"#edf2ff","actorBorder":"#5c7cfa","actorTextColor":"#243b75","actorLineColor":"#94a3b8","signalColor":"#345995","signalTextColor":"#17345b","labelBoxBkgColor":"#fff4d6","labelBoxBorderColor":"#f59f00","labelTextColor":"#8a4b08","loopTextColor":"#8a4b08","noteBkgColor":"#fff8db","noteTextColor":"#724713","noteBorderColor":"#e0b64f","activationBkgColor":"#dbeafe","activationBorderColor":"#4c6ef5","sequenceNumberColor":"#ffffff"},"sequence":{"useMaxWidth":false,"wrap":false,"mirrorActors":true,"actorMargin":65,"width":175,"height":70,"boxMargin":14,"boxTextMargin":12,"messageMargin":42,"noteMargin":14,"diagramMarginX":30,"diagramMarginY":25}}}%%
sequenceDiagram
    autonumber
actor L as Relayer<br/>提交提现 Permit
actor C as Guardian / Council<br/>取消及高额批准
box rgb(232,250,241) 普通对外支付
  participant T as TreasuryVault<br/>请求状态与付款
  participant P as PoolRegistry<br/>共享支付预算
end
participant A as TenantAuthority<br/>用途签名与政策
participant R as RiskRegistry<br/>案件预留 / HOLD
participant X as 资产转移<br/>Native / ERC20
actor U as 外部收款人
opt 政策要求高额独立共签
  C-->>L: Council 批准同一份请求内容，绑定当前政策版本
end
alt 取消交易先被执行
  C->>T: cancel(requestId)
  T->>A: 校验取消角色
  T->>T: Unused → Cancelled，发出取消事件
  L->>T: executeWithdrawal(旧 Permit)
  T--xL: 请求已取消，拒绝付款
else 付款交易先被执行
  L->>T: executeWithdrawal(Permit, paymentSignature, approvals)
  T->>A: 核验 Executor、付款签名者、资产和 policyEpoch
  T->>T: 检查收款地址、金额、有效期、请求状态及必要共签
  Note over T,U: 收款对象不得为受限名单或已知内部资金地址<br/>尚未部署的预测地址难以全部枚举，签名政策也须限制目的地
  T->>R: 检查 Treasury 本资产与全资产 HOLD / pause / epoch
  R-->>T: 返回 totalReserve 和当前开放状态
  T->>X: 查询付款前真实余额
  X-->>T: balance
  T->>T: 检查 balance - amount >= totalReserve + safetyFloor
  T->>P: 原子消费单笔 / 时间窗 / 租户共享支付限额
  P-->>T: 额度通过并记录占用
  T->>T: 消费 requestId，写入 Executed
  T->>X: 精确转账指定金额至指定收款人
  X-->>U: 到账 amount
  T->>X: 核验双端余额变化
  T-->>L: WithdrawalExecuted(requestId, token, amount, recipient)
  C->>T: 稍后 cancel(同一 requestId)
  T--xC: 已执行；没有逆转外部付款的入口
end
Note over T,U: 任一检查、预算消费或转账失败，本次事务整体回滚<br/>付款已确认后，追回外部资产需要链外处置或接收方配合
```

</details>

### 08. 热池转冷、离线批准回款与迁移预算

ColdVault 降低在线可支配余额，只接受固定托管路由，回热池逐笔需要离线批准；同租户总敞口不会因切换池而重置。

功能重点：

- 转冷和回款仍是资产移动，必须遵守当前风险、源预留底线和目标绑定。
- 冷池不能直接向任意外部地址付款；回热后仍需独立的普通提现授权。
- 共享限额由租户级 Registry 保存，新增 Treasury、迁移或改路由不能重置计数。

[SVG 放大预览](sequences/20261011-08-cold.svg) · [Mermaid 源码](sequences/20261011-08-cold.mmd) · [图册定位](sequences/index.html#20261011-08-cold)

<details>
<summary>展开 Mermaid sequenceDiagram</summary>

```mermaid
%%{init: {"theme":"base","themeVariables":{"fontFamily":"Arial, PingFang SC, Microsoft YaHei, sans-serif","fontSize":"18px","primaryColor":"#edf2ff","primaryTextColor":"#243b75","primaryBorderColor":"#5c7cfa","lineColor":"#345995","actorBkg":"#edf2ff","actorBorder":"#5c7cfa","actorTextColor":"#243b75","actorLineColor":"#94a3b8","signalColor":"#345995","signalTextColor":"#17345b","labelBoxBkgColor":"#fff4d6","labelBoxBorderColor":"#f59f00","labelTextColor":"#8a4b08","loopTextColor":"#8a4b08","noteBkgColor":"#fff8db","noteTextColor":"#724713","noteBorderColor":"#e0b64f","activationBkgColor":"#dbeafe","activationBorderColor":"#4c6ef5","sequenceNumberColor":"#ffffff"},"sequence":{"useMaxWidth":false,"wrap":false,"mirrorActors":true,"actorMargin":65,"width":175,"height":70,"boxMargin":14,"boxTextMargin":12,"messageMargin":42,"noteMargin":14,"diagramMarginX":30,"diagramMarginY":25}}}%%
sequenceDiagram
    autonumber
actor L as Relayer<br/>送交易
actor C as Council<br/>离线批准
box rgb(232,250,241) 热冷资金托管
  participant T as TreasuryVault<br/>在线热池
  participant D as ColdVault<br/>离线控制冷池
  participant P as PoolRegistry<br/>固定路由及共享预算
end
participant R as RiskRegistry<br/>双端预留与限制
participant X as 资产余额<br/>Native / ERC20
rect rgb(232,250,241)
  Note over L,X: 阶段一：减少热池敞口，转入固定冷池
  L->>T: transferCustody(转冷 Permit, 用途签名, 必要共签)
  T->>T: 核验调拨用途、当前版本、精确金额和唯一 ID
  T->>P: 核验 Treasury → Cold 的同租户托管路由
  T->>R: 检查双方开放，源剩余额度覆盖预留和热池底线
  T->>P: 消费租户共享支付预算
  T->>T: 消费调拨 ID
  T->>X: 精确转账至固定 Cold
  X-->>D: 托管资产到账
  T-->>L: CustodyTransferred
end
rect rgb(235,242,255)
  Note over L,X: 阶段二：补充热池流动性，另签独立回款授权
  C->>C: 审核回款目标、金额、有效期、当前风险和政策
  C-->>L: Council 对该笔回款签名，不授予无限权限
  L->>D: returnToTreasury(回款 Permit, 用途签名, Council 批准)
  D->>D: 核验两种批准、回款用途、请求 ID 和当前版本
  D->>P: 检查 Cold → 登记 Treasury 的固定路由
  D->>R: 双端必须开放，源扣除后仍覆盖案件预留
  D->>P: 消费与全部 Treasury 共用的预算
  D->>D: 消费回款 ID
  D->>X: 精确转账至批准的 Treasury
  X-->>T: 热池流动性到账
  D-->>L: ColdReturned
end
Note over T,P: 同租户 Treasury → Treasury 迁移也使用登记路由<br/>迁移需独立批准，原共享预算和风险控制持续生效
Note over T,X: 两个阶段是不同事务，不自动连续执行<br/>任一阶段失败只回滚该阶段；冷池无任意对外支付出口
```

</details>

### 09. 风险入金未归集：原地址冻结与旧授权撤销

风险状态位于独立 Registry，可先于 Vault 部署生效；冻结提升版本，使冻结之前签发的归集许可失效。

功能重点：

- HOLD 按案件登记，scope 分全资产与单资产；解除一个案件不能解除其他案件。
- 第三方转入、Vault 部署和请求取消都不能替代当前风险检查。
- 原生币 token=0 的单资产 scope 与 allAssets scope 必须不同；冻结并不阻止继续收款。

[SVG 放大预览](sequences/20261011-09-risk-before.svg) · [Mermaid 源码](sequences/20261011-09-risk-before.mmd) · [图册定位](sequences/index.html#20261011-09-risk-before)

<details>
<summary>展开 Mermaid sequenceDiagram</summary>

```mermaid
%%{init: {"theme":"base","themeVariables":{"fontFamily":"Arial, PingFang SC, Microsoft YaHei, sans-serif","fontSize":"18px","primaryColor":"#edf2ff","primaryTextColor":"#243b75","primaryBorderColor":"#5c7cfa","lineColor":"#345995","actorBkg":"#edf2ff","actorBorder":"#5c7cfa","actorTextColor":"#243b75","actorLineColor":"#94a3b8","signalColor":"#345995","signalTextColor":"#17345b","labelBoxBkgColor":"#fff4d6","labelBoxBorderColor":"#f59f00","labelTextColor":"#8a4b08","loopTextColor":"#8a4b08","noteBkgColor":"#fff8db","noteTextColor":"#724713","noteBorderColor":"#e0b64f","activationBkgColor":"#dbeafe","activationBorderColor":"#4c6ef5","sequenceNumberColor":"#ffffff"},"sequence":{"useMaxWidth":false,"wrap":false,"mirrorActors":true,"actorMargin":65,"width":175,"height":70,"boxMargin":14,"boxTextMargin":12,"messageMargin":42,"noteMargin":14,"diagramMarginX":30,"diagramMarginY":25}}}%%
sequenceDiagram
    autonumber
actor G as Guardian<br/>提交风险控制
actor C as Council<br/>案件解除审批
actor L as Relayer<br/>可能持有旧授权
box rgb(255,235,238) 可先于部署生效
  participant R as RiskRegistry<br/>HOLD / epoch / caseId
end
participant M as VaultManager<br/>归集入口
participant F as VaultFactory<br/>部署入口
participant V as DepositVault<br/>尚未部署或已部署
participant X as 资产余额<br/>第三方可继续转入
rect rgb(255,235,238)
  G->>R: addHold(caseId, predictedAddress, assetScope, evidenceHash)
  R->>R: 核验 Guardian 和租户域；登记独立案件 HOLD
  R->>R: 更新 HOLD 集合摘要、计数及 scopeEpoch
  R-->>G: HoldAdded(caseId, address, scope, newEpoch)
  L->>M: 提交冻结前签署的 SweepPermit
  M->>R: 检查当前 HOLD 及 permit.riskEpoch
  R-->>M: 存在 HOLD，且旧 epoch 已失配
  M--xL: 拒绝归集，请求 ID 不消费
  L->>M: 请求部署该 Vault
  M->>M: 检查 Executor，不解除原地址风险限制
  M->>F: 请求确定性部署
  F->>V: 原子部署并初始化固定绑定
  V->>R: 后续资金出口读取同一地址的风险状态
  R-->>V: 原 HOLD 持续有效，部署不重置
  X-->>V: 第三方仍可继续入金
end
rect rgb(235,242,255)
  C->>R: releaseHold(仅指定 caseId, 最新证据 / 批准)
  R->>R: 移除该案 HOLD，再次递增 scopeEpoch
  alt 仍有其他 HOLD 或安全暂停
    R-->>C: 当前 scope 继续限制普通资金流出
  else 所有 HOLD 与安全暂停均已解除
    R-->>C: 普通路径可重新评估，案件预留仍需单独处理
  end
  L->>M: 再次提交冻结前的旧归集签名
  M->>R: 读取当前风险版本
  R-->>M: 解除后的新 epoch 仍不等于旧签名 epoch
  M--xL: 旧签名持续失效，须按当前余额重新签署
end
Note over R,V: 合约接受控制命令，不能自行判定哪笔入金是风险资金<br/>需要隔离时转入专项 Controller 流程，不能直接解冻后扫款
```

</details>

### 10. 风险入金已归集：逐池控制、多案件预留与缺口

归集后必须控制实际持有资产的每个池；链上维护限制与可执行余额，来源证据和案件义务决定隔离金额。

功能重点：

- 冻结原 Vault 不会自动冻结 Clearing、Treasury、Cold 或正在排队的许可。
- 在受影响池按资产建立 HOLD 与案件预留，多案件预留求和；减少预留和解除 HOLD 是两个不同动作。
- 已外付资产没有链上撤回能力；案件义务、可控金额与缺口分开记录，不能让别的租户补足。

[SVG 放大预览](sequences/20261011-10-risk-after.svg) · [Mermaid 源码](sequences/20261011-10-risk-after.mmd) · [图册定位](sequences/index.html#20261011-10-risk-after)

<details>
<summary>展开 Mermaid sequenceDiagram</summary>

```mermaid
%%{init: {"theme":"base","themeVariables":{"fontFamily":"Arial, PingFang SC, Microsoft YaHei, sans-serif","fontSize":"18px","primaryColor":"#edf2ff","primaryTextColor":"#243b75","primaryBorderColor":"#5c7cfa","lineColor":"#345995","actorBkg":"#edf2ff","actorBorder":"#5c7cfa","actorTextColor":"#243b75","actorLineColor":"#94a3b8","signalColor":"#345995","signalTextColor":"#17345b","labelBoxBkgColor":"#fff4d6","labelBoxBorderColor":"#f59f00","labelTextColor":"#8a4b08","loopTextColor":"#8a4b08","noteBkgColor":"#fff8db","noteTextColor":"#724713","noteBorderColor":"#e0b64f","activationBkgColor":"#dbeafe","activationBorderColor":"#4c6ef5","sequenceNumberColor":"#ffffff"},"sequence":{"useMaxWidth":false,"wrap":false,"mirrorActors":true,"actorMargin":65,"width":175,"height":70,"boxMargin":14,"boxTextMargin":12,"messageMargin":42,"noteMargin":14,"diagramMarginX":30,"diagramMarginY":25}}}%%
sequenceDiagram
    autonumber
actor G as Guardian<br/>根据来源证据下控制命令
actor C as Council<br/>案件预算与恢复批准
box rgb(255,235,238) 风险总账
  participant R as RiskRegistry<br/>按池 / 资产 / 案件
end
box rgb(232,250,241) 实际持有资金的池
  participant S as ClearingVault<br/>观察期资金
  participant T as TreasuryVault<br/>混合热池余额
  participant D as ColdVault<br/>已转冷余额
end
actor L as Relayer<br/>可能提交旧授权
participant X as 当前链上余额
rect rgb(255,235,238)
  Note over G,X: 风险发现时先定位当前持有池，再阻断普通出口<br/>控制交易只能约束其链上执行之后的交易，不能追回已先执行的付款
  loop 对每个实际受影响的池及资产
    G->>R: 原子 addHold + setMinimumReserve(caseId, pool, token, amount)
    R->>R: 核验租户；同案幂等，不重复累计案件预留
    R->>R: 建立 HOLD，更新该案绝对预留和 CAS version
    R->>R: totalReserve = 各案件预留之和；递增控制 epoch
    R-->>G: 发出案件、总预留和新控制版本事件
  end
  L->>T: 提交旧提现 / 转冷 / 迁移 Permit
  T->>R: 检查本池当前 HOLD / pause / riskEpoch
  R-->>T: 普通流出被阻断，旧授权版本失配
  T--xL: 拒绝执行，ID 与付款额度不消费
  L->>S: 提交旧结算授权
  S->>R: 检查本池限制
  R-->>S: 拒绝普通结算
  L->>D: 提交旧回热授权
  D->>R: 检查本池限制
  R-->>D: 拒绝普通回款
end
rect rgb(255,246,221)
  C->>X: 获取各池余额、在途执行结果与来源证据
  X-->>C: 当前可控制余额，不包括已外部付款
  C->>C: 分别确认案件义务、可控隔离量与未覆盖缺口
  alt 需要专项隔离
    C-->>L: 对当前双端快照及隔离金额签署 Controller 授权
  else 可恢复部分普通业务
    C->>R: 以 CAS 调整该案绝对预留，保留案件义务证据
    C->>R: 独立解除该案 HOLD，其他案件保持有效
    R-->>C: 递增控制版本；后续出口仍遵守 totalReserve
  end
  Note over R,X: 如果余额低于总预留，普通出口必须继续失败<br/>不能自动减少预留，也不能跨租户挪用余额填补缺口
end
```

</details>

### 11. 专项隔离：批准快照、预留迁移与 lot 退休

DispositionController 为案件处置提供受限的例外资金路径，必须由离线批准精确内容；Quarantine 对转入的全部金额建立限制。

功能重点：

- 批准绑定源与目标完整控制摘要、案件、金额、证据、预留版本、路由及有效期；状态变化撤销旧批准。
- HOLD 例外只允许批准的受限隔离路径，安全暂停始终阻断；其他案件预留不能被消耗。
- Clearing 中的登记 lot 随转出退休；无 lot 的直接入金只能使用 balance - outstanding。

[SVG 放大预览](sequences/20261011-11-disposition.svg) · [Mermaid 源码](sequences/20261011-11-disposition.mmd) · [图册定位](sequences/index.html#20261011-11-disposition)

<details>
<summary>展开 Mermaid sequenceDiagram</summary>

```mermaid
%%{init: {"theme":"base","themeVariables":{"fontFamily":"Arial, PingFang SC, Microsoft YaHei, sans-serif","fontSize":"18px","primaryColor":"#edf2ff","primaryTextColor":"#243b75","primaryBorderColor":"#5c7cfa","lineColor":"#345995","actorBkg":"#edf2ff","actorBorder":"#5c7cfa","actorTextColor":"#243b75","actorLineColor":"#94a3b8","signalColor":"#345995","signalTextColor":"#17345b","labelBoxBkgColor":"#fff4d6","labelBoxBorderColor":"#f59f00","labelTextColor":"#8a4b08","loopTextColor":"#8a4b08","noteBkgColor":"#fff8db","noteTextColor":"#724713","noteBorderColor":"#e0b64f","activationBkgColor":"#dbeafe","activationBorderColor":"#4c6ef5","sequenceNumberColor":"#ffffff"},"sequence":{"useMaxWidth":false,"wrap":false,"mirrorActors":true,"actorMargin":65,"width":175,"height":70,"boxMargin":14,"boxTextMargin":12,"messageMargin":42,"noteMargin":14,"diagramMarginX":30,"diagramMarginY":25}}}%%
sequenceDiagram
    autonumber
actor C as Council<br/>审核全部当前限制
actor L as Relayer<br/>执行处置授权
box rgb(255,233,245) 受限隔离
  participant D as DispositionController<br/>唯一例外编排
  participant Q as QuarantineVault<br/>全额受限保管
end
participant R as RiskRegistry<br/>控制摘要与案件预留
participant P as PoolRegistry<br/>专项处置路由
participant F as VaultFactory<br/>必要时部署源地址
participant S as SourceVault<br/>Deposit / Clearing / Treasury / Cold
participant X as 资产余额<br/>Native / ERC20
C->>R: 查询源 / 目标全资产及单资产控制摘要
R-->>C: epochs、全部 HOLD 摘要、pause、总预留及 reserveVersion
C->>C: 审核所有约束，批准 caseId / amount / reserveToMove / lotsHash
C-->>L: Council 签署双端快照、目标 Quarantine、证据和有效期
L->>D: isolate(Permit, CouncilSignature, lotDetails)
D->>D: 验证 Executor、签名、金额、唯一 ID 和完整业务绑定
D->>R: 核对当前双端 controlDigest 与源 reserveVersion
R-->>D: 快照匹配；双方均无 SECURITY_PAUSED
D->>P: 核验源身份和同租户 Quarantine 专项路由
P-->>D: 允许受限隔离，不能改为任意外部收款人
break 快照变化 / 安全暂停 / 签名或路由失配
  D-->>L: revert，需重新审核并批准
end
rect rgb(255,233,245)
  D->>D: 消费处置 ID，锁定本次编排
  D->>R: 原子迁移该案预留，目标增加全部 amount 的预留和 HOLD
  R->>R: 校验 reserveToMove <= amount 且不超过源该案预留
  R->>R: 源只减少批准 reserveToMove；其他案件预留保留
  R->>R: 目标按完整 amount 受限；双方控制版本递增
  R-->>D: 返回更新后的源剩余预留底线
  opt 来源为尚未部署的预测 DepositVault
    D->>F: ensureDeployed(批准的 walletKey)
    F->>S: CREATE2 部署并原子初始化固定绑定
    F-->>D: 返回批准的源地址，原风险状态持续
  end
  alt 来源为 Clearing 且包含登记 lot
    D->>S: prepareDisposition(lotIds, amounts, lotsHash)
    S->>S: 核验来源权限、列表唯一和退休总额=amount
    S->>S: 退休本次份额并减少 outstanding，允许未成熟份额
  else 来源为 Clearing 的未登记直接入金
    D->>S: 校验 lot 列表为空，amount <= balance - outstanding
  else 来源为其他 Vault
    D->>D: 要求 lot 参数为空，拒绝无意义的 lot 声明
  end
  D->>S: dispose(固定 Quarantine, token, amount, caseId)
  S->>S: 仅允许 Controller；剩余余额覆盖其他案件和适用安全底线
  S->>R: 再核验无安全暂停及更新后的剩余总预留
  S->>X: 精确转账至已登记 Quarantine
  X-->>Q: 接收 amount，全部资金已有目标限制
  D-->>L: DispositionExecuted(案件、源、目标、金额、证据)
end
Note over D,X: 预留迁移、lot 退休、部署和转账必须同事务提交<br/>任何失败全部回滚；专项例外不能成为普通提现绕过口
```

</details>

### 12. Quarantine 解控、受控释放与后续独立支付

隔离解除需要案件解除和资金释放两组明确动作；Quarantine 只有回指定 Treasury 的受控出口，没有普通外部支付权限。

功能重点：

- 解除一个 HOLD 不会清除其他案件或安全暂停，也不会自动减记案件预留。
- 释放签名在解除之后按最新快照签发，不能复用隔离授权或解除前签名。
- 部分释放同步减记该案预留，剩余金额继续受限；回热池和外部提现不是同一笔业务。

[SVG 放大预览](sequences/20261011-12-release.svg) · [Mermaid 源码](sequences/20261011-12-release.mmd) · [图册定位](sequences/index.html#20261011-12-release)

<details>
<summary>展开 Mermaid sequenceDiagram</summary>

```mermaid
%%{init: {"theme":"base","themeVariables":{"fontFamily":"Arial, PingFang SC, Microsoft YaHei, sans-serif","fontSize":"18px","primaryColor":"#edf2ff","primaryTextColor":"#243b75","primaryBorderColor":"#5c7cfa","lineColor":"#345995","actorBkg":"#edf2ff","actorBorder":"#5c7cfa","actorTextColor":"#243b75","actorLineColor":"#94a3b8","signalColor":"#345995","signalTextColor":"#17345b","labelBoxBkgColor":"#fff4d6","labelBoxBorderColor":"#f59f00","labelTextColor":"#8a4b08","loopTextColor":"#8a4b08","noteBkgColor":"#fff8db","noteTextColor":"#724713","noteBorderColor":"#e0b64f","activationBkgColor":"#dbeafe","activationBorderColor":"#4c6ef5","sequenceNumberColor":"#ffffff"},"sequence":{"useMaxWidth":false,"wrap":false,"mirrorActors":true,"actorMargin":65,"width":175,"height":70,"boxMargin":14,"boxTextMargin":12,"messageMargin":42,"noteMargin":14,"diagramMarginX":30,"diagramMarginY":25}}}%%
sequenceDiagram
    autonumber
actor C as Council / Timelock<br/>按权限解除限制
actor L as Relayer<br/>提交新释放授权
box rgb(255,233,245) 隔离与受控出口
  participant D as DispositionController<br/>审核释放模式
  participant Q as QuarantineVault<br/>无普通支付出口
end
participant R as RiskRegistry<br/>多案件限制及预留
participant P as PoolRegistry<br/>Quarantine → Treasury
participant T as TreasuryVault<br/>重新托管资金
participant X as 资产余额<br/>Native / ERC20
rect rgb(235,242,255)
  C->>R: 对已结案的指定 caseId 解除 HOLD
  R->>R: 清除此案件 HOLD，递增 epoch；不自动清除其他案件
  opt 仍存在安全暂停
    C->>R: 经时间锁批准后解除 SECURITY_PAUSED
    R->>R: 递增控制版本
  end
  C->>R: 读取释放后的双端最新完整控制摘要
  R-->>C: 当前 HOLD、pause、预留和版本
  C-->>L: 签署独立 ReleasePermit，绑定精确金额和登记 Treasury
end
L->>D: release(新 Permit, CouncilSignature)
D->>D: 检查模式只能为 Quarantine → Treasury，核验新 ID 和签名
D->>R: 核验双端所有 HOLD / pause 均解除，快照匹配
D->>P: 检查同租户受控释放路由与目标类型
break 任一其他案件仍 HOLD / pause 或快照不匹配
  D-->>L: 拒绝释放，即使该案自身已解除
end
rect rgb(232,250,241)
  D->>D: 消费释放 ID
  D->>R: 按批准 amount 减记源该案预留，核验 CAS version
  R->>R: 要求 amount 不超过该案预留，拒绝减成负值
  R->>R: 保留所有其他案件预留，目标本次不新增该案限制
  R-->>D: 返回源剩余总预留
  D->>Q: dispose(批准的 Treasury, token, amount)
  Q->>R: 再查当前开放状态和剩余预留底线
  Q->>X: 精确转账至 Treasury
  X-->>T: 接收 amount
  D-->>L: ReleaseExecuted(案件、金额、目标和证据)
end
Note over Q,T: 部分释放后，源剩余余额必须覆盖其剩余预留<br/>目标原有的其他案件预留不会因此消失
L->>T: 若需外部支付，另提交独立 WithdrawalPermit
T->>R: 再次检查当前风险与 Treasury 总预留
T->>T: 独立核验付款签名、政策、限额和请求状态
Note over T,X: 释放不是退款，外部支付需按提现序列单独执行<br/>转入或转出 Quarantine 不证明历史风险来源已经消失
```

</details>

### 13. 紧急收紧、延迟恢复与固定合约版本迁移

紧急角色可以快速降低资金流出的能力；扩大权限、放宽政策和版本切换由离线治理及延迟执行约束。

功能重点：

- 暂停路由不等于暂停所有外部付款；阻断提现必须控制资金池风险或执行者权限。
- HOLD 解除、预留减少和安全暂停解除按各自权限执行，不能笼统地称为一键恢复。
- 固定代码采用新版本部署与显式资产迁移，地址、请求状态和风险限制保持可追溯。

[SVG 放大预览](sequences/20261011-13-governance.svg) · [Mermaid 源码](sequences/20261011-13-governance.mmd) · [图册定位](sequences/index.html#20261011-13-governance)

<details>
<summary>展开 Mermaid sequenceDiagram</summary>

```mermaid
%%{init: {"theme":"base","themeVariables":{"fontFamily":"Arial, PingFang SC, Microsoft YaHei, sans-serif","fontSize":"18px","primaryColor":"#edf2ff","primaryTextColor":"#243b75","primaryBorderColor":"#5c7cfa","lineColor":"#345995","actorBkg":"#edf2ff","actorBorder":"#5c7cfa","actorTextColor":"#243b75","actorLineColor":"#94a3b8","signalColor":"#345995","signalTextColor":"#17345b","labelBoxBkgColor":"#fff4d6","labelBoxBorderColor":"#f59f00","labelTextColor":"#8a4b08","loopTextColor":"#8a4b08","noteBkgColor":"#fff8db","noteTextColor":"#724713","noteBorderColor":"#e0b64f","activationBkgColor":"#dbeafe","activationBorderColor":"#4c6ef5","sequenceNumberColor":"#ffffff"},"sequence":{"useMaxWidth":false,"wrap":false,"mirrorActors":true,"actorMargin":65,"width":175,"height":70,"boxMargin":14,"boxTextMargin":12,"messageMargin":42,"noteMargin":14,"diagramMarginX":30,"diagramMarginY":25}}}%%
sequenceDiagram
    autonumber
actor G as Guardian<br/>紧急收紧
actor C as Council<br/>离线治理
box rgb(235,242,255) 延迟治理与版本
  participant T as TenantTimelock<br/>排队与精确执行
  participant A as TenantAuthority<br/>执行者及签名用途
  participant P as PoolRegistry<br/>路由与共享限额
end
participant R as RiskRegistry<br/>安全暂停和案件状态
participant V as Old / New Vault<br/>固定代码的不同版本
rect rgb(255,235,238)
  G->>A: 禁用 Executor 或特定用途签名者，提升对应版本
  G->>P: 暂停资金路由，收紧共享限额
  G->>R: 对受影响池 / 资产设置 SECURITY_PAUSED
  R->>R: 提升控制 epoch，阻断所有相应资金出口
  Note over A,V: 单独暂停内部路由不足以暂停外部提现<br/>使用池资产风险控制或 Executor 禁用覆盖付款入口
end
rect rgb(235,242,255)
  C->>T: schedule(恢复参数 / payloadHash / 最早执行时间)
  T->>T: 等待最小治理延迟，保留观察和取消窗口
  alt 出现新证据，应撤销恢复
    C->>T: cancel(该治理 operationId)
    T->>T: 标记取消，拒绝以后执行该排队操作
  else 未取消且延迟已到
    C->>T: execute(精确排队参数)
    T->>A: 恢复或轮换用途签名者 / Executor，提升版本
    T->>P: 放宽限额或恢复批准的路由，提升配置版本
    T->>R: 按批准解除安全暂停，提升控制 epoch
  end
  Note over R,V: 案件 HOLD 和案件预留仍需各自批准处理<br/>时间锁恢复不会自动抹除案件限制，也不复活旧签名
end
rect rgb(232,250,241)
  C->>T: 排队登记已核验的新版本与迁移路由
  T->>V: 核验已部署新版本的不可变绑定与权限配置
  T->>P: 登记新池代码身份，开放批准的迁移路由
  P->>P: 保留租户共享预算，不因新池出现而清零
  C->>V: 另签精确资产迁移授权和最新控制快照
  V->>R: 查双方风险；不能用换版本绕过 HOLD 或预留
  V->>V: 执行符合池类型的迁移，Clearing 继承 lot maturity
  Note over P,V: 旧充值地址仍属于旧 Factory 域并继续受原控制<br/>旧请求状态不清空，新版本业务 ID 仍需避免经济业务重复执行
end
```

</details>

## 5. 开发时应确认的协议决策

- 为每种授权确定独立 typeHash、必填字段、请求 ID 域规则和签名有效期；跨链、跨租户、跨合约和跨用途不能重放。
- 明确治理最小延迟、批次项数/gas/返回数据上限、观察期、共签阈值和共享预算时间窗。参数变化不能追溯放宽已有 lot 或复活旧签名。
- 明确各类资金出口支持的资产语义、Native 与 ERC20 的精确余额校验，以及 ERC1271/资产回调期间的执行锁。
- 明确预留迁移、部分释放、Clearing 无 lot 直接入金、多个案件同时控制和余额不足时的失败条件；专项处置不得消耗其他案件的可控资金。
- 明确部署初始化、固定互绑、新版本迁移、旧地址持续接收资金和未知资产的处理边界，并保持事件与状态可核对。
- 验收应覆盖权限越界、签名重放、版本竞争、取消先后、逐项/外层失败、lot 重复消费、多案解除、安全暂停及预留底线。

本章说明协议原理和设计约束。合约不能自行识别风险来源、阻止第三方入金或撤回已经外部支付的资产；这些边界需要在产品及案件处置流程中持续保留。
