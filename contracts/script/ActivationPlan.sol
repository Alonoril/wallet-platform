// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { PoolRegistry } from "../src/control/PoolRegistry.sol";
import { WalletTypes } from "../src/common/WalletTypes.sol";

library ActivationPlan {
    struct Configuration {
        PoolRegistry pools;
        address factory;
        address treasury;
        address clearing;
        address quarantine;
        address cold;
        bool allowDirectSweep;
        address[] tokens;
        WalletTypes.Limits nativeLimits;
        WalletTypes.Limits[] tokenLimits;
    }

    /// @dev One atomic activation: registered code, explicit routes, global budgets, then resume routing.
    function build(Configuration memory c)
        internal
        pure
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calls)
    {
        require(c.tokens.length == c.tokenLimits.length, "limit count mismatch");
        uint256 length = 16 + c.tokens.length;
        targets = new address[](length);
        values = new uint256[](length);
        calls = new bytes[](length);
        for (uint256 i; i < length; ++i) {
            targets[i] = address(c.pools);
        }
        calls[0] = abi.encodeCall(PoolRegistry.registerPool, (c.treasury, WalletTypes.PoolKind.Treasury));
        calls[1] = abi.encodeCall(PoolRegistry.registerPool, (c.clearing, WalletTypes.PoolKind.Clearing));
        calls[2] = abi.encodeCall(PoolRegistry.registerPool, (c.quarantine, WalletTypes.PoolKind.Quarantine));
        calls[3] = abi.encodeCall(PoolRegistry.registerPool, (c.cold, WalletTypes.PoolKind.Cold));
        calls[4] = _route(WalletTypes.RouteKind.Sweep, c.factory, c.clearing, true);
        calls[5] = _route(WalletTypes.RouteKind.Sweep, c.factory, c.treasury, c.allowDirectSweep);
        calls[6] = _route(WalletTypes.RouteKind.Settlement, c.clearing, c.treasury, true);
        calls[7] = _route(WalletTypes.RouteKind.Disposition, c.factory, c.quarantine, true);
        calls[8] = _route(WalletTypes.RouteKind.Disposition, c.treasury, c.quarantine, true);
        calls[9] = _route(WalletTypes.RouteKind.Disposition, c.clearing, c.quarantine, true);
        calls[10] = _route(WalletTypes.RouteKind.Disposition, c.quarantine, c.treasury, true);
        calls[11] = _route(WalletTypes.RouteKind.Disposition, c.cold, c.quarantine, true);
        calls[12] = _route(WalletTypes.RouteKind.Rebalance, c.treasury, c.cold, true);
        calls[13] = _route(WalletTypes.RouteKind.Rebalance, c.cold, c.treasury, true);
        calls[14] = abi.encodeCall(PoolRegistry.setLimits, (address(0), c.nativeLimits));
        for (uint256 i; i < c.tokens.length; ++i) {
            calls[15 + i] = abi.encodeCall(PoolRegistry.setLimits, (c.tokens[i], c.tokenLimits[i]));
        }
        calls[length - 1] = abi.encodeCall(PoolRegistry.setRoutesPaused, (false));
    }

    function _route(WalletTypes.RouteKind kind, address source, address destination, bool enabled)
        private
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(PoolRegistry.setRoute, (kind, source, destination, enabled));
    }
}
