// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../interfaces/IUnlockCallback.sol";
import {Currency} from "../types/Currency.sol";
import {PoolKey} from "../types/PoolKey.sol";
import {BalanceDelta} from "../types/BalanceDelta.sol";
import {SafeCast} from "../libraries/SafeCast.sol";

/// @title AetherRouter
/// @notice Periphery routing contract demonstrating flash-accounting single and multi-hop swaps
contract AetherRouter is IUnlockCallback {
    using SafeCast for uint256;
    using SafeCast for int256;

    IPoolManager public immutable poolManager;

    enum ActionType {
        SWAP_SINGLE,
        SWAP_MULTIHOP,
        ADD_LIQUIDITY,
        REMOVE_LIQUIDITY
    }

    struct SwapSingleParams {
        PoolKey key;
        bool zeroForOne;
        uint256 amountIn;
        uint256 amountOutMinimum;
        address recipient;
        bytes hookData;
    }

    struct MultiHopStep {
        PoolKey key;
        bool zeroForOne;
        bytes hookData;
    }

    struct SwapMultiHopParams {
        MultiHopStep[] steps;
        Currency currencyIn;
        Currency currencyOut;
        uint256 amountIn;
        uint256 amountOutMinimum;
        address recipient;
    }

    struct AddLiquidityParams {
        PoolKey key;
        uint128 liquidity;
        address recipient;
        bytes hookData;
    }

    struct RemoveLiquidityParams {
        PoolKey key;
        uint128 liquidity;
        address recipient;
        bytes hookData;
    }

    error SlippageExceeded(uint256 actual, uint256 minimum);
    error UnauthorizedCallback();

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
    }

    function swapExactInputSingle(SwapSingleParams calldata params) external payable returns (uint256 amountOut) {
        bytes memory data = abi.encode(ActionType.SWAP_SINGLE, msg.sender, params);
        bytes memory returnData = poolManager.unlock(data);
        amountOut = abi.decode(returnData, (uint256));
    }

    function swapExactInputMultiHop(SwapMultiHopParams calldata params) external payable returns (uint256 amountOut) {
        bytes memory data = abi.encode(ActionType.SWAP_MULTIHOP, msg.sender, params);
        bytes memory returnData = poolManager.unlock(data);
        amountOut = abi.decode(returnData, (uint256));
    }

    function addLiquidity(AddLiquidityParams calldata params) external payable returns (BalanceDelta delta) {
        bytes memory data = abi.encode(ActionType.ADD_LIQUIDITY, msg.sender, params);
        bytes memory returnData = poolManager.unlock(data);
        delta = abi.decode(returnData, (BalanceDelta));
    }

    function removeLiquidity(RemoveLiquidityParams calldata params) external returns (BalanceDelta delta) {
        bytes memory data = abi.encode(ActionType.REMOVE_LIQUIDITY, msg.sender, params);
        bytes memory returnData = poolManager.unlock(data);
        delta = abi.decode(returnData, (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();

        (ActionType action, address caller) = abi.decode(data, (ActionType, address));

        if (action == ActionType.SWAP_SINGLE) {
            (,, SwapSingleParams memory params) = abi.decode(data, (ActionType, address, SwapSingleParams));
            return _executeSwapSingle(caller, params);
        } else if (action == ActionType.SWAP_MULTIHOP) {
            (,, SwapMultiHopParams memory params) = abi.decode(data, (ActionType, address, SwapMultiHopParams));
            return _executeSwapMultiHop(caller, params);
        } else if (action == ActionType.ADD_LIQUIDITY) {
            (,, AddLiquidityParams memory params) = abi.decode(data, (ActionType, address, AddLiquidityParams));
            return _executeAddLiquidity(caller, params);
        } else {
            (,, RemoveLiquidityParams memory params) = abi.decode(data, (ActionType, address, RemoveLiquidityParams));
            return _executeRemoveLiquidity(caller, params);
        }
    }

    function _executeSwapSingle(address caller, SwapSingleParams memory params) internal returns (bytes memory) {
        BalanceDelta delta = poolManager.swap(
            params.key,
            IPoolManager.SwapParams({
                zeroForOne: params.zeroForOne, amountSpecified: -params.amountIn.toInt256(), sqrtPriceLimitX96: 0
            }),
            params.hookData
        );

        uint256 amountOut;
        if (params.zeroForOne) {
            amountOut = uint256(int256(delta.amount1()));
            if (amountOut < params.amountOutMinimum) {
                revert SlippageExceeded(amountOut, params.amountOutMinimum);
            }

            // Transfer input token from caller to poolManager
            params.key.currency0.transferFrom(caller, address(poolManager), params.amountIn);
            poolManager.settle(params.key.currency0);

            // Take output token to recipient
            poolManager.take(params.key.currency1, params.recipient, amountOut);
        } else {
            amountOut = uint256(int256(delta.amount0()));
            if (amountOut < params.amountOutMinimum) {
                revert SlippageExceeded(amountOut, params.amountOutMinimum);
            }

            params.key.currency1.transferFrom(caller, address(poolManager), params.amountIn);
            poolManager.settle(params.key.currency1);

            poolManager.take(params.key.currency0, params.recipient, amountOut);
        }

        return abi.encode(amountOut);
    }

    function _executeSwapMultiHop(address caller, SwapMultiHopParams memory params) internal returns (bytes memory) {
        uint256 intermediateAmount = params.amountIn;

        for (uint256 i = 0; i < params.steps.length; i++) {
            MultiHopStep memory step = params.steps[i];
            BalanceDelta stepDelta = poolManager.swap(
                step.key,
                IPoolManager.SwapParams({
                    zeroForOne: step.zeroForOne, amountSpecified: -intermediateAmount.toInt256(), sqrtPriceLimitX96: 0
                }),
                step.hookData
            );

            if (step.zeroForOne) {
                intermediateAmount = uint256(int256(stepDelta.amount1()));
            } else {
                intermediateAmount = uint256(int256(stepDelta.amount0()));
            }
        }

        if (intermediateAmount < params.amountOutMinimum) {
            revert SlippageExceeded(intermediateAmount, params.amountOutMinimum);
        }

        // Only settle input currency
        params.currencyIn.transferFrom(caller, address(poolManager), params.amountIn);
        poolManager.settle(params.currencyIn);

        // Only take output currency
        poolManager.take(params.currencyOut, params.recipient, intermediateAmount);

        return abi.encode(intermediateAmount);
    }

    function _executeAddLiquidity(address caller, AddLiquidityParams memory params) internal returns (bytes memory) {
        BalanceDelta delta = poolManager.modifyLiquidity(
            params.key,
            IPoolManager.ModifyLiquidityParams({
                liquidityDelta: uint256(params.liquidity).toInt128(), salt: bytes32(0)
            }),
            params.hookData
        );

        uint256 amount0 = uint256(int256(-delta.amount0()));
        uint256 amount1 = uint256(int256(-delta.amount1()));

        if (amount0 > 0) {
            params.key.currency0.transferFrom(caller, address(poolManager), amount0);
            poolManager.settle(params.key.currency0);
        }

        if (amount1 > 0) {
            params.key.currency1.transferFrom(caller, address(poolManager), amount1);
            poolManager.settle(params.key.currency1);
        }

        return abi.encode(delta);
    }

    function _executeRemoveLiquidity(address, RemoveLiquidityParams memory params) internal returns (bytes memory) {
        BalanceDelta delta = poolManager.modifyLiquidity(
            params.key,
            IPoolManager.ModifyLiquidityParams({
                liquidityDelta: -uint256(params.liquidity).toInt128(), salt: bytes32(0)
            }),
            params.hookData
        );

        uint256 amount0 = uint256(int256(delta.amount0()));
        uint256 amount1 = uint256(int256(delta.amount1()));

        if (amount0 > 0) {
            poolManager.take(params.key.currency0, params.recipient, amount0);
        }

        if (amount1 > 0) {
            poolManager.take(params.key.currency1, params.recipient, amount1);
        }

        return abi.encode(delta);
    }

    receive() external payable {}
}
