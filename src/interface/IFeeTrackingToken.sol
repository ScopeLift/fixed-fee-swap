// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IFeeTrackingToken
/// @author [ScopeLift](https://scopelift.co)
/// @notice Interface for tokens that track and distribute fees using cumulative fee indexes.
/// @dev This interface abstracts the common fee tracking functionality shared by
///      VaultShareToken and YieldToken contracts.
interface IFeeTrackingToken {
  /*//////////////////////////////////////////////////////////////
                          EVENTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Emitted when the global cumulative fee index for token0 and token1 are updated.
  /// @param newglobalFeeIndex0Scaled Updated global cumulative fee index for token0
  /// @param newglobalFeeIndex1Scaled Updated global cumulative fee index for token1
  /// @param collectedFeeToken0 Amount of token0 fees collected from the pool.
  /// @param collectedFeeToken1 Amount of token1 fees collected from the pool.
  event FeeIndexesUpdated(
    uint256 newglobalFeeIndex0Scaled,
    uint256 newglobalFeeIndex1Scaled,
    uint256 collectedFeeToken0,
    uint256 collectedFeeToken1
  );

  /// @notice Emitted when a user claims their accrued fees.
  /// @param user The address that claimed fees.
  /// @param token0Amount Amount of token0 fees claimed.
  /// @param token1Amount Amount of token1 fees claimed.
  event FeesClaimed(address indexed user, uint256 token0Amount, uint256 token1Amount);

  /*//////////////////////////////////////////////////////////////
                          FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Global cumulative fee index for token0.
  /// @dev
  ///   - Scaled by PRECISION.
  ///   - Increases whenever new token0 fees are distributed via `_updateFees`.
  ///   - Represents the total amount of token0 fees accrued per 1 share since vault inception.
  ///   - Used with `userFees[user].userFeeIndex0Scaled` to compute user-specific deltas.
  /// @return The global cumulative fee index for token0, scaled by PRECISION.
  function globalFeeIndex0Scaled() external view returns (uint256);

  /// @notice Global cumulative fee index for token1.
  /// @dev Same semantics as `globalFeeIndex0Scaled`, but for token1.
  /// @return The global cumulative fee index for token1, scaled by PRECISION.
  function globalFeeIndex1Scaled() external view returns (uint256);

  /// @notice Claims accrued (but not yet claimed) fees for a `_user`.
  /// @param _user Address whose accrued fees will be claimed.
  /// @return _claimedToken0 Amount of `FEE_TOKEN_0` transferred to `_user`.
  /// @return _claimedToken1 Amount of `FEE_TOKEN_1` transferred to `_user`.
  function claim(address _user) external returns (uint256 _claimedToken0, uint256 _claimedToken1);
}
