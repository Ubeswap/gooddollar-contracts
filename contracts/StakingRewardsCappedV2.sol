// SPDX-License-Identifier: MIT
// solhint-disable not-rely-on-time

pragma solidity ^0.8.3;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/IStakingRewardsCappedV2.sol";

contract StakingRewardsCappedV2 is IStakingRewardsCappedV2, Ownable, ReentrancyGuard {
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
        address _rewardsToken,
        address _stakingToken,
        uint256 _maxRewardRatePerToken
    ) Ownable(_owner) {
        require(_stakingToken != address(0), "Staking token cannot be zero address");
        require(_rewardsToken != address(0), "Rewards token cannot be zero address");
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
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

    // Capped: Calculate effective reward rate considering the cap
    function getEffectiveRewardRate() public view override returns (uint256) {
        if (_totalSupply == 0 || maxRewardRatePerToken == 0) {
            return rewardRate;
        }

        // Calculate max allowed reward rate based on total supply
        uint256 maxAllowedRewardRate = (maxRewardRatePerToken * _totalSupply) / 1e18;

        return Math.min(rewardRate, maxAllowedRewardRate);
    }

    // Capped: Get the amount of rewards being withheld per second
    function getWithheldRewardRate() public view override returns (uint256) {
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

    function stakeFor(uint256 amount, address recipient) external override  nonReentrant updateReward(recipient) {
        require(amount > 0, "Cannot stake 0");
        require(recipient != address(0), "Cannot stake for zero address");
        _totalSupply += amount;
        _balances[recipient] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit StakedFor(msg.sender, recipient, amount);
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

    // Permissionless: anyone may add rewards by transferring tokens directly into the contract
    // and calling this function. Withheld rewards are automatically recycled.
    function addToReward(uint256 reward) external override nonReentrant updateReward(address(0)) {
        require(reward > 0, "Cannot add 0 reward");
        rewardsToken.safeTransferFrom(msg.sender, address(this), reward);
        _addReward(reward);
    }

    function recycleReward() external override nonReentrant updateReward(address(0)) {
        require(withheldRewards > 0, 'no withheld rewards');
        _addReward(0);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */
    // Only the owner can call notifyRewardAmount, but anyone can add rewards via addToReward.
    // This is used if reward tokens trasferred in (by mistake) without calling addToReward, or if owner wants to top up rewards and reset the period.
    function notifyRewardAmount(uint256 reward) external onlyOwner nonReentrant updateReward(address(0)) {
        _addReward(reward);
    }

    // Internal helper: recycle any withheld rewards and apply the combined new reward amount.
    function _addReward(uint256 newReward) internal {
        // Recycle any previously withheld rewards back into the pool.
        uint256 recycled = withheldRewards;
        if (recycled > 0) {
            withheldRewards = 0;
            emit WithheldRewardsRecycled(recycled);
        }

        uint256 totalReward = newReward + recycled;

        if (block.timestamp >= periodFinish) {
            rewardRate = totalReward / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (totalReward + leftover) / rewardsDuration;
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint256 balance = rewardsToken.balanceOf(address(this));
        require(rewardRate <= (balance / rewardsDuration), "Provided reward too high");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(totalReward);
    }

    // End rewards emission earlier
    function updatePeriodFinish(uint timestamp) external onlyOwner updateReward(address(0)) {
        periodFinish = timestamp;
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAddress != address(stakingToken), "Cannot withdraw the staking token");
        require(tokenAddress != address(rewardsToken), "Cannot withdraw the rewards token");
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    // NEW: Withdraw accumulated withheld rewards. (Mostly unnecessary)
    function withdrawWithheldRewards() external onlyOwner {
        uint256 amount = withheldRewards;
        require(amount > 0, "withheldRewards is zero");

        rewardsToken.safeTransfer(owner(), amount);
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
                if (withheldAmount > 0) {
                    withheldRewards += withheldAmount;
                    emit RewardCapped(rewardRate, effectiveRate, withheldAmount);
                }
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
    event StakedFor(address indexed staker, address indexed recipient, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);
    event RewardCapped(uint256 originalRate, uint256 cappedRate, uint256 withheldAmount);
    event MaxRewardRateUpdated(uint256 newMaxRate);
    event WithheldRewardsWithdrawn(uint256 amount);
    event WithheldRewardsRecycled(uint256 amount);
}
