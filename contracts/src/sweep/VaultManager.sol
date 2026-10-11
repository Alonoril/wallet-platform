// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { TenantAuthority } from "../control/TenantAuthority.sol";
import { RiskRegistry } from "../control/RiskRegistry.sol";
import { PoolRegistry } from "../control/PoolRegistry.sol";
import { TenantComponent } from "../common/TenantComponent.sol";
import { OperationBook } from "../common/OperationBook.sol";
import { WalletTypes } from "../common/WalletTypes.sol";
import { PermitHash } from "../common/PermitHash.sol";
import { ExactTransfer } from "../common/ExactTransfer.sol";
import { BoundedCall } from "../common/BoundedCall.sol";
import { VaultFactory } from "../deposit/VaultFactory.sol";
import { DepositVault } from "../deposit/DepositVault.sol";

interface IClearingRecorder {
    function recordLot(bytes32 operationId, address token, uint256 amount) external;
}

contract VaultManager is OperationBook, EIP712, ReentrancyGuard {
    uint256 public constant MAX_BATCH_ITEMS = 50;
    uint256 public constant MAX_ITEM_GAS = 2_000_000;
    VaultFactory public immutable factory;
    RiskRegistry public immutable risk;
    PoolRegistry public immutable pools;
    bytes32 public immutable poolId;

    event SweepExecuted(
        bytes32 indexed operationId,
        address indexed vault,
        address indexed token,
        address destination,
        uint256 amount,
        bytes32 riskDecisionId
    );
    event ItemFailed(bytes32 indexed operationId, uint256 index, bytes32 errorDigest);
    event BatchStopped(uint256 firstUnexecuted);

    constructor(TenantAuthority authority_, VaultFactory factory_, RiskRegistry risk_, PoolRegistry pools_)
        TenantComponent(authority_)
        EIP712("Milon Sweep", "1")
    {
        if (
            pools_.factory() != address(factory_) || address(risk_.authority()) != address(authority_)
                || address(pools_.authority()) != address(authority_)
        ) revert InvalidConfiguration();
        factory = factory_;
        risk = risk_;
        pools = pools_;
        poolId = pools_.poolId();
    }

    function hashSweep(WalletTypes.SweepPermit calldata permit) public view returns (bytes32) {
        return _hashTypedDataV4(PermitHash.sweep(permit));
    }

    function sweep(WalletTypes.SweepPermit calldata permit, bytes calldata signature)
        external
        onlyExecutor
        nonReentrant
    {
        _sweep(permit, signature);
    }

    function deployVault(bytes32 walletKey) external onlyExecutor nonReentrant returns (address) {
        return factory.deployVault(walletKey); // No transfer and no risk authorization bypass.
    }

    function batchDeployAndSweep(
        WalletTypes.SweepPermit[] calldata permits,
        bytes[] calldata signatures,
        uint256[] calldata gasCaps
    ) external onlyExecutor nonReentrant {
        uint256 length = permits.length;
        if (
            length == 0 || length > MAX_BATCH_ITEMS || length != signatures.length || length != gasCaps.length
                || msg.data.length > 131_072
        ) revert InvalidConfiguration();
        // Bound CPU/calldata and reject duplicate task IDs before any effect.
        for (uint256 i; i < length; ++i) {
            if (gasCaps[i] < 100_000 || gasCaps[i] > MAX_ITEM_GAS || signatures[i].length > 4096) {
                revert InvalidConfiguration();
            }
            for (uint256 j; j < i; ++j) {
                if (permits[i].operationId == permits[j].operationId) revert InvalidConfiguration();
            }
        }
        for (uint256 i; i < length; ++i) {
            // EIP-150 forwarding slack plus bounded event/loop costs after each item.
            if (gasleft() < gasCaps[i] + gasCaps[i] / 63 + 60_000) {
                emit BatchStopped(i);
                break;
            }
            (bool success, bytes32 reason) = BoundedCall.invoke(
                address(this), abi.encodeCall(this.executeSweepItem, (permits[i], signatures[i])), gasCaps[i]
            );
            if (!success) emit ItemFailed(permits[i].operationId, i, reason);
        }
    }

    /// @dev Only self-call; deliberately does not enter the outer batch's reentrancy lock again.
    function executeSweepItem(WalletTypes.SweepPermit calldata permit, bytes calldata signature) external {
        if (msg.sender != address(this)) revert Unauthorized();
        _sweep(permit, signature);
    }

    function _sweep(WalletTypes.SweepPermit calldata p, bytes calldata signature) private {
        _validateTime(p.validAfter, p.deadline);
        _validateAsset(p.token);
        if (
            p.tenantKey != tenantKey || p.poolId != poolId || p.factory != address(factory)
                || p.vault != factory.predictVault(p.walletKey) || p.amount == 0 || p.amount != p.expectedBalance
                || p.routeEpoch != pools.routeEpoch() || p.riskDecisionId == bytes32(0)
                || p.evidenceDigest == bytes32(0)
        ) revert InvalidPermit();
        authority.verify(authority.RISK_SIGNER(), p.signerEpoch, hashSweep(p), signature);
        risk.assertEpochs(p.vault, p.token, p.vaultEpoch, p.vaultAssetEpoch);
        risk.assertEpochs(p.destination, p.token, p.poolEpoch, p.poolAssetEpoch);
        risk.assertOpen(p.vault, p.token);
        risk.assertOpen(p.destination, p.token);
        pools.assertRoute(WalletTypes.RouteKind.Sweep, address(factory), p.destination);
        if (ExactTransfer.balance(p.token, p.vault) != p.expectedBalance) revert InvalidPermit();
        _consume(p.operationId);
        address vault = factory.deployVault(p.walletKey);
        DepositVault(payable(vault)).sweep(p.token, p.destination, p.amount);
        if (pools.poolKind(p.destination) == WalletTypes.PoolKind.Clearing) {
            IClearingRecorder(p.destination).recordLot(p.operationId, p.token, p.amount);
        }
        emit SweepExecuted(p.operationId, vault, p.token, p.destination, p.amount, p.riskDecisionId);
    }
}
