// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";
import { TenantDeployment } from "./TenantDeployment.sol";

abstract contract DeploymentArtifacts is Script {
    function _manifestPath() internal view returns (string memory) {
        return string.concat(
            vm.projectRoot(), "/deployments/", vm.envOr("MANIFEST_NAME", string("suite.local.json"))
        );
    }

    function _writeManifest(
        TenantDeployment.Suite memory s,
        TenantDeployment.Configuration memory c,
        address deployer,
        uint256 nonce
    ) internal {
        string memory key = "tenant-suite";
        vm.serializeString(key, "status", "planned-reconcile-with-receipts-before-issuing-addresses");
        vm.serializeString(key, "solc", "0.8.28");
        vm.serializeString(key, "evmVersion", "cancun");
        vm.serializeBool(key, "viaIR", true);
        vm.serializeUint(key, "optimizerRuns", 200);
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeUint(key, "deployerNonce", nonce);
        vm.serializeAddress(key, "deployer", deployer);
        vm.serializeBytes32(key, "tenantKey", c.tenantKey);
        vm.serializeBytes32(key, "poolId", c.poolId);
        vm.serializeBytes32(key, "addressDomain", s.factory.ADDRESS_DOMAIN_V1());
        vm.serializeUint(key, "vaultVersion", c.version);
        vm.serializeUint(key, "observationWindow", c.observationWindow);
        vm.serializeAddress(key, "council", c.council);
        vm.serializeAddress(key, "guardian", c.guardian);
        vm.serializeAddress(key, "relayer", c.executor);
        vm.serializeAddress(key, "onlineSigners", _signers(c));
        vm.serializeAddress(key, "approvedTokens", c.tokens);
        _recordContract(key, "timelock", address(s.timelock));
        _recordContract(key, "authority", address(s.authority));
        _recordContract(key, "poolRegistry", address(s.pools));
        _recordContract(key, "riskRegistry", address(s.risk));
        _recordContract(key, "dispositionController", address(s.disposition));
        _recordContract(key, "vaultManager", address(s.manager));
        _recordContract(key, "vaultFactory", address(s.factory));
        _recordContract(key, "treasury", address(s.treasury));
        _recordContract(key, "clearing", address(s.clearing));
        _recordContract(key, "quarantine", address(s.quarantine));
        _recordContract(key, "cold", address(s.cold));
        string memory json = _recordContract(key, "implementation", s.factory.implementation());
        vm.writeJson(json, _manifestPath());
        console2.log("Planned deployment manifest", _manifestPath());
    }

    function _recordContract(string memory key, string memory name, address account)
        internal
        returns (string memory json)
    {
        vm.serializeAddress(key, name, account);
        return vm.serializeBytes32(key, string.concat(name, "CodeHash"), account.codehash);
    }

    function _readContract(string memory json, string memory name) internal pure returns (address account) {
        account = vm.parseJsonAddress(json, string.concat(".", name));
        require(account != address(0), "zero manifest address");
    }

    function _signers(TenantDeployment.Configuration memory c)
        private
        pure
        returns (address[] memory members)
    {
        members = new address[](4);
        for (uint256 i; i < 4; ++i) {
            members[i] = c.signers[i];
        }
    }
}
