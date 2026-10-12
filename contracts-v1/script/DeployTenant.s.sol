// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { console2 } from "forge-std/console2.sol";
import { TenantDeployment } from "./TenantDeployment.sol";
import { DeploymentArtifacts } from "./DeploymentArtifacts.sol";

/// @notice Deploy only; pools/routes/limits must separately be activated through the council timelock.
contract DeployTenant is DeploymentArtifacts {
    function run() external returns (TenantDeployment.Suite memory suite) {
        address deployer = vm.envAddress("DEPLOYER");
        require(block.chainid == vm.envUint("EXPECTED_CHAIN_ID"), "unexpected chain");
        TenantDeployment.Configuration memory c;
        c.tenantKey = vm.envBytes32("TENANT_KEY");
        c.poolId = vm.envBytes32("POOL_ID");
        c.council = vm.envAddress("COUNCIL");
        c.guardian = vm.envAddress("GUARDIAN");
        c.executor = vm.envAddress("RELAYER");
        c.signers = [
            vm.envAddress("RISK_SIGNER"),
            vm.envAddress("WITHDRAWAL_SIGNER"),
            vm.envAddress("SETTLEMENT_SIGNER"),
            vm.envAddress("TRANSFER_SIGNER")
        ];
        c.tokens = bytes(vm.envOr("APPROVED_TOKENS", string(""))).length == 0
            ? new address[](0)
            : vm.envAddress("APPROVED_TOKENS", ",");
        c.version = 1;
        c.observationWindow = vm.envUint("OBSERVATION_WINDOW");
        require(c.observationWindow >= 30 minutes, "observation window below production baseline");
        uint256 nonce = vm.getNonce(deployer);
        require(nonce == vm.envUint("EXPECTED_DEPLOYER_NONCE"), "unexpected deployer nonce");
        address factory = vm.computeCreateAddress(deployer, nonce + 6);
        address controller = vm.computeCreateAddress(deployer, nonce + 4);
        vm.startBroadcast(deployer);
        suite = TenantDeployment.deploy(c, factory, controller);
        vm.stopBroadcast();
        _writeManifest(suite, c, deployer, nonce);
        console2.log("Timelock", address(suite.timelock));
        console2.log("Authority", address(suite.authority));
        console2.log("PoolRegistry", address(suite.pools));
        console2.log("RiskRegistry", address(suite.risk));
        console2.log("DispositionController", address(suite.disposition));
        console2.log("VaultManager", address(suite.manager));
        console2.log("VaultFactory", address(suite.factory));
        console2.log("Implementation", suite.factory.implementation());
        console2.log("Treasury", address(suite.treasury));
        console2.log("Clearing", address(suite.clearing));
        console2.log("Quarantine", address(suite.quarantine));
        console2.log("Cold", address(suite.cold));
    }
}
