// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// External Imports
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Internal imports
import {FeeTracking} from "./lib/FeeTracking.sol";

contract PrincipalToken is ERC20 {
  using FeeTracking for FeeTracking.GlobalFees;
  using FeeTracking for FeeTracking.UserFees;

  /*//////////////////////////////////////////////////////////////
                        ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when the caller is not authorized.
  error PrincipalToken_NotAuthorized();

  /// @notice Thrown when a transfer fails.
  error PrincipalToken_TransferFailed();

  /// @notice Thrown when fee indexes are already initialized.
  error PrincipalToken_FeeIndexesAlreadyInitialized();

  /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice The fixed fee swap hook address.
  address public immutable FIXED_FEE_SWAP_HOOK;

  /// @notice The token address in which token0 fees are collected / distributed.
  /// @dev Use address(0) to represent native ETH following Uniswap v4 `Currency` convention.
  address public immutable FEE_TOKEN0;

  /// @notice The token address in which token1 fees are collected / distributed.
  /// @dev Use address(0) to represent native ETH following Uniswap v4 `Currency` convention.
  address public immutable FEE_TOKEN1;

  /// @notice Global fee tracking state.
  FeeTracking.GlobalFees private _globalFees;

  /// @notice Tracks fee accounting data per user.
  mapping(address => FeeTracking.UserFees) public userFees;

  /// @notice Whether fee indexes have been initialized (baseline set).
  bool private _feeIndexesInitialized;

  /// @notice Baseline fee indexes (set once at maturity).
  /// @dev Used to lazily initialize user checkpoints so nobody "earns the baseline".
  uint256 private _baselineFeeIndex0Scaled;
  uint256 private _baselineFeeIndex1Scaled;

  /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /// @notice Initializes the principal token metadata.
  /// @param _name ERC20 name value.
  /// @param _symbol ERC20 symbol value.
  /// @param _fixedFeeSwapHook The fixed fee swap hook address.
  constructor(
    string memory _name,
    string memory _symbol,
    address _fixedFeeSwapHook,
    address _feeToken0,
    address _feeToken1
  ) ERC20(_name, _symbol) {
    FIXED_FEE_SWAP_HOOK = _fixedFeeSwapHook;
    FEE_TOKEN0 = _feeToken0;
    FEE_TOKEN1 = _feeToken1;
  }

  /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Global cumulative fee index for token0.
  /// @dev Scaled by PRECISION. Represents total token0 fees accrued per 1 share since baseline.
  function globalFeeIndex0Scaled() external view returns (uint256) {
    return _globalFees.globalFeeIndex0Scaled;
  }

  /// @notice Global cumulative fee index for token1.
  /// @dev Scaled by PRECISION. Represents total token1 fees accrued per 1 share since baseline.
  function globalFeeIndex1Scaled() external view returns (uint256) {
    return _globalFees.globalFeeIndex1Scaled;
  }

  /// @notice Initializes the PT fee indexes baseline (one-time).
  /// @dev Intended to be called by the hook at maturity so PT fee tracking starts from YT's final
  /// indexes.
  function initializeFeeIndexes(uint256 _index0Scaled, uint256 _index1Scaled) external {
    _requireHook();
    if (_feeIndexesInitialized) revert PrincipalToken_FeeIndexesAlreadyInitialized();
    _globalFees.globalFeeIndex0Scaled = _index0Scaled;
    _globalFees.globalFeeIndex1Scaled = _index1Scaled;
    _baselineFeeIndex0Scaled = _index0Scaled;
    _baselineFeeIndex1Scaled = _index1Scaled;
    _feeIndexesInitialized = true;
  }

  /// @notice Updates the fee indexes for token0 and token1.
  /// @param _collectedFeeToken0 Newly collected token0 fees (delta since last call).
  /// @param _collectedFeeToken1 Newly collected token1 fees (delta since last call).
  /// @dev Can only be called by the hook.
  function updateFees(uint256 _collectedFeeToken0, uint256 _collectedFeeToken1) external {
    _requireHook();
    _globalFees._updateFees(_collectedFeeToken0, _collectedFeeToken1, totalSupply());
  }

  /// @notice Claims accrued (but not yet claimed) fees for `_user`.
  /// @dev Can only be called by the hook (typically during redeem when PT is burned).
  function claim(address _user) external returns (uint256 _claimedToken0, uint256 _claimedToken1) {
    _requireHook();
    _maybeInitializeUserCheckpoint(_user);
    _updateUserFees(_user);
    (_claimedToken0, _claimedToken1) = userFees[_user]._resetAccruedFees();
    _transferAmount(FEE_TOKEN0, _user, _claimedToken0);
    _transferAmount(FEE_TOKEN1, _user, _claimedToken1);
  }

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

  /// @inheritdoc ERC20
  /// @dev Updates user fee accounting for both the sender and the recipient.
  function _update(address _from, address _to, uint256 _value) internal override {
    if (_from != address(0)) {
      _maybeInitializeUserCheckpoint(_from);
      _updateUserFees(_from);
    }
    if (_to != address(0)) {
      _maybeInitializeUserCheckpoint(_to);
      _updateUserFees(_to);
    }
    super._update(_from, _to, _value);
  }

  /// @notice Updates user's accrued fees and fee indices.
  function _updateUserFees(address _user) internal {
    userFees[_user]._updateUserFees(
      balanceOf(_user), _globalFees.globalFeeIndex0Scaled, _globalFees.globalFeeIndex1Scaled
    );
  }

  /// @notice Lazily initializes a user's fee checkpoint to the maturity baseline.
  /// @dev PT fee tracking is enabled at maturity by setting the PT global indexes to a non-zero
  ///      baseline (copied from YT's final indexes). A user's checkpoint starts at 0 by default.
  ///
  ///      Example:
  ///      - At maturity we set PT baseline index to 100 (copied from YT final index).
  ///      - Alice holds 10 PT and has never interacted with PT fee accounting, so her checkpoint is
  /// 0. - Later, after fees accrue, PT global index becomes 120.
  ///
  ///      If we DID NOT initialize her checkpoint, syncing would accrue:
  ///          10 * (120 - 0) = 1200  (WRONG: includes the 0 -> 100 baseline)
  ///
  ///      With this initializer, we first set her checkpoint to the baseline (100), so she accrues:
  ///          10 * (120 - 100) = 200 (CORRECT: only post-maturity fees, 100 -> 120)
  function _maybeInitializeUserCheckpoint(address _user) internal {
    if (!_feeIndexesInitialized) return;
    FeeTracking.UserFees storage _uf = userFees[_user];
    if (_uf.userFeeIndex0Scaled == 0 && _uf.userFeeIndex1Scaled == 0) {
      _uf.userFeeIndex0Scaled = _baselineFeeIndex0Scaled;
      _uf.userFeeIndex1Scaled = _baselineFeeIndex1Scaled;
    }
  }

  /// @notice Transfers an amount of tokens to a user.
  /// @dev Following Uniswap v4's convention: address(0) represents native ETH.
  ///      See: https://github.com/Uniswap/v4-core/blob/main/src/types/Currency.sol#L37-L38
  function _transferAmount(address _token, address _to, uint256 _amount) internal {
    if (_amount == 0) return;
    if (_token == address(0)) {
      (bool _success,) = payable(_to).call{value: _amount}("");
      if (!_success) revert PrincipalToken_TransferFailed();
    } else {
      SafeERC20.safeTransfer(IERC20(_token), _to, _amount);
    }
  }

  /// @notice Requires the caller to be the fixed fee swap hook.
  function _requireHook() internal view {
    if (msg.sender != FIXED_FEE_SWAP_HOOK) revert PrincipalToken_NotAuthorized();
  }
}
