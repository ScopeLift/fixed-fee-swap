// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FixedFeeSwapHook} from "./FixedFeeSwapHook.sol";

/// @notice A factory for creating fixed fee swaps for a specific liquidity
/// distribution. Fixed Fee swaps can be created in the future, but they should
/// not accept liquidity until they take a snapshot of the fees.
contract FixedFeeSwapFactory {
  using PoolIdLibrary for PoolKey;
  using StateLibrary for IPoolManager;

  /// @notice Structure to track deployed fixed fee swaps
  struct FixedFeeSwapInfo {
    address hook;
    PoolKey targetPoolKey; // The underlying pool providing liquidity
    PoolKey ptPoolKey; // Pool for PT token trading
    PoolKey ytPoolKey; // Pool for YT token trading
    uint256 maturity;
    uint256 createdAt;
    address principalToken;
    address yieldToken;
  }

  /// @notice Structure for liquidity position configuration
  struct LiquidityPosition {
    int24 tickLower;
    int24 tickUpper;
    uint256 weight;
  }

  /// @notice Events
  event FixedFeeSwapCreated(
    address indexed hook,
    PoolId indexed targetPoolId,
    address indexed creator,
    uint256 maturity,
    address principalToken,
    address yieldToken
  );

  /// @notice Errors
  error InvalidMaturityLength();
  error InvalidCloseFee();
  error InvalidLiquidityDistribution();
  error PoolDoesNotExist();
  error ZeroAddress();

  /// @notice The Uniswap v4 PoolManager
  IPoolManager public immutable poolManager;

  /// @notice Default fee tier for PT/YT pools (0.3%)
  uint24 public constant DEFAULT_FEE = 3000;

  /// @notice Default tick spacing
  int24 public constant DEFAULT_TICK_SPACING = 60;

  /// @notice Minimum maturity length (1 day)
  uint48 public constant MIN_MATURITY = 1 days;

  /// @notice Maximum maturity length (365 days)
  uint48 public constant MAX_MATURITY = 365 days;

  /// @notice Maximum close fee (10%)
  uint256 public constant MAX_CLOSE_FEE_LIMIT = 1000;

  /// @notice Expiry divisor for daily expiries (00:00 UTC)
  uint256 public constant DAILY_EXPIRY = 1 days;

  /// @notice Expiry divisor for weekly expiries (Fridays at 00:00 UTC)
  uint256 public constant WEEKLY_EXPIRY = 7 days;

  /// @notice Expiry divisor for monthly expiries (last Friday of month at 00:00 UTC)
  uint256 public constant MONTHLY_EXPIRY = 30 days;

  /// @notice The expiry divisor to use for all markets (configurable at deployment)
  uint256 public immutable EXPIRY_DIVISOR;

  /// @notice Mapping from target pool ID to fixed fee swap info
  mapping(PoolId => FixedFeeSwapInfo) public swapsByPoolId;

  /// @notice Mapping from hook address to fixed fee swap info
  mapping(address => FixedFeeSwapInfo) public swapsByHook;

  /// @notice Constructor
  /// @param _poolManager The Uniswap v4 pool manager
  /// @param _expiryDivisor The divisor to use for standardizing expiry times (e.g., DAILY_EXPIRY,
  /// WEEKLY_EXPIRY)
  constructor(IPoolManager _poolManager, uint256 _expiryDivisor) {
    if (address(_poolManager) == address(0)) revert ZeroAddress();
    if (_expiryDivisor == 0) revert ZeroAddress();

    poolManager = _poolManager;
    EXPIRY_DIVISOR = _expiryDivisor;
  }

  /// @notice Calculate the standardized maturity time based on the expiry divisor
  /// @param requestedMaturity The requested maturity length in seconds from now
  /// @return The standardized maturity timestamp
  function _calculateStandardizedMaturity(uint48 requestedMaturity)
    internal
    view
    returns (uint256)
  {
    uint256 targetTime = block.timestamp + requestedMaturity;
    // Round up to the next expiry divisor boundary
    // For example, if EXPIRY_DIVISOR is 1 day, this rounds to the next midnight UTC
    return ((targetTime + EXPIRY_DIVISOR - 1) / EXPIRY_DIVISOR) * EXPIRY_DIVISOR;
  }

  /// @notice Create and initialize a trading pool for PT or YT tokens
  /// @param token The PT or YT token address
  /// @param referenceToken The reference token to pair with
  /// @param hook The hook address for the pool
  /// @return poolKey The created pool key
  /// @return poolId The created pool ID
  function _createTradingPool(address token, address referenceToken, address hook)
    internal
    returns (PoolKey memory poolKey, PoolId poolId)
  {
    // Ensure proper token ordering
    address token0 = token < referenceToken ? token : referenceToken;
    address token1 = token < referenceToken ? referenceToken : token;

    // Create pool key
    poolKey = PoolKey({
      currency0: Currency.wrap(token0),
      currency1: Currency.wrap(token1),
      fee: DEFAULT_FEE,
      tickSpacing: DEFAULT_TICK_SPACING,
      hooks: IHooks(hook)
    });

    // Calculate pool ID
    poolId = poolKey.toId();

    // Initialize the pool at 1:1 price
    // TODO; What is the best way to set the initial price of the pools
    // TODO: We need to set an initial positions to allow the connection of limit orders.
    poolManager.initialize(poolKey, 79_228_162_514_264_337_593_543_950_336);
  }

  /// @notice Create a Fixed fee swap for a given maturity length with default positions.
  /// The hook will create PT and YT tokens that represent claims on the
  /// underlying pool's liquidity and fees respectively. Two new pools are
  /// created for trading PT and YT against a reference token.
  /// The maturity will be standardized to the next expiry boundary.
  /// @param targetPoolKey The existing pool to create fixed fee swap for
  /// @param maturityLength The approximate length until maturity in seconds (will be rounded to
  /// next boundary) @param closeFee The fee paid to the closer (in basis points)
  /// @param referenceToken The token to pair PT/YT with (typically USDC or ETH)
  /// @return hook The address of the deployed FixedFeeSwapHook
  /// @return ptPoolId The ID of the created PT trading pool
  /// @return ytPoolId The ID of the created YT trading pool
  function createFixedFeeSwap(
    PoolKey memory targetPoolKey,
    uint48 maturityLength,
    uint256 closeFee,
    address referenceToken,
    LiquidityPosition[] memory positions
  ) internal returns (address hook, PoolId ptPoolId, PoolId ytPoolId) {
    // Validate inputs
    if (maturityLength < MIN_MATURITY || maturityLength > MAX_MATURITY) {
      revert InvalidMaturityLength();
    }
    if (closeFee > MAX_CLOSE_FEE_LIMIT) revert InvalidCloseFee();
    if (referenceToken == address(0)) revert ZeroAddress();

    // Verify the target pool exists by checking its sqrtPrice
    PoolId targetPoolId = targetPoolKey.toId();
    {
      (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(targetPoolId);
      if (sqrtPriceX96 == 0) revert PoolDoesNotExist();
    }

    // Calculate the standardized maturity time
    uint256 standardizedMaturity = _calculateStandardizedMaturity(maturityLength);

    // Deploy the FixedFeeSwapHook with the standardized maturity and positions
    {
      // Convert positions format for the hook
      FixedFeeSwapHook.LiquidityPosition[] memory hookPositions =
        new FixedFeeSwapHook.LiquidityPosition[](positions.length);
      for (uint256 i = 0; i < positions.length; i++) {
        hookPositions[i] = FixedFeeSwapHook.LiquidityPosition({
          tickLower: positions[i].tickLower,
          tickUpper: positions[i].tickUpper,
          weight: positions[i].weight
        });
      }

      FixedFeeSwapHook fixedFeeSwapHook = new FixedFeeSwapHook(
        poolManager, targetPoolKey, uint48(standardizedMaturity - block.timestamp), hookPositions
      );
      hook = address(fixedFeeSwapHook);
    }

    // Get hook reference for later use
    FixedFeeSwapHook hookContract = FixedFeeSwapHook(hook);

    // Create and initialize PT pool
    PoolKey memory ptPoolKey;
    (ptPoolKey, ptPoolId) =
      _createTradingPool(address(hookContract.principalToken()), referenceToken, hook);

    // Create and initialize YT pool
    PoolKey memory ytPoolKey;
    (ytPoolKey, ytPoolId) =
      _createTradingPool(address(hookContract.yieldToken()), referenceToken, hook);

    // Store complete fixed fee swap info
    {
      FixedFeeSwapInfo memory swapInfo;
      swapInfo.hook = hook;
      swapInfo.targetPoolKey = targetPoolKey;
      swapInfo.ptPoolKey = ptPoolKey;
      swapInfo.ytPoolKey = ytPoolKey;
      swapInfo.maturity = standardizedMaturity;
      swapInfo.createdAt = block.timestamp;
      swapInfo.principalToken = address(hookContract.principalToken());
      swapInfo.yieldToken = address(hookContract.yieldToken());

      // Update storage
      swapsByPoolId[targetPoolId] = swapInfo;
      swapsByHook[hook] = swapInfo;
    }

    // Emit event
    emit FixedFeeSwapCreated(
      hook,
      targetPoolId,
      msg.sender,
      standardizedMaturity,
      swapsByPoolId[targetPoolId].principalToken,
      swapsByPoolId[targetPoolId].yieldToken
    );

    return (hook, ptPoolId, ytPoolId);
  }

  /// @notice Create a fixed fee swap with custom liquidity positions
  /// @param targetPoolKey The existing pool to create fixed fee swap for
  /// @param maturityLength The length until maturity in seconds
  /// @param closeFee The fee paid to the closer (in basis points)
  /// @param referenceToken The token to pair PT/YT with
  /// @param positions Custom liquidity position distribution
  /// @return hook The address of the deployed FixedFeeSwapHook
  /// @return ptPoolId The ID of the PT trading pool
  /// @return ytPoolId The ID of the YT trading pool
  function createFixedFeeSwapWithPositions(
    PoolKey memory targetPoolKey,
    uint48 maturityLength,
    uint256 closeFee,
    address referenceToken,
    LiquidityPosition[] memory positions
  ) external returns (address hook, PoolId ptPoolId, PoolId ytPoolId) {
    // Validate positions
    _validatePositions(positions);

    // Create the fixed fee swap with the specified positions
    return createFixedFeeSwap(targetPoolKey, maturityLength, closeFee, referenceToken, positions);
  }

  /// @notice Check if a fixed fee swap has been deployed for a pool
  /// @param poolId The target pool ID to check
  /// @return True if a fixed fee swap exists for this pool
  function swapExistsForPool(PoolId poolId) external view returns (bool) {
    return address(swapsByPoolId[poolId].hook) != address(0);
  }

  /// @notice Get fixed fee swap info for a specific pool
  /// @param poolId The target pool ID
  /// @return The fixed fee swap info for the pool
  function getSwapByPoolId(PoolId poolId) external view returns (FixedFeeSwapInfo memory) {
    return swapsByPoolId[poolId];
  }

  /// @notice Get fixed fee swap info by hook address
  /// @param hook The hook address
  /// @return The fixed fee swap info for the hook
  function getSwapByHook(address hook) external view returns (FixedFeeSwapInfo memory) {
    return swapsByHook[hook];
  }

  /// @notice Validate liquidity positions
  /// @param positions The positions to validate
  function _validatePositions(LiquidityPosition[] memory positions) internal pure {
    if (positions.length == 0) revert InvalidLiquidityDistribution();

    uint256 totalWeight = 0;

    for (uint256 i = 0; i < positions.length; i++) {
      // Validate tick range
      if (positions[i].tickLower >= positions[i].tickUpper) {
        revert InvalidLiquidityDistribution();
      }

      // Accumulate weights
      totalWeight += positions[i].weight;
    }

    // Validate total weight equals 10000 (100%)
    if (totalWeight != 10_000) revert InvalidLiquidityDistribution();
  }
}
