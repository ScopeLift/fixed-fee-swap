// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// External imports
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title VaultShareToken
/// @author [ScopeLift](https://scopelift.co)
/// @notice Base ERC20 token representing shares in an LP Vault.
/// @dev This contract is meant to be inherited by the Vault.
contract VaultShareToken is ERC20 {
  /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /// @notice Initializes the Vault share token metadata.
  /// @param _name ERC20 name value.
  /// @param _symbol ERC20 symbol value.
  constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {}

  /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Mints new vault shares.
  /// @param _to The address to mint shares to.
  /// @param _amount The amount of shares to mint.
  /// @dev Intended to be called only from the inheriting vault.
  function _mintShares(address _to, uint256 _amount) internal {
    _mint(_to, _amount);
  }

  /// @notice Burns existing vault shares.
  /// @param _from The address to burn shares from.
  /// @param _amount The amount of shares to burn.
  /// @dev Intended to be called only from the inheriting vault.
  function _burnShares(address _from, uint256 _amount) internal {
    _burn(_from, _amount);
  }
}
