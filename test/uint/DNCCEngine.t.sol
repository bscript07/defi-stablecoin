// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {DeployDNCC} from "../../script/DeployDNCC.s.sol";
import {DenaroChainCoin} from "../../src/DenaroChainCoin.sol";
import {DNCCEngine} from "../../src/DNCCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DNCCTest is Test {
    DeployDNCC deployer;
    DenaroChainCoin dncc;
    DNCCEngine dnccEngine;
    HelperConfig config;

    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    // Create virtual user for tests with amount collateral and starting balance 10 ethers
    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDNCC();
        (dncc, dnccEngine, config) = deployer.run();
        (ethUsdPriceFeed,, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    ////////////////////////
    /// Constructor Tests///
    ////////////////////////
    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DNCCEngine.TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DNCCEngine(tokenAddresses, priceFeedAddresses, address(dncc));
    }

    //////////////////
    /// Price Tests///
    //////////////////
    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18; // 15 ethers

        // 30k dollars
        uint256 expectedUsd = 30000e18;

        // 15e18 * 2000/ETH = 30000 USD
        uint256 actualUsd = dnccEngine.getUsdValue(weth, ethAmount);

        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        // $2000 / ETH, $100
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dnccEngine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    ///////////////////////////////
    /// Deposit Collateral Tests///
    ///////////////////////////////
    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dnccEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DNCCEngine.NeedsMoreThanZero.selector);
        dnccEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        vm.startPrank(USER);

        vm.expectRevert(DNCCEngine.NotAllowedToken.selector);
        dnccEngine.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dnccEngine), AMOUNT_COLLATERAL);
        dnccEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDnccMinted, uint256 collateralValueInUsd) = dnccEngine.getAccountInformation(USER);

        uint256 expectedTotalDnccMinted = 0;
        // 10 ether * 2000 = $20000
        uint256 expectedDepositAmount = dnccEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalDnccMinted, expectedTotalDnccMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    ////////////////////////////////////////
    /// Deposit Collateral Tests and Mint///
    ////////////////////////////////////////
    function testDepositCollaterallAndMintDNCC() public {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dnccEngine), AMOUNT_COLLATERAL);

        // Current value of collateral in USD
        uint256 usdValue = dnccEngine.getUsdValue(weth, AMOUNT_COLLATERAL);

        // Mint only 40% from value to store health factor
        uint256 mintAmount = (usdValue * 40) / 100;

        // Deposit collateral and mint DNCC
        dnccEngine.depositCollateralAndMintDncc(weth, AMOUNT_COLLATERAL, mintAmount);

        // Create a user with totaly minted DNCC coins and theit collateral value in USD
        (uint256 totalMinted, uint256 collateralValue) = dnccEngine.getAccountInformation(USER);

        // Assert values
        assertEq(totalMinted, mintAmount);
        assertEq(collateralValue, usdValue);

        vm.stopPrank();
    }

    function testRevertIfMintTooMuchDncc() public {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dnccEngine), AMOUNT_COLLATERAL);
        dnccEngine.depositCollateral(weth, AMOUNT_COLLATERAL);

        uint256 usdValue = dnccEngine.getUsdValue(weth, AMOUNT_COLLATERAL);

        // Mint 100% from the collateral => health factor < 1.0
        uint256 mintAmount = usdValue + 1;

        vm.expectRevert(DNCCEngine.HealthFactorIsBelowMinimum.selector);
        dnccEngine.mintDncc(mintAmount);

        vm.stopPrank();
    }

    ///////////////////////////////
    /// Redeem Collateral Tests////
    ///////////////////////////////
    function testRedeemCollateral() public {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dnccEngine), AMOUNT_COLLATERAL);
        dnccEngine.depositCollateral(weth, AMOUNT_COLLATERAL);

        uint256 balanceBefore = ERC20Mock(weth).balanceOf(USER);
        dnccEngine.redeemCollateral(weth, 5 ether);
        uint256 balanceAfter = ERC20Mock(weth).balanceOf(USER);

        assertEq(balanceAfter, balanceBefore + 5 ether);
        vm.stopPrank();
    }

    function testRedeemCollateralRevertsWhenHealthFactorIsBroken() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dnccEngine), AMOUNT_COLLATERAL);
        dnccEngine.depositCollateral(weth, AMOUNT_COLLATERAL);

        uint256 usdValue = dnccEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 mintAmount = (usdValue * 40) / 100;

        dnccEngine.mintDncc(mintAmount);

        vm.expectRevert(DNCCEngine.HealthFactorIsBelowMinimum.selector);
        dnccEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);

        vm.stopPrank();
    }

    function testRedeemCollateralForDNCC() public {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dnccEngine), AMOUNT_COLLATERAL);
        dnccEngine.depositCollateral(weth, AMOUNT_COLLATERAL);

        uint256 usdValue = dnccEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 mintAmount = (usdValue * 40) / 100;

        dnccEngine.mintDncc(mintAmount);

        dncc.approve(address(dnccEngine), mintAmount);
        dnccEngine.redeemCollateralForDncc(weth, 2 ether, mintAmount);

        vm.stopPrank();
    }

    //////////////////
    /// Burn Tests////
    //////////////////
    function testBurnDNCC() public {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dnccEngine), AMOUNT_COLLATERAL);
        dnccEngine.depositCollateral(weth, AMOUNT_COLLATERAL);

        uint256 usdValue = dnccEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 mintAmount = (usdValue * 40) / 100;

        dnccEngine.mintDncc(mintAmount);

        // Approve burn
        dncc.approve(address(dnccEngine), mintAmount);
        dnccEngine.burnDncc(mintAmount);

        (uint256 totalMinted,) = dnccEngine.getAccountInformation(USER);
        assertEq(totalMinted, 0);

        vm.stopPrank();
    }

    ///////////////////////
    /// Liquidate Tests////
    ///////////////////////
    // function testLiquidateImprovesHealthFactor() public {
    //     address LIQUIDATOR = makeAddr("liquidator");
    //     vm.deal(LIQUIDATOR, 1 ether);

    //     // USER: deposit + mint -> health factor > 1
    //     vm.startPrank(USER);
    //     ERC20Mock(weth).approve(address(dnccEngine), AMOUNT_COLLATERAL);
    //     dnccEngine.depositCollateral(weth, AMOUNT_COLLATERAL);

    //     uint256 usdValue = dnccEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
    //     uint256 mintAmount = (usdValue * 45) / 100; // 45%
    //     dnccEngine.mintDncc(mintAmount);

    //     dncc.transfer(LIQUIDATOR, mintAmount / 2);
    //     vm.stopPrank();

    //     // LIQUIDATOR
    //     vm.startPrank(LIQUIDATOR);
    //     ERC20Mock(weth).mint(LIQUIDATOR, 1 ether);
    //     ERC20Mock(weth).approve(address(dnccEngine), 1 ether);
    //     dnccEngine.depositCollateral(weth, 1 ether);

    //     dncc.approve(address(dnccEngine), mintAmount / 2);

    //     // Check: before and after liquidation
    //     uint256 userHealthBefore = dnccEngine.getHealthFactor(USER);
    //     dnccEngine.liquidate(weth, USER, mintAmount / 2);
    //     uint256 userHealthAfter = dnccEngine.getHealthFactor(USER);

    //     assertGt(userHealthAfter, userHealthBefore);
    //     vm.stopPrank();
    // }

    // function testRevertIfHealthFactorOk() public {
    //     vm.startPrank(USER);

    //     ERC20Mock(weth).approve(address(dnccEngine), AMOUNT_COLLATERAL);
    //     dnccEngine.depositCollateral(weth, AMOUNT_COLLATERAL);

    //     uint256 usdValue = dnccEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
    //     uint256 mintAmount = (usdValue * 40) / 100; // healthFactor well above 1
    //     dnccEngine.mintDncc(mintAmount);
    //     vm.stopPrank();

    //     address LIQUIDATOR = makeAddr("liquidator");
    //     vm.startPrank(LIQUIDATOR);
    //     dncc.transfer(LIQUIDATOR, mintAmount);
    //     dncc.approve(address(dnccEngine), mintAmount);

    //     vm.expectRevert(DNCCEngine.HealthFactorOK.selector);
    //     dnccEngine.liquidate(weth, USER, mintAmount / 2);
    //     vm.stopPrank();
    // }
}
