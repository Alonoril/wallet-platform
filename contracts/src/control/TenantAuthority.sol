// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @notice Governance is a timelock; council MUST be an independently operated ERC-1271 multisig.
contract TenantAuthority {
    bytes32 public constant RISK_SIGNER = keccak256("RISK_SIGNER");
    bytes32 public constant WITHDRAWAL_SIGNER = keccak256("WITHDRAWAL_SIGNER");
    bytes32 public constant SETTLEMENT_SIGNER = keccak256("SETTLEMENT_SIGNER");
    bytes32 public constant TRANSFER_SIGNER = keccak256("TRANSFER_SIGNER");
    uint256 public constant MIN_GOVERNANCE_DELAY = 2 days;

    struct Signer {
        address account;
        uint256 epoch;
    }

    bytes32 public immutable tenantKey;
    address public immutable governor;
    address public immutable council;
    address public immutable guardian;
    mapping(bytes32 => Signer) public signers;
    mapping(address => bool) public executors;
    mapping(address => bool) public assets;

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidAuthorization();

    event SignerChanged(bytes32 indexed purpose, address indexed account, uint256 epoch);
    event ExecutorChanged(address indexed executor, bool enabled);
    event AssetChanged(address indexed token, bool enabled);

    constructor(
        bytes32 tenant_,
        address governor_,
        address council_,
        address guardian_,
        address executor_,
        address[4] memory signers_,
        address[] memory tokens_
    ) {
        if (
            tenant_ == bytes32(0) || governor_.code.length == 0 || council_.code.length == 0
                || guardian_ == address(0) || executor_ == address(0)
                || TimelockController(payable(governor_)).getMinDelay() < MIN_GOVERNANCE_DELAY
        ) {
            revert InvalidConfiguration();
        }
        tenantKey = tenant_;
        governor = governor_;
        council = council_;
        guardian = guardian_;
        executors[executor_] = true;
        assets[address(0)] = true;
        _setSigner(RISK_SIGNER, signers_[0]);
        _setSigner(WITHDRAWAL_SIGNER, signers_[1]);
        _setSigner(SETTLEMENT_SIGNER, signers_[2]);
        _setSigner(TRANSFER_SIGNER, signers_[3]);
        for (uint256 i; i < tokens_.length; ++i) {
            if (tokens_[i].code.length == 0) revert InvalidConfiguration();
            assets[tokens_[i]] = true;
        }
    }

    function setSigner(bytes32 purpose, address account) external {
        if (msg.sender != governor) revert Unauthorized();
        if (
            purpose != RISK_SIGNER && purpose != WITHDRAWAL_SIGNER && purpose != SETTLEMENT_SIGNER
                && purpose != TRANSFER_SIGNER
        ) revert InvalidConfiguration();
        _setSigner(purpose, account);
    }

    function setExecutor(address account, bool enabled) external {
        if (msg.sender != governor && !(msg.sender == guardian && !enabled)) revert Unauthorized();
        if (account == address(0)) revert InvalidConfiguration();
        executors[account] = enabled;
        emit ExecutorChanged(account, enabled);
    }

    function setAsset(address token, bool enabled) external {
        if (msg.sender != governor && !(msg.sender == guardian && !enabled)) revert Unauthorized();
        if (enabled && token != address(0) && token.code.length == 0) revert InvalidConfiguration();
        assets[token] = enabled;
        ++signers[RISK_SIGNER].epoch;
        ++signers[WITHDRAWAL_SIGNER].epoch;
        ++signers[SETTLEMENT_SIGNER].epoch;
        ++signers[TRANSFER_SIGNER].epoch;
        emit AssetChanged(token, enabled);
    }

    function verify(bytes32 purpose, uint256 epoch, bytes32 digest, bytes calldata signature) external view {
        Signer memory signer = signers[purpose];
        if (
            signer.epoch != epoch || signer.account == address(0)
                || !SignatureChecker.isValidSignatureNow(signer.account, digest, signature)
        ) {
            revert InvalidAuthorization();
        }
    }

    function verifyCouncil(bytes32 digest, bytes calldata signature) external view {
        if (!SignatureChecker.isValidSignatureNow(council, digest, signature)) revert InvalidAuthorization();
    }

    function _setSigner(bytes32 purpose, address account) private {
        if (account == address(0)) revert InvalidConfiguration();
        Signer storage signer = signers[purpose];
        signer.account = account;
        ++signer.epoch;
        emit SignerChanged(purpose, account, signer.epoch);
    }
}
