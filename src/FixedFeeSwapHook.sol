// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// External imports
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

// Internal imports
import {PrincipalToken} from "src/PrincipalToken.sol";
import {YieldToken} from "src/YieldToken.sol";
import {VaultShareToken} from "src/VaultShareToken.sol";

contract FixedFeeSwapHook is BaseHook {
  /*//////////////////////////////////////////////////////////////
                        ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when split is attempted after maturity is reached.
  error FixedFeeSwapHook_SplitAfterMaturity();

  /// @notice Thrown when deposit is attempted with an invalid amount.
  error FixedFeeSwapHook_InvalidAmount();

  /// @notice Thrown when split is attempted with an invalid maturity.
  error FixedFeeSwapHook_InvalidMaturity();

  /// @notice Thrown when split is attempted with an invalid manager.
  error FixedFeeSwapHook_InvalidManager();

  /// @notice Thrown when split is attempted with an invalid vault share token.
  error FixedFeeSwapHook_InvalidVaultShareToken();

  /// @notice Thrown when action is attempted with an insufficient balance.
  error FixedFeeSwapHook_InsufficientBalance();

  /*//////////////////////////////////////////////////////////////
                        EVENTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Emitted when the hook is initialized.
  /// @param poolManager The address of the pool manager.
  /// @param vaultShareToken The address of the vault share token.
  /// @param principalToken The address of the principal token.
  /// @param yieldToken The address of the yield token.
  /// @param maturity The maturity of the hook.
  event Initialized(
    address indexed poolManager,
    address vaultShareToken,
    address principalToken,
    address yieldToken,
    uint256 maturity
  );

  /// @notice Emitted when a user deposits their vault share token into principal and yield tokens.
  /// @param user The address of the user who deposited.
  /// @param vsAmount The amount of vault share token deposited.
  /// @param ptAmount The amount of principal token minted to the user.
  /// @param ytAmount The amount of yield token minted to the user.
  event Deposit(address indexed user, uint256 vsAmount, uint256 ptAmount, uint256 ytAmount);

  /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

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
  /// @param _manager The pool manager.
  /// @param _vaultShareToken The vault share token.
  /// @param _maturity The maturity of the hook.
  constructor(IPoolManager _manager, VaultShareToken _vaultShareToken, uint256 _maturity)
    BaseHook(_manager)
  {
    if (address(_manager) == address(0)) revert FixedFeeSwapHook_InvalidManager();
    if (address(_vaultShareToken) == address(0)) revert FixedFeeSwapHook_InvalidVaultShareToken();
    if (_maturity <= block.timestamp) revert FixedFeeSwapHook_InvalidMaturity();

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
      address(this)
    );

    MATURITY = _maturity;

    emit Initialized(
      address(_manager),
      address(_vaultShareToken),
      address(PRINCIPAL_TOKEN),
      address(YIELD_TOKEN),
      _maturity
    );
  }

  /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Returns the permissions for the hook.
  /// @dev This function is used to validate the hook address at deployment.
  function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
      beforeInitialize: false,
      afterInitialize: false,
      beforeAddLiquidity: false,
      afterAddLiquidity: false,
      beforeRemoveLiquidity: false,
      afterRemoveLiquidity: false,
      beforeSwap: false,
      afterSwap: false,
      beforeDonate: false,
      afterDonate: false,
      beforeSwapReturnDelta: false,
      afterSwapReturnDelta: false,
      afterAddLiquidityReturnDelta: false,
      afterRemoveLiquidityReturnDelta: false
    });
  }

  /// @notice Deposits the vault share token into principal and yield tokens.
  /// @param _amount The amount of vault share token to deposit.
  /// @return _ptAmount The amount of principal token minted.
  /// @return _ytAmount The amount of yield token minted.
  /// @dev The caller must have approved the hook to spend the vault share token.
  function deposit(uint256 _amount) external returns (uint256 _ptAmount, uint256 _ytAmount) {
    if (block.timestamp >= MATURITY) revert FixedFeeSwapHook_SplitAfterMaturity();

    if (_amount == 0) revert FixedFeeSwapHook_InvalidAmount();

    if (VAULT_SHARE_TOKEN.balanceOf(msg.sender) < _amount) {
      revert FixedFeeSwapHook_InsufficientBalance();
    }

    // Transfer VaultShareToken from caller to the hook
    VAULT_SHARE_TOKEN.transferFrom(msg.sender, address(this), _amount);

    // Split the vault share token into principal and yield tokens in a 1:1 ratio
    (_ptAmount, _ytAmount) = (_amount, _amount);

    // Mint PrincipalToken to the caller
    PRINCIPAL_TOKEN.mint(msg.sender, _ptAmount);

    // Mint YieldToken to the caller
    YIELD_TOKEN.mint(msg.sender, _ytAmount);

    emit Deposit(msg.sender, _amount, _ptAmount, _ytAmount);
  }
}
