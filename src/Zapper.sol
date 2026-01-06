// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Internal Imports
import {PrincipalToken} from "src/PrincipalToken.sol";
import {YieldToken} from "src/YieldToken.sol";
import {LPVault} from "src/LPVault.sol";
import {VaultShareToken} from "src/VaultShareToken.sol";
import {FixedFeeSwapHook} from "src/FixedFeeSwapHook.sol";
// External Imports
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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
  /// @param token0Amount The amount of token0 supplied.
  /// @param token1Amount The amount of token1 supplied.
  /// @param ytBought The amount of yield token bought.
  // event YieldTokenBought(address indexed user, uint256 token0Amount, uint256 token1Amount, uint256 ytBought);

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

  /// @notice Buys YT by supplying token0 and token1
  /// @param _token0Amount The amount of token0 to supply.
  /// @param _token1Amount The amount of token1 to supply.
  // function buyYieldToken(uint256 _token0Amount, uint256 _token1Amount) external {
    // 1. User deposits token0 and token1 to mint vaults shares
    // (uint256 _vstMinted, uint256 _amount0Used, uint256 _amount1Used) = LPVault(address(VAULT_SHARE_TOKEN)).deposit(_token0Amount, _token1Amount);
    
    // 2. Should flash loan PT based on PT debt X 1/1−(price of vault share token per 1PT)​


    // 3. Swap flash loaned PT for vault shares, mock this swap for now
    // 4. Split all vault shares
    // 5. Pay back PT flash loan
    // 6. Send all YT to the user

    // emit YieldTokenBought(msg.sender, _token0Amount, _token1Amount, _ytBought);
  // }

  /// @notice Flash loan callback implementation.
  /// @param _initiator The address that initiated the flash loan.
  /// @param _token The token being flash loaned.
  /// @param _amount The amount of tokens flash loaned.
  /// @return FLASH_LOAN_RETURN_VALUE The magic return value.
  function onFlashLoan(
    address _initiator,
    address _token,
    uint256 _amount,
    uint256 , // _fee
    bytes calldata // _data
  ) external returns (bytes32) {
    // Verify this contract initiated the flash loan
    if (_initiator != address(this)) revert Zapper_InvalidInitiator();

    // Verify the token is PT
    if (_token != address(PRINCIPAL_TOKEN)) revert Zapper_InvalidFlashLoanToken();

    // Verify the caller is the PT token contract
    if (msg.sender != address(PRINCIPAL_TOKEN)) revert Zapper_NotAuthorized();

    // Approve hook to spend PT and YT
    IERC20(address(PRINCIPAL_TOKEN)).approve(address(FIXED_FEE_SWAP_HOOK), _amount);
    IERC20(address(YIELD_TOKEN)).approve(address(FIXED_FEE_SWAP_HOOK), _amount);

    // Burn PT and YT to mint VST
    uint256 _vstMinted = FIXED_FEE_SWAP_HOOK.redeem(_amount);

    // Calculate and swap portion of VST for PT to repay flash loan
    uint256 _swappedPT = _calculateAndSwapVSTForPT(_vstMinted, _amount);

    // Approve PT contract to spend PT to repay flash loan
    IERC20(address(PRINCIPAL_TOKEN)).approve(address(PRINCIPAL_TOKEN), _swappedPT);

    return FLASH_LOAN_RETURN_VALUE;
  }

  /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Calculates and swaps portion of available VST for PT to repay flash loan.
  /// @param _availableVST The amount of VST available to swap.
  /// @param _neededPt The amount of PT needed to repay flash loan.
  /// @return _swappedPT The amount of PT obtained from swapping VST.
  /// @dev Mock implementation: uses deposit() to split VST into PT+YT (1:1 ratio).
  ///      In production, this would use an AMM curve to swap VST for PT.
  function _calculateAndSwapVSTForPT(uint256 _availableVST, uint256 _neededPt) internal returns (uint256 _swappedPT) {
    // Calculate how many VST we need to swap for PT to repay flash loan
    // TODO: this will be replaced by the actual AMM curve. For now, use minimum of available and needed.
    uint256 _vstToSwap = _availableVST > _neededPt ? _neededPt : _availableVST;

    // Approve hook to spend VST
    IERC20(address(VAULT_SHARE_TOKEN)).approve(address(FIXED_FEE_SWAP_HOOK), _vstToSwap);

    // Swap VST for PT+YT using deposit (mock implementation: 1 VST = 1 PT + 1 YT)
    (uint256 _ptAmount, uint256 _ytAmount) = FIXED_FEE_SWAP_HOOK.deposit(_vstToSwap);
    _swappedPT = _ptAmount;

    // In a real AMM, we'd get only PT. For this mock, deposit gives us PT+YT in 1:1 ratio,
    // so the PT amount equals the VST amount swapped. The YT is left in the contract.
  }
}
