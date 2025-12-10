// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VaultShareToken} from "src/VaultShareToken.sol";

/// @title LPVault
/// @author [ScopeLift](https://scopelift.co)
/// @notice A contract that wraps a set of static LP positions in a single Uniswap v4 pool.
/// @dev Positions and their weight distributions are fixed at contract creation.
contract LPVault is VaultShareToken, IUnlockCallback {
  using PoolIdLibrary for PoolKey;
  using StateLibrary for IPoolManager;
  using SafeCast for uint256;
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

  /// @notice Struct for passing deposit callback data.
  struct DepositCallbackData {
    address sender;
    uint256 amount0Max;
    uint256 amount1Max;
  }

  /// @notice Total weight must equal 10,000 BIPs (100%).
  uint16 public constant BIPS = 10_000;

  /// @notice The Uniswap v4 PoolManager.
  IPoolManager public immutable POOL_MANAGER;

  /// @notice The token0 in the target pool.
  address public immutable TOKEN0;

  /// @notice The token1 in the target pool.
  address public immutable TOKEN1;

  /// @notice The target pool that this vault manages liquidity for.
  PoolKey public targetPoolKey;

  /// @notice The predefined liquidity positions for this vault.
  LiquidityPosition[] public positions;

  /// @notice Thrown when the sum of position weights doesn't equal BIPS (10,000 BIPs).
  error LPVault__InvalidLiquidityDistribution();

  /// @notice Thrown when a position's tickLower is greater than or equal to tickUpper.
  error LPVault__InvalidTickRange();

  /// @notice Thrown when no positions are provided during initialization.
  error LPVault__NoPositions();

  /// @notice Thrown when the total liquidity is zero.
  error LPVault__ZeroLiquidity();

  /// @notice Thrown when the callback is called by a non-pool manager.
  error LPVault__OnlyPoolManager();

  /// @notice Emitted when the pool manager is set during construction.
  /// @param poolManager The address of the Uniswap v4 pool manager.
  event PoolManagerSet(address indexed poolManager);

  /// @notice Emitted when the vault tokens are set during construction.
  /// @param token0 The address of token0.
  /// @param token1 The address of token1.
  event TokensSet(address indexed token0, address indexed token1);

  /// @notice Emitted when a deposit is made.
  /// @param depositor The address that deposited and received shares.
  /// @param shares The amount of vault shares minted.
  /// @param amount0 The amount of token0 deposited.
  /// @param amount1 The amount of token1 deposited.
  event Deposited(address indexed depositor, uint256 shares, uint256 amount0, uint256 amount1);

  /// @notice Creates a new LP Vault with fixed positions.
  /// @param _poolManager The Uniswap v4 pool manager.
  /// @param _targetPoolKey The pool where liquidity is deposited.
  /// @param _positions Array of positions with tick ranges and weights (must sum to 10,000 BIPs).
  /// @param _name The name of the vault share token.
  /// @param _symbol The symbol of the vault share token.
  constructor(
    IPoolManager _poolManager,
    PoolKey memory _targetPoolKey,
    LiquidityPosition[] memory _positions,
    string memory _name,
    string memory _symbol
  )
    VaultShareToken(
      _name,
      _symbol,
      Currency.unwrap(_targetPoolKey.currency0),
      Currency.unwrap(_targetPoolKey.currency1)
    )
  {
    POOL_MANAGER = _poolManager;
    emit PoolManagerSet(address(_poolManager));

    targetPoolKey = _targetPoolKey;
    TOKEN0 = Currency.unwrap(_targetPoolKey.currency0);
    TOKEN1 = Currency.unwrap(_targetPoolKey.currency1);
    emit TokensSet(TOKEN0, TOKEN1);

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

  /// @notice Deposits tokens into the vault, distributing liquidity across positions by weight.
  /// @param _amount0Max The maximum amount of token0 to deposit.
  /// @param _amount1Max The maximum amount of token1 to deposit.
  /// @dev Mints the maximum shares possible given the provided token amounts. Any tokens not used
  /// for liquidity provision will be returned to the depositor.
  /// @return _shares The amount of vault shares minted.
  /// @return _amount0Used The actual amount of token0 used.
  /// @return _amount1Used The actual amount of token1 used.
  function deposit(uint256 _amount0Max, uint256 _amount1Max)
    external
    virtual
    returns (uint256 _shares, uint256 _amount0Used, uint256 _amount1Used)
  {
    bytes memory _result = POOL_MANAGER.unlock(
      abi.encode(
        DepositCallbackData({sender: msg.sender, amount0Max: _amount0Max, amount1Max: _amount1Max})
      )
    );

    (uint128[] memory _liquidityPerPosition, uint256 _amount0, uint256 _amount1) =
      abi.decode(_result, (uint128[], uint256, uint256));

    uint128 _newLiquidity = _liquidityPerPosition[0];
    if (_newLiquidity == 0) revert LPVault__ZeroLiquidity();

    // Use the first position's liquidity as the share amount since it serves as the reference
    // for proportional distribution across all positions based on their weights.
    _shares = uint256(_newLiquidity);

    // Update per-position liquidity.
    for (uint256 _i = 0; _i < _liquidityPerPosition.length; _i++) {
      positions[_i].liquidity += _liquidityPerPosition[_i];
    }

    _mint(msg.sender, _shares);

    _amount0Used = _amount0;
    _amount1Used = _amount1;
    emit Deposited(msg.sender, _shares, _amount0Used, _amount1Used);
  }

  /// @inheritdoc IUnlockCallback
  function unlockCallback(bytes calldata _data) external virtual returns (bytes memory) {
    if (msg.sender != address(POOL_MANAGER)) revert LPVault__OnlyPoolManager();

    DepositCallbackData memory _callbackData = abi.decode(_data, (DepositCallbackData));

    (uint128[] memory _liquidityPerPosition, int256 _totalDelta0, int256 _totalDelta1) =
      _addLiquidityToPositions(_callbackData.amount0Max, _callbackData.amount1Max);

    (uint256 _amount0Used, uint256 _amount1Used) =
      _settleDeltas(_totalDelta0, _totalDelta1, _callbackData.sender);

    return abi.encode(_liquidityPerPosition, _amount0Used, _amount1Used);
  }

  /// @notice Adds liquidity to all positions based on the provided token amounts.
  /// @param _amount0Max The maximum amount of token0 to distribute across positions.
  /// @param _amount1Max The maximum amount of token1 to distribute across positions.
  /// @return _liquidityPerPosition Array of liquidity added to each position.
  /// @return _totalDelta0 The total delta for token0 (negative = owed to pool).
  /// @return _totalDelta1 The total delta for token1 (negative = owed to pool).
  function _addLiquidityToPositions(uint256 _amount0Max, uint256 _amount1Max)
    internal
    virtual
    returns (uint128[] memory _liquidityPerPosition, int256 _totalDelta0, int256 _totalDelta1)
  {
    PoolId _poolId = targetPoolKey.toId();
    (uint160 _sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(_poolId);

    _liquidityPerPosition = new uint128[](positions.length);

    for (uint256 _i = 0; _i < positions.length; _i++) {
      LiquidityPosition memory _position = positions[_i];

      uint256 _amount0ForPosition = (_amount0Max * _position.weight) / BIPS;
      uint256 _amount1ForPosition = (_amount1Max * _position.weight) / BIPS;

      uint128 _liquidity = _calculateLiquidityForAmounts(
        _position, _sqrtPriceX96, _amount0ForPosition, _amount1ForPosition
      );

      _liquidityPerPosition[_i] = _liquidity;

      (BalanceDelta _delta,) = POOL_MANAGER.modifyLiquidity(
        targetPoolKey,
        ModifyLiquidityParams({
          tickLower: _position.tickLower,
          tickUpper: _position.tickUpper,
          liquidityDelta: int256(uint256(_liquidity)),
          salt: bytes32(0)
        }),
        ""
      );

      _totalDelta0 += _delta.amount0();
      _totalDelta1 += _delta.amount1();
    }
  }

  /// @notice Calculates the liquidity for a single position based on token amounts.
  /// @param _position The liquidity position configuration.
  /// @param _sqrtPriceX96 The current sqrt price of the pool.
  /// @param _amount0 The amount of token0 for this position.
  /// @param _amount1 The amount of token1 for this position.
  /// @return _liquidity The calculated liquidity for this position.
  function _calculateLiquidityForAmounts(
    LiquidityPosition memory _position,
    uint160 _sqrtPriceX96,
    uint256 _amount0,
    uint256 _amount1
  ) internal pure virtual returns (uint128 _liquidity) {
    uint160 _sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(_position.tickLower);
    uint160 _sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(_position.tickUpper);

    _liquidity = LiquidityAmounts.getLiquidityForAmounts(
      _sqrtPriceX96, _sqrtPriceLowerX96, _sqrtPriceUpperX96, _amount0, _amount1
    );
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
      _settleToken(targetPoolKey.currency0, _payer, _amount0Used);
    }
    if (_delta1 < 0) {
      _amount1Used = uint256(-_delta1);
      _settleToken(targetPoolKey.currency1, _payer, _amount1Used);
    }
  }

  /// @notice Settles a token payment to the pool manager.
  /// @param _currency The currency to settle.
  /// @param _payer The address paying the tokens.
  /// @param _amount The amount to settle.
  function _settleToken(Currency _currency, address _payer, uint256 _amount) internal virtual {
    POOL_MANAGER.sync(_currency);
    IERC20(Currency.unwrap(_currency)).safeTransferFrom(_payer, address(POOL_MANAGER), _amount);
    POOL_MANAGER.settle();
  }
}
