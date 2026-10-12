// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {
    ITenantBound,
    IHotPoolManager,
    IFactoryConfiguration,
    IPoolConfiguration,
    IBridgeMembership
} from "../common/IWallet.sol";

/// @title 单租户权限和全局操作版本
/// @notice 普通配置只能由延时治理修改；Guardian 只允许暂停、限制和撤销，不能自行放款。
/// @dev 用户双签自提只依赖 REFUND_SIGNER 的版本，不受热池/归集暂停开关影响。
contract TenantAuthority {
    /// @notice 平台自提签名角色，只能与绑定用户签名共同授权未归集提款。
    bytes32 public constant REFUND_SIGNER = keccak256("REFUND_SIGNER");
    /// @notice 独立归集审核签名角色，证明来源、观察时间及净金额；不具备外部提现权限。
    bytes32 public constant SWEEP_SIGNER = keccak256("SWEEP_SIGNER");
    /// @notice 热池之间调拨和转冷的专用签名角色，目标受链上登记与容量约束。
    bytes32 public constant TRANSFER_SIGNER = keccak256("TRANSFER_SIGNER");
    /// @notice 大额出金的独立审批签名者，可配置为 ERC1271 多签账户。
    bytes32 public constant COUNCIL_SIGNER = keccak256("COUNCIL_SIGNER");

    struct Signer {
        address account;
        uint64 epoch;
    }

    /// @notice 本部署固定的租户及 EVM 链实例标识；金额和订单不能跨租户共享。
    bytes32 public immutable tenantKey;
    bytes32 public immutable chainKey;
    /// @notice 不可替换的治理入口，应为 TenantTimelock；bootstrapper 只能一次性绑定组件。
    address public immutable governance;
    address public immutable bootstrapper;
    /// @notice 应急执行者，仅有收紧权限；地址变更仍由延时治理执行。
    address public guardian;
    /// @notice 一次性绑定的业务组件地址；不允许更换订单簿来清除历史消费状态。
    address public depositFactory;
    address public hotPoolManager;
    address public withdrawalVerifier;
    address public withdrawalBook;
    /// @notice 退役异常资金的专用处置接收地址，由治理单独配置，不参与正常资金池。
    address public dispositionReceiver;
    /// @notice 每笔归集来源最短观察秒数，范围 1 秒至 7 天；变更同时撤销旧归集授权。
    uint48 public observationWindow;
    /// @notice 全局操作版本。角色签名配置、观察窗口、暂停状态变化均递增，恢复不复用旧版本。
    uint64 public authorityEpoch = 1;
    /// @notice 热池付款授权独立撤销版本，与桥委员会和 bridgeEpoch 含义不同。
    uint64 public withdrawalSignerEpoch = 1;
    /// @notice 组件绑定完成标记；完成绑定不代表已启用出金，初始暂停仍须治理解除。
    bool public ready;
    bool public sweepsPaused = true;
    bool public outflowsPaused = true;
    /// @notice Gas 中继白名单，没有独立付款签名权。用户双签自提可由任意人提交原始授权。
    mapping(address => bool) public relayers;
    /// @notice 负责身份登记、充值地址轮换和正常退役的运营角色。
    mapping(address => bool) public operators;
    /// @notice 可收紧风险限制的风控操作员；解除风险仍必须经过治理。
    mapping(address => bool) public riskOperators;
    /// @notice 各用途签名者及单调递增 epoch，禁止不同平台用途共用同一地址。
    mapping(bytes32 => Signer) public signers;

    error Unauthorized();
    error InvalidConfiguration();
    error InvalidEpoch();
    error InvalidSignature();
    error InvalidTimeWindow();
    error SuiteNotReady();

    event SuiteBound(address factory, address manager, address verifier, address book);
    event SignerUpdated(bytes32 indexed role, address signer, uint64 epoch);
    event PermissionUpdated(address indexed account, uint8 kind, bool enabled);
    event PauseUpdated(bool sweepsPaused, bool outflowsPaused, uint64 authorityEpoch);
    event WithdrawalSignerRevoked(uint64 signerEpoch);
    event ObservationWindowUpdated(uint48 window, uint64 authorityEpoch);
    event GuardianUpdated(address guardian);
    event DispositionReceiverUpdated(address receiver);

    /// @notice 建立不可变租户边界，初始保持归集和热池出金关闭。
    constructor(
        bytes32 tenant,
        bytes32 chain,
        address governor,
        address emergency,
        address bootstrap,
        uint48 window
    ) {
        if (
            tenant == bytes32(0) || chain == bytes32(0) || governor.code.length == 0
                || emergency == address(0) || emergency == governor || bootstrap == address(0) || window == 0
                || window > 7 days
        ) revert InvalidConfiguration();
        tenantKey = tenant;
        chainKey = chain;
        governance = governor;
        guardian = emergency;
        bootstrapper = bootstrap;
        observationWindow = window;
    }

    /// @dev 所有敏感配置入口统一限制为固定 Timelock 地址，部署者和 Guardian 不具备此权限。
    modifier onlyGovernance() {
        checkGovernance(msg.sender);
        _;
    }

    /// @notice 引导账户或治理仅可调用一次，绑定完整租户组件。
    /// @dev 每个组件必须已部署并指向本 Authority；此函数不给部署者配置或出金权限。
    function bindSuite(address factory, address manager, address verifier, address book) external {
        if (ready || (msg.sender != bootstrapper && msg.sender != governance)) revert Unauthorized();
        address[4] memory components = [factory, manager, verifier, book];
        for (uint256 i; i < components.length; ++i) {
            if (components[i].code.length == 0 || ITenantBound(components[i]).authority() != address(this)) {
                revert InvalidConfiguration();
            }
            for (uint256 j; j < i; ++j) {
                if (components[i] == components[j]) revert InvalidConfiguration();
            }
        }
        if (
            IFactoryConfiguration(factory).manager() != manager
                || IPoolConfiguration(manager).withdrawalBook() != book
                || IPoolConfiguration(manager).verifier() != verifier
                || IPoolConfiguration(book).verifier() != verifier
                || IFactoryConfiguration(factory).riskRegistry() != IPoolConfiguration(manager).riskRegistry()
        ) revert InvalidConfiguration();
        depositFactory = factory;
        hotPoolManager = manager;
        withdrawalVerifier = verifier;
        withdrawalBook = book;
        ready = true;
        emit SuiteBound(factory, manager, verifier, book);
    }

    /// @notice 治理更新某用途签名者，校验预期版本并使旧签名永久失效。
    /// @dev 签名者不能兼任中继/运营身份，也不能与其他平台签名用途共用地址。
    function setSigner(bytes32 role, address account, uint64 expectedEpoch) external onlyGovernance {
        if (
            !_knownRole(role) || account == address(0) || account == guardian || relayers[account]
                || operators[account] || riskOperators[account] || _isBridgeMember(account)
        ) revert InvalidConfiguration();
        bytes32[4] memory roles = [REFUND_SIGNER, SWEEP_SIGNER, TRANSFER_SIGNER, COUNCIL_SIGNER];
        for (uint256 i; i < roles.length; ++i) {
            if (roles[i] != role && signers[roles[i]].account == account) revert InvalidConfiguration();
        }
        Signer storage signer = signers[role];
        if (signer.epoch != expectedEpoch) revert InvalidEpoch();
        signer.account = account;
        ++signer.epoch;
        ++authorityEpoch;
        emit SignerUpdated(role, account, signer.epoch);
    }

    /// @notice 治理管理账户权限：kind=0 中继、1 运营、2 风控。
    /// @dev 不能将已有平台签名者同时登记为操作员。
    function setPermission(address account, uint8 kind, bool enabled) external onlyGovernance {
        if (account == address(0) || kind > 2) revert InvalidConfiguration();
        if (enabled && (_isSigner(account) || _isBridgeMember(account))) revert InvalidConfiguration();
        if (kind == 0) relayers[account] = enabled;
        else if (kind == 1) operators[account] = enabled;
        else riskOperators[account] = enabled;
        emit PermissionUpdated(account, kind, enabled);
    }

    /// @notice 治理更换应急执行者，不授予其解除暂停或转移资金的能力。
    function setGuardian(address emergency) external onlyGovernance {
        if (
            emergency == address(0) || emergency == governance || _isSigner(emergency)
                || _isBridgeMember(emergency)
        ) revert InvalidConfiguration();
        guardian = emergency;
        emit GuardianUpdated(emergency);
    }

    /// @notice 治理指定异常资金接收者；禁止使用正常托管地址形成自动重新入池。
    function setDispositionReceiver(address receiver) external onlyGovernance {
        if (!ready || receiver == address(0) || IHotPoolManager(hotPoolManager).isCustodyAddress(receiver)) {
            revert InvalidConfiguration();
        }
        dispositionReceiver = receiver;
        emit DispositionReceiverUpdated(receiver);
    }

    /// @notice 治理修改观察时间并递增 authorityEpoch，旧归集任务必须重新签发。
    function setObservationWindow(uint48 window) external onlyGovernance {
        if (window == 0 || window > 7 days) revert InvalidConfiguration();
        observationWindow = window;
        ++authorityEpoch;
        emit ObservationWindowUpdated(window, authorityEpoch);
    }

    /// @notice Guardian/治理只能追加暂停限制；所有既有操作授权因 epoch 递增失效。
    /// @dev 不暂停 ACTIVE 充值地址的双签自提。
    function pause(bool sweeps, bool outflows) external {
        checkGuardian(msg.sender);
        // Guardian can only add restrictions, including while a previous emergency is already active.
        sweepsPaused = sweepsPaused || sweeps;
        outflowsPaused = outflowsPaused || outflows;
        ++authorityEpoch;
        emit PauseUpdated(sweepsPaused, outflowsPaused, authorityEpoch);
    }

    /// @notice 只有治理可以解除暂停，要求预期全局版本匹配；解除后也会递增版本。
    function setPaused(bool sweeps, bool outflows, uint64 expectedEpoch) external onlyGovernance {
        if (authorityEpoch != expectedEpoch || !ready) revert InvalidEpoch();
        sweepsPaused = sweeps;
        outflowsPaused = outflows;
        ++authorityEpoch;
        emit PauseUpdated(sweeps, outflows, authorityEpoch);
    }

    /// @notice 紧急撤销已发出的全部旧热池付款 Permit，不改变共享订单历史。
    function revokeWithdrawalSigner() external {
        checkGuardian(msg.sender);
        ++withdrawalSignerEpoch;
        emit WithdrawalSignerRevoked(withdrawalSignerEpoch);
    }

    /// @notice 返回签名服务在构造授权时必须绑定的当前用途版本。
    function signerEpoch(bytes32 role) external view returns (uint64) {
        return signers[role].epoch;
    }

    /// @notice 验证指定用途的签名地址、当前版本和完整摘要，支持 EOA 或 ERC1271。
    /// @dev 此只读验证不消费业务 nonce；由调用合约在同一事务内执行消费和转账。
    function verify(bytes32 role, uint64 epoch, bytes32 digest, bytes calldata authorization) external view {
        Signer memory signer = signers[role];
        if (epoch == 0 || epoch != signer.epoch) revert InvalidEpoch();
        if (
            authorization.length > 8192
                || !SignatureChecker.isValidSignatureNow(signer.account, digest, authorization)
        ) {
            revert InvalidSignature();
        }
    }

    /// @notice 组件共用的治理权限断言，调用方应传入自身收到的 msg.sender。
    function checkGovernance(address caller) public view {
        if (caller != governance) revert Unauthorized();
    }
    /// @notice 仅接受当前 Guardian 或延时治理执行限制类操作。

    function checkGuardian(address caller) public view {
        if (caller != guardian && caller != governance) revert Unauthorized();
    }
    /// @notice 风控操作员、Guardian 和治理均可收紧限制。

    function checkRiskOperator(address caller) external view {
        if (caller != guardian && caller != governance && !riskOperators[caller]) revert Unauthorized();
    }
    /// @notice 热池出金及归集交易需要部署已绑定且调用者具有中继权限。

    function checkRelayer(address caller) external view {
        if (!ready) revert SuiteNotReady();
        if (!relayers[caller]) revert Unauthorized();
    }
    /// @notice 身份登记、地址管理需要部署已绑定且调用者具有运营权限。

    function checkOperator(address caller) external view {
        if (!ready) revert SuiteNotReady();
        if (!operators[caller]) revert Unauthorized();
    }

    /// @notice 授权时间使用 EVM 秒，要求当前处于时间窗内，单份授权窗口不超过 1 小时。
    function checkTime(uint48 validAfter, uint48 deadline) external view {
        if (
            validAfter > block.timestamp || deadline < block.timestamp || deadline <= validAfter
                || deadline - validAfter > 1 hours
        ) revert InvalidTimeWindow();
    }

    /// @dev 仅接受四个明确平台签名用途，不能用任意 bytes32 新建有出金含义的角色。
    function _knownRole(bytes32 role) private pure returns (bool) {
        return
            role == REFUND_SIGNER || role == SWEEP_SIGNER || role == TRANSFER_SIGNER || role == COUNCIL_SIGNER;
    }

    /// @dev 识别已登记平台用途签名地址，用于禁止与操作员或桥成员重复注册。
    function _isSigner(address account) private view returns (bool) {
        return account == signers[REFUND_SIGNER].account || account == signers[SWEEP_SIGNER].account
            || account == signers[TRANSFER_SIGNER].account || account == signers[COUNCIL_SIGNER].account;
    }

    /// @dev 安装委员会后也保持角色分离，不能绕过安装时检查再将桥成员登记成平台在线角色。
    function _isBridgeMember(address account) private view returns (bool) {
        if (!ready) return false;
        uint64 epoch = IBridgeMembership(withdrawalVerifier).committeeEpoch();
        return epoch != 0 && IBridgeMembership(withdrawalVerifier).memberEpoch(account) == epoch;
    }
}
