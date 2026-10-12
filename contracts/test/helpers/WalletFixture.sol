// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { TenantTimelock } from "../../src/control/TenantTimelock.sol";
import { TenantAuthority } from "../../src/control/TenantAuthority.sol";
import { RiskRegistry } from "../../src/control/RiskRegistry.sol";
import { MilonWithdrawalVerifier } from "../../src/bridge/MilonWithdrawalVerifier.sol";
import { WithdrawalBook } from "../../src/bridge/WithdrawalBook.sol";
import { HotPoolManager } from "../../src/pools/HotPoolManager.sol";
import { HotVault } from "../../src/pools/HotVault.sol";
import { DepositFactory } from "../../src/deposit/DepositFactory.sol";
import { DepositVault } from "../../src/deposit/DepositVault.sol";
import { IHotPoolManager } from "../../src/common/IWallet.sol";
import { WalletTypes as T } from "../../src/common/WalletTypes.sol";
import { ExactTransfer } from "../../src/common/ExactTransfer.sol";
import { MockToken, MockSigner } from "./Mocks.sol";

/// @notice 全部测试使用的独立 v2 租户与合成签名密钥；setup 的治理模拟不替代专门的 timelock 测试。
abstract contract WalletFixture is Test {
    uint256 internal constant USER_PK = 0x10001;
    uint256 internal constant REFUND_PK = 0x20001;
    uint256 internal constant SWEEP_PK = 0x30001;
    uint256 internal constant TRANSFER_PK = 0x40001;
    uint256 internal constant COUNCIL_PK = 0x50001;
    bytes32 internal constant TENANT = keccak256("test tenant");
    bytes32 internal constant CHAIN = keccak256("test EVM chain");
    bytes32 internal constant USER = keccak256("test user");
    bytes32 internal constant CASE = keccak256("test risk case");
    address internal relayer;
    address internal operator;
    address internal guardian;
    address internal cold;
    address internal recipient;
    TenantTimelock internal timelock;
    MockSigner internal council;
    TenantAuthority internal authority;
    RiskRegistry internal risks;
    MilonWithdrawalVerifier internal verifier;
    WithdrawalBook internal book;
    HotPoolManager internal manager;
    DepositFactory internal factory;
    DepositVault internal vault;
    HotVault internal hot;
    MockToken internal token;
    uint256[4] internal committeeKeys;
    uint256 internal sequence;

    function setUp() public virtual {
        vm.warp(10 days);
        vm.chainId(31337);
        relayer = makeAddr("relayer");
        operator = makeAddr("operator");
        guardian = makeAddr("guardian");
        cold = makeAddr("offline cold");
        recipient = makeAddr("recipient");
        council = new MockSigner(vm.addr(COUNCIL_PK));
        timelock = new TenantTimelock(2 days, address(council));
        authority = new TenantAuthority(TENANT, CHAIN, address(timelock), guardian, address(this), 30 minutes);
        risks = new RiskRegistry(authority);
        verifier =
            new MilonWithdrawalVerifier(authority, keccak256("bridge"), 567, keccak256("Milon genesis"), 42);
        book = new WithdrawalBook(authority, verifier);
        manager = new HotPoolManager(authority, risks, book, verifier, 20);
        factory = new DepositFactory(authority, risks, IHotPoolManager(address(manager)));
        authority.bindSuite(address(factory), address(manager), address(verifier), address(book));
        _govern(
            address(authority),
            abi.encodeCall(authority.setSigner, (authority.REFUND_SIGNER(), vm.addr(REFUND_PK), 0))
        );
        _govern(
            address(authority),
            abi.encodeCall(authority.setSigner, (authority.SWEEP_SIGNER(), vm.addr(SWEEP_PK), 0))
        );
        _govern(
            address(authority),
            abi.encodeCall(authority.setSigner, (authority.TRANSFER_SIGNER(), vm.addr(TRANSFER_PK), 0))
        );
        _govern(
            address(authority),
            abi.encodeCall(authority.setSigner, (authority.COUNCIL_SIGNER(), address(council), 0))
        );
        _govern(address(authority), abi.encodeCall(authority.setPermission, (relayer, 0, true)));
        _govern(address(authority), abi.encodeCall(authority.setPermission, (operator, 1, true)));
        _installCommittee();
        token = new MockToken();
        _configureAsset(address(0), 18, 100 ether, 50 ether);
        _configureAsset(address(token), 6, 1_000_000e6, 500_000e6);
        _govern(address(manager), abi.encodeCall(manager.setColdAddress, (cold, 0)));
        _govern(address(manager), abi.encodeCall(manager.publishMapping, (keccak256("approved mapping"), 1)));
        _govern(
            address(authority),
            abi.encodeCall(authority.setPaused, (false, false, authority.authorityEpoch()))
        );
        _govern(address(verifier), abi.encodeCall(verifier.setPaused, (false, verifier.bridgeEpoch())));
        vault = _createWallet(USER, keccak256("wallet"), USER_PK, vm.addr(USER_PK));
        hot = _createHot();
    }

    function _installCommittee() internal {
        for (uint256 i; i < 4; ++i) {
            committeeKeys[i] = 0x60001 + i;
        }
        for (uint256 i; i < 4; ++i) {
            for (uint256 j = i + 1; j < 4; ++j) {
                if (vm.addr(committeeKeys[j]) < vm.addr(committeeKeys[i])) {
                    (committeeKeys[i], committeeKeys[j]) = (committeeKeys[j], committeeKeys[i]);
                }
            }
        }
        address[] memory members = new address[](4);
        for (uint256 i; i < 4; ++i) {
            members[i] = vm.addr(committeeKeys[i]);
        }
        _govern(
            address(verifier),
            abi.encodeCall(
                verifier.installCommittee, (keccak256("committee"), members, 3, verifier.committeeEpoch())
            )
        );
    }

    function _configureAsset(address asset, uint8 decimals, uint256 cap, uint256 councilThreshold) internal {
        _govern(address(manager), abi.encodeCall(manager.registerAsset, (asset, decimals)));
        _govern(address(manager), abi.encodeCall(manager.setAssetCap, (asset, cap, true, 0)));
        T.OutflowPolicy memory policy =
            T.OutflowPolicy(cap, cap * 10, cap * 10, 0, councilThreshold, 0, true, true);
        _govern(address(manager), abi.encodeCall(manager.setOutflowPolicy, (asset, policy, 0)));
    }

    function _createWallet(bytes32 user, bytes32 logical, uint256 signerKey, address signer)
        internal
        returns (DepositVault)
    {
        T.WalletBinding memory binding = T.WalletBinding(
            TENANT, user, logical, signer, uint48(block.timestamp), uint48(block.timestamp + 1 hours)
        );
        bytes memory authorization = _sign(signerKey, factory.hashBinding(binding));
        vm.prank(operator);
        return DepositVault(payable(factory.createWallet(binding, authorization)));
    }

    function _createHot() internal returns (HotVault) {
        vm.prank(relayer);
        return HotVault(payable(manager.createHotVault()));
    }

    function _govern(address target, bytes memory payload) internal {
        vm.prank(address(timelock));
        (bool ok, bytes memory reason) = target.call(payload);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _refund(address asset, uint256 amount) internal view returns (T.RefundPermit memory p) {
        p.tenantKey = TENANT;
        p.userKey = vault.userKey();
        p.walletKey = vault.walletKey();
        p.assetKey = manager.assetConfig(asset).assetKey;
        p.token = asset;
        p.recipient = recipient;
        p.amount = amount;
        p.assetStateNonce = vault.assetStateNonce(asset);
        p.userSignerEpoch = factory.userSignerEpoch(p.userKey);
        p.refundSignerEpoch = authority.signerEpoch(authority.REFUND_SIGNER());
        p.validAfter = uint48(block.timestamp);
        p.deadline = uint48(block.timestamp + 1 hours);
    }

    function _refundSignatures(T.RefundPermit memory p) internal view returns (bytes memory, bytes memory) {
        bytes32 digest = vault.hashRefund(p);
        return (_sign(USER_PK, digest), _sign(REFUND_PK, digest));
    }

    function _executeRefund(T.RefundPermit memory p) internal {
        (bytes memory userSignature, bytes memory platformSignature) = _refundSignatures(p);
        vault.withdraw(p, userSignature, platformSignature);
    }

    function _sweep(address asset, uint256 amount)
        internal
        returns (T.SweepPermit memory p, T.SourceAllocation[] memory allocations)
    {
        allocations = new T.SourceAllocation[](1);
        allocations[0] = T.SourceAllocation(
            keccak256(abi.encode(++sequence)),
            amount,
            uint48(block.timestamp - authority.observationWindow()),
            0
        );
        p.operationId = keccak256(abi.encode("sweep", sequence));
        p.tenantKey = TENANT;
        p.walletKey = vault.walletKey();
        p.assetKey = manager.assetConfig(asset).assetKey;
        p.token = asset;
        p.hotVault = address(hot);
        p.amount = amount;
        p.expectedBalance = ExactTransfer.balance(asset, address(vault));
        p.assetStateNonce = vault.assetStateNonce(asset);
        p.allocationsHash = vault.hashAllocations(allocations);
        p.mappingEpoch = manager.mappingEpoch();
        p.assetEpoch = manager.assetConfig(asset).assetEpoch;
        p.capVersion = manager.assetCap(asset).capVersion;
        p.vaultEpoch = _riskEpoch(risks.vaultScope(address(vault)));
        p.vaultAssetEpoch = _riskEpoch(risks.assetScope(address(vault), asset));
        p.userRiskEpoch = _riskEpoch(risks.userScope(vault.userKey()));
        p.hotEpoch = _riskEpoch(risks.vaultScope(address(hot)));
        p.hotAssetEpoch = _riskEpoch(risks.assetScope(address(hot), asset));
        p.policyEpoch = manager.outflowPolicy(asset).policyEpoch;
        p.authorityEpoch = authority.authorityEpoch();
        p.sweepSignerEpoch = authority.signerEpoch(authority.SWEEP_SIGNER());
        p.validAfter = uint48(block.timestamp);
        p.deadline = uint48(block.timestamp + 1 hours);
    }

    function _executeSweep(T.SweepPermit memory p, T.SourceAllocation[] memory allocations) internal {
        bytes memory signature = _sign(SWEEP_PK, vault.hashSweep(p));
        vm.prank(relayer);
        vault.sweep(p, allocations, signature);
    }

    function _withdrawal(HotVault payer, address asset, uint256 amount, bytes32 requestId)
        internal
        view
        returns (T.WithdrawalPermit memory p)
    {
        p.requestId = requestId;
        p.tenantKey = TENANT;
        p.userKey = USER;
        p.assetKey = manager.assetConfig(asset).assetKey;
        p.poolId = payer.poolId();
        p.token = asset;
        p.to = recipient;
        p.amount = amount;
        p.approvalDigest = keccak256("approved user authorization and reservation");
        p.mappingEpoch = manager.mappingEpoch();
        p.assetEpoch = manager.assetConfig(asset).assetEpoch;
        p.poolEpoch = _riskEpoch(risks.vaultScope(address(payer)));
        p.poolAssetEpoch = _riskEpoch(risks.assetScope(address(payer), asset));
        p.userRiskEpoch = _riskEpoch(risks.userScope(USER));
        p.recipientRiskEpoch = _riskEpoch(risks.recipientScope(recipient));
        p.policyEpoch = manager.outflowPolicy(asset).policyEpoch;
        p.authorityEpoch = authority.authorityEpoch();
        p.signerEpoch = authority.withdrawalSignerEpoch();
        p.validAfter = uint48(block.timestamp);
        p.deadline = uint48(block.timestamp + 1 hours);
    }

    function _attestation(bytes32 digest) internal view returns (T.WithdrawalAttestation memory) {
        return T.WithdrawalAttestation(
            digest,
            verifier.sourceChainId(),
            verifier.sourceGenesisHash(),
            verifier.withdrawalAppId(),
            verifier.committeeId(),
            verifier.committeeEpoch(),
            100,
            keccak256("approved block"),
            keccak256("approved tx"),
            verifier.bridgeEpoch(),
            1
        );
    }

    function _certificate(HotVault payer, T.WithdrawalPermit memory p) internal view returns (bytes memory) {
        T.WithdrawalAttestation memory a = _attestation(payer.hashWithdrawal(p));
        return abi.encode(a, _committeeSign(verifier.hashAttestation(a)));
    }

    function _committeeSign(bytes32 digest) internal view returns (bytes[] memory signatures) {
        signatures = new bytes[](3);
        for (uint256 i; i < 3; ++i) {
            signatures[i] = _sign(committeeKeys[i], digest);
        }
    }

    function _executeWithdrawal(HotVault payer, T.WithdrawalPermit memory p) internal {
        bytes memory certificate = _certificate(payer, p);
        bytes memory councilSignature = _sign(COUNCIL_PK, payer.hashWithdrawal(p));
        vm.prank(relayer);
        payer.executeWithdrawal(p, certificate, councilSignature);
    }

    function _cancelPermit(bytes32 requestId) internal view returns (T.CancelPermit memory) {
        return T.CancelPermit(
            requestId,
            TENANT,
            keccak256("cancel context"),
            authority.withdrawalSignerEpoch(),
            uint48(block.timestamp),
            uint48(block.timestamp + 1 hours)
        );
    }

    function _cancelCertificate(T.CancelPermit memory p) internal view returns (bytes memory) {
        T.CancellationAttestation memory a = T.CancellationAttestation(
            book.hashCancel(p),
            verifier.sourceChainId(),
            verifier.sourceGenesisHash(),
            verifier.withdrawalAppId(),
            verifier.committeeId(),
            verifier.committeeEpoch(),
            100,
            keccak256("cancel block"),
            keccak256("cancel tx"),
            verifier.bridgeEpoch(),
            2
        );
        return abi.encode(a, _committeeSign(verifier.hashCancellation(a)));
    }

    function _movement(HotVault source, address asset, address destination, uint256 amount)
        internal
        returns (T.MovementPermit memory p)
    {
        p.operationId = keccak256(abi.encode("movement", ++sequence));
        p.tenantKey = TENANT;
        p.assetKey = manager.assetConfig(asset).assetKey;
        p.token = asset;
        p.destination = destination;
        p.amount = amount;
        p.expectedBalance = ExactTransfer.balance(asset, address(source));
        p.assetStateNonce = source.assetStateNonce(asset);
        p.mappingEpoch = manager.mappingEpoch();
        p.assetEpoch = manager.assetConfig(asset).assetEpoch;
        p.capVersion = manager.assetCap(asset).capVersion;
        p.sourceEpoch = _riskEpoch(risks.vaultScope(address(source)));
        p.sourceAssetEpoch = _riskEpoch(risks.assetScope(address(source), asset));
        p.destinationEpoch = _riskEpoch(risks.vaultScope(destination));
        p.destinationAssetEpoch = _riskEpoch(risks.assetScope(destination, asset));
        p.destinationRecipientEpoch = _riskEpoch(risks.recipientScope(destination));
        p.policyEpoch = manager.outflowPolicy(asset).policyEpoch;
        p.authorityEpoch = authority.authorityEpoch();
        p.transferSignerEpoch = authority.signerEpoch(authority.TRANSFER_SIGNER());
        p.validAfter = uint48(block.timestamp);
        p.deadline = uint48(block.timestamp + 1 hours);
    }

    function _riskEpoch(bytes32 scope) internal view returns (uint64) {
        return risks.state(scope).epoch;
    }

    function _restrict(bytes32 scope) internal {
        uint64 epoch = _riskEpoch(scope);
        vm.prank(guardian);
        risks.restrict(scope, 0, epoch, CASE);
    }
}
