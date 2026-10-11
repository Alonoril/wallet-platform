// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { TenantAuthority } from "../control/TenantAuthority.sol";
import { PoolRegistry } from "../control/PoolRegistry.sol";
import { RiskRegistry } from "../control/RiskRegistry.sol";
import { PoolBase } from "../common/PoolBase.sol";
import { OperationBook } from "../common/OperationBook.sol";
import { WalletTypes } from "../common/WalletTypes.sol";
import { PermitHash } from "../common/PermitHash.sol";
import { ExactTransfer } from "../common/ExactTransfer.sol";

contract ClearingVault is PoolBase, OperationBook, EIP712 {
    struct Lot {
        address token;
        uint256 amount;
        uint256 released;
        uint256 maturity;
    }

    address public immutable manager;
    uint256 public immutable observationWindow;
    mapping(bytes32 => Lot) public lots;
    mapping(address => uint256) public outstanding;

    event LotRecorded(bytes32 indexed lotId, address indexed token, uint256 amount, uint256 maturity);
    event LotReleased(bytes32 indexed operationId, bytes32 indexed lotId, uint256 amount);
    event SettlementExecuted(
        bytes32 indexed operationId,
        address indexed token,
        address indexed destination,
        uint256 amount,
        bool migration
    );

    constructor(
        TenantAuthority authority_,
        PoolRegistry pools_,
        RiskRegistry risk_,
        address manager_,
        uint256 window_
    ) PoolBase(authority_, pools_, risk_) EIP712("Milon Clearing", "1") {
        if (manager_ == address(0) || window_ == 0) revert InvalidConfiguration();
        manager = manager_;
        observationWindow = window_;
    }

    function recordLot(bytes32 operationId, address token, uint256 amount) external {
        if (msg.sender != manager) revert Unauthorized();
        _record(operationId, token, amount, block.timestamp + observationWindow);
    }

    function hashSettlement(WalletTypes.SettlementPermit calldata p) public view returns (bytes32) {
        return _hashTypedDataV4(PermitHash.settlement(p));
    }

    function settle(
        WalletTypes.SettlementPermit calldata p,
        bytes32[] calldata lotIds,
        uint256[] calldata amounts,
        bytes calldata authorization,
        bytes calldata councilAuthorization
    ) external onlyExecutor nonReentrant {
        _validateTime(p.validAfter, p.deadline);
        _validateAsset(p.token);
        if (
            p.tenantKey != tenantKey || p.poolId != poolId || p.routeEpoch != pools.routeEpoch()
                || p.evidenceDigest == bytes32(0) || p.lotsHash != keccak256(abi.encode(lotIds, amounts))
        ) revert InvalidPermit();
        bytes32 digest = hashSettlement(p);
        authority.verify(authority.SETTLEMENT_SIGNER(), p.signerEpoch, digest, authorization);
        bool migration = pools.poolKind(p.destination) == WalletTypes.PoolKind.Clearing;
        pools.assertRoute(
            migration ? WalletTypes.RouteKind.Migration : WalletTypes.RouteKind.Settlement,
            address(this),
            p.destination
        );
        if (migration) authority.verifyCouncil(digest, councilAuthorization);
        risk.assertEpochs(address(this), p.token, p.sourceEpoch, p.sourceAssetEpoch);
        risk.assertEpochs(p.destination, p.token, p.destinationEpoch, p.destinationAssetEpoch);
        risk.assertOpen(p.destination, p.token);
        _consume(p.operationId);
        uint256 total = _releaseLots(p.operationId, p.token, lotIds, amounts, !migration);
        risk.assertSpendable(address(this), p.token, total, 0);
        ExactTransfer.send(p.token, p.destination, total);
        if (migration) {
            uint256[] memory maturities = new uint256[](lotIds.length);
            for (uint256 i; i < lotIds.length; ++i) {
                maturities[i] = lots[lotIds[i]].maturity;
            }
            ClearingVault(payable(p.destination)).importLots(
                p.operationId, p.token, lotIds, amounts, maturities
            );
        }
        emit SettlementExecuted(p.operationId, p.token, p.destination, total, migration);
    }

    /// @dev Only approved source Clearing code can call this after an atomic migration transfer.
    function importLots(
        bytes32 operationId,
        address token,
        bytes32[] calldata oldIds,
        uint256[] calldata amounts,
        uint256[] calldata maturities
    ) external nonReentrant {
        if (
            pools.poolKind(msg.sender) != WalletTypes.PoolKind.Clearing || oldIds.length == 0
                || oldIds.length > 50 || oldIds.length != amounts.length || oldIds.length != maturities.length
        ) revert Unauthorized();
        pools.assertRoute(WalletTypes.RouteKind.Migration, msg.sender, address(this));
        risk.assertOpen(msg.sender, token);
        risk.assertOpen(address(this), token);
        for (uint256 i; i < oldIds.length; ++i) {
            _record(
                keccak256(abi.encode(msg.sender, operationId, oldIds[i])), token, amounts[i], maturities[i]
            );
        }
    }

    /// @notice Legal disposition retires the exact lots it moves, so they cannot later settle twice.
    function prepareDisposition(
        bytes32 operationId,
        address token,
        bytes32[] calldata lotIds,
        uint256[] calldata amounts
    ) external nonReentrant returns (uint256) {
        if (msg.sender != dispositionController) revert Unauthorized();
        return _releaseLots(operationId, token, lotIds, amounts, false);
    }

    /// @notice Unsolicited approved-asset transfers have no lot; isolating them cannot consume recorded lots.
    function assertUnattributedDisposition(address token, uint256 amount) external view {
        if (msg.sender != dispositionController) revert Unauthorized();
        uint256 balance = ExactTransfer.balance(token, address(this));
        if (amount == 0 || balance < outstanding[token] || amount > balance - outstanding[token]) {
            revert InvalidPermit();
        }
    }

    function _record(bytes32 lotId, address token, uint256 amount, uint256 maturity) private {
        if (lotId == bytes32(0) || amount == 0 || lots[lotId].amount != 0) revert InvalidPermit();
        outstanding[token] += amount;
        if (ExactTransfer.balance(token, address(this)) < outstanding[token]) revert InvalidPermit();
        lots[lotId] = Lot(token, amount, 0, maturity);
        emit LotRecorded(lotId, token, amount, maturity);
    }

    function _releaseLots(
        bytes32 operationId,
        address token,
        bytes32[] calldata lotIds,
        uint256[] calldata amounts,
        bool requireMaturity
    ) private returns (uint256 total) {
        if (lotIds.length == 0 || lotIds.length > 50 || lotIds.length != amounts.length) {
            revert InvalidPermit();
        }
        for (uint256 i; i < lotIds.length; ++i) {
            for (uint256 j; j < i; ++j) {
                if (lotIds[i] == lotIds[j]) revert InvalidPermit();
            }
            Lot storage lot = lots[lotIds[i]];
            if (
                lot.token != token || amounts[i] == 0 || lot.amount == 0
                    || amounts[i] > lot.amount - lot.released
                    || (requireMaturity && block.timestamp < lot.maturity)
            ) revert InvalidPermit();
            lot.released += amounts[i];
            total += amounts[i];
            emit LotReleased(operationId, lotIds[i], amounts[i]);
        }
        outstanding[token] -= total;
    }
}
