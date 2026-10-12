// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { PrepareActivation } from "../script/PrepareActivation.s.sol";
import { TenantTimelock } from "../src/control/TenantTimelock.sol";
import { TenantAuthority } from "../src/control/TenantAuthority.sol";
import { RiskRegistry } from "../src/control/RiskRegistry.sol";
import { MilonWithdrawalVerifier } from "../src/bridge/MilonWithdrawalVerifier.sol";
import { WithdrawalBook } from "../src/bridge/WithdrawalBook.sol";
import { HotPoolManager } from "../src/pools/HotPoolManager.sol";
import { DepositFactory } from "../src/deposit/DepositFactory.sol";
import { IHotPoolManager } from "../src/common/IWallet.sol";
import { MockSigner } from "./helpers/Mocks.sol";

/// @notice 对生成的真实公开激活 calldata 做完整 schedule/execute 验证，确保脚本未提前修改任何业务状态。
contract ActivationPlanTest is Test {
    TenantAuthority private authority;
    TenantTimelock private timelock;
    HotPoolManager private manager;
    MilonWithdrawalVerifier private verifier;
    MockSigner private council;
    PrepareActivation private planner;

    function setUp() public {
        vm.warp(10 days);
        vm.chainId(31337);
        council = new MockSigner(vm.addr(0x90001));
        timelock = new TenantTimelock(2 days, address(council));
        authority = new TenantAuthority(
            keccak256("activation tenant"),
            keccak256("activation chain"),
            address(timelock),
            makeAddr("guardian"),
            address(this),
            1800
        );
        RiskRegistry risks = new RiskRegistry(authority);
        verifier = new MilonWithdrawalVerifier(
            authority, keccak256("activation bridge"), 567, keccak256("source genesis"), 42
        );
        WithdrawalBook book = new WithdrawalBook(authority, verifier);
        manager = new HotPoolManager(authority, risks, book, verifier, 20);
        DepositFactory factory = new DepositFactory(authority, risks, IHotPoolManager(address(manager)));
        authority.bindSuite(address(factory), address(manager), address(verifier), address(book));
        planner = new PrepareActivation();
        vm.setEnv("EXPECTED_CHAIN_ID", "31337");
        vm.setEnv("AUTHORITY", vm.toString(address(authority)));
        vm.setEnv("REFUND_SIGNER", vm.toString(vm.addr(0x20001)));
        vm.setEnv("SWEEP_SIGNER", vm.toString(vm.addr(0x30001)));
        vm.setEnv("TRANSFER_SIGNER", vm.toString(vm.addr(0x40001)));
        vm.setEnv("COUNCIL_SIGNER", vm.toString(address(council)));
        vm.setEnv("RELAYER", vm.toString(makeAddr("relayer")));
        vm.setEnv("OPERATOR", vm.toString(makeAddr("operator")));
        vm.setEnv("COLD_ADDRESS", vm.toString(makeAddr("cold")));
        vm.setEnv("MAPPING_DIGEST", vm.toString(keccak256("mapping")));
        vm.setEnv("COMMITTEE_ID", vm.toString(keccak256("committee")));
        address[4] memory members;
        for (uint256 i; i < 4; ++i) {
            members[i] = vm.addr(0x60001 + i);
        }
        for (uint256 i; i < 4; ++i) {
            for (uint256 j = i + 1; j < 4; ++j) {
                if (members[j] < members[i]) (members[i], members[j]) = (members[j], members[i]);
            }
        }
        vm.setEnv(
            "BRIDGE_SIGNERS",
            string.concat(
                vm.toString(members[0]),
                ",",
                vm.toString(members[1]),
                ",",
                vm.toString(members[2]),
                ",",
                vm.toString(members[3])
            )
        );
        vm.setEnv("BRIDGE_QUORUM", "3");
        vm.setEnv("ACTIVATION_SALT", vm.toString(keccak256("activation salt")));
        vm.setEnv("ASSET_TOKENS", vm.toString(address(0)));
        vm.setEnv("ASSET_DECIMALS", "18");
        vm.setEnv("ASSET_CAPS_RAW", "100000000000000000000");
        vm.setEnv("SINGLE_LIMITS_RAW", "100000000000000000000");
        vm.setEnv("DAILY_LIMITS_RAW", "1000000000000000000000");
        vm.setEnv("ROLLING_LIMITS_RAW", "1000000000000000000000");
        vm.setEnv("SAFETY_FLOORS_RAW", "0");
        vm.setEnv("COUNCIL_THRESHOLDS_RAW", "50000000000000000000");
    }

    function testGeneratedBatchActivatesOnlyAfterTimelockExecution() public {
        // Foundry's environment variables are process-wide. Keep invalid/valid env cases in one test
        // so parallel tests cannot overwrite a different test's BRIDGE_QUORUM during plan generation.
        vm.setEnv("BRIDGE_QUORUM", "2");
        vm.expectRevert();
        planner.run();
        assertEq(manager.assetCount(), 0);
        assertEq(verifier.committeeEpoch(), 0);
        assertEq(authority.authorityEpoch(), 1);
        vm.setEnv("BRIDGE_QUORUM", "3");
        bytes32 id = planner.run();
        assertTrue(authority.sweepsPaused());
        assertTrue(authority.outflowsPaused());
        assertTrue(verifier.paused());
        assertEq(manager.assetCount(), 0);
        string memory plan = vm.readFile(
            string.concat(
                vm.projectRoot(), "/deployments/activation-", vm.toString(address(authority)), ".local.json"
            )
        );
        bytes memory schedule = vm.parseJsonBytes(plan, ".scheduleCalldata");
        bytes memory execute = vm.parseJsonBytes(plan, ".executeCalldata");
        vm.prank(address(council));
        (bool ok,) = address(timelock).call(schedule);
        assertTrue(ok);
        assertTrue(timelock.isOperationPending(id));
        (ok,) = address(timelock).call(execute);
        assertFalse(ok);
        vm.warp(block.timestamp + 2 days);
        (ok,) = address(timelock).call(execute);
        assertTrue(ok);
        assertTrue(timelock.isOperationDone(id));
        assertFalse(authority.sweepsPaused());
        assertFalse(authority.outflowsPaused());
        assertFalse(verifier.paused());
        assertEq(manager.assetCap(address(0)).maxBalanceRaw, 100 ether);
    }
}
