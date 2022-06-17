//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/ISwapper.sol";
import "./interfaces/IOracle.sol";

contract DCA is Ownable {
    uint256 public constant BLOCKS_PER_DAY = 17280;
    uint256 public constant MAX_FEE_NUMERATOR = 6_000; // max 60 bps.
    uint256 public constant FEE_DENOMINATOR = 1_000_000;

    event OrderCreated(
        address indexed userAddress,
        uint256 index,
        IERC20 indexed sellToken,
        IERC20 indexed buyToken,
        uint256 amountPerSwap,
        uint256 numberOfSwaps,
        uint256 startingPeriod
    );
    event SwapExecuted(
        address indexed sellToken,
        address indexed buyToken,
        uint256 sellAmount,
        uint256 buyAmount,
        uint256 indexed period
    );
    event SwappedWithdrawal(
        address indexed userAddress,
        uint256 indexed index,
        address indexed token,
        uint256 amount
    );
    event RemainingWithdrawal(
        address indexed userAddress,
        uint256 indexed index,
        address indexed token,
        uint256 amount
    );
    event TokenPairInitialized(address sellToken, address buyToken);
    event EmergencyWithdrawal(address token, uint256 amount, address to);
    event OracleSet(address oracle);
    event OracleAddressMappingSet(address from, address to);
    event BeneficiarySet(address newBeneficiary);
    event FeeNumeratorSet(uint256 feeNumerator);

    struct UserOrder {
        IERC20 sellToken;
        IERC20 buyToken;
        uint256 amountPerSwap;
        uint256 numberOfSwaps;
        uint256 startingPeriod;
        uint256 lastPeriodWithdrawal;
    }

    struct SwapOrder {
        uint256 amountToSwap;
        uint256 lastPeriod;
        // For each past period, what exchange rate was used.
        mapping(uint256 => uint256) swapExchangeRates;
        // For each future period, how much to reduce to |amountToSwap|.
        mapping(uint256 => uint256) amountsToReduce;
        // The fee numerator used on each period's swap.
        mapping(uint256 => uint256) feeOnPeriod;
    }

    // sellToken => buyToken => SwapOrder
    mapping(address => mapping(address => SwapOrder)) public swapOrders;
    // userAddress => UserOrder list
    mapping(address => UserOrder[]) public orders;
    // For cUSD, we need to use mcUSD in the oracle because of Ubeswap liquidity. Same with cEUR/cREAL.
    mapping(address => address) public oracleAddresses;

    uint256 public feeNumerator;
    address public beneficiary;
    Oracle public oracle;

    constructor(
        Oracle _oracle,
        address _beneficiary,
        uint256 initialFee
    ) {
        setOracle(_oracle);
        setBeneficiary(_beneficiary);
        setFeeNumerator(initialFee);
    }

    function createOrder(
        IERC20 _sellToken,
        IERC20 _buyToken,
        uint256 _amountPerSwap,
        uint256 _numberOfSwaps
    ) external returns (uint256 index) {
        require(
            _sellToken.transferFrom(
                msg.sender,
                address(this),
                _amountPerSwap * _numberOfSwaps
            ),
            "DCA: Not enough funds"
        );

        SwapOrder storage swapOrder = swapOrders[address(_sellToken)][
            address(_buyToken)
        ];
        if (swapOrder.lastPeriod == 0) {
            swapOrder.lastPeriod = getCurrentPeriod() - 1;
            emit TokenPairInitialized(address(_sellToken), address(_buyToken));
        }
        uint256 startingPeriod = swapOrder.lastPeriod + 1;
        UserOrder memory newOrder = UserOrder(
            _sellToken,
            _buyToken,
            _amountPerSwap,
            _numberOfSwaps,
            startingPeriod,
            swapOrder.lastPeriod
        );

        swapOrder.amountToSwap += _amountPerSwap;
        swapOrder.amountsToReduce[
            startingPeriod + _numberOfSwaps - 1
        ] += _amountPerSwap;

        index = orders[msg.sender].length;
        orders[msg.sender].push(newOrder);

        emit OrderCreated(
            msg.sender,
            index,
            _sellToken,
            _buyToken,
            _amountPerSwap,
            _numberOfSwaps,
            startingPeriod
        );
    }

    function executeOrder(
        address _sellToken,
        address _buyToken,
        uint256 _period,
        address _swapper,
        bytes memory _params
    ) external {
        SwapOrder storage swapOrder = swapOrders[_sellToken][_buyToken];
        require(swapOrder.lastPeriod + 1 == _period, "DCA: Invalid period");
        require(
            _period <= getCurrentPeriod(),
            "DCA: Period cannot be in the future"
        );
        uint256 fee = (swapOrder.amountToSwap * feeNumerator) / FEE_DENOMINATOR;
        uint256 swapAmount = swapOrder.amountToSwap - fee;

        uint256 requiredAmount = oracle.consult(
            getOracleTokenAddress(_sellToken),
            swapAmount,
            getOracleTokenAddress(_buyToken)
        );
        require(requiredAmount > 0, "DCA: Oracle failure");

        swapOrder.lastPeriod++;
        swapOrder.swapExchangeRates[_period] =
            (requiredAmount * 1e18) /
            swapAmount;
        swapOrder.amountToSwap -= swapOrder.amountsToReduce[_period];
        swapOrder.feeOnPeriod[_period] = feeNumerator;

        require(
            IERC20(_sellToken).transfer(beneficiary, fee),
            "DCA: Fee transfer to beneficiary failed"
        );

        uint256 balanceBefore = IERC20(_buyToken).balanceOf(address(this));
        require(
            IERC20(_sellToken).transfer(_swapper, swapAmount),
            "DCA: Transfer to Swapper failed"
        );
        ISwapper(_swapper).swap(
            _sellToken,
            _buyToken,
            swapAmount,
            requiredAmount,
            _params
        );
        require(
            balanceBefore + requiredAmount <=
                IERC20(_buyToken).balanceOf(address(this)),
            "DCA: Not enough balance returned"
        );

        emit SwapExecuted(
            _sellToken,
            _buyToken,
            swapAmount,
            requiredAmount,
            _period
        );
    }

    function withdrawSwapped(uint256 index) public {
        UserOrder storage order = orders[msg.sender][index];
        (
            uint256 amountToWithdraw,
            uint256 finalPeriod
        ) = calculateAmountToWithdraw(order);
        order.lastPeriodWithdrawal = finalPeriod;

        require(
            order.buyToken.transfer(msg.sender, amountToWithdraw),
            "DCA: Not enough funds to withdraw"
        );

        emit SwappedWithdrawal(
            msg.sender,
            index,
            address(order.buyToken),
            amountToWithdraw
        );
    }

    function withdrawAll(uint256 index) external {
        withdrawSwapped(index);

        UserOrder storage order = orders[msg.sender][index];
        SwapOrder storage swapOrder = swapOrders[address(order.sellToken)][
            address(order.buyToken)
        ];

        uint256 finalPeriod = order.startingPeriod + order.numberOfSwaps - 1;

        if (finalPeriod > swapOrder.lastPeriod) {
            swapOrder.amountToSwap -= order.amountPerSwap;
            swapOrder.amountsToReduce[finalPeriod] -= order.amountPerSwap;
            uint256 amountToWithdraw = order.amountPerSwap *
                (finalPeriod - swapOrder.lastPeriod);
            order.lastPeriodWithdrawal = finalPeriod;

            require(
                order.sellToken.transfer(msg.sender, amountToWithdraw),
                "DCA: Not enough funds to withdraw"
            );

            emit RemainingWithdrawal(
                msg.sender,
                index,
                address(order.sellToken),
                amountToWithdraw
            );
        }
    }

    function emergencyWithdrawal(IERC20 token, address to) external onlyOwner {
        uint256 balance = token.balanceOf(address(this));
        require(token.transfer(to, balance), "DCA: Emergency transfer failed");
        emit EmergencyWithdrawal(address(token), balance, to);
    }

    // Parameter setters

    function setOracle(Oracle _newOracle) public onlyOwner {
        oracle = _newOracle;
        emit OracleSet(address(oracle));
    }

    function setBeneficiary(address _beneficiary) public onlyOwner {
        beneficiary = _beneficiary;
        emit BeneficiarySet(_beneficiary);
    }

    function setFeeNumerator(uint256 _feeNumerator) public onlyOwner {
        feeNumerator = _feeNumerator;
        emit FeeNumeratorSet(_feeNumerator);
    }

    function addAddressMapping(address _from, address _to) external onlyOwner {
        oracleAddresses[_from] = _to;
        emit OracleAddressMappingSet(_from, _to);
    }

    // Views

    function calculateAmountToWithdraw(UserOrder memory order)
        public
        view
        returns (uint256 amountToWithdraw, uint256 finalPeriod)
    {
        SwapOrder storage swapOrder = swapOrders[address(order.sellToken)][
            address(order.buyToken)
        ];
        finalPeriod = Math.min(
            swapOrder.lastPeriod,
            order.startingPeriod + order.numberOfSwaps - 1
        );
        amountToWithdraw = 0;
        for (
            uint256 period = order.lastPeriodWithdrawal + 1;
            period <= finalPeriod;
            period++
        ) {
            uint256 periodSwapAmount = (swapOrder.swapExchangeRates[period] *
                order.amountPerSwap) / 1e18;
            uint256 fee = (periodSwapAmount * feeNumerator) / FEE_DENOMINATOR;
            amountToWithdraw += periodSwapAmount - fee;
        }
    }

    function calculateAmountWithdrawn(UserOrder memory order)
        public
        view
        returns (uint256 amountWithdrawn)
    {
        SwapOrder storage swapOrder = swapOrders[address(order.sellToken)][
            address(order.buyToken)
        ];

        amountWithdrawn = 0;
        for (
            uint256 period = order.startingPeriod;
            period <= order.lastPeriodWithdrawal;
            period++
        ) {
            uint256 periodWithdrawAmount = (swapOrder.swapExchangeRates[
                period
            ] * order.amountPerSwap) / 1e18;
            uint256 fee = (periodWithdrawAmount * feeNumerator) /
                FEE_DENOMINATOR;
            amountWithdrawn += periodWithdrawAmount - fee;
        }
    }

    function getUserOrders(address userAddress)
        external
        view
        returns (UserOrder[] memory)
    {
        return orders[userAddress];
    }

    function getUserOrdersWithExtras(address userAddress)
        external
        view
        returns (
            UserOrder[] memory,
            uint256[] memory,
            uint256[] memory,
            uint256[] memory,
            uint256
        )
    {
        UserOrder[] memory userOrders = orders[userAddress];
        uint256[] memory ordersLastPeriod = new uint256[](userOrders.length);
        uint256[] memory amountsToWithdraw = new uint256[](userOrders.length);
        uint256[] memory amountsWithdrawn = new uint256[](userOrders.length);

        for (uint256 i = 0; i < userOrders.length; i++) {
            UserOrder memory order = userOrders[i];
            (
                uint256 amountToWithdraw,
                uint256 finalPeriod
            ) = calculateAmountToWithdraw(order);
            ordersLastPeriod[i] = finalPeriod;
            amountsToWithdraw[i] = amountToWithdraw;
            amountsWithdrawn[i] = calculateAmountWithdrawn(order);
        }

        return (
            userOrders,
            ordersLastPeriod,
            amountsToWithdraw,
            amountsWithdrawn,
            getCurrentPeriod()
        );
    }

    function getOrder(address userAddress, uint256 index)
        external
        view
        returns (UserOrder memory)
    {
        return orders[userAddress][index];
    }

    function getSwapOrderAmountToReduce(
        address _sellToken,
        address _buyToken,
        uint256 _period
    ) external view returns (uint256) {
        return swapOrders[_sellToken][_buyToken].amountsToReduce[_period];
    }

    function getSwapOrderExchangeRate(
        address _sellToken,
        address _buyToken,
        uint256 _period
    ) external view returns (uint256) {
        return swapOrders[_sellToken][_buyToken].swapExchangeRates[_period];
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

    function getCurrentPeriod() public view returns (uint256 period) {
        period = block.number / BLOCKS_PER_DAY;
    }
}
