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

  // Tracking ticks
  mapping(int24 tick => TickInfo) ticks;
  mapping(int16 wordPos => uint256) tickBitmap;
  mapping(bytes32 positionId => PositionInfo) positions;

  // 1. Market opens on deployment. We will
  // want to make this better. Maturities may want
  // to end at the same time.
  constructor(uint48 _lengthOfMarket, address _token0, address _token1, IPoolManager _manager)
    BaseHook(_manager)
  {
    START_TIME = uint48(block.timestamp);
    MATURITY = uint48(block.timestamp) + _lengthOfMarket;
    TOKEN0 = IERC20(_token0);
    TOKEN1 = IERC20(_token1);
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

    // 3. Loop unitl tokens specified is either exhausted or we hit the specified price limit
    int256 amountInRemaining = amountIn;
    uint256 amountOutCalculated = 0;

    // Calculate prices
    // Only support exact In
    // TODO: Can thin be greater than the price limit. I don't think the price limit is being
    // handled correctly.
    while (amountInRemaining != 0) {
      if (priceLimitWad != 0) {
        uint256 stepPriceAbs = currentPrice.abs();
        bool hitLimit =
          principalForCash ? stepPriceAbs <= priceLimitWad : stepPriceAbs >= priceLimitWad;
        if (hitLimit) break;
      }

      // 4. Initialize next tick
      // TODO: Check the new  tick logic does not messs this up
      // TODO: And spacing param
      bool _tickMovingLeft = !principalForCash;
      // `nextInitializedTickWithinOneWord(..., lte=true)` searches for ticks `<=` the given tick.
      // For leftward swaps we want the next tick strictly to the left, otherwise we can get
      // `_nextTick == currentTick` when `currentTick` is not initialized (e.g. at tick 0),
      // which causes `tickDelta == 0` and reverts.
      int24 _searchTick = currentTick;
      if (_tickMovingLeft && currentTick != type(int24).min) {
        _searchTick = currentTick - YIELD_PER_TICK;
      }
      (int24 _nextTick, bool _initialized) =
        tickBitmap.nextInitializedTickWithinOneWord(_searchTick, YIELD_PER_TICK, _tickMovingLeft);
      // TODO Check if tick hits min or max tick
      uint256 _stepAmountIn;
      uint256 _stepAmountOut;
      int24 _stepTick;

      // 1. See if we hit the tick boundry if we do then we will have to do another loop
      // 2.
      int256 _stepCurrentPrice;
      (_stepAmountIn, _stepAmountOut, _stepCurrentPrice, _stepTick) =
        _calculateSwap(amountInRemaining, currentPrice, _nextTick, principalForCash);
      if (_stepAmountIn == 0) revert FixedFeeSwap__SwapStepProducedZeroIn();
      if (_stepAmountIn.toInt256() > amountInRemaining) {
        // Defensive: indicates inconsistent step math.
        revert FixedFeeSwap__InvalidHookParams();
      }

      // Tick has been crossed
      // - Move the price to the new price
      // - Move to the next tick
      // - Consume the liquidity
      // Means we have crossed a tick
      // Cross tick if next price is current price and the current tick is initialized
      // And the stepTick is the same as the next tick because this means we hit the
      // next tick boundary rather than be inside of the boundary.
      bool _hitTickBoundary = _stepTick == _nextTick;
      if (_hitTickBoundary && _initialized) {
        TickInfo storage info = ticks[_nextTick];
        int128 _liquidityNet = info.liquidityNet;
        // if we're moving leftward, we interpret liquidityNet as the opposite sign
        // safe because liquidityNet cannot be type(int128).min
        if (_tickMovingLeft) _liquidityNet = -_liquidityNet;
        activeLiquidity = LiquidityMath.addDelta(activeLiquidity, _liquidityNet);
      }

      currentPrice = _stepCurrentPrice;
      // When moving left, `nextInitializedTickWithinOneWord` searches `<= currentTick`.
      // If we land exactly on a tick boundary, decrement by `tickSpacing` so the next
      // iteration continues searching strictly to the left (and can cross word boundaries).
      currentTick = (_tickMovingLeft && _hitTickBoundary) ? _stepTick - YIELD_PER_TICK : _stepTick;
      amountInRemaining -= _stepAmountIn.toInt256();
      amountOutCalculated += _stepAmountOut;
    }

    // Calculate final amounts
    uint256 amountInUsed = uint256((amountIn - amountInRemaining));

    // Execute token transfers
    // TOKEN0 = principal token, TOKEN1 = cash token
    if (principalForCash) {
      // User sends principal (TOKEN0), receives cash (TOKEN1)
      if (amountInUsed != 0) TOKEN0.safeTransferFrom(_sender, address(this), amountInUsed);
      if (amountOutCalculated != 0) TOKEN1.safeTransfer(_sender, amountOutCalculated);
      return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
    } else {
      // User sends cash (TOKEN1), receives principal (TOKEN0)
      if (amountInUsed != 0) TOKEN1.safeTransferFrom(_sender, address(this), amountInUsed);
      if (amountOutCalculated != 0) TOKEN0.safeTransfer(_sender, amountOutCalculated);
      return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
    }
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
    // First calculate the liquidity delta
    BalanceDelta memory _balanceDelta =
      _modifyLiquidity(msg.sender, _tickUpper, _tickLower, _liquidity.toInt128());
    if (
      _balanceDelta.amount0.toUint128() > _amount0Max
        || _balanceDelta.amount1.toUint128() > _amount1Max
    ) revert FixedFeeSwap__InvalidLiquidityAmount();
    bytes32 _positionId = keccak256(abi.encodePacked(_tickUpper, _tickLower, msg.sender));
    positions[_positionId] = PositionInfo({
      tickUpper: _tickUpper,
      tickLower: _tickLower,
      owner: msg.sender,
      liquidity: _liquidity.toInt128()
    });

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
    PositionInfo memory _positionInfo = positions[_positionId];
    if (_positionInfo.owner == address(0)) revert FixedFeeSwap__PositionNotFound();
    if (_positionInfo.owner != msg.sender) revert FixedFeeSwap__NotPositionOwner();
    BalanceDelta memory _balanceDelta = _modifyLiquidity(
      msg.sender, _positionInfo.tickUpper, _positionInfo.tickLower, _liquidity.toInt128()
    );
    if (
      _balanceDelta.amount0.toUint128() > _amount0Max
        || _balanceDelta.amount1.toUint128() > _amount1Max
    ) revert FixedFeeSwap__InvalidLiquidityAmount();
    positions[_positionId] = PositionInfo({
      tickUpper: _positionInfo.tickUpper,
      tickLower: _positionInfo.tickLower,
      owner: msg.sender,
      liquidity: _positionInfo.liquidity + _liquidity.toInt128()
    });

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
    PositionInfo memory _positionInfo = positions[_positionId];
    if (_positionInfo.owner == address(0)) revert FixedFeeSwap__PositionNotFound();
    if (_positionInfo.owner != msg.sender) revert FixedFeeSwap__NotPositionOwner();
    BalanceDelta memory _balanceDelta =
      _modifyLiquidity(msg.sender, _positionInfo.tickUpper, _positionInfo.tickLower, _liquidity);
    if (_balanceDelta.amount0.abs() < _amount0Min || _balanceDelta.amount1.abs() < _amount1Min) {
      revert FixedFeeSwap__InvalidLiquidityAmount();
    }
    positions[_positionId] = PositionInfo({
      tickUpper: _positionInfo.tickUpper,
      tickLower: _positionInfo.tickLower,
      owner: msg.sender,
      liquidity: _positionInfo.liquidity + _liquidity
    });

    // TODO Make sure these helpers are taking the absolute value
    if (_balanceDelta.amount0 < 0) TOKEN0.safeTransfer(msg.sender, _balanceDelta.amount0.abs());

    if (_balanceDelta.amount1 < 0) TOKEN1.safeTransfer(msg.sender, _balanceDelta.amount1.abs());
  }

  /// Shared liquidity functionality
  function _modifyLiquidity(address _owner, int24 _tickUpper, int24 _tickLower, int128 _liquidity)
    internal
    returns (BalanceDelta memory)
  {
    if (_tickLower >= _tickUpper) revert FixedFeeSwap__InvalidTickRange();

    /// TODO make these safe
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

      // TODO check above max liquidity
      // Not sure why we need this

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

    // TODO: Handle Fee collection

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

    // TODO handle fee growth
    // - I don't understand this too well
    // if (liquidityGrossBefore == 0) {
    //     // by convention, we assume that all growth before a tick was initialized happened
    // _below_ the tick if (tick <= self.slot0.tick()) {
    //         info.feeGrowthOutside0X128 = self.feeGrowthGlobal0X128;
    //         info.feeGrowthOutside1X128 = self.feeGrowthGlobal1X128;
    //     }
    // }

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
}
