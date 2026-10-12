// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { TenantTimelock } from "../src/control/TenantTimelock.sol";
import { TenantAuthority } from "../src/control/TenantAuthority.sol";
import { MilonWithdrawalVerifier } from "../src/bridge/MilonWithdrawalVerifier.sol";
import { HotPoolManager } from "../src/pools/HotPoolManager.sol";
import { WalletTypes as T } from "../src/common/WalletTypes.sol";

/// @title 首次激活的可审阅治理计划生成器
/// @notice 仅生成 scheduleBatch/executeBatch calldata 和 operationId，不广播或自动解除暂停。
/// @dev 所有配置、委员会、资产上限与解锁在同一批治理操作中生效，任一版本过期会整体失败。
contract PrepareActivation is Script {
    error InvalidActivationOperation(uint256 index, bytes reason);

    struct Operations {
        address[] targets;
        uint256[] values;
        bytes[] payloads;
        uint256 count;
    }

    struct AssetInputs {
        address[] tokens;
        uint256[] decimals;
        uint256[] caps;
        uint256[] singles;
        uint256[] dailies;
        uint256[] rolling;
        uint256[] floors;
        uint256[] councilThresholds;
    }

    /// @notice 读取新部署 Authority 和公开配置，输出供 Council 审阅、提案与等待后执行的完整材料。
    function run() external returns (bytes32 operationId) {
        TenantAuthority authority = TenantAuthority(vm.envAddress("AUTHORITY"));
        require(
            block.chainid == vm.envUint("EXPECTED_CHAIN_ID") && authority.ready(),
            "wrong chain or unbound suite"
        );
        require(authority.sweepsPaused() && authority.outflowsPaused(), "not a fresh paused deployment");
        HotPoolManager manager = HotPoolManager(authority.hotPoolManager());
        require(manager.assetCount() == 0, "initial activation only");
        MilonWithdrawalVerifier verifier = MilonWithdrawalVerifier(authority.withdrawalVerifier());
        TenantTimelock timelock = TenantTimelock(payable(authority.governance()));
        AssetInputs memory assets = _readAssets();
        uint256 length = 11 + 3 * assets.tokens.length;
        Operations memory operations =
            Operations(new address[](length), new uint256[](length), new bytes[](length), 0);
        _authorityOperations(operations, authority);
        _push(
            operations,
            address(manager),
            abi.encodeCall(
                manager.setColdAddress, (vm.envAddress("COLD_ADDRESS"), manager.coldAddressEpoch())
            )
        );
        _push(
            operations,
            address(manager),
            abi.encodeCall(manager.publishMapping, (vm.envBytes32("MAPPING_DIGEST"), manager.mappingEpoch()))
        );
        _push(
            operations,
            address(verifier),
            abi.encodeCall(
                verifier.installCommittee,
                (
                    vm.envBytes32("COMMITTEE_ID"),
                    vm.envAddress("BRIDGE_SIGNERS", ","),
                    vm.envUint("BRIDGE_QUORUM"),
                    verifier.committeeEpoch()
                )
            )
        );
        for (uint256 i; i < assets.tokens.length; ++i) {
            _assetOperations(operations, manager, assets, i);
        }
        _push(
            operations,
            address(authority),
            abi.encodeCall(authority.setPaused, (false, false, authority.authorityEpoch() + 4))
        );
        _push(
            operations,
            address(verifier),
            abi.encodeCall(verifier.setPaused, (false, verifier.bridgeEpoch() + 1))
        );
        require(operations.count == length, "incorrect activation length");
        bytes32 salt = vm.envBytes32("ACTIVATION_SALT");
        require(salt != bytes32(0), "missing operation salt");
        operationId = timelock.hashOperationBatch(
            operations.targets, operations.values, operations.payloads, bytes32(0), salt
        );
        bytes memory schedule = abi.encodeCall(
            timelock.scheduleBatch,
            (
                operations.targets,
                operations.values,
                operations.payloads,
                bytes32(0),
                salt,
                timelock.getMinDelay()
            )
        );
        bytes memory execute = abi.encodeCall(
            timelock.executeBatch,
            (operations.targets, operations.values, operations.payloads, bytes32(0), salt)
        );
        _simulate(operations, address(timelock));
        string memory key = "activation-v2";
        vm.serializeAddress(key, "governanceTarget", address(timelock));
        vm.serializeBytes32(key, "operationId", operationId);
        vm.serializeUint(key, "minimumDelaySeconds", timelock.getMinDelay());
        vm.serializeBytes(key, "scheduleCalldata", schedule);
        string memory plan = vm.serializeBytes(key, "executeCalldata", execute);
        vm.writeJson(
            plan,
            string.concat(
                vm.projectRoot(), "/deployments/activation-", vm.toString(address(authority)), ".local.json"
            )
        );
    }

    /// @dev 各角色均绑定当前 epoch。四次 setSigner 恰好使 authorityEpoch 增加四，不依赖部署时固定数值。
    function _authorityOperations(Operations memory ops, TenantAuthority authority) private view {
        bytes32[4] memory roles = [
            authority.REFUND_SIGNER(),
            authority.SWEEP_SIGNER(),
            authority.TRANSFER_SIGNER(),
            authority.COUNCIL_SIGNER()
        ];
        address[4] memory signers = [
            vm.envAddress("REFUND_SIGNER"),
            vm.envAddress("SWEEP_SIGNER"),
            vm.envAddress("TRANSFER_SIGNER"),
            vm.envAddress("COUNCIL_SIGNER")
        ];
        for (uint256 i; i < 4; ++i) {
            _push(
                ops,
                address(authority),
                abi.encodeCall(authority.setSigner, (roles[i], signers[i], authority.signerEpoch(roles[i])))
            );
        }
        _push(
            ops,
            address(authority),
            abi.encodeCall(authority.setPermission, (vm.envAddress("RELAYER"), 0, true))
        );
        _push(
            ops,
            address(authority),
            abi.encodeCall(authority.setPermission, (vm.envAddress("OPERATOR"), 1, true))
        );
    }

    function _assetOperations(
        Operations memory ops,
        HotPoolManager manager,
        AssetInputs memory inputs,
        uint256 i
    ) private pure {
        require(inputs.decimals[i] <= type(uint8).max, "decimals overflow");
        _push(
            ops,
            address(manager),
            abi.encodeCall(manager.registerAsset, (inputs.tokens[i], uint8(inputs.decimals[i])))
        );
        _push(
            ops,
            address(manager),
            abi.encodeCall(manager.setAssetCap, (inputs.tokens[i], inputs.caps[i], true, 0))
        );
        T.OutflowPolicy memory policy = T.OutflowPolicy(
            inputs.singles[i],
            inputs.dailies[i],
            inputs.rolling[i],
            inputs.floors[i],
            inputs.councilThresholds[i],
            0,
            true,
            true
        );
        _push(ops, address(manager), abi.encodeCall(manager.setOutflowPolicy, (inputs.tokens[i], policy, 0)));
    }

    /// @dev 所有数组严格按 ASSET_TOKENS 顺序对应，防止误把另一币种精度或数量上限应用到当前资产。
    function _readAssets() private view returns (AssetInputs memory inputs) {
        inputs.tokens = vm.envAddress("ASSET_TOKENS", ",");
        inputs.decimals = vm.envUint("ASSET_DECIMALS", ",");
        inputs.caps = vm.envUint("ASSET_CAPS_RAW", ",");
        inputs.singles = vm.envUint("SINGLE_LIMITS_RAW", ",");
        inputs.dailies = vm.envUint("DAILY_LIMITS_RAW", ",");
        inputs.rolling = vm.envUint("ROLLING_LIMITS_RAW", ",");
        inputs.floors = vm.envUint("SAFETY_FLOORS_RAW", ",");
        inputs.councilThresholds = vm.envUint("COUNCIL_THRESHOLDS_RAW", ",");
        uint256 length = inputs.tokens.length;
        require(
            length > 0 && length <= 64 && inputs.decimals.length == length && inputs.caps.length == length
                && inputs.singles.length == length && inputs.dailies.length == length
                && inputs.rolling.length == length && inputs.floors.length == length
                && inputs.councilThresholds.length == length,
            "asset arrays mismatch"
        );
    }

    function _push(Operations memory ops, address target, bytes memory payload) private pure {
        ops.targets[ops.count] = target;
        ops.payloads[ops.count] = payload;
        ++ops.count;
    }

    /// @dev 只在本地模拟治理调用，验证成员分离、数组配置与全部版本后恢复快照；不会广播链上交易。
    function _simulate(Operations memory ops, address governor) private {
        uint256 snapshot = vm.snapshot();
        for (uint256 i; i < ops.count; ++i) {
            vm.prank(governor);
            (bool ok, bytes memory reason) = ops.targets[i].call(ops.payloads[i]);
            if (!ok) revert InvalidActivationOperation(i, reason);
        }
        require(vm.revertTo(snapshot), "activation simulation restore failed");
    }
}
