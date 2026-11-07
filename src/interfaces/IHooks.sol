// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey} from "../types/PoolKey.sol";
import {BalanceDelta} from "../types/BalanceDelta.sol";
import {IPoolManager} from "./IPoolManager.sol";

interface IHooks {
    function beforeInitialize(address sender, PoolKey memory key, bytes memory hookData) external returns (bytes4);

    function afterInitialize(address sender, PoolKey memory key, bytes memory hookData) external returns (bytes4);

    function beforeAddLiquidity(
        address sender,
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes memory hookData
    ) external returns (bytes4);

    function afterAddLiquidity(
        address sender,
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        BalanceDelta delta,
        bytes memory hookData
    ) external returns (bytes4);

    function beforeRemoveLiquidity(
        address sender,
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes memory hookData
    ) external returns (bytes4);

    function afterRemoveLiquidity(
        address sender,
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        BalanceDelta delta,
        bytes memory hookData
    ) external returns (bytes4);

    function beforeSwap(
        address sender,
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        bytes memory hookData
    ) external returns (bytes4, uint24 overrideFee);

    function afterSwap(
        address sender,
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        BalanceDelta delta,
        bytes memory hookData
    ) external returns (bytes4);

    function beforeDonate(address sender, PoolKey memory key, uint256 amount0, uint256 amount1, bytes memory hookData)
        external
        returns (bytes4);

    function afterDonate(address sender, PoolKey memory key, uint256 amount0, uint256 amount1, bytes memory hookData)
        external
        returns (bytes4);
}
