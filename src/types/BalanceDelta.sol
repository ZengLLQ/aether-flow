// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

type BalanceDelta is int256;

using BalanceDeltaLibrary for BalanceDelta global;

function toBalanceDelta(int128 _amount0, int128 _amount1) pure returns (BalanceDelta) {
    int256 res;
    assembly {
        res := or(shl(128, _amount0), and(_amount1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
    }
    return BalanceDelta.wrap(res);
}

library BalanceDeltaLibrary {
    function amount0(BalanceDelta delta) internal pure returns (int128 _amount0) {
        assembly {
            _amount0 := sar(128, delta)
        }
    }

    function amount1(BalanceDelta delta) internal pure returns (int128 _amount1) {
        assembly {
            _amount1 := signextend(15, delta)
        }
    }
}
