## Design

## 设计文档入口

- [V2 模块详细设计总览与模块目录](multitenant-wallet-design/v2-detailed-design/README.md)：按 14 个模块说明职责、数据模型、接口、流程、恢复和验收。
- [V2 核心架构方案](multitenant-wallet-design/web3_multitenant_custodial_wallet_phase1_architecture_v2.md)：六项核心需求和架构决策。
- [V1 架构方案](multitenant-wallet-design/web3_multitenant_custodial_wallet_phase1_architecture.md)：一期整体背景。

# 问1

我要开发一个Web3中心化钱包的项目，这个项目是一个平台项目类似于支付宝。主要的功能区分多租户，并且其他的项目可以通过Http
API集成，且加密通讯。这个钱包类似于币安的交易所钱包，在平台通过助记词派生一堆平台可控的钱包地址，并且分配给租户的用户，平台控制这批钱包的私钥。需要支持EVM链的充值和提现等功能。未来二期需要提供波场，Solana等平台的充提，这期暂时不考虑，在架构层面需要支持。根据我的这个需求生成一份第一期可行的架构方案。markdown格式输出。

# 答案1

# Web3 多租户中心化托管钱包平台——一期技术架构方案

版本：V1.0 · 2026-10-09 · 架构设计 / 可行性方案

## 一、总体设计结论

你的项目本质上并不是普通的 Web3 钱包，而是一个面向第三方业务平台的 多租户托管钱包基础设施（Multi-Tenant Custodial Wallet
Platform）。

它结合了币安等中心化交易所的钱包托管模式，以及支付宝式的账户、余额、交易流水和开放 API 能力。

推荐一期采用：多租户 SaaS + HD 托管钱包 + 平台统一资金账本 + EVM 链适配器 + 独立签名服务 + 加密开放 API。

一期关键架构决策

| 架构维度  | 推荐设计                        |
|-------|-----------------------------|
| 钱包模式  | 中心化托管，平台掌握私钥                |
| 租户模型  | 共享平台能力，租户资金独立核算             |
| 地址管理  | BIP39 / BIP32 / BIP44 HD 钱包 |
| 首期区块链 | EVM 链，支持原生币及 ERC-20         |
| 资金管理  | PostgreSQL 双重记账账本           |
| 充值    | 链上监听、确认、入账、资金归集             |
| 提现    | 风控、余额冻结、审批、签名、广播            |
| 外部接入  | REST API + TLS + 请求签名 / 加密  |
| 技术栈   | Rust + PostgreSQL + Redis   |
| 二期扩展  | TRON、Solana 独立链适配器          |

### 最关键的设计原则

必须区分三种东西：

1. 链上钱包地址： 用于用户充值和平台控制链上资产，私钥由平台托管。
2. 平台内部资金账户： 记录每个租户、每个用户实际拥有多少余额、冻结了多少资金。
3. 平台资金钱包： 用于充值归集、提现、Gas 补充和冷热资产管理。

用户在平台中拥有的 USDT 余额，不必始终存放在其对应的充值地址上。

例如，用户充值 100 USDT，链上资金随后被归集到平台金库地址，但用户内部账本仍有 100 USDT。用户提现时，由平台热钱包统一支付。

这是整个系统实现资金管理、高性能内部转账和未来多链扩展的基础。

## 二、核心系统架构

\#chatgpt-mermaid-\_r_2gt\_{font-family:-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"
Apple Color Emoji",Arial,sans-serif,"Segoe UI Emoji","Segoe UI Symbol";font-size:16px;fill:rgb(13, 13, 13);}@keyframes
edge-animation-frame{from{stroke-dashoffset:0;}}@keyframes dash{to{stroke-dashoffset:0;}}#chatgpt-mermaid-\_r_2gt\_
.edge-animation-slow{stroke-dasharray:9,5!important;stroke-dashoffset:900;animation:dash 50s linear
infinite;stroke-linecap:round;}#chatgpt-mermaid-\_r_2gt\_ .edge-animation-fast{stroke-dasharray:9,5!
important;stroke-dashoffset:900;animation:dash 20s linear infinite;stroke-linecap:round;}#chatgpt-mermaid-\_r_2gt\_
.error-icon{fill:rgb(243, 243, 243);}#chatgpt-mermaid-\_r_2gt\_ .error-text{fill:rgb(13, 13, 13);stroke:rgb(13, 13, 13)
;}#chatgpt-mermaid-\_r_2gt\_ .edge-thickness-normal{stroke-width:1px;}#chatgpt-mermaid-\_r_2gt\_
.edge-thickness-thick{stroke-width:3.5px;}#chatgpt-mermaid-\_r_2gt\_ .edge-pattern-solid{stroke-dasharray:
0;}#chatgpt-mermaid-\_r_2gt\_ .edge-thickness-invisible{stroke-width:0;fill:none;}#chatgpt-mermaid-\_r_2gt\_
.edge-pattern-dashed{stroke-dasharray:3;}#chatgpt-mermaid-\_r_2gt\_ .edge-pattern-dotted{stroke-dasharray:
2;}#chatgpt-mermaid-\_r_2gt\_ .marker{fill:rgb(143, 143, 143);stroke:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_2gt\_
.marker.cross{stroke:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_2gt\_ svg{font-family:
-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"Apple Color Emoji",Arial,sans-serif,"
Segoe UI Emoji","Segoe UI Symbol";font-size:16px;}#chatgpt-mermaid-\_r_2gt\_ p{margin:0;}#chatgpt-mermaid-\_r_2gt\_
.label{font-family:-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"Apple Color Emoji"
,Arial,sans-serif,"Segoe UI Emoji","Segoe UI Symbol";color:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2gt\_ .cluster-label
text{fill:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2gt\_ .cluster-label span{color:rgb(13, 13, 13)
;}#chatgpt-mermaid-\_r_2gt\_ .cluster-label span p{background-color:transparent;}#chatgpt-mermaid-\_r_2gt\_ .label
text,#chatgpt-mermaid-\_r_2gt\_ span{fill:rgb(13, 13, 13);color:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2gt\_ .node
rect,#chatgpt-mermaid-\_r_2gt\_ .node circle,#chatgpt-mermaid-\_r_2gt\_ .node ellipse,#chatgpt-mermaid-\_r_2gt\_ .node
polygon,#chatgpt-mermaid-\_r_2gt\_ .node path{fill:rgb(222, 234, 251);stroke:rgb(83, 154, 248);stroke-width:
1px;}#chatgpt-mermaid-\_r_2gt\_ .rough-node .label text,#chatgpt-mermaid-\_r_2gt\_ .node .label
text,#chatgpt-mermaid-\_r_2gt\_ .image-shape .label,#chatgpt-mermaid-\_r_2gt\_ .icon-shape .label{text-anchor:
middle;}#chatgpt-mermaid-\_r_2gt\_ .node .katex path{fill:#000;stroke:#000;stroke-width:1px;}#chatgpt-mermaid-\_r_2gt\_
.rough-node .label,#chatgpt-mermaid-\_r_2gt\_ .node .label,#chatgpt-mermaid-\_r_2gt\_ .image-shape
.label,#chatgpt-mermaid-\_r_2gt\_ .icon-shape .label{text-align:center;}#chatgpt-mermaid-\_r_2gt\_
.node.clickable{cursor:pointer;}#chatgpt-mermaid-\_r_2gt\_ .root .anchor path{fill:rgb(143, 143, 143)!
important;stroke-width:0;stroke:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_2gt\_ .arrowheadPath{fill:rgb(143, 143, 143)
;}#chatgpt-mermaid-\_r_2gt\_ .edgePath .path{stroke:rgb(143, 143, 143);stroke-width:1px;}#chatgpt-mermaid-\_r_2gt\_
.flowchart-link{stroke:rgb(143, 143, 143);fill:none;}#chatgpt-mermaid-\_r_2gt\_ .edgeLabel{background-color:rgb(252,
252, 252);text-align:center;}#chatgpt-mermaid-\_r_2gt\_ .edgeLabel p{background-color:rgb(252, 252, 252)
;}#chatgpt-mermaid-\_r_2gt\_ .edgeLabel rect{opacity:0.5;background-color:rgb(252, 252, 252);fill:rgb(252, 252, 252)
;}#chatgpt-mermaid-\_r_2gt\_ .labelBkg{background-color:rgba(252, 252, 252, 0.5);}#chatgpt-mermaid-\_r_2gt\_ .cluster
rect{fill:rgb(243, 243, 243);stroke:rgba(0, 0, 0, 0.1);stroke-width:1px;}#chatgpt-mermaid-\_r_2gt\_ .cluster text{fill:
rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2gt\_ .cluster span{color:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2gt\_
div.mermaidTooltip{position:absolute;text-align:center;max-width:200px;padding:2px;font-family:
-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"Apple Color Emoji",Arial,sans-serif,"
Segoe UI Emoji","Segoe UI Symbol";font-size:12px;background:rgb(243, 243, 243);border:1px solid rgba(0, 0, 0, 0.1)
;border-radius:2px;pointer-events:none;z-index:100;}#chatgpt-mermaid-\_r_2gt\_ .flowchartTitleText{text-anchor:
middle;font-size:18px;fill:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2gt\_ rect.text{fill:none;stroke-width:
0;}#chatgpt-mermaid-\_r_2gt\_ .icon-shape,#chatgpt-mermaid-\_r_2gt\_ .image-shape{background-color:rgb(252, 252, 252)
;text-align:center;}#chatgpt-mermaid-\_r_2gt\_ .icon-shape p,#chatgpt-mermaid-\_r_2gt\_ .image-shape p{background-color:
rgb(252, 252, 252);padding:2px;}#chatgpt-mermaid-\_r_2gt\_ .icon-shape .label rect,#chatgpt-mermaid-\_r_2gt\_
.image-shape .label rect{opacity:0.5;background-color:rgb(252, 252, 252);fill:rgb(252, 252, 252)
;}#chatgpt-mermaid-\_r_2gt\_ .label-icon{display:inline-block;height:1em;overflow:visible;vertical-align:
-0.125em;}#chatgpt-mermaid-\_r_2gt\_ .node .label-icon path{fill:currentColor;stroke:revert;stroke-width:
revert;}#chatgpt-mermaid-\_r_2gt\_ .node .neo-node{stroke:rgb(83, 154, 248)
;}#chatgpt-mermaid-\_r_2gt\_ [data-look="neo"].node rect,#chatgpt-mermaid-\_r_2gt\_ [data-look="neo"].cluster
rect,#chatgpt-mermaid-\_r_2gt\_ [data-look="neo"].node polygon{stroke:url(#chatgpt-mermaid-\_r_2gt\_-gradient);filter:
drop-shadow( 1px 2px 2px rgba(185,185,185,1));}#chatgpt-mermaid-\_r_2gt\_ [data-look="neo"].swimlane.cluster
rect{filter:none;}#chatgpt-mermaid-\_r_2gt\_ [data-look="neo"].node path{stroke:url(#chatgpt-mermaid-\_r_2gt\_-gradient)
;stroke-width:1px;}#chatgpt-mermaid-\_r_2gt\_ [data-look="neo"].node .outer-path{filter:drop-shadow( 1px 2px 2px rgba(
185,185,185,1));}#chatgpt-mermaid-\_r_2gt\_ [data-look="neo"].node .neo-line path{stroke:rgb(83, 154, 248);filter:
none;}#chatgpt-mermaid-\_r_2gt\_ [data-look="neo"].node circle{stroke:url(#chatgpt-mermaid-\_r_2gt\_-gradient);filter:
drop-shadow( 1px 2px 2px rgba(185,185,185,1));}#chatgpt-mermaid-\_r_2gt\_ [data-look="neo"].node circle
.state-start{fill:#000000;}#chatgpt-mermaid-\_r_2gt\_ [data-look="neo"].icon-shape .icon{fill:url(
#chatgpt-mermaid-\_r_2gt\_-gradient);filter:drop-shadow( 1px 2px 2px rgba(185,185,185,1))
;}#chatgpt-mermaid-\_r_2gt\_ [data-look="neo"].icon-shape .icon-neo path{stroke:url(#chatgpt-mermaid-\_r_2gt\_-gradient)
;filter:drop-shadow( 1px 2px 2px rgba(185,185,185,1));}#chatgpt-mermaid-\_r_2gt\_ .node text{font-size:14px;font-weight:
600;letter-spacing:normal;fill:rgb(0, 79, 153);}#chatgpt-mermaid-\_r_2gt\_ .edgeLabels text{font-size:13px;font-weight:
600;letter-spacing:-0.08px;fill:rgb(0, 79, 153);}#chatgpt-mermaid-\_r_2gt\_ .node tspan[font-weight="normal"]
,#chatgpt-mermaid-\_r_2gt\_ .edgeLabels tspan[font-weight="normal"]{font-weight:600;}#chatgpt-mermaid-\_r_2gt\_
.edgeLabel .label rect{opacity:1;rx:13px;ry:13px;fill:rgb(245, 250, 255);stroke:rgb(206, 219, 229);stroke-width:
1px;}#chatgpt-mermaid-\_r_2gt\_ .node rect,#chatgpt-mermaid-\_r_2gt\_ .node circle,#chatgpt-mermaid-\_r_2gt\_ .node
ellipse,#chatgpt-mermaid-\_r_2gt\_ .node polygon,#chatgpt-mermaid-\_r_2gt\_ .node path{fill:rgb(229, 243, 255);stroke:
rgba(0, 0, 0, 0.1);stroke-width:1px;}#chatgpt-mermaid-\_r_2gt\_ .node rect{rx:16px;ry:16px;}#chatgpt-mermaid-\_r_2gt\_
.node.mermaid-decision .label-container{fill:rgb(245, 250, 255);stroke:rgb(206, 219, 229);stroke-dasharray:
2,2;}#chatgpt-mermaid-\_r_2gt\_ .edgePaths .flowchart-link{stroke:rgb(143, 143, 143);stroke-width:1px;stroke-linecap:
round;stroke-linejoin:round;}#chatgpt-mermaid-\_r_2gt\_ .marker{fill:rgb(143, 143, 143);stroke:rgb(143, 143, 143)
;}#chatgpt-mermaid-\_r_2gt\_ :root{--mermaid-font-family:-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe
UI",Helvetica,"Apple Color Emoji",Arial,sans-serif,"Segoe UI Emoji","Segoe UI Symbol";}安全域区块链服务钱包平台核心独立签名服务密钥托管
KMS / HSM / MPCEVM 链适配器充值扫描与确认资金归集与 Gas 管理交易广播与状态跟踪Wallet Platform
API多租户与用户中心资产与双重记账账本提现与风控引擎HD 地址管理第三方租户业务系统API Gateway / 加密认证区块链
RPCPostgreSQLOutbox / 消息队列

## 三、一期必须重点解决的六个技术问题

| 技术问题      | 设计要求                           |
|-----------|--------------------------------|
| HD 私钥安全   | 普通业务服务只使用扩展公钥派生地址，签名必须进入独立安全域  |
| 租户资产隔离    | 资金账本按租户核算，必要时使用每租户独立根密钥与归集钱包   |
| 充值可靠性     | 区块扫描、确认策略、Reorg 回滚、重复事件幂等入账    |
| 提现安全性     | 冻结余额、审批、Nonce 管理、持久化签名交易和防重复支付 |
| ERC-20 归集 | 需要额外原生币 Gas、动态归集策略以及成本控制       |
| 未来多链扩展    | 业务层不绑定 EVM 的地址、Nonce、Gas 和签名算法 |

HD 派生设计参考 BIP32/BIP44；ERC-20 充值识别基于标准事件，但真实到账处理必须同时考虑网络确认和代币行为。

[image](https://www.google.com/s2/favicons?domain=https://github.com\&sz=32)

GitHub

+3

## 四、推荐实施顺序

第一阶段：平台基础

Rust 项目框架、多租户、HD 地址分配、账本、API 身份认证与安全边界。

第二阶段：充值与归集

EVM 监听、ERC-20 解析、确认机制、Reorg 恢复、自动归集及 Gas 管理。

第三阶段：提现与资金安全

提现状态机、风控审批、Signer、Nonce 管理、交易跟踪与失败恢复。

第四阶段：开放平台及上线

开放 API、Webhook、管理后台、对账、压测、安全审计和灰度运行。

## 五、完整 Markdown 方案

下载 Web3 多租户托管钱包一期完整架构方案.md

包含 18 个章节、系统架构图、充值时序图、提现状态机、核心数据表、REST API 设计、Rust 项目结构、实施里程碑及测试验收标准。

整体上，我建议把一期当作一个金融级资金托管系统来建设，而不是普通的钱包地址管理服务。
特别是资金账本、签名权限、提现防重复执行这三个模块，应该在架构阶段就明确边界，而不是开发完成后再补充。

二期接入 TRON 和 Solana 时，理想情况下只需增加链适配器、对应的密钥/签名实现和资源管理策略，原有多租户体系、账户账本和开放
API 均可复用。

# 问2

一期重点功能：0.怎么和第三方业务进行安全集成和通讯，1.需要思考怎么安全存储助记词，2.怎么根据租户ID和租户用户ID生成唯一的账户信息，3.怎么进行链币和ERC20充值、提现、冻结、解冻，4.怎么进行最优化归集（节约Gas
fee），5.怎么做提现的风控以及最优提现方案。重点按照这些功能重点考虑架构

# 答案2

下面继续细化为可以直接指导 Rust 开发的设计。相比第一版，最重要的变化是：按资金安全边界拆模块，而不是单纯按业务功能拆服务。

## 0. 第三方业务平台的安全集成

### 0.1 接入与安全策略

第三方只需要知道自己的 `tenant_id`、用户 ID、资产余额和交易订单，不需要接触任何链上私钥。

建议 API 采用四层安全机制：

| 层次   | 技术方案                         | 主要防范风险     |
|------|------------------------------|------------|
| 传输安全 | TLS 1.3，提现接口建议 mTLS          | 通信窃听、中间人攻击 |
| 请求认证 | API Key ID + Ed25519 请求签名    | 请求伪造、篡改    |
| 重放保护 | 时间戳 + 随机 nonce + 有效期         | 重复提交有效请求   |
| 业务幂等 | `Idempotency-Key` + 业务订单唯一约束 | 重复冻结、重复提现  |

请求签名建议参考 RFC 9421 HTTP Message Signatures，避免自行设计不完整的签名规范。

[image](https://www.google.com/s2/favicons?domain=https://datatracker.ietf.org\&sz=32)

HTTP Message Signatures

+1

第三方发起提现的安全调用链

LedgerRisk EngineWallet CoreAPI Gateway租户服务端LedgerRisk EngineWallet CoreAPI
Gateway租户服务端#chatgpt-mermaid-\_r_2o1\_{font-family:-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe
UI",Helvetica,"Apple Color Emoji",Arial,sans-serif,"Segoe UI Emoji","Segoe UI Symbol";font-size:16px;fill:rgb(13, 13,
13);}@keyframes edge-animation-frame{from{stroke-dashoffset:0;}}@keyframes dash{to{stroke-dashoffset:
0;}}#chatgpt-mermaid-\_r_2o1\_ .edge-animation-slow{stroke-dasharray:9,5!important;stroke-dashoffset:900;animation:dash
50s linear infinite;stroke-linecap:round;}#chatgpt-mermaid-\_r_2o1\_ .edge-animation-fast{stroke-dasharray:9,5!
important;stroke-dashoffset:900;animation:dash 20s linear infinite;stroke-linecap:round;}#chatgpt-mermaid-\_r_2o1\_
.error-icon{fill:rgb(243, 243, 243);}#chatgpt-mermaid-\_r_2o1\_ .error-text{fill:rgb(13, 13, 13);stroke:rgb(13, 13, 13)
;}#chatgpt-mermaid-\_r_2o1\_ .edge-thickness-normal{stroke-width:1px;}#chatgpt-mermaid-\_r_2o1\_
.edge-thickness-thick{stroke-width:3.5px;}#chatgpt-mermaid-\_r_2o1\_ .edge-pattern-solid{stroke-dasharray:
0;}#chatgpt-mermaid-\_r_2o1\_ .edge-thickness-invisible{stroke-width:0;fill:none;}#chatgpt-mermaid-\_r_2o1\_
.edge-pattern-dashed{stroke-dasharray:3;}#chatgpt-mermaid-\_r_2o1\_ .edge-pattern-dotted{stroke-dasharray:
2;}#chatgpt-mermaid-\_r_2o1\_ .marker{fill:rgb(143, 143, 143);stroke:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_2o1\_
.marker.cross{stroke:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_2o1\_ svg{font-family:
-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"Apple Color Emoji",Arial,sans-serif,"
Segoe UI Emoji","Segoe UI Symbol";font-size:16px;}#chatgpt-mermaid-\_r_2o1\_ p{margin:0;}#chatgpt-mermaid-\_r_2o1\_
.actor{stroke:rgb(83, 154, 248);fill:rgb(222, 234, 251);stroke-width:1;}#chatgpt-mermaid-\_r_2o1\_
rect.actor.outer-path[data-look="neo"]{filter:drop-shadow( 1px 2px 2px rgba(185,185,185,1));}#chatgpt-mermaid-\_r_2o1\_
rect.note[data-look="neo"]{stroke:rgb(107, 198, 127);fill:rgb(243, 243, 243);filter:drop-shadow( 1px 2px 2px rgba(
185,185,185,1));}#chatgpt-mermaid-\_r_2o1\_ text.actor>tspan{fill:rgb(13, 13, 13);stroke:
none;}#chatgpt-mermaid-\_r_2o1\_ .actor-line{stroke:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_2o1\_
.innerArc{stroke-width:1.5;stroke-dasharray:none;}#chatgpt-mermaid-\_r_2o1\_ .messageLine0{stroke-width:
1.5;stroke-dasharray:none;stroke:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_2o1\_ .messageLine1{stroke-width:
1.5;stroke-dasharray:2,2;stroke:rgb(143, 143, 143)
;}#chatgpt-mermaid-\_r_2o1\_ [id$="-arrowhead"] path{fill:rgb(143, 143, 143);stroke:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_2o1\_ .sequenceNumber{fill:#707070;}#chatgpt-mermaid-\_r_2o1\_ [id$="-sequencenumber"]
{fill:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_2o1\_ [id$="-crosshead"] path{fill:rgb(143, 143, 143);stroke:rgb(143,
143, 143);}#chatgpt-mermaid-\_r_2o1\_ .messageText{fill:rgb(13, 13, 13);stroke:none;}#chatgpt-mermaid-\_r_2o1\_
.labelBox{stroke:rgba(0, 0, 0, 0.1);fill:rgb(252, 252, 252);filter:none;}#chatgpt-mermaid-\_r_2o1\_
.labelText,#chatgpt-mermaid-\_r_2o1\_ .labelText>tspan{fill:rgb(13, 13, 13);stroke:none;}#chatgpt-mermaid-\_r_2o1\_
.loopText,#chatgpt-mermaid-\_r_2o1\_ .loopText>tspan{fill:rgb(13, 13, 13);stroke:none;}#chatgpt-mermaid-\_r_2o1\_
.sectionTitle,#chatgpt-mermaid-\_r_2o1\_ .sectionTitle>tspan{fill:rgb(13, 13, 13);stroke:
none;}#chatgpt-mermaid-\_r_2o1\_ .loopLine{stroke-width:2px;stroke-dasharray:2,2;stroke:rgba(0, 0, 0, 0.1);fill:rgba(0,
0, 0, 0.1);}#chatgpt-mermaid-\_r_2o1\_ .note{stroke:rgb(107, 198, 127);fill:rgb(243, 243, 243)
;}#chatgpt-mermaid-\_r_2o1\_ .noteText,#chatgpt-mermaid-\_r_2o1\_ .noteText>tspan{fill:rgb(13, 13, 13);stroke:
none;font-weight:normal;}#chatgpt-mermaid-\_r_2o1\_ .activation0{fill:rgb(243, 243, 243);stroke:hsl(0, 0%,
85.2941176471%);}#chatgpt-mermaid-\_r_2o1\_ .activation1{fill:rgb(243, 243, 243);stroke:hsl(0, 0%, 85.2941176471%)
;}#chatgpt-mermaid-\_r_2o1\_ .activation2{fill:rgb(243, 243, 243);stroke:hsl(0, 0%, 85.2941176471%)
;}#chatgpt-mermaid-\_r_2o1\_ .actorPopupMenu{position:absolute;}#chatgpt-mermaid-\_r_2o1\_
.actorPopupMenuPanel{position:absolute;fill:rgb(222, 234, 251);box-shadow:0px 8px 16px 0px rgba(0,0,0,0.2);filter:
drop-shadow(3px 5px 2px rgb(0 0 0 / 0.4));}#chatgpt-mermaid-\_r_2o1\_ .actor-man circle,#chatgpt-mermaid-\_r_2o1\_
line{fill:rgb(222, 234, 251);stroke-width:2px;}#chatgpt-mermaid-\_r_2o1\_ g rect.rect{filter:drop-shadow( 1px 2px 2px
rgba(185,185,185,1));stroke:rgb(83, 154, 248);}#chatgpt-mermaid-\_r_2o1\_ .node .neo-node{stroke:rgb(83, 154, 248)
;}#chatgpt-mermaid-\_r_2o1\_ [data-look="neo"].node rect,#chatgpt-mermaid-\_r_2o1\_ [data-look="neo"].cluster
rect,#chatgpt-mermaid-\_r_2o1\_ [data-look="neo"].node polygon{stroke:url(#chatgpt-mermaid-\_r_2o1\_-gradient);filter:
drop-shadow( 1px 2px 2px rgba(185,185,185,1));}#chatgpt-mermaid-\_r_2o1\_ [data-look="neo"].swimlane.cluster
rect{filter:none;}#chatgpt-mermaid-\_r_2o1\_ [data-look="neo"].node path{stroke:url(#chatgpt-mermaid-\_r_2o1\_-gradient)
;stroke-width:1px;}#chatgpt-mermaid-\_r_2o1\_ [data-look="neo"].node .outer-path{filter:drop-shadow( 1px 2px 2px rgba(
185,185,185,1));}#chatgpt-mermaid-\_r_2o1\_ [data-look="neo"].node .neo-line path{stroke:rgb(83, 154, 248);filter:
none;}#chatgpt-mermaid-\_r_2o1\_ [data-look="neo"].node circle{stroke:url(#chatgpt-mermaid-\_r_2o1\_-gradient);filter:
drop-shadow( 1px 2px 2px rgba(185,185,185,1));}#chatgpt-mermaid-\_r_2o1\_ [data-look="neo"].node circle
.state-start{fill:#000000;}#chatgpt-mermaid-\_r_2o1\_ [data-look="neo"].icon-shape .icon{fill:url(
#chatgpt-mermaid-\_r_2o1\_-gradient);filter:drop-shadow( 1px 2px 2px rgba(185,185,185,1))
;}#chatgpt-mermaid-\_r_2o1\_ [data-look="neo"].icon-shape .icon-neo path{stroke:url(#chatgpt-mermaid-\_r_2o1\_-gradient)
;filter:drop-shadow( 1px 2px 2px rgba(185,185,185,1));}#chatgpt-mermaid-\_r_2o1\_ :root{--mermaid-font-family:
-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"Apple Color Emoji",Arial,sans-serif,"
Segoe UI Emoji","Segoe UI Symbol";}HTTPS + 签名 + nonce +
幂等键验签、防重放、租户权限校验已认证租户上下文绑定租户、校验订单唯一性提现风险预检查允许或拒绝原子创建订单并冻结余额成功202
Accepted + withdrawal_id

特别注意： `tenant_id` 必须由已验证的 API 凭证确定，不能相信第三方请求 Body 中自行声明的租户 ID。

### 0.2 是否需要 HTTP 报文加密？

TLS 本身已经提供传输加密。对于希望额外保护敏感交易信息的租户，可增加基于 HPKE 或 JWE 的应用层报文加密。

但请求签名与报文加密解决的是不同问题：

- 签名： 确认请求者身份，防止交易参数被篡改。
- 加密： 防止未授权方读取报文内容。
- 幂等： 防止同一业务指令被重复执行。

提现接口还应使用单独的 API 权限，例如 `withdraw:create`，避免查询余额的凭证也能发起资金转出。

## 1. 助记词与私钥的安全架构

这是一期安全等级最高的模块。

### 1.1 推荐每个租户独立 HD 根密钥

虽然技术上可以使用一套平台助记词派生全部租户的钱包，但这种模式存在明显的系统性风险：一旦根密钥泄露，所有租户资产都受到威胁。

推荐：

```
Wallet Vault
├── Tenant A
│   ├── Root Key A
│   ├── Deposit Addresses
│   └── Treasury Wallets
├── Tenant B
│   ├── Root Key B
│   ├── Deposit Addresses
│   └── Treasury Wallets
└── Tenant C
    ├── Root Key C
    ├── Deposit Addresses
    └── Treasury Wallets
```

每租户独立根密钥能够缩小单一根密钥泄露时的影响范围，但不能防止拥有全部密钥解密和签名权限的服务被攻陷。因此签名授权、访问隔离和风险限额仍然不可缺少。

### 1.2 推荐密钥存储方案

\#chatgpt-mermaid-\_r_2og\_{font-family:-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"
Apple Color Emoji",Arial,sans-serif,"Segoe UI Emoji","Segoe UI Symbol";font-size:16px;fill:rgb(13, 13, 13);}@keyframes
edge-animation-frame{from{stroke-dashoffset:0;}}@keyframes dash{to{stroke-dashoffset:0;}}#chatgpt-mermaid-\_r_2og\_
.edge-animation-slow{stroke-dasharray:9,5!important;stroke-dashoffset:900;animation:dash 50s linear
infinite;stroke-linecap:round;}#chatgpt-mermaid-\_r_2og\_ .edge-animation-fast{stroke-dasharray:9,5!
important;stroke-dashoffset:900;animation:dash 20s linear infinite;stroke-linecap:round;}#chatgpt-mermaid-\_r_2og\_
.error-icon{fill:rgb(243, 243, 243);}#chatgpt-mermaid-\_r_2og\_ .error-text{fill:rgb(13, 13, 13);stroke:rgb(13, 13, 13)
;}#chatgpt-mermaid-\_r_2og\_ .edge-thickness-normal{stroke-width:1px;}#chatgpt-mermaid-\_r_2og\_
.edge-thickness-thick{stroke-width:3.5px;}#chatgpt-mermaid-\_r_2og\_ .edge-pattern-solid{stroke-dasharray:
0;}#chatgpt-mermaid-\_r_2og\_ .edge-thickness-invisible{stroke-width:0;fill:none;}#chatgpt-mermaid-\_r_2og\_
.edge-pattern-dashed{stroke-dasharray:3;}#chatgpt-mermaid-\_r_2og\_ .edge-pattern-dotted{stroke-dasharray:
2;}#chatgpt-mermaid-\_r_2og\_ .marker{fill:rgb(143, 143, 143);stroke:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_2og\_
.marker.cross{stroke:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_2og\_ svg{font-family:
-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"Apple Color Emoji",Arial,sans-serif,"
Segoe UI Emoji","Segoe UI Symbol";font-size:16px;}#chatgpt-mermaid-\_r_2og\_ p{margin:0;}#chatgpt-mermaid-\_r_2og\_
.label{font-family:-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"Apple Color Emoji"
,Arial,sans-serif,"Segoe UI Emoji","Segoe UI Symbol";color:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2og\_ .cluster-label
text{fill:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2og\_ .cluster-label span{color:rgb(13, 13, 13)
;}#chatgpt-mermaid-\_r_2og\_ .cluster-label span p{background-color:transparent;}#chatgpt-mermaid-\_r_2og\_ .label
text,#chatgpt-mermaid-\_r_2og\_ span{fill:rgb(13, 13, 13);color:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2og\_ .node
rect,#chatgpt-mermaid-\_r_2og\_ .node circle,#chatgpt-mermaid-\_r_2og\_ .node ellipse,#chatgpt-mermaid-\_r_2og\_ .node
polygon,#chatgpt-mermaid-\_r_2og\_ .node path{fill:rgb(222, 234, 251);stroke:rgb(83, 154, 248);stroke-width:
1px;}#chatgpt-mermaid-\_r_2og\_ .rough-node .label text,#chatgpt-mermaid-\_r_2og\_ .node .label
text,#chatgpt-mermaid-\_r_2og\_ .image-shape .label,#chatgpt-mermaid-\_r_2og\_ .icon-shape .label{text-anchor:
middle;}#chatgpt-mermaid-\_r_2og\_ .node .katex path{fill:#000;stroke:#000;stroke-width:1px;}#chatgpt-mermaid-\_r_2og\_
.rough-node .label,#chatgpt-mermaid-\_r_2og\_ .node .label,#chatgpt-mermaid-\_r_2og\_ .image-shape
.label,#chatgpt-mermaid-\_r_2og\_ .icon-shape .label{text-align:center;}#chatgpt-mermaid-\_r_2og\_
.node.clickable{cursor:pointer;}#chatgpt-mermaid-\_r_2og\_ .root .anchor path{fill:rgb(143, 143, 143)!
important;stroke-width:0;stroke:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_2og\_ .arrowheadPath{fill:rgb(143, 143, 143)
;}#chatgpt-mermaid-\_r_2og\_ .edgePath .path{stroke:rgb(143, 143, 143);stroke-width:1px;}#chatgpt-mermaid-\_r_2og\_
.flowchart-link{stroke:rgb(143, 143, 143);fill:none;}#chatgpt-mermaid-\_r_2og\_ .edgeLabel{background-color:rgb(252,
252, 252);text-align:center;}#chatgpt-mermaid-\_r_2og\_ .edgeLabel p{background-color:rgb(252, 252, 252)
;}#chatgpt-mermaid-\_r_2og\_ .edgeLabel rect{opacity:0.5;background-color:rgb(252, 252, 252);fill:rgb(252, 252, 252)
;}#chatgpt-mermaid-\_r_2og\_ .labelBkg{background-color:rgba(252, 252, 252, 0.5);}#chatgpt-mermaid-\_r_2og\_ .cluster
rect{fill:rgb(243, 243, 243);stroke:rgba(0, 0, 0, 0.1);stroke-width:1px;}#chatgpt-mermaid-\_r_2og\_ .cluster text{fill:
rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2og\_ .cluster span{color:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2og\_
div.mermaidTooltip{position:absolute;text-align:center;max-width:200px;padding:2px;font-family:
-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"Apple Color Emoji",Arial,sans-serif,"
Segoe UI Emoji","Segoe UI Symbol";font-size:12px;background:rgb(243, 243, 243);border:1px solid rgba(0, 0, 0, 0.1)
;border-radius:2px;pointer-events:none;z-index:100;}#chatgpt-mermaid-\_r_2og\_ .flowchartTitleText{text-anchor:
middle;font-size:18px;fill:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2og\_ rect.text{fill:none;stroke-width:
0;}#chatgpt-mermaid-\_r_2og\_ .icon-shape,#chatgpt-mermaid-\_r_2og\_ .image-shape{background-color:rgb(252, 252, 252)
;text-align:center;}#chatgpt-mermaid-\_r_2og\_ .icon-shape p,#chatgpt-mermaid-\_r_2og\_ .image-shape p{background-color:
rgb(252, 252, 252);padding:2px;}#chatgpt-mermaid-\_r_2og\_ .icon-shape .label rect,#chatgpt-mermaid-\_r_2og\_
.image-shape .label rect{opacity:0.5;background-color:rgb(252, 252, 252);fill:rgb(252, 252, 252)
;}#chatgpt-mermaid-\_r_2og\_ .label-icon{display:inline-block;height:1em;overflow:visible;vertical-align:
-0.125em;}#chatgpt-mermaid-\_r_2og\_ .node .label-icon path{fill:currentColor;stroke:revert;stroke-width:
revert;}#chatgpt-mermaid-\_r_2og\_ .node .neo-node{stroke:rgb(83, 154, 248)
;}#chatgpt-mermaid-\_r_2og\_ [data-look="neo"].node rect,#chatgpt-mermaid-\_r_2og\_ [data-look="neo"].cluster
rect,#chatgpt-mermaid-\_r_2og\_ [data-look="neo"].node polygon{stroke:url(#chatgpt-mermaid-\_r_2og\_-gradient);filter:
drop-shadow( 1px 2px 2px rgba(185,185,185,1));}#chatgpt-mermaid-\_r_2og\_ [data-look="neo"].swimlane.cluster
rect{filter:none;}#chatgpt-mermaid-\_r_2og\_ [data-look="neo"].node path{stroke:url(#chatgpt-mermaid-\_r_2og\_-gradient)
;stroke-width:1px;}#chatgpt-mermaid-\_r_2og\_ [data-look="neo"].node .outer-path{filter:drop-shadow( 1px 2px 2px rgba(
185,185,185,1));}#chatgpt-mermaid-\_r_2og\_ [data-look="neo"].node .neo-line path{stroke:rgb(83, 154, 248);filter:
none;}#chatgpt-mermaid-\_r_2og\_ [data-look="neo"].node circle{stroke:url(#chatgpt-mermaid-\_r_2og\_-gradient);filter:
drop-shadow( 1px 2px 2px rgba(185,185,185,1));}#chatgpt-mermaid-\_r_2og\_ [data-look="neo"].node circle
.state-start{fill:#000000;}#chatgpt-mermaid-\_r_2og\_ [data-look="neo"].icon-shape .icon{fill:url(
#chatgpt-mermaid-\_r_2og\_-gradient);filter:drop-shadow( 1px 2px 2px rgba(185,185,185,1))
;}#chatgpt-mermaid-\_r_2og\_ [data-look="neo"].icon-shape .icon-neo path{stroke:url(#chatgpt-mermaid-\_r_2og\_-gradient)
;filter:drop-shadow( 1px 2px 2px rgba(185,185,185,1));}#chatgpt-mermaid-\_r_2og\_ .node text{font-size:14px;font-weight:
600;letter-spacing:normal;fill:rgb(0, 79, 153);}#chatgpt-mermaid-\_r_2og\_ .edgeLabels text{font-size:13px;font-weight:
600;letter-spacing:-0.08px;fill:rgb(0, 79, 153);}#chatgpt-mermaid-\_r_2og\_ .node tspan[font-weight="normal"]
,#chatgpt-mermaid-\_r_2og\_ .edgeLabels tspan[font-weight="normal"]{font-weight:600;}#chatgpt-mermaid-\_r_2og\_
.edgeLabel .label rect{opacity:1;rx:13px;ry:13px;fill:rgb(245, 250, 255);stroke:rgb(206, 219, 229);stroke-width:
1px;}#chatgpt-mermaid-\_r_2og\_ .node rect,#chatgpt-mermaid-\_r_2og\_ .node circle,#chatgpt-mermaid-\_r_2og\_ .node
ellipse,#chatgpt-mermaid-\_r_2og\_ .node polygon,#chatgpt-mermaid-\_r_2og\_ .node path{fill:rgb(229, 243, 255);stroke:
rgba(0, 0, 0, 0.1);stroke-width:1px;}#chatgpt-mermaid-\_r_2og\_ .node rect{rx:16px;ry:16px;}#chatgpt-mermaid-\_r_2og\_
.node.mermaid-decision .label-container{fill:rgb(245, 250, 255);stroke:rgb(206, 219, 229);stroke-dasharray:
2,2;}#chatgpt-mermaid-\_r_2og\_ .edgePaths .flowchart-link{stroke:rgb(143, 143, 143);stroke-width:1px;stroke-linecap:
round;stroke-linejoin:round;}#chatgpt-mermaid-\_r_2og\_ .marker{fill:rgb(143, 143, 143);stroke:rgb(143, 143, 143)
;}#chatgpt-mermaid-\_r_2og\_ :root{--mermaid-font-family:-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe
UI",Helvetica,"Apple Color Emoji",Arial,sans-serif,"Segoe UI Emoji","Segoe UI Symbol";}安全环境生成高熵随机种子AES-256-GCM
加密KMS 管理密钥 KEK仅存密文种子与加密 DEK隔离 Signer / Vault经过风控授权的签名请求临时解密并派生子密钥生成交易签名清理敏感内存，返回签名交易

KMS 信封加密是成熟的密钥保护设计：数据使用独立数据密钥加密，数据密钥再由上层管理密钥保护。

[image](https://www.google.com/s2/favicons?domain=https://docs.aws.amazon.com\&sz=32)

AWS Encryption SDK

+1

这里有三项必须强调的安全约束：

1. KMS 加密不等于 HSM 内不可导出的私钥。 如果 Signer 可以解密种子，Signer 被攻陷仍有严重风险。高价值生产资产推荐经过验证的
   HSM/MPC 托管方案，并确认供应商真正支持 HD 派生。
2. 普通 API、数据库和链监听服务不得获取明文种子。 Signer 只接受已授权、限定用途和额度的交易签名请求。
3. 恢复能力与加密能力同等重要。 必须做离线加密备份、双人控制、恢复演练，以及根密钥泄露后的资产迁移预案。

另外，BIP32 有一个需要特别防范的安全问题：如果某个非硬化子私钥泄露，同时其父级扩展公钥 `xpub` 也泄露，攻击者可能恢复相应父私钥。因此不能把
`xpub` 当成完全不敏感的数据。

[image](https://www.google.com/s2/favicons?domain=https://github.com\&sz=32)

GitHub

## 2. 根据租户 ID 和用户 ID 创建唯一账户

我不建议直接进行：

```
Hash(tenant_id + user_id) -> HD 派生索引
```

虽然看起来具有确定性，但会引入派生索引范围限制、哈希碰撞、用户 ID 规范化和后期迁移等问题。

推荐设计：数据库负责唯一身份映射，HD 钱包负责生成链上地址，两者职责分离。

### 2.1 账户映射

```
tenant_id + external_user_id
              |
              v
      TenantUserAccount
              |
              +-- internal_user_id
              +-- ledger_accounts
              +-- wallet_address_index
              |
              v
      HD 派生充值地址
```

数据库层必须具有以下约束：

```
UNIQUE (tenant_id, external_user_id)
UNIQUE (key_root_id, derivation_path)
UNIQUE (chain_id, address_bytes)
```

最后一项必须按业务需要区分地址角色与归属；如果同一 EVM 地址跨多个网络使用，`chain_id` 必须参与充值匹配，不能仅通过地址识别资金归属。

### 2.2 推荐地址派生路径

每租户一套独立 EVM 根种子：

```
m / 44' / 60' / 0' / 0 / address_index
```

其中 `address_index` 在所属根密钥范围内通过数据库事务原子分配，永不重复使用或回收。

一次分配成功后：

- 相同租户、相同用户，重复调用返回已有账户。
- 不同租户，即使用户 ID 相同，也属于不同账户。
- 同一用户可以在不同 EVM 网络使用同一派生地址，但各网络的余额、订单和充值事件必须严格独立。
- 后期新增 TRON、Solana 时，由不同的密钥派生策略和链适配器实现，不改变用户的内部身份。

这符合 BIP44 的基本派生结构；真实部署时，还必须持久化根密钥版本、派生路径和地址分配信息，以便备份恢复和密钥轮换。

[image](https://www.google.com/s2/favicons?domain=https://github.com\&sz=32)

GitHub

+1

## 3. 链币与 ERC-20 的充值、提现、冻结、解冻

这一部分建议以双重记账资金账本作为核心，而不是简单修改用户余额字段。

### 3.1 内部资金账户模型

每个用户在每条链的每个资产上拥有独立余额。

| 余额类型              | 用途              | 是否可提现 |
|-------------------|-----------------|-------|
| `AVAILABLE`       | 可用余额            | 是     |
| `PENDING_DEPOSIT` | 链上已发现，尚未达到最终性要求 | 否     |
| `HELD_WITHDRAWAL` | 提现申请占用资金        | 否     |
| `HELD_RISK`       | 平台或业务风控冻结       | 否     |

以用户充值 100 USDT、申请提现 40 USDT 为例：

资金账本变化示例 · USDT

可用余额

提现冻结

0306090120充值完成提现申请提现成功

余额按最小单位在数据库中记录，此处换算为 USDT 便于展示。

实际记账必须使用不可变分录：

- 充值成功：增加托管资产，同时增加用户余额负债。
- 提现申请：从可用余额转入提现冻结账户。
- 提现成功：核销提现冻结负债，同时减少平台托管资产。
- 提现确认未执行且安全取消：释放对应冻结金额。
- 风控冻结：转入独立风险冻结账户，不能被普通提现解冻操作释放。

充值归集和用户余额入账必须解耦。 用户充值达到确认条件后，可以先入账，之后再进行归集。

### 3.2 充值的关键问题

EVM 原生币普通转账可以通过区块交易及回执识别，但智能合约内部 ETH 转账不一定能通过普通交易的 `to/value`
查出，所以如果要完整支持原生币充值，还需要 trace 能力或可信的索引服务，并完成链上核验。

ERC-20 则通过白名单合约地址与 `Transfer` 日志发现充值，保存区块哈希、交易哈希、日志索引和最终性状态，确保重复扫描不会重复入账。Ethereum
JSON-RPC 本身支持日志查询及 `safe`、`finalized` 等区块标记，具体链仍须配置自己的最终性策略。

[image](https://www.google.com/s2/favicons?domain=https://ethereum.org\&sz=32)

ethereum.org

+1

## 4. 智能归集：真正降低 Gas 的方案

我建议一期采用 动态阈值 + 延迟归集 + 风险敞口上限 + 热钱包流动性保障。

ERC-20 充值地址归集通常需要两步：

\#chatgpt-mermaid-\_r_2so\_{font-family:-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"
Apple Color Emoji",Arial,sans-serif,"Segoe UI Emoji","Segoe UI Symbol";font-size:16px;fill:rgb(13, 13, 13);}@keyframes
edge-animation-frame{from{stroke-dashoffset:0;}}@keyframes dash{to{stroke-dashoffset:0;}}#chatgpt-mermaid-\_r_2so\_
.edge-animation-slow{stroke-dasharray:9,5!important;stroke-dashoffset:900;animation:dash 50s linear
infinite;stroke-linecap:round;}#chatgpt-mermaid-\_r_2so\_ .edge-animation-fast{stroke-dasharray:9,5!
important;stroke-dashoffset:900;animation:dash 20s linear infinite;stroke-linecap:round;}#chatgpt-mermaid-\_r_2so\_
.error-icon{fill:rgb(243, 243, 243);}#chatgpt-mermaid-\_r_2so\_ .error-text{fill:rgb(13, 13, 13);stroke:rgb(13, 13, 13)
;}#chatgpt-mermaid-\_r_2so\_ .edge-thickness-normal{stroke-width:1px;}#chatgpt-mermaid-\_r_2so\_
.edge-thickness-thick{stroke-width:3.5px;}#chatgpt-mermaid-\_r_2so\_ .edge-pattern-solid{stroke-dasharray:
0;}#chatgpt-mermaid-\_r_2so\_ .edge-thickness-invisible{stroke-width:0;fill:none;}#chatgpt-mermaid-\_r_2so\_
.edge-pattern-dashed{stroke-dasharray:3;}#chatgpt-mermaid-\_r_2so\_ .edge-pattern-dotted{stroke-dasharray:
2;}#chatgpt-mermaid-\_r_2so\_ .marker{fill:rgb(143, 143, 143);stroke:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_2so\_
.marker.cross{stroke:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_2so\_ svg{font-family:
-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"Apple Color Emoji",Arial,sans-serif,"
Segoe UI Emoji","Segoe UI Symbol";font-size:16px;}#chatgpt-mermaid-\_r_2so\_ p{margin:0;}#chatgpt-mermaid-\_r_2so\_
.label{font-family:-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"Apple Color Emoji"
,Arial,sans-serif,"Segoe UI Emoji","Segoe UI Symbol";color:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2so\_ .cluster-label
text{fill:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2so\_ .cluster-label span{color:rgb(13, 13, 13)
;}#chatgpt-mermaid-\_r_2so\_ .cluster-label span p{background-color:transparent;}#chatgpt-mermaid-\_r_2so\_ .label
text,#chatgpt-mermaid-\_r_2so\_ span{fill:rgb(13, 13, 13);color:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2so\_ .node
rect,#chatgpt-mermaid-\_r_2so\_ .node circle,#chatgpt-mermaid-\_r_2so\_ .node ellipse,#chatgpt-mermaid-\_r_2so\_ .node
polygon,#chatgpt-mermaid-\_r_2so\_ .node path{fill:rgb(222, 234, 251);stroke:rgb(83, 154, 248);stroke-width:
1px;}#chatgpt-mermaid-\_r_2so\_ .rough-node .label text,#chatgpt-mermaid-\_r_2so\_ .node .label
text,#chatgpt-mermaid-\_r_2so\_ .image-shape .label,#chatgpt-mermaid-\_r_2so\_ .icon-shape .label{text-anchor:
middle;}#chatgpt-mermaid-\_r_2so\_ .node .katex path{fill:#000;stroke:#000;stroke-width:1px;}#chatgpt-mermaid-\_r_2so\_
.rough-node .label,#chatgpt-mermaid-\_r_2so\_ .node .label,#chatgpt-mermaid-\_r_2so\_ .image-shape
.label,#chatgpt-mermaid-\_r_2so\_ .icon-shape .label{text-align:center;}#chatgpt-mermaid-\_r_2so\_
.node.clickable{cursor:pointer;}#chatgpt-mermaid-\_r_2so\_ .root .anchor path{fill:rgb(143, 143, 143)!
important;stroke-width:0;stroke:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_2so\_ .arrowheadPath{fill:rgb(143, 143, 143)
;}#chatgpt-mermaid-\_r_2so\_ .edgePath .path{stroke:rgb(143, 143, 143);stroke-width:1px;}#chatgpt-mermaid-\_r_2so\_
.flowchart-link{stroke:rgb(143, 143, 143);fill:none;}#chatgpt-mermaid-\_r_2so\_ .edgeLabel{background-color:rgb(252,
252, 252);text-align:center;}#chatgpt-mermaid-\_r_2so\_ .edgeLabel p{background-color:rgb(252, 252, 252)
;}#chatgpt-mermaid-\_r_2so\_ .edgeLabel rect{opacity:0.5;background-color:rgb(252, 252, 252);fill:rgb(252, 252, 252)
;}#chatgpt-mermaid-\_r_2so\_ .labelBkg{background-color:rgba(252, 252, 252, 0.5);}#chatgpt-mermaid-\_r_2so\_ .cluster
rect{fill:rgb(243, 243, 243);stroke:rgba(0, 0, 0, 0.1);stroke-width:1px;}#chatgpt-mermaid-\_r_2so\_ .cluster text{fill:
rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2so\_ .cluster span{color:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2so\_
div.mermaidTooltip{position:absolute;text-align:center;max-width:200px;padding:2px;font-family:
-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"Apple Color Emoji",Arial,sans-serif,"
Segoe UI Emoji","Segoe UI Symbol";font-size:12px;background:rgb(243, 243, 243);border:1px solid rgba(0, 0, 0, 0.1)
;border-radius:2px;pointer-events:none;z-index:100;}#chatgpt-mermaid-\_r_2so\_ .flowchartTitleText{text-anchor:
middle;font-size:18px;fill:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2so\_ rect.text{fill:none;stroke-width:
0;}#chatgpt-mermaid-\_r_2so\_ .icon-shape,#chatgpt-mermaid-\_r_2so\_ .image-shape{background-color:rgb(252, 252, 252)
;text-align:center;}#chatgpt-mermaid-\_r_2so\_ .icon-shape p,#chatgpt-mermaid-\_r_2so\_ .image-shape p{background-color:
rgb(252, 252, 252);padding:2px;}#chatgpt-mermaid-\_r_2so\_ .icon-shape .label rect,#chatgpt-mermaid-\_r_2so\_
.image-shape .label rect{opacity:0.5;background-color:rgb(252, 252, 252);fill:rgb(252, 252, 252)
;}#chatgpt-mermaid-\_r_2so\_ .label-icon{display:inline-block;height:1em;overflow:visible;vertical-align:
-0.125em;}#chatgpt-mermaid-\_r_2so\_ .node .label-icon path{fill:currentColor;stroke:revert;stroke-width:
revert;}#chatgpt-mermaid-\_r_2so\_ .node .neo-node{stroke:rgb(83, 154, 248)
;}#chatgpt-mermaid-\_r_2so\_ [data-look="neo"].node rect,#chatgpt-mermaid-\_r_2so\_ [data-look="neo"].cluster
rect,#chatgpt-mermaid-\_r_2so\_ [data-look="neo"].node polygon{stroke:url(#chatgpt-mermaid-\_r_2so\_-gradient);filter:
drop-shadow( 1px 2px 2px rgba(185,185,185,1));}#chatgpt-mermaid-\_r_2so\_ [data-look="neo"].swimlane.cluster
rect{filter:none;}#chatgpt-mermaid-\_r_2so\_ [data-look="neo"].node path{stroke:url(#chatgpt-mermaid-\_r_2so\_-gradient)
;stroke-width:1px;}#chatgpt-mermaid-\_r_2so\_ [data-look="neo"].node .outer-path{filter:drop-shadow( 1px 2px 2px rgba(
185,185,185,1));}#chatgpt-mermaid-\_r_2so\_ [data-look="neo"].node .neo-line path{stroke:rgb(83, 154, 248);filter:
none;}#chatgpt-mermaid-\_r_2so\_ [data-look="neo"].node circle{stroke:url(#chatgpt-mermaid-\_r_2so\_-gradient);filter:
drop-shadow( 1px 2px 2px rgba(185,185,185,1));}#chatgpt-mermaid-\_r_2so\_ [data-look="neo"].node circle
.state-start{fill:#000000;}#chatgpt-mermaid-\_r_2so\_ [data-look="neo"].icon-shape .icon{fill:url(
#chatgpt-mermaid-\_r_2so\_-gradient);filter:drop-shadow( 1px 2px 2px rgba(185,185,185,1))
;}#chatgpt-mermaid-\_r_2so\_ [data-look="neo"].icon-shape .icon-neo path{stroke:url(#chatgpt-mermaid-\_r_2so\_-gradient)
;filter:drop-shadow( 1px 2px 2px rgba(185,185,185,1));}#chatgpt-mermaid-\_r_2so\_ .node text{font-size:14px;font-weight:
600;letter-spacing:normal;fill:rgb(0, 79, 153);}#chatgpt-mermaid-\_r_2so\_ .edgeLabels text{font-size:13px;font-weight:
600;letter-spacing:-0.08px;fill:rgb(0, 79, 153);}#chatgpt-mermaid-\_r_2so\_ .node tspan[font-weight="normal"]
,#chatgpt-mermaid-\_r_2so\_ .edgeLabels tspan[font-weight="normal"]{font-weight:600;}#chatgpt-mermaid-\_r_2so\_
.edgeLabel .label rect{opacity:1;rx:13px;ry:13px;fill:rgb(245, 250, 255);stroke:rgb(206, 219, 229);stroke-width:
1px;}#chatgpt-mermaid-\_r_2so\_ .node rect,#chatgpt-mermaid-\_r_2so\_ .node circle,#chatgpt-mermaid-\_r_2so\_ .node
ellipse,#chatgpt-mermaid-\_r_2so\_ .node polygon,#chatgpt-mermaid-\_r_2so\_ .node path{fill:rgb(229, 243, 255);stroke:
rgba(0, 0, 0, 0.1);stroke-width:1px;}#chatgpt-mermaid-\_r_2so\_ .node rect{rx:16px;ry:16px;}#chatgpt-mermaid-\_r_2so\_
.node.mermaid-decision .label-container{fill:rgb(245, 250, 255);stroke:rgb(206, 219, 229);stroke-dasharray:
2,2;}#chatgpt-mermaid-\_r_2so\_ .edgePaths .flowchart-link{stroke:rgb(143, 143, 143);stroke-width:1px;stroke-linecap:
round;stroke-linejoin:round;}#chatgpt-mermaid-\_r_2so\_ .marker{fill:rgb(143, 143, 143);stroke:rgb(143, 143, 143)
;}#chatgpt-mermaid-\_r_2so\_ :root{--mermaid-font-family:-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe
UI",Helvetica,"Apple Color Emoji",Arial,sans-serif,"Segoe UI Emoji","Segoe UI Symbol";}Gas Pool原生币储备用户充值地址ERC-20
余额租户 Treasury归集金库租户 Hot Wallet提现资金池补 GasERC-20 transfer按需调拨

对于没有原生币 Gas 的充值 EOA，补 Gas 与 ERC-20 转出通常分别需要一次链上交易。

### 4.1 归集优先级

| 条件          | 归集策略           |
|-------------|----------------|
| 小额充值、Gas 高昂 | 延迟归集，积累多次充值    |
| 大额充值，风险敞口过高 | 优先归集，即使 Gas 较高 |
| 热钱包提现资金不足   | 提升归集和金库补仓优先级   |
| Gas 处于低成本区间 | 对满足阈值的地址批量调度   |
| 充值地址长期沉淀资产  | 达到最长驻留时间后处理    |

关键不在于“如何让一笔 ERC-20 归集交易便宜”，而在于如何减少没有必要的链上交易，并控制额外的 Gas 补充成本。

例如，某地址连续收到 10 次 USDT 充值，若无风险敞口或流动性压力，可以在达到阈值后只进行一次 ERC-20 归集，而不是产生 10 次归集交易。

归集服务还需要保证同一地址同一时间只能有一个活跃归集任务，避免重复补 Gas 和重复签名。

## 5. 最优提现架构

提现建议采用 风控决策与链执行分离 的架构。

\#chatgpt-mermaid-\_r_2t1\_{font-family:-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"
Apple Color Emoji",Arial,sans-serif,"Segoe UI Emoji","Segoe UI Symbol";font-size:16px;fill:rgb(13, 13, 13);}@keyframes
edge-animation-frame{from{stroke-dashoffset:0;}}@keyframes dash{to{stroke-dashoffset:0;}}#chatgpt-mermaid-\_r_2t1\_
.edge-animation-slow{stroke-dasharray:9,5!important;stroke-dashoffset:900;animation:dash 50s linear
infinite;stroke-linecap:round;}#chatgpt-mermaid-\_r_2t1\_ .edge-animation-fast{stroke-dasharray:9,5!
important;stroke-dashoffset:900;animation:dash 20s linear infinite;stroke-linecap:round;}#chatgpt-mermaid-\_r_2t1\_
.error-icon{fill:rgb(243, 243, 243);}#chatgpt-mermaid-\_r_2t1\_ .error-text{fill:rgb(13, 13, 13);stroke:rgb(13, 13, 13)
;}#chatgpt-mermaid-\_r_2t1\_ .edge-thickness-normal{stroke-width:1px;}#chatgpt-mermaid-\_r_2t1\_
.edge-thickness-thick{stroke-width:3.5px;}#chatgpt-mermaid-\_r_2t1\_ .edge-pattern-solid{stroke-dasharray:
0;}#chatgpt-mermaid-\_r_2t1\_ .edge-thickness-invisible{stroke-width:0;fill:none;}#chatgpt-mermaid-\_r_2t1\_
.edge-pattern-dashed{stroke-dasharray:3;}#chatgpt-mermaid-\_r_2t1\_ .edge-pattern-dotted{stroke-dasharray:
2;}#chatgpt-mermaid-\_r_2t1\_ .marker{fill:rgb(143, 143, 143);stroke:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_2t1\_
.marker.cross{stroke:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_2t1\_ svg{font-family:
-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"Apple Color Emoji",Arial,sans-serif,"
Segoe UI Emoji","Segoe UI Symbol";font-size:16px;}#chatgpt-mermaid-\_r_2t1\_ p{margin:0;}#chatgpt-mermaid-\_r_2t1\_
.label{font-family:-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"Apple Color Emoji"
,Arial,sans-serif,"Segoe UI Emoji","Segoe UI Symbol";color:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2t1\_ .cluster-label
text{fill:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2t1\_ .cluster-label span{color:rgb(13, 13, 13)
;}#chatgpt-mermaid-\_r_2t1\_ .cluster-label span p{background-color:transparent;}#chatgpt-mermaid-\_r_2t1\_ .label
text,#chatgpt-mermaid-\_r_2t1\_ span{fill:rgb(13, 13, 13);color:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2t1\_ .node
rect,#chatgpt-mermaid-\_r_2t1\_ .node circle,#chatgpt-mermaid-\_r_2t1\_ .node ellipse,#chatgpt-mermaid-\_r_2t1\_ .node
polygon,#chatgpt-mermaid-\_r_2t1\_ .node path{fill:rgb(222, 234, 251);stroke:rgb(83, 154, 248);stroke-width:
1px;}#chatgpt-mermaid-\_r_2t1\_ .rough-node .label text,#chatgpt-mermaid-\_r_2t1\_ .node .label
text,#chatgpt-mermaid-\_r_2t1\_ .image-shape .label,#chatgpt-mermaid-\_r_2t1\_ .icon-shape .label{text-anchor:
middle;}#chatgpt-mermaid-\_r_2t1\_ .node .katex path{fill:#000;stroke:#000;stroke-width:1px;}#chatgpt-mermaid-\_r_2t1\_
.rough-node .label,#chatgpt-mermaid-\_r_2t1\_ .node .label,#chatgpt-mermaid-\_r_2t1\_ .image-shape
.label,#chatgpt-mermaid-\_r_2t1\_ .icon-shape .label{text-align:center;}#chatgpt-mermaid-\_r_2t1\_
.node.clickable{cursor:pointer;}#chatgpt-mermaid-\_r_2t1\_ .root .anchor path{fill:rgb(143, 143, 143)!
important;stroke-width:0;stroke:rgb(143, 143, 143);}#chatgpt-mermaid-\_r_2t1\_ .arrowheadPath{fill:rgb(143, 143, 143)
;}#chatgpt-mermaid-\_r_2t1\_ .edgePath .path{stroke:rgb(143, 143, 143);stroke-width:1px;}#chatgpt-mermaid-\_r_2t1\_
.flowchart-link{stroke:rgb(143, 143, 143);fill:none;}#chatgpt-mermaid-\_r_2t1\_ .edgeLabel{background-color:rgb(252,
252, 252);text-align:center;}#chatgpt-mermaid-\_r_2t1\_ .edgeLabel p{background-color:rgb(252, 252, 252)
;}#chatgpt-mermaid-\_r_2t1\_ .edgeLabel rect{opacity:0.5;background-color:rgb(252, 252, 252);fill:rgb(252, 252, 252)
;}#chatgpt-mermaid-\_r_2t1\_ .labelBkg{background-color:rgba(252, 252, 252, 0.5);}#chatgpt-mermaid-\_r_2t1\_ .cluster
rect{fill:rgb(243, 243, 243);stroke:rgba(0, 0, 0, 0.1);stroke-width:1px;}#chatgpt-mermaid-\_r_2t1\_ .cluster text{fill:
rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2t1\_ .cluster span{color:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2t1\_
div.mermaidTooltip{position:absolute;text-align:center;max-width:200px;padding:2px;font-family:
-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe UI",Helvetica,"Apple Color Emoji",Arial,sans-serif,"
Segoe UI Emoji","Segoe UI Symbol";font-size:12px;background:rgb(243, 243, 243);border:1px solid rgba(0, 0, 0, 0.1)
;border-radius:2px;pointer-events:none;z-index:100;}#chatgpt-mermaid-\_r_2t1\_ .flowchartTitleText{text-anchor:
middle;font-size:18px;fill:rgb(13, 13, 13);}#chatgpt-mermaid-\_r_2t1\_ rect.text{fill:none;stroke-width:
0;}#chatgpt-mermaid-\_r_2t1\_ .icon-shape,#chatgpt-mermaid-\_r_2t1\_ .image-shape{background-color:rgb(252, 252, 252)
;text-align:center;}#chatgpt-mermaid-\_r_2t1\_ .icon-shape p,#chatgpt-mermaid-\_r_2t1\_ .image-shape p{background-color:
rgb(252, 252, 252);padding:2px;}#chatgpt-mermaid-\_r_2t1\_ .icon-shape .label rect,#chatgpt-mermaid-\_r_2t1\_
.image-shape .label rect{opacity:0.5;background-color:rgb(252, 252, 252);fill:rgb(252, 252, 252)
;}#chatgpt-mermaid-\_r_2t1\_ .label-icon{display:inline-block;height:1em;overflow:visible;vertical-align:
-0.125em;}#chatgpt-mermaid-\_r_2t1\_ .node .label-icon path{fill:currentColor;stroke:revert;stroke-width:
revert;}#chatgpt-mermaid-\_r_2t1\_ .node .neo-node{stroke:rgb(83, 154, 248)
;}#chatgpt-mermaid-\_r_2t1\_ [data-look="neo"].node rect,#chatgpt-mermaid-\_r_2t1\_ [data-look="neo"].cluster
rect,#chatgpt-mermaid-\_r_2t1\_ [data-look="neo"].node polygon{stroke:url(#chatgpt-mermaid-\_r_2t1\_-gradient);filter:
drop-shadow( 1px 2px 2px rgba(185,185,185,1));}#chatgpt-mermaid-\_r_2t1\_ [data-look="neo"].swimlane.cluster
rect{filter:none;}#chatgpt-mermaid-\_r_2t1\_ [data-look="neo"].node path{stroke:url(#chatgpt-mermaid-\_r_2t1\_-gradient)
;stroke-width:1px;}#chatgpt-mermaid-\_r_2t1\_ [data-look="neo"].node .outer-path{filter:drop-shadow( 1px 2px 2px rgba(
185,185,185,1));}#chatgpt-mermaid-\_r_2t1\_ [data-look="neo"].node .neo-line path{stroke:rgb(83, 154, 248);filter:
none;}#chatgpt-mermaid-\_r_2t1\_ [data-look="neo"].node circle{stroke:url(#chatgpt-mermaid-\_r_2t1\_-gradient);filter:
drop-shadow( 1px 2px 2px rgba(185,185,185,1));}#chatgpt-mermaid-\_r_2t1\_ [data-look="neo"].node circle
.state-start{fill:#000000;}#chatgpt-mermaid-\_r_2t1\_ [data-look="neo"].icon-shape .icon{fill:url(
#chatgpt-mermaid-\_r_2t1\_-gradient);filter:drop-shadow( 1px 2px 2px rgba(185,185,185,1))
;}#chatgpt-mermaid-\_r_2t1\_ [data-look="neo"].icon-shape .icon-neo path{stroke:url(#chatgpt-mermaid-\_r_2t1\_-gradient)
;filter:drop-shadow( 1px 2px 2px rgba(185,185,185,1));}#chatgpt-mermaid-\_r_2t1\_ .node text{font-size:14px;font-weight:
600;letter-spacing:normal;fill:rgb(0, 79, 153);}#chatgpt-mermaid-\_r_2t1\_ .edgeLabels text{font-size:13px;font-weight:
600;letter-spacing:-0.08px;fill:rgb(0, 79, 153);}#chatgpt-mermaid-\_r_2t1\_ .node tspan[font-weight="normal"]
,#chatgpt-mermaid-\_r_2t1\_ .edgeLabels tspan[font-weight="normal"]{font-weight:600;}#chatgpt-mermaid-\_r_2t1\_
.edgeLabel .label rect{opacity:1;rx:13px;ry:13px;fill:rgb(245, 250, 255);stroke:rgb(206, 219, 229);stroke-width:
1px;}#chatgpt-mermaid-\_r_2t1\_ .node rect,#chatgpt-mermaid-\_r_2t1\_ .node circle,#chatgpt-mermaid-\_r_2t1\_ .node
ellipse,#chatgpt-mermaid-\_r_2t1\_ .node polygon,#chatgpt-mermaid-\_r_2t1\_ .node path{fill:rgb(229, 243, 255);stroke:
rgba(0, 0, 0, 0.1);stroke-width:1px;}#chatgpt-mermaid-\_r_2t1\_ .node rect{rx:16px;ry:16px;}#chatgpt-mermaid-\_r_2t1\_
.node.mermaid-decision .label-container{fill:rgb(245, 250, 255);stroke:rgb(206, 219, 229);stroke-dasharray:
2,2;}#chatgpt-mermaid-\_r_2t1\_ .edgePaths .flowchart-link{stroke:rgb(143, 143, 143);stroke-width:1px;stroke-linecap:
round;stroke-linejoin:round;}#chatgpt-mermaid-\_r_2t1\_ .marker{fill:rgb(143, 143, 143);stroke:rgb(143, 143, 143)
;}#chatgpt-mermaid-\_r_2t1\_ :root{--mermaid-font-family:-apple-system-body,ui-sans-serif,-apple-system,system-ui,"Segoe
UI",Helvetica,"Apple Color Emoji",Arial,sans-serif,"Segoe UI Emoji","Segoe UI Symbol"
;}租户提现申请认证、权限与幂等用户余额检查 + 初步风控是否允许拒绝申请账本冻结金额审批策略人工审批 /
延迟提现调度安全解冻选择热钱包 + 分配 NonceSigner 二次策略验证签名 / 广播 / 追踪最终确认 + 账本结算拒绝允许高风险低风险通过拒绝

### 5.1 风控需要控制三层风险

| 风险层    | 推荐检查                                 |
|--------|--------------------------------------|
| 租户级    | 租户身份、提现权限、日限额、资金余额、异常 API 请求         |
| 用户与地址级 | 用户提现频率、目的地址风险、白名单、地址变更冷静期、大额人工审批     |
| 平台资金级  | 热钱包可用余额、单钱包支出上限、Gas 预算、异常交易监控、全局紧急暂停 |

对于签名服务，即使 Core 已经批准提现，也必须再独立确认：交易的来源钱包、目标地址、链 ID、合约、金额、Nonce 和授权订单全部匹配。

### 5.2 如何做到最优提现

一期建议：

第一层：账本内部划转优先。 同租户用户间转账直接完成内部双重记账，避免产生链上 Gas。

第二层：普通 EOA 热钱包提现。 使用专门的交易调度器分配 Nonce、选择合适热钱包、估算 Gas、控制等待队列。对支持 EIP-1559 的链使用
`maxFeePerGas`、`maxPriorityFeePerGas` 等费用机制。

[image](https://www.google.com/s2/favicons?domain=https://eips.ethereum.org\&sz=32)

以太坊改进提案

第三层：批量 ERC-20 提现评估。 批量支付合约有可能在特定交易规模下降低成本，但不是必然。建议一期先用普通 ERC-20
Transfer，等获得真实提现数据后，再通过基准测试确认批量合约是否更省 Gas，并单独进行合约审计。

### 5.3 必须解决的 Nonce 风险

例如，一笔提现已经签名并广播，但 RPC 请求超时。

此时不能直接认为失败，也不能重新分配新的 Nonce 再付款。正确方案是保存原始签名交易及其哈希，持续追踪同一 Nonce
的所有交易和替代交易，在结果未确定之前保留提现冻结金额。

这应作为一期 P0 级别安全要求。

## 6. 完整 V2.0 Markdown 架构文档

下载 Web3 多租户托管钱包一期核心架构设计 V2.0.md

已生成完整 Markdown 文件，约 45 KB、700 行，覆盖六项核心需求，包含 Mermaid 架构与业务流程图、数据库模型、Rust
项目结构、状态机、异常恢复与验收标准。

### 实施建议

架构开发顺序我建议定为：

安全接入与密钥体系 → 多租户地址与资金账本 → 充值及最终性 → 提现风控与执行 → 智能归集优化。

尤其不要在账本、签名权限和提现幂等尚未可靠实现时，先开发复杂的归集和批量提现算法。对于这个项目，正确记账和防止资金被错误转出是第一优先级，节省
Gas 是在安全约束下进行的优化目标。
