// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {VaultShareToken} from "src/VaultShareToken.sol";

/// @notice Mock of the VaultShareToken contract for testing.
contract VaultShareTokenHarness is VaultShareToken {
  constructor(string memory _name, string memory _symbol) VaultShareToken(_name, _symbol) {}

  /// @notice Exposes the internal _mint function for testing.
  /// @param _to The address to mint shares to.
  /// @param _amount The amount of shares to mint.
  function exposed_mint(address _to, uint256 _amount) external {
    _mint(_to, _amount);
  }

  /// @notice Exposes the internal _burn function for testing.
  /// @param _from The address to burn shares from.
  /// @param _amount The amount of shares to burn.
  function exposed_burn(address _from, uint256 _amount) external {
    _burn(_from, _amount);
  }

  /// @notice Exposes the internal _updateRewards function for testing.
  /// @param _collectedReward0 Amount of token0 rewards collected from the pool.
  /// @param _collectedReward1 Amount of token1 rewards collected from the pool.
  function exposed_updateRewards(uint256 _collectedReward0, uint256 _collectedReward1) external {
    _updateRewards(_collectedReward0, _collectedReward1);
  }

  /// @notice Exposes the internal _updateUserRewards function for testing.
  /// @param _user The address to update rewards for.
  function exposed_updateUserRewards(address _user) external {
    _updateUserRewards(_user);
  }
}
