// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { WalletFixture } from "./helpers/WalletFixture.sol";
import { MockSigner } from "./helpers/Mocks.sol";
import { WalletTypes as T } from "../src/common/WalletTypes.sol";
import { DepositFactory } from "../src/deposit/DepositFactory.sol";
import { DepositVault } from "../src/deposit/DepositVault.sol";
import { TenantAuthority } from "../src/control/TenantAuthority.sol";

/// @notice 验证身份不可被平台单方替换、用户密钥轮换以及旧地址完整生命周期。
contract FactoryAndIdentityTest is WalletFixture {
    function testCreate2RotationRetainsIdentityAndOldVaultCanStillRefund() public {
        vm.deal(address(vault), 10 ether);
        bytes32 key = vault.walletKey();
        address predicted = factory.predictVault(key, 2);
        vm.prank(operator);
        address next = factory.rotateWallet(key, 1, CASE);
        assertEq(predicted, next);
        assertTrue(vault.sweepsDisabled());
        assertFalse(vault.retired());
        assertEq(DepositVault(payable(next)).userKey(), USER);
        assertEq(factory.userSigner(USER), vm.addr(USER_PK));
        _executeRefund(_refund(address(0), 10 ether));
        vm.prank(operator);
        factory.retireVault(address(vault), CASE);
        assertTrue(vault.retired());
    }

    function testOldUserCannotBeReboundByCreatingAnotherLogicalWallet() public {
        T.WalletBinding memory p = T.WalletBinding(
            TENANT,
            USER,
            keccak256("second wallet"),
            vm.addr(0xABCD),
            uint48(block.timestamp),
            uint48(block.timestamp + 1 hours)
        );
        bytes memory proof = _sign(0xABCD, factory.hashBinding(p));
        vm.prank(operator);
        vm.expectRevert(DepositFactory.InvalidBinding.selector);
        factory.createWallet(p, proof);
        assertEq(factory.userSigner(USER), vm.addr(USER_PK));
    }

    function testRotationNeedsOldUserNewUserAndPlatformAuthorization() public {
        T.UserSignerRotation memory p = _rotation();
        bytes32 digest = factory.hashUserRotation(p);
        bytes memory newProof = _sign(0xABCD, digest);
        bytes memory platformProof = _sign(REFUND_PK, digest);
        vm.expectRevert(DepositFactory.InvalidRotation.selector);
        factory.rotateUserSigner(p, "", newProof, platformProof);
        bytes memory oldProof = _sign(USER_PK, digest);
        vm.expectRevert(TenantAuthority.InvalidSignature.selector);
        factory.rotateUserSigner(p, oldProof, newProof, "");
        factory.rotateUserSigner(p, oldProof, newProof, platformProof);
        assertEq(factory.userSigner(USER), vm.addr(0xABCD));
        assertEq(factory.userSignerEpoch(USER), 2);
        vm.expectRevert(DepositFactory.InvalidRotation.selector);
        factory.rotateUserSigner(p, oldProof, newProof, platformProof);
    }

    function testUserSignerRotationInvalidatesPreviouslySignedRefunds() public {
        vm.deal(address(vault), 10 ether);
        T.RefundPermit memory refundPermit = _refund(address(0), 1 ether);
        (bytes memory userSignature, bytes memory platformSignature) = _refundSignatures(refundPermit);
        T.UserSignerRotation memory rotation = _rotation();
        bytes32 digest = factory.hashUserRotation(rotation);
        factory.rotateUserSigner(
            rotation, _sign(USER_PK, digest), _sign(0xABCD, digest), _sign(REFUND_PK, digest)
        );
        vm.expectRevert(DepositVault.InvalidRefund.selector);
        vault.withdraw(refundPermit, userSignature, platformSignature);
        refundPermit = _refund(address(0), 1 ether);
        digest = vault.hashRefund(refundPermit);
        vault.withdraw(refundPermit, _sign(0xABCD, digest), _sign(REFUND_PK, digest));
        assertEq(recipient.balance, 1 ether);
    }

    function testUserSmartAccountSupportsERC1271() public {
        MockSigner smartUser = new MockSigner(vm.addr(USER_PK));
        vault = _createWallet(keccak256("smart user"), keccak256("smart wallet"), USER_PK, address(smartUser));
        vm.deal(address(vault), 10 ether);
        _executeRefund(_refund(address(0), 2 ether));
        assertEq(recipient.balance, 2 ether);
    }

    function testPlatformAndUserCannotCollapseIntoSameSigner() public {
        _govern(
            address(authority),
            abi.encodeCall(authority.setSigner, (authority.REFUND_SIGNER(), vm.addr(USER_PK), 1))
        );
        vm.deal(address(vault), 10 ether);
        T.RefundPermit memory p = _refund(address(0), 1 ether);
        bytes memory signature = _sign(USER_PK, vault.hashRefund(p));
        vm.expectRevert(DepositVault.InvalidUserSignature.selector);
        vault.withdraw(p, signature, signature);
    }

    function testNormalRetirementRejectsResidualBalances() public {
        bytes32 key = vault.walletKey();
        vm.prank(operator);
        factory.rotateWallet(key, 1, CASE);
        token.mint(address(vault), 10e6);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DepositFactory.ResidualBalance.selector, address(token), 10e6));
        factory.retireVault(address(vault), CASE);
        assertFalse(vault.retired());
    }

    function testResidualRetirementAndLateFundsRequireGovernedDisposition() public {
        bytes32 key = vault.walletKey();
        vm.prank(operator);
        factory.rotateWallet(key, 1, CASE);
        vm.deal(address(vault), 2 ether);
        _govern(address(factory), abi.encodeCall(factory.retireWithResidual, (address(vault), CASE)));
        T.RefundPermit memory p = _refund(address(0), 1 ether);
        (bytes memory userProof, bytes memory platformProof) = _refundSignatures(p);
        vm.expectRevert(DepositVault.VaultRetired.selector);
        vault.withdraw(p, userProof, platformProof);
        address disposal = makeAddr("quarantine receiver");
        _govern(address(authority), abi.encodeCall(authority.setDispositionReceiver, (disposal)));
        _govern(
            address(vault),
            abi.encodeCall(vault.disposeRetired, (address(0), 2 ether, keccak256("disposal"), CASE))
        );
        assertEq(disposal.balance, 2 ether);
        assertEq(address(hot).balance, 0);
    }

    function testCannotRetireCurrentRouteOrInitializeCloneTwice() public {
        vm.prank(operator);
        vm.expectRevert(DepositFactory.InvalidRetirement.selector);
        factory.retireVault(address(vault), CASE);
        vm.prank(address(factory));
        vm.expectRevert(DepositVault.InvalidInitialization.selector);
        vault.initialize(keccak256("replacement"), USER, 2);
    }

    function _rotation() private view returns (T.UserSignerRotation memory) {
        return T.UserSignerRotation(
            TENANT,
            USER,
            vm.addr(USER_PK),
            vm.addr(0xABCD),
            factory.userSignerEpoch(USER),
            authority.signerEpoch(authority.REFUND_SIGNER()),
            uint48(block.timestamp),
            uint48(block.timestamp + 1 hours)
        );
    }
}
