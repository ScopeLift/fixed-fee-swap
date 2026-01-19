// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Internal Imports
import {PrincipalToken} from "src/PrincipalToken.sol";
import {YieldToken} from "src/YieldToken.sol";
import {LPVault} from "src/LPVault.sol";
import {VaultShareToken} from "src/VaultShareToken.sol";
import {FixedFeeSwapHook} from "src/FixedFeeSwapHook.sol";
import {FeeTracking} from "src/lib/FeeTracking.sol";
// External Imports
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract Zapper is IERC3156FlashBorrower {
  using SafeERC20 for IERC20;

  /*//////////////////////////////////////////////////////////////
                        ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when address is invalid.
  error Zapper_InvalidAddress();

  /// @notice Thrown when amount is invalid.
  error Zapper_InvalidAmount();

  /// @notice Thrown when flash loan callback is called with invalid initiator.
  error Zapper_InvalidInitiator();

  /// @notice Thrown when flash loan callback is called with invalid token.
  error Zapper_InvalidFlashLoanToken();

  /// @notice Thrown when flash loan callback is called with invalid caller.
  error Zapper_NotAuthorized();

  /*//////////////////////////////////////////////////////////////
                        EVENTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Emitted when yield token is sold.
  /// @param user The address that sold the yield token.
  /// @param ytAmount The amount of yield token sold.
  /// @param vaultSharesReceived The amount of vault shares received.
  event YieldTokenSold(address indexed user, uint256 ytAmount, uint256 vaultSharesReceived);

  /// @notice Emitted when yield token is bought.
  /// @param user The address that bought the yield token.
  /// @param ytBought The amount of yield token bought.
  /// @param vstSupplied The amount of VST supplied.
  event YieldTokenBought(address indexed user, uint256 ytBought, uint256 vstSupplied);

  /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice Magic return value for flash loan callback.
  bytes32 private constant FLASH_LOAN_RETURN_VALUE = keccak256("ERC3156FlashBorrower.onFlashLoan");

  /// @notice The yield token address.
  YieldToken public immutable YIELD_TOKEN;

  /// @notice The principal token address.
  PrincipalToken public immutable PRINCIPAL_TOKEN;

  /// @notice The vault share token address.
  VaultShareToken public immutable VAULT_SHARE_TOKEN;

  /// @notice The fixed fee swap hook address.
  FixedFeeSwapHook public immutable FIXED_FEE_SWAP_HOOK;

  /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /// @notice Initializes the zapper.
  /// @param _fixedFeeSwapHook The fixed fee swap hook address.
  constructor(FixedFeeSwapHook _fixedFeeSwapHook) {
    if (address(_fixedFeeSwapHook) == address(0)) revert Zapper_InvalidAddress();

    FIXED_FEE_SWAP_HOOK = _fixedFeeSwapHook;
    YIELD_TOKEN = _fixedFeeSwapHook.YIELD_TOKEN();
    PRINCIPAL_TOKEN = _fixedFeeSwapHook.PRINCIPAL_TOKEN();
    VAULT_SHARE_TOKEN = _fixedFeeSwapHook.VAULT_SHARE_TOKEN();
  }

  /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Sells YT tokens for VST.
  /// @param _ytAmount The amount of YT tokens to sell.
  function sellYieldToken(uint256 _ytAmount) external {
    if (_ytAmount == 0) revert Zapper_InvalidAmount();

    // 1. User sends YT to zapper
    YIELD_TOKEN.transferFrom(msg.sender, address(this), _ytAmount);

    // 2. Request flash loan of PT equal to YT amount
    PRINCIPAL_TOKEN.flashLoan(
      IERC3156FlashBorrower(address(this)),
      address(PRINCIPAL_TOKEN),
      _ytAmount,
      "" // No data needed
    );

    // 3. After repaying flash loan (via `onFlashLoan`), transfer remaining VST to user
    uint256 _vstReceived = VAULT_SHARE_TOKEN.balanceOf(address(this));
    VAULT_SHARE_TOKEN.transfer(msg.sender, _vstReceived);

    emit YieldTokenSold(msg.sender, _ytAmount, _vstReceived);
  }

  /// @notice Buys YT by supplying VST.
  /// @param _vstAmount The amount of VST to supply.
  function buyYieldToken(uint256 _vstAmount) external {
    if (_vstAmount == 0) revert Zapper_InvalidAmount();

    // 1. User sends VST to zapper
    VAULT_SHARE_TOKEN.transferFrom(msg.sender, address(this), _vstAmount);

    // 2. Calculate PT debt: X = vstAmount / (1 - ptPrice)
    uint256 _ptPrice = 0.98e18; // Mock: 0.98 VST per PT (18 decimals)
    uint256 _ptDebt =
      Math.mulDiv(_vstAmount, FeeTracking.PRECISION, FeeTracking.PRECISION - _ptPrice);

    // 3. Flash loan PT
    PRINCIPAL_TOKEN.flashLoan(
      IERC3156FlashBorrower(address(this)),
      address(PRINCIPAL_TOKEN),
      _ptDebt,
      abi.encode(true) // Flag to indicate this is a buy operation
    );

    // 4. After flash loan callback, send all YT to user
    uint256 _ytBought = YIELD_TOKEN.balanceOf(address(this));
    YIELD_TOKEN.transfer(msg.sender, _ytBought);

    emit YieldTokenBought(msg.sender, _ytBought, _vstAmount);
  }

  /// @notice Flash loan callback implementation.
  /// @param _initiator The address that initiated the flash loan.
  /// @param _token The token being flash loaned.
  /// @param _amount The amount of tokens flash loaned.
  /// @param _data Encoded bool: true = buy, false/empty = sell.
  /// @return FLASH_LOAN_RETURN_VALUE The magic return value.
  function onFlashLoan(
    address _initiator,
    address _token,
    uint256 _amount,
    uint256, // _fee
    bytes calldata _data
  ) external returns (bytes32) {
    // Verify this contract initiated the flash loan
    if (_initiator != address(this)) revert Zapper_InvalidInitiator();

    // Verify the token is PT
    if (_token != address(PRINCIPAL_TOKEN)) revert Zapper_InvalidFlashLoanToken();

    // Verify the caller is the PT token contract
    if (msg.sender != address(PRINCIPAL_TOKEN)) revert Zapper_NotAuthorized();

    bool _isBuy = _data.length > 0 && abi.decode(_data, (bool));

    if (_isBuy) _handleBuyFlashLoan(_amount);
    else _handleSellFlashLoan(_amount);

    return FLASH_LOAN_RETURN_VALUE;
  }

  /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Handles flash loan callback for selling YT.
  /// @param _amount The amount of PT flash loaned.
  function _handleSellFlashLoan(uint256 _amount) internal {
    // Approve hook to spend PT and YT
    IERC20(address(PRINCIPAL_TOKEN)).approve(address(FIXED_FEE_SWAP_HOOK), _amount);
    IERC20(address(YIELD_TOKEN)).approve(address(FIXED_FEE_SWAP_HOOK), _amount);

    // Burn PT and YT to mint VST
    uint256 _vstMinted = FIXED_FEE_SWAP_HOOK.redeem(_amount);

    // Calculate and swap portion of VST for PT to repay flash loan
    uint256 _swappedPT = _calculateAndSwapVSTForPT(_vstMinted, _amount);

    // Approve PT contract to spend PT to repay flash loan
    IERC20(address(PRINCIPAL_TOKEN)).approve(address(PRINCIPAL_TOKEN), _swappedPT);
  }

  /// @notice Handles flash loan callback for buying YT.
  /// @param _amount The amount of PT to repay (flash loan amount).
  function _handleBuyFlashLoan(uint256 _amount) internal {
    // Mock: Swap PT for VST (assume 1 PT = 0.98 VST)
    // In production, this would be an AMM swap
    uint256 _vstFromSwap = (_amount * 98) / 100;

    // Combine swapped VST with user's VST
    uint256 _totalVst = VAULT_SHARE_TOKEN.balanceOf(address(this));

    // Split all VST into PT + YT
    IERC20(address(VAULT_SHARE_TOKEN)).approve(address(FIXED_FEE_SWAP_HOOK), _totalVst);
    (uint256 _ptMinted,) = FIXED_FEE_SWAP_HOOK.deposit(_totalVst);

    // Approve PT contract to spend PT to repay flash loan
    IERC20(address(PRINCIPAL_TOKEN)).approve(address(PRINCIPAL_TOKEN), _amount);

    // YT stays in contract and will be sent to user after callback
  }

  /// @notice Calculates and swaps portion of available VST for PT to repay flash loan.
  /// @param _availableVST The amount of VST available to swap.
  /// @param _neededPt The amount of PT needed to repay flash loan.
  /// @return _swappedPT The amount of PT obtained from swapping VST.
  /// @dev Mock implementation: uses deposit() with assumption that 1 VST = 0.5 PT + 0.5 YT.
  ///      Since deposit() gives 1 VST = 1 PT + 1 YT, we swap 2x the needed PT to account for this.
  ///      This ensures we always leave some VST for the user. In production, use AMM curve.
  function _calculateAndSwapVSTForPT(uint256 _availableVST, uint256 _neededPt)
    internal
    returns (uint256 _swappedPT)
  {
    // Mock: Assume we need 2 VST to get 1 PT (since deposit gives 1 VST = 1 PT + 1 YT,
    // but we only need PT, so we effectively need 2 VST per 1 PT)
    uint256 _vstToSwap = _neededPt * 2;

    // Cap at available VST
    if (_vstToSwap > _availableVST) _vstToSwap = _availableVST;

    // Use deposit to swap VST for PT+YT (mock: 1 VST = 1 PT + 1 YT)
    IERC20(address(VAULT_SHARE_TOKEN)).approve(address(FIXED_FEE_SWAP_HOOK), _vstToSwap);
    (uint256 _ptAmount, uint256 _ytAmount) = FIXED_FEE_SWAP_HOOK.deposit(_vstToSwap);
    _swappedPT = _ptAmount;
    // YT amount is unused but left in contract

    // Note: This mock always leaves VST for the user since we swap 2x the needed PT
  }
}
