//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "../interfaces/IOracle.sol";

contract MockOracle is Oracle {
    function consult(
        address,
        uint256 amountIn,
        address
    ) external pure returns (uint256 amountOut) {
        amountOut = amountIn * 2;
    }
}
