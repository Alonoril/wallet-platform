// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { WalletFixture } from "./helpers/WalletFixture.sol";
import { WalletTypes } from "../src/common/WalletTypes.sol";

contract ColdTest is WalletFixture {
    function testCoolingAndReturningAssetsAlwaysNeedsCouncilOnReturn() public {
        token.mint(address(s.treasury), 100);
        WalletTypes.TransferPermit memory p = _transferPermit(
            address(token), address(s.cold), 40, WalletTypes.RouteKind.Rebalance, bytes32(uint256(1))
        );
        bytes memory signature = _sign(TRANSFER_KEY, s.treasury.hashTransfer(p));
        vm.prank(relayer);
        s.treasury.transferCustody(p, signature, "");
        assertEq(token.balanceOf(address(s.cold)), 40);
        p = _returnPermit(address(token), 40, bytes32(uint256(2)));
        bytes32 digest = s.cold.hashTransfer(p);
        signature = _sign(TRANSFER_KEY, digest);
        vm.expectRevert();
        vm.prank(relayer);
        s.cold.returnToTreasury(p, signature, "");
        bytes memory offline = _sign(COUNCIL_KEY, digest);
        vm.prank(relayer);
        s.cold.returnToTreasury(p, signature, offline);
        assertEq(token.balanceOf(address(s.treasury)), 100);
        assertEq(s.pools.dailySpent(address(token), block.timestamp / 1 days), 80);
        vm.expectRevert();
        vm.prank(relayer);
        s.cold.returnToTreasury(p, signature, offline);
    }

    function testColdHoldBlocksReturnAndFundsCanBeIsolated() public {
        token.mint(address(s.cold), 100);
        vm.prank(guardian);
        s.risk.applyPoolAssetHold(address(s.cold), address(token), CASE, 50);
        WalletTypes.TransferPermit memory p = _returnPermit(address(token), 40, bytes32(uint256(3)));
        bytes32 digest = s.cold.hashTransfer(p);
        bytes memory signature = _sign(TRANSFER_KEY, digest);
        bytes memory offline = _sign(COUNCIL_KEY, digest);
        vm.expectRevert();
        vm.prank(relayer);
        s.cold.returnToTreasury(p, signature, offline);
        WalletTypes.DispositionPermit memory disposition = _dispositionPermit(
            address(s.cold), address(token), address(s.quarantine), 50, 50, bytes32(uint256(4))
        );
        offline = _sign(COUNCIL_KEY, s.disposition.hashDisposition(disposition));
        vm.prank(relayer);
        s.disposition.executeDisposition(disposition, new bytes32[](0), new uint256[](0), offline);
        assertEq(token.balanceOf(address(s.cold)), 50);
        assertEq(s.risk.totalReserve(address(s.quarantine), address(token)), 50);
        vm.expectRevert();
        s.risk.assertOpen(address(s.cold), address(token));
    }

    function testNativeReturnIsExactAndCannotBePaidToExternalRecipient() public {
        vm.deal(address(s.cold), 1 ether);
        WalletTypes.TransferPermit memory p = _returnPermit(address(0), 1 ether, bytes32(uint256(5)));
        p.destination = payee;
        bytes32 digest = s.cold.hashTransfer(p);
        bytes memory signature = _sign(TRANSFER_KEY, digest);
        bytes memory offline = _sign(COUNCIL_KEY, digest);
        vm.expectRevert();
        vm.prank(relayer);
        s.cold.returnToTreasury(p, signature, offline);
        p = _returnPermit(address(0), 1 ether, bytes32(uint256(6)));
        digest = s.cold.hashTransfer(p);
        signature = _sign(TRANSFER_KEY, digest);
        offline = _sign(COUNCIL_KEY, digest);
        vm.prank(relayer);
        s.cold.returnToTreasury(p, signature, offline);
        assertEq(address(s.cold).balance, 0);
        assertEq(address(s.treasury).balance, 1 ether);
    }

    function _returnPermit(address asset, uint256 amount, bytes32 operationId)
        private
        view
        returns (WalletTypes.TransferPermit memory p)
    {
        p = _transferPermit(asset, address(s.treasury), amount, WalletTypes.RouteKind.Rebalance, operationId);
        (p.sourceEpoch, p.sourceAssetEpoch) = s.risk.epochs(address(s.cold), asset);
    }
}
