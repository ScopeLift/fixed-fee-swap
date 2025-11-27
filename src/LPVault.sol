// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

/// @title LPVault
/// @author [ScopeLift](https://scopelift.co)
/// @notice A contract that wraps a set of static LP positions in a single Uniswap v4 pool.
/// @dev Positions and their weight distributions are fixed at contract creation.
contract LPVault {
  using PoolIdLibrary for PoolKey;

  /// @notice Structure for liquidity position configuration.
  struct LiquidityPosition {
    int24 tickLower;
    int24 tickUpper;
    uint256 weight; // Weight in basis points (BIPs)
  }

  /// @notice Total weight must equal 10,000 BIPs (100%).
  uint256 public constant TOTAL_WEIGHT = 10_000;

  /// @notice The Uniswap v4 PoolManager.
  IPoolManager public immutable POOL_MANAGER;

  /// @notice The token0 in the target pool.
  address public immutable TOKEN0;

  /// @notice The token1 in the target pool.
  address public immutable TOKEN1;

  /// @notice The target pool that this vault manages liquidity for.
  PoolKey public targetPoolKey;

  /// @notice The predefined liquidity positions for this vault.
  LiquidityPosition[] public positions;

  /// @notice Custom errors.
  error LPVault__InvalidLiquidityDistribution();
  error LPVault__InvalidTickRange();
  error LPVault__NoPositions();

  /// @notice Creates a new LP Vault with fixed positions.
  /// @param _poolManager The Uniswap v4 pool manager.
  /// @param _targetPoolKey The pool to provide liquidity to.
  /// @param _positions Array of positions with tick ranges and weights (must sum to 10,000 BIPs).
  constructor(
    IPoolManager _poolManager,
    PoolKey memory _targetPoolKey,
    LiquidityPosition[] memory _positions
  ) {
    POOL_MANAGER = _poolManager;
    targetPoolKey = _targetPoolKey;
    TOKEN0 = Currency.unwrap(_targetPoolKey.currency0);
    TOKEN1 = Currency.unwrap(_targetPoolKey.currency1);
    _initializePositions(_positions);
  }

  /// @notice Initializes and validates the liquidity positions for the vault.
  /// @dev Validates that positions have valid tick ranges and weights sum to TOTAL_WEIGHT.
  /// @param _positions Array of liquidity positions to initialize.
  function _initializePositions(LiquidityPosition[] memory _positions) internal virtual {
    // Ensure at least one position is provided.
    if (_positions.length == 0) revert LPVault__NoPositions();

    // Validate positions and calculate total weight.
    uint256 _totalWeight = 0;
    for (uint256 _i = 0; _i < _positions.length; _i++) {
      if (_positions[_i].tickLower >= _positions[_i].tickUpper) {
        revert LPVault__InvalidTickRange();
      }
      positions.push(_positions[_i]);
      _totalWeight += _positions[_i].weight;
    }

    // Ensure weights sum to exactly 100% (10,000 BIPs).
    if (_totalWeight != TOTAL_WEIGHT) revert LPVault__InvalidLiquidityDistribution();
  }
}

