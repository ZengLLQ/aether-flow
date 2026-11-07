// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {PoolManager} from "../src/core/PoolManager.sol";
import {AetherRouter} from "../src/periphery/AetherRouter.sol";
import {VolatilityDynamicFeeHook} from "../src/hooks/VolatilityDynamicFeeHook.sol";
import {TwammHook} from "../src/hooks/TwammHook.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {Currency} from "../src/types/Currency.sol";
import {PoolKey, PoolId} from "../src/types/PoolKey.sol";
import {Hooks} from "../src/libraries/Hooks.sol";

contract DeployAetherFlow is Script {
    function run() external {
        vm.startBroadcast();

        console2.log("=== Deploying AetherFlow Protocol ===");

        // 1. Deploy Core Singleton PoolManager
        PoolManager manager = new PoolManager();
        console2.log("PoolManager deployed at:", address(manager));

        // 2. Deploy Periphery Router
        AetherRouter router = new AetherRouter(manager);
        console2.log("AetherRouter deployed at:", address(router));

        // 3. Deploy Mocks for Demonstration
        MockERC20 token0 = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 token1 = new MockERC20("Wrapped Ether", "WETH", 18);

        address c0 = address(token0) < address(token1) ? address(token0) : address(token1);
        address c1 = address(token0) < address(token1) ? address(token1) : address(token0);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0), currency1: Currency.wrap(c1), fee: 3000, tickSpacing: 60, hooks: address(0)
        });

        PoolId id = manager.initialize(key, 3000, "");
        console2.log("Standard Pool initialized with ID:");
        console2.logBytes32(PoolId.unwrap(id));

        console2.log("=== AetherFlow Deployment Completed Successfully ===");

        vm.stopBroadcast();
    }
}
