// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library SafeTransfer {
    error TransferFailed();

    function pull(address token, address from, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, address(this), amount));
        _check(ok, data);
    }

    function push(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        _check(ok, data);
    }

    function approve(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(0x095ea7b3, spender, amount));
        _check(ok, data);
    }

    function _check(bool ok, bytes memory data) private pure {
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
