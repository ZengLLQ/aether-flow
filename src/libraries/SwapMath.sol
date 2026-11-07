// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FullMath} from "./FullMath.sol";

library SwapMath {
    uint24 internal constant FEE_DENOMINATOR = 1_000_000; // 100% = 1,000,000 (1 bps = 100)

    error InsufficientReserves();
    error ExcessiveInput();
    error ZeroAmount();

    function computeSwap(uint256 reserveIn, uint256 reserveOut, int256 amountSpecified, uint24 fee)
        internal
        pure
        returns (uint256 amountIn, uint256 amountOut)
    {
        if (reserveIn == 0 || reserveOut == 0) revert InsufficientReserves();
        if (amountSpecified == 0) revert ZeroAmount();

        if (amountSpecified < 0) {
            // Exact input
            amountIn = uint256(-amountSpecified);
            uint256 amountInWithFee = FullMath.mulDiv(amountIn, (FEE_DENOMINATOR - fee), FEE_DENOMINATOR);
            amountOut = FullMath.mulDiv(amountInWithFee, reserveOut, reserveIn + amountInWithFee);
            if (amountOut == 0) revert ZeroAmount();
        } else {
            // Exact output
            amountOut = uint256(amountSpecified);
            if (amountOut >= reserveOut) revert InsufficientReserves();

            uint256 numerator = FullMath.mulDivRoundingUp(reserveIn, amountOut, reserveOut - amountOut);
            amountIn = FullMath.mulDivRoundingUp(numerator, FEE_DENOMINATOR, FEE_DENOMINATOR - fee);
        }
    }

    function computeLiquidityAmounts(uint256 reserve0, uint256 reserve1, uint128 totalLiquidity, int128 liquidityDelta)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (liquidityDelta > 0) {
            uint256 delta = uint256(int256(liquidityDelta));
            if (totalLiquidity == 0) {
                // Initial pool seeding
                amount0 = delta;
                amount1 = delta;
            } else {
                amount0 = FullMath.mulDivRoundingUp(delta, reserve0, totalLiquidity);
                amount1 = FullMath.mulDivRoundingUp(delta, reserve1, totalLiquidity);
            }
        } else if (liquidityDelta < 0) {
            uint256 delta = uint256(int256(-liquidityDelta));
            amount0 = FullMath.mulDiv(delta, reserve0, totalLiquidity);
            amount1 = FullMath.mulDiv(delta, reserve1, totalLiquidity);
        }
    }
}
