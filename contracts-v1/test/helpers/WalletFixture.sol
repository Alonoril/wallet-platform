// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { TenantDeployment } from "../../script/TenantDeployment.sol";
import { WalletTypes } from "../../src/common/WalletTypes.sol";
import { TestToken, TestCouncil } from "./Mocks.sol";

abstract contract WalletFixture is Test {
    TenantDeployment.Suite internal s;
    TestToken internal token;
    TestCouncil internal council;
    address internal guardian = address(0x1001);
    address internal relayer = address(0x1002);
    address internal payee = address(0x1003);
    uint256 internal constant RISK_KEY = 0xA11CE;
    uint256 internal constant WITHDRAW_KEY = 0xB0B;
    uint256 internal constant SETTLE_KEY = 0xCAFE;
    uint256 internal constant TRANSFER_KEY = 0xBABE;
    uint256 internal constant COUNCIL_KEY = 0xD00D;
    bytes32 internal constant TENANT = keccak256("tenant-A");
    bytes32 internal constant POOL = keccak256("tenant-A-pool");
    bytes32 internal constant WALLET = keccak256("user-1");
    bytes32 internal constant CASE = keccak256("case-1");

    function setUp() public virtual {
        vm.warp(10 days);
        token = new TestToken();
        council = new TestCouncil(vm.addr(COUNCIL_KEY));
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        TenantDeployment.Configuration memory configuration = TenantDeployment.Configuration({
            tenantKey: TENANT,
            poolId: POOL,
            council: address(council),
            guardian: guardian,
            executor: relayer,
            signers: [vm.addr(RISK_KEY), vm.addr(WITHDRAW_KEY), vm.addr(SETTLE_KEY), vm.addr(TRANSFER_KEY)],
            tokens: tokens,
            version: 1,
            observationWindow: 30 minutes
        });
        uint256 nonce = vm.getNonce(address(this));
        s = TenantDeployment.deploy(
            configuration,
            vm.computeCreateAddress(address(this), nonce + 6),
            vm.computeCreateAddress(address(this), nonce + 4)
        );
        vm.startPrank(address(s.timelock));
        s.pools.registerPool(address(s.treasury), WalletTypes.PoolKind.Treasury);
        s.pools.registerPool(address(s.clearing), WalletTypes.PoolKind.Clearing);
        s.pools.registerPool(address(s.quarantine), WalletTypes.PoolKind.Quarantine);
        s.pools.registerPool(address(s.cold), WalletTypes.PoolKind.Cold);
        s.pools.setRoute(WalletTypes.RouteKind.Sweep, address(s.factory), address(s.treasury), true);
        s.pools.setRoute(WalletTypes.RouteKind.Sweep, address(s.factory), address(s.clearing), true);
        s.pools.setRoute(WalletTypes.RouteKind.Settlement, address(s.clearing), address(s.treasury), true);
        s.pools.setRoute(WalletTypes.RouteKind.Disposition, address(s.factory), address(s.quarantine), true);
        s.pools.setRoute(WalletTypes.RouteKind.Disposition, address(s.treasury), address(s.quarantine), true);
        s.pools.setRoute(WalletTypes.RouteKind.Disposition, address(s.clearing), address(s.quarantine), true);
        s.pools.setRoute(WalletTypes.RouteKind.Disposition, address(s.quarantine), address(s.treasury), true);
        s.pools.setRoute(WalletTypes.RouteKind.Disposition, address(s.cold), address(s.quarantine), true);
        s.pools.setRoute(WalletTypes.RouteKind.Rebalance, address(s.treasury), address(s.cold), true);
        s.pools.setRoute(WalletTypes.RouteKind.Rebalance, address(s.cold), address(s.treasury), true);
        WalletTypes.Limits memory limits =
            WalletTypes.Limits(1_000_000 ether, 2_000_000 ether, 2_000_000 ether, 1000 ether, 0);
        s.pools.setLimits(address(token), limits);
        s.pools.setLimits(address(0), limits);
        s.pools.setRoutesPaused(false);
        vm.stopPrank();
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 signatureS) = vm.sign(key, digest);
        return abi.encodePacked(r, signatureS, v);
    }

    function _sweepPermit(
        bytes32 walletKey,
        address asset,
        address destination,
        uint256 amount,
        bytes32 operationId
    ) internal view returns (WalletTypes.SweepPermit memory p) {
        p.operationId = operationId;
        p.tenantKey = TENANT;
        p.poolId = POOL;
        p.walletKey = walletKey;
        p.factory = address(s.factory);
        p.vault = s.factory.predictVault(walletKey);
        p.token = asset;
        p.destination = destination;
        p.amount = amount;
        p.expectedBalance = amount;
        p.riskDecisionId = keccak256("decision-1");
        p.evidenceDigest = keccak256("evidence-1");
        (p.vaultEpoch, p.vaultAssetEpoch) = s.risk.epochs(p.vault, asset);
        (p.poolEpoch, p.poolAssetEpoch) = s.risk.epochs(destination, asset);
        p.routeEpoch = s.pools.routeEpoch();
        (, p.signerEpoch) = s.authority.signers(s.authority.RISK_SIGNER());
        p.validAfter = block.timestamp;
        p.deadline = block.timestamp + 1 hours;
    }

    function _withdrawPermit(address asset, address to, uint256 amount, bytes32 requestId)
        internal
        view
        returns (WalletTypes.WithdrawalPermit memory p)
    {
        p.requestId = requestId;
        p.tenantKey = TENANT;
        p.poolId = POOL;
        p.token = asset;
        p.to = to;
        p.amount = amount;
        p.approvalDigest = keccak256("approval");
        (p.poolEpoch, p.poolAssetEpoch) = s.risk.epochs(address(s.treasury), asset);
        p.policyEpoch = s.pools.policyEpoch();
        (, p.signerEpoch) = s.authority.signers(s.authority.WITHDRAWAL_SIGNER());
        p.validAfter = block.timestamp;
        p.deadline = block.timestamp + 1 hours;
    }

    function _settlementPermit(
        address asset,
        address destination,
        bytes32[] memory ids,
        uint256[] memory amounts,
        bytes32 operationId
    ) internal view returns (WalletTypes.SettlementPermit memory p) {
        p.operationId = operationId;
        p.tenantKey = TENANT;
        p.poolId = POOL;
        p.token = asset;
        p.destination = destination;
        p.lotsHash = keccak256(abi.encode(ids, amounts));
        p.evidenceDigest = keccak256("settlement-risk");
        (p.sourceEpoch, p.sourceAssetEpoch) = s.risk.epochs(address(s.clearing), asset);
        (p.destinationEpoch, p.destinationAssetEpoch) = s.risk.epochs(destination, asset);
        p.routeEpoch = s.pools.routeEpoch();
        (, p.signerEpoch) = s.authority.signers(s.authority.SETTLEMENT_SIGNER());
        p.validAfter = block.timestamp;
        p.deadline = block.timestamp + 1 hours;
    }

    function _transferPermit(
        address asset,
        address destination,
        uint256 amount,
        WalletTypes.RouteKind kind,
        bytes32 operationId
    ) internal view returns (WalletTypes.TransferPermit memory p) {
        p.operationId = operationId;
        p.tenantKey = TENANT;
        p.poolId = POOL;
        p.kind = kind;
        p.token = asset;
        p.destination = destination;
        p.amount = amount;
        p.approvalDigest = keccak256("custody-approval");
        (p.sourceEpoch, p.sourceAssetEpoch) = s.risk.epochs(address(s.treasury), asset);
        (p.destinationEpoch, p.destinationAssetEpoch) = s.risk.epochs(destination, asset);
        p.routeEpoch = s.pools.routeEpoch();
        p.policyEpoch = s.pools.policyEpoch();
        (, p.signerEpoch) = s.authority.signers(s.authority.TRANSFER_SIGNER());
        p.validAfter = block.timestamp;
        p.deadline = block.timestamp + 1 hours;
    }

    function _dispositionPermit(
        address source,
        address asset,
        address destination,
        uint256 amount,
        uint256 reserveToMove,
        bytes32 operationId
    ) internal view returns (WalletTypes.DispositionPermit memory p) {
        p.operationId = operationId;
        p.tenantKey = TENANT;
        p.poolId = POOL;
        p.caseId = CASE;
        p.source = source;
        p.token = asset;
        p.destination = destination;
        p.amount = amount;
        p.reserveToMove = reserveToMove;
        p.evidenceDigest = keccak256("legal-disposition");
        p.sourceControlDigest = s.risk.controlDigest(source, asset);
        p.destinationControlDigest = s.risk.controlDigest(destination, asset);
        (, p.reserveVersion) = s.risk.reserves(source, asset, CASE);
        p.routeEpoch = s.pools.routeEpoch();
        p.preserveRestriction = true;
        p.validAfter = block.timestamp;
        p.deadline = block.timestamp + 1 hours;
    }

    function _sweepToClearing(uint256 amount, bytes32 operationId) internal {
        token.mint(s.factory.predictVault(WALLET), amount);
        WalletTypes.SweepPermit memory p =
            _sweepPermit(WALLET, address(token), address(s.clearing), amount, operationId);
        bytes memory signature = _sign(RISK_KEY, s.manager.hashSweep(p));
        vm.prank(relayer);
        s.manager.sweep(p, signature);
    }

    function _oneLot(bytes32 id, uint256 amount)
        internal
        pure
        returns (bytes32[] memory ids, uint256[] memory amounts)
    {
        ids = new bytes32[](1);
        amounts = new uint256[](1);
        ids[0] = id;
        amounts[0] = amount;
    }
}
