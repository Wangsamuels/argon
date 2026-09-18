// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPoolAdapter {
    function tokenA() external view returns (address);
    function tokenB() external view returns (address);
    function enter(int24 tickLower, int24 tickUpper, uint256 amountAMin, uint256 amountBMin) external;
    function exit(uint256 amountAMin, uint256 amountBMin) external;
    function harvest() external;
    function inPosition() external view returns (bool);
    function amounts() external view returns (uint256 amountA, uint256 amountB);
}
