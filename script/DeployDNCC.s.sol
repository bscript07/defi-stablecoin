// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {DenaroChainCoin} from "../src/DenaroChainCoin.sol";
import {DNCCEngine} from "../src/DNCCEngine.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployDNCC is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;
    uint256[] public deployerPrivateKey;

    function run() external returns (DenaroChainCoin, DNCCEngine, HelperConfig) {
        HelperConfig config = new HelperConfig();

        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) =
            config.activeNetworkConfig();

        deployerPrivateKey = [deployerKey];
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        vm.startBroadcast();
        DenaroChainCoin dncc = new DenaroChainCoin();
        DNCCEngine engine = new DNCCEngine(tokenAddresses, priceFeedAddresses, address(dncc));

        dncc.transferOwnership(address(engine));
        vm.stopBroadcast();

        return (dncc, engine, config);
    }
}
