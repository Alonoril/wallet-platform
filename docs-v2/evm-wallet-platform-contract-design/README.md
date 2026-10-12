# EVM / wallet-platform-rust / Milon 设计索引

EVM v2 合约已在 [contracts](../../contracts/README.md) 落地，接口、资金状态、风险与部署见 [2026-10-12 实现说明](20261012-evm-contract-implementation.md)。最新未归集提现规则采用**用户签名 + 平台 REFUND_SIGNER 签名**，允许指定外部收款地址；早期文档和图表的单签描述以该实现说明及[提现约定](../提现.md)覆盖。

`wallet-platform-rust` 是双向桥服务。未归集充值由用户本人授权从 EVM 充值合约直接提走，标黑不影响此自提，也无需多签或热钱包。净归集终局后才生成 Milon 专用权益；热钱包提现使用 Milon 预留与多签。热钱包持仓上限按链和币种配置，后端提供授权修改 API。

## 文档

| 文档 | 内容 |
|---|---|
| [需求](需求.md) | EVM 充值地址、热钱包池、Milon 多签及三段桥接要求 |
| [EVM v2 实现与对接](20261012-evm-contract-implementation.md) | 用户与平台双签、合约/API/ABI、风险隔离、共享订单、部署和验证 |
| [数据映射与桥接协议](20261011-evm-rust-milon-mapping-and-bridge.md) | 用户直接自提、净归集权益、按币种上限 API、统一 ID、uint256 金额、幂等、终局和对账 |
| [Milon 多签与 EVM 提现](20261011-milon-multisig-evm-withdrawal-design.md) | 现有源码依据、节点多签、跨链证书、验签与安全取消 |

## 已打通的设计流程

图中固定顺序为 EVM 链、wallet-platform-rust、Milon App。独立节点的核验与签名由后端协调和中继，不赋予后端独立放款权。

| 流程图 | SVG | Mermaid 源码 |
|---|---|---|
| 三段总流程 | [查看](20261011-cross-chain-overview.svg) | [编辑](20261011-cross-chain-overview.mmd) |
| 充值、自提与净归集权益入账 | [查看](20261011-cross-chain-deposit-sequence.svg) | [编辑](20261011-cross-chain-deposit-sequence.mmd) |
| 多签提现与付款回执 | [查看](20261011-milon-withdrawal-sequence.svg) | [编辑](20261011-milon-withdrawal-sequence.mmd) |
| 风险、地址轮换、取消与恢复 | [查看](20261011-cross-chain-recovery-sequence.svg) | [编辑](20261011-cross-chain-recovery-sequence.mmd) |
| 提现订单状态 | [查看](20261011-milon-withdrawal-state.svg) | [编辑](20261011-milon-withdrawal-state.mmd) |
| EVM 业务及桥接衔接 | [查看](evm_wallet_platform_flow.svg) | [编辑](evm_wallet_platform_flow.mmd) |

本目录为设计交付，尚未部署两条链或实现 Rust 桥服务。图表仅生成 SVG，原始源码为 Mermaid。
