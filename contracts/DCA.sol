// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./interfaces/ISwapper.sol";
import "./interfaces/IOracle.sol";

/// @title DCA
/// This contract allows users to deposit one token and gradually swaps it for another one
/// every day at the price it's trading at, allowing user to buy the target token using a
/// Dollar-Cost Averaging (DCA) strategy.
/// @dev To perform the swaps, we aggregate the tokens for all the users and make one big
/// swap instead of many small ones.
contract DCA is Ownable {
    /// Number of blocks in a day assuming 5 seconds per block. Works for the Celo blockchain.
    uint256 public constant BLOCKS_PER_DAY = 17280;
    /// Upper limit of the fee that can be charged on swaps. Has to be divided by
    /// |FEE_DENOMINATOR|. Equivalent to 60bps.
    uint256 public constant MAX_FEE_NUMERATOR = 6_000;
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
    /// Emitted when a user withdraws the funds that were already swapped.
    event SwappedWithdrawal(
        address indexed userAddress,
        uint256 indexed index,
        address indexed token,
        uint256 amount
    );
    /// Emitted when a user withdraws their principal early. ie. before it was swapped.
    event RemainingWithdrawal(
        address indexed userAddress,
        uint256 indexed index,
        address indexed token,
        uint256 amount
    );
    event TokenPairInitialized(address sellToken, address buyToken);
    event EmergencyWithdrawal(address token, uint256 amount, address to);
    event OracleUpdaterChanged(address oracleUpdater);
    event OracleSet(address oracle);
    event BeneficiarySet(address newBeneficiary);
    event FeeNumeratorSet(uint256 feeNumerator);

    /// Contains information about one specific user order.
    /// A period is defined as a block number divided by |BLOCKS_PER_DAY|.
    struct UserOrder {
        IERC20 sellToken;
        IERC20 buyToken;
        uint256 amountPerSwap;
        uint256 numberOfSwaps;
        uint256 startingPeriod;
        uint256 lastPeriodWithdrawal;
    }

    /// Contains information about the swapping status of a token pair.
    struct SwapState {
        uint256 amountToSwap;
        uint256 lastSwapPeriod;
    }

    /// For a given (sellToken, buyToken, period) tuple it returns the exchange rate used (if
    /// the period is in the past), how many daily swap tokens have their last day on that period
    /// and the fee charged in the period if it's in the past.
    struct PeriodSwapState {
        /// For each past period, what exchange rate was used.
        uint256 exchangeRate;
        /// For each future period, how much to reduce to |amountToSwap| in its SwapState.
        uint256 amountToReduce;
        /// For past periods, the fee numerator used on the swap.
        uint256 feeNumerator;
    }

    /// Contains the state of a token pair swaps. For a given (sellToken, buyToken)
    /// it contains how much it should swap in the next period and when the last period was.
    mapping(address => mapping(address => SwapState)) public swapStates;
    /// Contains information related to swaps for a (sellToken, buyToken, period) tuple.
    /// See |PeriodSwapState| for more info.
    mapping(address => mapping(address => mapping(uint256 => PeriodSwapState)))
        public periodsSwapStates;
    /// A list of |UserOrder| for each user address.
    mapping(address => UserOrder[]) public orders;

    /// Active fee on swaps. To be used together with |FEE_DENOMINATOR|.
    uint256 public feeNumerator;
    /// Where to send the fees.
    address public beneficiary;
    /// Oracle to use to get the amount to receive on swaps.
    Oracle public oracle;
    /// If true, the owner can withdraw funds. Should be turned off after there is sufficient confidence
    /// in the code, for example after audits.
    bool public guardrailsOn;
    /// Address that can update the oracle. Matches the owner at first, but should be operated by the
    /// community after a while.
    address public oracleUpdater;

    /// @dev Throws if called by any account other than the oracle updater.
    modifier onlyOracleUpdater() {
        require(
            oracleUpdater == msg.sender,
            "DCA: caller is not the oracle updater"
        );
        _;
    }

    constructor(
        Oracle _oracle,
        address _beneficiary,
        uint256 initialFee
    ) {
        guardrailsOn = true;
        oracleUpdater = msg.sender;
        setOracle(_oracle);
        setBeneficiary(_beneficiary);
        setFeeNumerator(initialFee);
    }

    /// Starts a new DCA position for the |msg.sender|. When creating a new position, we
    /// add the |_amountPerSwap| to the |amountToSwap| variable on |SwapState| and to
    /// |amountToReduce| on the final period's |PeriodSwapState|. Thus, the amount to swap
    /// daily will increase between the current period and the final one.
    /// @param _sellToken token to sell on each period.
    /// @param _buyToken token to buy on each period.
    /// @param _amountPerSwap amount of _sellToken to sell each period.
    /// @param _numberOfSwaps number of periods to do the swapping.
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

        SwapState storage swapState = swapStates[address(_sellToken)][
            address(_buyToken)
        ];
        // If it's the first order for this pair, initialize it.
        if (swapState.lastSwapPeriod == 0) {
            swapState.lastSwapPeriod = getCurrentPeriod() - 1;
            emit TokenPairInitialized(address(_sellToken), address(_buyToken));
        }
        uint256 startingPeriod = swapState.lastSwapPeriod + 1;
        UserOrder memory newOrder = UserOrder(
            _sellToken,
            _buyToken,
            _amountPerSwap,
            _numberOfSwaps,
            startingPeriod,
            swapState.lastSwapPeriod
        );

        swapState.amountToSwap += _amountPerSwap;
        periodsSwapStates[address(_sellToken)][address(_buyToken)][
            startingPeriod + _numberOfSwaps - 1
        ].amountToReduce += _amountPerSwap;

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

    /// Executes a swap between two tokens. The period must be the last executed + 1.
    /// The swapping is done by the |_swapper|. We calculate the required exchange rate using
    /// an oracle, send them the funds to swap and expect them to return the calculated return
    /// amount. This allows us to more easily add pairs since we just need the oracle support,
    /// not the exact routes to follow. Callers are incentivized to call this function for
    /// the arbitrage opportunity.
    ///
    /// In other words, the general logic followed here is:
    /// - Calculate and send the fee to the |beneficiary|.
    /// - Calculate the exchange rate using |oracle|.
    /// - Send the swap amount to |_swapper| can call its |swap| function.
    /// - Check that it returned the required funds taking the exchange rate into account.
    /// @param _sellToken token to sell on the swap.
    /// @param _buyToken token to buy on the swap.
    /// @param _period period to perform the swap for. It has only one possible valid
    /// value, so it is not strictly necessary.
    /// @param _swapper address that will perform the swap.
    /// @param _params params to send to |_swapper| for performing the swap.
    function executeOrder(
        address _sellToken,
        address _buyToken,
        uint256 _period,
        address _swapper,
        bytes memory _params
    ) external {
        SwapState storage swapState = swapStates[_sellToken][_buyToken];
        require(swapState.lastSwapPeriod + 1 == _period, "DCA: Invalid period");
        require(
            _period <= getCurrentPeriod(),
            "DCA: Period cannot be in the future"
        );
        uint256 fee = (swapState.amountToSwap * feeNumerator) / FEE_DENOMINATOR;
        uint256 swapAmount = swapState.amountToSwap - fee;

        uint256 requiredAmount = oracle.consult(
            _sellToken,
            swapAmount,
            _buyToken
        );
        require(requiredAmount > 0, "DCA: Oracle failure");

        PeriodSwapState storage periodSwapState = periodsSwapStates[_sellToken][
            _buyToken
        ][_period];

        swapState.lastSwapPeriod++;
        swapState.amountToSwap -= periodSwapState.amountToReduce;
        periodSwapState.exchangeRate = (requiredAmount * 1e18) / swapAmount;
        periodSwapState.feeNumerator = feeNumerator;

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

    /// Withdraw the funds that were already swapped for the caller user.
    /// @param index the index of the |orders| array for msg.sender.
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

    /// Withdraw the funds that were already swapped for the caller user AND the
    /// funds that were not swapped yet, effectively terminating the position.
    /// @param index the index of the |orders| array for msg.sender.
    function withdrawAll(uint256 index) external {
        withdrawSwapped(index);

        UserOrder storage order = orders[msg.sender][index];
        SwapState storage swapState = swapStates[address(order.sellToken)][
            address(order.buyToken)
        ];

        uint256 finalPeriod = order.startingPeriod + order.numberOfSwaps - 1;

        if (finalPeriod > swapState.lastSwapPeriod) {
            PeriodSwapState storage finalPeriodSwapState = periodsSwapStates[
                address(order.sellToken)
            ][address(order.buyToken)][finalPeriod];

            swapState.amountToSwap -= order.amountPerSwap;
            finalPeriodSwapState.amountToReduce -= order.amountPerSwap;
            uint256 amountToWithdraw = order.amountPerSwap *
                (finalPeriod - swapState.lastSwapPeriod);
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

    function turnOffGuardrails() external onlyOwner {
        guardrailsOn = false;
    }

    /// In case of emergency, in hte beginning the owner can remove the funds to return them to users.
    /// Should be turned off before receiving any meaningful deposits by calling |turnOffGuardrails|.
    function emergencyWithdrawal(IERC20 token, address to) external onlyOwner {
        require(guardrailsOn, "DCA: Guardrails are off");
        uint256 balance = token.balanceOf(address(this));
        require(token.transfer(to, balance), "DCA: Emergency transfer failed");
        emit EmergencyWithdrawal(address(token), balance, to);
    }

    /// Change the address that can update the oracle.
    function setOracleUpdater(address _newOracleUpdater)
        external
        onlyOracleUpdater
    {
        oracleUpdater = _newOracleUpdater;
        emit OracleUpdaterChanged(_newOracleUpdater);
    }

    /// Update the oracle
    function setOracle(Oracle _newOracle) public onlyOracleUpdater {
        oracle = _newOracle;
        emit OracleSet(address(oracle));
    }

    /// Update the beneficiary
    function setBeneficiary(address _beneficiary) public onlyOwner {
        beneficiary = _beneficiary;
        emit BeneficiarySet(_beneficiary);
    }

    /// Update the fee
    function setFeeNumerator(uint256 _feeNumerator) public onlyOwner {
        require(_feeNumerator <= MAX_FEE_NUMERATOR, "DCA: Fee too high");
        feeNumerator = _feeNumerator;
        emit FeeNumeratorSet(_feeNumerator);
    }

    // From here to the bottom of the file are the view calls.

    /// Calculates hoy much |buyToken| is available to withdraw for a user order.
    /// Takes into account previous withdrawals and fee taken.
    function calculateAmountToWithdraw(UserOrder memory order)
        public
        view
        returns (uint256 amountToWithdraw, uint256 finalPeriod)
    {
        SwapState memory swapState = swapStates[address(order.sellToken)][
            address(order.buyToken)
        ];
        finalPeriod = Math.min(
            swapState.lastSwapPeriod,
            order.startingPeriod + order.numberOfSwaps - 1
        );
        amountToWithdraw = 0;
        for (
            uint256 period = order.lastPeriodWithdrawal + 1;
            period <= finalPeriod;
            period++
        ) {
            PeriodSwapState memory periodSwapState = periodsSwapStates[
                address(order.sellToken)
            ][address(order.buyToken)][period];
            uint256 periodSwapAmount = (periodSwapState.exchangeRate *
                order.amountPerSwap) / 1e18;
            uint256 fee = (periodSwapAmount * periodSwapState.feeNumerator) /
                FEE_DENOMINATOR;
            amountToWithdraw += periodSwapAmount - fee;
        }
    }

    function getCurrentPeriod() public view returns (uint256 period) {
        period = block.number / BLOCKS_PER_DAY;
    }

    function getUserOrders(address userAddress)
        external
        view
        returns (UserOrder[] memory)
    {
        return orders[userAddress];
    }

    function getSwapState(address sellToken, address buyToken)
        external
        view
        returns (SwapState memory)
    {
        return swapStates[sellToken][buyToken];
    }

    function getPeriodSwapState(
        address sellToken,
        address buyToken,
        uint256 period
    ) external view returns (PeriodSwapState memory) {
        return periodsSwapStates[sellToken][buyToken][period];
    }
}
