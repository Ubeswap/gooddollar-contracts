// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title StakingVault
 * @notice Holds staked Tokens in isolation from the reward pool.
 * @dev Only the staking contract can deposit/withdraw.
 *      This ensures that reward streams can never accidentally drain staked principal,
 *      and staked principal is never mistaken for available reward balance.
 *      Stake contract should deploy this contract.
 */
contract StakingVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;
    address public immutable stakingContract;

    error OnlyStakingContract();
    error ZeroAddress();

    modifier onlyStaking() {
        if (msg.sender != stakingContract) revert OnlyStakingContract();
        _;
    }

    constructor(address _stakingToken) {
        stakingToken = IERC20(_stakingToken);
        stakingContract = msg.sender;
    }

    /// @notice Pull tokens from the staking contract into the vault.
    /// @dev The staking contract must have approved this vault beforehand.
    function deposit(uint256 amount) external onlyStaking {
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Send tokens from the vault back to a user (on withdraw/exit).
    function withdraw(address to, uint256 amount) external onlyStaking {
        stakingToken.safeTransfer(to, amount);
    }

    /// @notice View the total staked principal held in the vault.
    function balance() external view returns (uint256) {
        return stakingToken.balanceOf(address(this));
    }
}
