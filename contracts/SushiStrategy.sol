// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.11;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {IStrategy} from "./Interfaces/IStrategy.sol";
import {IMasterChefV2} from "./Interfaces/IMasterChefV2.sol";

contract SushiStrategy is IStrategy {
  using SafeMath for uint256;

  address private _token;
  address[] private _rewardTokens;
  address private _sushiToken;
  address private _yggToken;
  address private _vault;
  uint256 private _vaultId;
  address private _bootstrapStakingPools;

  uint256 private _totalDeposited;

  constructor(address token, address vault, uint256 vaultId, address bootstrapStakingPools, address[] memory rewardTokens) public {
    _token = token;
    _vault = vault;
    _vaultId = vaultId;
    _bootstrapStakingPools = bootstrapStakingPools;
    _rewardTokens = rewardTokens;
    IERC20(token).approve(_vault, uint256(-1));
  }

  function token() external view override returns (address) {
    return _token;
  }

  function vault() external view override returns (address) {
    return _vault;
  }

  function vaultId() external view returns (uint256) {
    return _vaultId;
  }

  function rewardToken(uint256 index) external view returns (address) {
    return _rewardTokens[index];
  }

  function totalDeposited() external view override returns (uint256) {
    return _totalDeposited;
  }

  function deposit(address _sender, uint256 _amount) external override {
    _totalDeposited = _totalDeposited.add(_amount);
    IMasterChefV2(_vault).deposit(_vaultId, _amount,address(this));
  }

  function withdraw(address _recipient, uint256 _amount) external override returns (uint256, uint256) {
    require(msg.sender == _bootstrapStakingPools, "Only bootstrapStakingPools can withdraw");
    IMasterChefV2(_vault).withdraw(_vaultId, _amount,_recipient);
    _totalDeposited = _totalDeposited.sub(_amount);
    return (_amount, _amount);
  }

  function withdrawAll(address _recipient) external override returns (uint256, uint256) {
    require(msg.sender == _bootstrapStakingPools && _recipient == _bootstrapStakingPools, "Only bootstrapStakingPools can withdraw all");
    uint256 _withdrawAmount = _totalDeposited;
    IMasterChefV2(_vault).emergencyWithdraw(_vaultId, _recipient);
    _totalDeposited = 0;
    return (_withdrawAmount, _withdrawAmount);
  }

  function harvest(address _recipient) external override {
    IMasterChefV2(_vault).harvest(_vaultId, address(this));

    for (uint i = 0; i < _rewardTokens.length; i++) {
      address rewardTokenAddr = _rewardTokens[i];
      uint256 harvestAmount = IERC20(rewardTokenAddr).balanceOf(address(this));
      if (harvestAmount > 0) {
        IERC20(rewardTokenAddr).transfer(_recipient, harvestAmount);
        emit StrategyHarvested(address(this), _vault, rewardTokenAddr, harvestAmount);
      }
    }
  }
}
