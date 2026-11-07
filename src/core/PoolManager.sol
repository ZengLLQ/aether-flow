// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {IEIP6909} from "../interfaces/IEIP6909.sol";
import {IUnlockCallback} from "../interfaces/IUnlockCallback.sol";
import {Currency} from "../types/Currency.sol";
import {PoolKey, PoolId} from "../types/PoolKey.sol";
import {BalanceDelta, toBalanceDelta} from "../types/BalanceDelta.sol";
import {TransientStorage} from "../libraries/TransientStorage.sol";
import {Hooks} from "../libraries/Hooks.sol";
import {SwapMath} from "../libraries/SwapMath.sol";
import {SafeCast} from "../libraries/SafeCast.sol";

/// @title PoolManager
/// @notice Core singleton managing multiple liquidity pools with EIP-1153 transient flash accounting & dynamic hooks
contract PoolManager is IPoolManager, IEIP6909 {
    using SafeCast for uint256;
    using SafeCast for int256;

    mapping(PoolId => PoolState) internal _pools;
    mapping(Currency => uint256) public totalReserves;

    // EIP-6909 state
    mapping(address => mapping(uint256 => uint256)) public override balanceOf;
    mapping(address => mapping(address => mapping(uint256 => uint256))) public override allowance;
    mapping(address => mapping(address => bool)) public override isOperator;

    modifier onlyUnlocked() {
        if (!TransientStorage.isLocked()) revert UnauthorizedUnlock();
        _;
    }

    // --- Core Lifecycle ---

    function initialize(PoolKey memory key, uint24 fee, bytes memory hookData) external override returns (PoolId id) {
        if (Currency.unwrap(key.currency0) >= Currency.unwrap(key.currency1)) {
            revert CurrenciesOutOfOrder();
        }

        id = key.toId();
        if (_pools[id].initialized) revert PoolAlreadyInitialized();

        Hooks.callBeforeInitialize(key.hooks, msg.sender, key, hookData);

        _pools[id] = PoolState({reserve0: 0, reserve1: 0, liquidity: 0, fee: fee, initialized: true});

        emit PoolInitialized(id, key.currency0, key.currency1, fee, key.tickSpacing, key.hooks);

        Hooks.callAfterInitialize(key.hooks, msg.sender, key, hookData);
    }

    function unlock(bytes calldata data) external override returns (bytes memory result) {
        TransientStorage.setReentrancyLock();

        result = IUnlockCallback(msg.sender).unlockCallback(data);

        uint256 nonzeroCount = TransientStorage.getNonzeroDeltaCount(msg.sender);
        if (nonzeroCount != 0) {
            revert NonzeroDeltasRemaining(msg.sender, nonzeroCount);
        }

        TransientStorage.clearReentrancyLock();
    }

    // --- Pool Operations ---

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData)
        external
        override
        onlyUnlocked
        returns (BalanceDelta delta)
    {
        PoolId id = key.toId();
        PoolState storage pool = _pools[id];
        if (!pool.initialized) revert PoolNotInitialized();

        uint24 effectiveFee = Hooks.callBeforeSwap(key.hooks, msg.sender, key, params, hookData);
        if (effectiveFee == 0) {
            effectiveFee = pool.fee;
        }

        uint256 amountIn;
        uint256 amountOut;

        if (params.zeroForOne) {
            (amountIn, amountOut) =
                SwapMath.computeSwap(pool.reserve0, pool.reserve1, params.amountSpecified, effectiveFee);

            pool.reserve0 += amountIn;
            pool.reserve1 -= amountOut;

            delta = toBalanceDelta(-amountIn.toInt128(), amountOut.toInt128());
            TransientStorage.applyDelta(msg.sender, key.currency0, -amountIn.toInt128());
            TransientStorage.applyDelta(msg.sender, key.currency1, amountOut.toInt128());
        } else {
            (amountIn, amountOut) =
                SwapMath.computeSwap(pool.reserve1, pool.reserve0, params.amountSpecified, effectiveFee);

            pool.reserve1 += amountIn;
            pool.reserve0 -= amountOut;

            delta = toBalanceDelta(amountOut.toInt128(), -amountIn.toInt128());
            TransientStorage.applyDelta(msg.sender, key.currency0, amountOut.toInt128());
            TransientStorage.applyDelta(msg.sender, key.currency1, -amountIn.toInt128());
        }

        emit Swap(id, msg.sender, delta.amount0(), delta.amount1(), pool.reserve0, pool.reserve1, effectiveFee);

        Hooks.callAfterSwap(key.hooks, msg.sender, key, params, delta, hookData);
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes memory hookData)
        external
        override
        onlyUnlocked
        returns (BalanceDelta delta)
    {
        PoolId id = key.toId();
        PoolState storage pool = _pools[id];
        if (!pool.initialized) revert PoolNotInitialized();
        if (params.liquidityDelta == 0) revert ZeroLiquidity();

        if (params.liquidityDelta > 0) {
            Hooks.callBeforeAddLiquidity(key.hooks, msg.sender, key, params, hookData);
        } else {
            Hooks.callBeforeRemoveLiquidity(key.hooks, msg.sender, key, params, hookData);
        }

        (uint256 amount0, uint256 amount1) =
            SwapMath.computeLiquidityAmounts(pool.reserve0, pool.reserve1, pool.liquidity, params.liquidityDelta);

        if (params.liquidityDelta > 0) {
            uint128 addedLiquidity = uint128(uint256(int256(params.liquidityDelta)));
            pool.reserve0 += amount0;
            pool.reserve1 += amount1;
            pool.liquidity += addedLiquidity;

            delta = toBalanceDelta(-amount0.toInt128(), -amount1.toInt128());
            TransientStorage.applyDelta(msg.sender, key.currency0, -amount0.toInt128());
            TransientStorage.applyDelta(msg.sender, key.currency1, -amount1.toInt128());

            emit ModifyLiquidity(id, msg.sender, params.liquidityDelta, delta);

            Hooks.callAfterAddLiquidity(key.hooks, msg.sender, key, params, delta, hookData);
        } else {
            uint128 removedLiquidity = uint128(uint256(int256(-params.liquidityDelta)));
            if (removedLiquidity > pool.liquidity) revert InsufficientReserves();

            pool.reserve0 -= amount0;
            pool.reserve1 -= amount1;
            pool.liquidity -= removedLiquidity;

            delta = toBalanceDelta(amount0.toInt128(), amount1.toInt128());
            TransientStorage.applyDelta(msg.sender, key.currency0, amount0.toInt128());
            TransientStorage.applyDelta(msg.sender, key.currency1, amount1.toInt128());

            emit ModifyLiquidity(id, msg.sender, params.liquidityDelta, delta);

            Hooks.callAfterRemoveLiquidity(key.hooks, msg.sender, key, params, delta, hookData);
        }
    }

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1, bytes memory hookData)
        external
        override
        onlyUnlocked
        returns (BalanceDelta delta)
    {
        PoolId id = key.toId();
        PoolState storage pool = _pools[id];
        if (!pool.initialized) revert PoolNotInitialized();
        if (pool.liquidity == 0) revert ZeroLiquidity();

        Hooks.callBeforeDonate(key.hooks, msg.sender, key, amount0, amount1, hookData);

        pool.reserve0 += amount0;
        pool.reserve1 += amount1;

        delta = toBalanceDelta(-amount0.toInt128(), -amount1.toInt128());
        TransientStorage.applyDelta(msg.sender, key.currency0, -amount0.toInt128());
        TransientStorage.applyDelta(msg.sender, key.currency1, -amount1.toInt128());

        emit Donate(id, msg.sender, amount0, amount1);

        Hooks.callAfterDonate(key.hooks, msg.sender, key, amount0, amount1, hookData);
    }

    // --- Settlement & Flash Accounting ---

    function settle(Currency currency) external payable override onlyUnlocked returns (uint256 paid) {
        if (currency.isNative()) {
            paid = msg.value;
        } else {
            uint256 actualBalance = currency.balanceOfSelf();
            uint256 expectedReserve = totalReserves[currency];
            if (actualBalance > expectedReserve) {
                paid = actualBalance - expectedReserve;
            }
        }

        if (paid > 0) {
            totalReserves[currency] += paid;
            TransientStorage.applyDelta(msg.sender, currency, paid.toInt128());
            emit Settle(currency, msg.sender, paid);
        }
    }

    function settleFrom(Currency currency, address from, uint256 amount) external onlyUnlocked returns (uint256) {
        if (amount == 0) return 0;
        totalReserves[currency] += amount;
        TransientStorage.applyDelta(msg.sender, currency, amount.toInt128());
        emit Settle(currency, msg.sender, amount);
        currency.transferFrom(from, address(this), amount);
        return amount;
    }

    function take(Currency currency, address to, uint256 amount) external override onlyUnlocked {
        if (amount == 0) return;
        totalReserves[currency] -= amount;
        TransientStorage.applyDelta(msg.sender, currency, -amount.toInt128());
        emit Take(currency, to, amount);
        currency.transfer(to, amount);
    }

    // --- EIP-6909 Integration ---

    function mint6909(Currency currency, address to, uint256 amount) external onlyUnlocked {
        if (amount == 0) return;
        TransientStorage.applyDelta(msg.sender, currency, -amount.toInt128());
        uint256 id = uint256(uint160(Currency.unwrap(currency)));
        balanceOf[to][id] += amount;
        emit Transfer(msg.sender, address(0), to, id, amount);
    }

    function burn6909(Currency currency, uint256 amount) external onlyUnlocked {
        if (amount == 0) return;
        uint256 id = uint256(uint160(Currency.unwrap(currency)));
        balanceOf[msg.sender][id] -= amount;
        TransientStorage.applyDelta(msg.sender, currency, amount.toInt128());
        emit Transfer(msg.sender, msg.sender, address(0), id, amount);
    }

    // --- EIP-6909 Standard Methods ---

    function transfer(address receiver, uint256 id, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender][id] -= amount;
        balanceOf[receiver][id] += amount;
        emit Transfer(msg.sender, msg.sender, receiver, id, amount);
        return true;
    }

    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        external
        override
        returns (bool)
    {
        if (msg.sender != sender && !isOperator[sender][msg.sender]) {
            uint256 currentAllowance = allowance[sender][msg.sender][id];
            if (currentAllowance != type(uint256).max) {
                allowance[sender][msg.sender][id] = currentAllowance - amount;
            }
        }
        balanceOf[sender][id] -= amount;
        balanceOf[receiver][id] += amount;
        emit Transfer(msg.sender, sender, receiver, id, amount);
        return true;
    }

    function approve(address spender, uint256 id, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender][id] = amount;
        emit Approval(msg.sender, spender, id, amount);
        return true;
    }

    function setOperator(address operator, bool approved) external override returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    // --- View Methods ---

    function getPool(PoolId id) external view override returns (PoolState memory) {
        return _pools[id];
    }

    function getCurrencyDelta(address target, Currency currency) external view override returns (int256) {
        return TransientStorage.getDelta(target, currency);
    }

    receive() external payable {}
}
