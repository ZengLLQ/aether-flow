// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Currency} from "../types/Currency.sol";

/// @title TransientStorage
/// @notice Implements EIP-1153 transient storage primitives for reentrancy control and flash accounting
library TransientStorage {
    bytes32 internal constant REENTRANCY_LOCK_SLOT = keccak256("aetherflow.transient.reentrancy.lock");

    bytes32 internal constant DELTA_SALT = keccak256("aetherflow.transient.delta");

    bytes32 internal constant NONZERO_COUNT_SALT = keccak256("aetherflow.transient.nonzero_count");

    error ReentrancyGuardLocked();

    function setReentrancyLock() internal {
        bytes32 slot = REENTRANCY_LOCK_SLOT;
        uint256 val;
        assembly {
            val := tload(slot)
        }
        if (val != 0) revert ReentrancyGuardLocked();
        assembly {
            tstore(slot, 1)
        }
    }

    function clearReentrancyLock() internal {
        bytes32 slot = REENTRANCY_LOCK_SLOT;
        assembly {
            tstore(slot, 0)
        }
    }

    function isLocked() internal view returns (bool locked) {
        bytes32 slot = REENTRANCY_LOCK_SLOT;
        assembly {
            locked := iszero(iszero(tload(slot)))
        }
    }

    function _deltaSlot(address target, Currency currency) private pure returns (bytes32) {
        return keccak256(abi.encode(target, Currency.unwrap(currency), DELTA_SALT));
    }

    function _countSlot(address target) private pure returns (bytes32) {
        return keccak256(abi.encode(target, NONZERO_COUNT_SALT));
    }

    function getDelta(address target, Currency currency) internal view returns (int256 delta) {
        bytes32 slot = _deltaSlot(target, currency);
        assembly {
            delta := tload(slot)
        }
    }

    function applyDelta(address target, Currency currency, int128 amount) internal returns (int256 newDelta) {
        bytes32 slot = _deltaSlot(target, currency);
        bytes32 countSlot = _countSlot(target);

        assembly {
            let currentDelta := tload(slot)
            newDelta := add(currentDelta, amount)
            tstore(slot, newDelta)

            let count := tload(countSlot)
            // If delta was zero and is now non-zero, increment count
            if and(iszero(currentDelta), iszero(iszero(newDelta))) {
                count := add(count, 1)
                tstore(countSlot, count)
            }
            // If delta was non-zero and is now zero, decrement count
            if and(iszero(iszero(currentDelta)), iszero(newDelta)) {
                count := sub(count, 1)
                tstore(countSlot, count)
            }
        }
    }

    function getNonzeroDeltaCount(address target) internal view returns (uint256 count) {
        bytes32 countSlot = _countSlot(target);
        assembly {
            count := tload(countSlot)
        }
    }
}
