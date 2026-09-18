// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IEthUsdOracle {
    /// @return ETH/USD with 8 decimals (Chainlink style).
    function ethUsd8() external view returns (uint256);
    function assertHealthy() external view;
}
