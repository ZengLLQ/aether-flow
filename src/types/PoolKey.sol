// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Currency} from "./Currency.sol";

type PoolId is bytes32;

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

using PoolIdLibrary for PoolKey global;

library PoolIdLibrary {
    function toId(PoolKey memory poolKey) internal pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(poolKey)));
    }
}
