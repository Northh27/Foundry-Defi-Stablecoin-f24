//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Carlos Sanchez
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollarteralized". At no point should the value of all collateral be less than the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */

contract DSCEngine is ReentrancyGuard {
    //////////////
    /// Errors ///
    /////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressMustBeSameLength();
    error DSCEngine_NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine_HealthIsOkay();
    error DSCEngine__HealthFactorNotImproved();
    error DSCEngine__NotEnoughDsc();
    //////////////////////
    /// State Variables ///
    //////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECSION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // this means 10% bonus

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DscMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////////
    /// Events ///////////
    //////////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    /////////////////
    /// Modifiers ///
    /////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }
    // In a mapping if the address type of the token is not in the mapping, it just returns a deafult value which is 0

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine_NotAllowedToken();
        }
        _;
    }

    /////////////////
    /// Functions ///
    /////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////////
    /// ExternalFunctions ///
    ////////////////////////

    /**
     *
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of DSC to mint
     * @notice this function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice follows CEI pattern
     * @param tokenCollateralAddress the address of the collateral token to be deposited
     * @param amountCollateral the aoount of collateral to be deposited
     *
     */

    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
        isAllowedToken(tokenCollateralAddress)
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     *
     * @param tokenCollateralAddress The collateral token to redeem
     * @param amountCollateral  the amount of collateral to redeem
     * @param amountDscToBurn the amount of DSC to burn
     * @notice this function will burn DSC and redeem collateral in one transaction
     */

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        // first we burn the DSC then we allow them to redeem the collateral
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);

        _revertHealthFactorIsBroken(msg.sender);
    }
    // put in $100 eth and mint 20 DSC
    // what if i want my eth back? and redeem 100 eth, itll break because
    // first need to burn DSC
    // then redeem eth
    // this is a two step process so lets make it one step, and make a burn DSC function

    /**
     *
     * @notice follows CEI pattern
     * @param amountDscToMint the amount of DSC to mint
     * @notice they must have more collateral value than the minuumum threshold
     *
     */

    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DscMinted[msg.sender] += amountDscToMint;
        _revertHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertHealthFactorIsBroken(msg.sender);
    }
    // if someone is almost undercollateralized, we want to liquidate them
    // and we will pay the user that liquidates them a fee
    // If the backing goes to $75 dollars of the $50 DSC minted then
    // the liquidator will get the 75 dollars and pay back the 50 DSC and keep the 25 dollars
    // liquidator will be able to choose the collarteral, the user and the debt to pay off
    // They can keep track of the users by the events we are emitting

    /**
     * @param collateral the erc20 collateral address to liquidate from the user
     * @param user The user who has broken the health factor, thier _healthFactor is less than 1
     * @param debtToCover the amount of DSC you want ot burn to improve the users health factor
     * @notice You can partically liquidate a user
     * @notice you will get a liquidation bonus for liquidating a user
     * @notice this funcion working assumes the protocol will be roughly 200% overcollaralized // this system only works if its overcollateralized
     * @notice a known bug would be if the protocol were 100% or less collaterazlied, then we wouldnt be able to liquidate be able to incentivize liquidators
     * For example, if the price of the collateral plummets, then the liquidator would have to pay more than the collateral is worth. i.e collateral is 50 and the debt is 100
     *
     * Following the CEI pattern: Checks, effects , interactions
     */

    function liquidateDsc(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // need to check the users healthFactor, since we will only liquidate if they are undercollateralized
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine_HealthIsOkay();
        }
        // we want to burn thier DSC "debt"
        // and take thier collateral
        // bad user : $140, $100 DSC
        // debtToCover = $100 - we'll pay back 100 worth of eth
        // $100 of DSC - how mcuh eth??
        //0,05 eth
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // and give them a 10% bonus
        // we are giving the liquidator $110 worth of eth for 100 DSC
        // we should implement a feature to liquidate in the event the protocol is insolvent
        // and swwp extra amounts into a tresury
        //0,05 ETH * 0.1 = 0.005. getting 0.055 eth as a bonus
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECSION;
        // need to redeem this amount of collateral for the user calling the liquidate function and burn the DSC from the debttoCover
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        // we need to burm DSC
        // Amount is the debttocover, onbealfOf is the user, the one who is calling liquidate is paying down the debt
        // they are paying back that minted DSC
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    ///////////////////////////////////////////
    /// Private & Internal View Functions ///
    /////////////////////////////////////////

    /**
     * @dev Low-Level internal Function, do not call unless the function it is checking
     * for health facotors beign broken
     */
    function _burnDsc(
        uint256 amountDscToBurn,
        address /*Whos debt were paying down*/ onBehalfOf,
        address /*Where were getting the dsc from*/ dscFrom
    ) private {
        if (s_DscMinted[onBehalfOf] < amountDscToBurn) {
            revert DSCEngine__NotEnoughDsc();
        }
        //Taking away their debt
        s_DscMinted[onBehalfOf] -= amountDscToBurn;
        // tranfering the DSC from the user to the contract
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        // then takes it and burns it with the .burn function
        i_dsc.burn(amountDscToBurn);
    }

    // This is an internal function that allows us to redeem collateral from anyone
    function _redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        // someone can liquidate a user and send it to thier address
        address from,
        address to
    ) internal {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     *
     * Returns how clsoe to liquidation a user is
     * if a user goes below 1, then they can get liquidated
     */
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        // Takes the amount the user minted since its a uint256
        totalDscMinted = s_DscMinted[user];
        collateralValueInUsd = getAccountCollateralValueInUsd(user); // 100000000000000 wei
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        if (totalDscMinted <= 0) {
            return 1e18; // or more than 1e18. -> i.e., 1e18 + 1
        }
        /*$1000 * 50 / 100 We wanna know what half of the collateral value is                */
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECSION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertHealthFactorIsBroken(address _user) internal view {
        uint256 userHealthFactor = _healthFactor(_user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ///////////////////////////////////////////
    /// Public & External View Functions ///
    /////////////////////////////////////////

    /*
    */
    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // have to get the price of eth
        // if the price of eth is 2000 and we have $1000 of eth how much eht is that? gotta divide the two.
        // The usdAmountInWei divided by the price of eth
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // (10e18 * 1e18) / ($2000 * 1e10)
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountCollateralValueInUsd(address user) public view returns (uint256 totalCollateralValue) {
        //loop through each collateal token, get the amount they have deposited
        // and map it to the price to get the usd value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValue += getUsdValue(token, amount);
        }
        return totalCollateralValue;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECSION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }
    /* 
    */

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }
}
