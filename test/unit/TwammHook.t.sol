// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "../../src/core/PoolManager.sol";
import {TwammHook} from "../../src/hooks/TwammHook.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {Currency} from "../../src/types/Currency.sol";
import {PoolKey, PoolId} from "../../src/types/PoolKey.sol";
import {BalanceDelta} from "../../src/types/BalanceDelta.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Hooks} from "../../src/libraries/Hooks.sol";
import {IUnlockCallback} from "../../src/interfaces/IUnlockCallback.sol";

contract TwammHookTest is Test, IUnlockCallback {
    PoolManager public manager;
    TwammHook public hook;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    Currency public currency0;
    Currency public currency1;
    PoolKey public key;
    PoolId public poolId;

    address public trader = address(0x8888);

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

        // Required flags: BEFORE_SWAP_FLAG (0x0080) | BEFORE_ADD_LIQUIDITY_FLAG (0x0800) = 0x0880
        uint16 flags = Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        TwammHook impl = new TwammHook(manager);
        address hookAddress = address(uint160(flags));
        vm.etch(hookAddress, address(impl).code);
        hook = TwammHook(hookAddress);

        key = PoolKey({currency0: currency0, currency1: currency1, fee: 3000, tickSpacing: 60, hooks: address(hook)});

        poolId = manager.initialize(key, 3000, "");

        tokenA.mint(address(this), 10_000_000 ether);
        tokenB.mint(address(this), 10_000_000 ether);
        tokenA.approve(address(manager), type(uint256).max);
        tokenB.approve(address(manager), type(uint256).max);

        // Seed liquidity: 1,000,000 tokenA and 1,000,000 tokenB
        manager.unlock(abi.encode(1, uint256(0)));

        // Setup trader
        tokenA.mint(trader, 100_000 ether);
        tokenB.mint(trader, 100_000 ether);

        vm.startPrank(trader);
        tokenA.approve(address(hook), type(uint256).max);
        tokenB.approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    function test_Twamm_SubmitAndExecuteOrder() public {
        vm.startPrank(trader);

        // Submit 10,000 token0 long-term order over 100 blocks
        uint256 amount = 10_000 ether;
        uint256 duration = 100;
        uint256 orderId = hook.submitOrder(key, true, amount, duration);

        assertEq(orderId, 1);
        assertEq(tokenA.balanceOf(address(hook)), amount);

        vm.stopPrank();

        // Advance 50 blocks
        vm.roll(block.number + 50);

        // Execute TWAMM orders
        hook.executeTwammOrders(key);

        uint256 claimable = hook.getClaimableProceeds(orderId);
        assertTrue(claimable > 0);
        // ~5,000 token0 sold into 1,000,000 pool ~ 4,975 token1 proceeds
        assertApproxEqAbs(claimable, 4975 ether, 20 ether);

        // Trader claims proceeds
        vm.startPrank(trader);
        uint256 proceeds = hook.claimProceeds(orderId, key);
        vm.stopPrank();

        assertEq(proceeds, claimable);
        assertEq(tokenB.balanceOf(trader), 100_000 ether + proceeds);
    }

    function test_Twamm_CancelOrder_RefundsUnsoldTokens() public {
        vm.startPrank(trader);

        uint256 amount = 10_000 ether;
        uint256 duration = 100;
        uint256 orderId = hook.submitOrder(key, true, amount, duration);

        // Advance 30 blocks
        vm.roll(block.number + 30);

        (uint256 refund, uint256 proceeds) = hook.cancelOrder(orderId, key);

        vm.stopPrank();

        // 70 blocks remaining -> 70% refund = 7,000 ether
        assertEq(refund, 7000 ether);
        assertTrue(proceeds > 0);
        assertEq(tokenA.balanceOf(trader), 100_000 ether - amount + refund);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (uint256 action,) = abi.decode(data, (uint256, uint256));

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
        }

        return "";
    }
}
