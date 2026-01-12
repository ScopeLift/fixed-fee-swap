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

/// @dev Struct to hold swap step variables to avoid stack too deep
struct SwapStepCache {
  int24 nextTick;
  bool initialized;
  uint256 stepAmountInNet;
  uint256 stepAmountOut;
  int256 stepPrice;
  int24 stepTick;
  uint256 stepAmountInGross;
  uint256 stepFee;
  bool hitTickBoundary;
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

  /// @notice Fee rate in hundredths of a bip (1 = 0.0001%)
  /// @dev 3000 = 0.30% fee, similar to Uniswap v3 medium tier
  uint24 public immutable FEE_RATE;

  /// @notice Denominator for fee calculations (1e6 for hundredths of a bip)
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
    START_TIME = uint48(block.timestamp);
    MATURITY = uint48(block.timestamp) + _lengthOfMarket;
    TOKEN0 = IERC20(_token0);
    TOKEN1 = IERC20(_token1);
    FEE_RATE = _feeRate;
  }

  /**
   * @dev Liquidity was attempted to be added or removed via the `PoolManager` instead of the hook.
   */
  error LiquidityOnlyViaHook();

  error FixedFeeSwap__InvalidTickRange();

  error FixedFeeSwap__PositionNotFound();

  error FixedFeeSwap__NotPositionOwner();

  error FixedFeeSwap__InvalidLiquidityAmount();

  error FixedFeeSwap__InvalidHookParams();

  error FixedFeeSwap__SwapAmountCannotBeZero();

  error FixedFeeSwap__NoActiveLiquidity();

  error FixedFeeSwap__SwapStepProducedZeroIn();

  error FixedFeeSwap__TimeElapsedIsZero();

  error FixedFeeSwap__InvalidPriceDirection();

  error FixedFeeSwap__InvalidTickTraversal();

  error FixedFeeSwap__LiquidityDeltaMustBeNegative();

  error FixedFeeSwap__InsufficientPositionLiquidity();

  function _scaledTimeElapsedWad() internal view returns (uint256) {
    uint256 elapsed = block.timestamp - START_TIME;
    if (elapsed == 0) revert FixedFeeSwap__TimeElapsedIsZero();
    return (elapsed * SCALE_FACTOR) / (MATURITY - START_TIME);
  }

  function _getCashSwapAmountWithinTick(
    uint256 amountIn,
    uint256 principalToBoundary,
    uint256 cashOutToBoundary,
    uint256 priceDiff
  ) internal view returns (uint256, uint256, int256, int24) {
    uint256 cashOut = FixedPointMathLib.mulDiv(cashOutToBoundary, amountIn, principalToBoundary);
    uint256 priceDelta = FixedPointMathLib.mulDiv(priceDiff, amountIn, principalToBoundary);
    int24 ticksMoved =
      int24(uint24(FixedPointMathLib.mulDiv(amountIn, BIPS, uint256(activeLiquidity))));
    return (amountIn, cashOut, currentPrice - int256(priceDelta), currentTick + ticksMoved);
  }

  function _getPrincipalSwapAmountWithinTick(
    uint256 amountIn,
    uint256 cashInToBoundary,
    uint256 principalOutToBoundary,
    uint256 priceDiff,
    int24 tickDelta
  ) internal view returns (uint256, uint256, int256, int24) {
    uint256 principalOut =
      FixedPointMathLib.mulDiv(principalOutToBoundary, amountIn, cashInToBoundary);
    uint256 priceDelta = FixedPointMathLib.mulDiv(priceDiff, amountIn, cashInToBoundary);
    uint256 ticksMoved =
      FixedPointMathLib.mulDiv(uint256(uint24(tickDelta)), amountIn, cashInToBoundary);
    return (
      amountIn,
      principalOut,
      currentPrice + int256(priceDelta),
      currentTick - int24(uint24(ticksMoved))
    );
  }

  function _beforeAddLiquidity(
    address,
    PoolKey calldata,
    ModifyLiquidityParams calldata,
    bytes calldata
  ) internal virtual override returns (bytes4) {
    revert LiquidityOnlyViaHook();
  }

  function _beforeRemoveLiquidity(
    address,
    PoolKey calldata,
    ModifyLiquidityParams calldata,
    bytes calldata
  ) internal virtual override returns (bytes4) {
    revert LiquidityOnlyViaHook();
  }

  /// @dev Hook data schema: `abi.encode(int256 amountIn, bool principalForCash, uint256
  /// priceLimitWad)`. If `principalForCash` is true, TOKEN0 is input and TOKEN1 is output (tick
  /// increases, price decreases).
  /// If `priceLimitWad` is 0, the swap only stops once `amountIn` is fully consumed.
  /// @dev amountIn is the gross amount (before fees) the trader provides.
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

  /// @dev Internal function to execute the swap loop, separated to avoid stack too deep
  function _executeSwapLoop(uint256 amountInGross, bool principalForCash, uint256 priceLimitWad)
    internal
    returns (uint256 amountInUsed, uint256 amountOutCalculated)
  {
    uint256 amountInRemainingGross = amountInGross;
    bool tickMovingLeft = !principalForCash;

    while (amountInRemainingGross != 0) {
      // Check price limit
      if (priceLimitWad != 0) {
        uint256 stepPriceAbs = currentPrice.abs();
        bool hitLimit =
          principalForCash ? stepPriceAbs <= priceLimitWad : stepPriceAbs >= priceLimitWad;
        if (hitLimit) break;
      }

      // Compute net-of-fee input
      uint256 amountInRemainingNet = _netOfFee(amountInRemainingGross);
      if (amountInRemainingNet == 0) break;

      // Execute one swap step
      SwapStepCache memory step =
        _computeSwapStep(amountInRemainingNet, amountInRemainingGross, tickMovingLeft, principalForCash);

      // Update fee growth (before tick crossing)
      if (step.stepFee > 0 && activeLiquidity > 0) {
        if (principalForCash) {
          feeGrowthGlobal0X128 += FixedPointMathLib.mulDiv(step.stepFee, Q128, activeLiquidity);
        } else {
          feeGrowthGlobal1X128 += FixedPointMathLib.mulDiv(step.stepFee, Q128, activeLiquidity);
        }
      }

      // Cross tick if needed
      if (step.hitTickBoundary && step.initialized) {
        _crossTick(step.nextTick);
        int128 liquidityNet = ticks[step.nextTick].liquidityNet;
        if (tickMovingLeft) liquidityNet = -liquidityNet;
        activeLiquidity = LiquidityMath.addDelta(activeLiquidity, liquidityNet);
      }

      // Update state
      currentPrice = step.stepPrice;
      currentTick = (tickMovingLeft && step.hitTickBoundary)
        ? step.stepTick - YIELD_PER_TICK
        : step.stepTick;
      amountInRemainingGross -= step.stepAmountInGross;
      amountOutCalculated += step.stepAmountOut;
    }

    amountInUsed = amountInGross - amountInRemainingGross;
  }

  /// @dev Computes a single swap step, returns results in a struct to avoid stack issues
  function _computeSwapStep(
    uint256 amountInRemainingNet,
    uint256 amountInRemainingGross,
    bool tickMovingLeft,
    bool principalForCash
  ) internal returns (SwapStepCache memory step) {
    // Find next initialized tick
    int24 searchTick = currentTick;
    if (tickMovingLeft && currentTick != type(int24).min) {
      searchTick = currentTick - YIELD_PER_TICK;
    }
    (step.nextTick, step.initialized) =
      tickBitmap.nextInitializedTickWithinOneWord(searchTick, YIELD_PER_TICK, tickMovingLeft);

    // Compute the step using NET input
    (step.stepAmountInNet, step.stepAmountOut, step.stepPrice, step.stepTick) =
      _calculateSwap(amountInRemainingNet.toInt256(), currentPrice, step.nextTick, principalForCash);
    if (step.stepAmountInNet == 0) revert FixedFeeSwap__SwapStepProducedZeroIn();

    // Convert NET to GROSS
    step.stepAmountInGross = _grossFromNet(step.stepAmountInNet);
    if (step.stepAmountInGross > amountInRemainingGross) {
      step.stepAmountInGross = amountInRemainingGross;
    }
    if (step.stepAmountInGross < step.stepAmountInNet) revert FixedFeeSwap__InvalidHookParams();
    step.stepFee = _feeFromNetAndGross(step.stepAmountInNet, step.stepAmountInGross);
    step.hitTickBoundary = step.stepTick == step.nextTick;
  }

  /// V4 allows unique position at the same range
  /// ? What is liquidity delta where does it come from
  /// 1. updateTick ->
  ///
  /// A tick can step multiple bps
  /// 1. Creating a position for the first time
  /// TODO: V4 allow allows a recipient to be specified
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

    // Initialize or refresh snapshots when liquidity transitions from 0 -> positive.
    if (isNew || liquidityBefore == 0) {
      (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
        _getFeeGrowthInside(_tickLower, _tickUpper);
      position.feeGrowthInside0LastX128 = feeGrowthInside0X128;
      position.feeGrowthInside1LastX128 = feeGrowthInside1X128;
    }

    if (_balanceDelta.amount0.toUint128() > 0) {
      TOKEN0.safeTransferFrom(msg.sender, address(this), _balanceDelta.amount0.toUint128());
    }

    if (_balanceDelta.amount1.toUint128() > 0) {
      TOKEN1.safeTransferFrom(msg.sender, address(this), _balanceDelta.amount1.toUint128());
    }
  }

  function increaseLiquidity(
    bytes32 _positionId,
    uint256 _liquidity,
    uint256 _amount0Max,
    uint256 _amount1Max
  ) external virtual {
    PositionInfo storage position = positions[_positionId];
    if (position.owner == address(0)) revert FixedFeeSwap__PositionNotFound();
    if (position.owner != msg.sender) revert FixedFeeSwap__NotPositionOwner();

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

    // If the position had zero liquidity, refresh fee growth snapshots after ticks are (re)initialized.
    // This prevents newly added liquidity from earning fees from before it was added.
    if (liquidityBefore == 0) {
      (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
        _getFeeGrowthInside(position.tickLower, position.tickUpper);
      position.feeGrowthInside0LastX128 = feeGrowthInside0X128;
      position.feeGrowthInside1LastX128 = feeGrowthInside1X128;
    }

    if (_balanceDelta.amount0.toUint128() > 0) {
      TOKEN0.safeTransferFrom(msg.sender, address(this), _balanceDelta.amount0.toUint128());
    }

    if (_balanceDelta.amount1.toUint128() > 0) {
      TOKEN1.safeTransferFrom(msg.sender, address(this), _balanceDelta.amount1.toUint128());
    }
  }

  function decreaseLiquidity(
    bytes32 _positionId,
    int128 _liquidity,
    uint256 _amount0Min,
    uint256 _amount1Min
  ) external virtual {
    PositionInfo storage position = positions[_positionId];
    if (position.owner == address(0)) revert FixedFeeSwap__PositionNotFound();
    if (position.owner != msg.sender) revert FixedFeeSwap__NotPositionOwner();
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
  /// @param amount0Requested Maximum TOKEN0 fees to collect (0 for all)
  /// @param amount1Requested Maximum TOKEN1 fees to collect (0 for all)
  /// @return amount0 Actual TOKEN0 fees collected
  /// @return amount1 Actual TOKEN1 fees collected
  function collectFees(
    bytes32 positionId,
    address recipient,
    uint128 amount0Requested,
    uint128 amount1Requested
  ) external returns (uint128 amount0, uint128 amount1) {
    PositionInfo storage position = positions[positionId];
    if (position.owner == address(0)) revert FixedFeeSwap__PositionNotFound();
    if (position.owner != msg.sender) revert FixedFeeSwap__NotPositionOwner();

    // Update owed amounts before collection
    if (position.liquidity > 0) {
      (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
        _getFeeGrowthInside(position.tickLower, position.tickUpper);

      position.tokensOwed0 += uint128(
        FixedPointMathLib.mulDiv(
          feeGrowthInside0X128 - position.feeGrowthInside0LastX128,
          uint256(uint128(position.liquidity)),
          Q128
        )
      );
      position.tokensOwed1 += uint128(
        FixedPointMathLib.mulDiv(
          feeGrowthInside1X128 - position.feeGrowthInside1LastX128,
          uint256(uint128(position.liquidity)),
          Q128
        )
      );

      position.feeGrowthInside0LastX128 = feeGrowthInside0X128;
      position.feeGrowthInside1LastX128 = feeGrowthInside1X128;
    }

    // Calculate amounts to collect
    amount0 = amount0Requested == 0
      ? position.tokensOwed0
      : (amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested);
    amount1 = amount1Requested == 0
      ? position.tokensOwed1
      : (amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested);

    // Update owed amounts (CEI: update state before transfers)
    position.tokensOwed0 -= amount0;
    position.tokensOwed1 -= amount1;

    // Transfer fees
    if (amount0 > 0) TOKEN0.safeTransfer(recipient, amount0);
    if (amount1 > 0) TOKEN1.safeTransfer(recipient, amount1);
  }

  /// Shared liquidity functionality
  function _modifyLiquidity(address _owner, int24 _tickUpper, int24 _tickLower, int128 _liquidity)
    internal
    returns (BalanceDelta memory)
  {
    if (_tickLower >= _tickUpper) revert FixedFeeSwap__InvalidTickRange();
    if (_liquidity == 0) return BalanceDelta({amount0: 0, amount1: 0});

    bytes32 positionId = keccak256(abi.encodePacked(_tickUpper, _tickLower, _owner));
    PositionInfo storage position = positions[positionId];

    // 1) Accrue fees owed using the position's *current* liquidity, before mutating ticks.
    // This must happen before any tick data is cleared (e.g. when liquidityGross goes to 0).
    if (position.owner != address(0) && position.liquidity > 0) {
      (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
        _getFeeGrowthInside(_tickLower, _tickUpper);

      position.tokensOwed0 += uint128(
        FixedPointMathLib.mulDiv(
          feeGrowthInside0X128 - position.feeGrowthInside0LastX128,
          uint256(uint128(position.liquidity)),
          Q128
        )
      );
      position.tokensOwed1 += uint128(
        FixedPointMathLib.mulDiv(
          feeGrowthInside1X128 - position.feeGrowthInside1LastX128,
          uint256(uint128(position.liquidity)),
          Q128
        )
      );

      position.feeGrowthInside0LastX128 = feeGrowthInside0X128;
      position.feeGrowthInside1LastX128 = feeGrowthInside1X128;
    }

    // 2) Mutate ticks / bitmap / activeLiquidity
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

    return BalanceDelta({amount0: 0, amount1: 0});
  }

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

  /// Returns yield for a given tick
  function yieldToTick(int256 yieldBps) public view returns (int24) {
    return int24(yieldBps / YIELD_PER_TICK);
  }

  // Convert tick to yield by multiplying by yield per tick
  // the exponential times yield times maturity to get price
  // TODO: Change tick to int24
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

  /// @param _tick The tick that will be updated
  /// @param _liquidityDelta A new amount of liquidity to be added (subtracted) when tick is crossed
  /// from left to right (right to left)
  /// @param _upper true for updating a position's upper tick, or
  /// false for updating a position's lower tick
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

  // Tick crossing handled in higher function
  // - To consume a tick L(rnext - rcurrent)
  // - to calculate the next next (L/t * (current prince - next price)
  // Yield goes up
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

  /// @notice Calculates fee growth inside a tick range
  /// @param tickLower The lower tick boundary
  /// @param tickUpper The upper tick boundary
  /// @return feeGrowthInside0X128 Fee growth for TOKEN0 inside the range
  /// @return feeGrowthInside1X128 Fee growth for TOKEN1 inside the range
  function _getFeeGrowthInside(int24 tickLower, int24 tickUpper)
    internal
    view
    returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
  {
    TickInfo storage lower = ticks[tickLower];
    TickInfo storage upper = ticks[tickUpper];

    // Calculate fee growth below the lower tick
    uint256 feeGrowthBelow0X128;
    uint256 feeGrowthBelow1X128;
    if (currentTick >= tickLower) {
      feeGrowthBelow0X128 = lower.feeGrowthOutside0X128;
      feeGrowthBelow1X128 = lower.feeGrowthOutside1X128;
    } else {
      feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;
      feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128;
    }

    // Calculate fee growth above the upper tick
    uint256 feeGrowthAbove0X128;
    uint256 feeGrowthAbove1X128;
    if (currentTick < tickUpper) {
      feeGrowthAbove0X128 = upper.feeGrowthOutside0X128;
      feeGrowthAbove1X128 = upper.feeGrowthOutside1X128;
    } else {
      feeGrowthAbove0X128 = feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128;
      feeGrowthAbove1X128 = feeGrowthGlobal1X128 - upper.feeGrowthOutside1X128;
    }

    // Fee growth inside = global - below - above
    feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
    feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
  }

  /// @notice Updates fee growth outside values when crossing a tick
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

  /// @notice Fee paid for a step, derived from net/gross relationship.
  function _feeFromNetAndGross(uint256 amountInNet, uint256 amountInGross)
    internal
    pure
    returns (uint256)
  {
    return amountInGross - amountInNet;
  }
}
