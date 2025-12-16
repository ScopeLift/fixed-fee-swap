// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FeeTracking
/// @author [ScopeLift](https://scopelift.co)
/// @notice Fee accounting library for pro-rata distribution of collected fees to token holders.
/// @dev Implements a cumulative “fee-per-share” index (a.k.a. reward index) model:
///  - Global fee indexes track the total fees earned per share over time.
///  - Each user stores a checkpoint of the last index they synced to.
///  - User earnings are accrued lazily on interaction (mint, burn, transfer, claim),
///    avoiding any iteration over holders.
///
/// This design guarantees:
///  - O(1) fee accounting per operation
///  - No over-distribution (rounding always favors the system)
///  - Correct proportional rewards based on share ownership at sync time
///
/// The library is token-agnostic and can be reused by multiple ERC20-like
/// accounting tokens (e.g. VaultShareToken, YieldToken) that need
/// deterministic, gas-efficient fee distribution.
library FeeTracking {
  /// @notice Precision for the fee accumulators (to prevent precision loss).
  uint256 public constant PRECISION = 1e18;

  /*//////////////////////////////////////////////////////////////
                          STRUCTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Per-user fee accounting state.
  /// @dev
  ///  - `userFeeIndex0Scaled` and `userFeeIndex1Scaled` are the user's last synced fee indices
  /// (checkpoints).
  ///  - `userAccruedToken0` and `userAccruedToken1` are earned-but-not-yet-claimed fee amounts.
  struct UserFees {
    /// @notice Last fee-per-share index for token0 the user has synced to.
    uint256 userFeeIndex0Scaled;
    /// @notice Last fee-per-share index for token1 the user has synced to.
    uint256 userFeeIndex1Scaled;
    /// @notice Accrued (but not yet claimed) fees for token0.
    uint256 userAccruedToken0;
    /// @notice Accrued (but not yet claimed) fees for token1.
    uint256 userAccruedToken1;
  }

  /// @notice Global fee tracking state.
  struct GlobalFees {
    /// @notice Global cumulative fee index for token0 (scaled by PRECISION).
    uint256 globalFeeIndex0Scaled;
    /// @notice Global cumulative fee index for token1 (scaled by PRECISION).
    uint256 globalFeeIndex1Scaled;
  }

  /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Updates the global fee indexes when new fees are collected.
  /// @param _globalFees Storage reference to global fee state.
  /// @param _collectedFeeToken0 Newly collected token0 fees (delta since last call).
  /// @param _collectedFeeToken1 Newly collected token1 fees (delta since last call).
  /// @param _totalSupply Current total supply of tokens.
  /// @dev
  ///  - Updates the global cumulative fee index for token0 and token1.
  ///  - `globalFeeIndexScaled` represents "how much token each share has earned" since inception.
  ///  - We scale first to avoid precision loss: delta = collectedFees * PRECISION / totalShares
  ///  - Rounding.Floor ensures that total distributed <= collected. Any dust remains (safe).
  function _updateFees(
    GlobalFees storage _globalFees,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1,
    uint256 _totalSupply
  ) internal {
    // No shares minted yet, so no fees to update
    if (_totalSupply == 0) return;

    // Update the global cumulative fee index for token0.
    // `globalFeeIndex0Scaled` represents "how much token0 each share has earned"
    // since the vault started.
    //
    // We scale first to avoid precision loss:
    //     delta = collectedFees * PRECISION / totalShares
    //
    // Rounding.Floor ensures that total distributed <= collected.
    // Any dust remains inside the vault (safe and intentional).
    if (_collectedFeeToken0 > 0) {
      _globalFees.globalFeeIndex0Scaled += Math.mulDiv(
        _collectedFeeToken0, PRECISION, _totalSupply, Math.Rounding.Floor
      );
    }

    // Update the global cumulative fee index for token1
    // Same calculation for token1 fees:
    // - convert collected fees to per-share units via scaling
    // - no rewards are minted, only accounting updated
    // - FLOOR ensures we don't over-distribute
    if (_collectedFeeToken1 > 0) {
      _globalFees.globalFeeIndex1Scaled += Math.mulDiv(
        _collectedFeeToken1, PRECISION, _totalSupply, Math.Rounding.Floor
      );
    }
  }

  /// @notice Updates a user's accrued fees based on their current balance.
  /// @param _userFees Storage reference to user's fee state.
  /// @param _userBalance Current balance of the user.
  /// @param _globalIndex0 Current global fee index for token0.
  /// @param _globalIndex1 Current global fee index for token1.
  /// @dev
  ///  - Should be called before mint, burn, transfer and claim.
  ///  - Accrues newly earned fees into `_userFees.userAccruedToken0/_userFees.userAccruedToken1`.
  ///  - Updates `_userFees.userFeeIndex0Scaled/_userFees.userFeeIndex1Scaled` to the current global
  ///    indices.
  ///  - If user has no balance, syncs their indices so they don't retro-earn when they
  ///    receive tokens in the future.
  function _updateUserFees(
    UserFees storage _userFees,
    uint256 _userBalance,
    uint256 _globalIndex0,
    uint256 _globalIndex1
  ) internal {
    // If user has no shares, they cannot earn new fees going forward.
    // Just sync their fee indices so they don't retro-earn when they
    // receive shares in the future.
    if (_userBalance == 0) {
      if (_userFees.userFeeIndex0Scaled != _globalIndex0) {
        _userFees.userFeeIndex0Scaled = _globalIndex0;
      }
      if (_userFees.userFeeIndex1Scaled != _globalIndex1) {
        _userFees.userFeeIndex1Scaled = _globalIndex1;
      }
      return;
    }

    // Accrue newly earned fees for token0
    if (_globalIndex0 > _userFees.userFeeIndex0Scaled) {
      uint256 _deltaIndex0 = _globalIndex0 - _userFees.userFeeIndex0Scaled;
      _userFees.userAccruedToken0 += Math.mulDiv(_userBalance, _deltaIndex0, PRECISION);
      _userFees.userFeeIndex0Scaled = _globalIndex0;
    }

    // Accrue newly earned fees for token1
    if (_globalIndex1 > _userFees.userFeeIndex1Scaled) {
      uint256 _deltaIndex1 = _globalIndex1 - _userFees.userFeeIndex1Scaled;
      _userFees.userAccruedToken1 += Math.mulDiv(_userBalance, _deltaIndex1, PRECISION);
      _userFees.userFeeIndex1Scaled = _globalIndex1;
    }
  }

  /// @notice Resets the user's accrued fees to zero and returns the amounts.
  /// @param _userFees Storage reference to user's fee state.
  /// @return token0Amount Accrued token0 fees before reset.
  /// @return token1Amount Accrued token1 fees before reset.
  function _resetAccruedFees(UserFees storage _userFees)
    internal
    returns (uint256 token0Amount, uint256 token1Amount)
  {
    token0Amount = _userFees.userAccruedToken0;
    token1Amount = _userFees.userAccruedToken1;
    _userFees.userAccruedToken0 = 0;
    _userFees.userAccruedToken1 = 0;
  }
}
