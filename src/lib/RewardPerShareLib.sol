// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RewardPerShareLib
/// @author [ScopeLift](https://scopelift.co)
/// @notice Library providing dual-token reward checkpointing functionality.
/// @dev
///  - Implements cumulative "reward-per-share" indexes for two tokens.
///  - When new rewards are collected, call `_updateRewards`,
///    which increases the global indexes: `index += rewards * PRECISION / totalSupply`
///
///  - Users accrue rewards lazily:
///         `accrued += balance * (index - userIndex) / PRECISION`
///    and their checkpoint `userIndex` is updated.
///
///  - This model ensures:
///     - Users only earn while they hold shares
///     - Reward distribution never loops over all holders
///     - Mint/burn/transfer are correctly compensated over time
library RewardPerShareLib {
  /// @notice Precision for the reward accumulators (to prevent precision loss).
  uint256 public constant PRECISION = 1e18;

  /*//////////////////////////////////////////////////////////////
                          STRUCTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Per-user reward accounting state.
  /// @dev
  ///  - `rewardIndex{0,1}` are the user's last synced reward indices (checkpoints).
  ///  - `accruedReward{0,1}` are earned-but-not-yet-claimed reward amounts.
  struct UserRewards {
    /// @notice Last reward-per-share index for token0 the user has synced to.
    uint256 rewardIndex0;
    /// @notice Last reward-per-share index for token1 the user has synced to.
    uint256 rewardIndex1;
    /// @notice Accrued (but not yet claimed) rewards for token0.
    uint256 accruedReward0;
    /// @notice Accrued (but not yet claimed) rewards for token1.
    uint256 accruedReward1;
  }

  /// @notice Global reward index state.
  struct GlobalRewardIndexes {
    /// @notice Global cumulative reward index for token0.
    uint256 rewardIndex0;
    /// @notice Global cumulative reward index for token1.
    uint256 rewardIndex1;
  }

  /*//////////////////////////////////////////////////////////////
                          EVENTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Emitted when the global cumulative reward index for token0 and token1 are updated.
  /// @param newRewardIndex0 Updated global cumulative reward index for token0 (with PRECISION).
  /// @param newRewardIndex1 Updated global cumulative reward index for token1 (with PRECISION).
  /// @param collectedReward0 Amount of token0 rewards collected.
  /// @param collectedReward1 Amount of token1 rewards collected.
  event RewardIndexesUpdated(
    uint256 newRewardIndex0,
    uint256 newRewardIndex1,
    uint256 collectedReward0,
    uint256 collectedReward1
  );

  /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Updates the reward indexes for token0 and token1.
  /// @param _rewardIndexes Storage pointer to global reward indexes.
  /// @param _collectedReward0 Newly collected token0 rewards (delta since last call).
  /// @param _collectedReward1 Newly collected token1 rewards (delta since last call).
  /// @param _totalSupply Total supply of shares for reward distribution.
  function _updateRewards(
    GlobalRewardIndexes storage _rewardIndexes,
    uint256 _collectedReward0,
    uint256 _collectedReward1,
    uint256 _totalSupply
  ) internal {
    // No shares minted yet, so no rewards to update
    if (_totalSupply == 0) return;

    // Update the global cumulative reward index for token0.
    // `rewardIndex0` represents "how much token0 each share has earned"
    // since the vault started.
    //
    // We scale first to avoid precision loss:
    //     delta = collectedRewards * PRECISION / totalShares
    //
    // Rounding.Floor ensures that total distributed <= collected.
    // Any dust remains inside the vault (safe and intentional).
    if (_collectedReward0 > 0) {
      _rewardIndexes.rewardIndex0 += Math.mulDiv(
        _collectedReward0, PRECISION, _totalSupply, Math.Rounding.Floor
      );
    }

    // Update the global cumulative reward index for token1
    // Same calculation for token1 rewards:
    // - convert collected rewards to per-share units via scaling
    // - no rewards are minted, only accounting updated
    // - FLOOR ensures we don’t over-distribute
    if (_collectedReward1 > 0) {
      _rewardIndexes.rewardIndex1 += Math.mulDiv(
        _collectedReward1, PRECISION, _totalSupply, Math.Rounding.Floor
      );
    }

    emit RewardIndexesUpdated(
      _rewardIndexes.rewardIndex0, _rewardIndexes.rewardIndex1, _collectedReward0, _collectedReward1
    );
  }

  /// @notice Updates user's accrued (but not yet claimed) and user's reward indices.
  /// @param _userRewards Storage pointer to user's reward accounting state.
  /// @param _rewardIndexes Storage pointer to global reward indexes.
  /// @param _userBalance User's current balance of shares.
  function _updateUserRewards(
    UserRewards storage _userRewards,
    GlobalRewardIndexes storage _rewardIndexes,
    uint256 _userBalance
  ) internal {
    // 1. Current global reward indices
    uint256 _globalRewardIndex0 = _rewardIndexes.rewardIndex0;
    uint256 _globalRewardIndex1 = _rewardIndexes.rewardIndex1;

    // 2. User's last recorded reward indices
    uint256 _userRewardIndex0 = _userRewards.rewardIndex0;
    uint256 _userRewardIndex1 = _userRewards.rewardIndex1;

    // 3. If user has no shares, they cannot earn new rewards going forward.
    // Just sync their reward indices so they don't retro-earn when they
    // receive shares in the future.
    if (_userBalance == 0) {
      if (_userRewardIndex0 != _globalRewardIndex0) {
        _userRewards.rewardIndex0 = _globalRewardIndex0;
      }
      if (_userRewardIndex1 != _globalRewardIndex1) {
        _userRewards.rewardIndex1 = _globalRewardIndex1;
      }
      return;
    }

    // 4. Accrue newly earned rewards for token0
    if (_globalRewardIndex0 > _userRewardIndex0) {
      uint256 _deltaIndex0 = _globalRewardIndex0 - _userRewardIndex0;
      _userRewards.accruedReward0 += Math.mulDiv(_userBalance, _deltaIndex0, PRECISION);
    }

    // 5. Accrue newly earned rewards for token1
    if (_globalRewardIndex1 > _userRewardIndex1) {
      uint256 _deltaIndex1 = _globalRewardIndex1 - _userRewardIndex1;
      _userRewards.accruedReward1 += Math.mulDiv(_userBalance, _deltaIndex1, PRECISION);
    }

    // 6. Update user checkpoints to the latest global indices
    if (_userRewardIndex0 != _globalRewardIndex0) _userRewards.rewardIndex0 = _globalRewardIndex0;
    if (_userRewardIndex1 != _globalRewardIndex1) _userRewards.rewardIndex1 = _globalRewardIndex1;
  }
}

