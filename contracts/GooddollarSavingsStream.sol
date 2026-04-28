// SPDX-License-Identifier: MIT
// solhint-disable not-rely-on-time

pragma solidity ^0.8.23;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { ISuperToken } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperToken.sol";
import { ISuperfluidPool } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/gdav1/ISuperfluidPool.sol";
import { SuperTokenV1Library } from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";
import { PoolConfig } from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";

import { StakingVault } from "./StakingVault.sol";
import { IGooddollarSavingsStream } from "./interfaces/IGooddollarSavingsStream.sol";

/**
 * @title GooddollarSavingsStream
 * @notice Staking contract for GoodDollar (G$) native Super Token that distributes
 *         rewards as a continuous Superfluid stream via a GDA Distribution Pool.
 *
 * @dev Architecture overview:
 *
 *  ┌─────────────┐   stake()    ┌────────────────────────┐
 *  │   Staker    │ ──────────►  │  GooddollarSavingsStream│
 *  └─────────────┘              │  (this contract)        │
 *        ▲                      │                         │
 *        │  streaming           │  - Manages pool units   │
 *        │  rewards             │  - Computes flow rate   │
 *        │  (real-time)         │  - Enforces APR cap     │
 *        │                      └────────┬───────────────┘
 *        │                               │
 *        │                     ┌─────────▼──────────┐
 *        │                     │  Superfluid GDA    │
 *        │◄────────────────────│  Distribution Pool │
 *        │                     └────────────────────┘
 *        │
 *        │  Staked tokens held safely in:
 *        │                     ┌────────────────────┐
 *        └─────────────────────│   StakingVault     │
 *                              └────────────────────┘
 *
 * KEY DESIGN DECISIONS:
 *
 *  1. VAULT SEPARATION: Staked tokens are held in a separate StakingVault contract.
 *     This contract (the main staking contract) holds ONLY reward tokens.
 *     Superfluid streams drain from this contract's Super Token balance, so keeping
 *     staked principal in the vault prevents the stream from consuming staked funds.
 *
 *  2. APR CAP via FLOW RATE: Rewards are determined by two parameters set by the owner:
 *      - `rewardRate`: the target total reward distribution per second (global cap).
 *      - `maxRewardRatePerToken`: the max reward per staked token per second
 *     effectiveFlowRate = min(rewardRate, maxRewardRatePerToken * totalSupply / 1e18)
 *
 *     When totalSupply is small, the APR cap kicks in → lower flow rate → rewards last longer.
 *     When totalSupply is large, rewardRate is the binding constraint.
 *
 *  3. FLOW RATE UPDATES: Every stake/unstake recalculates the effective flow rate and
 *     calls `distributeFlow()` on the Superfluid pool. This is a single tx that atomically
 *     updates what every staker receives per second, proportional to their units.
 *
 *  4. REWARD EXHAUSTION PROTECTION: Before each flow rate update, we check if the contract's
 *     reward balance can sustain the stream. If rewards are running low the flow stops.
 *     In order to do this syncFlowRate() should be called.
 *
 *  5. UNITS = STAKE AMOUNT: Each staker's pool units equal their staked amount (divided
 *     by a scaling factor to keep units manageable). Superfluid automatically distributes
 *     the flow proportionally.
 *
 *  6. STAKING & REWARD TOKEN ARE THE SAME NATIVE SUPER TOKEN (G$). The vault holds the
 *     staked principal; this contract holds reward balance and streams it out.
 */
contract GooddollarSavingsStream is IGooddollarSavingsStream, Ownable, ReentrancyGuard {
    using SuperTokenV1Library for ISuperToken;

    // ═══════════════════════════════════════════════════════════════════════
    //                          CONSTANTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Minimum reward buffer: keep enough for ~4 hours of streaming so
    ///         Superfluid doesn't liquidate the flow before a keeper can react.
    uint256 public constant MIN_STREAM_BUFFER_SECONDS = 4 hours;

    /// @notice Scaling factor: pool units = stakedAmount / SCALING_FACTOR.
    ///         Keeps units << flow rate to minimize GDA integer-division dust.
    ///         Example: if G$ has 18 decimals and SCALING_FACTOR = 1e12,
    ///         then 1000 G$ staked = 1000e18 / 1e12 = 1_000_000 units.
    uint256 public constant SCALING_FACTOR = 1e12;

    // ═══════════════════════════════════════════════════════════════════════
    //                          IMMUTABLES
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The G$ native Super Token (used for both staking and rewards).
    ISuperToken public immutable superToken;

    /// @notice The vault that holds staked principal in isolation.
    StakingVault public immutable vault;

    // ═══════════════════════════════════════════════════════════════════════
    //                          STATE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The Superfluid GDA distribution pool for reward streaming.
    ISuperfluidPool public pool;

    /// @notice Target reward rate: tokens distributed per second (global cap).
    uint256 public rewardRate;

    /// @notice Max reward per staked-token per second (APR cap), scaled by 1e18.
    ///         Set to 0 to disable the cap.
    ///         Example for 5% APR: 5e16 / 365.25 days ≈ 1_585_489_599_188 (wei/sec/token)
    uint256 public maxRewardRatePerToken;

    /// @notice Total amount of tokens currently staked.
    uint256 private _totalSupply;

    /// @notice Per-user staked balance.
    mapping(address => uint256) private _balances;

    // ═══════════════════════════════════════════════════════════════════════
    //                          EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    event Staked(address indexed user, uint256 amount);
    event StakedFor(address indexed staker, address indexed recipient, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardAdded(uint256 amount);
    event DailyRewardsUpdated(uint256 rewardRate, uint256 givenDailyRewards);
    event MaxRewardRateUpdated(uint256 newMaxRate);
    event FlowRateUpdated(int96 newFlowRate);
    event Recovered(address token, uint256 amount, address receiver);
    event StreamStopped(string reason);

    // ═══════════════════════════════════════════════════════════════════════
    //                          ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    error CannotStakeZero();
    error CannotWithdrawZero();
    error InsufficientStake();
    error InvalidAddress();
    error InvalidAmount();
    error NoRewardToAdd();
    error CannotRecoverStakingToken();

    // ═══════════════════════════════════════════════════════════════════════
    //                          CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @param _owner              Contract owner (can set rates, recover tokens).
     * @param _superToken         The G$ native Super Token address.
     * @param _dailyRewards       Initial daily reward amount (in token wei).
     * @param _maxRewardRatePerToken  Max reward per staked token per second (1e18 scaled). 0 = no cap.
     */
    constructor(
        address _owner,
        ISuperToken _superToken,
        uint256 _dailyRewards,
        uint256 _maxRewardRatePerToken
    ) Ownable(_owner) {
        require(address(_superToken) != address(0), "zero token");

        superToken = _superToken;
        vault = new StakingVault(address(_superToken));
        _superToken.approve(address(vault), type(uint256).max);

        // Create a Superfluid GDA distribution pool.
        // - This contract is the pool admin.
        // - Units are NOT transferable (staking contract controls them).
        // - Distribution only from this contract (not multi-distributor).
        pool = _superToken.createPool(
            address(this),
            PoolConfig({ transferabilityForUnitsOwner: false, distributionFromAnyAddress: false })
        );

        _setDailyRewards(_dailyRewards);
        _setMaxRewardRatePerToken(_maxRewardRatePerToken);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          VIEWS
    // ═══════════════════════════════════════════════════════════════════════

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    /// @notice Returns the daily reward amount at the current settings.
    function getDailyRewards() external view override returns (uint256) {
        return rewardRate * 1 days;
    }

    /**
     * @notice Compute the effective flow rate (tokens/sec) accounting for both
     *         the global rewardRate cap and the per-token APR cap.
     *
     *  effectiveRate = min(rewardRate, maxRewardRatePerToken * totalSupply / 1e18)
     *
     *  This rate is further capped by the available reward balance to prevent
     *  Superfluid liquidation.
     */
    function getEffectiveFlowRate() public view override returns (int96) {
        if (_totalSupply == 0 || rewardRate == 0) return 0;

        uint256 available = superToken.balanceOf(address(this));
        if (available == 0) return 0;

        uint256 effectiveRate = rewardRate;

        // Apply APR cap if configured.
        if (maxRewardRatePerToken > 0) {
            uint256 maxAllowed = (maxRewardRatePerToken * _totalSupply) / 1e18;
            effectiveRate = Math.min(effectiveRate, maxAllowed);
        }

        // Superfluid flow rates are int96.
        if (effectiveRate > uint256(uint96(type(int96).max))) {
            effectiveRate = uint256(uint96(type(int96).max));
        }

        // Hard stop if balance can't sustain the candidate rate for at least
        // 2x the Superfluid buffer. This keeps the buffer intact and guarantees
        // a safety window for keepers/top-ups before any liquidation risk.
        uint256 minSafeBalance = effectiveRate * MIN_STREAM_BUFFER_SECONDS * 2;
        if (available < minSafeBalance) return 0;

        return int96(int256(effectiveRate));
    }

    /// @notice Estimated timestamp when reward balance will be fully drained
    ///         at the current effective flow rate.
    function periodFinish() external view override returns (uint256) {
        int96 flowRate = getEffectiveFlowRate();
        if (flowRate <= 0) return 0;

        uint256 available = superToken.balanceOf(address(this));
        if (available == 0) return block.timestamp;

        return block.timestamp + (available / uint256(uint96(flowRate)));
    }

    /// @notice Get the current Superfluid pool units for a given account.
    function getUnits(address account) external view returns (uint128) {
        return pool.getUnits(account);
    }

    /// @notice Get total units in the Superfluid pool.
    function getTotalUnits() external view returns (uint128) {
        return pool.getTotalUnits();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      STAKING / UNSTAKING
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Stake G$ tokens. Tokens are transferred to the vault; pool units
     *         are assigned proportional to staked amount; the stream flow rate
     *         is recalculated to enforce the APR cap.
     */
    function stake(uint256 amount) external override nonReentrant {
        if (amount == 0) revert CannotStakeZero();

        // 1. Transfer tokens from user → this contract → vault.
        superToken.transferFrom(msg.sender, address(this), amount);
        superToken.approve(address(vault), amount);
        vault.deposit(amount);

        // 2. Update bookkeeping.
        _totalSupply += amount;
        _balances[msg.sender] += amount;

        // 3. Update Superfluid pool units for this staker.
        _updateUnits(msg.sender);

        // 4. Recalculate and apply the stream flow rate (APR cap check).
        _syncFlowRate();

        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Stake G$ on behalf of another address.
     */
    function stakeFor(uint256 amount, address recipient) external override nonReentrant {
        if (amount == 0) revert CannotStakeZero();
        if (
            recipient == address(0) ||
            recipient == address(this) ||
            recipient == address(superToken) ||
            recipient == address(vault)
        ) revert InvalidAddress();

        superToken.transferFrom(msg.sender, address(this), amount);
        vault.deposit(amount);

        _totalSupply += amount;
        _balances[recipient] += amount;

        _updateUnits(recipient);
        _syncFlowRate();

        emit StakedFor(msg.sender, recipient, amount);
    }

    /**
     * @notice Withdraw staked G$ tokens. Reduces pool units and recalculates
     *         the stream flow rate.
     */
    function withdraw(uint256 amount) public override nonReentrant {
        if (amount == 0) revert CannotWithdrawZero();
        if (_balances[msg.sender] < amount) revert InsufficientStake();

        // 1. Update bookkeeping.
        _totalSupply -= amount;
        _balances[msg.sender] -= amount;

        // 2. Update pool units.
        _updateUnits(msg.sender);

        // 3. Recalculate flow rate.
        _syncFlowRate();

        // 4. Transfer tokens from vault → user.
        vault.withdraw(msg.sender, amount);

        emit Withdrawn(msg.sender, amount);
    }

    /**
     * @notice Withdraw all staked tokens.
     */
    function exit() external override {
        if (_balances[msg.sender] > 0) {
            withdraw(_balances[msg.sender]);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      REWARD MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Permissionless: add reward tokens to the contract.
     *         Caller approves this contract, then calls addToReward(amount).
     */
    function addToReward(uint256 reward) external override nonReentrant {
        if (reward == 0) revert NoRewardToAdd();
        superToken.transferFrom(msg.sender, address(this), reward);

        // Re-sync the flow rate in case we were throttled due to low balance.
        _syncFlowRate();

        emit RewardAdded(reward);
    }

    /**
     * @notice Permissionless: if someone sent tokens directly to this contract,
     *         re-sync the flow rate to account for the new balance.
     */
    function syncFlowRate() external nonReentrant {
        _syncFlowRate();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      OWNER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Set the target daily reward distribution.
    function setDailyRewards(uint256 _dailyRewards) external onlyOwner {
        _setDailyRewards(_dailyRewards);
        _syncFlowRate();
    }

    /// @notice Set the maximum per-token-per-second reward rate (APR cap). 0 = no cap.
    function setMaxRewardRatePerToken(uint256 _value) external onlyOwner {
        _setMaxRewardRatePerToken(_value);
        _syncFlowRate();
    }

    /// @notice Recover non-G$ ERC20 tokens accidentally sent to this contract.
    function recoverERC20(
        address tokenAddress,
        uint256 tokenAmount
    ) external onlyOwner nonReentrant {
        if (tokenAddress == address(superToken)) revert CannotRecoverStakingToken();
        ISuperToken(tokenAddress).transfer(msg.sender, tokenAmount);
        emit Recovered(tokenAddress, tokenAmount, msg.sender);
    }

    /// @notice Emergency: stop all streaming and set flow rate to zero.
    function emergencyStopStream() external onlyOwner {
        superToken.distributeFlow(address(this), pool, int96(0));
        emit StreamStopped("emergency");
        emit FlowRateUpdated(int96(0));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      INTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    function _setDailyRewards(uint256 _dailyRewards) internal {
        require(_dailyRewards == 0 || _dailyRewards >= 1 days, "daily rewards too low");
        require(_dailyRewards < type(uint128).max, "invalid amount");
        rewardRate = _dailyRewards / 1 days;
        emit DailyRewardsUpdated(rewardRate, _dailyRewards);
    }

    function _setMaxRewardRatePerToken(uint256 _value) internal {
        require(_value == 0 || _value >= 1e6, "value too low");
        require(_value < type(uint128).max, "value too high");
        maxRewardRatePerToken = _value;
        emit MaxRewardRateUpdated(_value);
    }

    /**
     * @dev Update the Superfluid pool units for a specific account.
     *      units = _balances[account] / SCALING_FACTOR
     *      If user fully withdraws, units go to 0 → they stop receiving stream.
     */
    function _updateUnits(address account) internal {
        uint128 newUnits = uint128(_balances[account] / SCALING_FACTOR);
        pool.updateMemberUnits(account, newUnits);
    }

    /**
     * @dev Core function: recalculates the effective flow rate (respecting both the
     *      global rewardRate and the per-token APR cap) and updates the Superfluid
     *      distribution pool's flow.
     *      Called on every stake, unstake, reward addition, and parameter change.
     */
    function _syncFlowRate() internal {
        int96 newFlowRate = getEffectiveFlowRate();

        // Get current flow rate to avoid unnecessary Superfluid calls.
        int96 currentFlowRate = superToken.getFlowDistributionFlowRate(address(this), pool);

        if (newFlowRate != currentFlowRate) {
            superToken.distributeFlow(address(this), pool, newFlowRate);
            emit FlowRateUpdated(newFlowRate);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                      HELPER: APR CALCULATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Utility: calculate the maxRewardRatePerToken value for a desired APR.
     * @param aprBps  Desired APR in basis points (e.g. 500 = 5%).
     * @return The maxRewardRatePerToken value to pass to the constructor or setter.
     * @dev Formula: maxRewardRatePerToken = (aprBps * 1e18) / (10_000 * 365.25 days)
     */
    function calculateMaxRateForAPR(uint256 aprBps) external pure returns (uint256) {
        return (aprBps * 1e18) / (10_000 * 365.25 days);
    }
}
