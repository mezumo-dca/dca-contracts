import { ContractTransaction } from "@ethersproject/contracts";
import { BigNumber } from "ethers";
import { ethers } from "hardhat";

export async function awaitTx(txPromise: Promise<ContractTransaction>) {
  const tx = await txPromise;
  await tx.wait();
}

const decimals = BigNumber.from(10).pow(18);

// The divisor is to allow creating decimal numbers, since BigNumber doesn't support it.
// ie calling wei(25, 10) creates 2.5 wei.
export function wei(value: number, divisor: number = 1) {
  return BigNumber.from(value).div(divisor).mul(decimals);
}

export async function mineNBlocks(n: number) {
  for (let index = 0; index < n; index++) {
    await ethers.provider.send("evm_mine", []);
  }
}
