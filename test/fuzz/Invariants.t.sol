// SPDX-License-Identifier: MIT

// Have our invariant aka properties

// What are you invariants?

// 1. The total supply of DNCC should be less than the total value of collateral
// 2. Getter view functions should never revert <- evergreen invariant
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDNCC} from "../../script/DeployDNCC.s.sol";
import {DenaroChainCoin} from "../../src/DenaroChainCoin.sol";
import {DNCCEngine} from "../../src/DNCCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "../fuzz/Handler.t.sol";

pragma solidity 0.8.30;

contract Invariants is StdInvariant, Test {
    DeployDNCC deployer;
    DenaroChainCoin dncc;
    DNCCEngine dnccEngine;

    HelperConfig config;
    Handler handler;

    address weth;
    address wbtc;

    function setUp() external {
        deployer = new DeployDNCC();
        (dncc, dnccEngine, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();

        handler = new Handler(dnccEngine, dncc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        // get the value of all the collateral in the protocol
        // compare it to all the debt (dncc)
        uint256 totalSupply = dncc.totalSupply();

        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dnccEngine));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dnccEngine));

        uint256 wethValue = dnccEngine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = dnccEngine.getUsdValue(wbtc, totalWbtcDeposited);

        console.log("weth value", wethValue);
        console.log("wbtc value", wbtcValue);
        console.log("total supply", totalSupply);
        console.log("Times mint called: ", handler.timesMintIsCalled());

        assert(wethValue + wbtcValue >= totalSupply);
    }

    function invariant_gettersShouldNotRevert() public view {
        dnccEngine.getLiquidationBonus();
        dnccEngine.getPrecision();
    }
}
