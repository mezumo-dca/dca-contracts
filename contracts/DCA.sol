//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IExchange.sol";

contract DCA {
    address cUSDAddress;
    IExchange cUSDExchange;

    struct Order {
        IERC20 sellToken;
        IERC20 buyToken;
        uint256 total;
        uint256 spent;
        uint256 amountPerPurchase;
        uint256 blocksBetweenPurchases;
        uint256 lastBlock;
    }

    mapping(address => Order[]) public orders;

    event OrderCreated(
        address indexed userAddress,
        uint256 index,
        uint256 total,
        IERC20 sellToken,
        IERC20 buyToken,
        uint256 amountPerPurchase,
        uint256 blocksBetweenPurchases
    );

    constructor(address _cUSDAddress, IExchange _cUSDExchange) {
        cUSDAddress = _cUSDAddress;
        cUSDExchange = _cUSDExchange;
    }

    function getUserOrders(address userAddress)
        external
        view
        returns (Order[] memory)
    {
        return orders[userAddress];
    }

    function getOrder(address userAddress, uint256 index)
        external
        view
        returns (Order memory)
    {
        return orders[userAddress][index];
    }

    function createOrder(
        IERC20 _sellToken,
        IERC20 _buyToken,
        uint256 _total,
        uint256 _amountPerPurchase,
        uint256 _blocksBetweenPurchases
    ) external returns (uint256 index) {
        require(
            _sellToken.transferFrom(msg.sender, address(this), _total),
            "DCA: Not enough funds"
        );

        Order memory newOrder = Order(
            _sellToken,
            _buyToken,
            _total,
            0,
            _amountPerPurchase,
            _blocksBetweenPurchases,
            0
        );

        index = orders[msg.sender].length;
        orders[msg.sender].push(newOrder);

        emit OrderCreated(
            msg.sender,
            index,
            _total,
            _sellToken,
            _buyToken,
            _amountPerPurchase,
            _blocksBetweenPurchases
        );
    }

    function executeOrder(address userAddress, uint256 index) external {
        Order storage order = orders[userAddress][index];

        require(
            order.lastBlock + order.blocksBetweenPurchases <= block.number,
            "DCA: Not enough time passed yet."
        );
        require(
            order.spent + order.amountPerPurchase <= order.total,
            "DCA: Order fully executed"
        );

        order.spent += order.amountPerPurchase;
        order.lastBlock = block.number;

        IExchange exchange = getMentoExchange(order.sellToken);

        order.sellToken.approve(address(exchange), order.amountPerPurchase);

        // TODO: Arreglar el 0, esto no puede subirse a ningún lado así.
        uint256 boughtAmount = exchange.sell(order.amountPerPurchase, 0, false);
        require(
            order.buyToken.transfer(userAddress, boughtAmount),
            "DCA: buyToken transfer failed"
        );
    }

    function withdraw(uint256 index) external {
        Order storage order = orders[msg.sender][index];

        uint256 amountToWithdraw = order.total - order.spent;
        order.spent = order.total;

        require(
            order.sellToken.transfer(msg.sender, amountToWithdraw),
            "DCA: Not enough funds to withdraw"
        );
    }

    function getMentoExchange(IERC20 token) internal view returns (IExchange) {
        if (address(token) == cUSDAddress) {
            return cUSDExchange;
        }
        revert("DCA: Exchange not found");
    }
}
