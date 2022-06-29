module.exports = async ({ getNamedAccounts, deployments }) => {
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();
  await deploy("OracleWrapper", {
    from: deployer,
    args: [
      "0x056d9AAC902cc2925BB31f6C516B1e1579c35df9", // Oracle
    ],
    log: true,
  });
};
module.exports.tags = ["OracleWrapper"];
