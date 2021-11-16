// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.11;
pragma experimental ABIEncoderV2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {FixedPointMath} from "./Libraries/FixedPointMath.sol";
import {Pool} from "./Libraries/pools/Pool.sol";
import {Stake} from "./Libraries/pools/Stake.sol";
import {Power} from "./Libraries/pools/Power.sol";
import {IStrategy} from "./Interfaces/IStrategy.sol";
import "hardhat/console.sol";

contract BootstrapStakingPools is ReentrancyGuard {
  using FixedPointMath for FixedPointMath.uq192x64;
  using Pool for Pool.Data;
  using Pool for Pool.List;
  using SafeERC20 for IERC20;
  using SafeMath for uint256;
  using Stake for Stake.Data;
  using Power for Power.Data;

  event PendingGovernanceUpdated(
    address pendingGovernance
  );

  event GovernanceUpdated(
    address governance
  );

  event HarvestRewardCollectorUpdated(
    address harvestRewardCollector
  );

  event RewardRateUpdated(
    uint256 rewardRate
  );

  event PoolRewardWeightUpdated(
    uint256 indexed poolId,
    uint256 rewardWeight
  );

  event PoolCreated(
    uint256 indexed poolId,
    IERC20 indexed token,
    address strategy
  );

  event PoolStrategyUpdated(
    uint256 indexed poolId,
    address strategy
  );

  event PoolPauseUpdated(
    uint256 indexed poolId,
    bool status
  );

  event TokensDeposited(
    address indexed user,
    uint256 indexed poolId,
    address strategy,
    uint256 amount
  );

  event TokensWithdrawn(
    address indexed user,
    uint256 indexed poolId,
    address strategy,
    uint256 amount
  );

  event StrategyDeposited(
    uint256 indexed poolId,
    address strategy,
    uint256 amount
  );

  event StrategyRecalled(
    uint256 indexed poolId,
    address strategy,
    uint256 withdrawnAmount,
    uint256 decreasedValue
  );

  event PoolFlushed(
    uint256 indexed poolId,
    address strategy,
    uint256 amount
  );

  event PauseAllUpdated(
    bool status
  );

  event SentinelUpdated(
    address sentinel
  );

  address public governance;

  address public pendingGovernance;

  address public sentinel;

  address public harvestRewardCollector;

  mapping(IERC20 => uint256) public tokenPoolIds;

  Pool.Context private _ctx;

  Pool.List private _pools;

  mapping(address => mapping(uint256 => Stake.Data)) private _stakes;

  mapping(address => mapping(uint256 => Power.Data)) private _powers;

  mapping(address => mapping(uint256 => bool)) public userIsKnown;

  mapping(uint256 => mapping(uint256 => address)) public userList;

  mapping(uint256 => uint256) public nextUser;

  bool public pauseAll;

  constructor(
    address _governance,
    address _sentinel,
    address _harvestRewardCollector
  ) public {
    require(_governance != address(0), "BootstrapStakingPools: governance address cannot be 0x0");
    require(_sentinel != address(0), "BootstrapStakingPools: sentinel address cannot be 0x0");
    require(_harvestRewardCollector != address(0), "BootstrapStakingPools: harvestRewardCollector address cannot be 0x0");

    governance = _governance;
    sentinel = _sentinel;
    harvestRewardCollector = _harvestRewardCollector;
  }

  modifier onlyGovernance() {
    require(msg.sender == governance, "BootstrapStakingPools: only governance");
    _;
  }

  modifier checkIfNewUser(uint256 pid) {
    if (!userIsKnown[msg.sender][pid]) {
      userList[nextUser[pid]][pid] = msg.sender;
      userIsKnown[msg.sender][pid] = true;
      nextUser[pid]++;
    }
    _;
  }

  function setPendingGovernance(address _pendingGovernance) external onlyGovernance {
    require(_pendingGovernance != address(0), "BootstrapStakingPools: pending governance address cannot be 0x0");
    pendingGovernance = _pendingGovernance;

    emit PendingGovernanceUpdated(_pendingGovernance);
  }

  function acceptGovernance() external {
    require(msg.sender == pendingGovernance, "BootstrapStakingPools: only pending governance");

    address _pendingGovernance = pendingGovernance;
    governance = _pendingGovernance;

    emit GovernanceUpdated(_pendingGovernance);
  }

  function setRewardRate(uint256 _rewardRate) external onlyGovernance {
    _updatePools();

    _ctx.rewardRate = _rewardRate;

    emit RewardRateUpdated(_rewardRate);
  }

  function createPool(IERC20 _token, address _strategy) external onlyGovernance returns (uint256) {
    require(tokenPoolIds[_token] == 0, "BootstrapStakingPools: token already has a pool");

    uint256 _poolId = _pools.length();

    _pools.push(Pool.Data({
      token: _token,
      totalDeposited: 0,
      rewardWeight: 0,
      accumulatedRewardWeight: FixedPointMath.uq192x64(0),
      lastUpdatedBlock: block.number,
      strategy: _strategy,
      pause: false
    }));

    tokenPoolIds[_token] = _poolId + 1;

    emit PoolCreated(_poolId, _token, _strategy);

    return _poolId;
  }

  function setRewardWeights(uint256[] calldata _rewardWeights) external onlyGovernance {
    require(_rewardWeights.length == _pools.length(), "BootstrapStakingPools: weights length mismatch");

    _updatePools();

    uint256 _totalRewardWeight = _ctx.totalRewardWeight;
    for (uint256 _poolId = 0; _poolId < _pools.length(); _poolId++) {
      Pool.Data storage _pool = _pools.get(_poolId);

      uint256 _currentRewardWeight = _pool.rewardWeight;
      if (_currentRewardWeight == _rewardWeights[_poolId]) {
        continue;
      }

      _totalRewardWeight = _totalRewardWeight.sub(_currentRewardWeight).add(_rewardWeights[_poolId]);
      _pool.rewardWeight = _rewardWeights[_poolId];

      emit PoolRewardWeightUpdated(_poolId, _rewardWeights[_poolId]);
    }

    _ctx.totalRewardWeight = _totalRewardWeight;
  }

  function migrateStrategy(uint256 _poolId, address _newStrategy) external onlyGovernance {

    Pool.Data storage _pool = _pools.get(_poolId);
    require(_pool.pause, "BootstrapStakingPools: not paused");

    address strategy = _pool.strategy;

    if (strategy != address(0)) {
      harvest(_poolId);
      recallAll(_poolId);
    }
    updateStrategy(_poolId, _newStrategy);
    setPause(_poolId, false);

    emit PoolStrategyUpdated(_poolId, _newStrategy);
  }

  function updateStrategy(uint256 _poolId, address _newStrategy) public onlyGovernance {

    Pool.Data storage _pool = _pools.get(_poolId);
    require(_pool.pause, "BootstrapStakingPools: not paused");

    _pool.strategy = _newStrategy;

    emit PoolStrategyUpdated(_poolId, _newStrategy);
  }

  function setPause(uint256 _poolId, bool _pause) public onlyGovernance {
    Pool.Data storage _pool = _pools.get(_poolId);
    _pool.pause = _pause;

    emit PoolPauseUpdated(_poolId, _pause);
  }

  function deposit(uint256 _poolId, uint256 _depositAmount) external nonReentrant checkIfNewUser(_poolId) {
    require(!pauseAll, "BootstrapStakingPools: not paused");

    Pool.Data storage _pool = _pools.get(_poolId);
    require(!_pool.pause, "BootstrapStakingPools: pool not paused");

    _pool.update(_ctx);

    Stake.Data storage _stake = _stakes[msg.sender][_poolId];
    Power.Data storage _power = _powers[msg.sender][_poolId];

    _stake.update(_pool, _ctx);
    _power.update(_pool, _ctx);

    _deposit(_poolId, _depositAmount);
  }

  function withdraw(uint256 _poolId, uint256 _withdrawAmount) external nonReentrant {
    Pool.Data storage _pool = _pools.get(_poolId);
    _pool.update(_ctx);

    Stake.Data storage _stake = _stakes[msg.sender][_poolId];
    Power.Data storage _power = _powers[msg.sender][_poolId];

    _stake.update(_pool, _ctx);
    _power.update(_pool, _ctx);

    _withdraw(_poolId, _withdrawAmount);
  }

  function recallAll(uint256 _poolId) public onlyGovernance {
    Pool.Data storage _pool = _pools.get(_poolId);
    require(_pool.pause, "BootstrapStakingPools: pool not paused");

    address strategy = _pool.strategy;
    require(strategy != address(0), "BootstrapStakingPools: cannot recall if no strategy is set");
    (uint256 _withdrawnAmount, uint256 _decreasedValue) = IStrategy(strategy).withdrawAll(address(this));

    emit StrategyRecalled(_poolId, strategy, _withdrawnAmount, _decreasedValue);
  }

  function flush(uint256 _poolId) public onlyGovernance {
    Pool.Data storage _pool = _pools.get(_poolId);
    require(!_pool.pause, "BootstrapStakingPools: pool paused");

    address strategy = _pool.strategy;
    require(strategy != address(0), "BootstrapStakingPools: cannot flush if no strategy is set");

    uint256 flushAmount = _pool.token.balanceOf(address(this));
    _pool.token.safeTransfer(strategy, flushAmount);
    IStrategy(strategy).deposit(msg.sender, flushAmount);

    emit StrategyDeposited(_poolId, strategy, flushAmount);
    emit PoolFlushed(_poolId, strategy, flushAmount);
  }

  function harvest(uint256 _poolId) public onlyGovernance {
    require(harvestRewardCollector != address(0), "BootstrapStakingPools: harvestRewardCollector must be set");

    Pool.Data storage _pool = _pools.get(_poolId);
    address strategy = _pool.strategy;
    require(strategy != address(0), "BootstrapStakingPools: cannot harvest if no strategy is set");
    IStrategy(strategy).harvest(harvestRewardCollector);
  }

  function rewardRate() external view returns (uint256) {
    return _ctx.rewardRate;
  }

  function totalRewardWeight() external view returns (uint256) {
    return _ctx.totalRewardWeight;
  }

  function poolCount() external view returns (uint256) {
    return _pools.length();
  }

  function getPoolToken(uint256 _poolId) external view returns (IERC20) {
    Pool.Data storage _pool = _pools.get(_poolId);
    return _pool.token;
  }

  function getPoolTotalDeposited(uint256 _poolId) external view returns (uint256) {
    Pool.Data storage _pool = _pools.get(_poolId);
    return _pool.totalDeposited;
  }

  function getPoolRewardWeight(uint256 _poolId) external view returns (uint256) {
    Pool.Data storage _pool = _pools.get(_poolId);
    return _pool.rewardWeight;
  }

  function getPoolPause(uint256 _poolId) external view returns (bool) {
    Pool.Data storage _pool = _pools.get(_poolId);
    return _pool.pause;
  }

  function getPoolStrategy(uint256 _poolId) external view returns (address) {
    Pool.Data storage _pool = _pools.get(_poolId);
    return _pool.strategy;
  }

  function getPoolRewardRate(uint256 _poolId) external view returns (uint256) {
    Pool.Data storage _pool = _pools.get(_poolId);
    return _pool.getRewardRate(_ctx);
  }

  function getStakeTotalDeposited(address _account, uint256 _poolId) external view returns (uint256) {
    Stake.Data storage _stake = _stakes[_account][_poolId];
    return _stake.totalDeposited;
  }

  function getAccumulatedPower(address _account, uint256 _poolId) external view returns (uint256) {
    Power.Data storage _power = _powers[_account][_poolId];
    return _power.getUpdatedTotalPower(_pools.get(_poolId), _ctx);
  }

  function getPoolUser(uint256 _poolId, uint256 _userIndex) external view returns (address) {
    return userList[_userIndex][_poolId];
  }

  function _updatePools() internal {
    for (uint256 _poolId = 0; _poolId < _pools.length(); _poolId++) {
      Pool.Data storage _pool = _pools.get(_poolId);
      _pool.update(_ctx);
    }
  }

  function _deposit(uint256 _poolId, uint256 _depositAmount) internal {
    Pool.Data storage _pool = _pools.get(_poolId);
    Stake.Data storage _stake = _stakes[msg.sender][_poolId];
    Power.Data storage _power = _powers[msg.sender][_poolId];

    _pool.totalDeposited = _pool.totalDeposited.add(_depositAmount);
    _stake.totalDeposited = _stake.totalDeposited.add(_depositAmount);
    _power.totalDeposited = _power.totalDeposited.add(_depositAmount);

    address strategy = _pool.strategy;
    bool hasStrategy = strategy != address(0);

    if (hasStrategy) {
      _pool.token.safeTransferFrom(msg.sender, strategy, _depositAmount);
      IStrategy(strategy).deposit(msg.sender, _depositAmount);
      emit StrategyDeposited(_poolId, strategy, _depositAmount);
    } else {
      _pool.token.safeTransferFrom(msg.sender, address(this), _depositAmount);
    }

    emit TokensDeposited(msg.sender, _poolId, strategy, _depositAmount);
  }

  function _withdraw(uint256 _poolId, uint256 _withdrawAmount) internal {
    Pool.Data storage _pool = _pools.get(_poolId);
    Stake.Data storage _stake = _stakes[msg.sender][_poolId];
    Power.Data storage _power = _powers[msg.sender][_poolId];

    _pool.totalDeposited = _pool.totalDeposited.sub(_withdrawAmount);
    _stake.totalDeposited = _stake.totalDeposited.sub(_withdrawAmount);
    _power.totalDeposited = _power.totalDeposited.sub(_withdrawAmount);

    address strategy = _pool.strategy;
    bool hasStrategy = strategy != address(0);
    if (hasStrategy) {
      (uint256 _withdrawnAmount, uint256 _decreasedValue) = IStrategy(strategy).withdraw(msg.sender, _withdrawAmount);
      emit StrategyRecalled(_poolId, strategy, _withdrawnAmount, _decreasedValue);
    } else {
      _pool.token.safeTransfer(msg.sender, _withdrawAmount);
    }

    emit TokensWithdrawn(msg.sender, _poolId, strategy, _withdrawAmount);
  }

  function setSentinel(address _sentinel) external onlyGovernance {
    require(_sentinel != address(0), "BootstrapStakingPools: sentinel address cannot be 0x0.");
    sentinel = _sentinel;
    emit SentinelUpdated(_sentinel);
  }

  function setPauseAll(bool _pauseAll) public {
    require(msg.sender == governance || msg.sender == sentinel, "BootstrapStakingPools: !(gov || sentinel)");
    pauseAll = _pauseAll;
    emit PauseAllUpdated(_pauseAll);
  }

  function setHarvestRewardCollector(address _harvestRewardCollector) external onlyGovernance {
    require(_harvestRewardCollector != address(0), "BootstrapStakingPools: harvestRewardCollector cannot be zero address");
    harvestRewardCollector = _harvestRewardCollector;
    emit HarvestRewardCollectorUpdated(_harvestRewardCollector);
  }
}
