// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// External imports
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title VaultShareToken
/// @author [ScopeLift](https://scopelift.co)
/// @notice ERC20 representing proportional ownership of an LP vault.
/// @dev
///  - Implements fee accounting via cumulative “fee-per-share” indexes.
///  - When new fees are collected, the vault calls `_updateFees`,
///    which increases the global indexes:
///         `index += fees * PRECISION / totalSupply`
///
///  - Users accrue fees lazily:
///         `accrued += balance * (index - userIndex) / PRECISION`
///    and their checkpoint `userIndex` is updated.
///
///  - This model ensures:
///     - Users only earn while they hold shares
///     - Reward distribution never loops over all holders
///     - Mint/burn/transfer are correctly compensated over time
contract VaultShareToken is ERC20 {
  /// @notice Precision for the fee accumulators (to prevent precision loss).
  uint256 public constant PRECISION = 1e18;

  /*//////////////////////////////////////////////////////////////
                          STRUCTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Per-user fee accounting state.
  /// @dev
  ///  - `feeIndexToken{0,1}` are the user's last synced fee indices (checkpoints).
  ///  - `accruedToken{0,1}` are earned-but-not-yet-claimed fee amounts.
  struct UserFees {
    /// @notice Last fee-per-share index for token0 the user has synced to.
    uint256 feeIndexToken0;
    /// @notice Last fee-per-share index for token1 the user has synced to.
    uint256 feeIndexToken1;
    /// @notice Accrued (but not yet claimed) fees for token0.
    uint256 accruedToken0;
    /// @notice Accrued (but not yet claimed) fees for token1.
    uint256 accruedToken1;
  }

  /*//////////////////////////////////////////////////////////////
                          EVENTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Emitted when the global cumulative fee index for token0 and token1 are updated.
  /// @param newFeeIndexToken0 Updated global cumulative fee index for token0 (with PRECISION).
  /// @param newFeeIndexToken1 Updated global cumulative fee index for token1 (with PRECISION).
  /// @param collectedFeeToken0 Amount of token0 fees collected from the pool.
  /// @param collectedFeeToken1 Amount of token1 fees collected from the pool.
  event FeeIndexesUpdated(
    uint256 newFeeIndexToken0,
    uint256 newFeeIndexToken1,
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
  ///   - Used with `userFees[user].feeIndexToken0` to compute user-specific deltas.
  uint256 public feeIndexToken0;

  /// @notice Global cumulative fee index for token1.
  /// @dev Same semantics as `feeIndexToken0`, but for token1.
  uint256 public feeIndexToken1;

  /// @notice Tracks fee accounting data per user.
  mapping(address => UserFees) public userFees;

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

  /// @inheritdoc ERC20
  /// @dev Updates user fee accounting for both the sender and the recipient.
  function _update(address _from, address _to, uint256 _value) internal override {
    if (_from != address(0)) _updateUserFees(_from);
    if (_to != address(0)) _updateUserFees(_to);
    super._update(_from, _to, _value);
  }

  /// @notice Updates the fee indexes for token0 and token1.
  /// @param _collectedFeeToken0 Newly collected token0 fees collected from the pool (delta since
  /// last call). @param _collectedFeeToken1 Newly collected token1 fees collected from the pool
  /// (delta since last call).
  /// @dev Intended to be called only from the inheriting vault.
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
  ///   - Should be called before mint, burn, transfer and claim.
  ///   - Accrues newly earned fees into `userFees[_user].accruedToken0/1`.
  ///   - Updates `userFees[_user].feeIndexToken0/1` to the current global indices.
  function _updateUserFees(address _user) internal {
    // 1. User's balance of VaultShares tokens
    uint256 _userBalance = balanceOf(_user);

    // 2. Current global fee indices
    uint256 _globalFeeIndex0 = feeIndexToken0;
    uint256 _globalFeeIndex1 = feeIndexToken1;

    // 3. User's last recorded fee indices
    UserFees storage account = userFees[_user];
    uint256 _userFeeIndex0 = account.feeIndexToken0;
    uint256 _userFeeIndex1 = account.feeIndexToken1;

    // 4. If user has no shares, they cannot earn new fees going forward.
    // Just sync their fee indices so they don't retro-earn when they
    // receive shares in the future.
    if (_userBalance == 0) {
      if (_userFeeIndex0 != _globalFeeIndex0) account.feeIndexToken0 = _globalFeeIndex0;
      if (_userFeeIndex1 != _globalFeeIndex1) account.feeIndexToken1 = _globalFeeIndex1;
      return;
    }

    // 5. Accrue newly earned fees for token0
    if (_globalFeeIndex0 > _userFeeIndex0) {
      uint256 _deltaIndex0 = _globalFeeIndex0 - _userFeeIndex0;
      account.accruedToken0 += Math.mulDiv(_userBalance, _deltaIndex0, PRECISION);
    }

    // 6. Accrue newly earned fees for token1
    if (_globalFeeIndex1 > _userFeeIndex1) {
      uint256 _deltaIndex1 = _globalFeeIndex1 - _userFeeIndex1;
      account.accruedToken1 += Math.mulDiv(_userBalance, _deltaIndex1, PRECISION);
    }

    // 7. Update user checkpoints to the latest global indices
    if (_userFeeIndex0 != _globalFeeIndex0) account.feeIndexToken0 = _globalFeeIndex0;
    if (_userFeeIndex1 != _globalFeeIndex1) account.feeIndexToken1 = _globalFeeIndex1;
  }
}
