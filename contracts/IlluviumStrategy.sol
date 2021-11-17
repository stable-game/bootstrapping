// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.11;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {IStrategy} from "./Interfaces/IStrategy.sol";
import {IIlluviumCorePool} from "./Interfaces/IIlluviumCorePool.sol";

contract IlluviumStrategy is IStrategy {
  using SafeMath for uint256;

  address private _token;
  address private _vault;
  address private _silv;
  address private _bootstrapStakingPools;

  uint256 private _totalDeposited;

  mapping(address => uint256[]) private userDepositedIds;
  mapping(uint256 => uint256) private depositedAmounts;

  constructor(address token, address vault, address silv, address bootstrapStakingPools) public {
    _token = token;
    _vault = vault;
    _silv = silv;
    _bootstrapStakingPools = bootstrapStakingPools;
    IERC20(token).approve(vault,uint256(-1));
  }

  function token() external view override returns (address) {
    return _token;
  }

  function vault() external view override returns (address) {
    return _vault;
  }

  function totalDeposited() external view override returns (uint256) {
    return _totalDeposited;
  }

  function nextDepositedId() internal view returns (uint256) {
    if (IIlluviumCorePool(_vault).getDepositsLength(address(this)) > 0) {
      return IIlluviumCorePool(_vault).getDepositsLength(address(this));
    } else {
      return 0;
    }

  }

  function deposit(address sender, uint256 _amount) external override{
    _totalDeposited = _totalDeposited.add(_amount);
    uint256 nextId = nextDepositedId();
    IIlluviumCorePool(_vault).stake(_amount, 0, true);
    userDepositedIds[sender].push(nextId);
    depositedAmounts[nextId] = _amount;
  }

  function withdraw(address _recipient, uint256 _amount) external override returns (uint256, uint256) {
    require(msg.sender == _bootstrapStakingPools, "Only bootstrapStakingPools can withdraw");

    uint256[] memory deposits = userDepositedIds[_recipient];
    uint256 remaining = _amount;
    for (uint i=0; i < deposits.length; i++) {

      if (remaining >= depositedAmounts[deposits[i]] && depositedAmounts[deposits[i]] > 0) {
        IIlluviumCorePool(_vault).unstake(deposits[i],depositedAmounts[deposits[i]],true);
        remaining = remaining - depositedAmounts[deposits[i]];
        depositedAmounts[deposits[i]] = 0;
      } else if (remaining < depositedAmounts[deposits[i]]) {
        IIlluviumCorePool(_vault).unstake(deposits[i], remaining, true);
        depositedAmounts[deposits[i]] = depositedAmounts[deposits[i]] - remaining;
        remaining = 0;
        break;
      }
    }

    IERC20(_token).transfer(_recipient,_amount);
    _totalDeposited = _totalDeposited.sub(_amount);
    return (_amount, _amount);
  }

  function withdrawAll(address _recipient) external override returns (uint256, uint256) {
    require(msg.sender == _bootstrapStakingPools && _recipient == _bootstrapStakingPools, "Only bootstrapStakingPools can withdraw all");

    for (uint i = 0; i < nextDepositedId(); i++) {
      if(depositedAmounts[i] > 0){
        IIlluviumCorePool(_vault).unstake(i, depositedAmounts[i], true);
        depositedAmounts[i] = 0;
      }
    }

    uint256 withdrawAmount = IERC20(_token).balanceOf(address(this));
    IERC20(_token).transfer(_recipient, IERC20(_token).balanceOf(address(this)));
    _totalDeposited = 0;
    return (withdrawAmount, withdrawAmount);
  }

  function harvest(address _recipient) external override {
    IIlluviumCorePool(_vault).processRewards(true);
    uint256 harvestAmount = IERC20(_silv).balanceOf(address(this));
    IERC20(_silv).transfer(_recipient, harvestAmount);
    emit StrategyHarvested(address(this), _vault, _silv, harvestAmount);
  }
}
