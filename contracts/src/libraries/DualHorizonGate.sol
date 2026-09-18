// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Dual-horizon ETH gate. Bps are signed percent * 100 (e.g. -40 = -0.40%).
library DualHorizonGate {
    uint8 internal constant HOLD = 0;
    uint8 internal constant ENTER = 1;
    uint8 internal constant EXIT = 2;

    function absBps(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    /// @dev EXIT if |1h| or |2h| is outside. ENTER only if idle and all three inside.
    ///      Idle + 8h outside returns EXIT (stay flat). In-pool + not EXIT returns HOLD.
    function allowedAction(
        int256 pct1hBps,
        int256 pct2hBps,
        int256 pct8hBps,
        uint16 gate1hBps,
        uint16 gate2hBps,
        uint16 gate8hBps,
        bool inPool
    ) internal pure returns (uint8) {
        bool mustExit = absBps(pct1hBps) >= gate1hBps || absBps(pct2hBps) >= gate2hBps;
        if (mustExit) return EXIT;
        if (inPool) return HOLD;
        bool canEnter = absBps(pct1hBps) < gate1hBps && absBps(pct2hBps) < gate2hBps && absBps(pct8hBps) < gate8hBps;
        return canEnter ? ENTER : EXIT;
    }
}
