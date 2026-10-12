// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Script } from "forge-std/Script.sol";
import { TenantTimelock } from "../src/control/TenantTimelock.sol";
import { TenantAuthority } from "../src/control/TenantAuthority.sol";
import { RiskRegistry } from "../src/control/RiskRegistry.sol";
import { MilonWithdrawalVerifier } from "../src/bridge/MilonWithdrawalVerifier.sol";
import { WithdrawalBook } from "../src/bridge/WithdrawalBook.sol";
import { HotPoolManager } from "../src/pools/HotPoolManager.sol";
import { DepositFactory } from "../src/deposit/DepositFactory.sol";
import { IHotPoolManager } from "../src/common/IWallet.sol";
import { WalletIds } from "../src/common/WalletIds.sol";

/// @title v2 租户部署脚本
/// @notice 只读取公开配置，用 Foundry 外部钱包签署部署交易；部署后保持归集、出金和桥验证暂停。
/// @dev 同一租户同一目标链只认可一套部署，必须在后端/Milon 映射中登记本次公开 manifest。
contract DeployTenant is Script {
    struct Suite {
        TenantTimelock timelock;
        TenantAuthority authority;
        RiskRegistry risks;
        MilonWithdrawalVerifier verifier;
        WithdrawalBook book;
        HotPoolManager manager;
        DepositFactory factory;
    }

    /// @notice 校验链 ID、部署者 nonce 及配置后顺序部署组件，输出公开地址清单。
    /// @dev DEPLOYER 只是地址，签名材料由 --account/硬件钱包提供；脚本不读取任何私钥环境变量。
    function run() external returns (Suite memory suite) {
        address deployer = vm.envAddress("DEPLOYER");
        require(
            deployer != address(0) && block.chainid == vm.envUint("EXPECTED_CHAIN_ID"),
            "wrong deployment chain"
        );
        require(vm.getNonce(deployer) == vm.envUint("EXPECTED_DEPLOYER_NONCE"), "deployer nonce changed");
        bytes32 genesis = vm.envBytes32("EVM_GENESIS_HASH");
        require(genesis != bytes32(0), "missing EVM genesis");
        bytes32 chainKey = WalletIds.chain(keccak256("eip155"), block.chainid, genesis);
        vm.startBroadcast(deployer);
        suite.timelock =
            new TenantTimelock(vm.envUint("GOVERNANCE_DELAY"), vm.envAddress("GOVERNANCE_COUNCIL"));
        uint256 window = vm.envUint("OBSERVATION_WINDOW");
        require(window <= type(uint48).max, "observation window overflow");
        suite.authority = new TenantAuthority(
            vm.envBytes32("TENANT_KEY"),
            chainKey,
            address(suite.timelock),
            vm.envAddress("GUARDIAN"),
            deployer,
            uint48(window)
        );
        suite.risks = new RiskRegistry(suite.authority);
        uint256 app = vm.envUint("MILON_WITHDRAWAL_APP_ID");
        require(app > 0 && app <= type(uint8).max, "invalid App ID");
        suite.verifier = new MilonWithdrawalVerifier(
            suite.authority,
            vm.envBytes32("BRIDGE_ID"),
            vm.envUint("MILON_CHAIN_ID"),
            vm.envBytes32("MILON_GENESIS_HASH"),
            uint8(app)
        );
        suite.book = new WithdrawalBook(suite.authority, suite.verifier);
        suite.manager = new HotPoolManager(
            suite.authority, suite.risks, suite.book, suite.verifier, vm.envUint("MAX_HOT_VAULTS")
        );
        suite.factory =
            new DepositFactory(suite.authority, suite.risks, IHotPoolManager(address(suite.manager)));
        suite.authority.bindSuite(
            address(suite.factory), address(suite.manager), address(suite.verifier), address(suite.book)
        );
        vm.stopBroadcast();
        _writeManifest(suite, deployer);
    }

    /// @dev 清单不包含敏感凭据；记录两个克隆实现，供后端验证 CREATE2、字节码与固定绑定关系。
    function _writeManifest(Suite memory suite, address deployer) private {
        string memory key = "tenant-v2";
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeBytes32(key, "chainKey", suite.authority.chainKey());
        vm.serializeBytes32(key, "tenantKey", suite.authority.tenantKey());
        vm.serializeAddress(key, "deployer", deployer);
        vm.serializeAddress(key, "timelock", address(suite.timelock));
        vm.serializeAddress(key, "authority", address(suite.authority));
        vm.serializeAddress(key, "riskRegistry", address(suite.risks));
        vm.serializeAddress(key, "verifier", address(suite.verifier));
        vm.serializeAddress(key, "withdrawalBook", address(suite.book));
        vm.serializeAddress(key, "hotPoolManager", address(suite.manager));
        vm.serializeAddress(key, "depositFactory", address(suite.factory));
        vm.serializeAddress(key, "hotImplementation", suite.manager.implementation());
        string memory manifest =
            vm.serializeAddress(key, "depositImplementation", suite.factory.implementation());
        string memory path = string.concat(
            vm.projectRoot(),
            "/deployments/",
            vm.toString(block.chainid),
            "-",
            vm.toString(suite.authority.tenantKey()),
            ".local.json"
        );
        vm.writeJson(manifest, path);
    }
}
