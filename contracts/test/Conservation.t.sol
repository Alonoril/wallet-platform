// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { WalletFixture } from "./helpers/WalletFixture.sol";
import { WalletTypes as T } from "../src/common/WalletTypes.sol";
import { DepositVault } from "../src/deposit/DepositVault.sol";

/// @notice 随机交错双签退款、归集、门限付款及重放，持续验证原生币本金与 nonce 守恒。
contract ConservationTest is WalletFixture {
    function testFuzzInterleavedFlowsConservePrincipal(bytes32 seed) public {
        uint256 initial = 99 ether;
        vm.deal(address(vault), initial);
        uint256 refunded;
        uint256 swept;
        uint256 paid;
        uint256 sourceChanges;
        T.RefundPermit memory lastRefund;
        bytes memory lastUserSignature;
        bytes memory lastPlatformSignature;
        for (uint256 i; i < 16; ++i) {
            seed = keccak256(abi.encode(seed, i));
            uint256 action = uint256(seed) % 4;
            if (action == 0 && address(vault).balance != 0) {
                uint256 amount = 1 + uint256(seed) % address(vault).balance;
                lastRefund = _refund(address(0), amount);
                (lastUserSignature, lastPlatformSignature) = _refundSignatures(lastRefund);
                vault.withdraw(lastRefund, lastUserSignature, lastPlatformSignature);
                refunded += amount;
                ++sourceChanges;
            } else if (action == 1 && address(vault).balance != 0) {
                uint256 amount = 1 + uint256(seed) % address(vault).balance;
                (T.SweepPermit memory p, T.SourceAllocation[] memory sources) = _sweep(address(0), amount);
                _executeSweep(p, sources);
                swept += amount;
                ++sourceChanges;
            } else if (action == 2 && address(hot).balance != 0) {
                uint256 amount = 1 + uint256(seed) % address(hot).balance;
                _executeWithdrawal(
                    hot, _withdrawal(hot, address(0), amount, keccak256(abi.encode(seed, "request")))
                );
                paid += amount;
            } else if (action == 3 && lastUserSignature.length != 0) {
                vm.expectRevert(DepositVault.InvalidRefund.selector);
                vault.withdraw(lastRefund, lastUserSignature, lastPlatformSignature);
            }
            assertEq(address(vault).balance, initial - refunded - swept);
            assertEq(address(hot).balance, swept - paid);
            assertEq(recipient.balance, refunded + paid);
            assertEq(address(vault).balance + address(hot).balance + recipient.balance, initial);
            assertEq(vault.assetStateNonce(address(0)), sourceChanges);
            assertLe(address(hot).balance, manager.assetCap(address(0)).maxBalanceRaw);
        }
    }
}
