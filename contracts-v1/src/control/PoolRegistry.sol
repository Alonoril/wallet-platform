// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TenantAuthority } from "./TenantAuthority.sol";
import { TenantComponent } from "../common/TenantComponent.sol";
import { WalletTypes } from "../common/WalletTypes.sol";

interface IRegisteredPool {
    function tenantKey() external view returns (bytes32);
    function poolId() external view returns (bytes32);
    function authority() external view returns (address);
    function pools() external view returns (address);
    function risk() external view returns (address);
}

interface IFactoryRegistry {
    function isVault(address vault) external view returns (bool);
    function implementation() external view returns (address);
}

interface IVaultRiskBinding {
    function risk() external view returns (address);
}

/// @notice Tenant-wide limits are shared by every registered Treasury, so migration cannot reset budgets.
contract PoolRegistry is TenantComponent {
    address public immutable factory;
    bytes32 public immutable poolId;
    uint256 public routeEpoch;
    uint256 public policyEpoch;
    bool public routesPaused = true;
    mapping(address => WalletTypes.PoolKind) public poolKind;
    mapping(address => bytes32) public poolCodeHash;
    mapping(bytes32 => bool) public routes;
    mapping(address => bool) public blockedRecipients;
    mapping(address => WalletTypes.Limits) public limits;
    mapping(address => mapping(uint256 => uint256)) public dailySpent;
    mapping(address => mapping(uint256 => uint256)) public hourlySpent;

    error InvalidRoute();
    error LimitExceeded();

    event PoolRegistered(address indexed pool, WalletTypes.PoolKind kind);
    event RouteChanged(
        WalletTypes.RouteKind indexed kind,
        address indexed source,
        address indexed destination,
        bool enabled,
        uint256 epoch
    );
    event LimitsChanged(address indexed token, WalletTypes.Limits configuration, uint256 epoch);
    event RecipientChanged(address indexed recipient, bool blocked);
    event RoutesPauseChanged(bool paused, uint256 epoch);

    constructor(TenantAuthority authority_, address factory_, bytes32 poolId_) TenantComponent(authority_) {
        if (factory_ == address(0) || poolId_ == bytes32(0)) revert InvalidConfiguration();
        factory = factory_;
        poolId = poolId_;
    }

    function registerPool(address pool, WalletTypes.PoolKind kind) external onlyGovernor {
        if (
            pool.code.length == 0 || kind == WalletTypes.PoolKind.None
                || poolKind[pool] != WalletTypes.PoolKind.None || IRegisteredPool(pool).tenantKey() != tenantKey
                || IRegisteredPool(pool).poolId() != poolId
                || IRegisteredPool(pool).authority() != address(authority)
                || IRegisteredPool(pool).pools() != address(this)
                || IRegisteredPool(pool).risk()
                    != IVaultRiskBinding(IFactoryRegistry(factory).implementation()).risk()
        ) {
            revert InvalidConfiguration();
        }
        poolKind[pool] = kind;
        poolCodeHash[pool] = pool.codehash;
        ++routeEpoch;
        emit PoolRegistered(pool, kind);
    }

    /// @notice Route changes require a paused routing plane. Resuming always needs delayed governance.
    function setRoutesPaused(bool paused) external {
        if (msg.sender != authority.governor() && !(msg.sender == authority.guardian() && paused)) {
            revert Unauthorized();
        }
        if (routesPaused == paused) return;
        routesPaused = paused;
        ++routeEpoch;
        emit RoutesPauseChanged(paused, routeEpoch);
    }

    function routeKey(WalletTypes.RouteKind kind, address source, address destination)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(kind, source, destination));
    }

    function setRoute(WalletTypes.RouteKind kind, address source, address destination, bool enabled)
        external
        onlyGovernor
    {
        if (!routesPaused) revert InvalidRoute();
        WalletTypes.PoolKind target = poolKind[destination];
        if (source == destination || target == WalletTypes.PoolKind.None) revert InvalidRoute();
        if (kind == WalletTypes.RouteKind.Sweep) {
            if (
                source != factory
                    || (target != WalletTypes.PoolKind.Clearing && target != WalletTypes.PoolKind.Treasury)
            ) revert InvalidRoute();
        } else if (kind == WalletTypes.RouteKind.Settlement) {
            if (poolKind[source] != WalletTypes.PoolKind.Clearing || target != WalletTypes.PoolKind.Treasury)
            {
                revert InvalidRoute();
            }
        } else if (kind == WalletTypes.RouteKind.Disposition) {
            if (
                (source != factory && poolKind[source] == WalletTypes.PoolKind.None)
                    || (
                        target != WalletTypes.PoolKind.Quarantine
                            && !(
                                poolKind[source] == WalletTypes.PoolKind.Quarantine
                                    && target == WalletTypes.PoolKind.Treasury
                            )
                    )
            ) revert InvalidRoute();
        } else if (kind == WalletTypes.RouteKind.Rebalance) {
            if (
                !(
                    (
                        poolKind[source] == WalletTypes.PoolKind.Treasury
                            && (target == WalletTypes.PoolKind.Cold || target == WalletTypes.PoolKind.Treasury)
                    )
                        || (
                            poolKind[source] == WalletTypes.PoolKind.Cold
                                && target == WalletTypes.PoolKind.Treasury
                        )
                )
            ) revert InvalidRoute();
        } else {
            if (
                poolKind[source] == WalletTypes.PoolKind.None || poolKind[source] != target
                    || target == WalletTypes.PoolKind.Quarantine || target == WalletTypes.PoolKind.Cold
            ) revert InvalidRoute();
        }
        routes[routeKey(kind, source, destination)] = enabled;
        ++routeEpoch;
        emit RouteChanged(kind, source, destination, enabled, routeEpoch);
    }

    function assertRoute(WalletTypes.RouteKind kind, address source, address destination) external view {
        if (
            routesPaused || !routes[routeKey(kind, source, destination)]
                || destination.codehash != poolCodeHash[destination]
                || (source != factory && source.codehash != poolCodeHash[source])
        ) revert InvalidRoute();
    }

    function isInternal(address account) public view returns (bool) {
        return account == factory || poolKind[account] != WalletTypes.PoolKind.None
            || IFactoryRegistry(factory).isVault(account);
    }

    function setRecipientBlocked(address account, bool blocked) external {
        if (
            msg.sender != authority.governor() && msg.sender != authority.council()
                && !(msg.sender == authority.guardian() && blocked)
        ) revert Unauthorized();
        blockedRecipients[account] = blocked;
        ++policyEpoch;
        emit RecipientChanged(account, blocked);
    }

    function setLimits(address token, WalletTypes.Limits calldata configuration) external onlyGovernor {
        _setLimits(token, configuration);
    }

    function tightenLimits(address token, WalletTypes.Limits calldata configuration) external onlyGuardian {
        WalletTypes.Limits memory old = limits[token];
        if (
            configuration.single > old.single || configuration.daily > old.daily
                || configuration.rolling > old.rolling || configuration.councilThreshold > old.councilThreshold
                || configuration.safetyFloor < old.safetyFloor
        ) revert InvalidConfiguration();
        _setLimits(token, configuration);
    }

    function consumeLimit(address token, uint256 amount) external {
        if (
            poolKind[msg.sender] != WalletTypes.PoolKind.Treasury
                && poolKind[msg.sender] != WalletTypes.PoolKind.Cold
        ) revert Unauthorized();
        WalletTypes.Limits memory configuration = limits[token];
        uint256 day = block.timestamp / 1 days;
        uint256 hour = block.timestamp / 1 hours;
        uint256 rolling;
        // Includes 25 complete/current hour buckets: conservatively covers every trailing 24h window.
        for (uint256 offset; offset <= 24 && offset <= hour; ++offset) {
            rolling += hourlySpent[token][hour - offset];
        }
        if (
            amount == 0 || amount > configuration.single
                || dailySpent[token][day] + amount > configuration.daily
                || rolling + amount > configuration.rolling
        ) revert LimitExceeded();
        dailySpent[token][day] += amount;
        hourlySpent[token][hour] += amount;
    }

    function safetyFloor(address token) external view returns (uint256) {
        return limits[token].safetyFloor;
    }

    function councilRequired(address token, uint256 amount) external view returns (bool) {
        return amount > limits[token].councilThreshold;
    }

    function _setLimits(address token, WalletTypes.Limits calldata configuration) private {
        _validateAsset(token);
        if (configuration.single > configuration.daily || configuration.single > configuration.rolling) {
            revert InvalidConfiguration();
        }
        limits[token] = configuration;
        ++policyEpoch;
        emit LimitsChanged(token, configuration, policyEpoch);
    }
}
