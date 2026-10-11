# EVM 合约原理时序图

日期：2026-10-11。14 张独立 Mermaid `sequenceDiagram`，按协议设计原理展开合约职责和调用顺序。

[功能说明与全部时序源码](../20261011-09-evm-contract-principles-sequence.md) · [打开可缩放图册](index.html)

| 编号 | 原理与 Mermaid 源码 | 静态预览 |
|---|---|---|
| 00 | [租户隔离、部署与激活](20261011-00-bootstrap.mmd) | [SVG](20261011-00-bootstrap.svg) |
| 01 | [CREATE2 预测地址、预充值与原子部署](20261011-01-address.mmd) | [SVG](20261011-01-address.svg) |
| 02 | [资金授权、防重放与原子执行](20261011-02-authorization.mmd) | [SVG](20261011-02-authorization.svg) |
| 03 | [单地址授权归集与风险二次检查](20261011-03-sweep.mmd) | [SVG](20261011-03-sweep.svg) |
| 04 | [批量归集的单项隔离与交易边界](20261011-04-batch.mmd) | [SVG](20261011-04-batch.svg) |
| 05 | [观察期 lot、部分结算与余额覆盖](20261011-05-clearing.mmd) | [SVG](20261011-05-clearing.svg) |
| 06 | [Clearing 迁移与观察期继承](20261011-06-lot-migration.mmd) | [SVG](20261011-06-lot-migration.svg) |
| 07 | [Treasury 提现、共享限额与取消竞争](20261011-07-withdrawal.mmd) | [SVG](20261011-07-withdrawal.svg) |
| 08 | [热池转冷、离线批准回款与迁移预算](20261011-08-cold.mmd) | [SVG](20261011-08-cold.svg) |
| 09 | [风险入金未归集：原地址冻结与旧授权撤销](20261011-09-risk-before.mmd) | [SVG](20261011-09-risk-before.svg) |
| 10 | [风险入金已归集：逐池控制、多案件预留与缺口](20261011-10-risk-after.mmd) | [SVG](20261011-10-risk-after.svg) |
| 11 | [专项隔离：批准快照、预留迁移与 lot 退休](20261011-11-disposition.mmd) | [SVG](20261011-11-disposition.svg) |
| 12 | [Quarantine 解控、受控释放与后续独立支付](20261011-12-release.mmd) | [SVG](20261011-12-release.svg) |
| 13 | [紧急收紧、延迟恢复与固定合约版本迁移](20261011-13-governance.mmd) | [SVG](20261011-13-governance.svg) |

图中的合约入口名称是设计接口，部署参数由治理政策确定。彩色职责框、阶段框、分支和序号共同表达责任与执行顺序。主文档中的 Mermaid 代码与独立 `.mmd` 保持一致，SVG 从同一源码生成。

图册使用本地 SVG，不依赖 CDN 或在线 Mermaid 服务。可直接打开 `index.html`，用目录切换、缩放、横向/纵向滚动和展开源码阅读。宽图先看参与者，再使用“阅读字号”查看消息细节。

静态预览使用本地 Mermaid CLI 12.0.0 渲染，语法采用标准 sequenceDiagram 的 participant、box、rect、alt、opt、loop、break 和 Note。再次生成时应使用支持这些语法的 Mermaid 渲染器，并检查字体、分支框和长注释的可读性。
