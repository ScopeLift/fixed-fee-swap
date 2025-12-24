// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// External imports
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Internal imports
import {PrincipalToken} from "src/PrincipalToken.sol";
import {YieldToken} from "src/YieldToken.sol";
import {VaultShareToken} from "src/VaultShareToken.sol";
import {FeeTracking} from "src/lib/FeeTracking.sol";

contract FixedFeeSwapHook is BaseHook {
  using SafeERC20 for IERC20;
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

  /// @notice Thrown when an action is attempted before maturity is reached.
  error FixedFeeSwapHook_BeforeMaturity();

  /// @notice Thrown when a transfer fails.
  error FixedFeeSwapHook_TransferFailed();

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

  /// @notice Emitted when a user redeems their principal and yield tokens back into the vault share
  /// token. @param user The address of the user who redeemed.
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

  /// @notice Emitted when the post-maturity fee indexes are updated.
  /// @param postMaturityFeeIndex0Scaled The post-maturity fee index for token0.
  /// @param postMaturityFeeIndex1Scaled The post-maturity fee index for token1.
  /// @param feeToken0 The amount of token0 fees collected.
  /// @param feeToken1 The amount of token1 fees collected.
  event FeeIndexesUpdated(
    uint256 postMaturityFeeIndex0Scaled,
    uint256 postMaturityFeeIndex1Scaled,
    uint256 feeToken0,
    uint256 feeToken1
  );

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

  /// @notice Post-maturity global cumulative fee index for token0 (scaled by PRECISION).
  /// @dev Represents "how much token0 each PT has earned" since maturity.
  uint256 public postMaturityFeeIndex0Scaled;

  /// @notice Post-maturity global cumulative fee index for token1 (scaled by PRECISION).
  /// @dev Represents "how much token1 each PT has earned" since maturity.
  uint256 public postMaturityFeeIndex1Scaled;

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
      address(this),
      VAULT_SHARE_TOKEN.FEE_TOKEN0(),
      VAULT_SHARE_TOKEN.FEE_TOKEN1()
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
      afterSwap: true,
      beforeDonate: false,
      afterDonate: true,
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

  /// @notice Redeems the principal and yield tokens back into the vault share token.
  /// @param _amount The amount of principal and yield tokens to redeem.
  /// @return _vstAmount The amount of vault share token redeemed.
  /// @dev
  ///  - The caller must have approved the hook to spend the PT and YT tokens.
  ///  - If called before maturity, the caller must have at least `_amount` PT and YT tokens.
  ///  - If called at/after maturity, the caller must have at least `_amount` PT tokens.
  ///  - Note:
  ///    - Before maturity, the YT will be non-zero, so 1 PT + 1 YT = 1 VST.
  ///    - At maturity, the YT will be 0, so 1 PT = 1 VST.
  function redeem(uint256 _amount) external returns (uint256 _vstAmount) {
    if (_amount == 0) revert FixedFeeSwapHook_InvalidAmount();

    // Caller should always have enough PT tokens
    if (PRINCIPAL_TOKEN.balanceOf(msg.sender) < _amount) {
      revert FixedFeeSwapHook_InsufficientBalance();
    }

    bool _maturityReached = block.timestamp >= MATURITY;

    if (!_maturityReached) {
      // -------- BEFORE MATURITY ( needs both PT and YT) --------
      _claimAndBurnYieldTokens(msg.sender, _amount);
    } else {
      // -------- AFTER MATURITY --------
      _claimFeesAccruedAfterMaturity(msg.sender, _amount);
    }

    // Burn PT tokens (always required)
    PRINCIPAL_TOKEN.burn(msg.sender, _amount);

    // Transfer VaultShareToken from the hook to the caller
    _vstAmount = _amount;
    if (VAULT_SHARE_TOKEN.balanceOf(address(this)) < _vstAmount) {
      revert FixedFeeSwapHook_InsufficientBalance();
    }

    VAULT_SHARE_TOKEN.transfer(msg.sender, _vstAmount);

    emit Redeem(msg.sender, _vstAmount, _maturityReached);
  }

  /// @notice Claims fees and burns leftover yield tokens after maturity.
  /// @return _claimedToken0 Amount of token0 fees claimed.
  /// @return _claimedToken1 Amount of token1 fees claimed.
  /// @dev
  ///  - Can only be called after maturity.
  ///  - Claims any fees accrued on the YT tokens before maturity.
  ///  - Burns the YT tokens after claiming fees.
  ///  - Useful for users who have leftover YT tokens after maturity.
  function claimYTFeesAfterMaturity()
    external
    returns (uint256 _claimedToken0, uint256 _claimedToken1)
  {
    if (block.timestamp < MATURITY) revert FixedFeeSwapHook_BeforeMaturity();

    uint256 _amount = YIELD_TOKEN.balanceOf(msg.sender);

    if (_amount == 0) revert FixedFeeSwapHook_InsufficientBalance();

    (_claimedToken0, _claimedToken1) = _claimAndBurnYieldTokens(msg.sender, _amount);
  }

  /*//////////////////////////////////////////////////////////////
                        UNISWAP V4 HOOK FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Called by the PoolManager after a swap has been executed and settled.
  /// @dev
  ///  - At this point, all swap fees have been finalized.
  ///  - Any positive balance delta represents fees received by this hook.
  ///  - These fees are routed through `_updateFees`, which:
  ///   - Sends fees to the YieldToken before maturity
  ///   - Accumulates fees into the post-maturity PT fee index after maturity
  ///  - Negative deltas are ignored, as they represent amounts paid out by the hook.
  function _afterSwap(
    address,
    PoolKey calldata,
    SwapParams calldata,
    BalanceDelta delta,
    bytes calldata
  ) internal override returns (bytes4, int128) {
    int128 _delta0 = delta.amount0();
    int128 _delta1 = delta.amount1();

    uint256 _fee0 = _delta0 > 0 ? uint256(uint128(_delta0)) : 0;
    uint256 _fee1 = _delta1 > 0 ? uint256(uint128(_delta1)) : 0;

    if (_fee0 > 0 || _fee1 > 0) _updateFees(_fee0, _fee1);
    return (this.afterSwap.selector, 0);
  }

  /// @notice Called by the PoolManager after a donation is made to the pool.
  /// @dev
  ///  - Donations are explicit fee-like transfers and are treated identically
  ///    to swap fees for accounting purposes.
  ///  - Donated amounts are routed through `_updateFees`, which applies
  ///    maturity-based fee routing logic.
  ///  - This hook does not distinguish between swap fees and donations;
  ///    both contribute to protocol fee distribution.
  function _afterDonate(
    address,
    PoolKey calldata,
    uint256 _amount0,
    uint256 _amount1,
    bytes calldata
  ) internal override returns (bytes4) {
    if (_amount0 > 0 || _amount1 > 0) _updateFees(_amount0, _amount1);

    return this.afterDonate.selector;
  }

  /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Called by hook to update the fees for the yield token or the post-maturity fee index.
  /// @param fee0 The amount of token0 fees collected.
  /// @param fee1 The amount of token1 fees collected.
  /// @dev
  ///  - If called before maturity, the fees are routed to the yield token.
  ///  - If called after maturity, the fees are routed to the post-maturity fee index.
  function _updateFees(uint256 fee0, uint256 fee1) internal {
    if (block.timestamp < MATURITY) {
      // Pre-maturity → YT owns fees
      YIELD_TOKEN.updateFees(fee0, fee1);
    } else {
      // Post-maturity → Hook owns fees
      _updatePostMaturityFeeIndex(fee0, fee1);
    }
  }

  /// @notice Updates the post-maturity fee index.
  /// @param feeToken0 The amount of token0 fees collected.
  /// @param feeToken1 The amount of token1 fees collected.
  /// @dev
  ///  - Updates the post-maturity fee index for token0 and token1.
  ///  - postMaturityFeeIndex0Scaled is scaled by PRECISION (like FeeTracking's
  /// globalFeeIndex0Scaled).
  ///  - Formula: fees = (feeIndex * amount) / PRECISION
  function _updatePostMaturityFeeIndex(uint256 feeToken0, uint256 feeToken1) internal {
    uint256 totalPT = PRINCIPAL_TOKEN.totalSupply();
    if (totalPT == 0) return;

    if (feeToken0 > 0) {
      postMaturityFeeIndex0Scaled += Math.mulDiv(
        feeToken0, FeeTracking.PRECISION, totalPT, Math.Rounding.Floor
      );
    }

    if (feeToken1 > 0) {
      postMaturityFeeIndex1Scaled += Math.mulDiv(
        feeToken1, FeeTracking.PRECISION, totalPT, Math.Rounding.Floor
      );
    }

    emit FeeIndexesUpdated(
      postMaturityFeeIndex0Scaled, postMaturityFeeIndex1Scaled, feeToken0, feeToken1
    );
  }

  /// @notice Claims fees and burns YT tokens
  /// @param _user The address to claim fees from and burn YT tokens for.
  /// @param _amount The amount of YT tokens to claim fees from and burn.
  /// @return _claimedToken0 Amount of token0 fees claimed.
  /// @return _claimedToken1 Amount of token1 fees claimed.
  /// @dev
  ///  - Claims fees from the YT tokens.
  ///  - Burns the YT tokens after claiming fees.
  function _claimAndBurnYieldTokens(address _user, uint256 _amount)
    internal
    returns (uint256 _claimedToken0, uint256 _claimedToken1)
  {
    // Caller should have enough YT tokens
    if (YIELD_TOKEN.balanceOf(_user) < _amount) revert FixedFeeSwapHook_InsufficientBalance();

    // Claim fees from YT
    (_claimedToken0, _claimedToken1) = YIELD_TOKEN.claim(_user);

    // Burn YT tokens
    YIELD_TOKEN.burn(_user, _amount);
  }

  /// @notice Claims post-maturity fees accrued for a user based on their PT amount.
  /// @param _user The address to claim fees for.
  /// @param _amount The amount of PT tokens being redeemed.
  /// @dev
  ///  - Calculates fees based on postMaturityFeeIndex0Scaled and postMaturityFeeIndex1Scaled.
  ///  - postMaturityFeeIndex0Scaled is scaled by PRECISION (like FeeTracking's
  /// globalFeeIndex0Scaled).
  ///  - Formula: fees = (feeIndex * amount) / PRECISION
  function _claimFeesAccruedAfterMaturity(address _user, uint256 _amount) internal {
    // Calculate post-maturity fees claimable for the redeemed amount
    uint256 _postMaturityFeeToken0 =
      Math.mulDiv(postMaturityFeeIndex0Scaled, _amount, FeeTracking.PRECISION, Math.Rounding.Floor);
    uint256 _postMaturityFeeToken1 =
      Math.mulDiv(postMaturityFeeIndex1Scaled, _amount, FeeTracking.PRECISION, Math.Rounding.Floor);

    // Transfer post-maturity fees to the user
    if (_postMaturityFeeToken0 > 0) {
      _transferFeeToken(VAULT_SHARE_TOKEN.FEE_TOKEN0(), _user, _postMaturityFeeToken0);
    }
    if (_postMaturityFeeToken1 > 0) {
      _transferFeeToken(VAULT_SHARE_TOKEN.FEE_TOKEN1(), _user, _postMaturityFeeToken1);
    }

    emit FeesClaimed(
      _user,
      VAULT_SHARE_TOKEN.FEE_TOKEN0(),
      VAULT_SHARE_TOKEN.FEE_TOKEN1(),
      _postMaturityFeeToken0,
      _postMaturityFeeToken1
    );
  }

  /// @notice Transfers an amount of fee tokens to a user.
  /// @param _token The address of the token to transfer.
  /// @param _to The address to transfer the tokens to.
  /// @param _amount The amount of tokens to transfer.
  /// @dev Following Uniswap v4's convention: address(0) represents native ETH.
  function _transferFeeToken(address _token, address _to, uint256 _amount) internal {
    if (_token == address(0)) {
      (bool _success,) = payable(_to).call{value: _amount}("");
      if (!_success) revert FixedFeeSwapHook_TransferFailed();
    } else {
      IERC20(_token).safeTransfer(_to, _amount);
    }
  }
}
