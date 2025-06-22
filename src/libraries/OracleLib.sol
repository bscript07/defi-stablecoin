// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @notice This library is used to check Chainlink Oracle for stale data.
 * If a price is stale, the function will revert, and render the DNCCEngine unusable
 * We want the DNCCEngine to freeze if prices become stale.
 *
 * So if the Chanlink network explodes and you have a lot of money locked in the protocol... tooo bad.
 */
library OracleLib {
    error StalePrice();

    uint256 private constant TIMEOUT = 3 hours; // 3 * 60 * 60 = 10800 seconds

    function stalePriceCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        uint256 secondsSince = block.timestamp - updatedAt;
        if (secondsSince > TIMEOUT) revert StalePrice();

        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
