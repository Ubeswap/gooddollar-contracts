// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IGooddollarSavingsStream {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function getEffectiveFlowRate() external view returns (int96);
    function getDailyRewards() external view returns (uint256);
    function periodFinish() external view returns (uint256);

    function stake(uint256 amount) external;
    function stakeFor(uint256 amount, address recipient) external;
    function withdraw(uint256 amount) external;
    function exit() external;
    function addToReward(uint256 reward) external;
}
