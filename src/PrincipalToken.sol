// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "lib/uniswap-hooks/lib/v4-periphery/lib/permit2/lib/solmate/src/tokens/ERC20.sol";

/// @title PrincipalToken
/// @notice ERC20 token representing principal in the fixed fee swap system
contract PrincipalToken is ERC20 {
  address public immutable hook;

  modifier onlyHook() {
    require(msg.sender == hook, "Only hook can call");
    _;
  }

  constructor(string memory _name, string memory _symbol, address _hook) ERC20(_name, _symbol, 18) {
    hook = _hook;
  }

  /// @notice Mint tokens to an address
  /// @param to Recipient address
  /// @param amount Amount to mint
  function mint(address to, uint256 amount) external onlyHook {
    _mint(to, amount);
  }

  /// @notice Burn tokens from an address
  /// @param from Address to burn from
  /// @param amount Amount to burn
  function burnFrom(address from, uint256 amount) external onlyHook {
    _burn(from, amount);
  }
}