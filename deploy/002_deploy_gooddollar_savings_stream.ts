import { HardhatRuntimeEnvironment } from 'hardhat/types';
import { DeployFunction } from 'hardhat-deploy/types';
import { parseEther } from 'ethers/lib/utils';
import { BigNumber } from 'ethers';
import { ISuperfluid } from '../typechain';

// Superfluid host on Celo mainnet. The host itself is NOT the ERC2771 forwarder;
// it delegates ERC2771_FORWARD_CALL operations to a separate ERC2771Forwarder
// contract, exposed via getERC2771Forwarder().
const SUPERFLUID_HOST_CELO_MAINNET = '0xA4Ff07cF81C02CFD356184879D953970cA957585';

// G$ native Super Token (same address as the regular GoodDollar token).
const GOODDOLLAR_SUPER_TOKEN = '0x62B8B11039FcfE5aB0C56E502b1C372A3d2a9c7A';

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

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, network, ethers } = hre;
  const { deployer } = await getNamedAccounts();

  const dailyRewards = parseEther('66000'); // nearly 2M per month
  const maxRewardRatePerToken = calculateMaxRewardRatePerToken(5, 18); // 5% APR

  // Fetch the ERC2771 forwarder address from the host. This separate contract
  // is what actually `call`s the target with the user appended to calldata
  // during a host.batchCall ERC2771_FORWARD_CALL operation.
  const host = (await ethers.getContractAt(
    'ISuperfluid',
    SUPERFLUID_HOST_CELO_MAINNET,
  )) as ISuperfluid;
  const trustedForwarder = await host.getERC2771Forwarder();

  console.log({
    network: network.name,
    deployer,
    superfluidHost: SUPERFLUID_HOST_CELO_MAINNET,
    trustedForwarder,
    superToken: GOODDOLLAR_SUPER_TOKEN,
    dailyRewards: dailyRewards.toString(),
    maxRewardRatePerToken: maxRewardRatePerToken.toString(),
  });

  await deployments.deploy('GooddollarSavingsStream', {
    contract: 'GooddollarSavingsStream',
    from: deployer,
    args: [
      deployer, // address _owner
      trustedForwarder, // address _trustedForwarder
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
