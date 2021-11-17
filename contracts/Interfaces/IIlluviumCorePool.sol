// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;


interface IIlluviumCorePool {
  function stake(uint256 _amount,uint64 _lockUntil,bool _useSILV) external;
  function unstake(uint256 _depositId, uint256 _amount, bool _useSILV) external;
  function processRewards(bool _useSILV) external;
  function getDepositsLength(address _user) external view returns (uint256);
}
