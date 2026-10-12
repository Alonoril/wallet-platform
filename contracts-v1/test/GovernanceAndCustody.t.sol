// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { WalletFixture } from "./helpers/WalletFixture.sol";
import { WalletTypes } from "../src/common/WalletTypes.sol";
import { TenantAuthority } from "../src/control/TenantAuthority.sol";
import { TreasuryVault } from "../src/pools/TreasuryVault.sol";
import { TenantDeployment } from "../script/TenantDeployment.sol";
import { ActivationPlan } from "../script/ActivationPlan.sol";

contract GovernanceAndCustodyTest is WalletFixture {
    function testFreshSuiteActivationIsAtomicAndDefaultsToClearing() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        TenantDeployment.Configuration memory configuration = TenantDeployment.Configuration({
            tenantKey: TENANT,
            poolId: POOL,
            council: address(council),
            guardian: guardian,
            executor: relayer,
            signers: [vm.addr(RISK_KEY), vm.addr(WITHDRAW_KEY), vm.addr(SETTLE_KEY), vm.addr(TRANSFER_KEY)],
            tokens: tokens,
            version: 1,
            observationWindow: 30 minutes
        });
        uint256 nonce = vm.getNonce(address(this));
        TenantDeployment.Suite memory fresh = TenantDeployment.deploy(
            configuration,
            vm.computeCreateAddress(address(this), nonce + 6),
            vm.computeCreateAddress(address(this), nonce + 4)
        );
        vm.expectRevert();
        vm.prank(address(s.timelock));
        s.pools.registerPool(address(fresh.treasury), WalletTypes.PoolKind.Treasury);
        WalletTypes.Limits[] memory limits = new WalletTypes.Limits[](1);
        limits[0] = WalletTypes.Limits(10, 100, 100, 5, 0);
        ActivationPlan.Configuration memory activation = ActivationPlan.Configuration({
            pools: fresh.pools,
            factory: address(fresh.factory),
            treasury: address(fresh.treasury),
            clearing: address(fresh.clearing),
            quarantine: address(fresh.quarantine),
            cold: address(fresh.cold),
            allowDirectSweep: false,
            tokens: tokens,
            nativeLimits: limits[0],
            tokenLimits: limits
        });
        assertTrue(fresh.pools.routesPaused());
        (address[] memory targets, uint256[] memory values, bytes[] memory calls) =
            ActivationPlan.build(activation);
        assertEq(calls.length, 17);
        vm.prank(address(council));
        fresh.timelock.scheduleBatch(targets, values, calls, bytes32(0), CASE, 2 days);
        vm.expectRevert();
        vm.prank(address(council));
        fresh.timelock.executeBatch(targets, values, calls, bytes32(0), CASE);
        assertEq(uint256(fresh.pools.poolKind(address(fresh.treasury))), 0);
        vm.warp(block.timestamp + 2 days);
        vm.prank(address(council));
        fresh.timelock.executeBatch(targets, values, calls, bytes32(0), CASE);
        assertFalse(fresh.pools.routesPaused());
        fresh.pools.assertRoute(WalletTypes.RouteKind.Sweep, address(fresh.factory), address(fresh.clearing));
        vm.expectRevert();
        fresh.pools.assertRoute(WalletTypes.RouteKind.Sweep, address(fresh.factory), address(fresh.treasury));
        assertEq(fresh.pools.poolCodeHash(address(fresh.treasury)), address(fresh.treasury).codehash);
    }

    function testWithdrawalHashMatchesIndependentEip712Encoding() public view {
        WalletTypes.WithdrawalPermit memory p = _withdrawPermit(address(token), payee, 123, CASE);
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("Milon Treasury"),
                keccak256("1"),
                block.chainid,
                address(s.treasury)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "WithdrawalPermit(bytes32 requestId,bytes32 tenantKey,bytes32 poolId,address token,address to,uint256 amount,bytes32 approvalDigest,uint256 poolEpoch,uint256 poolAssetEpoch,uint256 policyEpoch,uint256 signerEpoch,uint256 validAfter,uint256 deadline)"
                ),
                p.requestId,
                p.tenantKey,
                p.poolId,
                p.token,
                p.to,
                p.amount,
                p.approvalDigest,
                p.poolEpoch,
                p.poolAssetEpoch,
                p.policyEpoch,
                p.signerEpoch,
                p.validAfter,
                p.deadline
            )
        );
        assertEq(s.treasury.hashWithdrawal(p), keccak256(abi.encodePacked(hex"1901", domain, structHash)));
    }

    function testSignerRotationRequiresScheduledCouncilAndTwoDays() public {
        bytes32 purpose = s.authority.RISK_SIGNER();
        address replacement = vm.addr(0x123456);
        bytes memory payload = abi.encodeCall(TenantAuthority.setSigner, (purpose, replacement));
        vm.expectRevert();
        vm.prank(guardian);
        s.authority.setSigner(purpose, replacement);
        vm.expectRevert();
        s.timelock.schedule(address(s.authority), 0, payload, bytes32(0), CASE, 2 days);
        vm.prank(address(council));
        s.timelock.schedule(address(s.authority), 0, payload, bytes32(0), CASE, 2 days);
        vm.expectRevert();
        vm.prank(address(council));
        s.timelock.execute(address(s.authority), 0, payload, bytes32(0), CASE);
        vm.warp(block.timestamp + 2 days);
        vm.prank(address(council));
        s.timelock.execute(address(s.authority), 0, payload, bytes32(0), CASE);
        (address account, uint256 epoch) = s.authority.signers(purpose);
        assertEq(account, replacement);
        assertEq(epoch, 2);
        assertFalse(s.timelock.hasRole(s.timelock.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function testGovernanceCannotReduceDelayFloor() public {
        bytes memory payload = abi.encodeWithSignature("updateDelay(uint256)", 1);
        vm.prank(address(council));
        s.timelock.schedule(address(s.timelock), 0, payload, bytes32(0), CASE, 2 days);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert();
        vm.prank(address(council));
        s.timelock.execute(address(s.timelock), 0, payload, bytes32(0), CASE);
        assertEq(s.timelock.getMinDelay(), 2 days);
    }

    function testRouteChangeRequiresPauseAndGuardianCannotResume() public {
        vm.expectRevert();
        vm.prank(address(s.timelock));
        s.pools.setRoute(WalletTypes.RouteKind.Sweep, address(s.factory), address(s.clearing), false);
        uint256 epoch = s.pools.routeEpoch();
        vm.prank(guardian);
        s.pools.setRoutesPaused(true);
        assertGt(s.pools.routeEpoch(), epoch);
        vm.expectRevert();
        vm.prank(guardian);
        s.pools.setRoutesPaused(false);
        vm.startPrank(address(s.timelock));
        s.pools.setRoute(WalletTypes.RouteKind.Sweep, address(s.factory), address(s.clearing), false);
        s.pools.setRoutesPaused(false);
        vm.stopPrank();
        vm.expectRevert();
        s.pools.assertRoute(WalletTypes.RouteKind.Sweep, address(s.factory), address(s.clearing));
    }

    function testTreasuryMigrationRequiresCouncilAndSharesBudget() public {
        TreasuryVault next = _nextTreasury();
        token.mint(address(s.treasury), 100);
        WalletTypes.TransferPermit memory p =
            _transferPermit(address(token), address(next), 40, WalletTypes.RouteKind.Migration, CASE);
        bytes32 digest = s.treasury.hashTransfer(p);
        bytes memory signature = _sign(TRANSFER_KEY, digest);
        vm.expectRevert();
        vm.prank(relayer);
        s.treasury.transferCustody(p, signature, "");
        bytes memory offline = _sign(COUNCIL_KEY, digest);
        vm.prank(relayer);
        s.treasury.transferCustody(p, signature, offline);
        assertEq(token.balanceOf(address(next)), 40);
        assertEq(s.pools.dailySpent(address(token), block.timestamp / 1 days), 40);
        vm.expectRevert();
        vm.prank(relayer);
        s.treasury.transferCustody(p, signature, offline);
    }

    function testCustodyCannotBypassDestinationHoldOrSourceReserve() public {
        TreasuryVault next = _nextTreasury();
        token.mint(address(s.treasury), 100);
        vm.prank(guardian);
        s.risk.addHold(address(next), address(token), false, CASE);
        WalletTypes.TransferPermit memory p =
            _transferPermit(address(token), address(next), 40, WalletTypes.RouteKind.Migration, CASE);
        bytes32 digest = s.treasury.hashTransfer(p);
        bytes memory signature = _sign(TRANSFER_KEY, digest);
        bytes memory offline = _sign(COUNCIL_KEY, digest);
        vm.expectRevert();
        vm.prank(relayer);
        s.treasury.transferCustody(p, signature, offline);
        vm.prank(address(council));
        s.risk.releaseHold(address(next), address(token), false, CASE);
        vm.prank(guardian);
        s.risk.setReserve(address(s.treasury), address(token), CASE, 70, 0);
        p = _transferPermit(address(token), address(next), 40, WalletTypes.RouteKind.Migration, CASE);
        digest = s.treasury.hashTransfer(p);
        signature = _sign(TRANSFER_KEY, digest);
        offline = _sign(COUNCIL_KEY, digest);
        vm.expectRevert();
        vm.prank(relayer);
        s.treasury.transferCustody(p, signature, offline);
        assertEq(token.balanceOf(address(s.treasury)), 100);
    }

    function testWithdrawalSignatureCannotReplayOnAnotherChain() public {
        token.mint(address(s.treasury), 100);
        WalletTypes.WithdrawalPermit memory p = _withdrawPermit(address(token), payee, 10, CASE);
        bytes memory signature = _sign(WITHDRAW_KEY, s.treasury.hashWithdrawal(p));
        vm.chainId(block.chainid + 1);
        vm.expectRevert();
        vm.prank(relayer);
        s.treasury.executeWithdrawal(p, signature, "");
        vm.expectRevert();
        s.factory.predictVault(WALLET);
    }

    function _nextTreasury() private returns (TreasuryVault next) {
        next = new TreasuryVault(s.authority, s.pools, s.risk);
        vm.startPrank(address(s.timelock));
        s.pools.registerPool(address(next), WalletTypes.PoolKind.Treasury);
        s.pools.setRoutesPaused(true);
        s.pools.setRoute(WalletTypes.RouteKind.Migration, address(s.treasury), address(next), true);
        s.pools.setRoutesPaused(false);
        vm.stopPrank();
    }
}
