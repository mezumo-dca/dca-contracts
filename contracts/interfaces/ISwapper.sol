//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

interface ISwapper {
    function swap(
        address _sellToken,
        address _buyToken,
        uint256 _inAmount,
        uint256 _outAmount,
        bytes calldata _params
    ) external;
}
