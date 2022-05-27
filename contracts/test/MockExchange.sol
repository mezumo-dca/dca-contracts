//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../IExchange.sol";
import "hardhat/console.sol";

contract MockExchange is IExchange {
    ERC20 public stableToken;
    ERC20 public celo;

    constructor(ERC20 _stableToken, ERC20 _celo) {
        stableToken = _stableToken;
        celo = _celo;
    }

    function sell(
        uint256 sellAmount,
        uint256,
        bool sellGold
    ) external returns (uint256) {
        require(!sellGold, "Mock Exchange only allows selling");

        uint256 stableBalance = stableToken.balanceOf(address(this));
        uint256 celoBalance = celo.balanceOf(address(this));
        uint256 amountToBuy = sellAmount * celoBalance / stableBalance;

        require(
            stableToken.transferFrom(msg.sender, address(this), sellAmount),
            "Getting stable tokens failed"
        );

        require(
            celo.transfer(msg.sender, amountToBuy),
            "Not enough funds to exchange"
        );
        return amountToBuy;
    }
}
