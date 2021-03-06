module.exports = async ({ getNamedAccounts, deployments }) => {
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();
  await deploy("SwapExecutor", {
    from: deployer,
    args: [
      "0xF35ed7156BABF2541E032B3bB8625210316e2832", // Swappa
      "0x76efD61146049612A78Fa3e0E9BD0a8Febc9dCe0", // Beneficiary
    ],
    log: true,
  });
};
module.exports.tags = ["SwapExecutor"];
