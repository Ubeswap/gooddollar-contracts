// SPDX-License-Identifier: MIT
// solhint-disable not-rely-on-time

pragma solidity ^0.8.3;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import "./interfaces/IGooddollarSavings.sol";

contract GooddollarSavings is IGooddollarSavings, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardsToken;

    /* ========== STATE VARIABLES ========== */

    // Reward to be paid out per second (constant; only owner can change)
    uint256 public rewardRate;
    // Maximum reward rate per token per second (in wei per second per token)
    uint256 public maxRewardRatePerToken;
    // Reward tokens still available to be distributed
    uint256 public remainingRewards;
    // Timestamp of the last reward accrual update
    uint256 public lastUpdateTime;
    // Sum of (effective reward rate * dt * 1e18 / total supply)
    uint256 public rewardPerTokenStored;
    // User address => rewardPerTokenStored snapshot at last interaction
    mapping(address => uint256) public userRewardPerTokenPaid;
    // User address => rewards accrued and pending claim
    mapping(address => uint256) public rewards;

    // Total staked
    uint256 private _totalSupply;
    // User address => staked amount
    mapping(address => uint256) private _balances;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _owner,
        address _rewardsToken,
        address _stakingToken,
        uint256 _dailyRewards,
        uint256 _maxRewardRatePerToken
    ) Ownable(_owner) {
        require(_stakingToken != address(0), "Staking token cannot be zero address");
        require(_rewardsToken != address(0), "Rewards token cannot be zero address");
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
        rewardRate = _dailyRewards / 1 days;
        maxRewardRatePerToken = _maxRewardRatePerToken;
    }

    /* ========== VIEWS ========== */

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    // Latest timestamp at which rewards can still be applied. Beyond this, the
    // remaining reward pool would be depleted at the current effective rate.
    function lastTimeRewardApplicable() public view override returns (uint256) {
        if (_totalSupply == 0 || remainingRewards == 0) {
            return lastUpdateTime;
        }
        uint256 effectiveRate = getEffectiveRewardRate();
        if (effectiveRate == 0) {
            return block.timestamp;
        }
        uint256 maxEnd = lastUpdateTime + (remainingRewards / effectiveRate);
        return Math.min(block.timestamp, maxEnd);
    }

    function rewardPerToken() public view override returns (uint256) {
        if (_totalSupply == 0 || remainingRewards == 0) {
            return rewardPerTokenStored;
        }
        uint256 effectiveRate = getEffectiveRewardRate();
        if (effectiveRate == 0) {
            return rewardPerTokenStored;
        }
        uint256 timeApplicable = lastTimeRewardApplicable() - lastUpdateTime;
        return rewardPerTokenStored + (effectiveRate * timeApplicable * 1e18) / _totalSupply;
    }

    function earned(address account) public view override returns (uint256) {
        return
            ((_balances[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18) +
            rewards[account];
    }

    // Calculate effective reward rate considering the per-token cap
    function getEffectiveRewardRate() public view override returns (uint256) {
        if (_totalSupply == 0 || maxRewardRatePerToken == 0) {
            return rewardRate;
        }
        uint256 maxAllowedRewardRate = (maxRewardRatePerToken * _totalSupply) / 1e18;
        return Math.min(rewardRate, maxAllowedRewardRate);
    }

    function getDailyRewards() external view override returns (uint256) {
        return rewardRate * 1 days;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint256 amount) external override nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        _totalSupply += amount;
        _balances[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function stakeFor(
        uint256 amount,
        address recipient
    ) external override nonReentrant updateReward(recipient) {
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
    // and calling this function.
    function addToReward(uint256 reward) external override nonReentrant updateReward(address(0)) {
        require(reward > 0, "Cannot add 0 reward");
        rewardsToken.safeTransferFrom(msg.sender, address(this), reward);
        remainingRewards += reward;
        emit RewardAdded(reward);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    // Used by the owner to register reward tokens that were transferred into the contract
    // directly (e.g. by mistake) without going through addToReward.
    function notifyRewardAmount(
        uint256 reward
    ) external onlyOwner nonReentrant updateReward(address(0)) {
        require(reward > 0, "Cannot add 0 reward");
        remainingRewards += reward;
        require(
            rewardsToken.balanceOf(address(this)) >= remainingRewards,
            "Insufficient reward balance"
        );
        emit RewardAdded(reward);
    }

    // Set the daily rewards distribution (translates to per-second rewardRate).
    function setDailyRewards(uint256 _dailyRewards) external onlyOwner updateReward(address(0)) {
        rewardRate = _dailyRewards / 1 days;
        emit DailyRewardsUpdated(_dailyRewards);
    }

    // Set maximum reward rate per token per second.
    function setMaxRewardRatePerToken(
        uint256 _maxRewardRatePerToken
    ) external onlyOwner updateReward(address(0)) {
        maxRewardRatePerToken = _maxRewardRatePerToken;
        emit MaxRewardRateUpdated(_maxRewardRatePerToken);
    }

    // Recover non-staking, non-rewards ERC20 tokens accidentally sent to the contract.
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAddress != address(stakingToken), "Cannot withdraw the staking token");
        require(tokenAddress != address(rewardsToken), "Cannot withdraw the rewards token");
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address account) {
        if (_totalSupply > 0 && remainingRewards > 0) {
            uint256 effectiveRate = getEffectiveRewardRate();
            if (effectiveRate > 0) {
                uint256 timeElapsed = block.timestamp - lastUpdateTime;
                uint256 distributable = effectiveRate * timeElapsed;
                if (distributable > remainingRewards) {
                    distributable = remainingRewards;
                }
                if (distributable > 0) {
                    rewardPerTokenStored += (distributable * 1e18) / _totalSupply;
                    remainingRewards -= distributable;
                }
            }
        }

        lastUpdateTime = block.timestamp;

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
    event Recovered(address token, uint256 amount);
    event MaxRewardRateUpdated(uint256 newMaxRate);
    event DailyRewardsUpdated(uint256 newDailyRewards);
}
