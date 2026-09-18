// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {InferenceRegistry} from "../src/InferenceRegistry.sol";
import {ArgonVault} from "../src/ArgonVault.sol";
import {UniswapV3Adapter} from "../src/adapters/UniswapV3Adapter.sol";
import {ChainlinkEthOracle} from "../src/oracle/ChainlinkEthOracle.sol";
import {ChainConfig} from "./ChainConfig.sol";
import {DeployBase} from "./DeployBase.sol";

contract DeployArbitrum is DeployBase {
    function run() external {
        uint256 pk = loadPrivateKey();
        address keeper = vm.envAddress("KEEPER");
        bytes32 modelId = keccak256(bytes(vm.envOr("MODEL_ID", string("eth-1-2-8h-v1"))));
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        InferenceRegistry reg = new InferenceRegistry(deployer, keeper, modelId);
        ChainlinkEthOracle oracle = new ChainlinkEthOracle(ChainConfig.ARB_ETH_USD, ChainConfig.ARB_SEQUENCER, 3600);
        ArgonVault vault = new ArgonVault(
            deployer, keeper, address(reg), address(oracle), ChainConfig.ARB_WETH, ChainConfig.ARB_USDC, 6
        );
        UniswapV3Adapter adapter = new UniswapV3Adapter(
            address(vault), ChainConfig.ARB_NPM, ChainConfig.ARB_WETH, ChainConfig.ARB_USDC, ChainConfig.ARB_FEE
        );
        vault.setPool(ChainConfig.ARB_POOL_ID, address(adapter), true);
        vm.stopBroadcast();

        console2.log("InferenceRegistry", address(reg));
        console2.log("ChainlinkEthOracle", address(oracle));
        console2.log("ArgonVault", address(vault));
        console2.log("UniswapV3Adapter", address(adapter));
    }
}
