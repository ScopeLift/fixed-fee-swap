// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// External Imports
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20FlashMint} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20FlashMint.sol";

contract PrincipalToken is ERC20, ERC20FlashMint {
  /*//////////////////////////////////////////////////////////////
                        ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when the caller is not authorized.
  error PrincipalToken_NotAuthorized();

  /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice The fixed fee swap hook address.
  address public immutable FIXED_FEE_SWAP_HOOK;

  /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /// @notice Initializes the principal token metadata.
  /// @param _name ERC20 name value.
  /// @param _symbol ERC20 symbol value.
  /// @param _fixedFeeSwapHook The fixed fee swap hook address.
  constructor(string memory _name, string memory _symbol, address _fixedFeeSwapHook)
    ERC20(_name, _symbol)
  {
    FIXED_FEE_SWAP_HOOK = _fixedFeeSwapHook;
  }

  /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Mints tokens to an address.
  /// @param _to The address to mint tokens to.
  /// @param _amount The amount of tokens to mint.
  function mint(address _to, uint256 _amount) external {
    _requireHook();
    _mint(_to, _amount);
  }

  /// @notice Burns tokens from an address.
  /// @param _from The address to burn tokens from.
  /// @param _amount The amount of tokens to burn.
  function burn(address _from, uint256 _amount) external {
    _requireHook();
    _burn(_from, _amount);
  }

  /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Requires the caller to be the fixed fee swap hook.
  function _requireHook() internal view {
    if (msg.sender != FIXED_FEE_SWAP_HOOK) revert PrincipalToken_NotAuthorized();
  }
}
