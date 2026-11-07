// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "../../src/core/PoolManager.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../src/interfaces/IUnlockCallback.sol";
import {Currency} from "../../src/types/Currency.sol";
import {PoolKey, PoolId} from "../../src/types/PoolKey.sol";
import {BalanceDelta} from "../../src/types/BalanceDelta.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {TransientStorage} from "../../src/libraries/TransientStorage.sol";

contract UnlockUnsettledCallee is IUnlockCallback {
    IPoolManager public manager;
    PoolKey public key;

    constructor(IPoolManager _manager, PoolKey memory _key) {
        manager = _manager;
        key = _key;
    }

    function executeUnsettledSwap() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external override returns (bytes memory) {
        // Perform swap but do not settle or take, leaving nonzero delta
        manager.swap(key, IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1000, sqrtPriceLimitX96: 0}), "");
        return "";
    }
}

contract ReentrantCallee is IUnlockCallback {
    IPoolManager public manager;

    constructor(IPoolManager _manager) {
        manager = _manager;
    }

    function executeReentrancy() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external override returns (bytes memory) {
        // Attempt recursive unlock
        manager.unlock("");
        return "";
    }
}

contract PoolManagerTest is Test, IUnlockCallback {
    PoolManager public manager;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    Currency public currency0;
    Currency public currency1;
    PoolKey public key;
    PoolId public poolId;

    address public alice = address(0x1111);
    address public bob = address(0x2222);

    function setUp() public {
        manager = new PoolManager();
        MockERC20 token1 = new MockERC20("Token 1", "TK1", 18);
        MockERC20 token2 = new MockERC20("Token 2", "TK2", 18);

        // Strict currency ordering
        if (address(token1) < address(token2)) {
            tokenA = token1;
            tokenB = token2;
        } else {
            tokenA = token2;
            tokenB = token1;
        }

        currency0 = Currency.wrap(address(tokenA));
        currency1 = Currency.wrap(address(tokenB));

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000, // 0.30%
            tickSpacing: 60,
            hooks: address(0)
        });

        poolId = manager.initialize(key, 3000, "");

        tokenA.mint(address(this), 10_000_000 ether);
        tokenB.mint(address(this), 10_000_000 ether);
        tokenA.approve(address(manager), type(uint256).max);
        tokenB.approve(address(manager), type(uint256).max);

        tokenA.mint(alice, 1_000_000 ether);
        tokenB.mint(alice, 1_000_000 ether);
        tokenA.mint(bob, 1_000_000 ether);
        tokenB.mint(bob, 1_000_000 ether);
    }

    function test_InitializePool() public {
        IPoolManager.PoolState memory pool = manager.getPool(poolId);
        assertTrue(pool.initialized);
        assertEq(pool.fee, 3000);
        assertEq(pool.reserve0, 0);
        assertEq(pool.reserve1, 0);
        assertEq(pool.liquidity, 0);
    }

    function test_InitializePool_RevertCurrenciesOutOfOrder() public {
        PoolKey memory invalidKey =
            PoolKey({currency0: currency1, currency1: currency0, fee: 3000, tickSpacing: 60, hooks: address(0)});

        vm.expectRevert(IPoolManager.CurrenciesOutOfOrder.selector);
        manager.initialize(invalidKey, 3000, "");
    }

    function test_InitializePool_RevertAlreadyInitialized() public {
        vm.expectRevert(IPoolManager.PoolAlreadyInitialized.selector);
        manager.initialize(key, 3000, "");
    }

    function test_OperationOutsideUnlock_Reverts() public {
        vm.expectRevert(IPoolManager.UnauthorizedUnlock.selector);
        manager.swap(key, IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: 0}), "");

        vm.expectRevert(IPoolManager.UnauthorizedUnlock.selector);
        manager.modifyLiquidity(key, IPoolManager.ModifyLiquidityParams({liquidityDelta: 100, salt: bytes32(0)}), "");

        vm.expectRevert(IPoolManager.UnauthorizedUnlock.selector);
        manager.settle(currency0);

        vm.expectRevert(IPoolManager.UnauthorizedUnlock.selector);
        manager.take(currency0, address(this), 100);
    }

    function test_AddLiquidityAndSwap() public {
        // Unlock to seed pool liquidity
        manager.unlock(abi.encode(1)); // action 1: add liquidity

        IPoolManager.PoolState memory pool = manager.getPool(poolId);
        assertEq(pool.reserve0, 100_000 ether);
        assertEq(pool.reserve1, 100_000 ether);
        assertEq(pool.liquidity, 100_000 ether);

        // Unlock to perform exact input swap: 1000 token0 for token1
        bytes memory swapResult = manager.unlock(abi.encode(2)); // action 2: swap 0 for 1
        uint256 amountOut = abi.decode(swapResult, (uint256));

        assertTrue(amountOut > 0);
        // Constant product with 0.3% fee: 1000 * 0.997 = 997. dy = 100000 * 997 / (100000 + 997) ~ 987.15 ether
        assertApproxEqAbs(amountOut, 987.15 ether, 0.1 ether);

        IPoolManager.PoolState memory poolAfter = manager.getPool(poolId);
        assertEq(poolAfter.reserve0, 100_000 ether + 1000 ether);
        assertEq(poolAfter.reserve1, 100_000 ether - amountOut);
    }

    function test_SwapExactOutput() public {
        // Seed liquidity
        manager.unlock(abi.encode(1));

        // Exact output: buy exactly 500 token1 with token0
        bytes memory res = manager.unlock(abi.encode(3));
        uint256 amountIn = abi.decode(res, (uint256));

        // dy = 500. dx_fee = 100000 * 500 / 99500 ~ 502.51. dx = dx_fee / 0.997 ~ 504.02 ether
        assertApproxEqAbs(amountIn, 504.03 ether, 0.1 ether);

        IPoolManager.PoolState memory pool = manager.getPool(poolId);
        assertEq(pool.reserve1, 100_000 ether - 500 ether);
        assertEq(pool.reserve0, 100_000 ether + amountIn);
    }

    function test_Unlock_RevertsWhenDeltaUnsettled() public {
        // First seed liquidity
        manager.unlock(abi.encode(1));

        UnlockUnsettledCallee callee = new UnlockUnsettledCallee(manager, key);
        vm.expectRevert(abi.encodeWithSelector(IPoolManager.NonzeroDeltasRemaining.selector, address(callee), 2));
        callee.executeUnsettledSwap();
    }

    function test_Unlock_RevertsOnReentrancy() public {
        ReentrantCallee callee = new ReentrantCallee(manager);
        vm.expectRevert(TransientStorage.ReentrancyGuardLocked.selector);
        callee.executeReentrancy();
    }

    function test_Donate_IncreasesPoolReserves() public {
        // Seed liquidity
        manager.unlock(abi.encode(1));

        // Donate 100 token0 and 200 token1
        manager.unlock(abi.encode(4));

        IPoolManager.PoolState memory pool = manager.getPool(poolId);
        assertEq(pool.reserve0, 100_100 ether);
        assertEq(pool.reserve1, 100_200 ether);
        assertEq(pool.liquidity, 100_000 ether); // liquidity shares unchanged
    }

    function test_EIP6909_ClaimsMintAndBurn() public {
        // Seed liquidity
        manager.unlock(abi.encode(1));

        // Swap and mint EIP-6909 claims instead of withdrawing ERC-20
        manager.unlock(abi.encode(5)); // action 5: swap and mint 6909

        uint256 id1 = uint256(uint160(Currency.unwrap(currency1)));
        uint256 claimBalance = manager.balanceOf(address(this), id1);
        assertTrue(claimBalance > 0);

        // Transfer 6909 claims to alice
        manager.transfer(alice, id1, 100 ether);
        assertEq(manager.balanceOf(alice, id1), 100 ether);
        assertEq(manager.balanceOf(address(this), id1), claimBalance - 100 ether);

        // Burn 6909 claims to settle debt
        manager.unlock(abi.encode(6)); // action 6: burn 6909
    }

    // --- IUnlockCallback Implementation for Tests ---

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        uint256 action = abi.decode(data, (uint256));

        if (action == 1) {
            // Add initial liquidity
            BalanceDelta delta = manager.modifyLiquidity(
                key, IPoolManager.ModifyLiquidityParams({liquidityDelta: 100_000 ether, salt: bytes32(0)}), ""
            );

            uint256 amount0 = uint256(int256(-delta.amount0()));
            uint256 amount1 = uint256(int256(-delta.amount1()));

            tokenA.transfer(address(manager), amount0);
            tokenB.transfer(address(manager), amount1);
            manager.settle(currency0);
            manager.settle(currency1);
            return "";
        } else if (action == 2) {
            // Swap 1000 token0 exact input for token1
            uint256 amountIn = 1000 ether;
            BalanceDelta delta = manager.swap(
                key,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0}),
                ""
            );

            uint256 amountOut = uint256(int256(delta.amount1()));

            tokenA.transfer(address(manager), amountIn);
            manager.settle(currency0);
            manager.take(currency1, address(this), amountOut);

            return abi.encode(amountOut);
        } else if (action == 3) {
            // Swap exact output: 500 token1
            uint256 exactOut = 500 ether;
            BalanceDelta delta = manager.swap(
                key,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: int256(exactOut), sqrtPriceLimitX96: 0}),
                ""
            );

            uint256 amountIn = uint256(int256(-delta.amount0()));

            tokenA.transfer(address(manager), amountIn);
            manager.settle(currency0);
            manager.take(currency1, address(this), exactOut);

            return abi.encode(amountIn);
        } else if (action == 4) {
            // Donate 100 token0 and 200 token1
            manager.donate(key, 100 ether, 200 ether, "");

            tokenA.transfer(address(manager), 100 ether);
            tokenB.transfer(address(manager), 200 ether);
            manager.settle(currency0);
            manager.settle(currency1);
            return "";
        } else if (action == 5) {
            // Swap 1000 token0 and mint 6909 claims for token1
            uint256 amountIn = 1000 ether;
            BalanceDelta delta = manager.swap(
                key,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0}),
                ""
            );

            uint256 amountOut = uint256(int256(delta.amount1()));

            tokenA.transfer(address(manager), amountIn);
            manager.settle(currency0);
            manager.mint6909(currency1, address(this), amountOut);

            return abi.encode(amountOut);
        } else if (action == 6) {
            // Swap 100 token1 for token0, settling token1 using burn6909
            uint256 amountIn = 100 ether;
            BalanceDelta delta = manager.swap(
                key,
                IPoolManager.SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: 0}),
                ""
            );

            uint256 amountOut = uint256(int256(delta.amount0()));

            // Burn 6909 claim to pay token1 debt
            manager.burn6909(currency1, amountIn);
            // Take token0 to self
            manager.take(currency0, address(this), amountOut);

            return abi.encode(amountOut);
        }

        return "";
    }
}
