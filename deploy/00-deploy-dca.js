module.exports = async ({ getNamedAccounts, deployments }) => {
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();
  await deploy("DCA", {
    from: deployer,
    args: [
      "0x056d9AAC902cc2925BB31f6C516B1e1579c35df9", // Oracle
      "0xaCa6FBe30f1557004D261e2D905b82571aC9Bab7", // Beneficiary
      4000, // Initial fee
    ],
    log: true,
  });
};
module.exports.tags = ["DCA"];
