//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../interfaces/ISwapper.sol";

contract MockSwapper is ISwapper {
    function swap(
        address,
        address _buyToken,
        uint256,
        uint256 _outAmount,
        bytes calldata
    ) external {
        ERC20(_buyToken).transfer(msg.sender, _outAmount);
    }
}
