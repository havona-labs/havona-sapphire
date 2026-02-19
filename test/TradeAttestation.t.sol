// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TradeAttestation} from "../contracts/TradeAttestation.sol";

contract TradeAttestationTest is Test {
    TradeAttestation oracle;

    address owner    = address(0xA1);
    address roflApp  = address(0xB2);
    address attacker = address(0xC3);

    // Cache commodity IDs once in setUp — calling oracle.X() inside a prank
    // would consume the prank before the actual state-changing call.
    bytes32 WTI;
    bytes32 GAS;
    bytes32 GOLD;

    function setUp() public {
        oracle = new TradeAttestation(owner, roflApp);
        WTI  = oracle.CRUDE_OIL_WTI();
        GAS  = oracle.NATURAL_GAS();
        GOLD = oracle.GOLD();
    }

    function test_SubmitAndReadPrice() public {
        vm.prank(roflApp);
        oracle.submitAttestation(WTI, 85_500000);

        (uint256 price, uint256 ts) = oracle.getPrice(WTI);
        assertEq(price, 85_500000);
        assertGt(ts, 0);
    }

    function test_BatchSubmit() public {
        bytes32[] memory comms = new bytes32[](2);
        uint256[] memory prices = new uint256[](2);
        comms[0] = WTI;
        comms[1] = GAS;
        prices[0] = 85_500000;
        prices[1] = 2_800000;

        vm.prank(roflApp);
        oracle.submitBatch(comms, prices);

        (uint256 p1,) = oracle.getPrice(WTI);
        (uint256 p2,) = oracle.getPrice(GAS);
        assertEq(p1, 85_500000);
        assertEq(p2, 2_800000);
    }

    function test_RejectUnauthorisedSubmit() public {
        vm.prank(attacker);
        vm.expectRevert("not ROFL oracle");
        oracle.submitAttestation(WTI, 100_000000);
    }

    function test_RejectStalePrice() public {
        vm.prank(roflApp);
        oracle.submitAttestation(WTI, 85_000000);

        vm.warp(block.timestamp + 6 minutes);

        vm.expectRevert("price stale");
        oracle.getPrice(WTI);
    }

    function test_RejectMissingPrice() public {
        vm.expectRevert("no data");
        oracle.getPrice(GOLD);
    }

    function test_UpdateRoflAddress() public {
        address newApp = address(0xD4);
        vm.prank(owner);
        oracle.setRoflAddress(newApp);
        assertEq(oracle.roflAppAddress(), newApp);

        vm.prank(newApp);
        oracle.submitAttestation(GOLD, 3_200_000000);
        (uint256 p,) = oracle.getPrice(GOLD);
        assertEq(p, 3_200_000000);
    }

    function test_OnlyOwnerCanUpdateRoflAddress() public {
        vm.prank(attacker);
        vm.expectRevert();
        oracle.setRoflAddress(attacker);
    }

    function test_HistoryAccumulates() public {
        vm.startPrank(roflApp);
        oracle.submitAttestation(GAS, 2_800000);
        oracle.submitAttestation(GAS, 2_850000);
        oracle.submitAttestation(GAS, 2_900000);
        vm.stopPrank();

        assertEq(oracle.getHistoryLength(GAS), 3);
        assertEq(oracle.getHistoryAt(GAS, 0).price, 2_800000);
        assertEq(oracle.getHistoryAt(GAS, 2).price, 2_900000);
    }
}
