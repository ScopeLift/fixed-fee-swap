// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Internal Imports
import {PrincipalToken} from "src/PrincipalToken.sol";
import {YieldToken} from "src/YieldToken.sol";
import {VaultShareToken} from "src/VaultShareToken.sol";
import {FixedFeeSwap} from "src/FixedFeeSwap.sol";
import {FeeTracking} from "src/lib/FeeTracking.sol";
import {FixedFeeSwapMarket} from "src/FixedFeeSwapMarket.sol";

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
  FixedFeeSwap public immutable FIXED_FEE_SWAP;

  /// @notice The fixed fee swap market address.
  FixedFeeSwapMarket public immutable FIXED_FEE_SWAP_MARKET;

  /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /// @notice Initializes the zapper.
  /// @param _fixedFeeSwap The fixed fee swap address.
  /// @param _fixedFeeSwapMarket The fixed fee swap market address.
  constructor(FixedFeeSwap _fixedFeeSwap, FixedFeeSwapMarket _fixedFeeSwapMarket) {
    if (
      address(_fixedFeeSwap) == address(0)
      || address(_fixedFeeSwapMarket) == address(0)
    ) revert Zapper_InvalidAddress();

    FIXED_FEE_SWAP = _fixedFeeSwap;
    FIXED_FEE_SWAP_MARKET = _fixedFeeSwapMarket;
    YIELD_TOKEN = _fixedFeeSwap.YIELD_TOKEN();
    PRINCIPAL_TOKEN = _fixedFeeSwap.PRINCIPAL_TOKEN();
    VAULT_SHARE_TOKEN = _fixedFeeSwap.VAULT_SHARE_TOKEN();
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
    // Get current PT price from market (WAD-scaled, e.g., 0.98e18 = 0.98 VST per PT)
    int256 _ptPriceSigned = FIXED_FEE_SWAP_MARKET.getCurrentPrice();
    uint256 _ptPrice = _ptPriceSigned > 0 ? uint256(_ptPriceSigned) : 0;
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
    IERC20(address(PRINCIPAL_TOKEN)).approve(address(FIXED_FEE_SWAP), _amount);
    IERC20(address(YIELD_TOKEN)).approve(address(FIXED_FEE_SWAP), _amount);

    // Burn PT and YT to mint VST
    uint256 _vstMinted = FIXED_FEE_SWAP.redeem(_amount);

    // Calculate and swap portion of VST for PT to repay flash loan
    uint256 _swappedPT = _calculateAndSwapVSTForPT(_vstMinted, _amount);

    // Approve PT contract to spend PT to repay flash loan
    IERC20(address(PRINCIPAL_TOKEN)).approve(address(PRINCIPAL_TOKEN), _swappedPT);
  }

  /// @notice Handles flash loan callback for buying YT.
  /// @param _amount The amount of PT to repay (flash loan amount).
  function _handleBuyFlashLoan(uint256 _amount) internal {
    // Swap PT for VST (cash) using the market
    // principalForCash = true means: PT in → cash out
    IERC20(address(PRINCIPAL_TOKEN)).approve(address(FIXED_FEE_SWAP_MARKET), _amount);
    FIXED_FEE_SWAP_MARKET.swap(
      _amount, // amountIn (PT)
      true, // principalForCash = true (we're swapping principal FOR cash)
      0 // no price limit
    );

    // Combine swapped VST with user's existing VST
    uint256 _totalVst = VAULT_SHARE_TOKEN.balanceOf(address(this));

    // Split all VST into PT + YT
    IERC20(address(VAULT_SHARE_TOKEN)).approve(address(FIXED_FEE_SWAP), _totalVst);
    FIXED_FEE_SWAP.deposit(_totalVst);

    // Approve PT contract to spend PT to repay flash loan
    IERC20(address(PRINCIPAL_TOKEN)).approve(address(PRINCIPAL_TOKEN), _amount);

    // YT stays in contract and will be sent to user after callback
  }

  /// @notice Swaps VST (cash) for PT using the FixedFeeSwapMarket
  /// @param _availableVST The amount of VST available to swap
  /// @param _neededPt The amount of PT needed to repay flash loan (unused, swap all available)
  /// @return _swappedPT The amount of PT obtained from swapping VST
  function _calculateAndSwapVSTForPT(uint256 _availableVST, uint256 _neededPt)
    internal
    returns (uint256 _swappedPT)
  {
    // Approve market to spend VST (cash token)
    IERC20(address(VAULT_SHARE_TOKEN)).approve(address(FIXED_FEE_SWAP_MARKET), _availableVST);

    // Swap VST (cash) for PT (principal)
    // principalForCash = false means: cash in → PT out
    (, _swappedPT) = FIXED_FEE_SWAP_MARKET.swap(
      _availableVST, // amountIn (VST)
      false, // principalForCash = false (we're swapping cash FOR principal)
      0 // no price limit
    );

    // Note: If we get less PT than needed, the flash loan repayment will fail
    // The caller should ensure sufficient VST is available for the swap
  }
}
