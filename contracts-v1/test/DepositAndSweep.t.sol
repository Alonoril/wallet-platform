// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { WalletFixture } from "./helpers/WalletFixture.sol";
import { WalletTypes } from "../src/common/WalletTypes.sol";
import { DepositVault } from "../src/deposit/DepositVault.sol";
import { NoReturnToken, FalseToken, TaxToken, ReturnBombToken } from "./helpers/Mocks.sol";

contract DepositAndSweepTest is WalletFixture {
    function testPreFundedTokenDeploysAndSweepsWithoutNativeBalance() public {
        address vault = s.factory.predictVault(WALLET);
        token.mint(vault, 100 ether);
        WalletTypes.SweepPermit memory p =
            _sweepPermit(WALLET, address(token), address(s.treasury), 100 ether, bytes32(uint256(1)));
        bytes memory signature = _sign(RISK_KEY, s.manager.hashSweep(p));
        vm.prank(relayer);
        s.manager.sweep(p, signature);
        assertTrue(s.factory.isVault(vault));
        assertTrue(DepositVault(payable(vault)).initialized());
        assertEq(token.balanceOf(vault), 0);
        assertEq(vault.balance, 0);
        assertEq(token.balanceOf(address(s.treasury)), 100 ether);
        vm.expectRevert();
        vm.prank(relayer);
        s.manager.sweep(p, signature);
    }

    function testNativePreFundingAndFullSweep() public {
        address vault = s.factory.predictVault(WALLET);
        vm.deal(vault, 1 ether);
        WalletTypes.SweepPermit memory p =
            _sweepPermit(WALLET, address(0), address(s.treasury), 1 ether, bytes32(uint256(2)));
        bytes memory signature = _sign(RISK_KEY, s.manager.hashSweep(p));
        vm.prank(relayer);
        s.manager.sweep(p, signature);
        assertEq(vault.balance, 0);
        assertEq(address(s.treasury).balance, 1 ether);
        vm.deal(address(this), 1 ether);
        (bool received,) = vault.call{ value: 1 ether }("");
        assertTrue(received);
        assertEq(vault.balance, 1 ether);
    }

    function testFactoryAndInitializationCannotBeHijacked() public {
        vm.expectRevert();
        s.factory.deployVault(WALLET);
        vm.prank(relayer);
        address vault = s.manager.deployVault(WALLET);
        address implementation = s.factory.implementation();
        vm.expectRevert();
        DepositVault(payable(vault)).initialize();
        vm.expectRevert();
        DepositVault(payable(implementation)).initialize();
        vm.expectRevert();
        DepositVault(payable(vault)).sweep(address(token), payee, 1);
        vm.prank(relayer);
        assertEq(s.manager.deployVault(WALLET), vault);
    }

    function testUnDeployedRiskHoldBlocksFirstSweepAndOldPermitStaysRevoked() public {
        address vault = s.factory.predictVault(WALLET);
        token.mint(vault, 120 ether);
        WalletTypes.SweepPermit memory p =
            _sweepPermit(WALLET, address(token), address(s.treasury), 120 ether, bytes32(uint256(3)));
        bytes memory signature = _sign(RISK_KEY, s.manager.hashSweep(p));
        vm.prank(guardian);
        s.risk.addHold(vault, address(token), false, CASE);
        vm.expectRevert();
        vm.prank(relayer);
        s.manager.sweep(p, signature);
        assertEq(vault.code.length, 0);
        assertEq(token.balanceOf(vault), 120 ether);
        vm.prank(relayer);
        s.manager.deployVault(WALLET);
        vm.expectRevert();
        vm.prank(relayer);
        s.manager.sweep(p, signature);
        vm.prank(address(council));
        s.risk.releaseHold(vault, address(token), false, CASE);
        vm.expectRevert();
        vm.prank(relayer);
        s.manager.sweep(p, signature);
        p = _sweepPermit(WALLET, address(token), address(s.treasury), 120 ether, bytes32(uint256(4)));
        signature = _sign(RISK_KEY, s.manager.hashSweep(p));
        vm.prank(relayer);
        s.manager.sweep(p, signature);
        assertEq(token.balanceOf(address(s.treasury)), 120 ether);
    }

    function testDustAfterAuthorizationFailsWithoutSweepingExtraFunds() public {
        address vault = s.factory.predictVault(WALLET);
        token.mint(vault, 100 ether);
        WalletTypes.SweepPermit memory p =
            _sweepPermit(WALLET, address(token), address(s.treasury), 100 ether, bytes32(uint256(5)));
        bytes memory signature = _sign(RISK_KEY, s.manager.hashSweep(p));
        token.mint(vault, 1);
        vm.expectRevert();
        vm.prank(relayer);
        s.manager.sweep(p, signature);
        assertEq(vault.code.length, 0);
        assertEq(token.balanceOf(vault), 100 ether + 1);
    }

    function testWrongTenantDestinationSignerAndExpiredAuthorizationFail() public {
        token.mint(s.factory.predictVault(WALLET), 100);
        WalletTypes.SweepPermit memory p =
            _sweepPermit(WALLET, address(token), address(s.treasury), 100, bytes32(uint256(6)));
        bytes memory signature = _sign(WITHDRAW_KEY, s.manager.hashSweep(p));
        vm.expectRevert();
        vm.prank(relayer);
        s.manager.sweep(p, signature);
        p.tenantKey = bytes32(uint256(77));
        signature = _sign(RISK_KEY, s.manager.hashSweep(p));
        vm.expectRevert();
        vm.prank(relayer);
        s.manager.sweep(p, signature);
        p.tenantKey = TENANT;
        p.destination = payee;
        signature = _sign(RISK_KEY, s.manager.hashSweep(p));
        vm.expectRevert();
        vm.prank(relayer);
        s.manager.sweep(p, signature);
        p.destination = address(s.treasury);
        signature = _sign(RISK_KEY, s.manager.hashSweep(p));
        vm.warp(p.deadline + 1);
        vm.expectRevert();
        vm.prank(relayer);
        s.manager.sweep(p, signature);
    }

    function testBatchRiskItemRevertsWithoutRollingBackGoodItem() public {
        bytes32 second = keccak256("user-2");
        address firstVault = s.factory.predictVault(WALLET);
        address secondVault = s.factory.predictVault(second);
        token.mint(firstVault, 100);
        token.mint(secondVault, 200);
        WalletTypes.SweepPermit[] memory permits = new WalletTypes.SweepPermit[](2);
        permits[0] = _sweepPermit(WALLET, address(token), address(s.treasury), 100, bytes32(uint256(7)));
        permits[1] = _sweepPermit(second, address(token), address(s.treasury), 200, bytes32(uint256(8)));
        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _sign(RISK_KEY, s.manager.hashSweep(permits[0]));
        signatures[1] = _sign(RISK_KEY, s.manager.hashSweep(permits[1]));
        uint256[] memory caps = new uint256[](2);
        caps[0] = 700_000;
        caps[1] = 700_000;
        vm.prank(guardian);
        s.risk.addHold(secondVault, address(token), false, CASE);
        vm.prank(relayer);
        s.manager.batchDeployAndSweep(permits, signatures, caps);
        assertEq(token.balanceOf(address(s.treasury)), 100);
        assertTrue(firstVault.code.length > 0);
        assertEq(secondVault.code.length, 0);
        assertEq(uint256(s.manager.operationStatus(permits[0].operationId)), 1);
        assertEq(uint256(s.manager.operationStatus(permits[1].operationId)), 0);
    }

    function testCancelledOperationCannotBeReissuedWithSameId() public {
        token.mint(s.factory.predictVault(WALLET), 100);
        WalletTypes.SweepPermit memory p =
            _sweepPermit(WALLET, address(token), address(s.treasury), 100, bytes32(uint256(9)));
        bytes memory signature = _sign(RISK_KEY, s.manager.hashSweep(p));
        vm.prank(guardian);
        s.manager.cancelOperation(p.operationId);
        vm.expectRevert();
        vm.prank(relayer);
        s.manager.sweep(p, signature);
        assertEq(uint256(s.manager.operationStatus(p.operationId)), 2);
    }

    function testNoReturnTokenSupportedFalseAndTaxTokensRejected() public {
        NoReturnToken noReturn = new NoReturnToken();
        FalseToken falseToken = new FalseToken();
        TaxToken tax = new TaxToken();
        vm.startPrank(address(s.timelock));
        s.authority.setAsset(address(noReturn), true);
        s.authority.setAsset(address(falseToken), true);
        s.authority.setAsset(address(tax), true);
        vm.stopPrank();
        address vault = s.factory.predictVault(WALLET);
        noReturn.mint(vault, 100);
        falseToken.mint(vault, 100);
        tax.mint(vault, 100);
        WalletTypes.SweepPermit memory p =
            _sweepPermit(WALLET, address(noReturn), address(s.treasury), 100, bytes32(uint256(10)));
        bytes memory signature = _sign(RISK_KEY, s.manager.hashSweep(p));
        vm.prank(relayer);
        s.manager.sweep(p, signature);
        assertEq(noReturn.balanceOf(address(s.treasury)), 100);
        p = _sweepPermit(WALLET, address(falseToken), address(s.treasury), 100, bytes32(uint256(11)));
        signature = _sign(RISK_KEY, s.manager.hashSweep(p));
        vm.expectRevert();
        vm.prank(relayer);
        s.manager.sweep(p, signature);
        p = _sweepPermit(WALLET, address(tax), address(s.treasury), 100, bytes32(uint256(12)));
        signature = _sign(RISK_KEY, s.manager.hashSweep(p));
        vm.expectRevert();
        vm.prank(relayer);
        s.manager.sweep(p, signature);
        assertEq(tax.balanceOf(vault), 100);
    }

    function testFuzzAmountConservation(uint128 amount) public {
        vm.assume(amount > 0);
        address vault = s.factory.predictVault(WALLET);
        token.mint(vault, amount);
        WalletTypes.SweepPermit memory p =
            _sweepPermit(WALLET, address(token), address(s.treasury), amount, bytes32(uint256(13)));
        bytes memory signature = _sign(RISK_KEY, s.manager.hashSweep(p));
        vm.prank(relayer);
        s.manager.sweep(p, signature);
        assertEq(token.balanceOf(vault) + token.balanceOf(address(s.treasury)), amount);
    }
}
