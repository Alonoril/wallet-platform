// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { TreasuryVault } from "../../src/pools/TreasuryVault.sol";
import { RiskRegistry } from "../../src/control/RiskRegistry.sol";
import { PoolRegistry } from "../../src/control/PoolRegistry.sol";
import { WalletTypes } from "../../src/common/WalletTypes.sol";
import { TestToken } from "./Mocks.sol";

/// @dev Fuzz-only handler. The fixed key is synthetic and never belongs to a deployed production wallet.
contract WalletHandler is Test {
    TreasuryVault public treasury;
    RiskRegistry public risk;
    PoolRegistry public pools;
    TestToken public token;
    address public guardian;
    address public relayer;
    address public council;
    address public constant RECIPIENT = address(0xBEEF);
    uint256 public minted;
    uint256 public paid;
    bool public violatedHold;
    bool public violatedFloor;
    bool public violatedAtomicity;
    mapping(bytes32 => uint256) public successfulPayments;

    constructor(
        TreasuryVault treasury_,
        RiskRegistry risk_,
        PoolRegistry pools_,
        TestToken token_,
        address guardian_,
        address relayer_,
        address council_
    ) {
        treasury = treasury_;
        risk = risk_;
        pools = pools_;
        token = token_;
        guardian = guardian_;
        relayer = relayer_;
        council = council_;
    }

    function fund(uint96 raw) external {
        uint256 amount = bound(raw, 1, 1e12);
        token.mint(address(treasury), amount);
        minted += amount;
    }

    function changeHold(uint8 selector, bool enabled) external {
        bytes32 caseId = bytes32(uint256(selector % 2 + 1));
        bool active = risk.holdByCase(risk.scopeKey(address(treasury), address(token), false), caseId);
        if (enabled) {
            vm.prank(guardian);
            risk.addHold(address(treasury), address(token), false, caseId);
        } else if (active) {
            vm.prank(council);
            risk.releaseHold(address(treasury), address(token), false, caseId);
        }
    }

    function changeReserve(uint8 selector, uint96 raw) external {
        bytes32 caseId = bytes32(uint256(selector % 2 + 1));
        (uint256 oldAmount, uint256 version) = risk.reserves(address(treasury), address(token), caseId);
        uint256 amount = bound(raw, 0, token.balanceOf(address(treasury)) + 1e12);
        vm.prank(amount >= oldAmount ? guardian : council);
        risk.setReserve(address(treasury), address(token), caseId, amount, version);
    }

    function cancel(uint8 slot) external {
        vm.prank(guardian);
        (bool success,) = address(treasury).call(abi.encodeCall(treasury.cancelWithdrawal, (_request(slot))));
        if (!success) assertEq(uint256(treasury.requestStatus(_request(slot))), 1);
    }

    function withdraw(uint8 slot, uint96 raw) external {
        WalletTypes.WithdrawalPermit memory p;
        p.requestId = _request(slot);
        p.tenantKey = treasury.tenantKey();
        p.poolId = treasury.poolId();
        p.token = address(token);
        p.to = RECIPIENT;
        p.amount = bound(raw, 1, 1e12);
        p.approvalDigest = keccak256("fuzz-ledger-approval");
        (p.poolEpoch, p.poolAssetEpoch) = risk.epochs(address(treasury), p.token);
        p.policyEpoch = pools.policyEpoch();
        (, p.signerEpoch) = treasury.authority().signers(treasury.authority().WITHDRAWAL_SIGNER());
        p.validAfter = block.timestamp;
        p.deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 signatureS) = vm.sign(0xB0B, treasury.hashWithdrawal(p));
        uint256 beforeBalance = token.balanceOf(address(treasury));
        uint256 reserve = risk.totalReserve(address(treasury), p.token);
        (,, bool held) = _controlState();
        uint256 beforeBudget = pools.dailySpent(p.token, block.timestamp / 1 days);
        vm.prank(relayer);
        (bool success,) = address(treasury).call(
            abi.encodeCall(treasury.executeWithdrawal, (p, abi.encodePacked(r, signatureS, v), bytes("")))
        );
        if (success) {
            ++successfulPayments[p.requestId];
            paid += p.amount;
            if (held) violatedHold = true;
            if (token.balanceOf(address(treasury)) < reserve + pools.safetyFloor(p.token)) {
                violatedFloor = true;
            }
        } else if (
            token.balanceOf(address(treasury)) != beforeBalance
                || pools.dailySpent(p.token, block.timestamp / 1 days) != beforeBudget
        ) {
            violatedAtomicity = true;
        }
    }

    function advanceTime(uint32 raw) external {
        vm.warp(block.timestamp + bound(raw, 0, 25 hours));
    }

    function request(uint8 slot) external pure returns (bytes32) {
        return _request(slot);
    }

    function _request(uint8 slot) private pure returns (bytes32) {
        return keccak256(abi.encode("fuzz-request", slot % 8));
    }

    function _controlState() private view returns (uint256 globalCount, uint256 assetCount, bool held) {
        bool globalPause;
        bool assetPause;
        (, globalCount,, globalPause) = risk.scopes(risk.scopeKey(address(treasury), address(token), true));
        (, assetCount,, assetPause) = risk.scopes(risk.scopeKey(address(treasury), address(token), false));
        held = globalCount != 0 || assetCount != 0 || globalPause || assetPause;
    }
}
