# EVM / wallet-platform-rust / Milon 设计索引

`wallet-platform-rust` 是双向桥服务。真实托管资产在 EVM，专用权益、预留和审批在 Milon；统一标识贯穿充值、归集、提现、回执与恢复。

## 文档

| 文档 | 内容 |
|---|---|
| [需求](需求.md) | EVM 充值地址、热钱包池、Milon 多签及三段桥接要求 |
| [数据映射与桥接协议](20261011-evm-rust-milon-mapping-and-bridge.md) | 三端权威、统一 ID、uint256 原始金额、消息字段、幂等、终局和对账 |
| [Milon 多签与 EVM 提现](20261011-milon-multisig-evm-withdrawal-design.md) | 现有源码依据、节点多签、跨链证书、验签与安全取消 |

## 已打通的设计流程

图中固定顺序为 EVM 链、wallet-platform-rust、Milon App。独立节点的核验与签名由后端协调和中继，不赋予后端独立放款权。

| 流程图 | SVG | Mermaid 源码 |
|---|---|---|
| 三段总流程 | [查看](20261011-cross-chain-overview.svg) | [编辑](20261011-cross-chain-overview.mmd) |
| 充值映射与权益入账 | [查看](20261011-cross-chain-deposit-sequence.svg) | [编辑](20261011-cross-chain-deposit-sequence.mmd) |
| 多签提现与付款回执 | [查看](20261011-milon-withdrawal-sequence.svg) | [编辑](20261011-milon-withdrawal-sequence.mmd) |
| 风险、地址轮换、取消与恢复 | [查看](20261011-cross-chain-recovery-sequence.svg) | [编辑](20261011-cross-chain-recovery-sequence.mmd) |
| 提现订单状态 | [查看](20261011-milon-withdrawal-state.svg) | [编辑](20261011-milon-withdrawal-state.mmd) |
| EVM 业务及桥接衔接 | [查看](evm_wallet_platform_flow.svg) | [编辑](evm_wallet_platform_flow.mmd) |

本目录为设计交付，尚未部署两条链或实现 Rust 桥服务。图表仅生成 SVG，原始源码为 Mermaid。
