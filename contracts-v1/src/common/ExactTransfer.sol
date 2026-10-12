// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

library ExactTransfer {
    using SafeERC20 for IERC20;

    error InvalidTransfer();
    error NativeTransferFailed();
    error UnexpectedBalanceChange();

    function balance(address token, address holder) internal view returns (uint256) {
        return token == address(0) ? holder.balance : IERC20(token).balanceOf(holder);
    }

    function send(address token, address destination, uint256 amount) internal {
        if (amount == 0 || destination == address(0) || destination == address(this)) {
            revert InvalidTransfer();
        }
        uint256 sourceBefore = balance(token, address(this));
        uint256 targetBefore = balance(token, destination);
        if (token == address(0)) {
            (bool success,) = destination.call{ value: amount }("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(destination, amount);
        }
        if (
            balance(token, address(this)) + amount != sourceBefore
                || balance(token, destination) != targetBefore + amount
        ) revert UnexpectedBalanceChange();
    }
}
