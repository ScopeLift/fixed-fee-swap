// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// External imports
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title VaultShareToken
/// @author [ScopeLift](https://scopelift.co)
/// @notice ERC20 representing proportional ownership of an LP vault.
/// @dev
///  - Implements fee accounting via cumulative “fee-per-share” indexes.
///  - When new fees are collected, the vault calls `_updateFees`,
///    which increases the global indexes:
///         `globalFeeIndexScaled += fees * PRECISION / totalSupply`
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
  ///  - `userFeeIndex0Scaled` and `userFeeIndex1Scaled` are the user's last synced fee indices
  /// (checkpoints). - `userAccruedToken0` and `userAccruedToken1` are earned-but-not-yet-claimed
  /// fee amounts.
  struct UserFees {
    /// @notice Last fee-per-share index for token0 the user has synced to.
    uint256 userFeeIndex0Scaled;
    /// @notice Last fee-per-share index for token1 the user has synced to.
    uint256 userFeeIndex1Scaled;
    /// @notice Accrued (but not yet claimed) fees for token0.
    uint256 userAccruedToken0;
    /// @notice Accrued (but not yet claimed) fees for token1.
    uint256 userAccruedToken1;
  }

  /*//////////////////////////////////////////////////////////////
                          ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when a transfer fails.
  error VaultShareToken_TransferFailed();

  /*//////////////////////////////////////////////////////////////
                          EVENTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Emitted when the global cumulative fee index for token0 and token1 are updated.
  /// @param newglobalFeeIndex0Scaled Updated global cumulative fee index for token0 (with
  /// PRECISION). @param newglobalFeeIndex1Scaled Updated global cumulative fee index for token1
  /// (with PRECISION).
  /// @param collectedFeeToken0 Amount of token0 fees collected from the pool.
  /// @param collectedFeeToken1 Amount of token1 fees collected from the pool.
  event FeeIndexesUpdated(
    uint256 newglobalFeeIndex0Scaled,
    uint256 newglobalFeeIndex1Scaled,
    uint256 collectedFeeToken0,
    uint256 collectedFeeToken1
  );

  /// @notice Emitted when a user claims their accrued fees.
  /// @param user The address that claimed fees.
  /// @param token0 The address of the token0 to claim fees for.
  /// @param token1 The address of the token1 to claim fees for.
  /// @param token0Amount Amount of token0 fees claimed.
  /// @param token1Amount Amount of token1 fees claimed.
  event FeesClaimed(
    address indexed user,
    address indexed token0,
    address indexed token1,
    uint256 token0Amount,
    uint256 token1Amount
  );

  /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice The token address in which token0 fees are collected / distributed.
  /// @dev Use address(0) to represent native ETH following Uniswap v4 `Currency` convention.
  address public immutable FEE_TOKEN0;

  /// @notice The token address in which token1 fees are collected / distributed.
  /// @dev Use address(0) to represent native ETH following Uniswap v4 `Currency` convention.
  address public immutable FEE_TOKEN1;

  /// @notice Global cumulative fee index for token0.
  /// @dev
  ///   - Scaled by PRECISION.
  ///   - Increases whenever new token0 fees are distributed via `_updateFees`.
  ///   - Represents the total amount of token0 fees accrued per 1 share since vault inception.
  ///   - Used with `userFees[user].userFeeIndex0Scaled` to compute user-specific deltas.
  uint256 public globalFeeIndex0Scaled;

  /// @notice Global cumulative fee index for token1.
  /// @dev Same semantics as `globalFeeIndex0Scaled`, but for token1.
  uint256 public globalFeeIndex1Scaled;

  /// @notice Tracks fee accounting data per user.
  mapping(address => UserFees) public userFees;

  /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /// @notice Initializes the Vault share token metadata.
  /// @param _name ERC20 name value.
  /// @param _symbol ERC20 symbol value.
  /// @param _feeToken0 The address of the token0 for which fees are being accrued for.
  /// @param _feeToken1 The address of the token1 for which fees are being accrued for.
  constructor(string memory _name, string memory _symbol, address _feeToken0, address _feeToken1)
    ERC20(_name, _symbol)
  {
    FEE_TOKEN0 = _feeToken0;
    FEE_TOKEN1 = _feeToken1;
  }

  /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Claims accrued (but not yet claimed) fees for a `_user`.
  /// @param _user Address whose accrued fees will be claimed.
  /// @return _claimedToken0 Amount of FEE_TOKEN_0 transferred to `_user`.
  /// @return _claimedToken1 Amount of FEE_TOKEN_1 transferred to `_user`.
  function claim(address _user) external returns (uint256 _claimedToken0, uint256 _claimedToken1) {
    (_claimedToken0, _claimedToken1) = _claim(_user);
  }

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
  /// last call).
  /// @param _collectedFeeToken1 Newly collected token1 fees collected from the pool (delta since
  /// (delta since last call).
  /// @dev Intended to be called only from the inheriting contract.
  function _updateFees(uint256 _collectedFeeToken0, uint256 _collectedFeeToken1) internal {
    // Get total supply
    uint256 _supply = totalSupply();

    // No shares minted yet, so no fees to update
    if (_supply == 0) return;

    // Update the global cumulative fee index for token0.
    // `globalFeeIndex0Scaled` represents "how much token0 each share has earned"
    // since the vault started.
    //
    // We scale first to avoid precision loss:
    //     delta = collectedFees * PRECISION / totalShares
    //
    // Rounding.Floor ensures that total distributed <= collected.
    // Any dust remains inside the vault (safe and intentional).
    if (_collectedFeeToken0 > 0) {
      globalFeeIndex0Scaled += Math.mulDiv(
        _collectedFeeToken0, PRECISION, _supply, Math.Rounding.Floor
      );
    }

    // Update the global cumulative fee index for token1
    // Same calculation for token1 fees:
    // - convert collected fees to per-share units via scaling
    // - no rewards are minted, only accounting updated
    // - FLOOR ensures we don’t over-distribute
    if (_collectedFeeToken1 > 0) {
      globalFeeIndex1Scaled += Math.mulDiv(
        _collectedFeeToken1, PRECISION, _supply, Math.Rounding.Floor
      );
    }

    emit FeeIndexesUpdated(
      globalFeeIndex0Scaled, globalFeeIndex1Scaled, _collectedFeeToken0, _collectedFeeToken1
    );
  }

  /// @notice Updates user's accrued (but not yet claimed) and user's fee indices.
  /// @param _user The address to update fees for.
  /// @dev
  ///   - Should be called before mint, burn, transfer and claim.
  ///   - Accrues newly earned fees into `userFees[_user].userAccruedToken0/userAccruedToken1`.
  ///   - Updates `userFees[_user].userFeeIndex0Scaled/userFeeIndex1Scaled` to the current global
  /// indices.
  function _updateUserFees(address _user) internal {
    // 1. User's balance of VaultShares tokens
    uint256 _userBalance = balanceOf(_user);

    // 2. User's last recorded fee indices
    UserFees storage account = userFees[_user];
    uint256 _userFeeIndex0 = account.userFeeIndex0Scaled;
    uint256 _userFeeIndex1 = account.userFeeIndex1Scaled;

    // 3. If user has no shares, they cannot earn new fees going forward.
    // Just sync their fee indices so they don't retro-earn when they
    // receive shares in the future.
    if (_userBalance == 0) {
      if (_userFeeIndex0 != globalFeeIndex0Scaled) {
        account.userFeeIndex0Scaled = globalFeeIndex0Scaled;
      }
      if (_userFeeIndex1 != globalFeeIndex1Scaled) {
        account.userFeeIndex1Scaled = globalFeeIndex1Scaled;
      }
      return;
    }

    // 4. Accrue newly earned fees for token0
    if (globalFeeIndex0Scaled > _userFeeIndex0) {
      uint256 _deltaIndex0 = globalFeeIndex0Scaled - _userFeeIndex0;
      account.userAccruedToken0 += Math.mulDiv(_userBalance, _deltaIndex0, PRECISION);
      account.userFeeIndex0Scaled = globalFeeIndex0Scaled;
    }

    // 5. Accrue newly earned fees for token1
    if (globalFeeIndex1Scaled > _userFeeIndex1) {
      uint256 _deltaIndex1 = globalFeeIndex1Scaled - _userFeeIndex1;
      account.userAccruedToken1 += Math.mulDiv(_userBalance, _deltaIndex1, PRECISION);
      account.userFeeIndex1Scaled = globalFeeIndex1Scaled;
    }
  }

  /// @notice Claims accrued fees for a user after syncing to the latest global indices.
  /// @param _user The address to claim fees for.
  /// @return _claimedToken0 Amount of FEE_TOKEN_0 that was transferred.
  /// @return _claimedToken1 Amount of FEE_TOKEN_1 that was transferred.
  function _claim(address _user) internal returns (uint256 _claimedToken0, uint256 _claimedToken1) {
    // Update user fees to ensure we're syncing to the latest global indices
    _updateUserFees(_user);

    // Get the accrued amounts before resetting
    UserFees storage account = userFees[_user];
    _claimedToken0 = account.userAccruedToken0;
    _claimedToken1 = account.userAccruedToken1;

    // Reset accrued amounts to 0
    account.userAccruedToken0 = 0;
    account.userAccruedToken1 = 0;

    // Emit event for transparency
    emit FeesClaimed(_user, FEE_TOKEN0, FEE_TOKEN1, _claimedToken0, _claimedToken1);

    // Transfer tokens to the user
    _transferAmount(FEE_TOKEN0, _user, _claimedToken0);
    _transferAmount(FEE_TOKEN1, _user, _claimedToken1);
  }

  /// @notice Transfers an amount of tokens to a user.
  /// @param _token The address of the token to transfer.
  /// @param _to The address to transfer the tokens to.
  /// @param _amount The amount of tokens to transfer.
  /// @dev Following Uniswap v4's convention: address(0) represents native ETH.
  ///      See: https://github.com/Uniswap/v4-core/blob/main/src/types/Currency.sol#L37-L38
  function _transferAmount(address _token, address _to, uint256 _amount) internal {
    if (_token == address(0)) {
      (bool _success,) = payable(_to).call{value: _amount}("");
      if (!_success) revert VaultShareToken_TransferFailed();
    } else {
      SafeERC20.safeTransfer(IERC20(_token), _to, _amount);
    }
  }
}
