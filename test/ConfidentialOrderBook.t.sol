// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ConfidentialOrderBook} from "../contracts/ConfidentialOrderBook.sol";

/**
 * Tests run against Anvil by default (blockhash fallback for randomness).
 * To test with real Sapphire precompiles, run against the localnet:
 *
 *   docker run --rm -p 8545:8545 ghcr.io/oasisprotocol/sapphire-dev:latest
 *   forge test --fork-url http://localhost:8545
 *
 * Sapphire-specific behaviour verified on the localnet:
 *   - Sapphire.randomBytes() returns cryptographic random (not blockhash)
 *   - Sapphire.padGas() actually pads gas to the target amount
 *   - msg.sender == address(0) on unsigned eth_call → getMyOrders() returns []
 *   - Signed view call (sapphire.wrap provider) → getMyOrders() returns the trader's orders
 */
contract ConfidentialOrderBookTest is Test {
    ConfidentialOrderBook book;

    address constant FORWARDER = address(0); // no gasless in these tests
    address trader1 = address(0xA1);
    address trader2 = address(0xB2);

    bytes32 constant CRUDE = keccak256("CRUDE_OIL_WTI");

    function setUp() public {
        book = new ConfidentialOrderBook(FORWARDER);
    }

    // -------------------------------------------------------------------------
    // Order placement
    // -------------------------------------------------------------------------

    function test_PlaceBuyOrder() public {
        vm.prank(trader1);
        uint256 id = book.placeOrder(CRUDE, 50_000e18, 85_000000, ConfidentialOrderBook.Side.Buy);
        assertEq(id, 0);
    }

    function test_PlaceSellOrder() public {
        vm.prank(trader2);
        uint256 id = book.placeOrder(CRUDE, 50_000e18, 82_000000, ConfidentialOrderBook.Side.Sell);
        assertEq(id, 0);
    }

    function test_RejectZeroQuantity() public {
        vm.prank(trader1);
        vm.expectRevert("zero qty");
        book.placeOrder(CRUDE, 0, 85_000000, ConfidentialOrderBook.Side.Buy);
    }

    // -------------------------------------------------------------------------
    // Matching
    // -------------------------------------------------------------------------

    function test_MatchOnOverlappingOrders() public {
        // Buy at 85, sell at 82 — they overlap, match at midpoint (83.5)
        vm.prank(trader1);
        uint256 buyId = book.placeOrder(CRUDE, 50_000e18, 85_000000, ConfidentialOrderBook.Side.Buy);

        vm.expectEmit(true, true, true, false);
        emit ConfidentialOrderBook.TradeMatched(0, buyId, 1, "");

        vm.prank(trader2);
        book.placeOrder(CRUDE, 50_000e18, 82_000000, ConfidentialOrderBook.Side.Sell);

        assertEq(book.matchCount(), 1);
    }

    function test_NoMatchWhenOrdersDontOverlap() public {
        // Buy at 80, sell at 85 — no match
        vm.prank(trader1);
        book.placeOrder(CRUDE, 50_000e18, 80_000000, ConfidentialOrderBook.Side.Buy);
        vm.prank(trader2);
        book.placeOrder(CRUDE, 50_000e18, 85_000000, ConfidentialOrderBook.Side.Sell);

        assertEq(book.matchCount(), 0);
    }

    function test_MatchedOrdersCannotBeCancelled() public {
        vm.prank(trader1);
        uint256 buyId = book.placeOrder(CRUDE, 1e18, 85_000000, ConfidentialOrderBook.Side.Buy);
        vm.prank(trader2);
        book.placeOrder(CRUDE, 1e18, 82_000000, ConfidentialOrderBook.Side.Sell);

        vm.prank(trader1);
        vm.expectRevert("not open");
        book.cancelOrder(buyId);
    }

    // -------------------------------------------------------------------------
    // Confidential reads
    // -------------------------------------------------------------------------

    function test_GetMyOrders_ReturnsOwnOrders() public {
        vm.prank(trader1);
        book.placeOrder(CRUDE, 50_000e18, 85_000000, ConfidentialOrderBook.Side.Buy);

        // On Sapphire: unsigned eth_call returns [] because msg.sender == 0x0.
        // On Anvil: msg.sender is whatever the caller is, no zeroing.
        vm.prank(trader1);
        ConfidentialOrderBook.Order[] memory orders = book.getMyOrders();
        assertEq(orders.length, 1);
        assertEq(orders[0].trader, trader1);
    }

    function test_GetMyOrders_DoesNotLeakOtherOrders() public {
        vm.prank(trader1);
        book.placeOrder(CRUDE, 50_000e18, 85_000000, ConfidentialOrderBook.Side.Buy);

        // trader2 cannot see trader1's orders
        vm.prank(trader2);
        ConfidentialOrderBook.Order[] memory orders = book.getMyOrders();
        assertEq(orders.length, 0);
    }

    // -------------------------------------------------------------------------
    // Match key access
    // -------------------------------------------------------------------------

    function test_OnlyCounterpartyCanGetMatchKey() public {
        vm.prank(trader1);
        book.placeOrder(CRUDE, 1e18, 85_000000, ConfidentialOrderBook.Side.Buy);
        vm.prank(trader2);
        book.placeOrder(CRUDE, 1e18, 82_000000, ConfidentialOrderBook.Side.Sell);

        // Both counterparties can read the key
        vm.prank(trader1);
        bytes32 key1 = book.getMatchKey(0);
        vm.prank(trader2);
        bytes32 key2 = book.getMatchKey(0);
        assertEq(key1, key2);

        // Third party cannot
        vm.prank(address(0xC3));
        vm.expectRevert("not a counterparty");
        book.getMatchKey(0);
    }

    // -------------------------------------------------------------------------
    // Cancellation
    // -------------------------------------------------------------------------

    function test_CancelOpenOrder() public {
        vm.prank(trader1);
        uint256 id = book.placeOrder(CRUDE, 50_000e18, 80_000000, ConfidentialOrderBook.Side.Buy);
        vm.prank(trader1);
        book.cancelOrder(id);

        vm.prank(trader1);
        ConfidentialOrderBook.Order[] memory open = book.getMyOpenOrders();
        assertEq(open.length, 0);
    }

    function test_CannotCancelOthersOrder() public {
        vm.prank(trader1);
        uint256 id = book.placeOrder(CRUDE, 1e18, 80_000000, ConfidentialOrderBook.Side.Buy);
        vm.prank(trader2);
        vm.expectRevert("not your order");
        book.cancelOrder(id);
    }
}
