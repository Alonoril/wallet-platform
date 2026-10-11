// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { WalletFixture } from "./helpers/WalletFixture.sol";
import { WalletTypes } from "../src/common/WalletTypes.sol";
import { ReturnBombToken } from "./helpers/Mocks.sol";

contract BatchTest is WalletFixture {
    function testLargeRevertDataCannotPreventNextItem() public {
        ReturnBombToken bomb = new ReturnBombToken();
        vm.prank(address(s.timelock));
        s.authority.setAsset(address(bomb), true);
        (WalletTypes.SweepPermit[] memory permits, bytes[] memory signatures, uint256[] memory caps) =
            _pair(address(bomb));
        bomb.mint(permits[0].vault, 100);
        vm.prank(relayer);
        s.manager.batchDeployAndSweep(permits, signatures, caps);
        assertEq(bomb.balanceOf(permits[0].vault), 100);
        assertEq(permits[0].vault.code.length, 0);
        assertEq(token.balanceOf(address(s.treasury)), 100);
        assertEq(uint256(s.manager.operationStatus(permits[0].operationId)), 0);
        assertEq(uint256(s.manager.operationStatus(permits[1].operationId)), 1);
    }

    function testItemOutOfGasDoesNotConsumeAuthorizationOrRollbackNextItem() public {
        (WalletTypes.SweepPermit[] memory permits, bytes[] memory signatures, uint256[] memory caps) =
            _pair(address(token));
        token.mint(permits[0].vault, 100);
        caps[0] = 100_000;
        vm.prank(relayer);
        s.manager.batchDeployAndSweep(permits, signatures, caps);
        assertEq(token.balanceOf(permits[0].vault), 100);
        assertEq(permits[0].vault.code.length, 0);
        assertEq(token.balanceOf(address(s.treasury)), 100);
        assertEq(uint256(s.manager.operationStatus(permits[0].operationId)), 0);
    }

    function testDuplicateOperationIdsRejectWholeBatchBeforeAnyEffect() public {
        (WalletTypes.SweepPermit[] memory permits, bytes[] memory signatures, uint256[] memory caps) =
            _pair(address(token));
        token.mint(permits[0].vault, 100);
        permits[1].operationId = permits[0].operationId;
        signatures[1] = _sign(RISK_KEY, s.manager.hashSweep(permits[1]));
        vm.expectRevert();
        vm.prank(relayer);
        s.manager.batchDeployAndSweep(permits, signatures, caps);
        assertEq(token.balanceOf(address(s.treasury)), 0);
        assertEq(permits[0].vault.code.length, 0);
        assertEq(permits[1].vault.code.length, 0);
    }

    function testOuterGasSafetyStopLeavesAllItemsRetryable() public {
        (WalletTypes.SweepPermit[] memory permits, bytes[] memory signatures, uint256[] memory caps) =
            _pair(address(token));
        token.mint(permits[0].vault, 100);
        vm.prank(relayer);
        (bool success,) = address(s.manager).call{ gas: 400_000 }(
            abi.encodeCall(s.manager.batchDeployAndSweep, (permits, signatures, caps))
        );
        assertTrue(success);
        assertEq(token.balanceOf(address(s.treasury)), 0);
        assertEq(uint256(s.manager.operationStatus(permits[0].operationId)), 0);
        assertEq(uint256(s.manager.operationStatus(permits[1].operationId)), 0);
        vm.expectRevert();
        s.manager.executeSweepItem(permits[0], signatures[0]);
    }

    function _pair(address firstAsset)
        private
        returns (WalletTypes.SweepPermit[] memory permits, bytes[] memory signatures, uint256[] memory caps)
    {
        permits = new WalletTypes.SweepPermit[](2);
        permits[0] = _sweepPermit(WALLET, firstAsset, address(s.treasury), 100, bytes32(uint256(1)));
        permits[1] =
            _sweepPermit(keccak256("user-2"), address(token), address(s.treasury), 100, bytes32(uint256(2)));
        token.mint(permits[1].vault, 100);
        signatures = new bytes[](2);
        signatures[0] = _sign(RISK_KEY, s.manager.hashSweep(permits[0]));
        signatures[1] = _sign(RISK_KEY, s.manager.hashSweep(permits[1]));
        caps = new uint256[](2);
        caps[0] = 700_000;
        caps[1] = 700_000;
    }
}
