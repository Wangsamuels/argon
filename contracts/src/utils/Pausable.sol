// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

abstract contract Pausable {
    bool public paused;

    error Paused();
    error NotPaused();

    event PauseSet(bool paused);

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    function _setPaused(bool v) internal {
        paused = v;
        emit PauseSet(v);
    }
}
