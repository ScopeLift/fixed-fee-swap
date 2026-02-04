// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// External imports
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Internal imports
import {PrincipalToken} from "src/PrincipalToken.sol";
import {YieldToken} from "src/YieldToken.sol";
import {VaultShareToken} from "src/VaultShareToken.sol";
import {FeeTracking} from "src/lib/FeeTracking.sol";

contract FixedFeeSwap {
  using SafeERC20 for IERC20;
  /*//////////////////////////////////////////////////////////////
                        ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when split is attempted after maturity is reached.
  error FixedFeeSwap_SplitAfterMaturity();

  /// @notice Thrown when deposit is attempted with an invalid amount.
  error FixedFeeSwap_InvalidAmount();

  /// @notice Thrown when split is attempted with an invalid maturity.
  error FixedFeeSwap_InvalidMaturity();

  /// @notice Thrown when split is attempted with an invalid vault share token.
  error FixedFeeSwap_InvalidVaultShareToken();

  /// @notice Thrown when action is attempted with an insufficient balance.
  error FixedFeeSwap_InsufficientBalance();

  /// @notice Thrown when an action is attempted before maturity is reached.
  error FixedFeeSwap_BeforeMaturity();

  /// @notice Thrown when a transfer fails.
  error FixedFeeSwap_TransferFailed();

  /*//////////////////////////////////////////////////////////////
                        EVENTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Emitted when the hook is initialized.
  /// @param vaultShareToken The address of the vault share token.
  /// @param principalToken The address of the principal token.
  /// @param yieldToken The address of the yield token.
  /// @param maturity The maturity of the hook.
  event Initialized(
    address vaultShareToken, address principalToken, address yieldToken, uint256 maturity
  );

  /// @notice Emitted when a user deposits their vault share token into principal and yield tokens.
  /// @param user The address of the user who deposited.
  /// @param amount The amount of vault share token deposited.
  event Deposit(address indexed user, uint256 amount);

  /// @notice Emitted when a user redeems their principal and yield tokens back into the vault share
  /// token.
  /// @param user The address of the user who redeemed.
  /// @param vstAmount The amount of vault share token redeemed.
  /// @param maturityReached Whether the maturity has been reached.
  event Redeem(address indexed user, uint256 vstAmount, bool maturityReached);

  /// @notice Emitted when a user claims fees after maturity.
  /// @param user The address of the user who claimed fees.
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

  /// @notice Native ETH address following Uniswap v4 `Currency` convention.
  /// @dev See: https://github.com/Uniswap/v4-core/blob/main/src/types/Currency.sol#L37-L38
  address private constant NATIVE = address(0);

  /// @notice The vault share token.
  VaultShareToken public immutable VAULT_SHARE_TOKEN;

  /// @notice The principal token.
  PrincipalToken public immutable PRINCIPAL_TOKEN;

  /// @notice The yield token.
  YieldToken public immutable YIELD_TOKEN;

  /// @notice The maturity after which yield token will be 0. (principal token will be equal to
  /// vault share token)
  uint256 public immutable MATURITY;

  /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /// @notice Initializes the hook and deploys the principal and yield tokens.
  /// @param _vaultShareToken The vault share token.
  /// @param _maturity The maturity of the hook.
  constructor(VaultShareToken _vaultShareToken, uint256 _maturity) {
    if (address(_vaultShareToken) == address(0)) revert FixedFeeSwap_InvalidVaultShareToken();
    if (_maturity <= block.timestamp) revert FixedFeeSwap_InvalidMaturity();

    VAULT_SHARE_TOKEN = _vaultShareToken;

    string memory _underlyingName = VAULT_SHARE_TOKEN.name();
    string memory _underlyingSymbol = VAULT_SHARE_TOKEN.symbol();
    string memory _maturityStr = Strings.toString(_maturity);

    PRINCIPAL_TOKEN = new PrincipalToken(
      string.concat("Principal ", _underlyingName),
      string.concat("PT-", _underlyingSymbol, "-", _maturityStr),
      address(this)
    );
    YIELD_TOKEN = new YieldToken(
      string.concat("Yield ", _underlyingName),
      string.concat("YT-", _underlyingSymbol, "-", _maturityStr),
      address(this),
      VAULT_SHARE_TOKEN.FEE_TOKEN0(),
      VAULT_SHARE_TOKEN.FEE_TOKEN1()
    );

    MATURITY = _maturity;

    emit Initialized(
      address(_vaultShareToken), address(PRINCIPAL_TOKEN), address(YIELD_TOKEN), _maturity
    );
  }

  /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Deposits the vault share token into principal and yield tokens.
  /// @param _amount The amount of vault share token to deposit.
  /// @dev The caller must have approved the hook to spend the vault share token.
  /// @dev When we split VST, we split it into equal amounts of YT + PT (1:1 ratio).
  function deposit(uint256 _amount) external {
    if (block.timestamp >= MATURITY) revert FixedFeeSwap_SplitAfterMaturity();

    if (_amount == 0) revert FixedFeeSwap_InvalidAmount();

    if (VAULT_SHARE_TOKEN.balanceOf(msg.sender) < _amount) {
      revert FixedFeeSwap_InsufficientBalance();
    }

    // Transfer VaultShareToken from caller to the hook
    VAULT_SHARE_TOKEN.transferFrom(msg.sender, address(this), _amount);

    // When we split VST, we split it into equal amounts of YT + PT (1:1 ratio)
    // Mint PrincipalToken to the caller
    PRINCIPAL_TOKEN.mint(msg.sender, _amount);

    // Mint YieldToken to the caller
    YIELD_TOKEN.mint(msg.sender, _amount);

    emit Deposit(msg.sender, _amount);
  }

  /// @notice Redeems the principal and yield tokens back into the vault share token.
  /// @param _amount The amount of principal and yield tokens to redeem.
  /// @return _vstAmount The amount of vault share token redeemed.
  /// @dev
  ///  - The caller must have approved the hook to spend the PT and YT tokens.
  ///  - If called before maturity, the caller must have at least `_amount` PT and YT tokens.
  ///  - If called at/after maturity, the caller must have at least `_amount` PT tokens.
  ///  - Note:
  ///    - Before maturity, the YT will be non-zero, so 1 PT + 1 YT = 1 VST.
  ///    - After maturity, the caller will claim fees proportionally based on their PT ownership.
  ///      Fees are calculated as: (contractBalance × amount) / totalSupply for each fee token.
  function redeem(uint256 _amount) external returns (uint256 _vstAmount) {
    if (_amount == 0) revert FixedFeeSwap_InvalidAmount();

    // Caller should always have enough PT tokens
    if (PRINCIPAL_TOKEN.balanceOf(msg.sender) < _amount) {
      revert FixedFeeSwap_InsufficientBalance();
    }

    bool _maturityReached = block.timestamp >= MATURITY;

    if (!_maturityReached) {
      // -------- BEFORE MATURITY ( needs both PT and YT) --------
      _claimAndBurnYieldTokens(msg.sender, _amount);
    } else {
      // -------- AFTER MATURITY --------
      // Note: Post maturity, YT tokens are valued at 0, so we could burn them as well,
      // but it's not required since they have no value. Users can burn YT separately if desired.
      _claimFeesAccruedAfterMaturity(msg.sender, _amount);
    }

    // Burn PT tokens (always required)
    PRINCIPAL_TOKEN.burn(msg.sender, _amount);

    // Transfer VaultShareToken from the hook to the caller
    _vstAmount = _amount;
    if (VAULT_SHARE_TOKEN.balanceOf(address(this)) < _vstAmount) {
      revert FixedFeeSwap_InsufficientBalance();
    }

    VAULT_SHARE_TOKEN.transfer(msg.sender, _vstAmount);

    emit Redeem(msg.sender, _vstAmount, _maturityReached);
  }

  /// @notice Claims fees and burns leftover yield tokens after maturity.
  /// @dev
  ///  - Can only be called after maturity.
  ///  - Claims any fees accrued on the YT tokens before maturity.
  ///  - Burns the YT tokens after claiming fees.
  ///  - Useful for users who have leftover YT tokens after maturity.
  ///  - Note: This function internally calls `burn()` on the YT token, which claims fees before
  /// burning. Fees are claimed through the YT token's burn mechanism.
  function claimYTFeesAfterMaturity() external {
    if (block.timestamp < MATURITY) revert FixedFeeSwap_BeforeMaturity();

    uint256 _amount = YIELD_TOKEN.balanceOf(msg.sender);

    if (_amount == 0) revert FixedFeeSwap_InvalidAmount();

    _claimAndBurnYieldTokens(msg.sender, _amount);
  }

  /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Claims fees and burns YT tokens
  /// @param _user The address to claim fees from and burn YT tokens for.
  /// @param _amount The amount of YT tokens to claim fees from and burn.
  /// @dev Burns the YT tokens, which internally claims fees before burning.
  function _claimAndBurnYieldTokens(address _user, uint256 _amount) internal {
    // Caller should have enough YT tokens
    if (YIELD_TOKEN.balanceOf(_user) < _amount) revert FixedFeeSwap_InsufficientBalance();

    // Burn YT tokens (which internally claims fees before burning)
    YIELD_TOKEN.burn(_user, _amount);
  }

  /// @notice Claims post-maturity fees accrued for a user based on their PT amount.
  /// @param _user The address to claim fees for.
  /// @param _amount The amount of PT tokens being redeemed.
  /// @dev
  ///  - Calculates fees proportionally based on contract balances and total PT supply.
  ///  - Formula: fees = (contractBalance * amount) / totalSupply
  function _claimFeesAccruedAfterMaturity(address _user, uint256 _amount) internal {
    // Get total PT supply to calculate proportional share
    uint256 _totalSupply = PRINCIPAL_TOKEN.totalSupply();

    if (_totalSupply == 0) revert FixedFeeSwap_InsufficientBalance();

    // Get contract balances for both fee tokens
    address _feeToken0 = VAULT_SHARE_TOKEN.FEE_TOKEN0();
    address _feeToken1 = VAULT_SHARE_TOKEN.FEE_TOKEN1();

    // Calculate post-maturity fees claimable for the redeemed amount proportionally
    // Scale by PRECISION to avoid rounding errors in intermediate calculations
    // Pattern: (balance * amount * PRECISION) / totalSupply, then divide by PRECISION
    // This preserves precision better than (balance * amount) / totalSupply for small values
    uint256 _feeToken0Amount = Math.mulDiv(
      _getTokenBalance(_feeToken0),
      _amount * FeeTracking.PRECISION,
      _totalSupply,
      Math.Rounding.Floor
    ) / FeeTracking.PRECISION;
    uint256 _feeToken1Amount = Math.mulDiv(
      _getTokenBalance(_feeToken1),
      _amount * FeeTracking.PRECISION,
      _totalSupply,
      Math.Rounding.Floor
    ) / FeeTracking.PRECISION;

    // Transfer post-maturity fees to the user
    if (_feeToken0Amount > 0) _transferFeeToken(_feeToken0, _user, _feeToken0Amount);
    if (_feeToken1Amount > 0) _transferFeeToken(_feeToken1, _user, _feeToken1Amount);

    emit FeesClaimed(_user, _feeToken0, _feeToken1, _feeToken0Amount, _feeToken1Amount);
  }

  /// @notice Gets the balance of a token in the contract.
  /// @param _token The address of the token to get the balance of.
  /// @return The balance of the token in the contract.
  function _getTokenBalance(address _token) internal view returns (uint256) {
    if (_token == NATIVE) return address(this).balance;
    else return IERC20(_token).balanceOf(address(this));
  }

  /// @notice Transfers an amount of fee tokens to a user.
  /// @param _token The address of the token to transfer.
  /// @param _to The address to transfer the tokens to.
  /// @param _amount The amount of tokens to transfer.
  /// @dev Following Uniswap v4's `Currency` convention: NATIVE represents native ETH.
  ///      See: https://github.com/Uniswap/v4-core/blob/main/src/types/Currency.sol#L37-L38
  function _transferFeeToken(address _token, address _to, uint256 _amount) internal {
    if (_token == NATIVE) {
      (bool _success,) = payable(_to).call{value: _amount}("");
      if (!_success) revert FixedFeeSwap_TransferFailed();
    } else {
      IERC20(_token).safeTransfer(_to, _amount);
    }
  }
}
