// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { WalletFixture } from "./helpers/WalletFixture.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { TenantTimelock } from "../src/control/TenantTimelock.sol";
import { TenantAuthority } from "../src/control/TenantAuthority.sol";
import { RiskRegistry } from "../src/control/RiskRegistry.sol";
import { MilonWithdrawalVerifier } from "../src/bridge/MilonWithdrawalVerifier.sol";

/// @notice 使用真实 schedule/execute 验证延时治理，确保应急角色不能放宽限制或单方修改签名配置。
contract GovernanceTest is WalletFixture {
    function testCouncilProposalMustWaitThenAnyoneMayExecuteExactOperation() public {
        bytes memory payload = abi.encodeCall(manager.setAssetCap, (address(0), 150 ether, true, 1));
        bytes32 salt = keccak256("cap proposal");
        vm.prank(address(council));
        timelock.schedule(address(manager), 0, payload, bytes32(0), salt, 2 days);
        vm.expectRevert();
        timelock.execute(address(manager), 0, payload, bytes32(0), salt);
        vm.warp(block.timestamp + 2 days);
        timelock.execute(address(manager), 0, payload, bytes32(0), salt);
        assertEq(manager.assetCap(address(0)).maxBalanceRaw, 150 ether);
        assertEq(manager.assetCap(address(0)).capVersion, 2);
    }

    function testTimelockDelayCannotBeLoweredBelowTwoDays() public {
        bytes memory payload = abi.encodeCall(timelock.updateDelay, (1 days));
        bytes32 salt = keccak256("bad delay");
        vm.prank(address(council));
        timelock.schedule(address(timelock), 0, payload, bytes32(0), salt, 2 days);
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(TenantTimelock.UnsafeGovernance.selector);
        timelock.execute(address(timelock), 0, payload, bytes32(0), salt);
        assertEq(timelock.getMinDelay(), 2 days);
    }

    function testDelayCanBeIncreasedOnlyByCompletedTimelockOperation() public {
        bytes memory payload = abi.encodeCall(timelock.updateDelay, (3 days));
        bytes32 salt = keccak256("increase delay");
        vm.prank(address(council));
        timelock.schedule(address(timelock), 0, payload, bytes32(0), salt, 2 days);
        vm.warp(block.timestamp + 2 days);
        timelock.execute(address(timelock), 0, payload, bytes32(0), salt);
        assertEq(timelock.getMinDelay(), 3 days);
        vm.prank(address(council));
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, 2 days, 3 days)
        );
        timelock.schedule(address(timelock), 0, payload, bytes32(0), keccak256("short wait"), 2 days);
    }

    function testGuardianCannotRaiseCapsReleaseRiskOrChangeSigners() public {
        vm.prank(guardian);
        vm.expectRevert(TenantAuthority.Unauthorized.selector);
        manager.setAssetCap(address(0), 1000 ether, true, 1);
        bytes32 scope = risks.vaultScope(address(hot));
        _restrict(scope);
        vm.prank(guardian);
        vm.expectRevert(TenantAuthority.Unauthorized.selector);
        risks.release(scope, 0, 1, CASE);
        bytes32 refundRole = authority.REFUND_SIGNER();
        vm.prank(guardian);
        vm.expectRevert(TenantAuthority.Unauthorized.selector);
        authority.setSigner(refundRole, guardian, 1);
    }

    function testRiskUpdatesRejectOutOfOrderAndDuplicateEpochs() public {
        bytes32 scope = risks.vaultScope(address(hot));
        _restrict(scope);
        vm.prank(guardian);
        vm.expectRevert(RiskRegistry.InvalidRiskUpdate.selector);
        risks.restrict(scope, 0, 0, CASE);
        _govern(address(risks), abi.encodeCall(risks.release, (scope, 0, 1, CASE)));
        assertEq(risks.state(scope).epoch, 2);
    }

    function testSignerRolesMustBeSeparatedFromRelayerAndOtherSigners() public {
        bytes32 role = authority.REFUND_SIGNER();
        vm.prank(address(timelock));
        vm.expectRevert(TenantAuthority.InvalidConfiguration.selector);
        authority.setSigner(role, relayer, 1);
        address sweepSigner = vm.addr(SWEEP_PK);
        vm.prank(address(timelock));
        vm.expectRevert(TenantAuthority.InvalidConfiguration.selector);
        authority.setSigner(role, sweepSigner, 1);
    }

    function testWeakOrDuplicateCommitteesAreRejected() public {
        address[] memory members = verifier.members();
        bytes32 committeeId = verifier.committeeId();
        uint64 epoch = verifier.committeeEpoch();
        vm.prank(address(timelock));
        vm.expectRevert(MilonWithdrawalVerifier.InvalidCommittee.selector);
        verifier.installCommittee(committeeId, members, 2, epoch);
        members[1] = members[0];
        vm.prank(address(timelock));
        vm.expectRevert(MilonWithdrawalVerifier.InvalidCommittee.selector);
        verifier.installCommittee(committeeId, members, 3, epoch);
    }

    function testSuiteCannotBeReboundToClearOrderHistory() public {
        vm.expectRevert(TenantAuthority.Unauthorized.selector);
        authority.bindSuite(address(factory), address(manager), address(verifier), address(book));
    }
}
