// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

type Currency is address;

using CurrencyLibrary for Currency global;

library CurrencyLibrary {
    Currency public constant ADDRESS_ZERO = Currency.wrap(address(0));

    error NativeTransferFailed();
    error ERC20TransferFailed();

    function isNative(Currency currency) internal pure returns (bool) {
        return Currency.unwrap(currency) == address(0);
    }

    function toAddress(Currency currency) internal pure returns (address) {
        return Currency.unwrap(currency);
    }

    function equals(Currency a, Currency b) internal pure returns (bool) {
        return Currency.unwrap(a) == Currency.unwrap(b);
    }

    function greaterThan(Currency a, Currency b) internal pure returns (bool) {
        return Currency.unwrap(a) > Currency.unwrap(b);
    }

    function balanceOfSelf(Currency currency) internal view returns (uint256) {
        if (currency.isNative()) {
            return address(this).balance;
        } else {
            (bool success, bytes memory data) = Currency.unwrap(currency)
                .staticcall(
                    abi.encodeWithSelector(0x70a08231, address(this)) // balanceOf(address)
                );
            if (success && data.length >= 32) {
                return abi.decode(data, (uint256));
            }
            return 0;
        }
    }

    function balanceOf(Currency currency, address owner) internal view returns (uint256) {
        if (currency.isNative()) {
            return owner.balance;
        } else {
            (bool success, bytes memory data) =
                Currency.unwrap(currency).staticcall(abi.encodeWithSelector(0x70a08231, owner));
            if (success && data.length >= 32) {
                return abi.decode(data, (uint256));
            }
            return 0;
        }
    }

    function transfer(Currency currency, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (currency.isNative()) {
            (bool success,) = to.call{value: amount}("");
            if (!success) revert NativeTransferFailed();
        } else {
            (bool success, bytes memory data) = Currency.unwrap(currency)
                .call(
                    abi.encodeWithSelector(0xa9059cbb, to, amount) // transfer(address,uint256)
                );
            if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
                revert ERC20TransferFailed();
            }
        }
    }

    function transferFrom(Currency currency, address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (currency.isNative()) {
            revert NativeTransferFailed(); // native ETH cannot transferFrom
        } else {
            (bool success, bytes memory data) = Currency.unwrap(currency)
                .call(
                    abi.encodeWithSelector(0x23b872dd, from, to, amount) // transferFrom(address,address,uint256)
                );
            if (!success || (data.length != 0 && !abi.decode(data, (bool)))) {
                revert ERC20TransferFailed();
            }
        }
    }
}
