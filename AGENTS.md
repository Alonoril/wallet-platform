# Repository Guidelines

## 项目结构与模块组织

`docs/` 存放架构方案，`contracts/` 存放 EVM Solidity 合约、Foundry 配置、部署脚本和测试；目前尚无 Rust workspace。文档请使用清晰的主题名和日期前缀，例如 `docs/20261009-v1-multi-wallet-design.md`。后端目标技术栈为 Rust、PostgreSQL，实际模块布局应随代码落地更新。

## 构建、测试与本地开发

合约依赖用 `bash contracts/scripts/bootstrap.sh` 按固定 commit 安装；从仓库根目录运行 `forge build --root contracts`、`forge fmt --root contracts --check`、`forge test --root contracts`。部署和治理流程见 `contracts/README.md`。编辑文档后请检查 Markdown 标题、代码块和相对链接，并在预览中确认 Mermaid 等图表可读。Rust workspace 建立后，使用 `cargo fmt --all -- --check` 检查格式，`cargo clippy --workspace --all-targets -- -D warnings` 执行静态检查，`cargo test --workspace` 运行测试。

## 编码风格与命名

Rust 代码遵循 Rust 2024 和仓库 `rustfmt.toml`：缩进使用制表符，保持 crate 级导入分组，并按格式化工具重排导入和模块。使用能表达领域含义的名称；避免 `foo`、`bar`、`tmp`、`data`、`obj` 等泛化名称。手写 `.rs` 文件不超过 500 行，函数不超过 120 行；优先借用数据，避免热路径中不必要的克隆和分配。

## 测试指南

Solidity 使用 Foundry 单元、fuzz 和 invariant，测试位于 `contracts/test/`，合成密钥和 mock 不用于真实部署；当前未设置覆盖率门槛。新增 Rust 功能时，为业务逻辑添加单元测试，并在 `tests/` 覆盖跨模块行为；测试名称应描述场景和预期结果。涉及账本、充值、提现、幂等或租户隔离的改动，应覆盖重复请求、失败恢复及边界条件。

## 提交与 Pull Request

当前目录没有 Git 历史，无法确认既有提交格式。提交标题请简洁说明改动，例如 `docs: clarify withdrawal flow`。PR 描述应交代背景、改动范围、验证结果及相关风险；架构或接口变更请附更新后的设计文档和必要示意图。

## 安全与智能体工作约定

不要提交助记词、私钥、API 密钥或真实凭据；示例配置只使用占位值。涉及密钥托管、租户资金隔离、账本或签名流程的改动，应明确说明安全边界和影响。进行代码影响、调用链或重构分析时先运行 `codegraph`；提出 Rust 编译、类型或符号相关修复前先运行 `rust-analyzer`。
