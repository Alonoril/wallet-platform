// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TenantAuthority } from "./TenantAuthority.sol";
import { WalletTypes as T } from "../common/WalletTypes.sol";
import { IHotPoolManager } from "../common/IWallet.sol";

/// @title 风险范围与单调版本登记
/// @notice 充值地址、热池、具体资产、用户、收款人与充值来源分别建模；标黑不自动退役地址。
/// @dev 限制/预留增加可即时执行，解除必须治理授权，旧版本签名不会在解冻后重新有效。
contract RiskRegistry {
    /// @notice 当前租户的权限根，风险状态不会被其他租户组件读取为本租户授权。
    TenantAuthority public immutable authority;
    /// @notice scope 对应限制标记、预留原始数量和递增 epoch；未配置时为健康且 epoch=0。
    mapping(bytes32 => T.RiskState) private _states;

    error InvalidRiskUpdate();
    error RiskRestricted(bytes32 scope);
    error StaleRiskEpoch(bytes32 scope);

    event RiskUpdated(
        bytes32 indexed scope,
        bytes32 indexed riskCaseId,
        bool restricted,
        uint256 reservedRaw,
        uint64 epoch,
        bool release
    );

    /// @dev 固定租户权限根，风险更新和解除均通过该组件校验原交易调用者权限。
    constructor(TenantAuthority tenantAuthority) {
        authority = tenantAuthority;
    }

    /// @notice 返回完整风险快照，供后端构造 Permit 和监控读取。
    function state(bytes32 scope) external view returns (T.RiskState memory) {
        return _states[scope];
    }
    /// @notice 地址级风险键，冻结一个热池时用于同时阻断其所有资产流入、出金和转冷。

    function vaultScope(address vault) public pure returns (bytes32) {
        return keccak256(abi.encode("VAULT_V2", vault));
    }
    /// @notice 地址+币种风险键；只有此范围的 reservedRaw 用于资金数量扣减。

    function assetScope(address vault, address token) public pure returns (bytes32) {
        return keccak256(abi.encode("VAULT_ASSET_V2", vault, token));
    }
    /// @notice 单笔充值来源风险键，用于拒绝已知污染来源参与归集分配。

    function sourceScope(bytes32 depositId) public pure returns (bytes32) {
        return keccak256(abi.encode("SOURCE_V2", depositId));
    }
    /// @notice 用户风险键，限制归集和热池付款，但不影响未归集双签自提。

    function userScope(bytes32 userKey) public pure returns (bytes32) {
        return keccak256(abi.encode("USER_RISK_V2", userKey));
    }
    /// @notice 热池对外收款地址风险键；冷钱包亦检查此范围。

    function recipientScope(address account) public pure returns (bytes32) {
        return keccak256(abi.encode("RECIPIENT_V2", account));
    }

    /// @notice 立即限制指定范围，只能保留或增加预留，不允许降低已有保护。
    /// @param expectedEpoch 当前风险版本，用于拒绝并发和乱序更新。
    /// @param riskCaseId 非零案件标识，后端据此同步 Milon 风险预留并追溯来源。
    function restrict(bytes32 scope, uint256 reservedRaw, uint64 expectedEpoch, bytes32 riskCaseId)
        external
    {
        authority.checkRiskOperator(msg.sender);
        T.RiskState storage current = _states[scope];
        if (
            scope == bytes32(0) || riskCaseId == bytes32(0) || current.epoch != expectedEpoch
                || reservedRaw < current.reservedRaw
        ) revert InvalidRiskUpdate();
        current.restricted = true;
        current.reservedRaw = reservedRaw;
        ++current.epoch;
        emit RiskUpdated(scope, riskCaseId, true, reservedRaw, current.epoch, false);
    }

    /// @notice 增加某资产风险预留但不必冻结整个池；可付款余额扣除该预留。
    /// @dev 只为已登记托管地址的具体币种建立数量预留，禁止使用 USD 或跨币种汇总。
    function increaseReserve(
        address vault,
        address token,
        uint256 reservedRaw,
        uint64 expectedEpoch,
        bytes32 riskCaseId
    ) external {
        authority.checkRiskOperator(msg.sender);
        IHotPoolManager pool = IHotPoolManager(authority.hotPoolManager());
        if (!authority.ready() || !pool.isCustodyAddress(vault) || !pool.assetConfig(token).registered) {
            revert InvalidRiskUpdate();
        }
        bytes32 scope = assetScope(vault, token);
        T.RiskState storage current = _states[scope];
        if (
            scope == bytes32(0) || riskCaseId == bytes32(0) || current.epoch != expectedEpoch
                || reservedRaw <= current.reservedRaw
        ) revert InvalidRiskUpdate();
        current.reservedRaw = reservedRaw;
        ++current.epoch;
        emit RiskUpdated(scope, riskCaseId, current.restricted, reservedRaw, current.epoch, false);
    }

    /// @notice 延时治理解除限制并可降低预留，必须绑定当前版本和独立处置证据。
    /// @dev 无论是否保留预留都递增 epoch，历史付款/归集授权不可恢复。
    function release(bytes32 scope, uint256 residualReserve, uint64 expectedEpoch, bytes32 releaseCaseId)
        external
    {
        authority.checkGovernance(msg.sender);
        T.RiskState storage current = _states[scope];
        if (
            scope == bytes32(0) || releaseCaseId == bytes32(0) || current.epoch != expectedEpoch
                || residualReserve > current.reservedRaw
        ) revert InvalidRiskUpdate();
        current.restricted = false;
        current.reservedRaw = residualReserve;
        ++current.epoch;
        emit RiskUpdated(scope, releaseCaseId, false, residualReserve, current.epoch, true);
    }

    /// @notice 同时检查当前范围健康且风险版本与签名一致。
    function check(bytes32 scope, uint64 expectedEpoch) external view {
        T.RiskState memory current = _states[scope];
        if (current.restricted) revert RiskRestricted(scope);
        if (current.epoch != expectedEpoch) revert StaleRiskEpoch(scope);
    }

    /// @notice 地址级和资产级均未冻结才可参与托管池流转；具体数量预留另行扣除。
    function healthy(address vault, address token) external view returns (bool) {
        return !_states[vaultScope(vault)].restricted && !_states[assetScope(vault, token)].restricted;
    }
}
