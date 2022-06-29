import { expect } from "chai";
import { BigNumber, Contract } from "ethers";
import { ethers } from "hardhat";
import { awaitTx, mineNBlocks, wei } from "./utils";

async function deployMockTokens() {
  const erc20Factory = await ethers.getContractFactory("MockERC20");
  const mockcUSD = await erc20Factory.deploy("cUSD", "cUSD", wei(2000));
  const mockCELO = await erc20Factory.deploy("CELO", "CELO", wei(2000));

  await mockcUSD.deployed();
  await mockCELO.deployed();

  const oracle = await ethers.getContractFactory("MockOracle");
  const mockOracle = await oracle.deploy();
  await mockOracle.deployed();

  const swapper = await ethers.getContractFactory("MockSwapper");
  const mockSwapper = await swapper.deploy();
  await mockSwapper.deployed();

  await awaitTx(mockcUSD.transfer(mockSwapper.address, wei(500)));
  await awaitTx(mockCELO.transfer(mockSwapper.address, wei(500)));

  return {
    cUSD: mockcUSD,
    CELO: mockCELO,
    oracle: mockOracle,
    swapper: mockSwapper,
  };
}

async function goToNextPeriod() {
  await mineNBlocks(17280);
}

describe("DCA", function () {
  let cUSD: Contract;
  let CELO: Contract;
  let oracle: Contract;
  let swapper: Contract;

  let DCA: Contract;
  let DCAViewer: Contract;

  beforeEach(async () => {
    const mocks = await deployMockTokens();
    cUSD = mocks.cUSD;
    CELO = mocks.CELO;
    oracle = mocks.oracle;
    swapper = mocks.swapper;

    const [, beneficiary] = await ethers.getSigners();

    const DCAFactory = await ethers.getContractFactory("DCA");
    DCA = await DCAFactory.deploy(oracle.address, beneficiary.address, 1000);
    await DCA.deployed();
    const DCAViewerFactory = await ethers.getContractFactory("DCAViewer");
    DCAViewer = await DCAViewerFactory.deploy();
    await DCAViewer.deployed();
  });

  before(async () => {
    await goToNextPeriod();
    await goToNextPeriod();
  });

  async function createOrder({
    amountPerSwap = wei(10),
    numberOfSwaps = 10,
  }: {
    amountPerSwap?: BigNumber;
    numberOfSwaps?: number;
  }) {
    await awaitTx(cUSD.approve(DCA.address, amountPerSwap.mul(numberOfSwaps)));
    await awaitTx(
      DCA.createOrder(cUSD.address, CELO.address, amountPerSwap, numberOfSwaps)
    );
  }

  it("Should create orders properly", async function () {
    const [account] = await ethers.getSigners();

    expect(await DCA.getUserOrders(account.address)).to.be.empty;

    // Should require approval first.
    await expect(
      DCA.createOrder(cUSD.address, CELO.address, wei(10), 10)
    ).to.be.revertedWith("ERC20: insufficient allowance");

    await createOrder({});

    expect(await cUSD.balanceOf(DCA.address)).to.eq(wei(100));
    expect(await cUSD.balanceOf(account.address)).to.eq(wei(1400));

    const createdOrders = await DCA.getUserOrders(account.address);
    expect(createdOrders.length).to.eq(1);

    expect(createdOrders[0].sellToken).to.eq(cUSD.address);
    expect(createdOrders[0].buyToken).to.eq(CELO.address);
    expect(createdOrders[0].amountPerSwap).to.eq(wei(10));
    expect(createdOrders[0].numberOfSwaps).to.eq(10);
    expect(createdOrders[0].startingPeriod).to.eq(2);
    expect(createdOrders[0].lastPeriodWithdrawal).to.eq(1);

    const swapState = await DCA.swapStates(cUSD.address, CELO.address);
    expect(swapState.amountToSwap).to.eq(wei(10));
    expect(swapState.lastSwapPeriod).to.eq(1);
    expect(
      await DCAViewer.getSwapStateAmountToReduce(
        DCA.address,
        cUSD.address,
        CELO.address,
        11
      )
    ).to.eq(wei(10));
  });

  it("should execute orders", async () => {
    await createOrder({});

    const beforeCusd = await cUSD.balanceOf(DCA.address);
    const beforeCelo = await CELO.balanceOf(DCA.address);

    await awaitTx(
      DCA.executeOrder(cUSD.address, CELO.address, 2, swapper.address, [])
    );

    const afterCusd = await cUSD.balanceOf(DCA.address);
    const afterCelo = await CELO.balanceOf(DCA.address);

    expect(afterCusd).to.eq(beforeCusd.sub(wei(10)));
    const fee = wei(10).mul(1_000).div(1_000_000);
    const swappedAmount = wei(10).sub(fee).mul(2);
    expect(afterCelo).to.eq(beforeCelo.add(swappedAmount));

    const swapState = await DCA.swapStates(cUSD.address, CELO.address);
    expect(swapState.amountToSwap).to.eq(wei(10));
    expect(swapState.lastSwapPeriod).to.eq(2);
    expect(
      await DCAViewer.getSwapStateExchangeRate(
        DCA.address,
        cUSD.address,
        CELO.address,
        2
      )
    ).to.eq(wei(2));

    // Should not allow executing the same period again.
    await expect(
      DCA.executeOrder(cUSD.address, CELO.address, 2, swapper.address, [])
    ).to.be.revertedWith("DCA: Invalid period");
  });

  it("should execute orders with the right amounts", async () => {
    await createOrder({ numberOfSwaps: 2 });

    await awaitTx(
      DCA.executeOrder(cUSD.address, CELO.address, 2, swapper.address, [])
    );
    let swapState = await DCA.swapStates(cUSD.address, CELO.address);
    expect(swapState.amountToSwap).to.eq(wei(10));

    const exchangeRate = await DCAViewer.getSwapStateExchangeRate(
      DCA.address,
      cUSD.address,
      CELO.address,
      2
    );
    expect(exchangeRate).to.eq(wei(2));

    await goToNextPeriod();

    await awaitTx(
      DCA.executeOrder(cUSD.address, CELO.address, 3, swapper.address, [])
    );
    swapState = await DCA.swapStates(cUSD.address, CELO.address);
    expect(swapState.amountToSwap).to.eq(0);
  });

  it("should allow withdrawals", async () => {
    const [account] = await ethers.getSigners();

    const startingPeriod = await DCA.getCurrentPeriod();

    await createOrder({ amountPerSwap: wei(1), numberOfSwaps: 2 });

    await awaitTx(
      DCA.executeOrder(
        cUSD.address,
        CELO.address,
        startingPeriod,
        swapper.address,
        []
      )
    );

    const beforeCelo = await CELO.balanceOf(account.address);

    await awaitTx(DCA.withdrawSwapped(0));

    const afterCelo = await CELO.balanceOf(account.address);

    const fee = wei(1).mul(1_000).div(1_000_000);
    const swappedAmount = wei(1).sub(fee).mul(2);
    expect(afterCelo).to.eq(beforeCelo.add(swappedAmount));

    let order = await DCAViewer.getOrder(DCA.address, account.address, 0);
    expect(order.lastPeriodWithdrawal).to.eq(startingPeriod);
    const amountWithdrawn = await DCAViewer.calculateAmountWithdrawn(
      DCA.address,
      order
    );
    expect(amountWithdrawn).to.eq(swappedAmount);

    // WITHDRAW ALL

    expect(
      await DCAViewer.getSwapStateAmountToReduce(
        DCA.address,
        cUSD.address,
        CELO.address,
        startingPeriod.add(1)
      )
    ).to.eq(wei(1));

    const beforeCUSD = await cUSD.balanceOf(account.address);
    await awaitTx(DCA.withdrawAll(0));

    const afterCUSD = await cUSD.balanceOf(account.address);

    expect(afterCUSD).to.eq(beforeCUSD.add(wei(1)));

    order = await DCAViewer.getOrder(DCA.address, account.address, 0);
    expect(order.lastPeriodWithdrawal).to.eq(startingPeriod.add(1));

    const swapState = await DCA.swapStates(cUSD.address, CELO.address);
    expect(swapState.amountToSwap).to.eq(0);

    expect(
      await DCAViewer.getSwapStateAmountToReduce(
        DCA.address,
        cUSD.address,
        CELO.address,
        startingPeriod.add(1)
      )
    ).to.eq(0);
  });

  it("uses reasonable amount of gas when withdrawing after doing DCA for 365 days", async () => {
    const startingPeriod = await DCA.getCurrentPeriod();

    await createOrder({ amountPerSwap: wei(1, 1000), numberOfSwaps: 365 });

    for (let i = 0; i < 365; i++) {
      await awaitTx(
        DCA.executeOrder(
          cUSD.address,
          CELO.address,
          startingPeriod.add(i),
          swapper.address,
          []
        )
      );
      await goToNextPeriod();
    }

    const receipt = await awaitTx(DCA.withdrawSwapped(0));

    // At current gas prices in Celo, this is equivalent to 0.1 CELO or $0.10.
    // We will prevent longer periods than this from the UI.
    // Also, withdrawing periodically will cause the gas cost to be lower.
    expect(receipt.gasUsed).to.eq(2_719_185);
  });
});
