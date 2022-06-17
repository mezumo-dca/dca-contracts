//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ISwappaRouter.sol";
import "./interfaces/ISwapper.sol";
import "./DCA.sol";

contract SwapExecutor is ISwapper, Ownable {
    event BeneficiarySet(address newBeneficiary);

    DCA private dca;
    ISwappaRouterV1 private swappaRouter;
    address public beneficiary;

    constructor(
        DCA _dca,
        ISwappaRouterV1 _swappaRouter,
        address _beneficiary
    ) {
        dca = _dca;
        swappaRouter = _swappaRouter;
        setBeneficiary(_beneficiary);
    }

    function setBeneficiary(address _beneficiary) public onlyOwner {
        beneficiary = _beneficiary;
        emit BeneficiarySet(_beneficiary);
    }

    function executeMezumoSwap(
        uint256 period,
        address[] calldata path,
        address[] calldata pairs,
        bytes[] calldata extras
    ) external {
        bytes memory params = abi.encode(path, pairs, extras);
        dca.executeOrder(
            path[0],
            path[path.length - 1],
            period,
            address(this),
            params
        );
    }

    function swap(
        address _sellToken,
        address _buyToken,
        uint256 _inAmount,
        uint256 _outAmount,
        bytes calldata _params
    ) external {
        (
            address[] memory path,
            address[] memory pairs,
            bytes[] memory extras
        ) = abi.decode(_params, (address[], address[], bytes[]));

        require(
            IERC20(_sellToken).approve(address(swappaRouter), _inAmount),
            "SwapExecutor: Approval to Swappa failed"
        );
        swappaRouter.swapExactInputForOutput(
            path,
            pairs,
            extras,
            _inAmount,
            _outAmount,
            address(this),
            block.timestamp
        );

        require(
            IERC20(_buyToken).transfer(address(dca), _outAmount),
            "SwapExecutor: Transfer to DCA failed"
        );
        require(
            IERC20(_buyToken).transfer(
                beneficiary,
                IERC20(_buyToken).balanceOf(address(this))
            ),
            "SwapExecutor: Transfer to DCA failed"
        );
    }

    function emergency(IERC20 token) external {
        require(
            token.transfer(beneficiary, token.balanceOf(address(this))),
            "SwapExecutor: Emergency withdrawal failed"
        );
    }
}
