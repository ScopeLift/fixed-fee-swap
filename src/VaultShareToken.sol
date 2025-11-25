// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// External imports
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title VaultShareToken
/// @author [ScopeLift](https://scopelift.co)
/// @notice Base ERC20 token representing shares in an LP Vault.
/// @dev This contract is meant to be inherited by the Vault.
contract VaultShareToken is ERC20 {
  /// @notice Precision for the fee accumulators (to prevent precision loss).
  uint256 public constant PRECISION = 1e18;

  /*//////////////////////////////////////////////////////////////
                          EVENTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Emitted when the global fee-per-share for token0 and token1 is updated.
  /// @param newFeePerShareToken0 Updated global fee-per-share index for token0 (with PRECISION)
  /// @param newFeePerShareToken1 Updated global fee-per-share index for token1 (with PRECISION)
  /// @param newToken0Fees Raw amount of token0 fees to add to the index.
  /// @param newToken1Fees Raw amount of token1 fees to add to the index.
  event FeePerShareUpdated(
    uint256 newFeePerShareToken0,
    uint256 newFeePerShareToken1,
    uint256 newToken0Fees,
    uint256 newToken1Fees
  );

  /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice Global fee-per-share accumulator for token0.
  /// @dev Scaled by PRECISION.
  ///      Every time new fees are distributed, this increases.
  ///      Used to compute each user's portion of collected fees.
  uint256 public feePerShareToken0;

  /// @notice Global fee-per-share accumulator for token1.
  /// @dev Works identical to `feePerShareToken0`, but for token1.
  uint256 public feePerShareToken1;

  /// @notice Per-account checkpoint of the token0 fee-per-share accumulator.
  /// @dev To calculate the user's portion of collected fees, we use the formula:
  ///      `(balanceOf(user) * (feePerShareToken0 - feePerShareCheckpointToken0 / PRECISION)`
  mapping(address => uint256) public feePerShareCheckpointToken0;

  /// @notice  Per-account checkpoint of the token1 fee-per-share accumulator.
  /// @dev Works identical to `feePerShareCheckpointToken0`, but for token1.
  mapping(address => uint256) public feePerShareCheckpointToken1;

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

  /// @notice Updates the fee indexes for token0 and token1.
  /// @param _newToken0Fees Raw amount of token0 fees to add to the index.
  /// @param _newToken1Fees Raw amount of token1 fees to add to the index.
  /// @dev Intended to be called only from the inheriting vault.
  function _updateFees(uint256 _newToken0Fees, uint256 _newToken1Fees) internal {
    // Get total supply
    uint256 _supply = totalSupply();

    // No shares minted yet, so no fees to update
    if (_supply == 0) return;

    // Update the global fee-per-share for token0
    if (_newToken0Fees > 0) feePerShareToken0 += (_newToken0Fees * PRECISION) / _supply;

    // Update the global fee-per-share for token1
    if (_newToken1Fees > 0) feePerShareToken1 += (_newToken1Fees * PRECISION) / _supply;

    emit FeePerShareUpdated(feePerShareToken0, feePerShareToken1, _newToken0Fees, _newToken1Fees);
  }
}
