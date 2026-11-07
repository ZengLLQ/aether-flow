// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "../../src/core/PoolManager.sol";
import {AetherRouter} from "../../src/periphery/AetherRouter.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {Currency} from "../../src/types/Currency.sol";
import {PoolKey, PoolId} from "../../src/types/PoolKey.sol";
import {BalanceDelta} from "../../src/types/BalanceDelta.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FullMath} from "../../src/libraries/FullMath.sol";

contract PoolInvariantsTest is Test {
    PoolManager public manager;
    AetherRouter public router;

    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;

    Currency public currencyA;
    Currency public currencyB;
    Currency public currencyC;

    PoolKey public poolABKey;
    PoolKey public poolBCKey;

    PoolId public poolABId;
    PoolId public poolBCId;

    address public user = address(0x9999);

    function setUp() public {
        manager = new PoolManager();
        router = new AetherRouter(manager);

        MockERC20 t1 = new MockERC20("Token 1", "TK1", 18);
        MockERC20 t2 = new MockERC20("Token 2", "TK2", 18);
        MockERC20 t3 = new MockERC20("Token 3", "TK3", 18);

        address[3] memory addrs = [address(t1), address(t2), address(t3)];
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (addrs[i] > addrs[j]) {
                    address temp = addrs[i];
                    addrs[i] = addrs[j];
                    addrs[j] = temp;
                }
            }
        }

        tokenA = MockERC20(addrs[0]);
        tokenB = MockERC20(addrs[1]);
        tokenC = MockERC20(addrs[2]);

        currencyA = Currency.wrap(address(tokenA));
        currencyB = Currency.wrap(address(tokenB));
        currencyC = Currency.wrap(address(tokenC));

        poolABKey = PoolKey({currency0: currencyA, currency1: currencyB, fee: 3000, tickSpacing: 60, hooks: address(0)});

        poolBCKey = PoolKey({currency0: currencyB, currency1: currencyC, fee: 3000, tickSpacing: 60, hooks: address(0)});

        poolABId = manager.initialize(poolABKey, 3000, "");
        poolBCId = manager.initialize(poolBCKey, 3000, "");

        tokenA.mint(address(this), 100_000_000 ether);
        tokenB.mint(address(this), 100_000_000 ether);
        tokenC.mint(address(this), 100_000_000 ether);

        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);

        // Seed 5,000,000 liquidity in both pools
        router.addLiquidity(
            AetherRouter.AddLiquidityParams({
                key: poolABKey, liquidity: 5_000_000 ether, recipient: address(this), hookData: ""
            })
        );

        router.addLiquidity(
            AetherRouter.AddLiquidityParams({
                key: poolBCKey, liquidity: 5_000_000 ether, recipient: address(this), hookData: ""
            })
        );

        tokenA.mint(user, 100_000_000 ether);
        tokenB.mint(user, 100_000_000 ether);
        tokenC.mint(user, 100_000_000 ether);

        vm.startPrank(user);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Invariant: Token balances in PoolManager must always equal or exceed totalReserves
    function assertSolvencyInvariant() internal view {
        assertGe(tokenA.balanceOf(address(manager)), manager.totalReserves(currencyA));
        assertGe(tokenB.balanceOf(address(manager)), manager.totalReserves(currencyB));
        assertGe(tokenC.balanceOf(address(manager)), manager.totalReserves(currencyC));
    }

    /// @notice Invariant: Transient delta must always be zero outside an unlocked transaction frame
    function assertDeltaZeroInvariant() internal view {
        assertEq(manager.getCurrencyDelta(address(this), currencyA), 0);
        assertEq(manager.getCurrencyDelta(address(this), currencyB), 0);
        assertEq(manager.getCurrencyDelta(address(this), currencyC), 0);
        assertEq(manager.getCurrencyDelta(user, currencyA), 0);
        assertEq(manager.getCurrencyDelta(user, currencyB), 0);
        assertEq(manager.getCurrencyDelta(user, currencyC), 0);
    }

    /// @notice Property-based fuzz test: Swaps preserve solvency, increase k, and maintain zero delta
    function testFuzz_SwapExactInput_SolvencyAndKInvariant(uint256 amountIn, bool zeroForOne) public {
        // Bound swap amount to [1 ether, 500,000 ether] to avoid pool depletion
        amountIn = bound(amountIn, 1 ether, 500_000 ether);

        IPoolManager.PoolState memory poolBefore = manager.getPool(poolABId);
        uint256 kBefore = FullMath.mulDiv(poolBefore.reserve0, poolBefore.reserve1, 1e18);

        vm.prank(user);
        uint256 amountOut = router.swapExactInputSingle(
            AetherRouter.SwapSingleParams({
                key: poolABKey,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: 0,
                recipient: user,
                hookData: ""
            })
        );

        assertTrue(amountOut > 0);

        IPoolManager.PoolState memory poolAfter = manager.getPool(poolABId);
        uint256 kAfter = FullMath.mulDiv(poolAfter.reserve0, poolAfter.reserve1, 1e18);

        // Constant product invariant: k must strictly increase or stay equal due to fees
        assertGe(kAfter, kBefore);

        assertSolvencyInvariant();
        assertDeltaZeroInvariant();
    }

    /// @notice Property-based fuzz test: Multi-hop swaps preserve zero intermediate token delta
    function testFuzz_MultiHop_PreservesZeroIntermediateDelta(uint256 amountIn) public {
        amountIn = bound(amountIn, 1 ether, 200_000 ether);

        uint256 managerTokenBBefore = tokenB.balanceOf(address(manager));
        uint256 userTokenBBefore = tokenB.balanceOf(user);

        AetherRouter.MultiHopStep[] memory steps = new AetherRouter.MultiHopStep[](2);
        steps[0] = AetherRouter.MultiHopStep({key: poolABKey, zeroForOne: true, hookData: ""});
        steps[1] = AetherRouter.MultiHopStep({key: poolBCKey, zeroForOne: true, hookData: ""});

        vm.prank(user);
        uint256 amountOut = router.swapExactInputMultiHop(
            AetherRouter.SwapMultiHopParams({
                steps: steps,
                currencyIn: currencyA,
                currencyOut: currencyC,
                amountIn: amountIn,
                amountOutMinimum: 0,
                recipient: user
            })
        );

        assertTrue(amountOut > 0);

        // Intermediate token B was NEVER transferred into or out of PoolManager!
        assertEq(tokenB.balanceOf(address(manager)), managerTokenBBefore);
        assertEq(tokenB.balanceOf(user), userTokenBBefore);

        assertSolvencyInvariant();
        assertDeltaZeroInvariant();
    }

    /// @notice Property-based fuzz test: Liquidity additions and removals are pro-rata and preserve solvency
    function testFuzz_ModifyLiquidity_ProRata(uint128 liquidityAmount) public {
        liquidityAmount = uint128(bound(uint256(liquidityAmount), 100 ether, 500_000 ether));

        BalanceDelta addDelta = router.addLiquidity(
            AetherRouter.AddLiquidityParams({
                key: poolABKey, liquidity: liquidityAmount, recipient: address(this), hookData: ""
            })
        );

        assertTrue(addDelta.amount0() < 0);
        assertTrue(addDelta.amount1() < 0);
        assertSolvencyInvariant();
        assertDeltaZeroInvariant();

        BalanceDelta removeDelta = router.removeLiquidity(
            AetherRouter.RemoveLiquidityParams({
                key: poolABKey, liquidity: liquidityAmount, recipient: address(this), hookData: ""
            })
        );

        assertTrue(removeDelta.amount0() > 0);
        assertTrue(removeDelta.amount1() > 0);
        assertSolvencyInvariant();
        assertDeltaZeroInvariant();
    }
}
