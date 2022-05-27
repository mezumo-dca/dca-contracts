import { expect } from "chai";
import { Contract } from "ethers";
import { ethers } from "hardhat";
import { awaitTx, mineNBlocks, wei } from "./utils";

// const CELO = "0x471EcE3750Da237f93B8E339c536989b8978a438";
// const cUSD = "0x765de816845861e75a25fca122bb6898b8b1282a";
// const cUSD_EXCHANGE = "0x67316300f17f063085ca8bca4bd3f7a5a3c66275";

async function deployMockTokens() {
  const erc20Factory = await ethers.getContractFactory("MockERC20");
  const mockcUSD = await erc20Factory.deploy("cUSD", "cUSD", wei(2000));
  const mockCELO = await erc20Factory.deploy("CELO", "CELO", wei(2000));

  await mockcUSD.deployed();
  await mockCELO.deployed();

  const exchangeFactory = await ethers.getContractFactory("MockExchange");
  const mockcUSDExchange = await exchangeFactory.deploy(
    mockcUSD.address,
    mockCELO.address
  );

  await mockcUSDExchange.deployed();

  await awaitTx(mockcUSD.transfer(mockcUSDExchange.address, wei(1000)));
  await awaitTx(mockCELO.transfer(mockcUSDExchange.address, wei(500)));

  return {
    cUSD: mockcUSD,
    CELO: mockCELO,
    cUSDExchange: mockcUSDExchange,
  };
}

describe("DCA", function () {
  let cUSD: Contract;
  let CELO: Contract;
  let cUSDExchange: Contract;

  let DCA: Contract;

  beforeEach(async () => {
    const mocks = await deployMockTokens();
    cUSD = mocks.cUSD;
    CELO = mocks.CELO;
    cUSDExchange = mocks.cUSDExchange;

    const DCAFactory = await ethers.getContractFactory("DCA");
    DCA = await DCAFactory.deploy(cUSD.address, cUSDExchange.address);
    await DCA.deployed();
  });

  it("Should create orders properly", async function () {
    const [account] = await ethers.getSigners();

    expect(await DCA.getUserOrders(account.address)).to.be.empty;

    // Should require approval first.
    await expect(
      DCA.createOrder(cUSD.address, CELO.address, wei(100), wei(10), 12)
    ).to.be.revertedWith("ERC20: insufficient allowance");

    await awaitTx(cUSD.approve(DCA.address, wei(100)));
    await awaitTx(
      DCA.createOrder(cUSD.address, CELO.address, wei(100), wei(10), 12)
    );

    expect(await cUSD.balanceOf(DCA.address)).to.eq(wei(100));
    expect(await cUSD.balanceOf(account.address)).to.eq(wei(900));

    const createdOrders = await DCA.getUserOrders(account.address);
    expect(createdOrders.length).to.eq(1);

    expect(createdOrders[0].sellToken).to.eq(cUSD.address);
    expect(createdOrders[0].buyToken).to.eq(CELO.address);
    expect(createdOrders[0].total).to.eq(wei(100));
    expect(createdOrders[0].spent).to.eq(wei(0));
    expect(createdOrders[0].amountPerPurchase).to.eq(wei(10));
    expect(createdOrders[0].blocksBetweenPurchases).to.eq(12);
    expect(createdOrders[0].lastBlock).to.eq(0);
  });

  it("should allow withdrawals", async () => {
    const [account] = await ethers.getSigners();

    // Create order
    await awaitTx(cUSD.approve(DCA.address, wei(100)));
    await awaitTx(
      DCA.createOrder(cUSD.address, CELO.address, wei(100), wei(10), 12)
    );

    // Withdraw
    await awaitTx(DCA.withdraw(0));

    // Checks
    expect(await cUSD.balanceOf(account.address)).to.eq(wei(1000));
    const order = await DCA.getOrder(account.address, 0);
    expect(order.spent).to.eq(wei(100));
  });

  it("should execute orders", async () => {
    const [account] = await ethers.getSigners();

    // Create Order
    await awaitTx(cUSD.approve(DCA.address, wei(100)));
    await awaitTx(
      DCA.createOrder(cUSD.address, CELO.address, wei(100), wei(10), 12)
    );

    const latestBlock = await ethers.provider.getBlock("latest")
  
    // Execute
    await mineNBlocks(12);
    await awaitTx(DCA.executeOrder(account.address, 0));
  
    // Checks
    expect(await cUSD.balanceOf(DCA.address)).to.eq(wei(90));
    expect(await CELO.balanceOf(DCA.address)).to.eq(wei(0));
    expect(await CELO.balanceOf(account.address)).to.eq(wei(1505));
    const order = await DCA.getOrder(account.address, 0);
    expect(order.spent).to.eq(wei(10));
    expect(order.lastBlock).to.eq(latestBlock.number + 12 + 1);
  });
});
