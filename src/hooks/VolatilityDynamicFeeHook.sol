// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseHook} from "./BaseHook.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {PoolKey, PoolId} from "../types/PoolKey.sol";
import {BalanceDelta} from "../types/BalanceDelta.sol";
import {Hooks} from "../libraries/Hooks.sol";
import {FullMath} from "../libraries/FullMath.sol";

/// @title VolatilityDynamicFeeHook
/// @notice Dynamically adjusts pool swap fees according to an Exponential Weighted Moving Average (EWMA) volatility metric
contract VolatilityDynamicFeeHook is BaseHook {
    uint24 public constant BASE_FEE = 3000; // 0.30% (30 bps in 1M scale = 3000)
    uint24 public constant MAX_FEE = 30000; // 3.00% (300 bps in 1M scale = 30000)
    uint256 public constant WAD = 1e18;
    uint256 public constant ALPHA = 2000; // 20% decay weight (in bps: 2000/10000)
    uint256 public constant BPS_DENOMINATOR = 10000;

    struct VolatilityState {
        uint256 lastPrice; // reserve1 * WAD / reserve0
        uint256 ewmaVariance;
        uint256 lastTimestamp;
    }

    mapping(PoolId => VolatilityState) public poolVolatility;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (uint16) {
        return Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
    }

    function beforeSwap(address, PoolKey memory key, IPoolManager.SwapParams memory, bytes memory)
        external
        override
        onlyPoolManager
        returns (bytes4, uint24 overrideFee)
    {
        PoolId id = key.toId();
        VolatilityState memory state = poolVolatility[id];

        if (state.lastPrice == 0 || state.ewmaVariance == 0) {
            return (this.beforeSwap.selector, BASE_FEE);
        }

        // Additional fee proportional to square root or linear approximation of variance
        // fee = BASE_FEE + min(MAX_FEE - BASE_FEE, variance / factor)
        uint256 dynamicAddition = FullMath.mulDiv(state.ewmaVariance, 100_000, WAD);
        uint24 totalFee =
            BASE_FEE + uint24(dynamicAddition > (MAX_FEE - BASE_FEE) ? (MAX_FEE - BASE_FEE) : dynamicAddition);

        return (this.beforeSwap.selector, totalFee);
    }

    function afterSwap(address, PoolKey memory key, IPoolManager.SwapParams memory, BalanceDelta, bytes memory)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        PoolId id = key.toId();
        IPoolManager.PoolState memory pool = poolManager.getPool(id);

        if (pool.reserve0 == 0 || pool.reserve1 == 0) {
            return this.afterSwap.selector;
        }

        uint256 currentPrice = FullMath.mulDiv(pool.reserve1, WAD, pool.reserve0);
        VolatilityState storage state = poolVolatility[id];

        if (state.lastPrice != 0) {
            uint256 priceDiff =
                currentPrice > state.lastPrice ? currentPrice - state.lastPrice : state.lastPrice - currentPrice;

            uint256 priceReturn = FullMath.mulDiv(priceDiff, WAD, state.lastPrice);
            uint256 squaredReturn = FullMath.mulDiv(priceReturn, priceReturn, WAD);

            // EWMA update: variance = alpha * return^2 + (1 - alpha) * old_variance
            uint256 term1 = FullMath.mulDiv(squaredReturn, ALPHA, BPS_DENOMINATOR);
            uint256 term2 = FullMath.mulDiv(state.ewmaVariance, BPS_DENOMINATOR - ALPHA, BPS_DENOMINATOR);
            state.ewmaVariance = term1 + term2;
        }

        state.lastPrice = currentPrice;
        state.lastTimestamp = block.timestamp;

        return this.afterSwap.selector;
    }
}
