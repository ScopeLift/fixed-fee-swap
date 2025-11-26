// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RewardPerShareLib
/// @author [ScopeLift](https://scopelift.co)
/// @notice Library providing dual-token fee checkpointing functionality.
/// @dev
///  - Implements cumulative "fee-per-share" indexes for two tokens.
///  - When new fees are collected, call `updateFees`,
///    which increases the global indexes: `index += fees * PRECISION / totalSupply`
///
///  - Users accrue fees lazily:
///         `accrued += balance * (index - userIndex) / PRECISION`
///    and their checkpoint `userIndex` is updated.
///
///  - This model ensures:
///     - Users only earn while they hold shares
///     - Fee distribution never loops over all holders
///     - Mint/burn/transfer are correctly compensated over time
library RewardPerShareLib {
  /// @notice Precision for the fee accumulators (to prevent precision loss).
  uint256 public constant PRECISION = 1e18;

  /*//////////////////////////////////////////////////////////////
                          STRUCTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Per-user fee accounting state.
  /// @dev
  ///  - `feeIndexToken{0,1}` are the user's last synced fee indices (checkpoints).
  ///  - `accruedToken{0,1}` are earned-but-not-yet-claimed fee amounts.
  struct UserFees {
    /// @notice Last fee-per-share index for token0 the user has synced to.
    uint256 feeIndexToken0;
    /// @notice Last fee-per-share index for token1 the user has synced to.
    uint256 feeIndexToken1;
    /// @notice Accrued (but not yet claimed) fees for token0.
    uint256 accruedToken0;
    /// @notice Accrued (but not yet claimed) fees for token1.
    uint256 accruedToken1;
  }

  /// @notice Global fee index state.
  struct GlobalFeeIndexes {
    /// @notice Global cumulative fee index for token0.
    uint256 feeIndexToken0;
    /// @notice Global cumulative fee index for token1.
    uint256 feeIndexToken1;
  }

  /*//////////////////////////////////////////////////////////////
                          EVENTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Emitted when the global cumulative fee index for token0 and token1 are updated.
  /// @param newFeeIndexToken0 Updated global cumulative fee index for token0 (with PRECISION).
  /// @param newFeeIndexToken1 Updated global cumulative fee index for token1 (with PRECISION).
  /// @param collectedFeeToken0 Amount of token0 fees collected.
  /// @param collectedFeeToken1 Amount of token1 fees collected.
  event FeeIndexesUpdated(
    uint256 newFeeIndexToken0,
    uint256 newFeeIndexToken1,
    uint256 collectedFeeToken0,
    uint256 collectedFeeToken1
  );

  /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Updates the fee indexes for token0 and token1.
  /// @param _feeIndexes Storage pointer to global fee indexes.
  /// @param _collectedFeeToken0 Newly collected token0 fees (delta since last call).
  /// @param _collectedFeeToken1 Newly collected token1 fees (delta since last call).
  /// @param _totalSupply Total supply of shares for fee distribution.
  function _updateFees(
    GlobalFeeIndexes storage _feeIndexes,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1,
    uint256 _totalSupply
  ) internal {
    // No shares minted yet, so no fees to update
    if (_totalSupply == 0) return;

    // Update the global cumulative fee index for token0.
    // `feeIndexToken0` represents "how much token0 each share has earned"
    // since the vault started.
    //
    // We scale first to avoid precision loss:
    //     delta = collectedFees * PRECISION / totalShares
    //
    // Rounding.Floor ensures that total distributed <= collected.
    // Any dust remains inside the vault (safe and intentional).
    if (_collectedFeeToken0 > 0) {
      _feeIndexes.feeIndexToken0 += Math.mulDiv(_collectedFeeToken0, PRECISION, _totalSupply, Math.Rounding.Floor);
    }

    // Update the global cumulative fee index for token1
    // Same calculation for token1 fees:
    // - convert collected fees to per-share units via scaling
    // - no rewards are minted, only accounting updated
    // - FLOOR ensures we don’t over-distribute
    if (_collectedFeeToken1 > 0) {
      _feeIndexes.feeIndexToken1 += Math.mulDiv(_collectedFeeToken1, PRECISION, _totalSupply, Math.Rounding.Floor);
    }

    emit FeeIndexesUpdated(
      _feeIndexes.feeIndexToken0,
      _feeIndexes.feeIndexToken1,
      _collectedFeeToken0,
      _collectedFeeToken1
    );
  }

  /// @notice Updates user's accrued (but not yet claimed) and user's fee indices.
  /// @param _userFees Storage pointer to user's fee accounting state.
  /// @param _feeIndexes Storage pointer to global fee indexes.
  /// @param _userBalance User's current balance of shares.
  function _updateUserFees(
    UserFees storage _userFees,
    GlobalFeeIndexes storage _feeIndexes,
    uint256 _userBalance
  ) internal {
    // 1. Current global fee indices
    uint256 _globalFeeIndex0 = _feeIndexes.feeIndexToken0;
    uint256 _globalFeeIndex1 = _feeIndexes.feeIndexToken1;

    // 2. User's last recorded fee indices
    uint256 _userFeeIndex0 = _userFees.feeIndexToken0;
    uint256 _userFeeIndex1 = _userFees.feeIndexToken1;

    // 3. If user has no shares, they cannot earn new fees going forward.
    // Just sync their fee indices so they don't retro-earn when they
    // receive shares in the future.
    if (_userBalance == 0) {
      if (_userFeeIndex0 != _globalFeeIndex0) _userFees.feeIndexToken0 = _globalFeeIndex0;
      if (_userFeeIndex1 != _globalFeeIndex1) _userFees.feeIndexToken1 = _globalFeeIndex1;
      return;
    }

    // 4. Accrue newly earned fees for token0
    if (_globalFeeIndex0 > _userFeeIndex0) {
      uint256 _deltaIndex0 = _globalFeeIndex0 - _userFeeIndex0;
      _userFees.accruedToken0 += Math.mulDiv(_userBalance, _deltaIndex0, PRECISION);
    }

    // 5. Accrue newly earned fees for token1
    if (_globalFeeIndex1 > _userFeeIndex1) {
      uint256 _deltaIndex1 = _globalFeeIndex1 - _userFeeIndex1;
      _userFees.accruedToken1 += Math.mulDiv(_userBalance, _deltaIndex1, PRECISION);
    }

    // 6. Update user checkpoints to the latest global indices
    if (_userFeeIndex0 != _globalFeeIndex0) _userFees.feeIndexToken0 = _globalFeeIndex0;
    if (_userFeeIndex1 != _globalFeeIndex1) _userFees.feeIndexToken1 = _globalFeeIndex1;
  }
}

