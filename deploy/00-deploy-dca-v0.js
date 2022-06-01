module.exports = async ({ getNamedAccounts, deployments }) => {
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();
  await deploy("DCA", {
    from: deployer,
    args: [
      "0x765de816845861e75a25fca122bb6898b8b1282a",
      "0x67316300f17f063085ca8bca4bd3f7a5a3c66275",
    ],
    log: true,
  });
};
module.exports.tags = ["DCA"];
