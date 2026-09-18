// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DualHorizonGate} from "../src/libraries/DualHorizonGate.sol";

contract DualHorizonGateTest is Test {
    uint16 constant G1 = 100;
    uint16 constant G2 = 250;
    uint16 constant G8 = 200;

    function testEnterWhenAllInsideAndIdle() public pure {
        uint8 a = DualHorizonGate.allowedAction(-40, -110, -150, G1, G2, G8, false);
        assertEq(a, DualHorizonGate.ENTER);
    }

    function testExitWhen2hOutsideEvenIf1hSmall() public pure {
        uint8 a = DualHorizonGate.allowedAction(-30, -280, -150, G1, G2, G8, true);
        assertEq(a, DualHorizonGate.EXIT);
    }

    function testExitWhen1hOutside() public pure {
        uint8 a = DualHorizonGate.allowedAction(120, 10, 10, G1, G2, G8, true);
        assertEq(a, DualHorizonGate.EXIT);
    }

    function testIdleStayFlatWhen8hOutside() public pure {
        uint8 a = DualHorizonGate.allowedAction(-20, -30, -250, G1, G2, G8, false);
        assertEq(a, DualHorizonGate.EXIT);
    }

    function testHoldWhenInPoolAndInside() public pure {
        uint8 a = DualHorizonGate.allowedAction(-20, -30, -50, G1, G2, G8, true);
        assertEq(a, DualHorizonGate.HOLD);
    }
}
