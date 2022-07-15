module.exports = async ({ getNamedAccounts, deployments }) => {
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();
  await deploy("DCAClaimer", {
    from: deployer,
    args: [],
    log: true,
  });
};
module.exports.tags = ["DCAClaimer"];
