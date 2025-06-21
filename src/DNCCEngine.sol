// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

pragma solidity 0.8.30;

import {DenaroChainCoin} from "./DenaroChainCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title DNCCEngine
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token -- 1$ peg.
 * This stablecoin has the properties:
 * - Exogenus Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 *
 * Our DNCC system should always be `overcollaterized`. At no point, should the value of
 *  all collateral <= the $ backed value of all the DNCC.
 *
 * @notice This contract is core of the DNCC System. It handles all the logic for minting
 *  and redeeming DNCC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */
contract DNCCEngine is ReentrancyGuard {
    ///////////////
    // Errors //
    ///////////////
    error NeedsMoreThanZero();
    error TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error NotAllowedToken();
    error TransferFailed();
    error HealthFactorIsBelowMinimum();
    error MintFailed();
    error HealthFactorOK();
    error HealthFactorNotImproved();
    error InvalidPrice();

    /////////////////////
    // State Variables //
    /////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // This means a 10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDnccMinted) private s_DNCCMinted;
    address[] private s_collateralTokens;

    // Stablecoin
    DenaroChainCoin private immutable i_dncc;

    ///////////////
    // Events /////
    ///////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    ///////////////
    // Modifiers //
    ///////////////
    modifier moreThanZero(uint256 amount) {
        require(amount != 0, NeedsMoreThanZero());
        _;
    }

    modifier isAllowedToken(address token) {
        require(s_priceFeeds[token] != address(0), NotAllowedToken());
        _;
    }

    ///////////////
    // Functions //
    ///////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dnccAddress) {
        // USD Price Feeds
        require(
            tokenAddresses.length == priceFeedAddresses.length, TokenAddressesAndPriceFeedAddressesMustBeSameLength()
        );

        // For example ETH / USD, BTC / USD, MKR / USD, etc
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dncc = DenaroChainCoin(dnccAddress);
    }

    ////////////////////////
    // External Functions //
    ////////////////////////

    /**
     *
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDnccToMint The amount of decentralized stablecoin to mint
     * @notice this function will deposit your collateral and mint DNCC in one transactionexterndepositCollateralal
     */
    function depositCollateralAndMintDncc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDnccToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDncc(amountDnccToMint);
    }

    /*
     * @notice follows CEI
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);

        require(success, TransferFailed());
    }

    function redeemCollateralForDncc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDnccToBurn)
        external
    {
        burnDncc(amountDnccToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);

        // redeemCollateral already checks health factor
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI
     * @param amountDnccToMint The amount of decentralized stablecoin to mint
     * @notice they must have more collateral value than the minimum threshold
     */
    function mintDncc(uint256 amountDnccToMint) public moreThanZero(amountDnccToMint) nonReentrant {
        s_DNCCMinted[msg.sender] += amountDnccToMint;
        // If they minted too much ($150 DNCC, $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dncc.mint(msg.sender, amountDnccToMint);
        if (!minted) revert MintFailed();
    }

    function burnDncc(uint256 amount) public moreThanZero(amount) {
        _burnDncc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     *
     * @param collateral The ERC20 collateral address to liquidate from the user
     * @param user The user who has broken the health factor. Their _healthFactor should be
     *  below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve the users health factor
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking users funds
     * @notice This function working assumes protocol will be roughly 200%
     * overcollaterized in order for this to work.
     * @notice A known bug would be if the protocol were 100% or less collaterized, then
     * we wouldn't be able to incentive the liquidators.
     * Follows CEI: Checks, Effects, Interactions
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert HealthFactorOK();
        }

        // We want to burn their DNCC "debt"
        // And take their collateral
        // Bad User: $140 ETH, $100 DNCC
        // debtToCover = $100
        // $100 of DNCC == ?? ETH?
        // 0.005 ETH

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DNCC

        // 0.05 * 0.1 = 0.005. Getting 0.055
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);

        // We need to burn the DNCC
        _burnDncc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert HealthFactorNotImproved();
        }
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    //////////////////////////////////
    // Private & Internal Functions //
    //////////////////////////////////

    /**
     * @dev Low-level internal function, do not call unless the function it is
     * checking for health factors being broken
     */
    function _burnDncc(uint256 amountDnccToBurn, address onBehalfOf, address dnccFrom) private {
        s_DNCCMinted[onBehalfOf] -= amountDnccToBurn;

        bool success = i_dncc.transferFrom(dnccFrom, address(this), amountDnccToBurn);
        require(success, TransferFailed());

        i_dncc.burn(amountDnccToBurn);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        require(success, TransferFailed());
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDnccMinted, uint256 collateralValueInUsd)
    {
        totalDnccMinted = s_DNCCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total DNCC minted
        // total collateral VALUE
        (uint256 totalDnccMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        if (totalDnccMinted == 0) return type(uint256).max;

        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        if (collateralAdjustedForThreshold == 0) {
            return 0;
        }

        return (collateralAdjustedForThreshold * PRECISION) / totalDnccMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 1. Check health factor (do they have enough collateral?)
        // 2. Revert if they don't
        uint256 userHealthFactor = _healthFactor(user);

        require(userHealthFactor > MIN_HEALTH_FACTOR, HealthFactorIsBelowMinimum());
    }

    //////////////////////////////////
    // Public & External View Functions //
    //////////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // price of ETH (token)
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // ($10e18 * 1e18) / ($2000e8 * 1e10)
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token,
        // get the amount they have deposited, and map it to the price, to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }

        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        require(price > 0, InvalidPrice());
        // 1 ETH = $1000
        // The returned value from the CL will be 1000 * 1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDnccMinted, uint256 collateralValueInUsd)
    {
        (totalDnccMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}
