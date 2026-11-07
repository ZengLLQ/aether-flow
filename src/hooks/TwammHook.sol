// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseHook} from "./BaseHook.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../interfaces/IUnlockCallback.sol";
import {PoolKey, PoolId} from "../types/PoolKey.sol";
import {BalanceDelta} from "../types/BalanceDelta.sol";
import {Hooks} from "../libraries/Hooks.sol";
import {FullMath} from "../libraries/FullMath.sol";
import {Currency} from "../types/Currency.sol";
import {SafeCast} from "../libraries/SafeCast.sol";

/// @title TwammHook
/// @notice Time-Weighted Average Market Maker (TWAMM) hook executing long-term continuous orders lazily between blocks
contract TwammHook is BaseHook, IUnlockCallback {
    using SafeCast for uint256;
    using SafeCast for int256;

    struct Order {
        address owner;
        PoolId poolId;
        bool zeroForOne;
        uint256 totalAmount;
        uint256 startBlock;
        uint256 endBlock;
        uint256 saleRate; // amount per block
        uint256 proceedsClaimed;
        bool cancelled;
    }

    struct OrderPool {
        uint256 currentSaleRate0For1;
        uint256 currentSaleRate1For0;
        uint256 lastExecutionBlock;
        uint256 rewardFactor0For1; // cumulative token1 proceeds per unit sale rate
        uint256 rewardFactor1For0; // cumulative token0 proceeds per unit sale rate
    }

    mapping(PoolId => OrderPool) public orderPools;
    mapping(uint256 => Order) public orders;
    uint256 public nextOrderId = 1;

    event LongTermOrderSubmitted(
        uint256 indexed orderId,
        address indexed owner,
        PoolId indexed poolId,
        bool zeroForOne,
        uint256 totalAmount,
        uint256 startBlock,
        uint256 endBlock
    );

    event LongTermOrderCancelled(uint256 indexed orderId, uint256 unsoldRefund, uint256 proceeds);
    event ProceedsClaimed(uint256 indexed orderId, address indexed owner, uint256 proceeds);

    error InvalidDuration();
    error ZeroOrderAmount();
    error NotOrderOwner();
    error OrderAlreadyCancelled();
    error UnauthorizedCallback();

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (uint16) {
        return Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
    }

    function submitOrder(PoolKey memory key, bool zeroForOne, uint256 totalAmount, uint256 durationBlocks)
        external
        returns (uint256 orderId)
    {
        if (durationBlocks == 0) revert InvalidDuration();
        if (totalAmount == 0) revert ZeroOrderAmount();

        _executeTwamm(key);

        if (nextOrderId == 0) nextOrderId = 1;
        orderId = nextOrderId++;
        uint256 startBlock = block.number;
        uint256 endBlock = startBlock + durationBlocks;
        uint256 saleRate = totalAmount / durationBlocks;

        PoolId id = key.toId();
        orders[orderId] = Order({
            owner: msg.sender,
            poolId: id,
            zeroForOne: zeroForOne,
            totalAmount: totalAmount,
            startBlock: startBlock,
            endBlock: endBlock,
            saleRate: saleRate,
            proceedsClaimed: 0,
            cancelled: false
        });

        OrderPool storage op = orderPools[id];
        if (zeroForOne) {
            op.currentSaleRate0For1 += saleRate;
            key.currency0.transferFrom(msg.sender, address(this), totalAmount);
        } else {
            op.currentSaleRate1For0 += saleRate;
            key.currency1.transferFrom(msg.sender, address(this), totalAmount);
        }

        emit LongTermOrderSubmitted(orderId, msg.sender, id, zeroForOne, totalAmount, startBlock, endBlock);
    }

    function claimProceeds(uint256 orderId, PoolKey memory key) external returns (uint256 proceeds) {
        Order storage order = orders[orderId];
        if (order.owner != msg.sender) revert NotOrderOwner();

        _executeTwamm(key);

        proceeds = getClaimableProceeds(orderId);
        if (proceeds > 0) {
            order.proceedsClaimed += proceeds;
            if (order.zeroForOne) {
                key.currency1.transfer(order.owner, proceeds);
            } else {
                key.currency0.transfer(order.owner, proceeds);
            }
            emit ProceedsClaimed(orderId, order.owner, proceeds);
        }
    }

    function cancelOrder(uint256 orderId, PoolKey memory key)
        external
        returns (uint256 unsoldRefund, uint256 proceeds)
    {
        Order storage order = orders[orderId];
        if (order.owner != msg.sender) revert NotOrderOwner();
        if (order.cancelled) revert OrderAlreadyCancelled();

        _executeTwamm(key);

        order.cancelled = true;
        proceeds = getClaimableProceeds(orderId);
        if (proceeds > 0) {
            order.proceedsClaimed += proceeds;
            if (order.zeroForOne) {
                key.currency1.transfer(order.owner, proceeds);
            } else {
                key.currency0.transfer(order.owner, proceeds);
            }
        }

        uint256 blocksRemaining = block.number < order.endBlock ? order.endBlock - block.number : 0;
        unsoldRefund = blocksRemaining * order.saleRate;

        OrderPool storage op = orderPools[key.toId()];
        if (order.zeroForOne) {
            op.currentSaleRate0For1 -= order.saleRate;
            if (unsoldRefund > 0) key.currency0.transfer(order.owner, unsoldRefund);
        } else {
            op.currentSaleRate1For0 -= order.saleRate;
            if (unsoldRefund > 0) key.currency1.transfer(order.owner, unsoldRefund);
        }

        emit LongTermOrderCancelled(orderId, unsoldRefund, proceeds);
    }

    function getClaimableProceeds(uint256 orderId) public view returns (uint256) {
        Order memory order = orders[orderId];
        if (order.saleRate == 0) return 0;

        OrderPool memory op = orderPools[order.poolId];
        uint256 effectiveEnd = block.number < order.endBlock ? block.number : order.endBlock;
        if (effectiveEnd <= order.startBlock) return 0;

        uint256 elapsedBlocks = effectiveEnd - order.startBlock;
        uint256 totalEarned;

        if (order.zeroForOne) {
            totalEarned = FullMath.mulDiv(elapsedBlocks * order.saleRate, op.rewardFactor0For1, 1e18);
        } else {
            totalEarned = FullMath.mulDiv(elapsedBlocks * order.saleRate, op.rewardFactor1For0, 1e18);
        }

        return totalEarned > order.proceedsClaimed ? totalEarned - order.proceedsClaimed : 0;
    }

    function executeTwammOrders(PoolKey memory key) external {
        _executeTwamm(key);
    }

    function _executeTwamm(PoolKey memory key) internal {
        PoolId id = key.toId();
        OrderPool storage op = orderPools[id];

        if (op.lastExecutionBlock == 0) {
            op.lastExecutionBlock = block.number;
            return;
        }

        uint256 blocksElapsed = block.number - op.lastExecutionBlock;
        if (blocksElapsed == 0) return;

        op.lastExecutionBlock = block.number;

        uint256 amount0In = op.currentSaleRate0For1 * blocksElapsed;
        uint256 amount1In = op.currentSaleRate1For0 * blocksElapsed;

        if (amount0In == 0 && amount1In == 0) return;

        // Execute swap through poolManager unlock to settle tokens
        bytes memory data = abi.encode(key, amount0In, amount1In);
        poolManager.unlock(data);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert UnauthorizedCallback();

        (PoolKey memory key, uint256 amount0In, uint256 amount1In) = abi.decode(data, (PoolKey, uint256, uint256));

        PoolId id = key.toId();
        OrderPool storage op = orderPools[id];

        if (amount0In > 0) {
            BalanceDelta delta = poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: true, amountSpecified: -amount0In.toInt256(), sqrtPriceLimitX96: 0
                }),
                ""
            );

            uint256 out1 = uint256(int256(delta.amount1()));
            op.rewardFactor0For1 += FullMath.mulDiv(out1, 1e18, amount0In);

            // Settle token0 and take token1
            key.currency0.transfer(address(poolManager), amount0In);
            poolManager.settle(key.currency0);
            poolManager.take(key.currency1, address(this), out1);
        }

        if (amount1In > 0) {
            BalanceDelta delta = poolManager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: false, amountSpecified: -amount1In.toInt256(), sqrtPriceLimitX96: 0
                }),
                ""
            );

            uint256 out0 = uint256(int256(delta.amount0()));
            op.rewardFactor1For0 += FullMath.mulDiv(out0, 1e18, amount1In);

            key.currency1.transfer(address(poolManager), amount1In);
            poolManager.settle(key.currency1);
            poolManager.take(key.currency0, address(this), out0);
        }

        return "";
    }

    function beforeSwap(address, PoolKey memory, IPoolManager.SwapParams memory, bytes memory)
        external
        override
        onlyPoolManager
        returns (bytes4, uint24)
    {
        return (this.beforeSwap.selector, 0);
    }

    function beforeAddLiquidity(address, PoolKey memory, IPoolManager.ModifyLiquidityParams memory, bytes memory)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        return this.beforeAddLiquidity.selector;
    }
}
