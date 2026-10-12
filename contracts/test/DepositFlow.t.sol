// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { WalletFixture } from "./helpers/WalletFixture.sol";
import { WalletTypes as T } from "../src/common/WalletTypes.sol";
import { DepositVault } from "../src/deposit/DepositVault.sol";
import { TenantAuthority } from "../src/control/TenantAuthority.sol";
import { RiskRegistry } from "../src/control/RiskRegistry.sol";
import { ExactTransfer } from "../src/common/ExactTransfer.sol";
import { ReenteringRecipient, RejectingRecipient } from "./helpers/Mocks.sol";

/// @notice 验证未归集双签提现、逐来源观察期与归集的原子竞态，覆盖原生币及 ERC20。
contract DepositFlowTest is WalletFixture {
    function testNativeRefundNeedsBothSignaturesAndCanUseDifferentRecipient() public {
        vm.deal(address(vault), 10 ether);
        T.RefundPermit memory p = _refund(address(0), 3 ether);
        _executeRefund(p);
        assertEq(recipient.balance, 3 ether);
        assertEq(address(vault).balance, 7 ether);
        assertEq(vault.assetStateNonce(address(0)), 1);
        assertEq(address(hot).balance, 0);
    }

    function testPlatformSignatureAloneCannotWithdraw() public {
        vm.deal(address(vault), 10 ether);
        T.RefundPermit memory p = _refund(address(0), 1 ether);
        (, bytes memory platformSignature) = _refundSignatures(p);
        vm.expectRevert(DepositVault.InvalidUserSignature.selector);
        vault.withdraw(p, "", platformSignature);
        assertEq(vault.assetStateNonce(address(0)), 0);
    }

    function testUserSignatureAloneCannotWithdraw() public {
        vm.deal(address(vault), 10 ether);
        T.RefundPermit memory p = _refund(address(0), 1 ether);
        (bytes memory userSignature,) = _refundSignatures(p);
        vm.expectRevert(TenantAuthority.InvalidSignature.selector);
        vault.withdraw(p, userSignature, "");
    }

    function testOtherUserCannotAuthorizeWalletRefund() public {
        vm.deal(address(vault), 10 ether);
        T.RefundPermit memory p = _refund(address(0), 1 ether);
        bytes32 digest = vault.hashRefund(p);
        bytes memory wrongUser = _sign(0xABCD, digest);
        bytes memory platformSignature = _sign(REFUND_PK, digest);
        vm.expectRevert(DepositVault.InvalidUserSignature.selector);
        vault.withdraw(p, wrongUser, platformSignature);
    }

    function testRecipientTamperingInvalidatesBothSignatures() public {
        vm.deal(address(vault), 10 ether);
        T.RefundPermit memory p = _refund(address(0), 1 ether);
        (bytes memory userSignature, bytes memory platformSignature) = _refundSignatures(p);
        p.recipient = makeAddr("attacker");
        vm.expectRevert(DepositVault.InvalidUserSignature.selector);
        vault.withdraw(p, userSignature, platformSignature);
    }

    function testSignaturesCannotBeMixedFromDifferentAmounts() public {
        vm.deal(address(vault), 10 ether);
        T.RefundPermit memory p = _refund(address(0), 1 ether);
        (bytes memory userSignature,) = _refundSignatures(p);
        p.amount = 2 ether;
        (, bytes memory platformSignature) = _refundSignatures(p);
        vm.expectRevert(DepositVault.InvalidUserSignature.selector);
        vault.withdraw(p, userSignature, platformSignature);
    }

    function testRefundReplayAndCrossChainReplayFail() public {
        vm.deal(address(vault), 10 ether);
        T.RefundPermit memory p = _refund(address(0), 1 ether);
        (bytes memory userSignature, bytes memory platformSignature) = _refundSignatures(p);
        vm.chainId(31338);
        vm.expectRevert(DepositVault.InvalidUserSignature.selector);
        vault.withdraw(p, userSignature, platformSignature);
        vm.chainId(31337);
        vault.withdraw(p, userSignature, platformSignature);
        vm.expectRevert(DepositVault.InvalidRefund.selector);
        vault.withdraw(p, userSignature, platformSignature);
    }

    function testInternalBlacklistingAndGlobalPauseDoNotBlockDualSignedRefund() public {
        vm.deal(address(vault), 10 ether);
        _restrict(risks.vaultScope(address(vault)));
        _restrict(risks.assetScope(address(vault), address(0)));
        _restrict(risks.userScope(USER));
        vm.prank(guardian);
        authority.pause(true, true);
        _executeRefund(_refund(address(0), 2 ether));
        assertEq(recipient.balance, 2 ether);
    }

    function testExpiredOrOversizedWindowFails() public {
        vm.deal(address(vault), 10 ether);
        T.RefundPermit memory p = _refund(address(0), 1 ether);
        (bytes memory userSignature, bytes memory platformSignature) = _refundSignatures(p);
        vm.warp(p.deadline + 1);
        vm.expectRevert(TenantAuthority.InvalidTimeWindow.selector);
        vault.withdraw(p, userSignature, platformSignature);
        p = _refund(address(0), 1 ether);
        p.deadline += 1;
        (userSignature, platformSignature) = _refundSignatures(p);
        vm.expectRevert(TenantAuthority.InvalidTimeWindow.selector);
        vault.withdraw(p, userSignature, platformSignature);
    }

    function testRefundRejectsCustodyRecipientToPreserveControlledPoolCaps() public {
        vm.deal(address(vault), 10 ether);
        T.RefundPermit memory p = _refund(address(0), 1 ether);
        p.recipient = address(hot);
        (bytes memory userSignature, bytes memory platformSignature) = _refundSignatures(p);
        vm.expectRevert(DepositVault.InvalidRefund.selector);
        vault.withdraw(p, userSignature, platformSignature);
    }

    function testRefundFailureRollsBackNonceAndBalance() public {
        vm.deal(address(vault), 10 ether);
        T.RefundPermit memory p = _refund(address(0), 1 ether);
        p.recipient = address(new RejectingRecipient());
        (bytes memory userSignature, bytes memory platformSignature) = _refundSignatures(p);
        vm.expectRevert(ExactTransfer.TransferFailed.selector);
        vault.withdraw(p, userSignature, platformSignature);
        assertEq(vault.assetStateNonce(address(0)), 0);
        assertEq(address(vault).balance, 10 ether);
    }

    function testRefundRecipientCannotReenter() public {
        vm.deal(address(vault), 10 ether);
        ReenteringRecipient receiver = new ReenteringRecipient();
        T.RefundPermit memory p = _refund(address(0), 1 ether);
        p.recipient = address(receiver);
        (bytes memory userSignature, bytes memory platformSignature) = _refundSignatures(p);
        receiver.arm(address(vault), abi.encodeCall(vault.withdraw, (p, userSignature, platformSignature)));
        vault.withdraw(p, userSignature, platformSignature);
        assertTrue(receiver.attempted());
        assertFalse(receiver.succeeded());
        assertEq(address(receiver).balance, 1 ether);
        assertEq(vault.assetStateNonce(address(0)), 1);
    }

    function testRefundFirstInvalidatesOldSweepAndOnlyNetRemainderCanBeSwept() public {
        vm.deal(address(vault), 10 ether);
        (T.SweepPermit memory sweepPermit, T.SourceAllocation[] memory allocations) =
            _sweep(address(0), 10 ether);
        bytes memory oldSignature = _sign(SWEEP_PK, vault.hashSweep(sweepPermit));
        _executeRefund(_refund(address(0), 3 ether));
        vm.prank(relayer);
        vm.expectRevert(DepositVault.InvalidSweep.selector);
        vault.sweep(sweepPermit, allocations, oldSignature);
        (sweepPermit, allocations) = _sweep(address(0), 7 ether);
        _executeSweep(sweepPermit, allocations);
        assertEq(address(hot).balance, 7 ether);
        assertEq(address(vault).balance, 0);
        assertEq(vault.assetStateNonce(address(0)), 2);
    }

    function testSweepFirstInvalidatesOldRefund() public {
        vm.deal(address(vault), 10 ether);
        T.RefundPermit memory p = _refund(address(0), 3 ether);
        (bytes memory userSignature, bytes memory platformSignature) = _refundSignatures(p);
        (T.SweepPermit memory sweepPermit, T.SourceAllocation[] memory allocations) =
            _sweep(address(0), 5 ether);
        _executeSweep(sweepPermit, allocations);
        vm.expectRevert(DepositVault.InvalidRefund.selector);
        vault.withdraw(p, userSignature, platformSignature);
        assertEq(address(vault).balance, 5 ether);
    }

    function testEachSourceMustCompleteObservationAndSumMustMatch() public {
        vm.deal(address(vault), 10 ether);
        (T.SweepPermit memory p, T.SourceAllocation[] memory allocations) = _sweep(address(0), 5 ether);
        allocations[0].observedAt = uint48(block.timestamp);
        p.allocationsHash = vault.hashAllocations(allocations);
        _expectSweep(p, allocations, abi.encodeWithSelector(DepositVault.ObservationIncomplete.selector));
        allocations[0].observedAt -= authority.observationWindow();
        allocations[0].amount = 4 ether;
        p.allocationsHash = vault.hashAllocations(allocations);
        _expectSweep(p, allocations, abi.encodeWithSelector(DepositVault.InvalidSweep.selector));
    }

    function testRiskBeforeSweepStopsCollectingButNotRefunding() public {
        vm.deal(address(vault), 10 ether);
        _restrict(risks.vaultScope(address(vault)));
        (T.SweepPermit memory p, T.SourceAllocation[] memory allocations) = _sweep(address(0), 5 ether);
        _expectSweep(
            p,
            allocations,
            abi.encodeWithSelector(RiskRegistry.RiskRestricted.selector, risks.vaultScope(address(vault)))
        );
        _executeRefund(_refund(address(0), 5 ether));
        assertEq(recipient.balance, 5 ether);
    }

    function testNewUncontrolledDepositInvalidatesExpectedBalance() public {
        vm.deal(address(vault), 10 ether);
        (T.SweepPermit memory p, T.SourceAllocation[] memory allocations) = _sweep(address(0), 5 ether);
        vm.deal(address(vault), 11 ether);
        _expectSweep(p, allocations, abi.encodeWithSelector(DepositVault.InvalidSweep.selector));
    }

    function testERC20RefundAndSweepUseSeparateAssetNonce() public {
        token.mint(address(vault), 100e6);
        _executeRefund(_refund(address(token), 30e6));
        (T.SweepPermit memory p, T.SourceAllocation[] memory allocations) = _sweep(address(token), 70e6);
        _executeSweep(p, allocations);
        assertEq(token.balanceOf(recipient), 30e6);
        assertEq(token.balanceOf(address(hot)), 70e6);
        assertEq(vault.assetStateNonce(address(token)), 2);
        assertEq(vault.assetStateNonce(address(0)), 0);
    }

    function testTaxedAndIssuerFrozenTokensCannotCorruptAccounting() public {
        token.mint(address(vault), 100e6);
        T.RefundPermit memory p = _refund(address(token), 10e6);
        (bytes memory userSignature, bytes memory platformSignature) = _refundSignatures(p);
        token.setTaxed(true);
        vm.expectRevert(ExactTransfer.InexactTransfer.selector);
        vault.withdraw(p, userSignature, platformSignature);
        token.setTaxed(false);
        token.setBlocked(address(vault), true);
        vm.expectRevert(bytes("issuer frozen"));
        vault.withdraw(p, userSignature, platformSignature);
        assertEq(vault.assetStateNonce(address(token)), 0);
        assertEq(token.balanceOf(address(vault)), 100e6);
    }

    function testFuzzRefundAndNetSweepConserveFunds(uint96 initial, uint96 refundAmount) public {
        uint256 amount = bound(uint256(initial), 2, 99 ether);
        uint256 refund = bound(uint256(refundAmount), 1, amount - 1);
        vm.deal(address(vault), amount);
        _executeRefund(_refund(address(0), refund));
        (T.SweepPermit memory p, T.SourceAllocation[] memory allocations) =
            _sweep(address(0), amount - refund);
        _executeSweep(p, allocations);
        assertEq(recipient.balance + address(hot).balance, amount);
        assertEq(address(vault).balance, 0);
    }

    function _expectSweep(
        T.SweepPermit memory p,
        T.SourceAllocation[] memory allocations,
        bytes memory reason
    ) private {
        bytes memory authorization = _sign(SWEEP_PK, vault.hashSweep(p));
        vm.prank(relayer);
        vm.expectRevert(reason);
        vault.sweep(p, allocations, authorization);
    }
}
