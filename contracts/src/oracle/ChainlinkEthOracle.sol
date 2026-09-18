// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IEthUsdOracle} from "../interfaces/IEthUsdOracle.sol";

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Chainlink ETH/USD + optional L2 sequencer uptime feed.
contract ChainlinkEthOracle is IEthUsdOracle {
    AggregatorV3Interface public immutable ethUsd;
    AggregatorV3Interface public immutable sequencer; // address(0) = skip
    uint256 public immutable maxDelay;

    uint256 private constant GRACE = 3600;

    error StalePrice();
    error BadPrice();
    error SequencerDown();

    error ZeroAddress();

    constructor(address ethUsdFeed, address sequencerFeed, uint256 maxDelay_) {
        if (ethUsdFeed == address(0)) revert ZeroAddress();
        ethUsd = AggregatorV3Interface(ethUsdFeed);
        sequencer = AggregatorV3Interface(sequencerFeed);
        maxDelay = maxDelay_ == 0 ? 3600 : maxDelay_;
    }

    function assertHealthy() public view {
        if (address(sequencer) != address(0)) {
            (, int256 status,, uint256 startedAt,) = sequencer.latestRoundData();
            if (status == 1) revert SequencerDown();
            if (startedAt != 0 && block.timestamp - startedAt <= GRACE) revert SequencerDown();
        }
        ethUsd8();
    }

    function ethUsd8() public view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = ethUsd.latestRoundData();
        if (answer <= 0) revert BadPrice();
        if (block.timestamp - updatedAt > maxDelay) revert StalePrice();
        return uint256(answer);
    }
}
