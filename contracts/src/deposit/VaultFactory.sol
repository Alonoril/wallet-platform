// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { DepositVault } from "./DepositVault.sol";
import { TenantComponent } from "../common/TenantComponent.sol";
import { TenantAuthority } from "../control/TenantAuthority.sol";
import { RiskRegistry } from "../control/RiskRegistry.sol";
import { PoolRegistry } from "../control/PoolRegistry.sol";

contract VaultFactory is TenantComponent {
    bytes32 public constant ADDRESS_DOMAIN_V1 = keccak256("MILON_DEPOSIT_V1");
    address public immutable implementation;
    address public immutable manager;
    address public immutable dispositionController;
    bytes32 public immutable poolId;
    uint32 public immutable vaultVersion;
    uint256 public immutable deploymentChainId;
    mapping(bytes32 => address) public vaults;
    mapping(address => bool) public isVault;

    event VaultDeployed(bytes32 indexed walletKey, address indexed vault, uint32 version);

    constructor(
        TenantAuthority authority_,
        address manager_,
        address controller_,
        RiskRegistry risk_,
        PoolRegistry pools_,
        uint32 version_
    ) TenantComponent(authority_) {
        if (
            manager_ == address(0) || controller_ == address(0) || version_ == 0
                || pools_.factory() != address(this) || address(risk_.authority()) != address(authority_)
                || address(pools_.authority()) != address(authority_)
        ) revert InvalidConfiguration();
        manager = manager_;
        dispositionController = controller_;
        poolId = pools_.poolId();
        vaultVersion = version_;
        deploymentChainId = block.chainid;
        implementation = address(new DepositVault(address(this), manager_, controller_, risk_, pools_));
    }

    function salt(bytes32 walletKey) public view returns (bytes32) {
        if (block.chainid != deploymentChainId || walletKey == bytes32(0)) revert InvalidConfiguration();
        return keccak256(abi.encode(ADDRESS_DOMAIN_V1, deploymentChainId, tenantKey, walletKey, vaultVersion));
    }

    function predictVault(bytes32 walletKey) public view returns (address) {
        return Clones.predictDeterministicAddress(implementation, salt(walletKey), address(this));
    }

    function deployVault(bytes32 walletKey) external returns (address vault) {
        if (msg.sender != manager && msg.sender != dispositionController) revert Unauthorized();
        vault = vaults[walletKey];
        if (vault != address(0)) {
            if (
                vault.code.length == 0 || !isVault[vault] || vault != predictVault(walletKey)
                    || !DepositVault(payable(vault)).initialized()
            ) revert InvalidConfiguration();
            return vault;
        }
        vault = Clones.cloneDeterministic(implementation, salt(walletKey));
        DepositVault(payable(vault)).initialize();
        vaults[walletKey] = vault;
        isVault[vault] = true;
        emit VaultDeployed(walletKey, vault, vaultVersion);
    }
}
