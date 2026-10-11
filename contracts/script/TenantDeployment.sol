// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { TenantTimelock } from "../src/control/TenantTimelock.sol";
import { TenantAuthority } from "../src/control/TenantAuthority.sol";
import { RiskRegistry } from "../src/control/RiskRegistry.sol";
import { PoolRegistry } from "../src/control/PoolRegistry.sol";
import { DispositionController } from "../src/control/DispositionController.sol";
import { VaultManager } from "../src/sweep/VaultManager.sol";
import { VaultFactory } from "../src/deposit/VaultFactory.sol";
import { TreasuryVault } from "../src/pools/TreasuryVault.sol";
import { ClearingVault } from "../src/pools/ClearingVault.sol";
import { QuarantineVault } from "../src/pools/QuarantineVault.sol";
import { ColdVault } from "../src/pools/ColdVault.sol";

/// @dev Shared fixed-nonce deployment plan. Contains no authority after deployment.
library TenantDeployment {
    struct Configuration {
        bytes32 tenantKey;
        bytes32 poolId;
        address council;
        address guardian;
        address executor;
        address[4] signers;
        address[] tokens;
        uint32 version;
        uint256 observationWindow;
    }

    struct Suite {
        TimelockController timelock;
        TenantAuthority authority;
        PoolRegistry pools;
        RiskRegistry risk;
        DispositionController disposition;
        VaultManager manager;
        VaultFactory factory;
        TreasuryVault treasury;
        ClearingVault clearing;
        QuarantineVault quarantine;
        ColdVault cold;
    }

    function deploy(Configuration memory c, address predictedFactory, address predictedController)
        internal
        returns (Suite memory s)
    {
        s.timelock = new TenantTimelock(c.council);
        s.authority = new TenantAuthority(
            c.tenantKey, address(s.timelock), c.council, c.guardian, c.executor, c.signers, c.tokens
        );
        s.pools = new PoolRegistry(s.authority, predictedFactory, c.poolId);
        s.risk = new RiskRegistry(s.authority, predictedController);
        s.disposition =
            new DispositionController(s.authority, s.risk, s.pools, VaultFactory(predictedFactory));
        require(address(s.disposition) == predictedController, "controller deployment address mismatch");
        s.manager = new VaultManager(s.authority, VaultFactory(predictedFactory), s.risk, s.pools);
        s.factory = new VaultFactory(
            s.authority, address(s.manager), address(s.disposition), s.risk, s.pools, c.version
        );
        require(address(s.factory) == predictedFactory, "factory deployment address mismatch");
        s.treasury = new TreasuryVault(s.authority, s.pools, s.risk);
        s.clearing = new ClearingVault(s.authority, s.pools, s.risk, address(s.manager), c.observationWindow);
        s.quarantine = new QuarantineVault(s.authority, s.pools, s.risk);
        s.cold = new ColdVault(s.authority, s.pools, s.risk);
    }
}
