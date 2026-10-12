// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { WalletFixture } from "./helpers/WalletFixture.sol";
import { WalletTypes as T } from "../src/common/WalletTypes.sol";
import { DepositVault } from "../src/deposit/DepositVault.sol";
import { HotVault } from "../src/pools/HotVault.sol";
import { HotPoolManager } from "../src/pools/HotPoolManager.sol";
import { RiskRegistry } from "../src/control/RiskRegistry.sol";

/// @notice 验证按币种容量、池数量边界、最旧健康池转冷，以及调拨/补仓的风险和限额。
contract PoolCapacityAndCustodyTest is WalletFixture {
    function testCreationStopsAtTwentyAndCanExpandToFiftyByGovernance() public {
        for (uint256 i = 1; i < 20; ++i) {
            _createHot();
        }
        vm.prank(relayer);
        vm.expectRevert(HotPoolManager.PoolLimitReached.selector);
        manager.createHotVault();
        _govern(address(manager), abi.encodeCall(manager.setMaxHotVaults, (50)));
        for (uint256 i = 20; i < 50; ++i) {
            _createHot();
        }
        assertEq(manager.hotVaultCount(), 50);
        vm.prank(relayer);
        vm.expectRevert(HotPoolManager.PoolLimitReached.selector);
        manager.createHotVault();
    }

    function testCapUpdateUsesExpectedVersionAndDifferentTokensHaveSeparateCapacity() public {
        vm.deal(address(hot), 100 ether);
        assertEq(manager.capacityOf(address(hot), address(0)), 0);
        assertEq(manager.capacityOf(address(hot), address(token)), 1_000_000e6);
        _govern(address(manager), abi.encodeCall(manager.setAssetCap, (address(0), 50 ether, true, 1)));
        assertEq(address(hot).balance, 100 ether);
        assertEq(manager.capacityOf(address(hot), address(0)), 0);
        vm.prank(address(timelock));
        vm.expectRevert(HotPoolManager.InvalidVersion.selector);
        manager.setAssetCap(address(0), 200 ether, true, 1);
    }

    function testConcurrentSignedSweepsCannotExceedCap() public {
        vm.deal(address(hot), 90 ether);
        vm.deal(address(vault), 10 ether);
        (T.SweepPermit memory first, T.SourceAllocation[] memory firstSources) = _sweep(address(0), 10 ether);
        _executeSweep(first, firstSources);
        vm.deal(address(vault), 10 ether);
        (T.SweepPermit memory second, T.SourceAllocation[] memory secondSources) =
            _sweep(address(0), 10 ether);
        bytes memory authorization = _sign(SWEEP_PK, vault.hashSweep(second));
        vm.prank(relayer);
        vm.expectRevert(HotPoolManager.CapacityExceeded.selector);
        vault.sweep(second, secondSources, authorization);
        assertEq(address(hot).balance, 100 ether);
        assertFalse(manager.movementConsumed(second.operationId));
        assertEq(vault.assetStateNonce(address(0)), 1);
    }

    function testMissingDisabledAndZeroCapsRejectControlledDeposits() public {
        vm.deal(address(vault), 10 ether);
        _govern(address(manager), abi.encodeCall(manager.setAssetCap, (address(0), 100 ether, false, 1)));
        (T.SweepPermit memory p, T.SourceAllocation[] memory sources) = _sweep(address(0), 1 ether);
        bytes memory authorization = _sign(SWEEP_PK, vault.hashSweep(p));
        vm.prank(relayer);
        vm.expectRevert(HotPoolManager.IncomingNotAllowed.selector);
        vault.sweep(p, sources, authorization);
        _govern(address(manager), abi.encodeCall(manager.setAssetCap, (address(0), 0, true, 2)));
        assertEq(manager.capacityOf(address(hot), address(0)), 0);
    }

    function testDirectTransferOverCapOnlyBlocksFurtherControlledInflow() public {
        vm.deal(address(hot), 110 ether);
        assertEq(manager.capacityOf(address(hot), address(0)), 0);
        assertEq(manager.findCapacity(address(0), 1), address(0));
        _executeWithdrawal(hot, _withdrawal(hot, address(0), 20 ether, keccak256("reduce exposure")));
        assertEq(manager.capacityOf(address(hot), address(0)), 10 ether);
        assertEq(cold.balance, 0);
    }

    function testHotTransferEnforcesDestinationCapAndMovementUniqueness() public {
        HotVault target = _createHot();
        vm.deal(address(hot), 20 ether);
        vm.deal(address(target), 95 ether);
        T.MovementPermit memory p = _movement(hot, address(0), address(target), 10 ether);
        (bytes memory authorization, bytes memory councilProof) = _movementSignatures(hot, p);
        vm.prank(relayer);
        vm.expectRevert(HotPoolManager.CapacityExceeded.selector);
        hot.moveToHot(p, authorization, councilProof);
        assertFalse(manager.movementConsumed(p.operationId));
        assertEq(hot.assetStateNonce(address(0)), 0);
        p = _movement(hot, address(0), address(target), 5 ether);
        (authorization, councilProof) = _movementSignatures(hot, p);
        vm.prank(relayer);
        hot.moveToHot(p, authorization, councilProof);
        assertEq(address(target).balance, 100 ether);
        assertEq(address(hot).balance, 15 ether);
        assertTrue(manager.movementConsumed(p.operationId));
        p.assetStateNonce = hot.assetStateNonce(address(0));
        p.expectedBalance = address(hot).balance;
        (authorization, councilProof) = _movementSignatures(hot, p);
        vm.prank(relayer);
        vm.expectRevert(HotPoolManager.MovementAlreadyConsumed.selector);
        hot.moveToHot(p, authorization, councilProof);
    }

    function testFullPoolRecyclesOldestHealthyMatchingAssetOnly() public {
        _fillPool();
        HotVault second = HotVault(payable(manager.hotVaultAt(1)));
        _restrict(risks.vaultScope(address(hot)));
        (address oldest, uint256 needed) = manager.oldestRecyclable(address(0), 10 ether);
        assertEq(oldest, address(second));
        assertEq(needed, 10 ether);
        T.MovementPermit memory p = _coldPermit(second, 10 ether);
        (bytes memory authorization, bytes memory councilProof) = _movementSignatures(second, p);
        vm.prank(relayer);
        second.sweepToCold(p, authorization, councilProof);
        assertEq(cold.balance, 10 ether);
        assertEq(address(hot).balance, 100 ether);
        assertEq(manager.findCapacity(address(0), 10 ether), address(second));
    }

    function testCannotRecycleNewerPoolWhileOlderHealthyCandidateExists() public {
        _fillPool();
        HotVault second = HotVault(payable(manager.hotVaultAt(1)));
        T.MovementPermit memory p = _coldPermit(second, 10 ether);
        (bytes memory authorization, bytes memory councilProof) = _movementSignatures(second, p);
        vm.prank(relayer);
        vm.expectRevert(HotVault.InvalidMovement.selector);
        second.sweepToCold(p, authorization, councilProof);
    }

    function testColdRecycleRequiresFullPoolAndCannotUseUnrelatedToken() public {
        vm.deal(address(hot), 100 ether);
        T.MovementPermit memory p = _coldPermit(hot, 10 ether);
        (bytes memory authorization, bytes memory councilProof) = _movementSignatures(hot, p);
        vm.prank(relayer);
        vm.expectRevert(HotVault.InvalidMovement.selector);
        hot.sweepToCold(p, authorization, councilProof);
        (address candidate,) = manager.oldestRecyclable(address(token), 1e6);
        assertEq(candidate, address(0));
    }

    function testContaminatedColdOrAllHotPoolsHaveNoRecycleCandidate() public {
        _fillPool();
        _restrict(risks.vaultScope(cold));
        (address candidate,) = manager.oldestRecyclable(address(0), 10 ether);
        assertEq(candidate, address(0));
        bytes32 coldScope = risks.vaultScope(cold);
        _govern(address(risks), abi.encodeCall(risks.release, (coldScope, 0, 1, CASE)));
        for (uint256 i; i < manager.hotVaultCount(); ++i) {
            _restrict(risks.vaultScope(manager.hotVaultAt(i)));
        }
        (candidate,) = manager.oldestRecyclable(address(0), 10 ether);
        assertEq(candidate, address(0));
    }

    function testColdNativeRefillAllowsExactCapAndRejectsOverflow() public {
        vm.deal(cold, 200 ether);
        vm.prank(cold);
        hot.fundFromCold{ value: 100 ether }(address(0), 100 ether, keccak256("native refill"));
        assertEq(address(hot).balance, 100 ether);
        vm.prank(cold);
        vm.expectRevert(HotPoolManager.CapacityExceeded.selector);
        hot.fundFromCold{ value: 1 }(address(0), 1, keccak256("over cap"));
        assertEq(address(hot).balance, 100 ether);
    }

    function testColdERC20RefillAndRiskFreeze() public {
        token.mint(cold, 100e6);
        vm.prank(cold);
        token.approve(address(hot), 100e6);
        vm.prank(cold);
        hot.fundFromCold(address(token), 50e6, keccak256("token refill"));
        assertEq(token.balanceOf(address(hot)), 50e6);
        _restrict(risks.vaultScope(address(hot)));
        vm.prank(cold);
        vm.expectRevert(HotPoolManager.IncomingNotAllowed.selector);
        hot.fundFromCold(address(token), 50e6, keccak256("frozen refill"));
        assertEq(token.balanceOf(cold), 50e6);
    }

    function testFuzzControlledDepositNeverExceedsNativeCap(uint96 start, uint96 incoming) public {
        uint256 beforeBalance = bound(uint256(start), 0, 100 ether);
        uint256 amount = bound(uint256(incoming), 1, 100 ether);
        vm.deal(address(hot), beforeBalance);
        vm.deal(address(vault), amount);
        (T.SweepPermit memory p, T.SourceAllocation[] memory allocations) = _sweep(address(0), amount);
        bytes memory authorization = _sign(SWEEP_PK, vault.hashSweep(p));
        vm.prank(relayer);
        if (beforeBalance + amount > 100 ether) vm.expectRevert(HotPoolManager.CapacityExceeded.selector);
        vault.sweep(p, allocations, authorization);
        assertLe(address(hot).balance, 100 ether);
    }

    function _fillPool() private {
        for (uint256 i = manager.hotVaultCount(); i < 20; ++i) {
            _createHot();
        }
        for (uint256 i; i < 20; ++i) {
            vm.deal(manager.hotVaultAt(i), 100 ether);
        }
    }

    function _coldPermit(HotVault source, uint256 required) private returns (T.MovementPermit memory p) {
        p = _movement(source, address(0), cold, required);
        p.requiredCapacity = required;
        p.coldAddressEpoch = manager.coldAddressEpoch();
    }

    function _movementSignatures(HotVault source, T.MovementPermit memory p)
        private
        view
        returns (bytes memory, bytes memory)
    {
        bytes32 digest = source.hashMovement(p);
        return (_sign(TRANSFER_PK, digest), _sign(COUNCIL_PK, digest));
    }
}
