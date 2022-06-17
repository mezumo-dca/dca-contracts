/* eslint-disable no-unused-vars */

import { BigNumber } from "ethers";
import { ethers } from "hardhat";
import { awaitTx, wei } from "../test/utils";

const DCA_ADDRESS = "0x0e0f930d4712c2104D8A5AEAf65f2c77a57fc3ec";

async function approve(token: string, spender: string, amount: BigNumber) {
  const factory = await ethers.getContractFactory("ERC20");
  const erc20 = await factory.attach(token);

  await awaitTx(erc20.approve(spender, amount));
}

async function createOrder() {
  const factory = await ethers.getContractFactory("DCA");
  const DCA = await factory.attach(DCA_ADDRESS);

  await approve(
    "0x471EcE3750Da237f93B8E339c536989b8978a438",
    DCA_ADDRESS,
    wei(1, 100)
  );

  await awaitTx(
    DCA.createOrder(
      "0x471EcE3750Da237f93B8E339c536989b8978a438",
      "0x765DE816845861e75A25fCA122bb6898B8B1282a",
      wei(1, 1000),
      10,
      {
        gasLimit: 1000000,
      }
    )
  );

  // console.log((await swapper.feeNumerator()).toString());
  // await awaitTx(swapper.setFeeNumerator(1000));
}

async function addAddressMapping() {
  const factory = await ethers.getContractFactory("DCA");
  const DCA = await factory.attach(DCA_ADDRESS);

  // cUSD
  await awaitTx(
    DCA.addAddressMapping(
      "0x765DE816845861e75A25fCA122bb6898B8B1282a",
      "0x918146359264c492bd6934071c6bd31c854edbc3"
    )
  );
  // cEUR
  await awaitTx(
    DCA.addAddressMapping(
      "0xD8763CBa276a3738E6DE85b4b3bF5FDed6D6cA73",
      "0xE273Ad7ee11dCfAA87383aD5977EE1504aC07568"
    )
  );
}

async function setOracle() {
  const factory = await ethers.getContractFactory("DCA");
  const DCA = await factory.attach(DCA_ADDRESS);

  await awaitTx(DCA.setOracle("0x3DCEE4f51484D288542315bc15D3ca2357C8ea3B"));
}

async function printExchangeRate() {
  const factory = await ethers.getContractFactory("DCA");
  const DCA = await factory.attach(DCA_ADDRESS);

  const swapOrder = await DCA.swapOrders(
    "0x471EcE3750Da237f93B8E339c536989b8978a438",
    "0x765DE816845861e75A25fCA122bb6898B8B1282a"
  );
  console.log('amountToSwap', swapOrder.amountToSwap.toString());
  console.log('lastPeriod', swapOrder.lastPeriod.toString());
  console.log(
    (
      await DCA.getSwapOrderExchangeRate(
        "0x471EcE3750Da237f93B8E339c536989b8978a438",
        "0x765DE816845861e75A25fCA122bb6898B8B1282a",
        783
      )
    ).toString()
  );
}

async function main() {
  await addAddressMapping();

  // await printExchangeRate();
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
