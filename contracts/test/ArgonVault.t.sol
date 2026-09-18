// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ArgonVault} from "../src/ArgonVault.sol";
import {InferenceRegistry} from "../src/InferenceRegistry.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {MockPoolAdapter} from "../src/mocks/MockPoolAdapter.sol";

contract ArgonVaultTest is Test {
    ArgonVault internal vault;
    InferenceRegistry internal reg;
    MockERC20 internal weth;
    MockERC20 internal usdc;
    MockOracle internal oracle;
    MockPoolAdapter internal adapter;
    address internal keeper = address(0xB0);
    address internal alice = address(0xA1);
    address internal bob = address(0xB2);
    bytes32 internal modelId = keccak256("eth-1-2-8h-v1");

    function setUp() public {
        weth = new MockERC20("WETH", "WETH", 18);
        usdc = new MockERC20("USDC", "USDC", 6);
        oracle = new MockOracle();
        reg = new InferenceRegistry(address(this), keeper, modelId);
        vault = new ArgonVault(address(this), keeper, address(reg), address(oracle), address(weth), address(usdc), 6);
        adapter = new MockPoolAdapter(address(weth), address(usdc));
        adapter.setVault(address(vault));
        vault.setPool(1, address(adapter), true);

        weth.mint(alice, 10 ether);
        usdc.mint(alice, 20_000e6);
        weth.mint(bob, 10 ether);
        usdc.mint(bob, 20_000e6);
        vm.startPrank(alice);
        weth.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(bob);
        weth.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _hash(uint64 hour, int256 a, int256 b, int256 c) internal view returns (bytes32) {
        return keccak256(abi.encode(hour, a, b, c, modelId));
    }

    function _submit(uint64 hour, int256 a, int256 b, int256 c) internal {
        vm.prank(keeper);
        reg.submit(hour, a, b, c, _hash(hour, a, b, c));
    }

    function _warmup() internal {
        for (uint64 i = 0; i < 9; i++) {
            _submit(1000 + i, 10, 20, 30);
        }
    }

    function testDepositMintsSharesAndWithdrawProRata() public {
        vm.prank(alice);
        vault.deposit(address(usdc), 1_000e6);
        vm.prank(bob);
        vault.deposit(address(usdc), 1_000e6);
        assertEq(vault.shareBalance(alice), vault.shareBalance(bob));

        uint256 aliceUsdc = usdc.balanceOf(alice);
        uint256 shares = vault.shareBalance(alice);
        vm.prank(alice);
        vault.withdraw(shares);
        assertEq(usdc.balanceOf(alice) - aliceUsdc, 1_000e6);
        assertEq(vault.shareBalance(alice), 0);
    }

    function testEnterThenExit() public {
        _warmup();
        vm.prank(alice);
        vault.deposit(address(usdc), 2_000e6);
        vm.prank(alice);
        vault.deposit(address(weth), 1 ether);

        _submit(1010, -40, -110, -150);
        vm.prank(keeper);
        vault.rebalance(1010, 1, ArgonVault.Action.ENTER, -60, 60, 0, 0);
        assertEq(vault.poolStatus(1), 1);

        _submit(1011, -30, -280, -150);
        vm.prank(keeper);
        vault.rebalance(1011, 1, ArgonVault.Action.EXIT, 0, 0, 0, 0);
        assertEq(vault.poolStatus(1), 0);
        assertGt(weth.balanceOf(address(vault)), 0);
        assertGt(usdc.balanceOf(address(vault)), 0);
    }

    function testRejectEnterWhenGateSaysExit() public {
        _warmup();
        vm.prank(alice);
        vault.deposit(address(usdc), 1_000e6);
        _submit(1010, -30, -280, -50);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ArgonVault.ActionMismatch.selector, 2, 1));
        vault.rebalance(1010, 1, ArgonVault.Action.ENTER, -60, 60, 0, 0);
    }

    function testRejectEnterDuringWarmup() public {
        _submit(1, 10, 20, 30);
        vm.prank(alice);
        vault.deposit(address(usdc), 1_000e6);
        vm.prank(keeper);
        vm.expectRevert(ArgonVault.Warmup.selector);
        vault.rebalance(1, 1, ArgonVault.Action.ENTER, -60, 60, 0, 0);
    }

    function testWithdrawFlattensLp() public {
        _warmup();
        vm.prank(alice);
        vault.deposit(address(usdc), 2_000e6);
        vm.prank(alice);
        vault.deposit(address(weth), 1 ether);
        _submit(1010, -40, -110, -150);
        vm.prank(keeper);
        vault.rebalance(1010, 1, ArgonVault.Action.ENTER, -60, 60, 0, 0);
        assertEq(vault.poolStatus(1), 1);

        uint256 shares = vault.shareBalance(alice);
        vm.prank(alice);
        vault.withdraw(shares);
        assertEq(vault.poolStatus(1), 0);
        assertEq(vault.shareBalance(alice), 0);
    }

    function testEnterCooldownAfterExit() public {
        _warmup();
        vm.prank(alice);
        vault.deposit(address(usdc), 2_000e6);
        vm.prank(alice);
        vault.deposit(address(weth), 1 ether);
        _submit(1010, -40, -110, -150);
        vm.prank(keeper);
        vault.rebalance(1010, 1, ArgonVault.Action.ENTER, -60, 60, 0, 0);
        _submit(1011, -30, -280, -150);
        vm.prank(keeper);
        vault.rebalance(1011, 1, ArgonVault.Action.EXIT, 0, 0, 0, 0);
        _submit(1012, -40, -110, -150);
        vm.prank(keeper);
        vm.expectRevert(ArgonVault.Cooldown.selector);
        vault.rebalance(1012, 1, ArgonVault.Action.ENTER, -60, 60, 0, 0);
    }

    function testRejectDoubleRebalanceSameHour() public {
        _warmup();
        vm.prank(alice);
        vault.deposit(address(usdc), 1_000e6);
        _submit(1010, -40, -110, -150);
        vm.startPrank(keeper);
        vault.rebalance(1010, 1, ArgonVault.Action.HOLD, 0, 0, 0, 0);
        vm.expectRevert(ArgonVault.AlreadyRebalanced.selector);
        vault.rebalance(1010, 1, ArgonVault.Action.HOLD, 0, 0, 0, 0);
        vm.stopPrank();
    }

    function testUngatedPoolReverts() public {
        MockPoolAdapter link = new MockPoolAdapter(address(weth), address(usdc));
        link.setVault(address(vault));
        vault.setPool(2, address(link), false);
        _warmup();
        _submit(1010, 0, 0, 0);
        vm.prank(keeper);
        vm.expectRevert(ArgonVault.PoolNotGated.selector);
        vault.rebalance(1010, 2, ArgonVault.Action.HOLD, 0, 0, 0, 0);
    }
}
