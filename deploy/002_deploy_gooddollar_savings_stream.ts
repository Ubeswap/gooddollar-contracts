import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { parseEther } from 'ethers/lib/utils';
import { BigNumber } from 'ethers';

// Superfluid host on Celo mainnet (acts as the ERC2771 trusted forwarder for
// host.batchCall meta-tx flows like stake + connectPool in a single tx).
const SUPERFLUID_HOST_CELO_MAINNET = '0xA4Ff07cF81C02CFD356184879D953970cA957585';

// G$ native Super Token (same address as the regular GoodDollar token).
const GOODDOLLAR_SUPER_TOKEN = '0x62B8B11039FcfE5aB0C56E502b1C372A3d2a9c7A';

// 5% APR cap, expressed as maxRewardRatePerToken (1e18 scaled, per second).
// Formula: (aprBps * 1e18) / (10_000 * 365 days).
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
  const { deployments, getNamedAccounts, network } = hre;
  const { deployer } = await getNamedAccounts();

  const dailyRewards = parseEther('50000');
  const maxRewardRatePerToken = calculateMaxRewardRatePerToken(5, 18); // 5% APR

  console.log({
    network: network.name,
    deployer,
    trustedForwarder: SUPERFLUID_HOST_CELO_MAINNET,
    superToken: GOODDOLLAR_SUPER_TOKEN,
    dailyRewards: dailyRewards.toString(),
    maxRewardRatePerToken: maxRewardRatePerToken.toString(),
  });

  await deployments.deploy('GooddollarSavingsStream', {
    contract: 'GooddollarSavingsStream',
    from: deployer,
    args: [
      deployer, // address _owner
      SUPERFLUID_HOST_CELO_MAINNET, // address _trustedForwarder
      GOODDOLLAR_SUPER_TOKEN, // ISuperToken _superToken
      dailyRewards, // uint256 _dailyRewards
      maxRewardRatePerToken, // uint256 _maxRewardRatePerToken
    ],
    log: true,
    autoMine: true,
  });
};

export default func;
func.id = 'deploy_gooddollar_savings_stream';
func.tags = ['GooddollarSavingsStream'];
// eslint-disable-next-line @typescript-eslint/require-await
func.skip = async (hre: HardhatRuntimeEnvironment) => {
  if (hre.network.name !== 'celo_mainnet') {
    console.log(`Skipping GooddollarSavingsStream deploy on non-Celo network: celo_mainnet`);
    return true;
  }
  return false;
};
