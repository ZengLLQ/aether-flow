// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library SafeCast {
    error SafeCastOverflow();

    function toInt128(int256 value) internal pure returns (int128) {
        if (value < type(int128).min || value > type(int128).max) {
            revert SafeCastOverflow();
        }
        return int128(value);
    }

    function toInt128(uint256 value) internal pure returns (int128) {
        if (value > uint128(type(int128).max)) {
            revert SafeCastOverflow();
        }
        return int128(uint128(value));
    }

    function toInt256(uint256 value) internal pure returns (int256) {
        if (value > uint256(type(int256).max)) {
            revert SafeCastOverflow();
        }
        return int256(value);
    }

    function toUint128(uint256 value) internal pure returns (uint128) {
        if (value > type(uint128).max) {
            revert SafeCastOverflow();
        }
        return uint128(value);
    }

    function toUint256(int256 value) internal pure returns (uint256) {
        if (value < 0) {
            revert SafeCastOverflow();
        }
        return uint256(value);
    }
}
