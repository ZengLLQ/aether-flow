// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Currency} from "../types/Currency.sol";
import {PoolKey, PoolId} from "../types/PoolKey.sol";
import {BalanceDelta} from "../types/BalanceDelta.sol";

interface IPoolManager {
    struct ModifyLiquidityParams {
        int128 liquidityDelta;
        bytes32 salt;
    }

    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified; // negative = exact input, positive = exact output
        uint160 sqrtPriceLimitX96;
    }

    struct PoolState {
        uint256 reserve0;
        uint256 reserve1;
        uint128 liquidity;
        uint24 fee;
        bool initialized;
    }

    event PoolInitialized(
        PoolId indexed id,
        Currency indexed currency0,
        Currency indexed currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    );

    event ModifyLiquidity(PoolId indexed id, address indexed sender, int128 liquidityDelta, BalanceDelta delta);

    event Swap(
        PoolId indexed id,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint256 reserve0,
        uint256 reserve1,
        uint24 fee
    );

    event Settle(Currency indexed currency, address indexed sender, uint256 amount);
    event Take(Currency indexed currency, address indexed recipient, uint256 amount);
    event Donate(PoolId indexed id, address indexed sender, uint256 amount0, uint256 amount1);

    error PoolAlreadyInitialized();
    error PoolNotInitialized();
    error CurrenciesOutOfOrder();
    error ZeroLiquidity();
    error InsufficientReserves();
    error InvalidPriceLimit();
    error DeltaNotZero(address sender, Currency currency, int256 delta);
    error NonzeroDeltasRemaining(address sender, uint256 count);
    error UnauthorizedUnlock();
    error HookAddressNotValid(address hook);
    error HookCallFailed();
    error InsufficientSettlement(Currency currency, uint256 expected, uint256 actual);

    function initialize(PoolKey memory key, uint24 fee, bytes memory hookData) external returns (PoolId);
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData) external returns (BalanceDelta);
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        returns (BalanceDelta);
    function settle(Currency currency) external payable returns (uint256 paid);
    function take(Currency currency, address to, uint256 amount) external;
    function donate(PoolKey memory key, uint256 amount0, uint256 amount1, bytes memory hookData)
        external
        returns (BalanceDelta);

    function getPool(PoolId id) external view returns (PoolState memory);
    function getCurrencyDelta(address target, Currency currency) external view returns (int256);
}
