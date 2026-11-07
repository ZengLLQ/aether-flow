// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IHooks} from "../interfaces/IHooks.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {PoolKey} from "../types/PoolKey.sol";
import {BalanceDelta} from "../types/BalanceDelta.sol";
import {Hooks} from "../libraries/Hooks.sol";

abstract contract BaseHook is IHooks {
    IPoolManager public immutable poolManager;

    error NotPoolManager();
    error HookAddressNotValid();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        _validateHookPermissions();
    }

    function getHookPermissions() public pure virtual returns (uint16);

    function _validateHookPermissions() internal view virtual {
        uint16 expected = getHookPermissions();
        if (expected == 0) return;
        uint16 actual = uint16(uint160(address(this))) & Hooks.ALL_HOOK_MASK;
        if (uint160(address(this)) <= 0xFFFF && actual != expected) {
            revert HookAddressNotValid();
        }
    }

    function beforeInitialize(address, PoolKey memory, bytes memory)
        external
        virtual
        override
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey memory, bytes memory)
        external
        virtual
        override
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey memory, IPoolManager.ModifyLiquidityParams memory, bytes memory)
        external
        virtual
        override
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey memory,
        IPoolManager.ModifyLiquidityParams memory,
        BalanceDelta,
        bytes memory
    ) external virtual override onlyPoolManager returns (bytes4) {
        return IHooks.afterAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, PoolKey memory, IPoolManager.ModifyLiquidityParams memory, bytes memory)
        external
        virtual
        override
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey memory,
        IPoolManager.ModifyLiquidityParams memory,
        BalanceDelta,
        bytes memory
    ) external virtual override onlyPoolManager returns (bytes4) {
        return IHooks.afterRemoveLiquidity.selector;
    }

    function beforeSwap(address, PoolKey memory, IPoolManager.SwapParams memory, bytes memory)
        external
        virtual
        override
        onlyPoolManager
        returns (bytes4, uint24)
    {
        return (IHooks.beforeSwap.selector, 0);
    }

    function afterSwap(address, PoolKey memory, IPoolManager.SwapParams memory, BalanceDelta, bytes memory)
        external
        virtual
        override
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.afterSwap.selector;
    }

    function beforeDonate(address, PoolKey memory, uint256, uint256, bytes memory)
        external
        virtual
        override
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey memory, uint256, uint256, bytes memory)
        external
        virtual
        override
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }
}
