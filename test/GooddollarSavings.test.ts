import chai, { expect } from 'chai';
import { chaiEthers } from 'chai-ethers';
import { ethers, network } from 'hardhat';
import { BigNumber, BigNumberish, Signer } from 'ethers';
import { SignerWithAddress } from 'hardhat-deploy-ethers/signers';

import { GooddollarSavings, MockERC20 } from '../typechain';
import { GooddollarSavings__factory, MockERC20__factory } from '../typechain';

chai.use(chaiEthers);

const { parseEther } = ethers.utils;
const ONE_DAY = 24 * 60 * 60;
const WAD = parseEther('1');

const DAILY_REWARDS = parseEther('86400'); // => rewardRate = 1 GD/sec
const REWARD_RATE = DAILY_REWARDS.div(ONE_DAY);
// 1e15 wei/sec/token. Cap binds if totalSupply < 1000 GD; rewardRate binds otherwise.
const MAX_RPT = BigNumber.from(10).pow(15);
// Boundary at which the two constraints are equal (`rewardRate == maxRPT * supply / 1e18`).
const SUPPLY_BREAKEVEN = REWARD_RATE.mul(WAD).div(MAX_RPT); // == 1000 GD

const INITIAL_FUND = parseEther('10000000');

async function setNextBlockTimestamp(t: number) {
  await network.provider.send('evm_setNextBlockTimestamp', [t]);
}

async function mineAt(t: number) {
  await network.provider.send('evm_mine', [t]);
}

async function getBlockTime(): Promise<number> {
  const blk = await ethers.provider.getBlock('latest');
  return blk.timestamp;
}

function expectClose(actual: BigNumber, expected: BigNumber, tolerance: BigNumberish, msg?: string) {
  const tol = BigNumber.from(tolerance);
  const diff = actual.sub(expected).abs();
  expect(
    diff.lte(tol),
    `${msg ?? ''} expected ${actual.toString()} to be within ${tol.toString()} of ${expected.toString()} (diff=${diff.toString()})`
  ).to.equal(true);
}

describe('GooddollarSavings', () => {
  let owner: SignerWithAddress;
  let alice: SignerWithAddress;
  let bob: SignerWithAddress;
  let carol: SignerWithAddress;
  let funder: SignerWithAddress;
  let stranger: SignerWithAddress;

  let gd: MockERC20;
  let savings: GooddollarSavings;

  beforeEach(async () => {
    [owner, alice, bob, carol, funder, stranger] = (await ethers.getSigners()) as unknown as SignerWithAddress[];

    const erc20Factory = (await ethers.getContractFactory('MockERC20', owner)) as MockERC20__factory;
    gd = (await erc20Factory.deploy('GoodDollar', 'GD')) as MockERC20;
    await gd.deployed();

    const savingsFactory = (await ethers.getContractFactory('GooddollarSavings', owner)) as GooddollarSavings__factory;
    savings = (await savingsFactory.deploy(owner.address, gd.address, DAILY_REWARDS, MAX_RPT)) as GooddollarSavings;
    await savings.deployed();

    for (const acc of [alice, bob, carol, funder]) {
      await gd.mint(acc.address, parseEther('1000000'));
      await gd.connect(acc).approve(savings.address, ethers.constants.MaxUint256);
    }
  });

  // Convenience: fund the rewards pool by direct transfer + permissionless sweep.
  async function fundRewards(amount: BigNumberish) {
    await gd.connect(funder).transfer(savings.address, amount);
    await savings.connect(funder).addToReward(0);
  }

  // After a tx, lastUpdateTime == block.timestamp of that tx, so this gives us the
  // current effective starting point for the next accrual window.
  async function lastUpdateTime() {
    return (await savings.lastUpdateTime()).toNumber();
  }

  async function checkInvariant() {
    const totalStaked = await savings.totalSupply();
    const remaining = await savings.remainingRewards();
    const unclaimed = await savings.totalUnclaimedRewards();
    const bal = await gd.balanceOf(savings.address);
    expect(bal).to.equal(totalStaked.add(remaining).add(unclaimed));
  }

  describe('deployment / constructor', () => {
    it('stores constructor arguments and computes per-second rate', async () => {
      expect(await savings.gdToken()).to.equal(gd.address);
      expect(await savings.owner()).to.equal(owner.address);
      expect(await savings.rewardRate()).to.equal(REWARD_RATE);
      expect(await savings.maxRewardRatePerToken()).to.equal(MAX_RPT);
      expect(await savings.remainingRewards()).to.equal(0);
      expect(await savings.totalUnclaimedRewards()).to.equal(0);
      expect(await savings.totalSupply()).to.equal(0);
      expect(await savings.rewardPerTokenStored()).to.equal(0);
      expect(await savings.getDailyRewards()).to.equal(REWARD_RATE.mul(ONE_DAY));
    });

    it('reverts when gdToken is zero', async () => {
      const factory = (await ethers.getContractFactory(
        'GooddollarSavings',
        owner
      )) as GooddollarSavings__factory;
      await expect(
        factory.deploy(owner.address, ethers.constants.AddressZero, DAILY_REWARDS, MAX_RPT)
      ).to.be.revertedWith('GoodDollar address is zero');
    });

    it('allows zero dailyRewards (rewardRate = 0)', async () => {
      const factory = (await ethers.getContractFactory(
        'GooddollarSavings',
        owner
      )) as GooddollarSavings__factory;
      const s = await factory.deploy(owner.address, gd.address, 0, MAX_RPT);
      await s.deployed();
      expect(await s.rewardRate()).to.equal(0);
    });

    it('reverts when dailyRewards in (0, 1 days)', async () => {
      const factory = (await ethers.getContractFactory(
        'GooddollarSavings',
        owner
      )) as GooddollarSavings__factory;
      await expect(
        factory.deploy(owner.address, gd.address, ONE_DAY - 1, MAX_RPT)
      ).to.be.revertedWith('daily rewards too low');
    });

    it('reverts when dailyRewards >= 2^128', async () => {
      const factory = (await ethers.getContractFactory(
        'GooddollarSavings',
        owner
      )) as GooddollarSavings__factory;
      const tooBig = BigNumber.from(2).pow(128);
      await expect(factory.deploy(owner.address, gd.address, tooBig, MAX_RPT)).to.be.revertedWith(
        'invalid amount'
      );
    });

    it('allows zero maxRewardRatePerToken (cap disabled)', async () => {
      const factory = (await ethers.getContractFactory(
        'GooddollarSavings',
        owner
      )) as GooddollarSavings__factory;
      const s = await factory.deploy(owner.address, gd.address, DAILY_REWARDS, 0);
      await s.deployed();
      expect(await s.maxRewardRatePerToken()).to.equal(0);
    });

    it('reverts when maxRewardRatePerToken in (0, 1e6)', async () => {
      const factory = (await ethers.getContractFactory(
        'GooddollarSavings',
        owner
      )) as GooddollarSavings__factory;
      await expect(
        factory.deploy(owner.address, gd.address, DAILY_REWARDS, BigNumber.from(10).pow(6).sub(1))
      ).to.be.revertedWith('value too low');
    });

    it('reverts when maxRewardRatePerToken >= 2^128', async () => {
      const factory = (await ethers.getContractFactory(
        'GooddollarSavings',
        owner
      )) as GooddollarSavings__factory;
      const tooBig = BigNumber.from(2).pow(128);
      await expect(
        factory.deploy(owner.address, gd.address, DAILY_REWARDS, tooBig)
      ).to.be.revertedWith('value too high');
    });
  });

  describe('owner-only setters', () => {
    it('setDailyRewards updates rewardRate and emits event', async () => {
      const newDaily = DAILY_REWARDS.mul(2);
      await expect(savings.connect(owner).setDailyRewards(newDaily))
        .to.emit(savings, 'DailyRewardsUpdated')
        .withArgs(newDaily.div(ONE_DAY), newDaily);
      expect(await savings.rewardRate()).to.equal(newDaily.div(ONE_DAY));
    });

    it('setDailyRewards reverts for non-owner', async () => {
      await expect(savings.connect(stranger).setDailyRewards(DAILY_REWARDS)).to.be.revertedWith(
        'OwnableUnauthorizedAccount'
      );
    });

    it('setDailyRewards re-validates inputs', async () => {
      await expect(savings.connect(owner).setDailyRewards(ONE_DAY - 1)).to.be.revertedWith(
        'daily rewards too low'
      );
      await expect(
        savings.connect(owner).setDailyRewards(BigNumber.from(2).pow(128))
      ).to.be.revertedWith('invalid amount');
    });

    it('setMaxRewardRatePerToken updates value and emits event', async () => {
      const newMax = MAX_RPT.mul(3);
      await expect(savings.connect(owner).setMaxRewardRatePerToken(newMax))
        .to.emit(savings, 'MaxRewardRateUpdated')
        .withArgs(newMax);
      expect(await savings.maxRewardRatePerToken()).to.equal(newMax);
    });

    it('setMaxRewardRatePerToken reverts for non-owner', async () => {
      await expect(savings.connect(stranger).setMaxRewardRatePerToken(MAX_RPT)).to.be.revertedWith(
        'OwnableUnauthorizedAccount'
      );
    });

    it('setMaxRewardRatePerToken re-validates inputs', async () => {
      await expect(
        savings.connect(owner).setMaxRewardRatePerToken(BigNumber.from(10).pow(6).sub(1))
      ).to.be.revertedWith('value too low');
      await expect(
        savings.connect(owner).setMaxRewardRatePerToken(BigNumber.from(2).pow(128))
      ).to.be.revertedWith('value too high');
    });

    it('setters accrue prior rewards via updateReward(0)', async () => {
      await fundRewards(parseEther('1000'));
      const stake = SUPPLY_BREAKEVEN.mul(2); // rewardRate is binding
      await savings.connect(alice).stake(stake);
      const t0 = await lastUpdateTime();

      await setNextBlockTimestamp(t0 + 100);
      await savings.connect(owner).setDailyRewards(DAILY_REWARDS.mul(2));

      // After this owner action, lastUpdateTime should equal block.timestamp of the tx
      const t1 = await lastUpdateTime();
      expect(t1).to.equal(t0 + 100);
      // 100 seconds at the OLD rewardRate were accrued before the update
      expect(await savings.totalUnclaimedRewards()).to.equal(REWARD_RATE.mul(100));
    });
  });

  describe('stake / stakeFor', () => {
    beforeEach(async () => {
      await fundRewards(parseEther('1000'));
    });

    it('stake reverts on zero amount', async () => {
      await expect(savings.connect(alice).stake(0)).to.be.revertedWith('Cannot stake 0');
    });

    it('stake transfers tokens, updates state, and emits Staked', async () => {
      const amount = parseEther('123');
      const tx = savings.connect(alice).stake(amount);
      await expect(tx).to.emit(savings, 'Staked').withArgs(alice.address, amount);

      expect(await savings.totalSupply()).to.equal(amount);
      expect(await savings.balanceOf(alice.address)).to.equal(amount);
      await checkInvariant();
    });

    it('stakeFor credits recipient and pulls from caller', async () => {
      const amount = parseEther('250');
      const aliceBefore = await gd.balanceOf(alice.address);
      const bobBefore = await gd.balanceOf(bob.address);

      await expect(savings.connect(alice).stakeFor(amount, bob.address))
        .to.emit(savings, 'StakedFor')
        .withArgs(alice.address, bob.address, amount);

      expect(await gd.balanceOf(alice.address)).to.equal(aliceBefore.sub(amount));
      expect(await gd.balanceOf(bob.address)).to.equal(bobBefore);
      expect(await savings.balanceOf(bob.address)).to.equal(amount);
      expect(await savings.balanceOf(alice.address)).to.equal(0);
      await checkInvariant();
    });

    it('stakeFor reverts on zero amount', async () => {
      await expect(savings.connect(alice).stakeFor(0, bob.address)).to.be.revertedWith('Cannot stake 0');
    });

    it('stakeFor reverts on invalid recipient', async () => {
      await expect(
        savings.connect(alice).stakeFor(parseEther('1'), ethers.constants.AddressZero)
      ).to.be.revertedWith('invalid address');
      await expect(
        savings.connect(alice).stakeFor(parseEther('1'), savings.address)
      ).to.be.revertedWith('invalid address');
      await expect(savings.connect(alice).stakeFor(parseEther('1'), gd.address)).to.be.revertedWith(
        'invalid address'
      );
    });
  });

  describe('withdraw', () => {
    beforeEach(async () => {
      await fundRewards(parseEther('1000'));
      await savings.connect(alice).stake(parseEther('500'));
    });

    it('reverts on zero amount', async () => {
      await expect(savings.connect(alice).withdraw(0)).to.be.revertedWith('Cannot withdraw 0');
    });

    it('reverts when withdrawing more than balance', async () => {
      await expect(savings.connect(alice).withdraw(parseEther('501'))).to.be.reverted;
    });

    it('partial withdraw transfers tokens, updates state, emits Withdrawn', async () => {
      const amount = parseEther('200');
      await expect(savings.connect(alice).withdraw(amount))
        .to.emit(savings, 'Withdrawn')
        .withArgs(alice.address, amount);
      expect(await savings.balanceOf(alice.address)).to.equal(parseEther('300'));
      expect(await savings.totalSupply()).to.equal(parseEther('300'));
      await checkInvariant();
    });
  });

  describe('addToReward', () => {
    it('pulls reward via transferFrom and adds to remainingRewards', async () => {
      const amount = parseEther('500');
      await expect(savings.connect(funder).addToReward(amount))
        .to.emit(savings, 'RewardAdded')
        .withArgs(amount);
      expect(await savings.remainingRewards()).to.equal(amount);
      await checkInvariant();
    });

    it('sweeps direct transfers when called with reward = 0', async () => {
      const amount = parseEther('250');
      await gd.connect(funder).transfer(savings.address, amount);
      await expect(savings.connect(funder).addToReward(0))
        .to.emit(savings, 'RewardAdded')
        .withArgs(amount);
      expect(await savings.remainingRewards()).to.equal(amount);
      await checkInvariant();
    });

    it('combines direct transfer and pulled reward', async () => {
      const swept = parseEther('100');
      const pulled = parseEther('70');
      await gd.connect(funder).transfer(savings.address, swept);
      await expect(savings.connect(funder).addToReward(pulled))
        .to.emit(savings, 'RewardAdded')
        .withArgs(swept.add(pulled));
      expect(await savings.remainingRewards()).to.equal(swept.add(pulled));
      await checkInvariant();
    });

    it('reverts when there is no excess to credit', async () => {
      await expect(savings.connect(funder).addToReward(0)).to.be.revertedWith('No reward to add');
    });

    it('does not double-count previously accrued rewards', async () => {
      // Stage: stakers + accrued rewards already exist.
      await fundRewards(parseEther('1000'));
      const stake = SUPPLY_BREAKEVEN.mul(2); // rewardRate-binding
      await savings.connect(alice).stake(stake);
      const t0 = await lastUpdateTime();

      await setNextBlockTimestamp(t0 + 100);
      await savings.connect(alice).withdraw(parseEther('1')); // forces updateReward(alice)
      const t1 = await lastUpdateTime();
      const accruedBefore = await savings.totalUnclaimedRewards();
      expect(accruedBefore).to.equal(REWARD_RATE.mul(100));
      const remainingBefore = await savings.remainingRewards();

      // Top up with another 200 GD; only the new amount should be added on top of the
      // accrual that happens during this tx itself (one block advance from t1).
      const topUp = parseEther('200');
      const t2 = t1 + 1;
      await setNextBlockTimestamp(t2);
      await expect(savings.connect(funder).addToReward(topUp))
        .to.emit(savings, 'RewardAdded')
        .withArgs(topUp);

      const extraAccrual = REWARD_RATE.mul(t2 - t1);
      expect(await savings.remainingRewards()).to.equal(
        remainingBefore.sub(extraAccrual).add(topUp)
      );
      expect(await savings.totalUnclaimedRewards()).to.equal(accruedBefore.add(extraAccrual));
      await checkInvariant();
    });
  });

  describe('reward accrual: dailyRewards binding (large stake)', () => {
    beforeEach(async () => {
      await fundRewards(parseEther('1000000'));
    });

    it('single staker accrues rewardRate per second', async () => {
      const stake = SUPPLY_BREAKEVEN.mul(10); // rewardRate is binding
      await savings.connect(alice).stake(stake);
      const t0 = await lastUpdateTime();

      const dt = 60;
      await mineAt(t0 + dt);
      const earned = await savings.earned(alice.address);
      expectClose(earned, REWARD_RATE.mul(dt), 0, 'earned');

      const rpt = await savings.rewardPerToken();
      expectClose(rpt, REWARD_RATE.mul(dt).mul(WAD).div(stake), 0, 'rewardPerToken');
    });

    it('two equal stakers split accrual ~50/50', async () => {
      const stake = SUPPLY_BREAKEVEN.mul(5);
      await savings.connect(alice).stake(stake);
      const t0 = await lastUpdateTime();
      await setNextBlockTimestamp(t0 + 1);
      await savings.connect(bob).stake(stake);
      const t1 = await lastUpdateTime();
      expect(t1).to.equal(t0 + 1);

      const dt = 100;
      await mineAt(t1 + dt);
      const aEarned = await savings.earned(alice.address);
      const bEarned = await savings.earned(bob.address);

      // Bob has nothing for the first 1s gap; thereafter 50/50.
      const half = REWARD_RATE.mul(dt).div(2);
      expectClose(aEarned, REWARD_RATE.mul(1).add(half), REWARD_RATE);
      expectClose(bEarned, half, REWARD_RATE);
    });

    it('staggered stakes accrue proportionally', async () => {
      const stake = SUPPLY_BREAKEVEN.mul(5);
      await savings.connect(alice).stake(stake);
      const t0 = await lastUpdateTime();

      const T1 = 50;
      await setNextBlockTimestamp(t0 + T1);
      await savings.connect(bob).stake(stake);
      const t1 = await lastUpdateTime();
      expect(t1).to.equal(t0 + T1);

      const T2 = 30;
      await mineAt(t1 + T2);
      const aEarned = await savings.earned(alice.address);
      const bEarned = await savings.earned(bob.address);

      const expectedA = REWARD_RATE.mul(T1).add(REWARD_RATE.mul(T2).div(2));
      const expectedB = REWARD_RATE.mul(T2).div(2);
      expectClose(aEarned, expectedA, REWARD_RATE);
      expectClose(bEarned, expectedB, REWARD_RATE);
    });

    it('rewardPerToken and earned are monotonically non-decreasing', async () => {
      const stake = SUPPLY_BREAKEVEN.mul(5);
      await savings.connect(alice).stake(stake);
      const t0 = await lastUpdateTime();

      let prevRpt = await savings.rewardPerToken();
      let prevEarned = await savings.earned(alice.address);
      for (let i = 1; i <= 5; i++) {
        await mineAt(t0 + i * 10);
        const rpt = await savings.rewardPerToken();
        const earned = await savings.earned(alice.address);
        expect(rpt.gte(prevRpt)).to.equal(true);
        expect(earned.gte(prevEarned)).to.equal(true);
        prevRpt = rpt;
        prevEarned = earned;
      }
    });
  });

  describe('reward accrual: maxRewardRatePerToken binding (small stake)', () => {
    beforeEach(async () => {
      await fundRewards(parseEther('1000000'));
    });

    it('uses maxRewardRatePerToken * totalSupply / 1e18 as effective rate', async () => {
      // Stake well below SUPPLY_BREAKEVEN so the cap binds.
      const stake = SUPPLY_BREAKEVEN.div(10); // 100 GD
      await savings.connect(alice).stake(stake);
      const t0 = await lastUpdateTime();

      const expectedEffectiveRate = MAX_RPT.mul(stake).div(WAD);
      expect(await savings.getEffectiveRewardRate()).to.equal(expectedEffectiveRate);

      const dt = 600;
      await mineAt(t0 + dt);
      const earned = await savings.earned(alice.address);
      expectClose(earned, expectedEffectiveRate.mul(dt), 0);
    });

    it('switching to dailyRewards-binding regime by adding stake', async () => {
      const smallStake = SUPPLY_BREAKEVEN.div(10);
      await savings.connect(alice).stake(smallStake);

      const cappedRate = MAX_RPT.mul(smallStake).div(WAD);
      expect(await savings.getEffectiveRewardRate()).to.equal(cappedRate);

      // Add enough stake to push past the breakeven point: rewardRate now binds.
      await savings.connect(bob).stake(SUPPLY_BREAKEVEN.mul(5));
      expect(await savings.getEffectiveRewardRate()).to.equal(REWARD_RATE);
    });
  });

  describe('reward accrual: rewards depletion', () => {
    it('clamps distribution when remainingRewards is exhausted', async () => {
      const smallReward = parseEther('500'); // 500 sec at 1 GD/sec
      await fundRewards(smallReward);

      const stake = SUPPLY_BREAKEVEN.mul(10); // rewardRate binding
      await savings.connect(alice).stake(stake);
      const t0 = await lastUpdateTime();

      // Past depletion (500s window).
      await mineAt(t0 + 10_000);
      const earned = await savings.earned(alice.address);
      expect(earned).to.equal(smallReward);
      expect(await savings.rewardPerToken()).to.equal(smallReward.mul(WAD).div(stake));

      // Advance more time and ensure no extra accrues until topped up again.
      await mineAt(t0 + 20_000);
      expect(await savings.earned(alice.address)).to.equal(smallReward);
    });

    it('claiming after depletion drains the pool exactly', async () => {
      const smallReward = parseEther('500');
      await fundRewards(smallReward);

      const stake = SUPPLY_BREAKEVEN.mul(10);
      await savings.connect(alice).stake(stake);
      const t0 = await lastUpdateTime();
      await setNextBlockTimestamp(t0 + 10_000);
      await savings.connect(alice).getReward();

      expect(await savings.remainingRewards()).to.equal(0);
      expect(await savings.totalUnclaimedRewards()).to.equal(0);
      expect(await savings.earned(alice.address)).to.equal(0);
      await checkInvariant();
    });
  });

  describe('getReward / compound / exit', () => {
    beforeEach(async () => {
      await fundRewards(parseEther('100000'));
    });

    it('getReward pays out the accrued amount and zeroes user state', async () => {
      const stake = SUPPLY_BREAKEVEN.mul(5);
      await savings.connect(alice).stake(stake);
      const t0 = await lastUpdateTime();
      await setNextBlockTimestamp(t0 + 100);
      const expected = REWARD_RATE.mul(100);
      await expect(savings.connect(alice).getReward())
        .to.emit(savings, 'RewardPaid')
        .withArgs(alice.address, expected);

      const t1 = await lastUpdateTime();
      expect(t1).to.equal(t0 + 100);
      expect(await savings.rewards(alice.address)).to.equal(0);
      expect(await savings.totalUnclaimedRewards()).to.equal(0);
      await checkInvariant();
    });

    it('getReward is a no-op when nothing is owed', async () => {
      const tx = savings.connect(alice).getReward();
      // Should not revert and should emit nothing.
      await expect(tx).to.not.emit(savings, 'RewardPaid');
    });

    it('compound restakes pending rewards and emits both events', async () => {
      const stake = SUPPLY_BREAKEVEN.mul(5);
      await savings.connect(alice).stake(stake);
      const t0 = await lastUpdateTime();
      await setNextBlockTimestamp(t0 + 100);
      const expected = REWARD_RATE.mul(100);

      const tx = await savings.connect(alice).compound();
      const receipt = await tx.wait();
      const paid = receipt.events?.find((e) => e.event === 'RewardPaid');
      const staked = receipt.events?.find((e) => e.event === 'Staked');
      expect(paid?.args?.user).to.equal(alice.address);
      expect(paid?.args?.reward).to.equal(expected);
      expect(staked?.args?.user).to.equal(alice.address);
      expect(staked?.args?.amount).to.equal(expected);

      expect(await savings.balanceOf(alice.address)).to.equal(stake.add(expected));
      expect(await savings.totalSupply()).to.equal(stake.add(expected));
      expect(await savings.rewards(alice.address)).to.equal(0);
      expect(await savings.totalUnclaimedRewards()).to.equal(0);
      await checkInvariant();
    });

    it('compound reverts when there are no rewards', async () => {
      // Fresh contract with zero rewards funded so no accrual ever happens.
      const factory = (await ethers.getContractFactory(
        'GooddollarSavings',
        owner
      )) as GooddollarSavings__factory;
      const fresh = await factory.deploy(owner.address, gd.address, DAILY_REWARDS, MAX_RPT);
      await fresh.deployed();
      await gd.connect(alice).approve(fresh.address, ethers.constants.MaxUint256);
      await fresh.connect(alice).stake(parseEther('1'));
      await expect(fresh.connect(alice).compound()).to.be.revertedWith('No rewards to compound');
    });

    it('exit withdraws stake and claims rewards together', async () => {
      const stake = SUPPLY_BREAKEVEN.mul(5);
      await savings.connect(alice).stake(stake);
      const t0 = await lastUpdateTime();
      await setNextBlockTimestamp(t0 + 100);

      const balBefore = await gd.balanceOf(alice.address);
      const tx = await savings.connect(alice).exit();
      const receipt = await tx.wait();
      const expectedReward = REWARD_RATE.mul(100);

      const withdrawnLog = receipt.events?.find((e) => e.event === 'Withdrawn');
      const paidLog = receipt.events?.find((e) => e.event === 'RewardPaid');
      expect(withdrawnLog?.args?.user).to.equal(alice.address);
      expect(withdrawnLog?.args?.amount).to.equal(stake);
      expect(paidLog?.args?.user).to.equal(alice.address);
      expect(paidLog?.args?.reward).to.equal(expectedReward);

      expect(await savings.balanceOf(alice.address)).to.equal(0);
      expect(await gd.balanceOf(alice.address)).to.equal(balBefore.add(stake).add(expectedReward));
      await checkInvariant();
    });

    it('exit works for a user with rewards but no stake', async () => {
      // Alice stakes, accrues, withdraws fully but does not claim.
      const stake = parseEther('1');
      // Use small stake so capped accrual is small but non-zero.
      await savings.connect(alice).stake(stake);
      const t0 = await lastUpdateTime();
      await setNextBlockTimestamp(t0 + 100);
      await savings.connect(alice).withdraw(stake);

      const owed = await savings.rewards(alice.address);
      expect(owed.gt(0)).to.equal(true);

      const balBefore = await gd.balanceOf(alice.address);
      await expect(savings.connect(alice).exit())
        .to.emit(savings, 'RewardPaid')
        .withArgs(alice.address, owed);
      expect(await gd.balanceOf(alice.address)).to.equal(balBefore.add(owed));
    });

    it('exit works for a user with stake but no rewards', async () => {
      // No rewards funded scenario: redeploy without funding.
      const factory = (await ethers.getContractFactory(
        'GooddollarSavings',
        owner
      )) as GooddollarSavings__factory;
      const fresh = await factory.deploy(owner.address, gd.address, DAILY_REWARDS, MAX_RPT);
      await fresh.deployed();
      await gd.connect(alice).approve(fresh.address, ethers.constants.MaxUint256);
      await fresh.connect(alice).stake(parseEther('5'));

      await expect(fresh.connect(alice).exit())
        .to.emit(fresh, 'Withdrawn')
        .withArgs(alice.address, parseEther('5'));
      expect(await fresh.balanceOf(alice.address)).to.equal(0);
    });
  });

  describe('view helpers', () => {
    it('getEffectiveRewardRate returns rewardRate when totalSupply == 0', async () => {
      expect(await savings.getEffectiveRewardRate()).to.equal(REWARD_RATE);
    });

    it('getEffectiveRewardRate returns rewardRate when maxRewardRatePerToken == 0', async () => {
      await savings.connect(owner).setMaxRewardRatePerToken(0);
      await savings.connect(alice).stake(parseEther('1'));
      expect(await savings.getEffectiveRewardRate()).to.equal(REWARD_RATE);
    });

    it('getEffectiveRewardRate returns the capped rate when supply is small', async () => {
      const stake = SUPPLY_BREAKEVEN.div(10);
      await savings.connect(alice).stake(stake);
      expect(await savings.getEffectiveRewardRate()).to.equal(MAX_RPT.mul(stake).div(WAD));
    });

    it('getDailyRewards reflects current rewardRate', async () => {
      const newDaily = DAILY_REWARDS.mul(7);
      await savings.connect(owner).setDailyRewards(newDaily);
      expect(await savings.getDailyRewards()).to.equal(newDaily.div(ONE_DAY).mul(ONE_DAY));
    });

    it('periodFinish returns 0 when supply == 0 but rewards remain', async () => {
      await fundRewards(parseEther('100'));
      expect(await savings.periodFinish()).to.equal(0);
    });

    it('periodFinish returns lastUpdateTime when remainingRewards == 0', async () => {
      await savings.connect(alice).stake(parseEther('100'));
      const t = await lastUpdateTime();
      expect(await savings.periodFinish()).to.equal(t);
    });

    it('periodFinish reflects ceilDiv(remaining, effectiveRate) when active', async () => {
      const reward = parseEther('500');
      await fundRewards(reward);
      const stake = SUPPLY_BREAKEVEN.mul(10); // rewardRate binding
      await savings.connect(alice).stake(stake);
      const t = await lastUpdateTime();
      const expected = BigNumber.from(t).add(reward.add(REWARD_RATE).sub(1).div(REWARD_RATE));
      expect(await savings.periodFinish()).to.equal(expected);
    });
  });

  describe('recoverERC20', () => {
    let other: MockERC20;

    beforeEach(async () => {
      const factory = (await ethers.getContractFactory('MockERC20', owner)) as MockERC20__factory;
      other = (await factory.deploy('Other', 'OTH')) as MockERC20;
      await other.deployed();
      await other.mint(savings.address, parseEther('500'));
    });

    it('reverts for non-owner', async () => {
      await expect(savings.connect(stranger).recoverERC20(other.address, parseEther('1'))).to.be
        .reverted;
    });

    it('reverts when token is the GD token', async () => {
      await expect(savings.connect(owner).recoverERC20(gd.address, 1)).to.be.revertedWith(
        'Cannot withdraw the GoodDollar token'
      );
    });

    it('transfers other tokens to the owner and emits Recovered', async () => {
      const amount = parseEther('123');
      const ownerBefore = await other.balanceOf(owner.address);
      await expect(savings.connect(owner).recoverERC20(other.address, amount))
        .to.emit(savings, 'Recovered')
        .withArgs(other.address, amount, owner.address);
      expect(await other.balanceOf(owner.address)).to.equal(ownerBefore.add(amount));
    });
  });

  describe('invariants under combined operations', () => {
    it('balance invariant holds across stake/withdraw/getReward/compound/addToReward', async () => {
      await fundRewards(parseEther('5000'));
      const aliceStake = SUPPLY_BREAKEVEN.mul(3);
      const bobStake = SUPPLY_BREAKEVEN.mul(2);
      await savings.connect(alice).stake(aliceStake);
      await savings.connect(bob).stake(bobStake);
      await checkInvariant();

      const t0 = await lastUpdateTime();
      await setNextBlockTimestamp(t0 + 50);
      await savings.connect(alice).withdraw(parseEther('100'));
      await checkInvariant();

      await setNextBlockTimestamp((await lastUpdateTime()) + 50);
      await savings.connect(bob).getReward();
      await checkInvariant();

      await setNextBlockTimestamp((await lastUpdateTime()) + 50);
      await savings.connect(alice).compound();
      await checkInvariant();

      await savings.connect(funder).addToReward(parseEther('200'));
      await checkInvariant();

      await setNextBlockTimestamp((await lastUpdateTime()) + 25);
      await savings.connect(alice).exit();
      await checkInvariant();
    });
  });
});
