import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction, DeployResult } from 'hardhat-deploy/types';
import { BigNumber } from 'ethers';

function calculateMaxRewardRatePerToken(maxAprPercent: number, stakingTokenDecimals: number) {
  const secondsPerYear = 365 * 24 * 60 * 60;
  const oneToken = BigNumber.from(10).pow(stakingTokenDecimals);
  const maxRewardRatePerToken = oneToken
    .mul(Math.floor(maxAprPercent * 100))
    .div(10000)
    .div(secondsPerYear);
  return maxRewardRatePerToken;
}

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre;
  const { deployer } = await getNamedAccounts();

  const goodDollarToken = '0x62B8B11039FcfE5aB0C56E502b1C372A3d2a9c7A';
  console.log({ deployer, goodDollarToken });

  const maxApr = 5;

  await deployments.deploy('GoodDollarStakeV2', {
    contract: 'StakingRewardsCappedV2',
    from: deployer,
    args: [
      deployer, // address _owner,
      goodDollarToken, // address _rewardsToken,
      goodDollarToken, // address _stakingToken,
      calculateMaxRewardRatePerToken(maxApr, 18), // uint256 _maxRewardRatePerToken,
    ],
    log: true,
    autoMine: true, // speed up deployment on local network (ganache, hardhat), no effect on live networks
  });
};

export default func;
func.id = 'deploy_good_dollar_stake_v2'; // id required to prevent reexecution
func.tags = ['GoodDollarStakeV2'];
