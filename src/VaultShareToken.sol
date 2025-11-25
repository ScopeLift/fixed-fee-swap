// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// External imports
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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

  /// @notice Emitted when the global cumulative fee index for token0 and token1 are updated.
  /// @param feeIndexToken0 Updated global cumulative fee index for token0 (with PRECISION).
  /// @param feeIndexToken1 Updated global cumulative fee index for token1 (with PRECISION).
  /// @param collectedFeeToken0 Amount of token0 fees collected from the pool.
  /// @param collectedFeeToken1 Amount of token1 fees collected from the pool.
  event FeeIndexesUpdated(
    uint256 feeIndexToken0,
    uint256 feeIndexToken1,
    uint256 collectedFeeToken0,
    uint256 collectedFeeToken1
  );

  /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice Global cumulative fee index for token0.
  /// @dev
  ///   - Scaled by PRECISION.
  ///   - Increases whenever new token0 fees are distributed via `_updateFees`.
  ///   - Represents the total amount of token0 fees accrued per 1 share since vault inception.
  ///   - Used together with `userFeeIndexToken0[user]` to compute a user's pending token0 fees.
  uint256 public feeIndexToken0;

  /// @notice Global cumulative fee index for token1.
  /// @dev Same semantics as `feeIndexToken0`, but for token1.
  uint256 public feeIndexToken1;

  /// @notice User checkpoint of the token0 fee index.
  /// @dev To calculate the user's portion of collected fees, we use the formula:
  ///      `(balanceOf(user) * (feeIndexToken0 - userFeeIndexToken0 / PRECISION)`
  mapping(address => uint256) public userFeeIndexToken0;

  /// @notice User checkpoint of the token1 fee index.
  /// @dev Same semantics as `userFeeIndexToken0`, but for token1.
  mapping(address => uint256) public userFeeIndexToken1;

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
  /// @param _collectedFeeToken0 Amount of token0 fees collected from the pool.
  /// @param _collectedFeeToken1 Amount of token1 fees collected from the pool.
  /// @dev Intended to be called only from the inheriting vault.
  function _updateFees(uint256 _collectedFeeToken0, uint256 _collectedFeeToken1) internal {
    // Get total supply
    uint256 _supply = totalSupply();

    // No shares minted yet, so no fees to update
    if (_supply == 0) return;

    // Update the global cumulative fee index for token0
    if (_collectedFeeToken0 > 0) {
      feeIndexToken0 += Math.mulDiv(_collectedFeeToken0, PRECISION, _supply);
    }

    // Update the global cumulative fee index for token1
    if (_collectedFeeToken1 > 0) {
      feeIndexToken1 += Math.mulDiv(_collectedFeeToken1, PRECISION, _supply);
    }

    emit FeeIndexesUpdated(feeIndexToken0, feeIndexToken1, _collectedFeeToken0, _collectedFeeToken1);
  }
}
