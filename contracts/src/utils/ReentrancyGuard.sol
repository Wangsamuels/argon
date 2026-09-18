// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

abstract contract ReentrancyGuard {
    uint256 private _status = 1;

    error Reentrant();

    modifier nonReentrant() {
        if (_status != 1) revert Reentrant();
        _status = 2;
        _;
        _status = 1;
    }
}
