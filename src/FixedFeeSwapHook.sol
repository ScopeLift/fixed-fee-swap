// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// External imports
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Internal imports
import {PrincipalToken} from "src/PrincipalToken.sol";
import {YieldToken} from "src/YieldToken.sol";
import {VaultShareToken} from "src/VaultShareToken.sol";
import {FeeTracking} from "src/lib/FeeTracking.sol";

contract FixedFeeSwapHook is BaseHook {
  using FeeTracking for FeeTracking.GlobalFees;
  using FeeTracking for FeeTracking.UserFees;
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

  /// @notice Emitted when maturity is checkpointed (one-time event).
  /// @param ytFinalIndex0 Final YT global fee index for token0 at maturity.
  /// @param ytFinalIndex1 Final YT global fee index for token1 at maturity.
  event MaturityCheckpointed(uint256 ytFinalIndex0, uint256 ytFinalIndex1);

  /// @notice Emitted when PT fee indexes are updated.
  /// @param newglobalFeeIndex0Scaled Updated global cumulative fee index for token0.
  /// @param newglobalFeeIndex1Scaled Updated global cumulative fee index for token1.
  /// @param collectedFeeToken0 Amount of token0 fees collected from the pool.
  /// @param collectedFeeToken1 Amount of token1 fees collected from the pool.
  event PTFeeIndexesUpdated(
    uint256 newglobalFeeIndex0Scaled,
    uint256 newglobalFeeIndex1Scaled,
    uint256 collectedFeeToken0,
    uint256 collectedFeeToken1
  );

  /// @notice Emitted when a user claims their accrued PT fees.
  /// @param user The address that claimed fees.
  /// @param token0Amount Amount of token0 fees claimed.
  /// @param token1Amount Amount of token1 fees claimed.
  event PTFeesClaimed(address indexed user, uint256 token0Amount, uint256 token1Amount);

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

  /// @notice Global fee tracking state for Principal Token.
  FeeTracking.GlobalFees private _ptGlobalFees;

  /// @notice Tracks fee accounting data per user for Principal Token.
  mapping(address => FeeTracking.UserFees) public ptUserFees;

  /// @notice The token address in which token0 fees are collected / distributed.
  /// @dev Use address(0) to represent native ETH following Uniswap v4 `Currency` convention.
  address private immutable FEE_TOKEN0;

  /// @notice The token address in which token1 fees are collected / distributed.
  /// @dev Use address(0) to represent native ETH following Uniswap v4 `Currency` convention.
  address private immutable FEE_TOKEN1;

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
    FEE_TOKEN0 = VAULT_SHARE_TOKEN.FEE_TOKEN0();
    FEE_TOKEN1 = VAULT_SHARE_TOKEN.FEE_TOKEN1();

    YIELD_TOKEN = new YieldToken(
      string.concat("Yield ", _underlyingName),
      string.concat("YT-", _underlyingSymbol, "-", _maturityStr),
      address(this),
      FEE_TOKEN0,
      FEE_TOKEN1
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
    if (_hasMaturityReached()) revert FixedFeeSwapHook_SplitAfterMaturity();

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

    bool _maturityReached = _hasMaturityReached();

    if (PRINCIPAL_TOKEN.balanceOf(msg.sender) < _amount) {
      revert FixedFeeSwapHook_InsufficientBalance();
    }

    // Before maturity: burn both PT and YT (1 PT + 1 YT = 1 VST)
    // At/after maturity: only burn PT (1 PT = 1 VST, YT is worthless)
    if (!_maturityReached) {
      if (YIELD_TOKEN.balanceOf(msg.sender) < _amount) {
        revert FixedFeeSwapHook_InsufficientBalance();
      }

      // Claim fees from YT and send to msg.sender
      YIELD_TOKEN.claim(msg.sender);
      YIELD_TOKEN.burn(msg.sender, _amount);

    } else {
      // After maturity: check if user has YT balance (they might not have redeemed before maturity)
      // If they do, burn YT and claim accrued YT fees (earned before maturity)
      uint256 _ytBalance = YIELD_TOKEN.balanceOf(msg.sender);
      if (_ytBalance > 0) {
        YIELD_TOKEN.claim(msg.sender);
        YIELD_TOKEN.burn(msg.sender, _ytBalance);
      }

      // Claim PT fees (earned after maturity)
      _claimPTFees(msg.sender);
    }

    // Burn PT tokens
    PRINCIPAL_TOKEN.burn(msg.sender, _amount);

    // Transfer VaultShareToken from the hook to the caller
    _vstAmount = _amount;
    VAULT_SHARE_TOKEN.transfer(msg.sender, _vstAmount);

    emit Redeem(msg.sender, _vstAmount, _maturityReached);
  }

  /// @notice Checkpoints maturity by recording YT's final global fee indexes.
  /// @dev This is a one-time operation that should be called when maturity is reached.
  ///      After checkpointing, fees will be routed to PT instead of YT.
  function checkpointMaturity() external {
    _checkpointMaturity();
  }

  /// @notice Updates the PT fee indexes when new fees are collected after maturity.
  /// @param _collectedFeeToken0 Newly collected token0 fees (delta since last call).
  /// @param _collectedFeeToken1 Newly collected token1 fees (delta since last call).
  /// @dev Can only be called after maturity has been checkpointed.
  ///      Routes fees to PT holders instead of YT holders.
  ///      Will automatically checkpoint maturity if not already done.
  function updatePTFees(uint256 _collectedFeeToken0, uint256 _collectedFeeToken1) external {
    if (!_hasMaturityReached()) revert FixedFeeSwapHook_InvalidMaturity();
    
    // Ensure maturity is checkpointed (can be done lazily on first fee update)
    // Check if PT indexes are initialized (non-zero means checkpointed)
    if (_ptGlobalFees.globalFeeIndex0Scaled == 0 && _ptGlobalFees.globalFeeIndex1Scaled == 0) {
      _checkpointMaturity();
    }

    _ptGlobalFees._updateFees(_collectedFeeToken0, _collectedFeeToken1, PRINCIPAL_TOKEN.totalSupply());

    emit PTFeeIndexesUpdated(
      _ptGlobalFees.globalFeeIndex0Scaled,
      _ptGlobalFees.globalFeeIndex1Scaled,
      _collectedFeeToken0,
      _collectedFeeToken1
    );
  }

  /// @notice Global cumulative fee index for PT token0.
  /// @dev Scaled by PRECISION. Only meaningful after maturity is checkpointed.
  function ptGlobalFeeIndex0Scaled() external view returns (uint256) {
    return _ptGlobalFees.globalFeeIndex0Scaled;
  }

  /// @notice Global cumulative fee index for PT token1.
  /// @dev Scaled by PRECISION. Only meaningful after maturity is checkpointed.
  function ptGlobalFeeIndex1Scaled() external view returns (uint256) {
    return _ptGlobalFees.globalFeeIndex1Scaled;
  }

  /// @notice Whether maturity has been checkpointed.
  /// @dev Derived by checking if PT global fee indexes have been initialized (non-zero).
  function maturityCheckpointed() external view returns (bool) {
    if (!_hasMaturityReached()) return false;
    return _ptGlobalFees.globalFeeIndex0Scaled > 0 || _ptGlobalFees.globalFeeIndex1Scaled > 0;
  }

  /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Checks if maturity has been reached.
  /// @return True if current timestamp is at or past maturity.
  function _hasMaturityReached() internal view returns (bool) {
    return block.timestamp >= MATURITY;
  }

  /// @notice Internal function to checkpoint maturity by recording YT's final global fee indexes.
  /// @dev This is a one-time operation that should be called when maturity is reached.
  ///      After checkpointing, fees will be routed to PT instead of YT.
  function _checkpointMaturity() internal {
    if (!_hasMaturityReached()) revert FixedFeeSwapHook_InvalidMaturity();
    
    // Check if already checkpointed by seeing if PT indexes have been initialized
    if (_ptGlobalFees.globalFeeIndex0Scaled > 0 || _ptGlobalFees.globalFeeIndex1Scaled > 0) {
      return; // Already checkpointed, no-op
    }

    // Record YT's final global fee indexes as the starting point for PT
    uint256 _ytFinalIndex0 = YIELD_TOKEN.globalFeeIndex0Scaled();
    uint256 _ytFinalIndex1 = YIELD_TOKEN.globalFeeIndex1Scaled();

    // Initialize PT global fees with YT's final indexes
    _ptGlobalFees.globalFeeIndex0Scaled = _ytFinalIndex0;
    _ptGlobalFees.globalFeeIndex1Scaled = _ytFinalIndex1;

    emit MaturityCheckpointed(_ytFinalIndex0, _ytFinalIndex1);
  }

  /// @notice Updates a user's accrued PT fees based on their current PT balance.
  /// @param _user The address to update fees for.
  /// @dev Should be called before burning PT to ensure accurate fee calculation.
  function _updatePTUserFees(address _user) internal {
    // Why this exists (example):
    // - You mint 100 PT + 100 YT before maturity.
    // - You transfer me 50 PT (PT transfers do NOT touch the hook).
    // - At maturity, PT fee tracking starts from a baseline (the frozen YT fee indexes).
    //
    // If neither of us has ever interacted with PT fee tracking before, our PT user checkpoints are 0.
    // Without initializing them, our first claim would accrue `currentPtIndex - 0`, which incorrectly
    // includes the baseline (pre-maturity history) even though PT rewards are meant to start at maturity.
    //
    // Fix: on first post-maturity PT interaction, set the user's PT checkpoint to the frozen YT indexes
    // so they only accrue from the maturity baseline forward.
    //
    // Why this is not sufficient (post-maturity transfer example):
    // - Maturity baseline is 100 (PT global index starts at 100).
    // - Alice holds 100 PT while PT index moves 100 -> 110 (Alice has earned fees for 100 -> 110).
    // - Alice transfers her 100 PT to Bob when the PT index is 110.
    //   IMPORTANT: this transfer happens inside the PT ERC20 and does NOT call into this hook, so we
    //   cannot sync Alice/Bob fee checkpoints at the moment of transfer.
    // - Later the PT index moves 110 -> 120 and then Bob claims.
    //   If Bob's checkpoint is still 100, his claim accrues 100 -> 120 (includes 100 -> 110 he did NOT hold).
    //   If Alice later claims with 0 PT, she accrues nothing and effectively loses 100 -> 110.
    //
    if (_hasMaturityReached()) {
      FeeTracking.UserFees storage _uf = ptUserFees[_user];
      if (_uf.userFeeIndex0Scaled == 0 && _uf.userFeeIndex1Scaled == 0) {
        _uf.userFeeIndex0Scaled = YIELD_TOKEN.globalFeeIndex0Scaled();
        _uf.userFeeIndex1Scaled = YIELD_TOKEN.globalFeeIndex1Scaled();
      }
    }

    uint256 _userBalance = PRINCIPAL_TOKEN.balanceOf(_user);
    ptUserFees[_user]._updateUserFees(
      _userBalance,
      _ptGlobalFees.globalFeeIndex0Scaled,
      _ptGlobalFees.globalFeeIndex1Scaled
    );
  }

  /// @notice Claims accrued PT fees for a user and transfers them.
  /// @param _user The address to claim fees for.
  /// @return _claimedToken0 Amount of token0 fees claimed.
  /// @return _claimedToken1 Amount of token1 fees claimed.
  function _claimPTFees(address _user) internal returns (uint256 _claimedToken0, uint256 _claimedToken1) {
    // Update user fees to ensure we're syncing to the latest global indices
    _updatePTUserFees(_user);

    // Get the accrued amounts before resetting
    (_claimedToken0, _claimedToken1) = ptUserFees[_user]._resetAccruedFees();

    // Emit event for transparency
    emit PTFeesClaimed(_user, _claimedToken0, _claimedToken1);

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
      if (!_success) revert FixedFeeSwapHook_TransferFailed();
    } else {
      SafeERC20.safeTransfer(IERC20(_token), _to, _amount);
    }
  }
}
