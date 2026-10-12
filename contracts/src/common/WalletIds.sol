// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title EVM / Rust / Milon 统一业务标识编码
/// @notice 所有标识使用固定类型的 abi.encode 后 Keccak256，禁止使用字符串拼接或 JSON 序列化替代。
library WalletIds {
    bytes32 internal constant CHAIN_V1 = keccak256("CHAIN_V1");
    bytes32 internal constant WALLET_V1 = keccak256("WALLET_V1");
    bytes32 internal constant ASSET_V1 = keccak256("ASSET_V1");
    bytes32 internal constant DEPOSIT_V1 = keccak256("DEPOSIT_V1");
    bytes32 internal constant REFUND_V1 = keccak256("REFUND_V1");
    bytes32 internal constant MOVE_V1 = keccak256("MOVE_V1");

    /// @notice 链标识包含命名空间、原始链 ID 和 genesis hash，区分同 ID 的不同链实例。
    function chain(bytes32 namespace, uint256 chainId, bytes32 genesisHash) internal pure returns (bytes32) {
        return keccak256(abi.encode(CHAIN_V1, namespace, chainId, genesisHash));
    }

    /// @notice 逻辑钱包标识绑定租户与用户；地址轮换不改变 walletKey。
    function wallet(bytes32 tenantKey, bytes32 userKey, bytes32 logicalWalletId)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(WALLET_V1, tenantKey, userKey, logicalWalletId));
    }

    /// @notice 资产键包含链实例、Native=0/ERC20=1 类型及 token 地址，不按 symbol 合并资产。
    function asset(bytes32 chainKey, address token) internal pure returns (bytes32) {
        return keccak256(abi.encode(ASSET_V1, chainKey, uint8(token == address(0) ? 0 : 1), token));
    }

    /// @notice 原生币到账事件和 ERC20 Transfer 均使用 Log=1 的规范定位；blockHash 不进入稳定 depositId。
    function deposit(bytes32 chainKey, bytes32 txHash, uint64 logIndex) internal pure returns (bytes32) {
        // v2 uses one canonical receipt log for both native deposits and ERC20 transfers (Log = 1).
        return keccak256(abi.encode(DEPOSIT_V1, chainKey, txHash, uint8(1), logIndex));
    }

    /// @notice 自提回执键绑定充值地址、币种与被消费 nonce，后端据此幂等更新待归集余额。
    function refund(bytes32 chainKey, address vault, bytes32 assetKey, uint256 nonce)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(REFUND_V1, chainKey, vault, assetKey, nonce));
    }

    /// @notice 首次归集与后续内部调拨共用移动标识格式，但只有首次净归集可作为权益入账依据。
    function movement(bytes32 bridgeId, bytes32 chainKey, bytes32 operationId)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(MOVE_V1, bridgeId, chainKey, operationId));
    }
}
