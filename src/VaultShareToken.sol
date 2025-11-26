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

  /// @notice Accrued-but-not-yet-claimed token0 fees per user.
  mapping(address => uint256) public userAccruedToken0;

  /// @notice Accrued-but-not-yet-claimed token1 fees per user.
  mapping(address => uint256) public userAccruedToken1;

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

  function transfer(address _to, uint256 _value) public override returns (bool) {
    //
    return super.transfer(_to, _value);
  }

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
  /// @dev Intended to be called only from the inheriting contract.
  function _updateFees(uint256 _collectedFeeToken0, uint256 _collectedFeeToken1) internal {
    // Get total supply
    uint256 _supply = totalSupply();

    // No shares minted yet, so no fees to update
    if (_supply == 0) return;

    // Update the global cumulative fee index for token0.
    // `feeIndexToken0` represents "how much token0 each share has earned"
    // since the vault started.
    //
    // We scale first to avoid precision loss:
    //     delta = collectedFees * PRECISION / totalShares
    //
    // Rounding.Floor ensures that total distributed <= collected.
    // Any dust remains inside the vault (safe and intentional).
    if (_collectedFeeToken0 > 0) {
      feeIndexToken0 += Math.mulDiv(_collectedFeeToken0, PRECISION, _supply, Math.Rounding.Floor);
    }

    // Update the global cumulative fee index for token1
    // Same calculation for token1 fees:
    // - convert collected fees to per-share units via scaling
    // - no rewards are minted, only accounting updated
    // - FLOOR ensures we don’t over-distribute
    if (_collectedFeeToken1 > 0) {
      feeIndexToken1 += Math.mulDiv(_collectedFeeToken1, PRECISION, _supply, Math.Rounding.Floor);
    }

    emit FeeIndexesUpdated(feeIndexToken0, feeIndexToken1, _collectedFeeToken0, _collectedFeeToken1);
  }

  /// @notice Updates user's accrued (but not yet claimed) and user's fee indices.
  /// @param _user The address to update fees for.
  /// @dev
  ///   - Called before mint, burn, transfer and claim.
  ///   - Updates user's accrued (but not yet claimed) into `userAccruedToken0/1`.
  ///   - Updates user's fee indices to the current global indices.
  function _updateUserFees(address _user) internal {
    // 1. User's balance of VaultShares tokens
    uint256 _userBalance = balanceOf(_user);

    // 2. Current global fee indices
    uint256 _globalFeeIndex0 = feeIndexToken0;
    uint256 _globalFeeIndex1 = feeIndexToken1;

    // 3. User's last recorded fee indices
    uint256 _userFeeIndex0 = userFeeIndexToken0[_user];
    uint256 _userFeeIndex1 = userFeeIndexToken1[_user];

    // 4. If user has no shares, just sync checkpoints and exit
    if (_userBalance == 0) {
      if (_userFeeIndex0 != _globalFeeIndex0) userFeeIndexToken0[_user] = _globalFeeIndex0;
      if (_userFeeIndex1 != _globalFeeIndex1) userFeeIndexToken1[_user] = _globalFeeIndex1;
      return;
    }

    // 5. Update user's accrued fees for token0
    if (_globalFeeIndex0 > _userFeeIndex0) {
      uint256 _deltaIndex0 = _globalFeeIndex0 - _userFeeIndex0;
      userAccruedToken0[_user] += Math.mulDiv(_userBalance, _deltaIndex0, PRECISION);
    }

    // 6. Update user's accrued fees for token1
    if (_globalFeeIndex1 > _userFeeIndex1) {
      uint256 _deltaIndex1 = _globalFeeIndex1 - _userFeeIndex1;
      userAccruedToken1[_user] += Math.mulDiv(_userBalance, _deltaIndex1, PRECISION);
    }

    // 7. Update user checkpoints to the latest global indices
    if (_userFeeIndex0 != _globalFeeIndex0) userFeeIndexToken0[_user] = _globalFeeIndex0;
    if (_userFeeIndex1 != _globalFeeIndex1) userFeeIndexToken1[_user] = _globalFeeIndex1;
  }
}
