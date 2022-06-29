// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IOracle.sol";

contract OracleWrapper is Ownable, Oracle {
    event OracleSet(address oracle);
    event OracleAddressMappingSet(address from, address to);

    Oracle public oracle;

    /// Mapping from address to swap to address to use in the oracle.
    /// For cUSD, we need to use mcUSD in the oracle because of Ubeswap liquidity. Same with cEUR/cREAL.
    mapping(address => address) public oracleAddresses;

    constructor(Oracle _oracle) {
        setOracle(_oracle);
    }

    function setOracle(Oracle _newOracle) public onlyOwner {
        oracle = _newOracle;
        emit OracleSet(address(oracle));
    }

    function consult(
        address tokenIn,
        uint256 amountIn,
        address tokenOut
    ) external view returns (uint256 amountOut) {
        amountOut = oracle.consult(
            getOracleTokenAddress(tokenIn),
            amountIn,
            getOracleTokenAddress(tokenOut)
        );
    }

    function addAddressMapping(address _from, address _to) external onlyOwner {
        oracleAddresses[_from] = _to;
        emit OracleAddressMappingSet(_from, _to);
    }

    function getOracleTokenAddress(address token)
        public
        view
        returns (address)
    {
        address mappedToken = oracleAddresses[token];
        if (mappedToken != address(0)) {
            return mappedToken;
        } else {
            return token;
        }
    }
}
