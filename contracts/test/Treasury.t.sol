// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { WalletFixture } from "./helpers/WalletFixture.sol";
import { WalletTypes } from "../src/common/WalletTypes.sol";
import { TreasuryVault } from "../src/pools/TreasuryVault.sol";
import { RejectNative, ReentrantRecipient } from "./helpers/Mocks.sol";

contract TreasuryTest is WalletFixture {
    function testAuthorizedTokenWithdrawalExactlyOnce() public {
        token.mint(address(s.treasury), 100 ether);
        WalletTypes.WithdrawalPermit memory p =
            _withdrawPermit(address(token), payee, 40 ether, bytes32(uint256(1)));
        bytes memory signature = _sign(WITHDRAW_KEY, s.treasury.hashWithdrawal(p));
        vm.prank(relayer);
        s.treasury.executeWithdrawal(p, signature, "");
        assertEq(token.balanceOf(payee), 40 ether);
        assertEq(token.balanceOf(address(s.treasury)), 60 ether);
        vm.expectRevert();
        vm.prank(relayer);
        s.treasury.executeWithdrawal(p, signature, "");
        assertEq(uint256(s.treasury.requestStatus(p.requestId)), 1);
    }

    function testHighValueRequiresIndependentCouncilSignature() public {
        token.mint(address(s.treasury), 2000 ether);
        WalletTypes.WithdrawalPermit memory p =
            _withdrawPermit(address(token), payee, 1500 ether, bytes32(uint256(2)));
        bytes32 digest = s.treasury.hashWithdrawal(p);
        bytes memory signature = _sign(WITHDRAW_KEY, digest);
        vm.expectRevert();
        vm.prank(relayer);
        s.treasury.executeWithdrawal(p, signature, "");
        bytes memory councilSignature = _sign(COUNCIL_KEY, digest);
        vm.prank(relayer);
        s.treasury.executeWithdrawal(p, signature, councilSignature);
        assertEq(token.balanceOf(payee), 1500 ether);
    }

    function testCancellationWinsAndPauseDoesNotPreventCancellation() public {
        token.mint(address(s.treasury), 100);
        WalletTypes.WithdrawalPermit memory p =
            _withdrawPermit(address(token), payee, 40, bytes32(uint256(3)));
        bytes memory signature = _sign(WITHDRAW_KEY, s.treasury.hashWithdrawal(p));
        vm.startPrank(guardian);
        s.risk.applyPoolAssetHold(address(s.treasury), address(token), CASE, 0);
        s.treasury.cancelWithdrawal(p.requestId);
        vm.stopPrank();
        vm.prank(address(council));
        s.risk.releaseHold(address(s.treasury), address(token), false, CASE);
        vm.expectRevert();
        vm.prank(relayer);
        s.treasury.executeWithdrawal(p, signature, "");
        p = _withdrawPermit(address(token), payee, 40, p.requestId);
        signature = _sign(WITHDRAW_KEY, s.treasury.hashWithdrawal(p));
        vm.expectRevert();
        vm.prank(relayer);
        s.treasury.executeWithdrawal(p, signature, "");
        assertEq(uint256(s.treasury.requestStatus(p.requestId)), 2);
    }

    function testPaidWithdrawalCannotBeCancelledAndCannotReplayOnAnotherTreasury() public {
        token.mint(address(s.treasury), 100);
        WalletTypes.WithdrawalPermit memory p =
            _withdrawPermit(address(token), payee, 40, bytes32(uint256(4)));
        bytes memory signature = _sign(WITHDRAW_KEY, s.treasury.hashWithdrawal(p));
        vm.prank(relayer);
        s.treasury.executeWithdrawal(p, signature, "");
        vm.expectRevert();
        vm.prank(guardian);
        s.treasury.cancelWithdrawal(p.requestId);
        TreasuryVault second = new TreasuryVault(s.authority, s.pools, s.risk);
        vm.prank(address(s.timelock));
        s.pools.registerPool(address(second), WalletTypes.PoolKind.Treasury);
        token.mint(address(second), 100);
        vm.expectRevert();
        vm.prank(relayer);
        second.executeWithdrawal(p, signature, "");
    }

    function testRiskReserveAndSafetyFloorPreventSpending() public {
        token.mint(address(s.treasury), 100);
        vm.prank(address(s.timelock));
        s.pools.setLimits(address(token), WalletTypes.Limits(100, 200, 200, 100, 10));
        vm.prank(guardian);
        s.risk.setReserve(address(s.treasury), address(token), CASE, 20, 0);
        WalletTypes.WithdrawalPermit memory p =
            _withdrawPermit(address(token), payee, 71, bytes32(uint256(5)));
        bytes memory signature = _sign(WITHDRAW_KEY, s.treasury.hashWithdrawal(p));
        vm.expectRevert();
        vm.prank(relayer);
        s.treasury.executeWithdrawal(p, signature, "");
        p.amount = 70;
        signature = _sign(WITHDRAW_KEY, s.treasury.hashWithdrawal(p));
        vm.prank(relayer);
        s.treasury.executeWithdrawal(p, signature, "");
        assertEq(token.balanceOf(address(s.treasury)), 30);
    }

    function testNativeRejectRollsBackConsumptionAndBudget() public {
        vm.deal(address(s.treasury), 1 ether);
        RejectNative reject = new RejectNative();
        WalletTypes.WithdrawalPermit memory p =
            _withdrawPermit(address(0), address(reject), 0.1 ether, bytes32(uint256(6)));
        bytes memory signature = _sign(WITHDRAW_KEY, s.treasury.hashWithdrawal(p));
        vm.expectRevert();
        vm.prank(relayer);
        s.treasury.executeWithdrawal(p, signature, "");
        assertEq(uint256(s.treasury.requestStatus(p.requestId)), 0);
        assertEq(s.pools.dailySpent(address(0), block.timestamp / 1 days), 0);
        assertEq(address(s.treasury).balance, 1 ether);
    }

    function testBlockedAndInternalRecipientsAreRejected() public {
        token.mint(address(s.treasury), 100);
        vm.prank(guardian);
        s.pools.setRecipientBlocked(payee, true);
        WalletTypes.WithdrawalPermit memory p =
            _withdrawPermit(address(token), payee, 10, bytes32(uint256(7)));
        bytes memory signature = _sign(WITHDRAW_KEY, s.treasury.hashWithdrawal(p));
        vm.expectRevert();
        vm.prank(relayer);
        s.treasury.executeWithdrawal(p, signature, "");
        p.to = address(s.clearing);
        signature = _sign(WITHDRAW_KEY, s.treasury.hashWithdrawal(p));
        vm.expectRevert();
        vm.prank(relayer);
        s.treasury.executeWithdrawal(p, signature, "");
    }

    function testIssuerFreezeReturnsFailureWithoutConsumingRequest() public {
        token.mint(address(s.treasury), 100);
        token.setFrozen(address(s.treasury), true);
        WalletTypes.WithdrawalPermit memory p =
            _withdrawPermit(address(token), payee, 10, bytes32(uint256(8)));
        bytes memory signature = _sign(WITHDRAW_KEY, s.treasury.hashWithdrawal(p));
        vm.expectRevert();
        vm.prank(relayer);
        s.treasury.executeWithdrawal(p, signature, "");
        assertEq(uint256(s.treasury.requestStatus(p.requestId)), 0);
    }

    function testCrossDayRollingBudgetAndDifferentTreasuriesShareLimit() public {
        vm.warp(10 days + 23 hours + 59 minutes);
        vm.prank(address(s.timelock));
        s.pools.setLimits(address(token), WalletTypes.Limits(100, 100, 100, 100, 0));
        token.mint(address(s.treasury), 100);
        WalletTypes.WithdrawalPermit memory p =
            _withdrawPermit(address(token), payee, 80, bytes32(uint256(9)));
        bytes memory signature = _sign(WITHDRAW_KEY, s.treasury.hashWithdrawal(p));
        vm.prank(relayer);
        s.treasury.executeWithdrawal(p, signature, "");
        vm.warp(11 days + 1 minutes);
        TreasuryVault second = new TreasuryVault(s.authority, s.pools, s.risk);
        vm.prank(address(s.timelock));
        s.pools.registerPool(address(second), WalletTypes.PoolKind.Treasury);
        token.mint(address(second), 100);
        p = _withdrawPermit(address(token), payee, 21, bytes32(uint256(10)));
        signature = _sign(WITHDRAW_KEY, second.hashWithdrawal(p));
        vm.expectRevert();
        vm.prank(relayer);
        second.executeWithdrawal(p, signature, "");
        assertEq(token.balanceOf(payee), 80);
    }

    function testNativeReentrancyCannotPayRequestTwice() public {
        ReentrantRecipient recipient = new ReentrantRecipient();
        vm.prank(address(s.timelock));
        s.authority.setExecutor(address(recipient), true);
        vm.deal(address(s.treasury), 1 ether);
        WalletTypes.WithdrawalPermit memory p =
            _withdrawPermit(address(0), address(recipient), 0.1 ether, bytes32(uint256(11)));
        bytes memory signature = _sign(WITHDRAW_KEY, s.treasury.hashWithdrawal(p));
        recipient.configure(
            address(s.treasury), abi.encodeCall(s.treasury.executeWithdrawal, (p, signature, bytes("")))
        );
        vm.prank(relayer);
        s.treasury.executeWithdrawal(p, signature, "");
        assertFalse(recipient.reentrySucceeded());
        assertEq(address(recipient).balance, 0.1 ether);
    }

    function testAssetDisableThenReenableInvalidatesPreviouslySignedRequests() public {
        token.mint(address(s.treasury), 100);
        WalletTypes.WithdrawalPermit memory p =
            _withdrawPermit(address(token), payee, 10, bytes32(uint256(12)));
        bytes memory signature = _sign(WITHDRAW_KEY, s.treasury.hashWithdrawal(p));
        vm.prank(guardian);
        s.authority.setAsset(address(token), false);
        vm.prank(address(s.timelock));
        s.authority.setAsset(address(token), true);
        vm.expectRevert();
        vm.prank(relayer);
        s.treasury.executeWithdrawal(p, signature, "");
    }
}
