// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Internal imports
import {FeeTracking} from "src/lib/FeeTracking.sol";
import {IFeeTrackingToken} from "src/interface/IFeeTrackingToken.sol";

/// @title VaultShareToken
/// @author [ScopeLift](https://scopelift.co)
/// @notice ERC20 representing proportional ownership of an LP vault.
/// @dev
///  - Implements fee accounting via cumulative "fee-per-share" indexes.
///  - When new fees are collected, the vault calls `_updateFees`,
///    which increases the global indexes:
///         `globalFeeIndexScaled += fees * PRECISION / totalSupply`
///
///  - Users accrue fees lazily:
///         `accrued += balance * (index - userIndex) / PRECISION`
///    and their checkpoint `userIndex` is updated.
///
///  - This model ensures:
///     - Users only earn while they hold shares
///     - Reward distribution never loops over all holders
///     - Mint/burn/transfer are correctly compensated over time
contract VaultShareToken is ERC20, IFeeTrackingToken {
  using FeeTracking for FeeTracking.GlobalFees;
  using FeeTracking for FeeTracking.UserFees;

  /*//////////////////////////////////////////////////////////////
                          ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when a transfer fails.
  error VaultShareToken_TransferFailed();

  /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice The token address in which token0 fees are collected / distributed.
  /// @dev Use address(0) to represent native ETH following Uniswap v4 `Currency` convention.
  address public immutable FEE_TOKEN0;

  /// @notice The token address in which token1 fees are collected / distributed.
  /// @dev Use address(0) to represent native ETH following Uniswap v4 `Currency` convention.
  address public immutable FEE_TOKEN1;

  /// @notice Global fee tracking state.
  FeeTracking.GlobalFees private globalFees;

  /// @notice Tracks fee accounting data per user.
  mapping(address => FeeTracking.UserFees) public userFees;

  /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /// @notice Initializes the Vault share token metadata.
  /// @param _name ERC20 name value.
  /// @param _symbol ERC20 symbol value.
  /// @param _feeToken0 The address of the token0 for which fees are being accrued for.
  /// @param _feeToken1 The address of the token1 for which fees are being accrued for.
  constructor(string memory _name, string memory _symbol, address _feeToken0, address _feeToken1)
    ERC20(_name, _symbol)
  {
    FEE_TOKEN0 = _feeToken0;
    FEE_TOKEN1 = _feeToken1;
  }

  /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Global cumulative fee index for token0.
  /// @dev
  ///   - Scaled by PRECISION.
  ///   - Increases whenever new token0 fees are distributed via `_updateFees`.
  ///   - Represents the total amount of token0 fees accrued per 1 share since vault inception.
  ///   - Used with `userFees[user].userFeeIndex0Scaled` to compute user-specific deltas.
  function globalFeeIndex0Scaled() external view returns (uint256) {
    return globalFees.globalFeeIndex0Scaled;
  }

  /// @notice Global cumulative fee index for token1.
  /// @dev Same semantics as `globalFeeIndex0Scaled`, but for token1.
  function globalFeeIndex1Scaled() external view returns (uint256) {
    return globalFees.globalFeeIndex1Scaled;
  }

  /// @notice Claims accrued (but not yet claimed) fees for a `_user`.
  /// @param _user Address whose accrued fees will be claimed.
  /// @return _claimedToken0 Amount of `FEE_TOKEN_0` transferred to `_user`.
  /// @return _claimedToken1 Amount of `FEE_TOKEN_1` transferred to `_user`.
  function claim(address _user) external returns (uint256 _claimedToken0, uint256 _claimedToken1) {
    (_claimedToken0, _claimedToken1) = _claim(_user);
  }

  /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc ERC20
  /// @dev Updates user fee accounting for both the sender and the recipient.
  function _update(address _from, address _to, uint256 _value) internal virtual override {
    if (_from != address(0)) _updateUserFees(_from);
    if (_to != address(0)) _updateUserFees(_to);
    ERC20._update(_from, _to, _value);
  }

  /// @notice Updates the fee indexes for token0 and token1.
  /// @param _collectedFeeToken0 Newly collected token0 fees collected from the pool (delta since
  /// last call).
  /// @param _collectedFeeToken1 Newly collected token1 fees collected from the pool (delta since
  /// last call).
  /// @dev Intended to be called only from the inheriting contract.
  function _updateFees(uint256 _collectedFeeToken0, uint256 _collectedFeeToken1) internal {
    globalFees._updateFees(_collectedFeeToken0, _collectedFeeToken1, totalSupply());

    // Emit event after updating fees
    emit FeeIndexesUpdated(
      globalFees.globalFeeIndex0Scaled,
      globalFees.globalFeeIndex1Scaled,
      _collectedFeeToken0,
      _collectedFeeToken1
    );
  }

  /// @notice Updates user's accrued (but not yet claimed) and user's fee indices.
  /// @param _user The address to update fees for.
  /// @dev See `FeeTracking._updateUserFees` for details.
  function _updateUserFees(address _user) internal {
    userFees[_user]._updateUserFees(
      balanceOf(_user), globalFees.globalFeeIndex0Scaled, globalFees.globalFeeIndex1Scaled
    );
  }

  /// @notice Claims accrued fees for a user after syncing to the latest global indices.
  /// @param _user The address to claim fees for.
  /// @return _claimedToken0 Amount of `FEE_TOKEN_0` that was transferred.
  /// @return _claimedToken1 Amount of `FEE_TOKEN_1` that was transferred.
  function _claim(address _user) internal returns (uint256 _claimedToken0, uint256 _claimedToken1) {
    // Update user fees to ensure we're syncing to the latest global indices
    _updateUserFees(_user);

    // Get the accrued amounts before resetting
    (_claimedToken0, _claimedToken1) = userFees[_user]._resetAccruedFees();

    // Emit event for transparency
    emit FeesClaimed(_user, _claimedToken0, _claimedToken1);

    // Transfer tokens to the user
    if (_claimedToken0 > 0) _transferAmount(FEE_TOKEN0, _user, _claimedToken0);
    if (_claimedToken1 > 0) _transferAmount(FEE_TOKEN1, _user, _claimedToken1);
  }

  /// @notice Transfers an amount of tokens to a user.
  /// @param _token The address of the token to transfer.
  /// @param _to The address to transfer the tokens to.
  /// @param _amount The amount of tokens to transfer.
  /// @dev Following Uniswap v4's convention: address(0) represents native ETH.
  ///      See: https://github.com/Uniswap/v4-core/blob/main/src/types/Currency.sol#L37-L38
  function _transferAmount(address _token, address _to, uint256 _amount) internal {
    if (_token == address(0)) {
      (bool _success,) = payable(_to).call{value: _amount}("");
      if (!_success) revert VaultShareToken_TransferFailed();
    } else {
      SafeERC20.safeTransfer(IERC20(_token), _to, _amount);
    }
  }
}
