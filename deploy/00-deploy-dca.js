module.exports = async ({ getNamedAccounts, deployments }) => {
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();
  await deploy("DCA", {
    from: deployer,
    args: [
      "0xF00979c09aC0c2e825d82480272cC91398e57cd6", // Oracle
      "0xaCa6FBe30f1557004D261e2D905b82571aC9Bab7", // Beneficiary
      4000, // Initial fee
    ],
    log: true,
  });
};
module.exports.tags = ["DCA"];
