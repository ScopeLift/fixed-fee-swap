// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {LiquidityMath} from "v4-core/libraries/LiquidityMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {TickBitmap} from "v4-core/libraries/TickBitmap.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

struct TickInfo {
  // the total position liquidity that references this tick
  uint128 liquidityGross;
  // amount of net liquidity added (subtracted) when tick is crossed from left to right (right to
  // left),
  int128 liquidityNet;
  // fee growth per unit of liquidity on the _other_ side of this tick (relative to the current
  // tick)
  // only has relative meaning, not absolute — the value depends on when the tick is initialized
  uint256 feeGrowthOutside0X128;
  uint256 feeGrowthOutside1X128;
}

struct BalanceDelta {
  int128 amount0;
  int128 amount1;
}

struct PositionInfo {
  address owner;
  int24 tickLower;
  int24 tickUpper;
  int128 liquidity;
  // Fee tracking
  uint256 feeGrowthInside0LastX128;
  uint256 feeGrowthInside1LastX128;
  uint128 tokensOwed0;
  uint128 tokensOwed1;
}

/// @dev Minimal struct for swap step context to avoid stack-too-deep
struct SwapContext {
  bool principalForCash;
  bool tickMovingLeft;
}

// 1. ticks are yield, 1 tick represents 1 bip of yield
// 2. Add liquidity by yield, implement how positions like this would work
// 3. Swap, iterate through ticks
contract FixedFeeSwapMarket is BaseHook {
  using FixedPointMathLib for uint256;
  using SafeCast for uint256;
  using SafeCast for int256;
  using FixedPointMathLib for int256;
  using FixedPointMathLib for int128;
  using SafeCast for int128;
  using SafeERC20 for IERC20;
  using TickBitmap for mapping(int16 => uint256);

  int24 currentTick;
  int256 currentPrice;
  uint128 activeLiquidity;
  int24 constant YIELD_PER_TICK = 1;

  uint256 constant SCALE_FACTOR = 1e18;
  uint256 constant BIPS = 10_000;
  uint48 immutable MATURITY;
  uint48 immutable START_TIME;
  IERC20 immutable TOKEN0;
  IERC20 immutable TOKEN1;

  /// @notice Fee rate in hundredths of a bip, where a value of 1 equals 0.0001%
  /// @dev 3000 = 0.30% fee, similar to Uniswap v3 medium tier
  uint24 public immutable FEE_RATE;

  /// @notice Denominator for fee calculations, set to 1e6 to support hundredths of a bip
  uint256 constant FEE_DENOMINATOR = 1_000_000;

  /// @notice Q128 fixed-point multiplier for fee growth calculations
  uint256 constant Q128 = 1 << 128;

  // Tracking ticks
  mapping(int24 tick => TickInfo) ticks;
  mapping(int16 wordPos => uint256) tickBitmap;
  mapping(bytes32 positionId => PositionInfo) positions;

  /// @notice Global fee growth per unit of liquidity for TOKEN0 (principal)
  uint256 public feeGrowthGlobal0X128;

  /// @notice Global fee growth per unit of liquidity for TOKEN1 (cash)
  uint256 public feeGrowthGlobal1X128;

  // 1. Market opens on deployment. We will
  // want to make this better. Maturities may want
  // to end at the same time.
  constructor(
    uint48 _lengthOfMarket,
    address _token0,
    address _token1,
    uint24 _feeRate,
    IPoolManager _manager
  ) BaseHook(_manager) {
    if (_feeRate >= FEE_DENOMINATOR) revert FixedFeeSwap__FeeRateTooHigh();
    START_TIME = uint48(block.timestamp);
    MATURITY = uint48(block.timestamp) + _lengthOfMarket;
    TOKEN0 = IERC20(_token0);
    TOKEN1 = IERC20(_token1);
    FEE_RATE = _feeRate;
  }

  /// @notice Thrown when the fee rate is 100% or higher
  error FixedFeeSwap__FeeRateTooHigh();

  /// @notice Thrown when trying to remove more liquidity than the position holds
  error FixedFeeSwap__InsufficientPositionLiquidity();

  /// @notice Thrown when swap hook parameters are malformed or have incorrect length
  error FixedFeeSwap__InvalidHookParams();

  /// @notice Thrown when liquidity amount is zero or exceeds slippage bounds
  error FixedFeeSwap__InvalidLiquidityAmount();

  /// @notice Thrown when price moves in an unexpected direction during swap calculation
  error FixedFeeSwap__InvalidPriceDirection();

  /// @notice Thrown when the lower tick is greater than or equal to the upper tick
  error FixedFeeSwap__InvalidTickRange();

  /// @notice Thrown when tick traversal produces an invalid delta or zero boundary amount
  error FixedFeeSwap__InvalidTickTraversal();

  /// @notice Thrown when decreaseLiquidity is called with a non-negative liquidity delta
  error FixedFeeSwap__LiquidityDeltaMustBeNegative();

  /// @notice Thrown when attempting to swap with no active liquidity in range
  error FixedFeeSwap__NoActiveLiquidity();

  /// @notice Thrown when the caller is not the owner of the position
  error FixedFeeSwap__NotPositionOwner();

  /// @notice Thrown when the specified position does not exist
  error FixedFeeSwap__PositionNotFound();

  /// @notice Thrown when the swap amount is zero or negative
  error FixedFeeSwap__SwapAmountCannotBeZero();

  /// @notice Thrown when a swap step consumes zero input, which would cause an infinite loop
  error FixedFeeSwap__SwapStepProducedZeroIn();

  /// @notice Thrown at START_TIME when no time has elapsed, to prevent division by zero
  error FixedFeeSwap__TimeElapsedIsZero();

  /// @notice Thrown when liquidity is added or removed via PoolManager instead of this hook
  error LiquidityOnlyViaHook();

  /// @notice Emitted when fees are collected from a position
  event FeesCollected(
    bytes32 indexed positionId, address indexed recipient, uint128 amount0, uint128 amount1
  );

  /// @notice Calculates the scaled time elapsed since market start as a fraction of total duration
  /// @dev Returns a WAD-scaled value where 1e18 represents the full duration from START_TIME to MATURITY
  /// @return The scaled time elapsed in WAD precision, where 1e18 represents 100% of the duration
  function _scaledTimeElapsedWad() internal view returns (uint256) {
    uint256 elapsed = block.timestamp - START_TIME;
    if (elapsed == 0) revert FixedFeeSwap__TimeElapsedIsZero();
    return (elapsed * SCALE_FACTOR) / (MATURITY - START_TIME);
  }

  /// @notice Computes within-tick swap for PT→cash using exact exponential math
  /// @dev Uses expWad to handle fractional tick movements: P1 = exp(-(tickBps1/BIPS) * t)
  function _getCashSwapAmountWithinTick(
    uint256 amountIn,
    uint256, // principalToBoundary - unused with exact math
    uint256, // cashOutToBoundary - unused with exact math
    uint256 // priceDiff - unused with exact math
  ) internal view returns (uint256 amountInConsumed, uint256 cashOut, int256 newPrice, int24 newTick) {
    amountInConsumed = amountIn;
    uint256 t = _scaledTimeElapsedWad();

    // tickBps1Wad = currentTick * 1e18 + (amountIn * BIPS * 1e18 / L)
    // Tick movement is linear in PT: ΔtickBps = PT_in * BIPS / L
    int256 tickBps1Wad = int256(currentTick) * int256(1e18)
      + int256(FixedPointMathLib.mulDiv(amountIn, BIPS * 1e18, uint256(activeLiquidity)));

    // P1 = exp(-(tickBps1/BIPS) * t)
    // exponentWad = -(tickBps1Wad * t) / (BIPS * 1e18)
    {
      int256 exponentWad;
      if (tickBps1Wad >= 0) {
        exponentWad = -int256(FixedPointMathLib.mulDiv(uint256(tickBps1Wad), t, BIPS * 1e18));
      } else {
        exponentWad = int256(FixedPointMathLib.mulDiv(uint256(-tickBps1Wad), t, BIPS * 1e18));
      }
      newPrice = exponentWad.expWad();
    }

    // Cash_out = (L / t) * (P0 - P1)
    if (currentPrice > newPrice) {
      cashOut = FixedPointMathLib.mulDiv(uint256(activeLiquidity), uint256(currentPrice - newPrice), t);
    }

    // Convert tickBps1Wad to int24 (floor for tick increasing direction)
    newTick = tickBps1Wad >= 0
      ? int24(tickBps1Wad / int256(1e18))
      : int24((tickBps1Wad - int256(1e18) + 1) / int256(1e18));
  }

  /// @notice Computes within-tick swap for cash→PT using exact logarithm math
  /// @dev Uses lnWad to compute: r1 = -(1/t) * ln(P0 + (t/L) * C), then PT_out = L * (r0 - r1) / BIPS
  function _getPrincipalSwapAmountWithinTick(
    uint256 amountIn,
    uint256, // cashInToBoundary - unused with exact math
    uint256, // principalOutToBoundary - unused with exact math
    uint256, // priceDiff - unused with exact math
    int24 // tickDelta - unused with exact math
  ) internal view returns (uint256 amountInConsumed, uint256 principalOut, int256 newPrice, int24 newTick) {
    amountInConsumed = amountIn;
    uint256 t = _scaledTimeElapsedWad();

    // P1 = P0 + (t / L) * C
    newPrice = currentPrice + int256(FixedPointMathLib.mulDiv(t, amountIn, uint256(activeLiquidity)));

    // tickBps1Wad = (-ln(P1) / t) * BIPS * 1e18
    int256 tickBps1Wad;
    {
      int256 lnP1 = FixedPointMathLib.lnWad(newPrice);
      if (lnP1 <= 0) {
        tickBps1Wad = int256(FixedPointMathLib.mulDiv(uint256(-lnP1), BIPS * 1e18, t));
      } else {
        tickBps1Wad = -int256(FixedPointMathLib.mulDiv(uint256(lnP1), BIPS * 1e18, t));
      }
    }

    // Convert WAD-scaled tick to int24 (floor for tick decreasing direction)
    newTick = tickBps1Wad >= 0
      ? int24(tickBps1Wad / 1e18)
      : int24((tickBps1Wad - int256(1e18) + 1) / int256(1e18));

    // PT_out = L * (r0 - r1) / BIPS using WAD precision
    {
      int256 ticksMovedWad = int256(currentTick) * int256(1e18) - tickBps1Wad;
      if (ticksMovedWad > 0) {
        principalOut = FixedPointMathLib.mulDiv(uint256(activeLiquidity), uint256(ticksMovedWad), BIPS * 1e18);
      }
    }
  }

  /// @notice Hook called before liquidity is added via PoolManager
  /// @dev Always reverts because liquidity must be managed through this contract's mint/increase functions
  function _beforeAddLiquidity(
    address,
    PoolKey calldata,
    ModifyLiquidityParams calldata,
    bytes calldata
  ) internal virtual override returns (bytes4) {
    revert LiquidityOnlyViaHook();
  }

  /// @notice Hook called before liquidity is removed via PoolManager
  /// @dev Always reverts because liquidity must be managed through this contract's decrease function
  function _beforeRemoveLiquidity(
    address,
    PoolKey calldata,
    ModifyLiquidityParams calldata,
    bytes calldata
  ) internal virtual override returns (bytes4) {
    revert LiquidityOnlyViaHook();
  }

  /// @notice Hook called before a swap is executed via PoolManager
  /// @dev Hook data schema: `abi.encode(int256 amountIn, bool principalForCash, uint256
  /// priceLimitWad)`. If `principalForCash` is true, TOKEN0 is input and TOKEN1 is output, meaning
  /// the tick increases and price decreases.
  /// If `priceLimitWad` is 0, the swap only stops once `amountIn` is fully consumed.
  /// amountIn is the gross amount before fees that the trader provides.
  /// @param _sender The address initiating the swap
  /// @param _hookParams Encoded swap parameters containing amountIn, principalForCash, and priceLimitWad
  /// @return The hook selector, a zero delta because the swap is handled internally, and zero fee override
  function _beforeSwap(
    address _sender,
    PoolKey calldata,
    SwapParams calldata,
    bytes calldata _hookParams
  ) internal virtual override returns (bytes4, BeforeSwapDelta, uint24) {
    if (_hookParams.length == 0) {
      return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
    }
    if (_hookParams.length != 96) revert FixedFeeSwap__InvalidHookParams();

    (int256 amountIn, bool principalForCash, uint256 priceLimitWad) =
      abi.decode(_hookParams, (int256, bool, uint256));
    if (amountIn <= 0) revert FixedFeeSwap__SwapAmountCannotBeZero();
    if (activeLiquidity == 0) revert FixedFeeSwap__NoActiveLiquidity();
    if (currentPrice == 0) currentPrice = tickToPrice(currentTick);

    (uint256 amountInUsed, uint256 amountOutCalculated) =
      _executeSwapLoop(uint256(amountIn), principalForCash, priceLimitWad);

    // Execute token transfers
    // TOKEN0 = principal token, TOKEN1 = cash token
    if (principalForCash) {
      // User sends principal (TOKEN0), receives cash (TOKEN1)
      if (amountInUsed != 0) TOKEN0.safeTransferFrom(_sender, address(this), amountInUsed);
      if (amountOutCalculated != 0) TOKEN1.safeTransfer(_sender, amountOutCalculated);
    } else {
      // User sends cash (TOKEN1), receives principal (TOKEN0)
      if (amountInUsed != 0) TOKEN1.safeTransferFrom(_sender, address(this), amountInUsed);
      if (amountOutCalculated != 0) TOKEN0.safeTransfer(_sender, amountOutCalculated);
    }
    return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
  }

  /// @notice Executes the main swap loop, iterating through ticks until input is consumed or price limit is hit
  /// @param amountInGross The gross input amount (before fees)
  /// @param principalForCash True for PT→cash swap, false for cash→PT swap
  /// @param priceLimitWad Price limit in WAD; 0 means no limit
  /// @return amountInUsed Total gross input consumed
  /// @return amountOutCalculated Total output tokens to send to trader
  function _executeSwapLoop(uint256 amountInGross, bool principalForCash, uint256 priceLimitWad)
    internal
    returns (uint256 amountInUsed, uint256 amountOutCalculated)
  {
    uint256 amountInRemainingGross = amountInGross;
    SwapContext memory ctx = SwapContext({principalForCash: principalForCash, tickMovingLeft: !principalForCash});

    while (amountInRemainingGross != 0) {
      // Check price limit
      if (priceLimitWad != 0) {
        uint256 priceAbs = currentPrice.abs();
        if (ctx.principalForCash ? priceAbs <= priceLimitWad : priceAbs >= priceLimitWad) break;
      }

      // Compute net-of-fee input
      uint256 amountInRemainingNet = _netOfFee(amountInRemainingGross);
      if (amountInRemainingNet == 0) break;

      // Find next initialized tick
      int24 nextTick;
      bool initialized;
      {
        int24 searchTick = (ctx.tickMovingLeft && currentTick != type(int24).min)
          ? currentTick - YIELD_PER_TICK
          : currentTick;
        (nextTick, initialized) =
          tickBitmap.nextInitializedTickWithinOneWord(searchTick, YIELD_PER_TICK, ctx.tickMovingLeft);
      }

      // Compute swap step and update state
      (uint256 stepGross, uint256 stepOut, int24 newTick) =
        _executeSwapStep(amountInRemainingNet, amountInRemainingGross, nextTick, initialized, ctx);

      amountInRemainingGross -= stepGross;
      amountOutCalculated += stepOut;
      currentTick = newTick;
    }

    amountInUsed = amountInGross - amountInRemainingGross;
  }

  /// @notice Executes a single swap step: calculates amounts, updates fees, crosses tick if needed
  /// @param amountInNet Net input amount (after fees) available for this step
  /// @param amountInGrossRemaining Gross input remaining to clamp step size
  /// @param nextTick The next initialized tick boundary
  /// @param initialized Whether nextTick is an initialized tick with liquidity changes
  /// @param ctx Swap context containing direction flags
  /// @return stepGross Gross input consumed in this step
  /// @return stepOut Output tokens produced in this step
  /// @return newTick The tick position after this step
  function _executeSwapStep(
    uint256 amountInNet,
    uint256 amountInGrossRemaining,
    int24 nextTick,
    bool initialized,
    SwapContext memory ctx
  ) internal returns (uint256 stepGross, uint256 stepOut, int24 newTick) {
    // Compute swap using NET input
    (uint256 stepNet, uint256 amountOut, int256 stepPrice, int24 stepTick) =
      _calculateSwap(amountInNet.toInt256(), currentPrice, nextTick, ctx.principalForCash);
    if (stepNet == 0) revert FixedFeeSwap__SwapStepProducedZeroIn();

    // Convert NET to GROSS. Clamp to remaining gross to handle rounding edge cases
    // where _grossFromNet slightly overshoots due to rounding up.
    stepGross = _grossFromNet(stepNet);
    if (stepGross > amountInGrossRemaining) stepGross = amountInGrossRemaining;
    if (stepGross < stepNet) revert FixedFeeSwap__InvalidHookParams();

    // Update fee growth
    uint256 stepFee = stepGross - stepNet;
    if (stepFee > 0 && activeLiquidity > 0) {
      if (ctx.principalForCash) {
        feeGrowthGlobal0X128 += FixedPointMathLib.mulDiv(stepFee, Q128, activeLiquidity);
      } else {
        feeGrowthGlobal1X128 += FixedPointMathLib.mulDiv(stepFee, Q128, activeLiquidity);
      }
    }

    // Cross tick if needed
    bool hitBoundary = stepTick == nextTick;
    if (hitBoundary && initialized) {
      _crossTick(nextTick);
      int128 liquidityNet = ticks[nextTick].liquidityNet;
      if (ctx.tickMovingLeft) liquidityNet = -liquidityNet;
      activeLiquidity = LiquidityMath.addDelta(activeLiquidity, liquidityNet);
    }

    // Update price and calculate new tick
    currentPrice = stepPrice;
    newTick = (ctx.tickMovingLeft && hitBoundary) ? stepTick - YIELD_PER_TICK : stepTick;
    stepOut = amountOut;
  }

  /// @notice Creates a new liquidity position or adds to an existing one at the same tick range
  /// @dev Position ID is derived from tickUpper, tickLower, and msg.sender
  /// @param _tickLower The lower tick boundary of the position, representing the lower yield
  /// @param _tickUpper The upper tick boundary of the position, representing the higher yield
  /// @param _liquidity The amount of liquidity to mint
  /// @param _amount0Max Maximum TOKEN0 principal tokens willing to deposit
  /// @param _amount1Max Maximum TOKEN1 cash tokens willing to deposit
  function mintLiquidity(
    int24 _tickLower,
    int24 _tickUpper,
    uint256 _liquidity,
    uint256 _amount0Max,
    uint256 _amount1Max
  ) external virtual {
    bytes32 _positionId = keccak256(abi.encodePacked(_tickUpper, _tickLower, msg.sender));
    PositionInfo storage position = positions[_positionId];
    bool isNew = position.owner == address(0);
    int128 liquidityBefore = position.liquidity;

    if (isNew) {
      position.tickUpper = _tickUpper;
      position.tickLower = _tickLower;
      position.owner = msg.sender;
      position.tokensOwed0 = 0;
      position.tokensOwed1 = 0;
    }

    // Call modifyLiquidity first so tick init sets feeGrowthOutside correctly
    BalanceDelta memory _balanceDelta =
      _modifyLiquidity(msg.sender, _tickUpper, _tickLower, _liquidity.toInt128());
    if (
      _balanceDelta.amount0.toUint128() > _amount0Max
        || _balanceDelta.amount1.toUint128() > _amount1Max
    ) revert FixedFeeSwap__InvalidLiquidityAmount();

    // Update liquidity without overwriting fee fields
    position.liquidity = position.liquidity + _liquidity.toInt128();

    // Initialize snapshots when liquidity transitions from 0 -> positive
    // (isNew implies liquidityBefore == 0, so we only need to check liquidityBefore)
    if (liquidityBefore == 0) {
      _refreshFeeSnapshots(position);
    }

    if (_balanceDelta.amount0.toUint128() > 0) {
      TOKEN0.safeTransferFrom(msg.sender, address(this), _balanceDelta.amount0.toUint128());
    }

    if (_balanceDelta.amount1.toUint128() > 0) {
      TOKEN1.safeTransferFrom(msg.sender, address(this), _balanceDelta.amount1.toUint128());
    }
  }

  /// @notice Increases liquidity for an existing position
  /// @dev Caller must be the position owner. Accrues pending fees before adding liquidity.
  /// @param _positionId The unique identifier of the position
  /// @param _liquidity The amount of liquidity to add
  /// @param _amount0Max Maximum TOKEN0 principal tokens willing to deposit
  /// @param _amount1Max Maximum TOKEN1 cash tokens willing to deposit
  function increaseLiquidity(
    bytes32 _positionId,
    uint256 _liquidity,
    uint256 _amount0Max,
    uint256 _amount1Max
  ) external virtual {
    PositionInfo storage position = _requirePositionOwner(_positionId);
    int128 liquidityBefore = position.liquidity;

    // modifyLiquidity accrues fees internally and refreshes snapshots
    BalanceDelta memory _balanceDelta = _modifyLiquidity(
      msg.sender, position.tickUpper, position.tickLower, _liquidity.toInt128()
    );
    if (
      _balanceDelta.amount0.toUint128() > _amount0Max
        || _balanceDelta.amount1.toUint128() > _amount1Max
    ) revert FixedFeeSwap__InvalidLiquidityAmount();

    // Update position liquidity without overwriting fee fields
    position.liquidity = position.liquidity + _liquidity.toInt128();

    // If the position had zero liquidity, refresh snapshots to prevent earning past fees
    if (liquidityBefore == 0) {
      _refreshFeeSnapshots(position);
    }

    if (_balanceDelta.amount0.toUint128() > 0) {
      TOKEN0.safeTransferFrom(msg.sender, address(this), _balanceDelta.amount0.toUint128());
    }

    if (_balanceDelta.amount1.toUint128() > 0) {
      TOKEN1.safeTransferFrom(msg.sender, address(this), _balanceDelta.amount1.toUint128());
    }
  }

  /// @notice Decreases liquidity from an existing position and withdraws tokens
  /// @dev Caller must be the position owner. Accrues pending fees before removing liquidity.
  /// @param _positionId The unique identifier of the position
  /// @param _liquidity The amount of liquidity to remove, must be negative
  /// @param _amount0Min Minimum TOKEN0 principal tokens to receive
  /// @param _amount1Min Minimum TOKEN1 cash tokens to receive
  function decreaseLiquidity(
    bytes32 _positionId,
    int128 _liquidity,
    uint256 _amount0Min,
    uint256 _amount1Min
  ) external virtual {
    PositionInfo storage position = _requirePositionOwner(_positionId);
    if (_liquidity >= 0) revert FixedFeeSwap__LiquidityDeltaMustBeNegative();
    if (position.liquidity < 0) revert FixedFeeSwap__InvalidLiquidityAmount();
    if (uint128(position.liquidity) < uint128(_liquidity.abs())) {
      revert FixedFeeSwap__InsufficientPositionLiquidity();
    }

    // modifyLiquidity accrues fees owed before burning liquidity
    BalanceDelta memory _balanceDelta =
      _modifyLiquidity(msg.sender, position.tickUpper, position.tickLower, _liquidity);
    if (
      _balanceDelta.amount0.abs() < _amount0Min
        || _balanceDelta.amount1.abs() < _amount1Min
    ) revert FixedFeeSwap__InvalidLiquidityAmount();

    // Update position liquidity without overwriting fee fields
    position.liquidity = position.liquidity + _liquidity;

    if (_balanceDelta.amount0 < 0) {
      TOKEN0.safeTransfer(msg.sender, _balanceDelta.amount0.abs());
    }

    if (_balanceDelta.amount1 < 0) TOKEN1.safeTransfer(msg.sender, _balanceDelta.amount1.abs());
  }

  /// @notice Collects accumulated fees for a position
  /// @param positionId The position identifier
  /// @param recipient Address to receive the fees
  /// @param amount0Requested Maximum TOKEN0 fees to collect, or 0 to collect all available
  /// @param amount1Requested Maximum TOKEN1 fees to collect, or 0 to collect all available
  /// @return amount0 Actual TOKEN0 fees collected
  /// @return amount1 Actual TOKEN1 fees collected
  function collectFees(
    bytes32 positionId,
    address recipient,
    uint128 amount0Requested,
    uint128 amount1Requested
  ) external returns (uint128 amount0, uint128 amount1) {
    PositionInfo storage position = _requirePositionOwner(positionId);

    // Accrue pending fees before collection
    _accruePositionFees(position);

    // Calculate amounts to collect (0 means collect all, otherwise min of requested and owed)
    amount0 = (amount0Requested == 0 || amount0Requested > position.tokensOwed0)
      ? position.tokensOwed0
      : amount0Requested;
    amount1 = (amount1Requested == 0 || amount1Requested > position.tokensOwed1)
      ? position.tokensOwed1
      : amount1Requested;

    // Update owed amounts (CEI: update state before transfers)
    position.tokensOwed0 -= amount0;
    position.tokensOwed1 -= amount1;

    // Transfer fees
    if (amount0 > 0) TOKEN0.safeTransfer(recipient, amount0);
    if (amount1 > 0) TOKEN1.safeTransfer(recipient, amount1);

    emit FeesCollected(positionId, recipient, amount0, amount1);
  }

  /// @notice Validates position exists and caller is owner, returns storage pointer
  function _requirePositionOwner(bytes32 _positionId)
    internal
    view
    returns (PositionInfo storage position)
  {
    position = positions[_positionId];
    if (position.owner == address(0)) revert FixedFeeSwap__PositionNotFound();
    if (position.owner != msg.sender) revert FixedFeeSwap__NotPositionOwner();
  }

  /// @notice Internal function to modify liquidity for a position
  /// @dev Handles tick updates, bitmap flips, active liquidity changes, and fee accrual
  /// @param _owner The position owner address
  /// @param _tickUpper The upper tick boundary of the position
  /// @param _tickLower The lower tick boundary of the position
  /// @param _liquidity The liquidity delta (positive to add, negative to remove)
  /// @return The token amounts required to deposit (positive) or to withdraw (negative)
  function _modifyLiquidity(address _owner, int24 _tickUpper, int24 _tickLower, int128 _liquidity)
    internal
    returns (BalanceDelta memory)
  {
    if (_tickLower >= _tickUpper) revert FixedFeeSwap__InvalidTickRange();
    if (_liquidity == 0) return BalanceDelta({amount0: 0, amount1: 0});

    bytes32 positionId = keccak256(abi.encodePacked(_tickUpper, _tickLower, _owner));
    PositionInfo storage position = positions[positionId];

    // Accrue fees before mutating ticks (must happen before tick data is cleared)
    if (position.owner != address(0)) {
      _accruePositionFees(position);
    }

    // Mutate ticks / bitmap / activeLiquidity
    bool _flippedLower = false;
    bool _flippedUpper = false;
    uint128 _liquidityGrossAfterLower = 0;
    uint128 _liquidityGrossAfterUpper = 0;

    // Adding liquidity, make sure ticks are available and reflect the new liquidity
    if (_liquidity != 0) {
      (_flippedLower, _liquidityGrossAfterLower) =
        _updateTickLiquidity(_tickLower, _liquidity, false);
      (_flippedUpper, _liquidityGrossAfterUpper) =
        _updateTickLiquidity(_tickUpper, _liquidity, true);

      // initialize tick
      if (_flippedLower) tickBitmap.flipTick(_tickLower, YIELD_PER_TICK);

      // initialize tick
      if (_flippedUpper) tickBitmap.flipTick(_tickUpper, YIELD_PER_TICK);
    }
    if (_liquidity < 0) {
      // No liquidity left update
      if (_flippedLower) delete ticks[_tickLower];

      // No liquidity left update
      if (_flippedUpper) delete ticks[_tickUpper];
    }

    // Get token amounts owed for the liquidity
    if (_liquidity != 0) {
      // Get current tick and price
      if (currentTick < _tickLower) {
        return BalanceDelta({
          amount0: _getAmountPrincipleDelta(_tickLower, _tickUpper, _liquidity).toInt128(),
          amount1: 0
        });
      } else if (currentTick < _tickUpper) {
        // Added to active liquidity since the price is in the range
        activeLiquidity = LiquidityMath.addDelta(activeLiquidity, _liquidity);

        return BalanceDelta({
          amount0: _getAmountPrincipleDelta(currentTick, _tickUpper, _liquidity).toInt128(),
          amount1: _getAmountCashDelta(_tickLower, currentTick, _liquidity).toInt128()
        });
      } else {
        return BalanceDelta({
          amount0: 0, amount1: _getAmountCashDelta(_tickLower, _tickUpper, _liquidity).toInt128()
        });
      }
    }
  }

  /// @notice Returns the hook permissions indicating which callbacks this hook implements
  /// @return The permissions struct with beforeSwap enabled
  function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
      beforeInitialize: false,
      afterInitialize: false,
      beforeAddLiquidity: false,
      afterAddLiquidity: false,
      beforeRemoveLiquidity: false,
      afterRemoveLiquidity: false,
      beforeSwap: true,
      afterSwap: false,
      beforeDonate: false,
      afterDonate: false,
      beforeSwapReturnDelta: false,
      afterSwapReturnDelta: false,
      afterAddLiquidityReturnDelta: false,
      afterRemoveLiquidityReturnDelta: false
    });
  }

  /// @notice Converts a yield in basis points to the corresponding tick
  /// @param yieldBps The yield rate in basis points
  /// @return The tick value representing this yield
  function yieldToTick(int256 yieldBps) public view returns (int24) {
    return int24(yieldBps / YIELD_PER_TICK);
  }

  /// @notice Converts a tick to its corresponding discount factor price
  /// @dev Price is calculated as exp(-yield * scaledTimeElapsed) where yield = tick * YIELD_PER_TICK
  /// @param _tick The tick value to convert
  /// @return The price as a WAD-scaled discount factor, where 1e18 represents a price of 1.0
  function tickToPrice(int256 _tick) public view returns (int256) {
    // exp(- Y * time to maturity)
    int256 _yieldTick = (_tick * YIELD_PER_TICK);
    uint256 _timeBetweenMaturity = (BIPS * (MATURITY - START_TIME));
    uint256 _scaledTimeSinceMaturity = (block.timestamp - START_TIME) * SCALE_FACTOR;
    int256 _scaledPriceExponent =
      -1 * (_yieldTick * _scaledTimeSinceMaturity.toInt128()) / _timeBetweenMaturity.toInt128();
    int256 _price = _scaledPriceExponent.expWad();
    return _price;
  }

  /// @notice Updates the liquidity at a tick and initializes fee growth if tick is newly initialized
  /// @param _tick The tick that will be updated
  /// @param _liquidityDelta Amount of liquidity to be added when tick is crossed from left to right,
  /// or subtracted when crossed from right to left
  /// @param _upper true for updating a position's upper tick, or
  /// false for updating a position's lower tick
  /// @return flipped Whether the tick was flipped from initialized to uninitialized or vice versa
  /// @return liquidityGrossAfter The gross liquidity at the tick after the update
  function _updateTickLiquidity(int24 _tick, int128 _liquidityDelta, bool _upper)
    internal
    returns (bool, uint128)
  {
    TickInfo storage info = ticks[_tick];

    uint128 _liquidityGrossBefore = info.liquidityGross;
    int128 _liquidityNetBefore = info.liquidityNet;

    uint128 _liquidityGrossAfter;
    if (_liquidityDelta > 0) {
      _liquidityGrossAfter = _liquidityGrossBefore + _liquidityDelta.toUint128();
    } else {
      if (_liquidityGrossBefore < _liquidityDelta.abs()) {
        revert("Subtraction would cause underflow");
      }
      _liquidityGrossAfter = _liquidityGrossBefore - uint128(_liquidityDelta.abs());
    }

    bool _flipped = (_liquidityGrossAfter == 0) != (_liquidityGrossBefore == 0);

    // Initialize fee growth outside when tick becomes initialized
    // By convention, assume all prior fee growth occurred below this tick
    if (_liquidityGrossBefore == 0 && _liquidityGrossAfter > 0) {
      if (_tick <= currentTick) {
        info.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
        info.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
      }
      // If tick > currentTick, feeGrowthOutside stays 0 (all growth is below)
    }

    // when the lower (upper) tick is crossed left to right, liquidity must be added (removed)
    // when the lower (upper) tick is crossed right to left, liquidity must be removed (added)
    int128 _liquidityNet =
      _upper ? _liquidityNetBefore - _liquidityDelta : _liquidityNetBefore + _liquidityDelta;

    info.liquidityGross = _liquidityGrossAfter;
    info.liquidityNet = _liquidityNet;

    return (_flipped, _liquidityGrossAfter);
  }

  /// @notice Routes swap calculation to the appropriate direction-specific function
  /// @param _amountIn The input amount to swap
  /// @param _currentPrice The current price at the start of this step
  /// @param _nextTick The next initialized tick boundary
  /// @param _principalToCash True for PT→cash, false for cash→PT
  /// @return amountInConsumed Amount of input consumed
  /// @return amountOut Amount of output produced
  /// @return newPrice Price after the swap step
  /// @return newTick Tick after the swap step
  function _calculateSwap(
    int256 _amountIn,
    int256 _currentPrice,
    int24 _nextTick,
    bool _principalToCash
  ) internal returns (uint256, uint256, int256, int24) {
    if (_principalToCash) {
      return _getCashSwapAmount(_amountIn, _currentPrice, _nextTick);
    }
    return _getPrincipalSwapAmount(_amountIn, _currentPrice, _nextTick);
  }

  /// @notice Calculate the cash out for a provided amount of PT in up to the next tick boundary.
  /// @param _amountIn The amount of PT available to trade for cash.
  /// @param _currentPrice The price calculated with the current yield tick.
  /// @param _nextTick The next initialized within one word which is set as the boundary.
  /// @dev This note documents a PT→cash swap that crosses an initialized tick boundary and therefore must be
  /// evaluated piecewise, segment-by-segment. This function computes a single segment; the outer loop in
  /// `_executeSwapLoop` orchestrates multiple segments and handles tick crossing.
  ///
  /// In the scenario, the trader sells 9,000 PT for cash. The active (current) segment liquidity is
  /// L0 = 3,000,000. The next initialized tick is 25 bips away (650 − 625 = 25 bips), so the trade will
  /// first attempt to move the yield from the current yield r0 to the boundary yield rNext, consuming PT
  /// against the active segment liquidity L0. The amount of PT required to traverse exactly to the next
  /// boundary is computed per segment as:
  /// 
  ///     PT_in_seg = L0 * (r0 − rNext)
  /// 
  /// where r0 is the yield at the start of the segment, rNext is the yield at the next initialized tick
  /// in the direction of the swap, and L0 is the liquidity for that segment (note Lseg can change after
  /// crossing an initialized tick). The implementation must ensure the sign convention matches the trade
  /// direction (i.e., the expression above should be positive for “PT in” consumed to reach the boundary,
  /// or equivalently an absolute value is taken if the model stores yields in the opposite orientation).
  /// 
  /// For this trade, 7,500 PT is the amount that reaches the boundary, which means the swap crosses the
  /// initialized tick after consuming 7,500 PT, and there is 1,500 PT remaining to continue swapping in
  /// the next segment. When the boundary is reached, this function returns `(principalToBoundary,
  /// cashOutToBoundary, nextTickPrice, nextTick)`, signaling to the caller that a tick crossing is needed.
  /// 
  /// (With r expressed as a decimal yield, 25 bips = 0.0025, so L0 = 7,500 / 0.0025 = 3,000,000.
  /// Equivalently, this is 300 PT per bip since 3,000,000 * 0.0001 = 300.)
  /// 
  /// Cash out for any segment is computed by integrating the discount-factor price over the yield move:
  /// 
  ///     CashOut = (Lseg / t) * (exp(-r0 * t) - exp(-r1 * t))
  /// 
  /// where t is the time-to-maturity, r0 is the yield at the start of the segment, and r1 is the yield at
  /// the end of the segment. For the boundary-crossing segment, r1 is the boundary yield rNext and
  /// Lseg = L0 = 3,000,000. The r0/r1 ordering must be kept consistent with the intended sign of CashOut;
  /// if the trade direction makes the expression negative under the chosen ordering, the implementation
  /// should either swap the bounds or apply the protocol’s sign convention consistently across PT and
  /// cash deltas.
  /// 
  /// After the tick is crossed, the remaining PT amount X (here X = 1,500) no longer targets the same
  /// boundary; instead it moves the yield within the next segment using the next segment liquidity
  /// L1 = 1,000,000. The tick crossing itself (updating `feeGrowthOutside` and adjusting `activeLiquidity`)
  /// is handled by the caller before invoking this function again with the reduced input and new liquidity:
  /// 
  ///     Δr = X / L1
  /// 
  /// This yields a new end yield r1 = r0 ± Δr (the ± depends on whether “selling PT” moves yield up or down
  /// in the model). Once r1 is computed, the remaining cash out is calculated using the same integral,
  /// but with Lseg = L1:
  /// 
  ///     CashOut = (L1 / t) * (exp(-r0 * t) - exp(-r1 * t))
  /// 
  /// (Numerically here, Δr = 1,500 / 1,000,000 = 0.0015 = 15 bips; equivalently L1 = 100 PT per bip since
  /// 1,000,000 * 0.0001 = 100.) When the swap completes within a tick range, this function delegates to
  /// `_getCashSwapAmountWithinTick`, which computes the partial amounts proportionally.
  /// 
  /// The total cash out for the swap is the sum of the cash out from the boundary-crossing segment (using
  /// L0) and the cash out from the remainder segment (using L1), and the final yield state is the r1
  /// reached after consuming all 9,000 PT.
  /// @return amountInConsumed PT consumed in this step. Equals `_amountIn` if the swap completes within
  /// the tick range, otherwise equals `principalToBoundary` when the boundary is reached.
  /// @return cashOut Cash tokens to send to the trader for this segment.
  /// @return newPrice Price after this step, to be used as `_currentPrice` in the next iteration.
  /// @return newTick Tick after this step. If equal to `_nextTick`, the caller should cross the tick.
  function _getCashSwapAmount(int256 _amountIn, int256 _currentPrice, int24 _nextTick)
    internal
    returns (uint256, uint256, int256, int24)
  {
    if (_amountIn <= 0) revert FixedFeeSwap__SwapAmountCannotBeZero();
    int256 nextTickPrice = tickToPrice(_nextTick);
    if (nextTickPrice > _currentPrice) revert FixedFeeSwap__InvalidPriceDirection();

    int24 tickDelta = _nextTick - currentTick;
    if (tickDelta <= 0) revert FixedFeeSwap__InvalidTickTraversal();

    uint256 amountIn = uint256(_amountIn);
    uint256 liquidity = uint256(activeLiquidity);
    uint256 principalToBoundary = (liquidity * uint256(uint24(tickDelta))) / BIPS;
    if (principalToBoundary == 0) revert FixedFeeSwap__InvalidTickTraversal();

    uint256 priceDiff = uint256(_currentPrice - nextTickPrice);
    uint256 cashOutToBoundary =
      FixedPointMathLib.mulDiv(liquidity, priceDiff, _scaledTimeElapsedWad());

    if (amountIn >= principalToBoundary) {
      return (principalToBoundary, cashOutToBoundary, nextTickPrice, _nextTick);
    }

    return _getCashSwapAmountWithinTick(amountIn, principalToBoundary, cashOutToBoundary, priceDiff);
  }

  /// @notice Calculate the PT out for a provided amount of cash in up to the next tick boundary.
  /// @param _amountIn The amount of cash available to trade for PT.
  /// @param _currentPrice The price calculated with the current yield tick.
  /// @param _nextTick The next initialized tick within one word which is set as the boundary.
  /// @dev This note documents a cash→PT swap where the trader provides cash in and receives PT out. This
  /// function computes a single segment; the outer loop in `_executeSwapLoop` orchestrates multiple segments
  /// and handles tick crossing. The swap may cross one or more initialized tick boundaries. Because the price is expressed via the
  /// discount factor exp(-r * t), the swap must be evaluated segment-by-segment between initialized
  /// ticks, consuming cash to move the yield from the current yield r0 toward the next boundary yield rNext.
  /// 
  /// The concrete scenario assumed by this note is t = 0.5, an initial yield r0 = 665, and the next
  /// initialized tick boundary at rNext = 650. The swap starts in segment 1 with active liquidity
  /// L1 = 3,500,000. If the swap reaches the boundary and crosses the initialized tick, the active
  /// liquidity updates to L2 = 1,000,000 for segment 2. The trader is selling 6,000 units of cash.
  /// 
  /// The implementation first computes how much cash is required to move from the current yield r to the
  /// next initialized tick at yield rNext within the current segment liquidity L. The cash required to
  /// reach the next tick boundary is:
  /// 
  ///     Cash_in_seg = (L / t) * (exp(-rNext * t) - exp(-r * t))
  /// 
  /// where r is the yield at the start of the segment step and L is the active segment liquidity
  /// (L = L1 before the first crossing, and L = L2 after crossing to the next segment).
  ///
  /// If `Cash_in_seg` is less than or equal to the trader's remaining cash budget, then the swap reaches the
  /// boundary at rNext = 650. In that case, the implementation consumes exactly `Cash_in_seg` cash, updates
  /// the state to the boundary yield, and returns `(cashInToBoundary, principalOutToBoundary, nextTickPrice,
  /// nextTick)`, signaling to the caller that a tick crossing is needed. The caller crosses the initialized
  /// tick (updating `feeGrowthOutside` and adjusting `activeLiquidity` from L1 to L2) before invoking this
  /// function again. This loop continues until either the cash is fully consumed or the swap can no longer
  /// reach the next boundary with the remaining cash.
  /// 
  /// If instead the trader’s remaining cash is insufficient to reach the next initialized tick, the swap
  /// stays within the current segment. In that partial-fill case, the remaining cash amount C moves the
  /// discount factor from exp(-r0 * t) to a new level exp(-r1 * t) according to the segment liquidity.
  /// Solving for the end yield r1 gives:
  /// 
  ///     r1 = -(1 / t) * ln( exp(-r0 * t) + (t / L) * C )
  /// 
  /// where r0 is the yield at the start of this final segment step (665 for the first segment in this
  /// scenario), L is the active liquidity for that step (L1 unless the boundary has already been crossed),
  /// and C is the remaining cash being swapped in during this step. The implementation must ensure the
  /// quantity inside the logarithm remains strictly positive; under correct direction conventions this
  /// should hold automatically, but defensive checks are appropriate because an invalid sign convention or
  /// an over-consumption bug would violate the domain of ln().
  /// 
  /// Once r1 is computed, the swap finalizes within the segment, and the PT out for that final step (and
  /// thus the total PT out for the trade) is derived from the protocol's cash→PT accounting using the
  /// updated end yield. When the swap completes within a tick range, this function delegates to
  /// `_getPrincipalSwapAmountWithinTick`, which computes the partial amounts proportionally. The total swap
  /// outcome is the cumulative PT out across any full boundary-crossing steps plus the PT out from this
  /// final in-segment step, and the final yield state is r1 (or the final boundary yield if the last step
  /// landed exactly on an initialized tick).
  /// @return amountInConsumed Cash consumed in this step. Equals `_amountIn` if the swap completes within
  /// the tick range, otherwise equals `cashInToBoundary` when the boundary is reached.
  /// @return principalOut PT tokens to send to the trader for this segment.
  /// @return newPrice Price after this step, to be used as `_currentPrice` in the next iteration.
  /// @return newTick Tick after this step. If equal to `_nextTick`, the caller should cross the tick.
  function _getPrincipalSwapAmount(int256 _amountIn, int256 _currentPrice, int24 _nextTick)
    internal
    returns (uint256, uint256, int256, int24)
  {
    if (_amountIn <= 0) revert FixedFeeSwap__SwapAmountCannotBeZero();
    int256 nextTickPrice = tickToPrice(_nextTick);
    if (nextTickPrice < _currentPrice) revert FixedFeeSwap__InvalidPriceDirection();

    int24 tickDelta = currentTick - _nextTick;
    if (tickDelta <= 0) revert FixedFeeSwap__InvalidTickTraversal();

    uint256 amountIn = uint256(_amountIn);
    uint256 liquidity = uint256(activeLiquidity);
    uint256 priceDiff = uint256(nextTickPrice - _currentPrice);
    uint256 principalOutToBoundary = (liquidity * uint256(uint24(tickDelta))) / BIPS;
    uint256 cashInToBoundary =
      FixedPointMathLib.mulDiv(liquidity, priceDiff, _scaledTimeElapsedWad());
    if (cashInToBoundary == 0) revert FixedFeeSwap__InvalidTickTraversal();

    if (amountIn >= cashInToBoundary) {
      return (cashInToBoundary, principalOutToBoundary, nextTickPrice, _nextTick);
    }

    return _getPrincipalSwapAmountWithinTick(
      amountIn, cashInToBoundary, principalOutToBoundary, priceDiff, tickDelta
    );
  }

  /// @notice Calculates the principal token amount for a liquidity position across a tick range
  /// @dev Amount is linear in tick range: amount = liquidity * (upperYield - lowerYield)
  /// @param _lowerYield The lower tick boundary of the range
  /// @param _upperYield The upper tick boundary of the range
  /// @param _liquidity The liquidity amount, positive for mint and negative for burn
  /// @return The principal token delta: positive values indicate deposit required, negative values indicate withdrawal
  function _getAmountPrincipleDelta(int24 _lowerYield, int24 _upperYield, int128 _liquidity)
    internal
    pure
    returns (int256)
  {
    int256 liquidity = int256(_liquidity);
    uint256 absLiquidity = liquidity.abs();
    uint256 amount = absLiquidity * uint256(uint24(_upperYield - _lowerYield));
    return liquidity < 0 ? -int256(amount) : int256(amount);
  }

  /// @notice Calculates the cash token amount for a liquidity position across a tick range
  /// @dev Amount depends on time: amount = liquidity * (priceLower - priceUpper) / scaledTime
  /// @param _lowerYield The lower tick boundary of the range
  /// @param _upperYield The upper tick boundary of the range
  /// @param _liquidity The liquidity amount, positive for mint and negative for burn
  /// @return The cash token delta: positive values indicate deposit required, negative values indicate withdrawal
  function _getAmountCashDelta(int24 _lowerYield, int24 _upperYield, int128 _liquidity)
    internal
    returns (int256)
  {
    int256 liquidity = int256(_liquidity);
    uint256 absLiquidity = liquidity.abs();
    int256 _upperTickPrice = tickToPrice(_upperYield);
    int256 _lowerTickPrice = tickToPrice(_lowerYield);
    uint256 scaledTimeWad = _scaledTimeElapsedWad();
    if (_lowerTickPrice < _upperTickPrice) revert FixedFeeSwap__InvalidPriceDirection();
    uint256 priceDiff = uint256(_lowerTickPrice - _upperTickPrice);
    uint256 amount = FixedPointMathLib.mulDiv(absLiquidity, priceDiff, scaledTimeWad);
    return liquidity < 0 ? -int256(amount) : int256(amount);
  }

  // ============ Fee Tracking Functions ============

  /// @notice Accrues pending fees for a position and updates its fee growth snapshots
  /// @param position The position storage pointer to update
  function _accruePositionFees(PositionInfo storage position) internal {
    if (position.liquidity <= 0) return;

    (uint256 fg0, uint256 fg1) = _getFeeGrowthInside(position.tickLower, position.tickUpper);
    uint256 liq = uint256(uint128(position.liquidity));

    // Note: Cast to uint128 assumes fee amounts won't exceed type(uint128).max.
    // This is safe in practice as it would require mass fee accumulation beyond realistic volumes.
    position.tokensOwed0 += uint128(FixedPointMathLib.mulDiv(fg0 - position.feeGrowthInside0LastX128, liq, Q128));
    position.tokensOwed1 += uint128(FixedPointMathLib.mulDiv(fg1 - position.feeGrowthInside1LastX128, liq, Q128));

    position.feeGrowthInside0LastX128 = fg0;
    position.feeGrowthInside1LastX128 = fg1;
  }

  /// @notice Refreshes fee growth snapshots for a position (used when liquidity goes from 0 to positive)
  /// @param position The position storage pointer to update
  function _refreshFeeSnapshots(PositionInfo storage position) internal {
    (uint256 fg0, uint256 fg1) = _getFeeGrowthInside(position.tickLower, position.tickUpper);
    position.feeGrowthInside0LastX128 = fg0;
    position.feeGrowthInside1LastX128 = fg1;
  }

  /// @notice Calculates fee growth inside a tick range
  /// @param tickLower The lower tick boundary
  /// @param tickUpper The upper tick boundary
  /// @return fg0 Fee growth for TOKEN0 inside the range
  /// @return fg1 Fee growth for TOKEN1 inside the range
  function _getFeeGrowthInside(int24 tickLower, int24 tickUpper)
    internal
    view
    returns (uint256 fg0, uint256 fg1)
  {
    TickInfo storage lower = ticks[tickLower];
    TickInfo storage upper = ticks[tickUpper];

    bool belowLower = currentTick < tickLower;
    bool aboveUpper = currentTick >= tickUpper;

    uint256 below0 = belowLower ? feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128 : lower.feeGrowthOutside0X128;
    uint256 below1 = belowLower ? feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128 : lower.feeGrowthOutside1X128;
    uint256 above0 = aboveUpper ? feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128 : upper.feeGrowthOutside0X128;
    uint256 above1 = aboveUpper ? feeGrowthGlobal1X128 - upper.feeGrowthOutside1X128 : upper.feeGrowthOutside1X128;

    fg0 = feeGrowthGlobal0X128 - below0 - above0;
    fg1 = feeGrowthGlobal1X128 - below1 - above1;
  }

  /// @notice Updates fee growth outside values when crossing a tick
  /// @dev Crossing a tick flips the meaning of "outside" - subtracting from global inverts
  ///      the above/below perspective. This is the standard Uniswap v3 tick crossing pattern.
  /// @param tick The tick being crossed
  function _crossTick(int24 tick) internal {
    TickInfo storage info = ticks[tick];
    info.feeGrowthOutside0X128 = feeGrowthGlobal0X128 - info.feeGrowthOutside0X128;
    info.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - info.feeGrowthOutside1X128;
  }

  // ============ Fee Helper Functions ============

  /// @notice Returns the amount available to swap after fees, given a gross exact-in amount.
  function _netOfFee(uint256 amountInGross) internal view returns (uint256) {
    return FixedPointMathLib.mulDiv(amountInGross, FEE_DENOMINATOR - FEE_RATE, FEE_DENOMINATOR);
  }

  /// @notice Returns the gross amount required to obtain a desired net-of-fee amount.
  /// @dev Rounds up so the protocol is not underpaid on fees.
  function _grossFromNet(uint256 amountInNet) internal view returns (uint256) {
    return FixedPointMathLib.mulDivUp(amountInNet, FEE_DENOMINATOR, FEE_DENOMINATOR - FEE_RATE);
  }
}
