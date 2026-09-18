// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library ChainConfig {
    uint256 constant ARB_CHAIN_ID = 42161;
    uint256 constant RH_CHAIN_ID = 4663;

    // Arbitrum One
    address constant ARB_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant ARB_NPM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant ARB_ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address constant ARB_SEQUENCER = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    uint24 constant ARB_FEE = 500;
    uint8 constant ARB_POOL_ID = 1;

    // Robinhood Chain
    address constant RH_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant RH_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant RH_NPM = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address constant RH_ETH_USD = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    uint24 constant RH_FEE = 500;
    uint8 constant RH_POOL_ID = 4;
}
