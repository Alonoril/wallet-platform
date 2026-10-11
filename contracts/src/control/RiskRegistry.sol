// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TenantAuthority } from "./TenantAuthority.sol";
import { TenantComponent } from "../common/TenantComponent.sol";
import { ExactTransfer } from "../common/ExactTransfer.sol";

/// @notice Per-case holds survive deployment of counterfactual deposit addresses.
contract RiskRegistry is TenantComponent {
    struct Scope {
        uint256 epoch;
        uint256 count;
        bytes32 holdDigest;
        bool securityPaused;
    }

    struct Reserve {
        uint256 amount;
        uint256 version;
    }

    address public immutable dispositionController;
    mapping(bytes32 => Scope) public scopes;
    mapping(bytes32 => mapping(bytes32 => bool)) public holdByCase;
    mapping(address => mapping(address => mapping(bytes32 => Reserve))) public reserves;
    mapping(address => mapping(address => uint256)) public totalReserve;

    error RiskBlocked();
    error StaleControl();
    error InsufficientUnrestrictedBalance();

    event HoldChanged(
        address indexed target,
        address indexed token,
        bytes32 indexed caseId,
        bool allAssets,
        bool active,
        uint256 epoch
    );
    event SecurityPauseChanged(address indexed target, address indexed token, bool allAssets, bool paused);
    event ReserveChanged(
        address indexed target, address indexed token, bytes32 indexed caseId, uint256 amount, uint256 version
    );

    constructor(TenantAuthority authority_, address controller_) TenantComponent(authority_) {
        if (controller_ == address(0)) revert InvalidConfiguration();
        dispositionController = controller_;
    }

    function scopeKey(address target, address token, bool allAssets) public pure returns (bytes32) {
        return keccak256(abi.encode(target, allAssets ? address(0) : token, allAssets));
    }

    function addHold(address target, address token, bool allAssets, bytes32 caseId) external onlyGuardian {
        _addHold(target, token, allAssets, caseId);
    }

    function releaseHold(address target, address token, bool allAssets, bytes32 caseId)
        external
        onlyCouncil
    {
        bytes32 key = scopeKey(target, token, allAssets);
        if (!holdByCase[key][caseId]) revert InvalidConfiguration();
        holdByCase[key][caseId] = false;
        Scope storage scope = scopes[key];
        --scope.count;
        scope.holdDigest ^= keccak256(abi.encode(caseId));
        ++scope.epoch;
        emit HoldChanged(target, token, caseId, allAssets, false, scope.epoch);
    }

    function setSecurityPause(address target, address token, bool allAssets, bool paused) external {
        if (paused) {
            if (msg.sender != authority.guardian() && msg.sender != authority.governor()) {
                revert Unauthorized();
            }
        } else if (msg.sender != authority.governor()) {
            revert Unauthorized();
        }
        Scope storage scope = scopes[scopeKey(target, token, allAssets)];
        if (scope.securityPaused == paused) return;
        scope.securityPaused = paused;
        ++scope.epoch;
        emit SecurityPauseChanged(target, token, allAssets, paused);
    }

    function setReserve(address target, address token, bytes32 caseId, uint256 amount, uint256 version)
        external
    {
        Reserve storage reserve = reserves[target][token][caseId];
        if (
            msg.sender != authority.council() && msg.sender != authority.governor()
                && !(msg.sender == authority.guardian() && amount >= reserve.amount)
        ) revert Unauthorized();
        _setReserve(target, token, caseId, amount, version);
    }

    function applyPoolAssetHold(address target, address token, bytes32 caseId, uint256 minimumReserve)
        external
        onlyGuardian
    {
        _addHold(target, token, false, caseId);
        Reserve storage reserve = reserves[target][token][caseId];
        if (minimumReserve > reserve.amount) {
            _setReserve(target, token, caseId, minimumReserve, reserve.version);
        }
    }

    function epochs(address target, address token)
        public
        view
        returns (uint256 globalEpoch, uint256 assetEpoch)
    {
        globalEpoch = scopes[scopeKey(target, token, true)].epoch;
        assetEpoch = scopes[scopeKey(target, token, false)].epoch;
    }

    function assertEpochs(address target, address token, uint256 globalEpoch, uint256 assetEpoch)
        external
        view
    {
        (uint256 currentGlobal, uint256 currentAsset) = epochs(target, token);
        if (globalEpoch != currentGlobal || assetEpoch != currentAsset) revert StaleControl();
    }

    function assertNoSecurityPause(address target, address token) public view {
        if (
            scopes[scopeKey(target, token, true)].securityPaused
                || scopes[scopeKey(target, token, false)].securityPaused
        ) revert RiskBlocked();
    }

    function assertOpen(address target, address token) public view {
        assertNoSecurityPause(target, token);
        if (
            scopes[scopeKey(target, token, true)].count != 0
                || scopes[scopeKey(target, token, false)].count != 0
        ) revert RiskBlocked();
    }

    function assertSpendable(address source, address token, uint256 amount, uint256 safetyFloor)
        external
        view
    {
        assertOpen(source, token);
        assertBalanceFloor(source, token, amount, safetyFloor);
    }

    function assertBalanceFloor(address source, address token, uint256 amount, uint256 safetyFloor)
        public
        view
    {
        uint256 balance = ExactTransfer.balance(token, source);
        uint256 floor = totalReserve[source][token] + safetyFloor;
        if (balance < floor || amount > balance - floor) revert InsufficientUnrestrictedBalance();
    }

    function controlDigest(address target, address token) external view returns (bytes32) {
        return keccak256(
            abi.encode(
                scopes[scopeKey(target, token, true)],
                scopes[scopeKey(target, token, false)],
                totalReserve[target][token]
            )
        );
    }

    /// @dev Controller verifies council approval of ALL source and destination holds before invoking this.
    function relocateReserve(
        address source,
        address destination,
        address token,
        bytes32 caseId,
        uint256 transferAmount,
        uint256 reserveToMove,
        uint256 sourceVersion,
        bool preserveRestriction
    ) external {
        if (msg.sender != dispositionController) revert Unauthorized();
        assertNoSecurityPause(source, token);
        assertNoSecurityPause(destination, token);
        Reserve storage sourceReserve = reserves[source][token][caseId];
        if (reserveToMove > transferAmount || reserveToMove > sourceReserve.amount) {
            revert InvalidConfiguration();
        }
        _setReserve(source, token, caseId, sourceReserve.amount - reserveToMove, sourceVersion);
        if (preserveRestriction) {
            Reserve storage targetReserve = reserves[destination][token][caseId];
            _setReserve(
                destination, token, caseId, targetReserve.amount + transferAmount, targetReserve.version
            );
            _addHold(destination, token, false, caseId);
        } else {
            assertOpen(source, token);
            assertOpen(destination, token);
        }
    }

    function _addHold(address target, address token, bool allAssets, bytes32 caseId) private {
        if (target == address(0) || caseId == bytes32(0)) revert InvalidConfiguration();
        bytes32 key = scopeKey(target, token, allAssets);
        if (holdByCase[key][caseId]) return;
        holdByCase[key][caseId] = true;
        Scope storage scope = scopes[key];
        ++scope.count;
        ++scope.epoch;
        scope.holdDigest ^= keccak256(abi.encode(caseId));
        emit HoldChanged(target, token, caseId, allAssets, true, scope.epoch);
    }

    function _setReserve(address target, address token, bytes32 caseId, uint256 amount, uint256 version)
        private
    {
        if (target == address(0) || caseId == bytes32(0)) revert InvalidConfiguration();
        Reserve storage reserve = reserves[target][token][caseId];
        if (reserve.version != version) revert StaleControl();
        if (reserve.amount == amount) return;
        totalReserve[target][token] = totalReserve[target][token] - reserve.amount + amount;
        reserve.amount = amount;
        ++reserve.version;
        ++scopes[scopeKey(target, token, false)].epoch;
        emit ReserveChanged(target, token, caseId, amount, reserve.version);
    }
}
