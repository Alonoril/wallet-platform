// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title 平台配置的延时治理入口
/// @notice Council 合约提案，等待至少两天后任何执行者可执行原操作；不存在部署者超级管理员。
contract TenantTimelock is TimelockController {
    /// @notice 治理最小等待时间，不能通过后续 updateDelay 降到两天以下。
    uint256 public constant MINIMUM_DELAY = 2 days;
    /// @dev 父类调度通过虚拟 getMinDelay 读取该值，以便强制更新时仍遵守安全下限。
    uint256 private _effectiveDelay;

    error UnsafeGovernance();

    /// @notice 提案方必须为已部署的 Council 合约，公开执行不允许修改已排队的调用内容。
    constructor(uint256 delay, address council)
        TimelockController(delay, _proposers(council), _executors(), address(0))
    {
        if (delay < MINIMUM_DELAY || council.code.length == 0) revert UnsafeGovernance();
        _effectiveDelay = delay;
    }

    /// @notice 返回调度操作实际采用的等待秒数。
    function getMinDelay() public view override returns (uint256) {
        return _effectiveDelay;
    }

    /// @notice 只能由本 Timelock 完成一笔已排队治理交易来修改等待时间。
    function updateDelay(uint256 newDelay) external override {
        if (newDelay < MINIMUM_DELAY) revert UnsafeGovernance();
        if (msg.sender != address(this)) revert TimelockUnauthorizedCaller(msg.sender);
        emit MinDelayChange(_effectiveDelay, newDelay);
        _effectiveDelay = newDelay;
    }

    /// @dev 仅将已确认 Council 合约登记为初始提案/取消方，不给部署者追加管理员权限。
    function _proposers(address council) private pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = council;
    }

    /// @dev 登记公开执行角色；任何人只可执行已经经过 Council 提案和等待期的原始操作。
    function _executors() private pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = address(0);
    }
}
