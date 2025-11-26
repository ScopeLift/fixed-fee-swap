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
///  - Implements reward accounting via cumulative "reward-per-share" indexes.
///  - When new rewards are collected, the vault calls `_updateRewards`,
///    which increases the global indexes:
///         `index += rewards * PRECISION / totalSupply`
///
///  - Users accrue rewards lazily:
///         `accrued += balance * (index - userIndex) / PRECISION`
///    and their checkpoint `userIndex` is updated.
///
///  - This model ensures:
///     - Users only earn while they hold shares
///     - Reward distribution never loops over all holders
///     - Mint/burn/transfer are correctly compensated over time
contract VaultShareToken is ERC20 {
  /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice Global reward indexes for token0 and token1.
  RewardPerShareLib.GlobalRewardIndexes internal _rewardIndexes;

  /// @notice Tracks reward accounting data per user.
  mapping(address => RewardPerShareLib.UserRewards) public userRewards;

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

  /// @notice Global cumulative reward index for token0.
  function rewardIndex0() external view returns (uint256) {
    return _rewardIndexes.rewardIndex0;
  }

  /// @notice Global cumulative reward index for token1.
  function rewardIndex1() external view returns (uint256) {
    return _rewardIndexes.rewardIndex1;
  }

  /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc ERC20
  /// @dev Updates user reward accounting for both the sender and the recipient.
  function _update(address _from, address _to, uint256 _value) internal override {
    if (_from != address(0)) _updateUserRewards(_from);
    if (_to != address(0)) _updateUserRewards(_to);
    super._update(_from, _to, _value);
  }

  /// @notice Updates the reward indexes for token0 and token1.
  /// @param _collectedReward0 Newly collected token0 rewards collected from the pool (delta since
  /// last call). @param _collectedReward1 Newly collected token1 rewards collected from the pool
  /// (delta since last call).
  /// @dev Intended to be called only from the inheriting vault.
  function _updateRewards(uint256 _collectedReward0, uint256 _collectedReward1) internal {
    RewardPerShareLib._updateRewards(
      _rewardIndexes, _collectedReward0, _collectedReward1, totalSupply()
    );
  }

  /// @notice Updates user's accrued (but not yet claimed) and user's reward indices.
  /// @param _user The address to update rewards for.
  /// @dev
  ///   - Should be called before mint, burn, transfer and claim.
  ///   - Accrues newly earned rewards into `userRewards[_user].accruedReward0/1`.
  ///   - Updates `userRewards[_user].rewardIndex0/1` to the current global indices.
  function _updateUserRewards(address _user) internal {
    RewardPerShareLib._updateUserRewards(userRewards[_user], _rewardIndexes, balanceOf(_user));
  }
}
