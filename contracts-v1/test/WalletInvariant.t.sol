// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { WalletFixture } from "./helpers/WalletFixture.sol";
import { WalletHandler } from "./helpers/WalletHandler.sol";

contract WalletInvariantTest is WalletFixture {
    WalletHandler private handler;

    function setUp() public override {
        super.setUp();
        handler = new WalletHandler(s.treasury, s.risk, s.pools, token, guardian, relayer, address(council));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = WalletHandler.fund.selector;
        selectors[1] = WalletHandler.changeHold.selector;
        selectors[2] = WalletHandler.changeReserve.selector;
        selectors[3] = WalletHandler.withdraw.selector;
        selectors[4] = WalletHandler.cancel.selector;
        selectors[5] = WalletHandler.advanceTime.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariantMoneyIsConservedAndLedgerMatchesActualPayments() public view {
        assertEq(
            token.balanceOf(address(s.treasury)) + token.balanceOf(handler.RECIPIENT()), handler.minted()
        );
        assertEq(token.balanceOf(handler.RECIPIENT()), handler.paid());
    }

    function invariantHoldsReservesAndRevertAtomicityAlwaysApply() public view {
        assertFalse(handler.violatedHold());
        assertFalse(handler.violatedFloor());
        assertFalse(handler.violatedAtomicity());
    }

    function invariantRequestCanPayAtMostOnceAndCancellationIsTerminal() public view {
        for (uint8 i; i < 8; ++i) {
            bytes32 requestId = handler.request(i);
            uint256 payments = handler.successfulPayments(requestId);
            assertLe(payments, 1);
            uint256 status = uint256(s.treasury.requestStatus(requestId));
            if (payments == 1) assertEq(status, 1);
            if (status == 2) assertEq(payments, 0);
        }
    }
}
