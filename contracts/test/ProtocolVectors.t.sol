// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { WalletTypes as T } from "../src/common/WalletTypes.sol";
import { PermitHash } from "../src/common/PermitHash.sol";

/// @notice 暴露正文哈希用于跨语言黄金向量验证，避免测试把同一 Solidity 实现当作预期值。
contract ProtocolHashHarness {
    function refund(T.RefundPermit calldata p) external pure returns (bytes32) {
        return PermitHash.refund(p);
    }

    function sweep(T.SweepPermit calldata p) external pure returns (bytes32) {
        return PermitHash.sweep(p);
    }

    function withdrawal(T.WithdrawalPermit calldata p) external pure returns (bytes32) {
        return PermitHash.withdrawal(p);
    }

    function movement(T.MovementPermit calldata p) external pure returns (bytes32) {
        return PermitHash.movement(p);
    }

    function binding(T.WalletBinding calldata p) external pure returns (bytes32) {
        return PermitHash.walletBinding(p);
    }

    function rotation(T.UserSignerRotation calldata p) external pure returns (bytes32) {
        return PermitHash.userRotation(p);
    }

    function cancel(T.CancelPermit calldata p) external pure returns (bytes32) {
        return PermitHash.cancel(p);
    }

    function attestation(T.WithdrawalAttestation calldata p) external pure returns (bytes32) {
        return PermitHash.attestation(p);
    }

    function cancelAttestation(T.CancellationAttestation calldata p) external pure returns (bytes32) {
        return PermitHash.cancellationAttestation(p);
    }
}

/// @notice 外部 Python 静态 ABI 编码和 cast Keccak 输出必须与 Solidity 的实际 tuple 编码一致。
contract ProtocolVectorsTest is Test {
    ProtocolHashHarness private harness;
    string private vectors;

    function setUp() public {
        harness = new ProtocolHashHarness();
        vectors = vm.readFile(string.concat(vm.projectRoot(), "/interfaces/vectors.json"));
    }

    function testRefundAndBindingVectors() public view {
        _check("RefundPermit", harness.refund.selector);
        _check("WalletBinding", harness.binding.selector);
        _check("UserSignerRotation", harness.rotation.selector);
    }

    function testSweepAndMovementVectors() public view {
        _check("SweepPermit", harness.sweep.selector);
        _check("MovementPermit", harness.movement.selector);
    }

    function testWithdrawalAndCancellationVectors() public view {
        _check("WithdrawalPermit", harness.withdrawal.selector);
        _check("CancelPermit", harness.cancel.selector);
        _check("WithdrawalAttestation", harness.attestation.selector);
        _check("CancellationAttestation", harness.cancelAttestation.selector);
    }

    function _check(string memory primary, bytes4 selector) private view {
        string memory path = string.concat(".", primary);
        bytes memory encoded = vm.parseJsonBytes(vectors, string.concat(path, ".encodedValue"));
        (bool ok, bytes memory result) = address(harness).staticcall(abi.encodePacked(selector, encoded));
        assertTrue(ok);
        bytes32 structHash = abi.decode(result, (bytes32));
        assertEq(structHash, vm.parseJsonBytes32(vectors, string.concat(path, ".structHash")));
        string memory name = vm.parseJsonString(vectors, string.concat(path, ".domain.name"));
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(name)),
                keccak256("2"),
                uint256(31337),
                address(0x1111111111111111111111111111111111111111)
            )
        );
        assertEq(domainSeparator, vm.parseJsonBytes32(vectors, string.concat(path, ".domainSeparator")));
        assertEq(
            keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash)),
            vm.parseJsonBytes32(vectors, string.concat(path, ".digest"))
        );
    }
}
