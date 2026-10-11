// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { WalletFixture } from "./helpers/WalletFixture.sol";

contract RiskRegistryTest is WalletFixture {
    function testTwoCasesStayBlockedUntilBothReleasedAndEpochOnlyIncreases() public {
        address vault = s.factory.predictVault(WALLET);
        bytes32 other = keccak256("other-case");
        vm.startPrank(guardian);
        s.risk.addHold(vault, address(token), false, CASE);
        s.risk.addHold(vault, address(token), false, CASE);
        s.risk.addHold(vault, address(token), false, other);
        vm.stopPrank();
        (, uint256 epoch) = s.risk.epochs(vault, address(token));
        assertEq(epoch, 2);
        vm.prank(address(council));
        s.risk.releaseHold(vault, address(token), false, CASE);
        vm.expectRevert();
        s.risk.assertOpen(vault, address(token));
        vm.prank(address(council));
        s.risk.releaseHold(vault, address(token), false, other);
        s.risk.assertOpen(vault, address(token));
        (, epoch) = s.risk.epochs(vault, address(token));
        assertEq(epoch, 4);
    }

    function testGlobalHoldAlsoBlocksNativeAndAnotherAsset() public {
        address vault = s.factory.predictVault(WALLET);
        vm.prank(guardian);
        s.risk.addHold(vault, address(0), true, CASE);
        vm.expectRevert();
        s.risk.assertOpen(vault, address(0));
        vm.expectRevert();
        s.risk.assertOpen(vault, address(token));
    }

    function testGuardianCannotReleaseOrReduceReserveOrClearSecurityPause() public {
        address target = address(s.treasury);
        vm.startPrank(guardian);
        s.risk.addHold(target, address(token), false, CASE);
        s.risk.setReserve(target, address(token), CASE, 100, 0);
        vm.expectRevert();
        s.risk.releaseHold(target, address(token), false, CASE);
        vm.expectRevert();
        s.risk.setReserve(target, address(token), CASE, 99, 1);
        s.risk.setSecurityPause(target, address(token), false, true);
        vm.expectRevert();
        s.risk.setSecurityPause(target, address(token), false, false);
        vm.stopPrank();
    }

    function testReserveAbsoluteVersionAndDuplicateHoldDoNotAccumulate() public {
        address target = address(s.treasury);
        vm.startPrank(guardian);
        s.risk.applyPoolAssetHold(target, address(token), CASE, 100);
        s.risk.applyPoolAssetHold(target, address(token), CASE, 100);
        vm.stopPrank();
        assertEq(s.risk.totalReserve(target, address(token)), 100);
        (uint256 reserve, uint256 version) = s.risk.reserves(target, address(token), CASE);
        assertEq(reserve, 100);
        assertEq(version, 1);
        vm.expectRevert();
        vm.prank(guardian);
        s.risk.setReserve(target, address(token), CASE, 200, 0);
        assertEq(s.risk.totalReserve(target, address(token)), 100);
        vm.prank(address(council));
        s.risk.releaseHold(target, address(token), false, CASE);
        token.mint(target, 100);
        vm.expectRevert();
        s.risk.assertSpendable(target, address(token), 1, 0);
    }

    function testUnprivilegedControlChangesFail() public {
        vm.expectRevert();
        s.risk.addHold(payee, address(token), false, CASE);
        vm.expectRevert();
        s.risk.setReserve(payee, address(token), CASE, 1, 0);
        vm.expectRevert();
        s.risk.relocateReserve(payee, address(s.quarantine), address(token), CASE, 1, 0, 0, true);
    }

    function testFuzzHoldsAndReservesRemainIndependent(uint128 first, uint128 second) public {
        address target = address(s.treasury);
        bytes32 other = keccak256("second-case");
        vm.startPrank(guardian);
        s.risk.applyPoolAssetHold(target, address(token), CASE, first);
        s.risk.applyPoolAssetHold(target, address(token), other, second);
        vm.stopPrank();
        assertEq(s.risk.totalReserve(target, address(token)), uint256(first) + uint256(second));
        vm.prank(address(council));
        s.risk.releaseHold(target, address(token), false, CASE);
        vm.expectRevert();
        s.risk.assertOpen(target, address(token));
    }
}
