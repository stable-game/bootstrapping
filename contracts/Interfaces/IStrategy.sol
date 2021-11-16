// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.11;

interface IStrategy {
  function token() external view returns (address);
  function vault() external view returns (address);
  function totalDeposited() external view returns (uint256);
  function deposit(address _sender, uint256 _amount) external;
  function withdraw(address _recipient, uint256 _amount) external returns (uint256, uint256);
  function withdrawAll(address _recipient) external returns (uint256, uint256);
  function harvest(address _recipient) external;

  event StrategyHarvested(
    address indexed strategy,
    address vault,
    address token,
    uint256 harvestAmount
  );
}
