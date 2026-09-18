// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolAdapter} from "../interfaces/IPoolAdapter.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransfer} from "../utils/SafeTransfer.sol";

contract MockPoolAdapter is IPoolAdapter {
    using SafeTransfer for address;

    address public vault;
    address public immutable tokenA;
    address public immutable tokenB;
    bool public inPosition;
    uint256 public principalA;
    uint256 public principalB;

    constructor(address tokenA_, address tokenB_) {
        tokenA = tokenA_;
        tokenB = tokenB_;
    }

    function setVault(address v) external {
        vault = v;
    }

    function amounts() external view returns (uint256, uint256) {
        return (principalA, principalB);
    }

    function enter(int24, int24, uint256, uint256) external {
        require(msg.sender == vault, "not vault");
        require(!inPosition, "in");
        uint256 a = IERC20(tokenA).balanceOf(vault);
        uint256 b = IERC20(tokenB).balanceOf(vault);
        if (a != 0) tokenA.pull(vault, a);
        if (b != 0) tokenB.pull(vault, b);
        principalA = a;
        principalB = b;
        inPosition = true;
    }

    function exit(uint256, uint256) external {
        require(msg.sender == vault, "not vault");
        require(inPosition, "out");
        inPosition = false;
        uint256 a = principalA;
        uint256 b = principalB;
        principalA = 0;
        principalB = 0;
        if (a != 0) tokenA.push(vault, a);
        if (b != 0) tokenB.push(vault, b);
    }

    function harvest() external view {
        require(msg.sender == vault, "not vault");
    }
}
