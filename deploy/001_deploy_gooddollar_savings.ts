import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction, DeployResult } from 'hardhat-deploy/types';
import { BigNumber } from 'ethers';
import { parseEther } from 'ethers/lib/utils';

// maxAprBps = maxApr * 100
// Formula: (aprBps * 1e18) / (10_000 * 365 days).
function calculateMaxRewardRatePerToken(maxApr: number, stakingTokenDecimals: number) {
  const secondsPerYear = 365 * 24 * 60 * 60;
  const oneToken = BigNumber.from(10).pow(stakingTokenDecimals);
  const maxRewardRatePerToken = oneToken
    .mul(Math.floor(maxApr * 100))
    .div(BigNumber.from(10_000).mul(secondsPerYear));
  return maxRewardRatePerToken;
}
function getGooddollarTokenAddress(networkName: string): string {
  switch (networkName) {
    case 'celo_mainnet':
      return '0x62B8B11039FcfE5aB0C56E502b1C372A3d2a9c7A';
    case 'xdc_mainnet':
      return '0xEC2136843a983885AebF2feB3931F73A8eBEe50c';
    default:
      throw new Error(`Unsupported network: ${networkName}`);
  }
}

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();

  const goodDollarToken = getGooddollarTokenAddress(hre.network.name);
  console.log({ deployer, goodDollarToken });

  const maxApr = 5;

  await deployments.deploy('GooddollarSavings', {
    contract: 'GooddollarSavings',
    from: deployer,
    args: [
      deployer, // address _owner,
      goodDollarToken, // address _gdToken,
      parseEther('50000'), // uint256 _dailyRewards,
      calculateMaxRewardRatePerToken(maxApr, 18), // uint256 _maxRewardRatePerToken,
    ],
    log: true,
    autoMine: true, // speed up deployment on local network (ganache, hardhat), no effect on live networks
  });
};

export default func;
func.id = 'deploy_gooddollar_savings'; // id required to prevent reexecution
func.tags = ['GooddollarSavings'];
