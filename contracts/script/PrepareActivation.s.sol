// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { console2 } from "forge-std/console2.sol";
import { PoolRegistry } from "../src/control/PoolRegistry.sol";
import { VaultFactory } from "../src/deposit/VaultFactory.sol";
import { VaultManager } from "../src/sweep/VaultManager.sol";
import { WalletTypes } from "../src/common/WalletTypes.sol";
import { ActivationPlan } from "./ActivationPlan.sol";
import { DeploymentArtifacts } from "./DeploymentArtifacts.sol";

/// @notice Writes reviewable council calldata. This script never broadcasts governance transactions.
contract PrepareActivation is DeploymentArtifacts {
    function run() external {
        string memory manifest = vm.readFile(_manifestPath());
        require(vm.parseJsonUint(manifest, ".chainId") == block.chainid, "manifest chain mismatch");
        ActivationPlan.Configuration memory c;
        c.pools = PoolRegistry(_checkedContract(manifest, "poolRegistry"));
        c.factory = _checkedContract(manifest, "vaultFactory");
        c.treasury = _checkedContract(manifest, "treasury");
        c.clearing = _checkedContract(manifest, "clearing");
        c.quarantine = _checkedContract(manifest, "quarantine");
        c.cold = _checkedContract(manifest, "cold");
        address authority = _checkedContract(manifest, "authority");
        address manager = _checkedContract(manifest, "vaultManager");
        address controller = _checkedContract(manifest, "dispositionController");
        address registry = _checkedContract(manifest, "riskRegistry");
        TimelockController timelock = TimelockController(payable(_checkedContract(manifest, "timelock")));
        require(
            address(c.pools.authority()) == authority && c.pools.factory() == c.factory
                && VaultFactory(c.factory).manager() == manager
                && VaultFactory(c.factory).dispositionController() == controller
                && address(VaultManager(manager).risk()) == registry
                && c.pools.authority().governor() == address(timelock),
            "manifest binding mismatch"
        );
        require(
            c.pools.tenantKey() == vm.parseJsonBytes32(manifest, ".tenantKey")
                && c.pools.poolId() == vm.parseJsonBytes32(manifest, ".poolId"),
            "identity mismatch"
        );
        require(
            c.pools.routesPaused() && c.pools.poolKind(c.treasury) == WalletTypes.PoolKind.None
                && c.pools.poolKind(c.clearing) == WalletTypes.PoolKind.None
                && c.pools.poolKind(c.quarantine) == WalletTypes.PoolKind.None
                && c.pools.poolKind(c.cold) == WalletTypes.PoolKind.None,
            "suite already activated"
        );
        require(
            VaultFactory(c.factory).implementation() == _checkedContract(manifest, "implementation"),
            "implementation mismatch"
        );
        c.allowDirectSweep = vm.envOr("ALLOW_DIRECT_SWEEP", false);
        c.tokens = vm.parseJsonAddressArray(manifest, ".approvedTokens");
        c.nativeLimits = WalletTypes.Limits(
            vm.envUint("NATIVE_SINGLE_LIMIT"),
            vm.envUint("NATIVE_DAILY_LIMIT"),
            vm.envUint("NATIVE_ROLLING_LIMIT"),
            vm.envUint("NATIVE_COUNCIL_THRESHOLD"),
            vm.envUint("NATIVE_SAFETY_FLOOR")
        );
        c.tokenLimits = _tokenLimits(c.tokens.length);
        (address[] memory targets, uint256[] memory values, bytes[] memory calls) = ActivationPlan.build(c);
        _writeActivation(timelock, targets, values, calls);
    }

    function _checkedContract(string memory json, string memory name)
        private
        view
        returns (address account)
    {
        account = _readContract(json, name);
        require(
            account.code.length != 0
                && account.codehash == vm.parseJsonBytes32(json, string.concat(".", name, "CodeHash")),
            "manifest code hash mismatch"
        );
    }

    function _tokenLimits(uint256 count) private view returns (WalletTypes.Limits[] memory configurations) {
        configurations = new WalletTypes.Limits[](count);
        if (count == 0) return configurations;
        uint256[] memory single = vm.envUint("TOKEN_SINGLE_LIMITS", ",");
        uint256[] memory daily = vm.envUint("TOKEN_DAILY_LIMITS", ",");
        uint256[] memory rolling = vm.envUint("TOKEN_ROLLING_LIMITS", ",");
        uint256[] memory threshold = vm.envUint("TOKEN_COUNCIL_THRESHOLDS", ",");
        uint256[] memory floor = vm.envUint("TOKEN_SAFETY_FLOORS", ",");
        require(
            single.length == count && daily.length == count && rolling.length == count
                && threshold.length == count && floor.length == count,
            "token limits length mismatch"
        );
        for (uint256 i; i < count; ++i) {
            configurations[i] = WalletTypes.Limits(single[i], daily[i], rolling[i], threshold[i], floor[i]);
        }
    }

    function _writeActivation(
        TimelockController timelock,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calls
    ) private {
        uint256 delay = timelock.getMinDelay();
        require(delay >= 2 days, "governance delay too short");
        bytes32 salt = vm.envBytes32("ACTIVATION_SALT");
        require(salt != bytes32(0), "empty activation salt");
        bytes32 id = timelock.hashOperationBatch(targets, values, calls, bytes32(0), salt);
        string memory key = "tenant-activation";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "to", address(timelock));
        vm.serializeUint(key, "value", 0);
        vm.serializeUint(key, "delay", delay);
        vm.serializeBytes32(key, "operationId", id);
        vm.serializeBytes32(key, "salt", salt);
        vm.serializeAddress(key, "targets", targets);
        vm.serializeUint(key, "values", values);
        vm.serializeBytes(key, "calls", calls);
        vm.serializeBytes(
            key,
            "scheduleCalldata",
            abi.encodeCall(
                TimelockController.scheduleBatch, (targets, values, calls, bytes32(0), salt, delay)
            )
        );
        string memory json = vm.serializeBytes(
            key,
            "executeCalldata",
            abi.encodeCall(TimelockController.executeBatch, (targets, values, calls, bytes32(0), salt))
        );
        string memory path = string.concat(
            vm.projectRoot(), "/deployments/", vm.envOr("ACTIVATION_NAME", string("activation.local.json"))
        );
        vm.writeJson(json, path);
        console2.log("Activation calldata", path);
        console2.logBytes32(id);
    }
}
