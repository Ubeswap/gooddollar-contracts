// SPDX-License-Identifier: MIT
// solhint-disable not-rely-on-time

pragma solidity ^0.8.3;

import "../../openzeppelin-solidity/contracts/Math.sol";
import "../../openzeppelin-solidity/contracts/SafeERC20.sol";
import "../../openzeppelin-solidity/contracts/ReentrancyGuard.sol";

import "./interfaces/IStakingRewards.sol";
import "./RewardsDistributionRecipient.sol";


contract StakingRewardsCapped is IStakingRewards, RewardsDistributionRecipient, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardsToken;

    /* ========== STATE VARIABLES ========== */

    // Timestamp of when the rewards finish
    uint256 public periodFinish = 0;
    // Reward to be paid out per second
    uint256 public rewardRate = 0;
    // Duration of rewards to be paid out (in seconds)
    uint256 public rewardsDuration = 7 days;
    // Minimum of last updated time and reward finish time
    uint256 public lastUpdateTime;
    // Sum of (effective reward rate * dt * 1e18 / total supply)
    uint256 public rewardPerTokenStored;
    // User address => rewardPerTokenStored
    mapping(address => uint256) public userRewardPerTokenPaid;
    // User address => rewards to be claimed
    mapping(address => uint256) public rewards;

    // NEW: Reward cap variables
    // Maximum reward rate per token per second (in wei per second per token)
    uint256 public maxRewardRatePerToken;
    // Accumulated rewards that were withheld due to cap
    uint256 public withheldRewards;

    // Total staked
    uint256 private _totalSupply;
    // User address => staked amount
    mapping(address => uint256) private _balances;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _owner,
        address _rewardsDistribution,
        address _rewardsToken,
        address _stakingToken,
        uint256 _maxRewardRatePerToken
    ) Owned(_owner) {
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
        rewardsDistribution = _rewardsDistribution;
        maxRewardRatePerToken = _maxRewardRatePerToken;
    }

    /* ========== VIEWS ========== */

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function lastTimeRewardApplicable() public view override returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view override returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        uint256 effectiveRate = getEffectiveRewardRate();
        return rewardPerTokenStored
            + (effectiveRate * (lastTimeRewardApplicable() - lastUpdateTime) * 1e18)
                / _totalSupply;
    }

    function earned(address account) public view override returns (uint256) {
        return (
            (
                _balances[account]
                    * (rewardPerToken() - userRewardPerTokenPaid[account])
            ) / 1e18
        ) + rewards[account];
    }

    function getRewardForDuration() external view override returns (uint256) {
        return getEffectiveRewardRate() * rewardsDuration;
    }

    // NEW: Calculate effective reward rate considering the cap
    function getEffectiveRewardRate() public view returns (uint256) {
        if (_totalSupply == 0 || maxRewardRatePerToken == 0) {
            return rewardRate;
        }

        // Calculate max allowed reward rate based on total supply
        uint256 maxAllowedRewardRate = (maxRewardRatePerToken * _totalSupply) / 1e18;

        return Math.min(rewardRate, maxAllowedRewardRate);
    }

    // NEW: Get the amount of rewards being withheld per second
    function getWithheldRewardRate() public view returns (uint256) {
        uint256 effectiveRate = getEffectiveRewardRate();
        return rewardRate > effectiveRate ? rewardRate - effectiveRate : 0;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint256 amount) external override nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        _totalSupply += amount;
        _balances[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public override nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        _totalSupply -= amount;
        _balances[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public override nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external override {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function notifyRewardAmount(uint256 reward) external override onlyRewardsDistribution updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint balance = rewardsToken.balanceOf(address(this));
        require(rewardRate <= (balance / rewardsDuration), "Provided reward too high");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(reward);
    }

    // End rewards emission earlier
    function updatePeriodFinish(uint timestamp) external onlyOwner updateReward(address(0)) {
        periodFinish = timestamp;
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAddress != address(stakingToken), "Cannot withdraw the staking token");
        IERC20(tokenAddress).safeTransfer(owner, tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    // NEW: Withdraw accumulated withheld rewards
    function withdrawWithheldRewards() external onlyRewardsDistribution {
        uint256 amount = withheldRewards;
        require(amount > 0, "withheldRewards is zero");

        rewardsToken.safeTransfer(rewardsDistribution, amount);
        withheldRewards = 0;

        emit WithheldRewardsWithdrawn(amount);
    }

    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        require(_rewardsDuration > 0, "Rewards duration must be greater than 0");
        require(block.timestamp > periodFinish, "Previous rewards period must be complete");
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    // NEW: Set maximum reward rate per token per second
    function setMaxRewardRatePerToken(uint256 _maxRewardRatePerToken) external onlyOwner {
        maxRewardRatePerToken = _maxRewardRatePerToken;
        emit MaxRewardRateUpdated(_maxRewardRatePerToken);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address account) {
        uint256 currentTime = lastTimeRewardApplicable();
        rewardPerTokenStored = rewardPerToken();

        // Update withheld rewards based on time elapsed
        if (_totalSupply > 0) {
            uint256 effectiveRate = getEffectiveRewardRate();
            if (rewardRate > effectiveRate) {
                uint256 timeElapsed = currentTime - lastUpdateTime;
                uint256 withheldAmount = (rewardRate - effectiveRate) * timeElapsed;
                withheldRewards += withheldAmount;
                emit RewardCapped(rewardRate, effectiveRate, withheldAmount);
            }
        }

        lastUpdateTime = currentTime;

        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);
    event RewardCapped(uint256 originalRate, uint256 cappedRate, uint256 withheldAmount);
    event MaxRewardRateUpdated(uint256 newMaxRate);
    event WithheldRewardsWithdrawn(uint256 amount);
}
