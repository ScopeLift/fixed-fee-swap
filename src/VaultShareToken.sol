// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// External imports
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Internal imports
import {RewardPerShareLib} from "src/lib/RewardPerShareLib.sol";

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
///     - Fee distribution never loops over all holders
///     - Mint/burn/transfer are correctly compensated over time
contract VaultShareToken is ERC20 {
  /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice Global cumulative fee indexes for token0 and token1.
  RewardPerShareLib.GlobalFeeIndexes internal globalFeeIndexes;

  /// @notice Tracks fee accounting data per user.
  mapping(address => RewardPerShareLib.UserFees) public userFees;

  /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /// @notice Initializes the Vault share token metadata.
  /// @param _name ERC20 name value.
  /// @param _symbol ERC20 symbol value.
  constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {}

  /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Updates user's accrued (but not yet claimed) and user's fee indices.
  /// @param _user The address to update fees for.
  /// @dev
  ///   - Accrues newly earned fees into `userFees[_user].userAccruedToken0/userAccruedToken1`.
  ///   - Updates `userFees[_user].userFeeIndex0Scaled/userFeeIndex1Scaled` to the current global
  /// indices.
  function updateUserFees(address _user) external {
    _updateUserFees(_user);
  }

  /// @notice Global cumulative fee index for token0.
  function globalFeeIndex0Scaled() external view returns (uint256) {
    return globalFeeIndexes.globalFeeIndex0Scaled;
  }

  /// @notice Global cumulative fee index for token1.
  function globalFeeIndex1Scaled() external view returns (uint256) {
    return globalFeeIndexes.globalFeeIndex1Scaled;
  }

  /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc ERC20
  /// @dev Updates user fee accounting for both the sender and the recipient.
  function _update(address _from, address _to, uint256 _value) internal override {
    if (_from != address(0)) _updateUserFees(_from);
    if (_to != address(0)) _updateUserFees(_to);
    super._update(_from, _to, _value);
  }

  /// @notice Updates the fee indexes for token0 and token1.
  /// @param _collectedFeeToken0 Newly collected token0 fees collected from the pool (delta since
  /// last call).
  /// @param _collectedFeeToken1 Newly collected token1 fees collected from the pool (delta since
  /// (delta since last call).
  /// @dev Intended to be called only from the inheriting contract.
  function _updateFees(uint256 _collectedFeeToken0, uint256 _collectedFeeToken1) internal {
    RewardPerShareLib._updateFees(
      globalFeeIndexes, _collectedFeeToken0, _collectedFeeToken1, totalSupply()
    );
  }

  /// @notice Updates user's accrued (but not yet claimed) and user's fee indices.
  /// @param _user The address to update fees for.
  /// @dev
  ///   - Should be called before mint, burn, transfer and claim.
  ///   - Accrues newly earned fees into `userFees[_user].userAccruedToken0/userAccruedToken1`.
  ///   - Updates `userFees[_user].userFeeIndex0Scaled/userFeeIndex1Scaled` to the current global
  /// indices.
  function _updateUserFees(address _user) internal {
    RewardPerShareLib._updateUserFees(userFees[_user], globalFeeIndexes, balanceOf(_user));
  }
}
