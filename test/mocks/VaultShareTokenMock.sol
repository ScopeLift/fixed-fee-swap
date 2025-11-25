// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {VaultShareToken} from "src/VaultShareToken.sol";

/// @notice Mock of the VaultShareToken contract for testing.
contract VaultShareTokenMock is VaultShareToken {
  constructor(string memory _name, string memory _symbol) VaultShareToken(_name, _symbol) {}

  /// @notice Exposes the internal _mintShares function for testing.
  function mintShares(address _to, uint256 _amount) external {
    _mintShares(_to, _amount);
  }

  /// @notice Exposes the internal _burnShares function for testing.
  function burnShares(address _from, uint256 _amount) external {
    _burnShares(_from, _amount);
  }
}
