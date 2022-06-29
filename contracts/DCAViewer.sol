// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./DCA.sol";

contract DCAViewer is Ownable {
    /// Calculates hoy much |buyToken| has already been withdrawn for a user order.
    /// Takes into account fees taken.
    function calculateAmountWithdrawn(DCA dca, DCA.UserOrder memory order)
        public
        view
        returns (uint256 amountWithdrawn)
    {
        amountWithdrawn = 0;
        for (
            uint256 period = order.startingPeriod;
            period <= order.lastPeriodWithdrawal;
            period++
        ) {
            DCA.PeriodSwapState memory periodSwapState = dca.getPeriodSwapState(
                address(order.sellToken),
                address(order.buyToken),
                period
            );
            uint256 periodWithdrawAmount = (periodSwapState.exchangeRate *
                order.amountPerSwap) / 1e18;
            uint256 fee = (periodWithdrawAmount *
                periodSwapState.feeNumerator) / dca.FEE_DENOMINATOR();
            amountWithdrawn += periodWithdrawAmount - fee;
        }
    }

    /// Returns the orders for a user with more information that can be shown on a front end.
    /// Might not work well if the user has too many orders, it's just for short-term convenience.
    function getUserOrdersWithExtras(DCA dca, address userAddress)
        external
        view
        returns (
            DCA.UserOrder[] memory,
            uint256[] memory,
            uint256[] memory,
            uint256[] memory,
            uint256
        )
    {
        DCA.UserOrder[] memory userOrders = dca.getUserOrders(userAddress);
        uint256[] memory ordersLastPeriod = new uint256[](userOrders.length);
        uint256[] memory amountsToWithdraw = new uint256[](userOrders.length);
        uint256[] memory amountsWithdrawn = new uint256[](userOrders.length);

        for (uint256 i = 0; i < userOrders.length; i++) {
            DCA.UserOrder memory order = userOrders[i];
            (uint256 amountToWithdraw, uint256 finalPeriod) = dca
                .calculateAmountToWithdraw(order);
            ordersLastPeriod[i] = finalPeriod;
            amountsToWithdraw[i] = amountToWithdraw;
            amountsWithdrawn[i] = calculateAmountWithdrawn(dca, order);
        }

        return (
            userOrders,
            ordersLastPeriod,
            amountsToWithdraw,
            amountsWithdrawn,
            dca.getCurrentPeriod()
        );
    }

    function getOrder(
        DCA dca,
        address userAddress,
        uint256 index
    ) external view returns (DCA.UserOrder memory) {
        return dca.getUserOrders(userAddress)[index];
    }

    function getSwapStateAmountToReduce(
        DCA dca,
        address _sellToken,
        address _buyToken,
        uint256 _period
    ) external view returns (uint256) {
        return
            dca
                .getPeriodSwapState(_sellToken, _buyToken, _period)
                .amountToReduce;
    }

    function getSwapStateExchangeRate(
        DCA dca,
        address _sellToken,
        address _buyToken,
        uint256 _period
    ) external view returns (uint256) {
        return
            dca.getPeriodSwapState(_sellToken, _buyToken, _period).exchangeRate;
    }

    function emergency(IERC20 token) external onlyOwner {
        require(
            token.transfer(msg.sender, token.balanceOf(address(this))),
            "SwapExecutor: Emergency withdrawal failed"
        );
    }
}
