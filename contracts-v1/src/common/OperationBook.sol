// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TenantComponent } from "./TenantComponent.sol";
import { WalletTypes } from "./WalletTypes.sol";

abstract contract OperationBook is TenantComponent {
    mapping(bytes32 => WalletTypes.OperationStatus) public operationStatus;

    event OperationCancelled(bytes32 indexed operationId);

    function cancelOperation(bytes32 operationId) public {
        if (
            msg.sender != authority.guardian() && msg.sender != authority.council()
                && msg.sender != authority.governor()
        ) revert Unauthorized();
        if (operationId == bytes32(0) || operationStatus[operationId] == WalletTypes.OperationStatus.Executed)
        {
            revert OperationUnavailable();
        }
        operationStatus[operationId] = WalletTypes.OperationStatus.Cancelled;
        emit OperationCancelled(operationId);
    }

    function _consume(bytes32 operationId) internal {
        if (operationId == bytes32(0) || operationStatus[operationId] != WalletTypes.OperationStatus.Unused) {
            revert OperationUnavailable();
        }
        operationStatus[operationId] = WalletTypes.OperationStatus.Executed;
    }
}
