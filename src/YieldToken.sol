// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// External Imports
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Internal imports
import {FeeTracking} from "src/lib/FeeTracking.sol";
import {IFeeTrackingToken} from "src/interface/IFeeTrackingToken.sol";
import {IFixedFeeSwap} from "src/interface/IFixedFeeSwap.sol";

contract YieldToken is ERC20, IFeeTrackingToken {
  using FeeTracking for FeeTracking.GlobalFees;
  using FeeTracking for FeeTracking.UserFees;

  /*//////////////////////////////////////////////////////////////
                        ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when the caller is not authorized.
  error YieldToken_NotAuthorized();

  /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice Native ETH address following Uniswap v4 `Currency` convention.
  /// @dev See: https://github.com/Uniswap/v4-core/blob/main/src/types/Currency.sol#L37-L38
  address private constant NATIVE = address(0);

  /// @notice The fixed fee swap address.
  address public immutable FIXED_FEE_SWAP;

  /// @notice The token address in which token0 fees are collected / distributed.
  address public immutable FEE_TOKEN0;

  /// @notice The token address in which token1 fees are collected / distributed.
  address public immutable FEE_TOKEN1;

  /// @notice Global fee tracking state.
  FeeTracking.GlobalFees private globalFees;

  /// @notice Tracks fee accounting data per user.
  mapping(address => FeeTracking.UserFees) public userFees;

  /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /// @notice Initializes the yield token metadata.
  /// @param _name ERC20 name value.
  /// @param _symbol ERC20 symbol value.
  /// @param _fixedFeeSwap The `FixedFeeSwap` address.
  constructor(
    string memory _name,
    string memory _symbol,
    address _fixedFeeSwap,
    address _feeToken0,
    address _feeToken1
  ) ERC20(_name, _symbol) {
    FIXED_FEE_SWAP = _fixedFeeSwap;
    FEE_TOKEN0 = _feeToken0;
    FEE_TOKEN1 = _feeToken1;
  }

  /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Global cumulative fee index for token0.
  /// @dev
  ///   - Scaled by PRECISION.
  ///   - Increases whenever new token0 fees are distributed via `_updateFees`.
  ///   - Represents the total amount of token0 fees accrued per 1 share since vault inception.
  ///   - Used with `userFees[user].userFeeIndex0Scaled` to compute user-specific deltas.
  function globalFeeIndex0Scaled() external view returns (uint256) {
    return globalFees.globalFeeIndex0Scaled;
  }

  /// @notice Global cumulative fee index for token1.
  /// @dev Same semantics as `globalFeeIndex0Scaled`, but for token1.
  function globalFeeIndex1Scaled() external view returns (uint256) {
    return globalFees.globalFeeIndex1Scaled;
  }

  /// @notice Claims accrued (but not yet claimed) fees for a `_user`.
  /// @param _user Address whose accrued fees will be claimed.
  /// @return _claimedToken0 Amount of `FEE_TOKEN_0` transferred to `_user`.
  /// @return _claimedToken1 Amount of `FEE_TOKEN_1` transferred to `_user`.
  function claim(address _user) external returns (uint256 _claimedToken0, uint256 _claimedToken1) {
    _requireFixedFeeSwap();
    (_claimedToken0, _claimedToken1) = _claim(_user);
  }

  /// @notice Mints tokens to an address.
  /// @param _to The address to mint tokens to.
  /// @param _amount The amount of tokens to mint.
  function mint(address _to, uint256 _amount) external {
    _requireFixedFeeSwap();
    _mint(_to, _amount);
  }

  /// @notice Burns tokens and claims accrued fees from an address.
  /// @param _from The address to burn tokens from.
  /// @param _amount The amount of tokens to burn.
  function burn(address _from, uint256 _amount) external {
    _requireFixedFeeSwap();
    _claim(_from);
    _burn(_from, _amount);
  }

  /// @notice Updates the fee indexes for token0 and token1.
  /// @param _collectedFeeToken0 Newly collected token0 fees collected from the pool (delta since
  /// last call).
  /// @param _collectedFeeToken1 Newly collected token1 fees collected from the pool (delta since
  /// last call).
  /// @dev Can only be called by `FixedFeeSwap` to update fees when collecting from the vault.
  function updateFees(uint256 _collectedFeeToken0, uint256 _collectedFeeToken1) external {
    _requireFixedFeeSwap();
    _updateFees(_collectedFeeToken0, _collectedFeeToken1);
  }

  /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Requires the caller to be the `FixedFeeSwap`.
  function _requireFixedFeeSwap() internal view {
    if (msg.sender != FIXED_FEE_SWAP) revert YieldToken_NotAuthorized();
  }

  /// @inheritdoc ERC20
  /// @dev Updates user fee accounting for both the sender and the recipient.
  function _update(address _from, address _to, uint256 _value) internal override {
    if (_from != NATIVE) _updateUserFees(_from);
    if (_to != NATIVE) _updateUserFees(_to);
    ERC20._update(_from, _to, _value);
  }

  /// @notice Updates the fee indexes for token0 and token1.
  /// @param _collectedFeeToken0 Newly collected token0 fees collected from the pool (delta since
  /// last call).
  /// @param _collectedFeeToken1 Newly collected token1 fees collected from the pool (delta since
  /// last call).
  /// @dev Intended to be called only from the inheriting contract.
  function _updateFees(uint256 _collectedFeeToken0, uint256 _collectedFeeToken1) internal {
    globalFees._updateFees(_collectedFeeToken0, _collectedFeeToken1, totalSupply());

    // Emit event after updating fees
    emit FeeIndexesUpdated(
      globalFees.globalFeeIndex0Scaled,
      globalFees.globalFeeIndex1Scaled,
      _collectedFeeToken0,
      _collectedFeeToken1
    );
  }

  /// @notice Updates user's accrued (but not yet claimed) and user's fee indices.
  /// @param _user The address to update fees for.
  /// @dev See `FeeTracking._updateUserFees` for details.
  function _updateUserFees(address _user) internal {
    userFees[_user]._updateUserFees(
      balanceOf(_user), globalFees.globalFeeIndex0Scaled, globalFees.globalFeeIndex1Scaled
    );
  }

  /// @notice Claims accrued fees for a user after syncing to the latest global indices.
  /// @param _user The address to claim fees for.
  /// @return _claimedToken0 Amount of `FEE_TOKEN_0` that was transferred.
  /// @return _claimedToken1 Amount of `FEE_TOKEN_1` that was transferred.
  /// @dev Syncs fees via FixedFeeSwap.collectFeesToYT, then transfers fees from FixedFeeSwap to
  /// the user. After maturity the sync credits nothing new, so this pays what the user's YT earned
  /// up to maturity.
  function _claim(address _user) internal returns (uint256 _claimedToken0, uint256 _claimedToken1) {
    IFixedFeeSwap(FIXED_FEE_SWAP).collectFeesToYT();

    // Update user fees to ensure we're syncing to the latest global indices
    _updateUserFees(_user);

    // Get the accrued amounts before resetting
    (_claimedToken0, _claimedToken1) = userFees[_user]._resetAccruedFees();

    // Emit event for transparency
    emit FeesClaimed(_user, _claimedToken0, _claimedToken1);

    // Transfer tokens directly from FixedFeeSwap to the user
    IFixedFeeSwap(FIXED_FEE_SWAP).transferFeesToUser(_user, _claimedToken0, _claimedToken1);
  }
}
