// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

pragma solidity 0.8.30;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DenaroChainCoin
 * @notice Collateral: Exogenous (ETH & BTC)
 * @notice Minting: Algorithmic
 * @notice Relative Stability: Pegged to USD
 *
 * This is the contract meant to be governet by DNCCEngine. This contract is just the ERC20
 *   implementation of our stablecoin system.
 *
 */
contract DenaroChainCoin is ERC20Burnable, Ownable {
    error MustBeMoreThanZero();
    error BurnAmountExceedsBalance();
    error NoZeroAddress();

    constructor() ERC20("DenaroChainCoin", "DNCC") Ownable(msg.sender) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);

        require(_amount > 0, MustBeMoreThanZero());
        require(balance >= _amount, BurnAmountExceedsBalance());

        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        require(_to != address(0), NoZeroAddress());
        require(_amount >= 0, MustBeMoreThanZero());

        _mint(_to, _amount);

        return true;
    }
}
