// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { WalletFixture } from "./helpers/WalletFixture.sol";
import { WalletTypes } from "../src/common/WalletTypes.sol";
import { ClearingVault } from "../src/pools/ClearingVault.sol";

contract ClearingAndDispositionTest is WalletFixture {
    function testSettlementRequiresObservationWindowAndCannotReleaseLotTwice() public {
        bytes32 lotId = bytes32(uint256(1));
        _sweepToClearing(100, lotId);
        (bytes32[] memory ids, uint256[] memory amounts) = _oneLot(lotId, 100);
        WalletTypes.SettlementPermit memory p =
            _settlementPermit(address(token), address(s.treasury), ids, amounts, bytes32(uint256(2)));
        bytes memory signature = _sign(SETTLE_KEY, s.clearing.hashSettlement(p));
        vm.expectRevert();
        vm.prank(relayer);
        s.clearing.settle(p, ids, amounts, signature, "");
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(relayer);
        s.clearing.settle(p, ids, amounts, signature, "");
        assertEq(token.balanceOf(address(s.treasury)), 100);
        assertEq(s.clearing.outstanding(address(token)), 0);
        vm.expectRevert();
        vm.prank(relayer);
        s.clearing.settle(p, ids, amounts, signature, "");
    }

    function testUnattributedDirectTransferCreatesNoLot() public {
        token.mint(address(s.clearing), 100);
        assertEq(s.clearing.outstanding(address(token)), 0);
        vm.expectRevert();
        s.clearing.recordLot(bytes32(uint256(3)), address(token), 100);
        (bytes32[] memory ids, uint256[] memory amounts) = _oneLot(bytes32(uint256(3)), 100);
        WalletTypes.SettlementPermit memory p =
            _settlementPermit(address(token), address(s.treasury), ids, amounts, bytes32(uint256(4)));
        bytes memory signature = _sign(SETTLE_KEY, s.clearing.hashSettlement(p));
        vm.expectRevert();
        vm.prank(relayer);
        s.clearing.settle(p, ids, amounts, signature, "");
    }

    function testDestinationHoldPreventsClearingFundsEnteringTreasury() public {
        bytes32 lotId = bytes32(uint256(5));
        _sweepToClearing(100, lotId);
        vm.warp(block.timestamp + 30 minutes);
        vm.prank(guardian);
        s.risk.applyPoolAssetHold(address(s.treasury), address(token), CASE, 0);
        (bytes32[] memory ids, uint256[] memory amounts) = _oneLot(lotId, 100);
        WalletTypes.SettlementPermit memory p =
            _settlementPermit(address(token), address(s.treasury), ids, amounts, bytes32(uint256(6)));
        bytes memory signature = _sign(SETTLE_KEY, s.clearing.hashSettlement(p));
        vm.expectRevert();
        vm.prank(relayer);
        s.clearing.settle(p, ids, amounts, signature, "");
        assertEq(s.clearing.outstanding(address(token)), 100);
    }

    function testPartialSettlementAndClearingMigrationPreserveMaturity() public {
        bytes32 lotId = bytes32(uint256(7));
        _sweepToClearing(100, lotId);
        ClearingVault next = new ClearingVault(s.authority, s.pools, s.risk, address(s.manager), 1);
        vm.startPrank(address(s.timelock));
        s.pools.registerPool(address(next), WalletTypes.PoolKind.Clearing);
        s.pools.setRoutesPaused(true);
        s.pools.setRoute(WalletTypes.RouteKind.Migration, address(s.clearing), address(next), true);
        s.pools.setRoutesPaused(false);
        vm.stopPrank();
        (bytes32[] memory ids, uint256[] memory amounts) = _oneLot(lotId, 40);
        WalletTypes.SettlementPermit memory p =
            _settlementPermit(address(token), address(next), ids, amounts, bytes32(uint256(8)));
        bytes32 digest = s.clearing.hashSettlement(p);
        bytes memory signature = _sign(SETTLE_KEY, digest);
        bytes memory offlineSignature = _sign(COUNCIL_KEY, digest);
        vm.prank(relayer);
        s.clearing.settle(p, ids, amounts, signature, offlineSignature);
        bytes32 newId = keccak256(abi.encode(address(s.clearing), p.operationId, lotId));
        (,,, uint256 oldMaturity) = s.clearing.lots(lotId);
        (,, uint256 released, uint256 newMaturity) = next.lots(newId);
        assertEq(newMaturity, oldMaturity);
        assertEq(released, 0);
        assertEq(s.clearing.outstanding(address(token)), 60);
        assertEq(next.outstanding(address(token)), 40);
    }

    function testUndeployedRiskVaultCanBeDisposedWithoutManagerPermission() public {
        address vault = s.factory.predictVault(WALLET);
        token.mint(vault, 100);
        vm.prank(guardian);
        s.risk.applyPoolAssetHold(vault, address(token), CASE, 100);
        WalletTypes.DispositionPermit memory p =
            _dispositionPermit(vault, address(token), address(s.quarantine), 100, 100, bytes32(uint256(9)));
        p.walletKey = WALLET;
        bytes memory signature = _sign(COUNCIL_KEY, s.disposition.hashDisposition(p));
        vm.prank(relayer);
        s.disposition.executeDisposition(p, new bytes32[](0), new uint256[](0), signature);
        assertTrue(s.factory.isVault(vault));
        assertEq(token.balanceOf(address(s.quarantine)), 100);
        assertEq(s.risk.totalReserve(vault, address(token)), 0);
        assertEq(s.risk.totalReserve(address(s.quarantine), address(token)), 100);
        vm.expectRevert();
        s.risk.assertOpen(address(s.quarantine), address(token));
        vm.expectRevert();
        vm.prank(relayer);
        s.disposition.executeDisposition(p, new bytes32[](0), new uint256[](0), signature);
    }

    function testNewCaseInvalidatesPreviouslyApprovedDisposition() public {
        token.mint(address(s.treasury), 100);
        vm.prank(guardian);
        s.risk.applyPoolAssetHold(address(s.treasury), address(token), CASE, 100);
        WalletTypes.DispositionPermit memory p = _dispositionPermit(
            address(s.treasury), address(token), address(s.quarantine), 100, 100, bytes32(uint256(10))
        );
        bytes memory signature = _sign(COUNCIL_KEY, s.disposition.hashDisposition(p));
        vm.prank(guardian);
        s.risk.addHold(address(s.treasury), address(token), false, keccak256("new-case"));
        vm.expectRevert();
        vm.prank(relayer);
        s.disposition.executeDisposition(p, new bytes32[](0), new uint256[](0), signature);
        assertEq(token.balanceOf(address(s.treasury)), 100);
    }

    function testSecurityPauseCannotBeBypassedEvenByCouncilSignature() public {
        token.mint(address(s.treasury), 100);
        vm.prank(guardian);
        s.risk.setSecurityPause(address(s.treasury), address(token), false, true);
        WalletTypes.DispositionPermit memory p = _dispositionPermit(
            address(s.treasury), address(token), address(s.quarantine), 100, 0, bytes32(uint256(11))
        );
        bytes memory signature = _sign(COUNCIL_KEY, s.disposition.hashDisposition(p));
        vm.expectRevert();
        vm.prank(relayer);
        s.disposition.executeDisposition(p, new bytes32[](0), new uint256[](0), signature);
    }

    function testDispositionRetiresClearingLotsAndPreservesOtherReserve() public {
        bytes32 lotId = bytes32(uint256(12));
        _sweepToClearing(100, lotId);
        vm.prank(guardian);
        s.risk.applyPoolAssetHold(address(s.clearing), address(token), CASE, 40);
        bytes32 otherCase = keccak256("other-case");
        vm.prank(guardian);
        s.risk.applyPoolAssetHold(address(s.clearing), address(token), otherCase, 30);
        WalletTypes.DispositionPermit memory p = _dispositionPermit(
            address(s.clearing), address(token), address(s.quarantine), 40, 40, bytes32(uint256(13))
        );
        (bytes32[] memory ids, uint256[] memory amounts) = _oneLot(lotId, 40);
        p.lotsHash = keccak256(abi.encode(ids, amounts));
        bytes memory signature = _sign(COUNCIL_KEY, s.disposition.hashDisposition(p));
        vm.prank(relayer);
        s.disposition.executeDisposition(p, ids, amounts, signature);
        assertEq(s.clearing.outstanding(address(token)), 60);
        assertEq(s.risk.totalReserve(address(s.clearing), address(token)), 30);
        vm.expectRevert();
        s.risk.assertOpen(address(s.clearing), address(token));
        (,, uint256 released,) = s.clearing.lots(lotId);
        assertEq(released, 40);
        assertEq(token.balanceOf(address(s.quarantine)), 40);
        vm.prank(address(council));
        s.risk.releaseHold(address(s.clearing), address(token), false, CASE);
        vm.prank(address(council));
        s.risk.releaseHold(address(s.clearing), address(token), false, otherCase);
        vm.prank(address(council));
        s.risk.setReserve(address(s.clearing), address(token), otherCase, 0, 1);
        vm.warp(block.timestamp + 30 minutes);
        amounts[0] = 100;
        WalletTypes.SettlementPermit memory settlement =
            _settlementPermit(address(token), address(s.treasury), ids, amounts, bytes32(uint256(14)));
        signature = _sign(SETTLE_KEY, s.clearing.hashSettlement(settlement));
        vm.expectRevert();
        vm.prank(relayer);
        s.clearing.settle(settlement, ids, amounts, signature, "");
        amounts[0] = 60;
        settlement =
            _settlementPermit(address(token), address(s.treasury), ids, amounts, bytes32(uint256(15)));
        signature = _sign(SETTLE_KEY, s.clearing.hashSettlement(settlement));
        vm.prank(relayer);
        s.clearing.settle(settlement, ids, amounts, signature, "");
        assertEq(s.clearing.outstanding(address(token)), 0);
        assertEq(token.balanceOf(address(s.treasury)), 60);
    }

    function testUnattributedClearingFundsCanBeIsolatedWithoutRetiringAnyLot() public {
        bytes32 lotId = keccak256("recorded-lot");
        _sweepToClearing(100, lotId);
        token.mint(address(s.clearing), 20);
        vm.prank(guardian);
        s.risk.applyPoolAssetHold(address(s.clearing), address(token), CASE, 20);
        WalletTypes.DispositionPermit memory p = _dispositionPermit(
            address(s.clearing), address(token), address(s.quarantine), 20, 20, keccak256("unknown-funds")
        );
        bytes memory signature = _sign(COUNCIL_KEY, s.disposition.hashDisposition(p));
        vm.prank(relayer);
        s.disposition.executeDisposition(p, new bytes32[](0), new uint256[](0), signature);
        assertEq(s.clearing.outstanding(address(token)), 100);
        assertEq(token.balanceOf(address(s.clearing)), 100);
        assertEq(token.balanceOf(address(s.quarantine)), 20);
        (,, uint256 released,) = s.clearing.lots(lotId);
        assertEq(released, 0);
    }

    function testUnattributedDispositionCannotConsumeRecordedLotBalance() public {
        _sweepToClearing(100, keccak256("recorded-lot"));
        WalletTypes.DispositionPermit memory p = _dispositionPermit(
            address(s.clearing),
            address(token),
            address(s.quarantine),
            1,
            0,
            keccak256("missing-unknown-funds")
        );
        bytes memory signature = _sign(COUNCIL_KEY, s.disposition.hashDisposition(p));
        vm.expectRevert();
        vm.prank(relayer);
        s.disposition.executeDisposition(p, new bytes32[](0), new uint256[](0), signature);
        assertEq(s.risk.totalReserve(address(s.quarantine), address(token)), 0);
        assertEq(s.clearing.outstanding(address(token)), 100);
    }

    function testTreasurySafetyFloorDoesNotTrapReleasedQuarantineBalance() public {
        token.mint(address(s.quarantine), 100);
        vm.prank(address(s.timelock));
        s.pools.setLimits(address(token), WalletTypes.Limits(100, 200, 200, 100, 10));
        vm.prank(guardian);
        s.risk.setReserve(address(s.quarantine), address(token), CASE, 100, 0);
        WalletTypes.DispositionPermit memory p = _dispositionPermit(
            address(s.quarantine),
            address(token),
            address(s.treasury),
            100,
            100,
            keccak256("release-with-treasury-floor")
        );
        p.preserveRestriction = false;
        bytes memory signature = _sign(COUNCIL_KEY, s.disposition.hashDisposition(p));
        vm.prank(relayer);
        s.disposition.executeDisposition(p, new bytes32[](0), new uint256[](0), signature);
        assertEq(token.balanceOf(address(s.quarantine)), 0);
        assertEq(token.balanceOf(address(s.treasury)), 100);
    }

    function testQuarantineReleaseRequiresAllHoldsClearedAndOnlyRegisteredTreasury() public {
        token.mint(address(s.quarantine), 100);
        vm.prank(guardian);
        s.risk.applyPoolAssetHold(address(s.quarantine), address(token), CASE, 100);
        WalletTypes.DispositionPermit memory p = _dispositionPermit(
            address(s.quarantine), address(token), address(s.treasury), 100, 100, bytes32(uint256(15))
        );
        p.preserveRestriction = false;
        bytes memory signature = _sign(COUNCIL_KEY, s.disposition.hashDisposition(p));
        vm.expectRevert();
        vm.prank(relayer);
        s.disposition.executeDisposition(p, new bytes32[](0), new uint256[](0), signature);
        vm.prank(address(council));
        s.risk.releaseHold(address(s.quarantine), address(token), false, CASE);
        p = _dispositionPermit(
            address(s.quarantine), address(token), address(s.treasury), 100, 100, bytes32(uint256(15))
        );
        p.preserveRestriction = false;
        signature = _sign(COUNCIL_KEY, s.disposition.hashDisposition(p));
        vm.prank(relayer);
        s.disposition.executeDisposition(p, new bytes32[](0), new uint256[](0), signature);
        assertEq(token.balanceOf(address(s.treasury)), 100);
        assertEq(s.risk.totalReserve(address(s.quarantine), address(token)), 0);
        s.risk.assertOpen(address(s.treasury), address(token));
    }
}
