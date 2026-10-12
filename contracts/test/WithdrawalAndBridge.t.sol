// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { WalletFixture } from "./helpers/WalletFixture.sol";
import { RejectingRecipient } from "./helpers/Mocks.sol";
import { WalletTypes as T } from "../src/common/WalletTypes.sol";
import { WithdrawalBook } from "../src/bridge/WithdrawalBook.sol";
import { HotVault } from "../src/pools/HotVault.sol";
import { TenantAuthority } from "../src/control/TenantAuthority.sol";
import { RiskRegistry } from "../src/control/RiskRegistry.sol";
import { ExactTransfer } from "../src/common/ExactTransfer.sol";

/// @notice 验证门限证书、跨池共享订单、付款/取消竞态，以及失败回滚和风险版本撤销。
contract WithdrawalAndBridgeTest is WalletFixture {
    bytes32 private constant REQUEST = keccak256("withdrawal request");

    function testValidCertificatePaysOnce() public {
        vm.deal(address(hot), 20 ether);
        T.WithdrawalPermit memory p = _withdrawal(hot, address(0), 5 ether, REQUEST);
        _executeWithdrawal(hot, p);
        assertEq(recipient.balance, 5 ether);
        assertEq(uint256(book.order(REQUEST).status), uint256(T.OrderStatus.Executed));
        assertEq(book.order(REQUEST).vault, address(hot));
        _expectWithdrawal(hot, p, abi.encodeWithSelector(WithdrawalBook.OrderAlreadyFinalized.selector));
        (uint256 spent,) = hot.spending(address(0));
        assertEq(spent, 5 ether);
    }

    function testSameEconomicOrderCannotBeResignedForAnotherVault() public {
        HotVault second = _createHot();
        vm.deal(address(hot), 20 ether);
        vm.deal(address(second), 20 ether);
        _executeWithdrawal(hot, _withdrawal(hot, address(0), 5 ether, REQUEST));
        T.WithdrawalPermit memory retry = _withdrawal(second, address(0), 5 ether, REQUEST);
        _expectWithdrawal(
            second, retry, abi.encodeWithSelector(WithdrawalBook.OrderAlreadyFinalized.selector)
        );
        assertEq(address(second).balance, 20 ether);
        assertEq(recipient.balance, 5 ether);
    }

    function testRelayerCannotPayWithoutCommittee() public {
        vm.deal(address(hot), 20 ether);
        T.WithdrawalPermit memory p = _withdrawal(hot, address(0), 5 ether, REQUEST);
        vm.prank(relayer);
        vm.expectRevert(HotVault.InvalidCertificate.selector);
        hot.executeWithdrawal(p, "", "");
    }

    function testCertificateCannotAuthorizeModifiedRecipient() public {
        vm.deal(address(hot), 20 ether);
        T.WithdrawalPermit memory p = _withdrawal(hot, address(0), 5 ether, REQUEST);
        bytes memory certificate = _certificate(hot, p);
        p.to = makeAddr("different recipient");
        vm.prank(relayer);
        vm.expectRevert(HotVault.InvalidCertificate.selector);
        hot.executeWithdrawal(p, certificate, "");
    }

    function testInsufficientDuplicateAndNonmemberSignaturesFail() public {
        vm.deal(address(hot), 20 ether);
        T.WithdrawalPermit memory p = _withdrawal(hot, address(0), 5 ether, REQUEST);
        T.WithdrawalAttestation memory a = _attestation(hot.hashWithdrawal(p));
        bytes32 digest = verifier.hashAttestation(a);
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _sign(committeeKeys[0], digest);
        signatures[1] = _sign(committeeKeys[1], digest);
        _rejectCertificate(p, abi.encode(a, signatures));
        signatures = _committeeSign(digest);
        signatures[1] = signatures[0];
        _rejectCertificate(p, abi.encode(a, signatures));
        signatures = _committeeSign(digest);
        signatures[0] = _sign(0xFACADE, digest);
        _rejectCertificate(p, abi.encode(a, signatures));
    }

    function testWrongSourceAppEpochAndActionFailEvenWithCommitteeSignatures() public {
        vm.deal(address(hot), 20 ether);
        T.WithdrawalPermit memory p = _withdrawal(hot, address(0), 5 ether, REQUEST);
        T.WithdrawalAttestation memory a = _attestation(hot.hashWithdrawal(p));
        a.sourceGenesisHash = keccak256("untrusted source");
        _rejectCertificate(p, abi.encode(a, _committeeSign(verifier.hashAttestation(a))));
        a = _attestation(hot.hashWithdrawal(p));
        ++a.withdrawalAppId;
        _rejectCertificate(p, abi.encode(a, _committeeSign(verifier.hashAttestation(a))));
        a = _attestation(hot.hashWithdrawal(p));
        ++a.committeeEpoch;
        _rejectCertificate(p, abi.encode(a, _committeeSign(verifier.hashAttestation(a))));
        a = _attestation(hot.hashWithdrawal(p));
        a.action = 2;
        _rejectCertificate(p, abi.encode(a, _committeeSign(verifier.hashAttestation(a))));
    }

    function testMalformedERC1271CertificateReturnsInvalidMagic() public view {
        assertEq(verifier.isValidSignature(bytes32(0), hex"00"), bytes4(0xffffffff));
        assertEq(verifier.isValidSignature(bytes32(0), new bytes(13000)), bytes4(0xffffffff));
    }

    function testCommitteeRevocationAndUnpauseNeverRevivesOldCertificate() public {
        vm.deal(address(hot), 20 ether);
        T.WithdrawalPermit memory p = _withdrawal(hot, address(0), 5 ether, REQUEST);
        bytes memory certificate = _certificate(hot, p);
        vm.prank(guardian);
        verifier.pause();
        _govern(address(verifier), abi.encodeCall(verifier.setPaused, (false, verifier.bridgeEpoch())));
        _rejectCertificate(p, certificate);
    }

    function testCancelledBeforePaymentBlocksAllVaults() public {
        vm.deal(address(hot), 20 ether);
        T.CancelPermit memory cancellation = _cancelPermit(REQUEST);
        bytes memory certificate = _cancelCertificate(cancellation);
        vm.prank(relayer);
        book.cancel(cancellation, certificate);
        assertEq(uint256(book.order(REQUEST).status), uint256(T.OrderStatus.Cancelled));
        _expectWithdrawal(
            hot,
            _withdrawal(hot, address(0), 5 ether, REQUEST),
            abi.encodeWithSelector(WithdrawalBook.OrderAlreadyFinalized.selector)
        );
    }

    function testPaymentBeforeCancellationKeepsExecutedState() public {
        vm.deal(address(hot), 20 ether);
        _executeWithdrawal(hot, _withdrawal(hot, address(0), 5 ether, REQUEST));
        T.CancelPermit memory cancellation = _cancelPermit(REQUEST);
        bytes memory certificate = _cancelCertificate(cancellation);
        vm.prank(relayer);
        vm.expectRevert(WithdrawalBook.OrderAlreadyFinalized.selector);
        book.cancel(cancellation, certificate);
        assertEq(uint256(book.order(REQUEST).status), uint256(T.OrderStatus.Executed));
    }

    function testApprovalCertificateCannotBeUsedForCancellation() public {
        T.WithdrawalPermit memory p = _withdrawal(hot, address(0), 5 ether, REQUEST);
        bytes memory certificate = _certificate(hot, p);
        T.CancelPermit memory cancellation = _cancelPermit(REQUEST);
        vm.prank(relayer);
        vm.expectRevert(WithdrawalBook.InvalidCancellation.selector);
        book.cancel(cancellation, certificate);
    }

    function testGuardianCanCancelWhileBridgePausedButRelayerCannotCancelArbitrarily() public {
        vm.prank(guardian);
        verifier.pause();
        vm.prank(relayer);
        vm.expectRevert(TenantAuthority.Unauthorized.selector);
        book.cancelByGuardian(REQUEST, CASE);
        vm.prank(guardian);
        book.cancelByGuardian(REQUEST, CASE);
        assertEq(uint256(book.order(REQUEST).status), uint256(T.OrderStatus.Cancelled));
    }

    function testPaymentFailureRollsBackBookBudgetAndNonce() public {
        vm.deal(address(hot), 20 ether);
        T.WithdrawalPermit memory p = _withdrawal(hot, address(0), 5 ether, REQUEST);
        p.to = address(new RejectingRecipient());
        _expectWithdrawal(hot, p, abi.encodeWithSelector(ExactTransfer.TransferFailed.selector));
        assertEq(uint256(book.order(REQUEST).status), uint256(T.OrderStatus.Unused));
        assertEq(hot.assetStateNonce(address(0)), 0);
        (uint256 daily, uint256 rolling) = hot.spending(address(0));
        assertEq(daily, 0);
        assertEq(rolling, 0);
    }

    function testHighAmountNeedsIndependentCouncilSignature() public {
        vm.deal(address(hot), 100 ether);
        T.WithdrawalPermit memory p = _withdrawal(hot, address(0), 60 ether, REQUEST);
        bytes memory certificate = _certificate(hot, p);
        vm.prank(relayer);
        vm.expectRevert(TenantAuthority.InvalidSignature.selector);
        hot.executeWithdrawal(p, certificate, "");
        _executeWithdrawal(hot, p);
        assertEq(recipient.balance, 60 ether);
    }

    function testContaminationAfterSweepFreezesPoolAndReleaseInvalidatesOldPermit() public {
        vm.deal(address(hot), 20 ether);
        T.WithdrawalPermit memory p = _withdrawal(hot, address(0), 5 ether, REQUEST);
        bytes32 scope = risks.vaultScope(address(hot));
        _restrict(scope);
        _expectWithdrawal(hot, p, abi.encodeWithSelector(RiskRegistry.RiskRestricted.selector, scope));
        _govern(address(risks), abi.encodeCall(risks.release, (scope, 0, 1, CASE)));
        _expectWithdrawal(hot, p, abi.encodeWithSelector(RiskRegistry.StaleRiskEpoch.selector, scope));
        _executeWithdrawal(hot, _withdrawal(hot, address(0), 5 ether, REQUEST));
    }

    function testSafetyFloorRiskReserveAndDailyRollingBudgets() public {
        vm.deal(address(hot), 100 ether);
        T.OutflowPolicy memory policy = manager.outflowPolicy(address(0));
        policy.singleLimit = 30 ether;
        policy.dailyLimit = 40 ether;
        policy.rollingLimit = 45 ether;
        policy.safetyFloor = 10 ether;
        _govern(
            address(manager),
            abi.encodeCall(manager.setOutflowPolicy, (address(0), policy, policy.policyEpoch))
        );
        vm.prank(guardian);
        risks.increaseReserve(address(hot), address(0), 50 ether, 0, CASE);
        assertEq(hot.availableOutflow(address(0)), 30 ether);
        _executeWithdrawal(hot, _withdrawal(hot, address(0), 30 ether, REQUEST));
        assertEq(hot.availableOutflow(address(0)), 10 ether);
        _expectWithdrawal(
            hot,
            _withdrawal(hot, address(0), 11 ether, keccak256("too much")),
            abi.encodeWithSelector(HotVault.OutflowUnavailable.selector)
        );
        _executeWithdrawal(hot, _withdrawal(hot, address(0), 10 ether, keccak256("second")));
        assertEq(hot.availableOutflow(address(0)), 0);
        vm.deal(address(hot), 100 ether);
        vm.warp(block.timestamp + 1 days);
        assertEq(hot.availableOutflow(address(0)), 5 ether);
        vm.warp(block.timestamp + 1 hours);
        assertEq(hot.availableOutflow(address(0)), 30 ether);
    }

    function testIssuerFreezeRollsBackERC20WithdrawalOrder() public {
        token.mint(address(hot), 100e6);
        token.setBlocked(address(hot), true);
        _expectWithdrawal(hot, _withdrawal(hot, address(token), 50e6, REQUEST), bytes("issuer frozen"));
        assertEq(uint256(book.order(REQUEST).status), uint256(T.OrderStatus.Unused));
    }

    function _expectWithdrawal(HotVault payer, T.WithdrawalPermit memory p, bytes memory reason) private {
        bytes memory certificate = _certificate(payer, p);
        bytes memory councilSignature = _sign(COUNCIL_PK, payer.hashWithdrawal(p));
        vm.prank(relayer);
        vm.expectRevert(reason);
        payer.executeWithdrawal(p, certificate, councilSignature);
    }

    function _rejectCertificate(T.WithdrawalPermit memory p, bytes memory certificate) private {
        vm.prank(relayer);
        vm.expectRevert(HotVault.InvalidCertificate.selector);
        hot.executeWithdrawal(p, certificate, "");
    }
}
