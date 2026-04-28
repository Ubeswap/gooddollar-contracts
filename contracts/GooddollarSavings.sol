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

    // GoodDollar token address
    IERC20 public immutable gdToken;

    /* ========== STATE VARIABLES ========== */

    // Reward to be paid out per second (constant; only owner can change)
    uint256 public rewardRate;
    // Maximum reward rate per token per second (in wei per second per token) (0 = no cap)
    uint256 public maxRewardRatePerToken;
    // Reward tokens still available to be distributed
    uint256 public remainingRewards;
    // Reward tokens that have been distributed to stakers but not yet claimed.
    // Incremented when rewards leave `remainingRewards` via `updateReward`,
    // decremented when stakers claim/compound their rewards.
    uint256 public totalUnclaimedRewards;
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
        address _gdToken,
        uint256 _dailyRewards,
        uint256 _maxRewardRatePerToken
    ) Ownable(_owner) {
        require(_gdToken != address(0), "GoodDollar address is zero");
        gdToken = IERC20(_gdToken);
        _setDailyRewards(_dailyRewards);
        _setMaxRewardRatePerToken(_maxRewardRatePerToken);
    }

    /* ========== VIEWS ========== */

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function rewardPerToken() public view override returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored + (_pendingDistributable() * 1e18) / _totalSupply;
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

    // Timestamp when the current reward pool is expected to be depleted.
    // Returns 0 when rewards are not actively being distributed.
    function periodFinish() external view override returns (uint256) {
        if (_totalSupply == 0 || remainingRewards == 0) {
            return remainingRewards == 0 ? lastUpdateTime : 0;
        }

        uint256 effectiveRate = getEffectiveRewardRate();
        if (effectiveRate == 0) {
            return 0;
        }

        return lastUpdateTime + Math.ceilDiv(remainingRewards, effectiveRate);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint256 amount) external override nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        _totalSupply += amount;
        _balances[msg.sender] += amount;
        gdToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function stakeFor(
        uint256 amount,
        address recipient
    ) external override nonReentrant updateReward(recipient) {
        require(amount > 0, "Cannot stake 0");
        require(
            recipient != address(0) && recipient != address(this) && recipient != address(gdToken),
            "invalid address"
        );
        _totalSupply += amount;
        _balances[recipient] += amount;
        gdToken.safeTransferFrom(msg.sender, address(this), amount);
        emit StakedFor(msg.sender, recipient, amount);
    }

    function withdraw(uint256 amount) public override nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        _totalSupply -= amount;
        _balances[msg.sender] -= amount;
        gdToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public override nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            totalUnclaimedRewards -= reward;
            gdToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    // Claim pending rewards and immediately re-stake them in a single tx.
    function compound() external override nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        require(reward > 0, "No rewards to compound");
        rewards[msg.sender] = 0;
        totalUnclaimedRewards -= reward;
        _totalSupply += reward;
        _balances[msg.sender] += reward;
        emit RewardPaid(msg.sender, reward);
        emit Staked(msg.sender, reward);
    }

    function exit() external override {
        if (_balances[msg.sender] > 0) {
            withdraw(_balances[msg.sender]);
        }
        getReward();
    }

    // Permissionless: anyone may top up rewards by either:
    //  - approving and passing `reward > 0` (the contract will pull it via transferFrom), and/or
    //  - transferring GoodDollar directly to the contract beforehand.
    // Any token balance in excess of staked + remaining + unclaimed rewards is swept into
    // `remainingRewards`. This replaces the previous owner-only `notifyRewardAmount` flow.
    function addToReward(uint256 reward) external override nonReentrant updateReward(address(0)) {
        if (reward > 0) {
            gdToken.safeTransferFrom(msg.sender, address(this), reward);
        }
        uint256 expectedBalance = _totalSupply + remainingRewards + totalUnclaimedRewards;
        uint256 balance = gdToken.balanceOf(address(this));
        require(balance > expectedBalance, "No reward to add");
        uint256 toAdd = balance - expectedBalance;
        remainingRewards += toAdd;
        emit RewardAdded(toAdd);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    // Set the daily rewards distribution (translates to per-second rewardRate).
    function setDailyRewards(uint256 _dailyRewards) external onlyOwner updateReward(address(0)) {
        _setDailyRewards(_dailyRewards);
    }

    function _setDailyRewards(uint256 _dailyRewards) internal {
        require(_dailyRewards == 0 || _dailyRewards >= 1 days, "daily rewards too low");
        require(_dailyRewards < type(uint128).max, "invalid amount");
        rewardRate = _dailyRewards / 1 days;
        emit DailyRewardsUpdated(rewardRate, _dailyRewards);
    }

    // Set maximum reward rate per token per second.
    function setMaxRewardRatePerToken(uint256 _value) external onlyOwner updateReward(address(0)) {
        _setMaxRewardRatePerToken(_value);
    }

    function _setMaxRewardRatePerToken(uint256 _value) internal {
        require(_value == 0 || _value >= 1e6, "value too low");
        require(_value < type(uint128).max, "value too high");
        maxRewardRatePerToken = _value;
        emit MaxRewardRateUpdated(_value);
    }

    // Recover non-staking, non-rewards ERC20 tokens accidentally sent to the contract.
    function recoverERC20(
        address tokenAddress,
        uint256 tokenAmount
    ) external onlyOwner nonReentrant {
        require(tokenAddress != address(gdToken), "Cannot withdraw the GoodDollar token");
        IERC20(tokenAddress).safeTransfer(msg.sender, tokenAmount);
        emit Recovered(tokenAddress, tokenAmount, msg.sender);
    }

    // Amount of rewards that would be moved from `remainingRewards` into
    // `totalUnclaimedRewards` if `updateReward` ran at this exact block.
    // Single source of truth for both the view (`rewardPerToken`) and the
    // modifier so they cannot disagree on the depletion-block remainder.
    function _pendingDistributable() internal view returns (uint256) {
        if (_totalSupply == 0 || remainingRewards == 0) {
            return 0;
        }
        uint256 effectiveRate = getEffectiveRewardRate();
        if (effectiveRate == 0) {
            return 0;
        }
        uint256 distributable = effectiveRate * (block.timestamp - lastUpdateTime);
        if (distributable > remainingRewards) {
            distributable = remainingRewards;
        }
        return distributable;
    }

    /* ========== MODIFIERS ========== */
    modifier updateReward(address account) {
        uint256 distributable = _pendingDistributable();
        if (distributable > 0) {
            rewardPerTokenStored += (distributable * 1e18) / _totalSupply;
            remainingRewards -= distributable;
            totalUnclaimedRewards += distributable;
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
    event Recovered(address token, uint256 amount, address receiver);
    event MaxRewardRateUpdated(uint256 newMaxRate);
    event DailyRewardsUpdated(uint256 rewardRate, uint256 givenDailyRewards);
}
