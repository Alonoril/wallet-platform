// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { WalletTypes as T } from "./WalletTypes.sol";

/// @title 按币种累计出金预算
/// @notice 日预算按 UTC 日切换；滚动预算使用 25 个小时桶，包含最旧部分小时以保证 24 小时内不超额。
library OutflowBudget {
    /// @dev day 为 UTC 日编号；hourKeys 保存小时编号加一（零为未使用），spent 保存该小时累计出金。
    struct Budget {
        uint64 day;
        uint256 dailySpent;
        uint64[25] hourKeys;
        uint256[25] spent;
    }

    error OutflowLimitExceeded();

    /// @notice 返回单笔、当日剩余和保守滚动剩余三者最小值；修改上限不会抹去已花费数量。
    function available(Budget storage budget, T.OutflowPolicy memory policy)
        internal
        view
        returns (uint256)
    {
        uint256 today = budget.day == block.timestamp / 1 days ? budget.dailySpent : 0;
        uint256 rolling = rollingSpent(budget);
        if (today >= policy.dailyLimit || rolling >= policy.rollingLimit) return 0;
        uint256 remaining = policy.dailyLimit - today;
        if (remaining > policy.rollingLimit - rolling) remaining = policy.rollingLimit - rolling;
        return remaining < policy.singleLimit ? remaining : policy.singleLimit;
    }

    /// @notice 计算当前小时和之前 24 个小时桶的总支出，查询成本固定为 25 次。
    function rollingSpent(Budget storage budget) internal view returns (uint256 total) {
        uint256 nowKey = block.timestamp / 1 hours + 1;
        // Including the oldest partial hour is conservative: no 24-hour interval exceeds the limit.
        for (uint256 i; i < 25; ++i) {
            uint256 key = budget.hourKeys[i];
            if (key != 0 && key <= nowKey && nowKey - key <= 24) total += budget.spent[i];
        }
    }

    /// @notice 先核验本次金额不超预算，再同步写入日计数与当前小时桶，随外层资金转账原子回滚。
    function consume(Budget storage budget, T.OutflowPolicy memory policy, uint256 amount) internal {
        if (amount == 0 || amount > available(budget, policy)) revert OutflowLimitExceeded();
        uint64 day = uint64(block.timestamp / 1 days);
        if (budget.day != day) {
            budget.day = day;
            budget.dailySpent = 0;
        }
        budget.dailySpent += amount;
        uint64 hourKey = uint64(block.timestamp / 1 hours + 1);
        uint256 index = (hourKey - 1) % 25;
        if (budget.hourKeys[index] != hourKey) {
            budget.hourKeys[index] = hourKey;
            budget.spent[index] = 0;
        }
        budget.spent[index] += amount;
    }
}
