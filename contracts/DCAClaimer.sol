// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./DCA.sol";

contract DCAClaimer is Ownable {
    function claimSwappedAmounts(
        DCA dca,
        address[] calldata userAddresses,
        uint256[] calldata indexes
    ) external returns (bool[] memory) {
        require(
            userAddresses.length == indexes.length,
            "DCAClaimer: Array sizes must match"
        );
        bool[] memory isCompleted = new bool[](userAddresses.length);

        for (uint256 index = 0; index < userAddresses.length; index++) {
            DCA.UserOrder memory order = dca.getUserOrders(
                userAddresses[index]
            )[indexes[index]];
            (, uint256 lastSwapPeriod) = dca.swapStates(
                address(order.sellToken),
                address(order.buyToken)
            );
            uint256 finalPeriod = order.startingPeriod +
                order.numberOfSwaps -
                1;
            isCompleted[index] = finalPeriod <= order.lastPeriodWithdrawal;

            if (
                lastSwapPeriod > order.lastPeriodWithdrawal &&
                !isCompleted[index]
            ) {
                dca.withdrawSwapped(userAddresses[index], indexes[index]);
            }
        }

        return isCompleted;
    }

    /// Shouldn't be necessary, just in case of emergency
    function emergency(IERC20 token) external onlyOwner {
        require(
            token.transfer(msg.sender, token.balanceOf(address(this))),
            "DCAClaimer: Emergency withdrawal failed"
        );
    }
}
