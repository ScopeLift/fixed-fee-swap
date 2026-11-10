// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCallback} from "v4-periphery/src/base/SafeCallback.sol";
import {DeltaResolver} from "v4-periphery/src/base/DeltaResolver.sol";
import {SlippageCheck} from "v4-periphery/src/libraries/SlippageCheck.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VaultShareToken} from "src/VaultShareToken.sol";

/// @title LPVault
/// @author [ScopeLift](https://scopelift.co)
/// @notice A contract that wraps a set of static LP positions in a single Uniswap v4 pool.
/// @dev Positions and their weight distributions are fixed at contract creation.
contract LPVault is VaultShareToken, SafeCallback, DeltaResolver {
  using PoolIdLibrary for PoolKey;
  using StateLibrary for IPoolManager;
  using SafeCast for uint256;
  using SafeCast for int256;
  using SafeERC20 for IERC20;

  /// @notice Structure for liquidity position configuration.
  /// @dev Packed into a single storage slot (24 bytes total).
  struct LiquidityPosition {
    /// @notice The lower tick boundary for this position.
    int24 tickLower;
    /// @notice The upper tick boundary for this position.
    int24 tickUpper;
    /// @notice The weight of liquidity allocated to this position in basis points (BIPs).
    /// @dev Must be between 0 and 10,000. All position weights must sum to exactly 10,000.
    uint16 weight;
    /// @notice The current liquidity held in this position.
    uint128 liquidity;
  }

  /// @notice Stores the last-seen fee growth values from Uniswap v4 for a position.
  struct PositionCheckpoint {
    uint256 feeGrowthInside0LastX128;
    uint256 feeGrowthInside1LastX128;
  }

  /// @notice Enum to distinguish callback actions.
  enum CallbackAction {
    Deposit,
    Withdraw,
    CollectFees
  }

  /// @notice Struct for passing deposit callback data.
  struct DepositCallbackData {
    address sender;
    uint256 amount0Max;
    uint256 amount1Max;
    uint128[] liquidityPerPosition;
  }

  /// @notice Struct for passing withdraw callback data.
  struct WithdrawCallbackData {
    address receiver;
    uint128[] liquidityToRemove;
  }

  /// @notice Total weight must equal 10,000 BIPs (100%).
  uint16 public constant BIPS = 10_000;

  /// @notice Reference liquidity unit for value calculations.
  uint256 public constant WAD = 1e18;

  /// @notice Q96 fixed-point scale factor.
  uint256 internal constant Q96 = 1 << 96;

  /// @notice The Uniswap v4 PoolManager.
  IPoolManager public immutable POOL_MANAGER;

  /// @notice The token0 in the target pool.
  address public immutable TOKEN0;

  /// @notice The token1 in the target pool.
  address public immutable TOKEN1;

  /// @notice The maximum total value in token1 equivalent for initial liquidity.
  uint256 public immutable INIT_MAX_VALUE;

  /// @notice The target pool that this vault manages liquidity for.
  PoolKey public targetPoolKey;

  /// @notice The predefined liquidity positions for this vault.
  LiquidityPosition[] public positions;

  /// @notice Fee growth checkpoints for each configured liquidity position.
  /// @dev Indexed by position index in `positions`.
  mapping(uint256 => PositionCheckpoint) internal positionCheckpoints;

  /// @notice Whether liquidity has been initialized.
  bool public liquidityInitialized;

  /// @notice Thrown when the sum of position weights doesn't equal BIPS (10,000 BIPs).
  error LPVault__InvalidLiquidityDistribution();

  /// @notice Thrown when a position's tickLower is greater than or equal to tickUpper.
  error LPVault__InvalidTickRange();

  /// @notice Thrown when no positions are provided during initialization.
  error LPVault__NoPositions();

  /// @notice Thrown when the total liquidity is zero.
  error LPVault__ZeroLiquidity();

  /// @notice Thrown when the shares amount is invalid (zero or exceeds balance).
  error LPVault__InvalidShares();

  /// @notice Thrown when liquidity has already been initialized.
  error LPVault__AlreadyInitialized();

  /// @notice Thrown when attempting deposit before initialization.
  error LPVault__NotInitialized();

  /// @notice Thrown when INIT_MAX_VALUE constructor parameter is zero.
  error LPVault__ZeroValue();

  /// @notice Thrown when caller's amounts exceed the max value constraint.
  error LPVault__ExceedsMaxValue();

  /// @notice Emitted when the pool manager is set during construction.
  /// @param poolManager The address of the Uniswap v4 pool manager.
  event PoolManagerSet(address indexed poolManager);

  /// @notice Emitted when a deposit is made.
  /// @param depositor The address that deposited and received shares.
  /// @param shares The amount of vault shares minted.
  /// @param amount0 The amount of token0 deposited.
  /// @param amount1 The amount of token1 deposited.
  event Deposited(address indexed depositor, uint256 shares, uint256 amount0, uint256 amount1);

  /// @notice Emitted when a withdrawal is made.
  /// @param withdrawer The address that burned shares.
  /// @param receiver The address that received the tokens.
  /// @param shares The amount of vault shares burned.
  /// @param amount0 The amount of token0 withdrawn.
  /// @param amount1 The amount of token1 withdrawn.
  event Withdraw(
    address indexed withdrawer,
    address indexed receiver,
    uint256 shares,
    uint256 amount0,
    uint256 amount1
  );

  /// @notice Emitted when fees are collected from all positions.
  /// @param collectedFee0 The amount of token0 fees collected.
  /// @param collectedFee1 The amount of token1 fees collected.
  event FeesCollected(uint256 collectedFee0, uint256 collectedFee1);

  /// @notice Creates a new LP Vault with fixed positions.
  /// @dev IMPORTANT: Call initializeLiquidity() immediately after deployment to prevent
  /// griefing attacks. The pool's current price is used for all calculations.
  /// @param _poolManager The Uniswap v4 pool manager.
  /// @param _targetPoolKey The pool where liquidity is deposited.
  /// @param _positions Array of positions with tick ranges and weights (must sum to 10,000 BIPs).
  /// @param _name The name of the vault share token.
  /// @param _symbol The symbol of the vault share token.
  /// @param _initMaxValue Maximum total value in token1 equivalent.
  constructor(
    IPoolManager _poolManager,
    PoolKey memory _targetPoolKey,
    LiquidityPosition[] memory _positions,
    string memory _name,
    string memory _symbol,
    uint256 _initMaxValue
  )
    VaultShareToken(
      _name,
      _symbol,
      Currency.unwrap(_targetPoolKey.currency0),
      Currency.unwrap(_targetPoolKey.currency1)
    )
    SafeCallback(_poolManager)
  {
    if (_initMaxValue == 0) revert LPVault__ZeroValue();

    POOL_MANAGER = _poolManager;
    emit PoolManagerSet(address(_poolManager));

    targetPoolKey = _targetPoolKey;
    TOKEN0 = Currency.unwrap(_targetPoolKey.currency0);
    TOKEN1 = Currency.unwrap(_targetPoolKey.currency1);
    INIT_MAX_VALUE = _initMaxValue;

    _initializePositions(_positions);
  }

  /// @notice Initializes and validates the liquidity positions for the vault.
  /// @dev Validates that positions have valid tick ranges and weights sum to `BIPS`.
  /// @param _positions Array of liquidity positions to initialize.
  function _initializePositions(LiquidityPosition[] memory _positions) internal virtual {
    // Ensure at least one position is provided.
    if (_positions.length == 0) revert LPVault__NoPositions();

    // Validate positions and calculate total weight.
    uint256 _totalWeight = 0;
    for (uint256 _i = 0; _i < _positions.length; _i++) {
      if (_positions[_i].tickLower >= _positions[_i].tickUpper) {
        revert LPVault__InvalidTickRange();
      }
      positions.push(_positions[_i]);
      _totalWeight += _positions[_i].weight;
    }

    // Ensure weights sum to exactly 100% (10,000 BIPs).
    if (_totalWeight != BIPS) revert LPVault__InvalidLiquidityDistribution();
  }

  /// @notice Initializes liquidity for all positions based on configured weights. Can only be
  /// called once. Uses the pool's current price and INIT_MAX_VALUE to calculate liquidity
  /// distribution by weight.
  /// @param _amount0Max The maximum amount of token0 the caller is willing to provide.
  /// @param _amount1Max The maximum amount of token1 the caller is willing to provide.
  /// @return _shares The amount of vault shares minted.
  /// @return _amount0Used The actual amount of token0 used.
  /// @return _amount1Used The actual amount of token1 used.
  function initializeLiquidity(uint256 _amount0Max, uint256 _amount1Max)
    external
    virtual
    returns (uint256 _shares, uint256 _amount0Used, uint256 _amount1Used)
  {
    if (liquidityInitialized) revert LPVault__AlreadyInitialized();

    // Fetch current pool price for value constraint check and liquidity calculation.
    // NOTE: Price is read outside the unlock callback, so it may be stale by the time
    // modifyLiquidity executes. The SlippageCheck in _addLiquidityToPositions provides
    // the actual protection; this is a best-effort cap.
    (uint160 _sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(targetPoolKey.toId());

    // Check value constraint: convert amount0 to token1 value and verify total <= INIT_MAX_VALUE.
    uint256 _amount0AsValue1 = _amount0ToValue1(_amount0Max, _sqrtPriceX96);
    uint256 _totalValue = _amount0AsValue1 + _amount1Max;
    if (_totalValue > INIT_MAX_VALUE) revert LPVault__ExceedsMaxValue();

    // Sync checkpoints before first liquidity add so pre-existing pool fees are not attributed.
    _syncFees();

    (uint128[] memory _liquidityPerPosition, uint128 _liquidity0) =
      _calculateInitialLiquidity(_sqrtPriceX96);

    bytes memory _result = POOL_MANAGER.unlock(
      abi.encode(
        CallbackAction.Deposit,
        abi.encode(
          DepositCallbackData({
            sender: msg.sender,
            amount0Max: _amount0Max,
            amount1Max: _amount1Max,
            liquidityPerPosition: _liquidityPerPosition
          })
        )
      )
    );

    (_amount0Used, _amount1Used) = abi.decode(_result, (uint256, uint256));

    // Update position liquidity tracking
    for (uint256 _i = 0; _i < _liquidityPerPosition.length; _i++) {
      positions[_i].liquidity = _liquidityPerPosition[_i];
    }

    // Mint shares equal to position0's liquidity
    _shares = uint256(_liquidity0);
    _mint(msg.sender, _shares);

    liquidityInitialized = true;

    emit Deposited(msg.sender, _shares, _amount0Used, _amount1Used);
  }

  /// @notice Deposits tokens into the vault by specifying desired position0 liquidity.
  /// @param _amount0Max The maximum amount of token0 to deposit across all positions.
  /// @param _amount1Max The maximum amount of token1 to deposit across all positions.
  /// @param _liquidity The liquidity to add to position0. Other positions calculated
  /// proportionally.
  /// @dev Requires liquidity to be initialized first via initializeLiquidity().
  /// @return _shares The amount of vault shares minted (equal to _liquidity).
  /// @return _amount0Used The actual amount of token0 used.
  /// @return _amount1Used The actual amount of token1 used.
  function deposit(uint256 _amount0Max, uint256 _amount1Max, uint128 _liquidity)
    external
    virtual
    returns (uint256 _shares, uint256 _amount0Used, uint256 _amount1Used)
  {
    if (!liquidityInitialized) revert LPVault__NotInitialized();
    if (_liquidity == 0) revert LPVault__ZeroLiquidity();

    // Sync fee accounting using the current liquidity configuration before changing it.
    _syncFees();

    // Calculate liquidity for each position based on current ratios
    uint128[] memory _liquidityPerPosition = new uint128[](positions.length);
    uint128 _position0Liquidity = positions[0].liquidity;

    for (uint256 _i = 0; _i < positions.length; _i++) {
      if (_i == 0) {
        _liquidityPerPosition[0] = _liquidity;
      } else {
        // positionN.liquidity / position0.liquidity * requested_liquidity
        _liquidityPerPosition[_i] =
          FullMath.mulDiv(_liquidity, positions[_i].liquidity, _position0Liquidity).toUint128();
      }
    }

    bytes memory _result = POOL_MANAGER.unlock(
      abi.encode(
        CallbackAction.Deposit,
        abi.encode(
          DepositCallbackData({
            sender: msg.sender,
            amount0Max: _amount0Max,
            amount1Max: _amount1Max,
            liquidityPerPosition: _liquidityPerPosition
          })
        )
      )
    );

    (_amount0Used, _amount1Used) = abi.decode(_result, (uint256, uint256));

    // Update per-position liquidity.
    for (uint256 _i = 0; _i < _liquidityPerPosition.length; _i++) {
      positions[_i].liquidity += _liquidityPerPosition[_i];
    }

    // Mint shares equal to position0's liquidity added
    _shares = uint256(_liquidity);
    _mint(msg.sender, _shares);

    emit Deposited(msg.sender, _shares, _amount0Used, _amount1Used);
  }

  /// @notice Withdraws tokens from the vault by burning shares.
  /// @param _shares The amount of vault shares to burn.
  /// @param _receiver The address to receive the withdrawn tokens.
  /// @return _amount0 The amount of token0 received.
  /// @return _amount1 The amount of token1 received.
  function withdraw(uint256 _shares, address _receiver)
    external
    virtual
    returns (uint256 _amount0, uint256 _amount1)
  {
    if (_shares == 0 || _shares > balanceOf(msg.sender)) revert LPVault__InvalidShares();

    // Sync fee accounting using the current liquidity configuration before changing it.
    _syncFees();

    // Calculate liquidity to remove from each position proportionally and update liquidity.
    uint128[] memory _liquidityToRemove = new uint128[](positions.length);

    // Calculate liquidity to remove from each position.
    // Position 0 uses shares directly (1:1 mapping), while other positions
    // are calculated proportionally based on their liquidity relative to position0's liquidity.
    uint128 _position0Liquidity = positions[0].liquidity;
    for (uint256 _i = 0; _i < positions.length; _i++) {
      if (_i == 0) {
        _liquidityToRemove[0] = uint128(_shares);
      } else {
        _liquidityToRemove[_i] =
          FullMath.mulDiv(_shares, positions[_i].liquidity, _position0Liquidity).toUint128();
      }
      positions[_i].liquidity -= _liquidityToRemove[_i];
    }

    // If all shares are burned, reset initialization to allow re-initialization.
    // Using totalSupply (checked after burn below) would require reordering; position0.liquidity
    // is equivalent since shares == position0.liquidity is a maintained invariant.
    if (positions[0].liquidity == 0) liquidityInitialized = false;

    // Burn shares before making external calls (reentrancy protection).
    _burn(msg.sender, _shares);

    bytes memory _result = POOL_MANAGER.unlock(
      abi.encode(
        CallbackAction.Withdraw,
        abi.encode(
          WithdrawCallbackData({receiver: _receiver, liquidityToRemove: _liquidityToRemove})
        )
      )
    );

    (_amount0, _amount1) = abi.decode(_result, (uint256, uint256));

    emit Withdraw(msg.sender, _receiver, _shares, _amount0, _amount1);
  }

  /// @notice Collects accumulated fees from all positions without modifying liquidity.
  /// @dev Callable by anyone. Fees are kept in the vault and distributed to share holders.
  /// @return _collectedFee0 The amount of token0 fees collected.
  /// @return _collectedFee1 The amount of token1 fees collected.
  function collectFees() external virtual returns (uint256 _collectedFee0, uint256 _collectedFee1) {
    (_collectedFee0, _collectedFee1) = _collectFees();
  }

  /// @inheritdoc VaultShareToken
  /// @dev Callable by anyone. Updates the fee indexes from the positions' fee growth without
  /// collecting tokens from the pool, so it works while the PoolManager is unlocked.
  function syncFees() external override {
    _syncFees();
  }

  /// @inheritdoc SafeCallback
  function _unlockCallback(bytes calldata _data) internal virtual override returns (bytes memory) {
    (CallbackAction _action, bytes memory _actionData) = abi.decode(_data, (CallbackAction, bytes));

    if (_action == CallbackAction.Deposit) return _handleDepositCallback(_actionData);
    if (_action == CallbackAction.Withdraw) return _handleWithdrawCallback(_actionData);
    return _handleCollectFeesCallback();
  }

  /// @notice Records the positions' fees in the fee indexes and moves them from the pool into the
  /// vault.
  /// @return _collectedFee0 The amount of token0 fees collected.
  /// @return _collectedFee1 The amount of token1 fees collected.
  /// @dev While the PoolManager is already unlocked, collects inside that unlock instead of
  /// unlocking again; the vault's own deltas net to zero either way.
  function _collectFees() internal returns (uint256 _collectedFee0, uint256 _collectedFee1) {
    // Sync fee accounting before physically collecting tokens from the pool.
    _syncFees();

    bytes memory _result = TransientStateLibrary.isUnlocked(POOL_MANAGER)
      ? _handleCollectFeesCallback()
      : POOL_MANAGER.unlock(abi.encode(CallbackAction.CollectFees, abi.encode("")));

    (_collectedFee0, _collectedFee1) = abi.decode(_result, (uint256, uint256));

    emit FeesCollected(_collectedFee0, _collectedFee1);
  }

  /// @inheritdoc VaultShareToken
  /// @dev Collects the positions' fees from the pool first. Syncing the fee indexes counts fees
  /// still in the PoolManager, so without collecting, the vault could be paying a claim with tokens
  /// it doesn't hold yet.
  function _claim(address _user)
    internal
    override
    returns (uint256 _claimedToken0, uint256 _claimedToken1)
  {
    _collectFees();
    (_claimedToken0, _claimedToken1) = super._claim(_user);
  }

  /// @inheritdoc VaultShareToken
  /// @dev Ensures fee accounting is synced before any vault share mint/burn/transfer by
  /// checkpointing fees against the underlying Uniswap v4 positions.
  function _update(address _from, address _to, uint256 _value) internal override {
    _syncFees();
    super._update(_from, _to, _value);
  }

  /// @notice Handles the deposit callback logic.
  /// @param _actionData The encoded deposit callback data.
  /// @return The encoded result containing amounts used.
  function _handleDepositCallback(bytes memory _actionData)
    internal
    virtual
    returns (bytes memory)
  {
    DepositCallbackData memory _callbackData = abi.decode(_actionData, (DepositCallbackData));

    (int256 _totalDelta0, int256 _totalDelta1, int256 _totalFeeDelta0, int256 _totalFeeDelta1) = _addLiquidityToPositions(
      _callbackData.liquidityPerPosition, _callbackData.amount0Max, _callbackData.amount1Max
    );

    (uint256 _amount0Used, uint256 _amount1Used) =
      _settleDeltas(_totalDelta0, _totalDelta1, _callbackData.sender);

    // Collect fee tokens from the pool. Fee-per-share indexes are updated separately
    // by _syncFees() (called before unlock and in _update on mint/burn/transfer).
    _collectFees(_totalFeeDelta0, _totalFeeDelta1);

    return abi.encode(_amount0Used, _amount1Used);
  }

  /// @notice Handles the withdraw callback logic.
  /// @param _actionData The encoded withdraw callback data.
  /// @return The encoded result containing amounts received.
  function _handleWithdrawCallback(bytes memory _actionData)
    internal
    virtual
    returns (bytes memory)
  {
    WithdrawCallbackData memory _callbackData = abi.decode(_actionData, (WithdrawCallbackData));

    (int256 _totalDelta0, int256 _totalDelta1, int256 _totalFeeDelta0, int256 _totalFeeDelta1) =
      _removeLiquidityFromPositions(_callbackData.liquidityToRemove);

    (uint256 _amount0Received, uint256 _amount1Received) =
      _settleWithdrawDeltas(_totalDelta0, _totalDelta1, _callbackData.receiver);

    // Collect fee tokens from the pool. Fee-per-share indexes are updated separately
    // by _syncFees() (called before unlock and in _update on mint/burn/transfer).
    _collectFees(_totalFeeDelta0, _totalFeeDelta1);

    return abi.encode(_amount0Received, _amount1Received);
  }

  /// @notice Handles the collect fees callback logic.
  /// @return The encoded result containing fee amounts collected.
  function _handleCollectFeesCallback() internal virtual returns (bytes memory) {
    (int256 _totalFeeDelta0, int256 _totalFeeDelta1) = _collectFeesFromPositions();

    uint256 _collectedFee0;
    uint256 _collectedFee1;

    if (_totalFeeDelta0 > 0) {
      _collectedFee0 = uint256(_totalFeeDelta0);
      POOL_MANAGER.take(targetPoolKey.currency0, address(this), _collectedFee0);
    }
    if (_totalFeeDelta1 > 0) {
      _collectedFee1 = uint256(_totalFeeDelta1);
      POOL_MANAGER.take(targetPoolKey.currency1, address(this), _collectedFee1);
    }

    return abi.encode(_collectedFee0, _collectedFee1);
  }

  /// @notice Collects fees from all positions without modifying liquidity.
  /// @return _totalFeeDelta0 The total fee delta for token0 (positive = fees earned).
  /// @return _totalFeeDelta1 The total fee delta for token1 (positive = fees earned).
  function _collectFeesFromPositions()
    internal
    virtual
    returns (int256 _totalFeeDelta0, int256 _totalFeeDelta1)
  {
    for (uint256 _i = 0; _i < positions.length; _i++) {
      LiquidityPosition memory _position = positions[_i];
      // An empty position has no fees to collect, and v4 rejects a zero change to it.
      if (_position.liquidity == 0) continue;

      (, BalanceDelta _feeDelta) = POOL_MANAGER.modifyLiquidity(
        targetPoolKey,
        ModifyLiquidityParams({
          tickLower: _position.tickLower,
          tickUpper: _position.tickUpper,
          liquidityDelta: 0,
          salt: bytes32(0)
        }),
        ""
      );

      _totalFeeDelta0 += _feeDelta.amount0();
      _totalFeeDelta1 += _feeDelta.amount1();
    }
  }

  /// @notice Calculates initial per-position liquidity based on weights and INIT_MAX_VALUE.
  /// @dev Splits INIT_MAX_VALUE by weight per position and calculates liquidity from each
  /// position's value using the pool's current price.
  /// @return _liquidityPerPosition Array of liquidity amounts for each position.
  /// @return _liquidity0 The liquidity assigned to position0.
  function _calculateInitialLiquidity(uint160 _sqrtPriceX96)
    internal
    view
    returns (uint128[] memory _liquidityPerPosition, uint128 _liquidity0)
  {
    _liquidityPerPosition = new uint128[](positions.length);

    for (uint256 _i = 0; _i < positions.length; _i++) {
      LiquidityPosition memory _position = positions[_i];

      // Calculate value for this position based on weight
      uint256 _positionValue = FullMath.mulDiv(INIT_MAX_VALUE, _position.weight, BIPS);

      // Calculate liquidity from this position's value using current pool price
      uint128 _liquidity = _calculateLiquidityFromValue(_position, _positionValue, _sqrtPriceX96);

      _liquidityPerPosition[_i] = _liquidity;
      if (_i == 0) _liquidity0 = _liquidity;
    }

    if (_liquidity0 == 0) revert LPVault__ZeroLiquidity();
  }

  /// @notice Calculates liquidity for a position given a token1-equivalent value.
  /// @dev This is the inverse of _getAmountsForLiquidity. Given a value in token1 terms,
  /// it calculates how much liquidity can be added to the position.
  /// @param _position The liquidity position.
  /// @param _value The token1-equivalent value to convert to liquidity.
  /// @param _sqrtPriceX96 The sqrt price to use for calculation.
  /// @return _liquidity The calculated liquidity amount.
  function _calculateLiquidityFromValue(
    LiquidityPosition memory _position,
    uint256 _value,
    uint160 _sqrtPriceX96
  ) internal pure returns (uint128 _liquidity) {
    if (_value == 0) return 0;

    // Calculate value per unit liquidity using a reference liquidity
    (uint256 _amount0Ref, uint256 _amount1Ref) =
      _getAmountsForLiquidity(_position, _sqrtPriceX96, uint128(WAD));

    // Convert amount0 to token1 value at current price.
    uint256 _amount0RefAsValue1 = _amount0ToValue1(_amount0Ref, _sqrtPriceX96);

    // Total value per unit reference liquidity
    uint256 _valuePerRefLiquidity = _amount0RefAsValue1 + _amount1Ref;

    if (_valuePerRefLiquidity == 0) return 0;

    // Calculate liquidity: liquidity = value * reference / valuePerRef
    uint256 _liquidityFull = FullMath.mulDiv(_value, WAD, _valuePerRefLiquidity);

    _liquidity = _liquidityFull.toUint128();
  }

  /// @notice Returns the maximum amounts that can be used for initialization.
  /// @dev Uses current pool price. Values may change as price fluctuates.
  /// @return _maxAmount0 Maximum token0 amount if only token0 is used.
  /// @return _maxAmount1 Maximum token1 amount (equals INIT_MAX_VALUE).
  function getMaxInitAmounts() external view returns (uint256 _maxAmount0, uint256 _maxAmount1) {
    (uint160 _sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(targetPoolKey.toId());

    _maxAmount1 = INIT_MAX_VALUE;
    // Convert max value from token1 to token0 at current price.
    _maxAmount0 = _value1ToAmount0(INIT_MAX_VALUE, _sqrtPriceX96);
  }

  /// @notice Converts token0 amount to token1-equivalent value using current sqrt price.
  /// @dev Uses two mulDiv steps to avoid overflow from squaring sqrt price in uint256.
  function _amount0ToValue1(uint256 _amount0, uint160 _sqrtPriceX96)
    internal
    pure
    returns (uint256 _value1)
  {
    if (_amount0 == 0) return 0;

    uint256 _sqrtPriceX96Uint = uint256(_sqrtPriceX96);
    uint256 _value1X96 = FullMath.mulDiv(_amount0, _sqrtPriceX96Uint, Q96);
    _value1 = FullMath.mulDiv(_value1X96, _sqrtPriceX96Uint, Q96);
  }

  /// @notice Converts token1-equivalent value to token0 amount using current sqrt price.
  /// @dev Uses two mulDiv steps to avoid overflow from squaring sqrt price in uint256.
  function _value1ToAmount0(uint256 _value1, uint160 _sqrtPriceX96)
    internal
    pure
    returns (uint256 _amount0)
  {
    if (_value1 == 0) return 0;

    uint256 _sqrtPriceX96Uint = uint256(_sqrtPriceX96);
    uint256 _amount0X96 = FullMath.mulDiv(_value1, Q96, _sqrtPriceX96Uint);
    _amount0 = FullMath.mulDiv(_amount0X96, Q96, _sqrtPriceX96Uint);
  }

  /// @notice Adds liquidity to all positions using pre-calculated amounts.
  /// @param _liquidityPerPosition Array of liquidity to add to each position.
  /// @param _amount0Max Maximum token0 for slippage protection.
  /// @param _amount1Max Maximum token1 for slippage protection.
  /// @return _totalDelta0 The total delta for token0 (negative = owed to pool).
  /// @return _totalDelta1 The total delta for token1 (negative = owed to pool).
  /// @return _totalFeeDelta0 The total fee delta for token0 (positive = fees earned).
  /// @return _totalFeeDelta1 The total fee delta for token1 (positive = fees earned).
  function _addLiquidityToPositions(
    uint128[] memory _liquidityPerPosition,
    uint256 _amount0Max,
    uint256 _amount1Max
  )
    internal
    virtual
    returns (
      int256 _totalDelta0,
      int256 _totalDelta1,
      int256 _totalFeeDelta0,
      int256 _totalFeeDelta1
    )
  {
    for (uint256 _i = 0; _i < positions.length; _i++) {
      LiquidityPosition memory _position = positions[_i];
      uint128 _liquidity = _liquidityPerPosition[_i];

      (BalanceDelta _delta, BalanceDelta _feeDelta) = POOL_MANAGER.modifyLiquidity(
        targetPoolKey,
        ModifyLiquidityParams({
          tickLower: _position.tickLower,
          tickUpper: _position.tickUpper,
          liquidityDelta: int256(uint256(_liquidity)),
          salt: bytes32(0)
        }),
        ""
      );

      _totalDelta0 += _delta.amount0() - _feeDelta.amount0();
      _totalDelta1 += _delta.amount1() - _feeDelta.amount1();
      _totalFeeDelta0 += _feeDelta.amount0();
      _totalFeeDelta1 += _feeDelta.amount1();
    }

    SlippageCheck.validateMaxIn(
      toBalanceDelta(_totalDelta0.toInt128(), _totalDelta1.toInt128()),
      _amount0Max.toUint128(),
      _amount1Max.toUint128()
    );
  }

  /// @notice Calculates token amounts needed for a position and liquidity amount.
  /// @param _position The liquidity position configuration.
  /// @param _sqrtPriceX96 The current sqrt price of the pool.
  /// @param _liquidity The liquidity to add for the position.
  /// @return _amount0 The amount of token0 required.
  /// @return _amount1 The amount of token1 required.
  function _getAmountsForLiquidity(
    LiquidityPosition memory _position,
    uint160 _sqrtPriceX96,
    uint128 _liquidity
  ) internal pure virtual returns (uint256 _amount0, uint256 _amount1) {
    if (_liquidity == 0) return (0, 0);

    uint160 _sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(_position.tickLower);
    uint160 _sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(_position.tickUpper);

    if (_sqrtPriceX96 <= _sqrtPriceLowerX96) {
      _amount0 =
        SqrtPriceMath.getAmount0Delta(_sqrtPriceLowerX96, _sqrtPriceUpperX96, _liquidity, true);
    } else if (_sqrtPriceX96 >= _sqrtPriceUpperX96) {
      _amount1 =
        SqrtPriceMath.getAmount1Delta(_sqrtPriceLowerX96, _sqrtPriceUpperX96, _liquidity, true);
    } else {
      _amount0 = SqrtPriceMath.getAmount0Delta(_sqrtPriceX96, _sqrtPriceUpperX96, _liquidity, true);
      _amount1 = SqrtPriceMath.getAmount1Delta(_sqrtPriceLowerX96, _sqrtPriceX96, _liquidity, true);
    }
  }

  /// @notice Settles token deltas with the pool manager.
  /// @dev Negative deltas mean we owe tokens to the pool, positive means pool owes us.
  /// @param _delta0 The delta for token0.
  /// @param _delta1 The delta for token1.
  /// @param _payer The address to pull tokens from if we owe the pool.
  /// @return _amount0Used The amount of token0 used (paid to pool).
  /// @return _amount1Used The amount of token1 used (paid to pool).
  function _settleDeltas(int256 _delta0, int256 _delta1, address _payer)
    internal
    virtual
    returns (uint256 _amount0Used, uint256 _amount1Used)
  {
    // Settle tokens owed to the pool (negative delta).
    if (_delta0 < 0) {
      _amount0Used = uint256(-_delta0);
      _settle(targetPoolKey.currency0, _payer, _amount0Used);
    }
    if (_delta1 < 0) {
      _amount1Used = uint256(-_delta1);
      _settle(targetPoolKey.currency1, _payer, _amount1Used);
    }
  }

  /// @inheritdoc DeltaResolver
  function _pay(Currency _currency, address _payer, uint256 _amount) internal virtual override {
    IERC20(Currency.unwrap(_currency)).safeTransferFrom(_payer, address(POOL_MANAGER), _amount);
  }

  /// @notice Removes liquidity from all positions based on the provided amounts.
  /// @param _liquidityToRemove Array of liquidity to remove from each position.
  /// @return _totalDelta0 The total delta for token0 (positive = pool owes us).
  /// @return _totalDelta1 The total delta for token1 (positive = pool owes us).
  /// @return _totalFeeDelta0 The total fee delta for token0 (positive = fees earned).
  /// @return _totalFeeDelta1 The total fee delta for token1 (positive = fees earned).
  function _removeLiquidityFromPositions(uint128[] memory _liquidityToRemove)
    internal
    virtual
    returns (
      int256 _totalDelta0,
      int256 _totalDelta1,
      int256 _totalFeeDelta0,
      int256 _totalFeeDelta1
    )
  {
    for (uint256 _i = 0; _i < positions.length; _i++) {
      uint128 _liquidity = _liquidityToRemove[_i];

      LiquidityPosition memory _position = positions[_i];

      (BalanceDelta _delta, BalanceDelta _feeDelta) = POOL_MANAGER.modifyLiquidity(
        targetPoolKey,
        ModifyLiquidityParams({
          tickLower: _position.tickLower,
          tickUpper: _position.tickUpper,
          liquidityDelta: -int256(uint256(_liquidity)),
          salt: bytes32(0)
        }),
        ""
      );

      // Note: `_delta` (callerDelta) includes both principal and fees. We subtract
      // the fee portion so withdrawers only receive principal, not vault's accrued fees.
      _totalDelta0 += _delta.amount0() - _feeDelta.amount0();
      _totalDelta1 += _delta.amount1() - _feeDelta.amount1();
      _totalFeeDelta0 += _feeDelta.amount0();
      _totalFeeDelta1 += _feeDelta.amount1();
    }
  }

  /// @notice Settles token deltas for withdrawals with the pool manager.
  /// @dev Positive deltas mean pool owes us tokens (we receive them).
  /// @param _delta0 The delta for token0.
  /// @param _delta1 The delta for token1.
  /// @param _receiver The address to send tokens to.
  /// @return _amount0Received The amount of token0 received.
  /// @return _amount1Received The amount of token1 received.
  function _settleWithdrawDeltas(int256 _delta0, int256 _delta1, address _receiver)
    internal
    virtual
    returns (uint256 _amount0Received, uint256 _amount1Received)
  {
    // Take tokens owed to us by the pool (positive delta).
    if (_delta0 > 0) {
      _amount0Received = uint256(_delta0);
      _take(targetPoolKey.currency0, _receiver, _amount0Received);
    }
    if (_delta1 > 0) {
      _amount1Received = uint256(_delta1);
      _take(targetPoolKey.currency1, _receiver, _amount1Received);
    }
  }

  /// @notice Collects fee tokens from the pool.
  /// @dev Fee deltas are positive when the pool owes us fees.
  /// @param _feeDelta0 The fee delta for token0.
  /// @param _feeDelta1 The fee delta for token1.
  function _collectFees(int256 _feeDelta0, int256 _feeDelta1) internal virtual {
    uint256 _collectedFee0;
    uint256 _collectedFee1;

    // Take fee tokens from the pool (positive delta = pool owes us).
    if (_feeDelta0 > 0) {
      _collectedFee0 = uint256(_feeDelta0);
      POOL_MANAGER.take(targetPoolKey.currency0, address(this), _collectedFee0);
    }
    if (_feeDelta1 > 0) {
      _collectedFee1 = uint256(_feeDelta1);
      POOL_MANAGER.take(targetPoolKey.currency1, address(this), _collectedFee1);
    }
  }

  /// @notice View-only fee checkpointing based on Uniswap v4 fee growth inside each position range.
  /// @dev
  ///  - Reads fee growth via `getFeeGrowthInside` without calling `unlock` or modifying pool state.
  ///  - Converts fee growth deltas into token amounts using position liquidity and Q128 math.
  ///  - Updates `VaultShareToken` fee indexes via `_updateFees`.
  function _syncFees() internal {
    PoolId _poolId = targetPoolKey.toId();

    uint256 _newFees0;
    uint256 _newFees1;

    for (uint256 _i = 0; _i < positions.length; _i++) {
      LiquidityPosition memory _position = positions[_i];
      uint128 _liquidity = _position.liquidity;

      (uint256 _feeGrowthInside0NowX128, uint256 _feeGrowthInside1NowX128) =
        POOL_MANAGER.getFeeGrowthInside(_poolId, _position.tickLower, _position.tickUpper);

      PositionCheckpoint storage checkpoint = positionCheckpoints[_i];

      // Only compute fees if position has liquidity.
      if (_liquidity > 0) {
        uint256 _feeGrowthInside0LastX128 = checkpoint.feeGrowthInside0LastX128;
        uint256 _feeGrowthInside1LastX128 = checkpoint.feeGrowthInside1LastX128;

        // Compute growth deltas since last checkpoint.
        uint256 _deltaFeeGrowth0X128 = _feeGrowthInside0NowX128 - _feeGrowthInside0LastX128;
        uint256 _deltaFeeGrowth1X128 = _feeGrowthInside1NowX128 - _feeGrowthInside1LastX128;

        if (_deltaFeeGrowth0X128 > 0) {
          _newFees0 += Math.mulDiv(_deltaFeeGrowth0X128, _liquidity, FixedPoint128.Q128);
        }
        if (_deltaFeeGrowth1X128 > 0) {
          _newFees1 += Math.mulDiv(_deltaFeeGrowth1X128, _liquidity, FixedPoint128.Q128);
        }
      }

      // Always advance checkpoints to prevent claiming fees from before we had liquidity.
      checkpoint.feeGrowthInside0LastX128 = _feeGrowthInside0NowX128;
      checkpoint.feeGrowthInside1LastX128 = _feeGrowthInside1NowX128;
    }

    // Update fee indexes if any fees accrued.
    if (_newFees0 > 0 || _newFees1 > 0) _updateFees(_newFees0, _newFees1);
  }
}
