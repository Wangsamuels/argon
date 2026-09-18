// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IInferenceRegistry {
    struct Forecast {
        int256 pct1hBps;
        int256 pct2hBps;
        int256 pct8hBps;
        bytes32 forecastHash;
        uint64 submittedAt;
        address submitter;
    }

    function getForecast(uint64 hourId) external view returns (Forecast memory);
    function latestHourId() external view returns (uint64);
    function forecastCount() external view returns (uint64);
    function modelId() external view returns (bytes32);
}
