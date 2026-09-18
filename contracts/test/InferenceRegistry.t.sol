// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {InferenceRegistry} from "../src/InferenceRegistry.sol";

contract InferenceRegistryTest is Test {
    InferenceRegistry internal reg;
    address internal keeper = address(0xB0);
    bytes32 internal modelId = keccak256("eth-1-2-8h-v1");

    function setUp() public {
        reg = new InferenceRegistry(address(this), keeper, modelId);
    }

    function _hash(uint64 hour, int256 a, int256 b, int256 c) internal view returns (bytes32) {
        return keccak256(abi.encode(hour, a, b, c, modelId));
    }

    function testSubmitAndRead() public {
        vm.prank(keeper);
        reg.submit(1000, -40, -110, -150, _hash(1000, -40, -110, -150));
        InferenceRegistry.Forecast memory f = reg.getForecast(1000);
        assertEq(f.pct1hBps, -40);
        assertEq(reg.latestHourId(), 1000);
        assertEq(reg.forecastCount(), 1);
        assertFalse(reg.warmupComplete());
    }

    function testRejectBadHash() public {
        vm.prank(keeper);
        vm.expectRevert(InferenceRegistry.HashMismatch.selector);
        reg.submit(1000, -40, -110, -150, bytes32(uint256(1)));
    }

    function testRejectNonMonotonic() public {
        vm.startPrank(keeper);
        reg.submit(1000, 1, 1, 1, _hash(1000, 1, 1, 1));
        vm.expectRevert(InferenceRegistry.HourNotMonotonic.selector);
        reg.submit(1000, 1, 1, 1, _hash(1000, 1, 1, 1));
        vm.stopPrank();
    }

    function testWarmupAtNine() public {
        vm.startPrank(keeper);
        for (uint64 i = 0; i < 9; i++) {
            int256 x = int256(uint256(i));
            reg.submit(1000 + i, x, x, x, _hash(1000 + i, x, x, x));
        }
        vm.stopPrank();
        assertTrue(reg.warmupComplete());
        assertEq(reg.forecastCount(), 9);
    }

    function testComputeHashMatchesSubmit() public {
        bytes32 h = reg.computeHash(1000, -40, -110, -150);
        assertEq(h, _hash(1000, -40, -110, -150));
        vm.prank(keeper);
        reg.submit(1000, -40, -110, -150, h);
        assertEq(reg.getForecast(1000).forecastHash, h);
    }

    function testOnlyKeeper() public {
        vm.expectRevert(InferenceRegistry.NotKeeper.selector);
        reg.submit(1, 0, 0, 0, _hash(1, 0, 0, 0));
    }
}
