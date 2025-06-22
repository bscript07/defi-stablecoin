// SPDX-License-Identifier: MIT

// Handler is going to narrow down the way we call function
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {DNCCEngine} from "../../src/DNCCEngine.sol";
import {DenaroChainCoin} from "../../src/DenaroChainCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DNCCEngine dnccEngine;
    DenaroChainCoin dncc;

    ERC20Mock weth;
    ERC20Mock wbtc;

    // Mints function counter
    uint256 public timesMintIsCalled;
    address[] public usersWithCollateralDeposited;
    MockV3Aggregator public ethUsdPriceFeed;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max; // the max uint96 value

    constructor(DNCCEngine _dnccEngine, DenaroChainCoin _dncc) {
        dnccEngine = _dnccEngine;
        dncc = _dncc;

        address[] memory collateralTokens = dnccEngine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dnccEngine.getCollateralTokenPriceFeed(address(weth)));
    }

    // redeem collateral <-
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dnccEngine), amountCollateral);
        dnccEngine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dnccEngine.getCollateralBalanceOfUser(address(collateral), msg.sender);

        amountCollateral = bound(amountCollateral, 1, maxCollateralToRedeem);
        if (amountCollateral == 0) {
            return;
        }

        dnccEngine.redeemCollateral(address(collateral), amountCollateral);
    }

    function mintDNCC(uint256 amount, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }

        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        (uint256 totalDnccMinted, uint256 collateralValueInUsd) = dnccEngine.getAccountInformation(sender);

        int256 maxDnccToMint = (int256(collateralValueInUsd) / 2) - int256(totalDnccMinted);
        if (maxDnccToMint < 0) {
            return;
        }
        amount = bound(amount, 0, uint256(maxDnccToMint));
        if (amount == 0) {
            return;
        }

        vm.startPrank(sender);
        dnccEngine.mintDncc(amount);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    // THis breaks our invariant test suite!!!
    // function updateCollateralPriceFeed(uint96 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    // Helper Functions
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
