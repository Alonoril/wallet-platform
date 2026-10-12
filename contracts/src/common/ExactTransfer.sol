// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title 原始数量精确转账工具
/// @notice ERC20 同时核对发送方减少量和接收方增加量，拒绝扣税/rebase 等不一致转账。
library ExactTransfer {
    using SafeERC20 for IERC20;

    error InvalidTransfer();
    error TransferFailed();
    error InexactTransfer();

    /// @notice 原生币读取账户余额，ERC20 读取注册资产 balanceOf；原生币用零地址表示。
    function balance(address token, address account) internal view returns (uint256) {
        return token == address(0) ? account.balance : IERC20(token).balanceOf(account);
    }

    /// @notice 从当前业务合约发送精确数量，任何失败均向上回滚 nonce、预算和订单。
    /// @dev 原生币收款合约可在 receive 中继续花费，因此只强制发送方精确扣减；ERC20 检查双侧余额。
    function send(address token, address recipient, uint256 amount) internal {
        if (recipient == address(0) || recipient == address(this) || amount == 0) revert InvalidTransfer();
        uint256 beforeSource = balance(token, address(this));
        if (token == address(0)) {
            (bool ok,) = recipient.call{ value: amount }("");
            if (!ok) revert TransferFailed();
            // Native recipients may spend their receipt in receive(); exact source debit is authoritative.
            if (address(this).balance != beforeSource - amount) revert InexactTransfer();
        } else {
            uint256 beforeRecipient = balance(token, recipient);
            IERC20(token).safeTransfer(recipient, amount);
            if (
                balance(token, address(this)) != beforeSource - amount
                    || balance(token, recipient) != beforeRecipient + amount
            ) revert InexactTransfer();
        }
    }

    /// @notice 冷地址补仓时拉取 ERC20，并验证两侧精确差额；不适用于原生币。
    function pull(address token, address source, uint256 amount) internal {
        if (token == address(0) || source == address(0) || source == address(this) || amount == 0) {
            revert InvalidTransfer();
        }
        uint256 beforeSource = balance(token, source);
        uint256 beforeTarget = balance(token, address(this));
        IERC20(token).safeTransferFrom(source, address(this), amount);
        if (
            balance(token, source) != beforeSource - amount
                || balance(token, address(this)) != beforeTarget + amount
        ) revert InexactTransfer();
    }
}
