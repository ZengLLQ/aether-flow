// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IUnlockCallback {
    /// @notice Called by the PoolManager upon unlock
    /// @param data Arbitrary data passed in by the caller of unlock()
    /// @return returnData Arbitrary return data propagated back to the caller
    function unlockCallback(bytes calldata data) external returns (bytes memory returnData);
}
