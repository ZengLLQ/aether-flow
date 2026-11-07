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

contract AetherRouterTest is Test {
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

    address public user = address(0x4444);
    address public recipient = address(0x5555);

    function setUp() public {
        manager = new PoolManager();
        router = new AetherRouter(manager);

        MockERC20 t1 = new MockERC20("Token 1", "TK1", 18);
        MockERC20 t2 = new MockERC20("Token 2", "TK2", 18);
        MockERC20 t3 = new MockERC20("Token 3", "TK3", 18);

        // Sort tokens deterministically so tokenA < tokenB < tokenC
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

        manager.initialize(poolABKey, 3000, "");
        manager.initialize(poolBCKey, 3000, "");

        // Mint tokens to this contract and seed liquidity
        tokenA.mint(address(this), 10_000_000 ether);
        tokenB.mint(address(this), 10_000_000 ether);
        tokenC.mint(address(this), 10_000_000 ether);

        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);

        // Seed Pool AB: 500,000 tokenA and 500,000 tokenB
        router.addLiquidity(
            AetherRouter.AddLiquidityParams({
                key: poolABKey, liquidity: 500_000 ether, recipient: address(this), hookData: ""
            })
        );

        // Seed Pool BC: 500,000 tokenB and 500,000 tokenC
        router.addLiquidity(
            AetherRouter.AddLiquidityParams({
                key: poolBCKey, liquidity: 500_000 ether, recipient: address(this), hookData: ""
            })
        );

        // Mint user tokens
        tokenA.mint(user, 100_000 ether);
        tokenB.mint(user, 100_000 ether);
        tokenC.mint(user, 100_000 ether);

        vm.startPrank(user);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function test_Router_SwapExactInputSingle() public {
        vm.startPrank(user);

        uint256 amountIn = 1000 ether;
        uint256 amountOut = router.swapExactInputSingle(
            AetherRouter.SwapSingleParams({
                key: poolABKey,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: 900 ether,
                recipient: recipient,
                hookData: ""
            })
        );

        vm.stopPrank();

        assertTrue(amountOut > 900 ether);
        assertEq(tokenB.balanceOf(recipient), amountOut);
    }

    function test_Router_SwapExactInputSingle_RevertSlippage() public {
        vm.startPrank(user);

        vm.expectRevert();
        router.swapExactInputSingle(
            AetherRouter.SwapSingleParams({
                key: poolABKey,
                zeroForOne: true,
                amountIn: 1000 ether,
                amountOutMinimum: 1500 ether, // Impossible minimum
                recipient: recipient,
                hookData: ""
            })
        );

        vm.stopPrank();
    }

    function test_Router_MultiHopSwap_TransientFlashAccounting() public {
        // Multi-hop: Token A -> Token B (Pool AB) -> Token C (Pool BC)
        // Notice: User starts with Token A and receives Token C at recipient.
        // Intermediate Token B is never transferred from user or to user!
        uint256 userTokenBBefore = tokenB.balanceOf(user);
        uint256 recipientTokenBBefore = tokenB.balanceOf(recipient);

        vm.startPrank(user);

        AetherRouter.MultiHopStep[] memory steps = new AetherRouter.MultiHopStep[](2);
        steps[0] = AetherRouter.MultiHopStep({
            key: poolABKey,
            zeroForOne: true, // A -> B
            hookData: ""
        });
        steps[1] = AetherRouter.MultiHopStep({
            key: poolBCKey,
            zeroForOne: true, // B -> C
            hookData: ""
        });

        uint256 amountIn = 2000 ether;
        uint256 amountOut = router.swapExactInputMultiHop(
            AetherRouter.SwapMultiHopParams({
                steps: steps,
                currencyIn: currencyA,
                currencyOut: currencyC,
                amountIn: amountIn,
                amountOutMinimum: 1800 ether,
                recipient: recipient
            })
        );

        vm.stopPrank();

        assertTrue(amountOut > 1800 ether);
        assertEq(tokenC.balanceOf(recipient), amountOut);

        // Verification of transient flash accounting:
        // No Token B was ever touched in user or recipient balances!
        assertEq(tokenB.balanceOf(user), userTokenBBefore);
        assertEq(tokenB.balanceOf(recipient), recipientTokenBBefore);
    }

    function test_Router_RemoveLiquidity() public {
        uint256 bal0Before = tokenA.balanceOf(address(this));
        uint256 bal1Before = tokenB.balanceOf(address(this));

        BalanceDelta delta = router.removeLiquidity(
            AetherRouter.RemoveLiquidityParams({
                key: poolABKey, liquidity: 10_000 ether, recipient: address(this), hookData: ""
            })
        );

        uint256 amount0 = uint256(int256(delta.amount0()));
        uint256 amount1 = uint256(int256(delta.amount1()));

        assertTrue(amount0 > 0);
        assertTrue(amount1 > 0);
        assertEq(tokenA.balanceOf(address(this)), bal0Before + amount0);
        assertEq(tokenB.balanceOf(address(this)), bal1Before + amount1);
    }
}
