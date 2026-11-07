// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IHooks} from "../interfaces/IHooks.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {PoolKey} from "../types/PoolKey.sol";
import {BalanceDelta} from "../types/BalanceDelta.sol";

library Hooks {
    uint16 internal constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    uint16 internal constant AFTER_INITIALIZE_FLAG = 1 << 12;
    uint16 internal constant BEFORE_ADD_LIQUIDITY_FLAG = 1 << 11;
    uint16 internal constant AFTER_ADD_LIQUIDITY_FLAG = 1 << 10;
    uint16 internal constant BEFORE_REMOVE_LIQUIDITY_FLAG = 1 << 9;
    uint16 internal constant AFTER_REMOVE_LIQUIDITY_FLAG = 1 << 8;
    uint16 internal constant BEFORE_SWAP_FLAG = 1 << 7;
    uint16 internal constant AFTER_SWAP_FLAG = 1 << 6;
    uint16 internal constant BEFORE_DONATE_FLAG = 1 << 5;
    uint16 internal constant AFTER_DONATE_FLAG = 1 << 4;

    uint16 internal constant ALL_HOOK_MASK = 0x3FF0;

    error HookAddressNotValid(address hook);
    error HookCallFailed();
    error InvalidHookResponse();

    function hasPermission(address hook, uint16 flag) internal pure returns (bool) {
        return (uint16(uint160(hook)) & flag) != 0;
    }

    function validateHookPermissions(address hook, uint16 expectedFlags) internal pure {
        if (hook == address(0)) {
            if (expectedFlags != 0) revert HookAddressNotValid(hook);
            return;
        }
        uint16 actualFlags = uint16(uint160(hook)) & ALL_HOOK_MASK;
        if (actualFlags != expectedFlags) revert HookAddressNotValid(hook);
    }

    function callBeforeInitialize(address hook, address sender, PoolKey memory key, bytes memory hookData) internal {
        if (!hasPermission(hook, BEFORE_INITIALIZE_FLAG)) return;
        bytes4 selector = IHooks(hook).beforeInitialize(sender, key, hookData);
        if (selector != IHooks.beforeInitialize.selector) revert InvalidHookResponse();
    }

    function callAfterInitialize(address hook, address sender, PoolKey memory key, bytes memory hookData) internal {
        if (!hasPermission(hook, AFTER_INITIALIZE_FLAG)) return;
        bytes4 selector = IHooks(hook).afterInitialize(sender, key, hookData);
        if (selector != IHooks.afterInitialize.selector) revert InvalidHookResponse();
    }

    function callBeforeAddLiquidity(
        address hook,
        address sender,
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes memory hookData
    ) internal {
        if (!hasPermission(hook, BEFORE_ADD_LIQUIDITY_FLAG)) return;
        bytes4 selector = IHooks(hook).beforeAddLiquidity(sender, key, params, hookData);
        if (selector != IHooks.beforeAddLiquidity.selector) revert InvalidHookResponse();
    }

    function callAfterAddLiquidity(
        address hook,
        address sender,
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        BalanceDelta delta,
        bytes memory hookData
    ) internal {
        if (!hasPermission(hook, AFTER_ADD_LIQUIDITY_FLAG)) return;
        bytes4 selector = IHooks(hook).afterAddLiquidity(sender, key, params, delta, hookData);
        if (selector != IHooks.afterAddLiquidity.selector) revert InvalidHookResponse();
    }

    function callBeforeRemoveLiquidity(
        address hook,
        address sender,
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes memory hookData
    ) internal {
        if (!hasPermission(hook, BEFORE_REMOVE_LIQUIDITY_FLAG)) return;
        bytes4 selector = IHooks(hook).beforeRemoveLiquidity(sender, key, params, hookData);
        if (selector != IHooks.beforeRemoveLiquidity.selector) revert InvalidHookResponse();
    }

    function callAfterRemoveLiquidity(
        address hook,
        address sender,
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        BalanceDelta delta,
        bytes memory hookData
    ) internal {
        if (!hasPermission(hook, AFTER_REMOVE_LIQUIDITY_FLAG)) return;
        bytes4 selector = IHooks(hook).afterRemoveLiquidity(sender, key, params, delta, hookData);
        if (selector != IHooks.afterRemoveLiquidity.selector) revert InvalidHookResponse();
    }

    function callBeforeSwap(
        address hook,
        address sender,
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        bytes memory hookData
    ) internal returns (uint24 overrideFee) {
        if (!hasPermission(hook, BEFORE_SWAP_FLAG)) return 0;
        (bytes4 selector, uint24 fee) = IHooks(hook).beforeSwap(sender, key, params, hookData);
        if (selector != IHooks.beforeSwap.selector) revert InvalidHookResponse();
        return fee;
    }

    function callAfterSwap(
        address hook,
        address sender,
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        BalanceDelta delta,
        bytes memory hookData
    ) internal {
        if (!hasPermission(hook, AFTER_SWAP_FLAG)) return;
        bytes4 selector = IHooks(hook).afterSwap(sender, key, params, delta, hookData);
        if (selector != IHooks.afterSwap.selector) revert InvalidHookResponse();
    }

    function callBeforeDonate(
        address hook,
        address sender,
        PoolKey memory key,
        uint256 amount0,
        uint256 amount1,
        bytes memory hookData
    ) internal {
        if (!hasPermission(hook, BEFORE_DONATE_FLAG)) return;
        bytes4 selector = IHooks(hook).beforeDonate(sender, key, amount0, amount1, hookData);
        if (selector != IHooks.beforeDonate.selector) revert InvalidHookResponse();
    }

    function callAfterDonate(
        address hook,
        address sender,
        PoolKey memory key,
        uint256 amount0,
        uint256 amount1,
        bytes memory hookData
    ) internal {
        if (!hasPermission(hook, AFTER_DONATE_FLAG)) return;
        bytes4 selector = IHooks(hook).afterDonate(sender, key, amount0, amount1, hookData);
        if (selector != IHooks.afterDonate.selector) revert InvalidHookResponse();
    }
}
