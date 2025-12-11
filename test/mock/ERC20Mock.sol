// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title ERC20Mock
/// @notice A mock ERC20 token for testing purposes.
/// @dev Provides minting functionality for test scenarios.
contract ERC20Mock is ERC20 {
  /// @notice Creates a new mock ERC20 token.
  /// @param _name The name of the token.
  /// @param _symbol The symbol of the token.
  constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {}

  /// @notice Mints tokens to a specified address.
  /// @param _to The address to mint tokens to.
  /// @param _amount The amount of tokens to mint.
  /// @dev This function is public for testing purposes and allows anyone to mint.
  function mint(address _to, uint256 _amount) external {
    _mint(_to, _amount);
  }

  /// @notice Burns tokens from a specified address.
  /// @param _from The address to burn tokens from.
  /// @param _amount The amount of tokens to burn.
  /// @dev This function is public for testing purposes.
  function burn(address _from, uint256 _amount) external {
    _burn(_from, _amount);
  }
}

