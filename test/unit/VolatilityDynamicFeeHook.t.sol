// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "../../src/core/PoolManager.sol";
import {VolatilityDynamicFeeHook} from "../../src/hooks/VolatilityDynamicFeeHook.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {Currency} from "../../src/types/Currency.sol";
import {PoolKey, PoolId} from "../../src/types/PoolKey.sol";
import {BalanceDelta} from "../../src/types/BalanceDelta.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Hooks} from "../../src/libraries/Hooks.sol";
import {IUnlockCallback} from "../../src/interfaces/IUnlockCallback.sol";

contract VolatilityDynamicFeeHookTest is Test, IUnlockCallback {
    PoolManager public manager;
    VolatilityDynamicFeeHook public hook;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    Currency public currency0;
    Currency public currency1;
    PoolKey public key;
    PoolId public poolId;

    address public user = address(0x7777);

    function setUp() public {
        manager = new PoolManager();

        MockERC20 t1 = new MockERC20("Token 1", "TK1", 18);
        MockERC20 t2 = new MockERC20("Token 2", "TK2", 18);

        if (address(t1) < address(t2)) {
            tokenA = t1;
            tokenB = t2;
        } else {
            tokenA = t2;
            tokenB = t1;
        }

        currency0 = Currency.wrap(address(tokenA));
        currency1 = Currency.wrap(address(tokenB));

        // Deploy template hook
        VolatilityDynamicFeeHook impl = new VolatilityDynamicFeeHook(manager);

        // Required flags: BEFORE_SWAP_FLAG (0x0080) | AFTER_SWAP_FLAG (0x0040) = 0x00C0
        uint16 flags = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;
        address hookAddress = address(uint160(flags));
        vm.etch(hookAddress, address(impl).code);
        hook = VolatilityDynamicFeeHook(hookAddress);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000, // static fee: 0.30%
            tickSpacing: 60,
            hooks: address(hook)
        });

        poolId = manager.initialize(key, 3000, "");

        tokenA.mint(address(this), 10_000_000 ether);
        tokenB.mint(address(this), 10_000_000 ether);
        tokenA.approve(address(manager), type(uint256).max);
        tokenB.approve(address(manager), type(uint256).max);

        // Seed liquidity: 1,000,000 tokenA and 1,000,000 tokenB
        manager.unlock(abi.encode(1, uint256(0)));
    }

    function test_VolatilityHook_InitialBaselineFee() public {
        // First swap should execute at baseline fee (3000 = 0.3%)
        bytes memory res = manager.unlock(abi.encode(2, 1000 ether)); // swap 1000 token0
        uint256 amountOut = abi.decode(res, (uint256));

        assertTrue(amountOut > 0);
        // With baseline 0.3% fee: 1000 * 0.997 = 997. dy = 1000000 * 997 / 1000997 ~ 996.0 ether
        assertApproxEqAbs(amountOut, 996.0 ether, 0.5 ether);

        (uint256 lastPrice, uint256 variance,) = hook.poolVolatility(poolId);
        assertTrue(lastPrice > 0);
        assertEq(variance, 0); // first swap only records initial price baseline
    }

    function test_VolatilityHook_FeeExpandsDuringPriceShock() public {
        // Execute initial swap to set price benchmark
        manager.unlock(abi.encode(2, 1000 ether));

        // Execute massive volatile price shock swap (400,000 token0)
        manager.unlock(abi.encode(2, 400_000 ether));

        // Verify EWMA variance expanded
        (, uint256 varianceAfterShock,) = hook.poolVolatility(poolId);
        assertTrue(varianceAfterShock > 0);

        // Query beforeSwap fee for subsequent swap as poolManager
        vm.prank(address(manager));
        (, uint24 elevatedFee) = hook.beforeSwap(
            address(this),
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1000 ether, sqrtPriceLimitX96: 0}),
            ""
        );

        // Dynamic fee must be strictly higher than baseline 3000 bps
        assertTrue(elevatedFee > hook.BASE_FEE());
        assertTrue(elevatedFee <= hook.MAX_FEE());
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (uint256 action, uint256 amount) = abi.decode(data, (uint256, uint256));

        if (action == 1) {
            BalanceDelta delta = manager.modifyLiquidity(
                key, IPoolManager.ModifyLiquidityParams({liquidityDelta: 1_000_000 ether, salt: bytes32(0)}), ""
            );

            uint256 a0 = uint256(int256(-delta.amount0()));
            uint256 a1 = uint256(int256(-delta.amount1()));
            tokenA.transfer(address(manager), a0);
            tokenB.transfer(address(manager), a1);
            manager.settle(currency0);
            manager.settle(currency1);
            return "";
        } else if (action == 2) {
            BalanceDelta delta = manager.swap(
                key,
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -int256(amount), sqrtPriceLimitX96: 0}),
                ""
            );

            uint256 amountOut = uint256(int256(delta.amount1()));
            tokenA.transfer(address(manager), amount);
            manager.settle(currency0);
            manager.take(currency1, address(this), amountOut);
            return abi.encode(amountOut);
        }

        return "";
    }
}
