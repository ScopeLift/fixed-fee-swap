// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LiquidityMath} from "v4-core/libraries/LiquidityMath.sol";
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

struct TokenDelta {
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
  uint256 priceLimitWad;
}

contract FixedFeeSwapMarket is BaseHook {
  using SafeCast for uint256;
  using SafeCast for int256;
  using FixedPointMathLib for int256;
  using FixedPointMathLib for int128;
  using SafeCast for int128;
  using SafeERC20 for IERC20;
  using TickBitmap for mapping(int16 => uint256);

  // ============ Events ============

  /// @notice Emitted when fees are collected from a position
  event FeesCollected(
    bytes32 indexed positionId, address indexed recipient, uint128 amount0, uint128 amount1
  );

  /// @notice Emitted when a swap is executed
  event Swap(address indexed sender, bool principalForCash, uint256 amountIn, uint256 amountOut);

  /// @notice Emitted when liquidity is modified for a position
  event LiquidityModified(
    bytes32 indexed positionId,
    address indexed owner,
    int24 tickLower,
    int24 tickUpper,
    int128 liquidityDelta,
    int128 amount0,
    int128 amount1
  );

  // ============ Errors ============

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

  /// @notice Thrown when a swap step produces zero output for nonzero input
  error FixedFeeSwap__SwapStepProducedZeroOut();

  /// @notice Thrown at START_TIME when no time has elapsed, to prevent division by zero
  error FixedFeeSwap__TimeElapsedIsZero();

  /// @notice Thrown when a tick's gross liquidity would underflow
  error FixedFeeSwap__TickLiquidityGrossUnderflow();

  /// @notice Thrown when liquidity is added or removed via PoolManager instead of this hook
  error LiquidityOnlyViaHook();

  // ============ Constants ============

  int24 constant YIELD_PER_TICK = 1;
  uint256 constant WAD = 1e18;
  uint256 constant BIPS = 10_000;
  uint256 constant SWAP_HOOK_PARAMS_LENGTH = 96;

  /// @notice Denominator for fee calculations, set to 1e6 to support hundredths of a bip
  uint256 constant FEE_DENOMINATOR = 1_000_000;

  /// @notice Q128 fixed-point multiplier for fee growth calculations
  uint256 constant Q128 = 1 << 128;

  // ============ Immutables ============

  uint48 immutable MATURITY;
  uint48 immutable START_TIME;
  IERC20 immutable TOKEN0;
  IERC20 immutable TOKEN1;

  /// @notice Fee rate in hundredths of a bip, where a value of 1 equals 0.0001%
  /// @dev 3000 = 0.30% fee, similar to Uniswap v3 medium tier
  uint24 public immutable FEE_RATE;

  // ============ State Variables ============

  int24 currentTick;
  int256 currentPrice;
  uint128 activeLiquidity;

  /// @notice Global fee growth per unit of liquidity for TOKEN0 (principal)
  uint256 public feeGrowthGlobal0X128;

  /// @notice Global fee growth per unit of liquidity for TOKEN1 (cash)
  uint256 public feeGrowthGlobal1X128;

  // ============ Mappings ============

  mapping(int24 tick => TickInfo) ticks;
  mapping(int16 wordPos => uint256) tickBitmap;
  mapping(bytes32 positionId => PositionInfo) positions;

  // ============ Constructor ============

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

  // ============ Public Functions ============

  /// @notice Returns the hook permissions indicating which callbacks this hook implements
  /// @return The permissions struct with beforeSwap enabled
  function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
    return Hooks.Permissions({
      beforeInitialize: false,
      afterInitialize: false,
      beforeAddLiquidity: true,
      afterAddLiquidity: false,
      beforeRemoveLiquidity: true,
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
  /// @param _yieldBps The yield rate in basis points
  /// @return The tick value representing this yield
  function yieldToTick(int256 _yieldBps) public pure returns (int24) {
    return int24(_yieldBps / YIELD_PER_TICK);
  }

  /// @notice Converts a tick to its corresponding discount factor price
  /// @dev Price is calculated as exp(-yield * scaledTimeElapsed) where yield = tick *
  /// YIELD_PER_TICK
  /// @param _tick The tick value to convert
  /// @return The price as a WAD-scaled discount factor, where 1e18 represents a price of 1.0
  function tickToPrice(int256 _tick) public view returns (int256) {
    uint256 _elapsed = block.timestamp - START_TIME;
    if (_elapsed == 0) return int256(WAD);
    uint256 _duration = MATURITY - START_TIME;
    if (_elapsed > _duration) _elapsed = _duration;
    uint256 _scaledTime = (_elapsed * WAD) / _duration;
    return _priceFromYieldWad(_tick * YIELD_PER_TICK * int256(WAD), _scaledTime);
  }

  // ============ External Functions ============

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
    bytes32 _positionId = _getPositionId(msg.sender, _tickUpper, _tickLower);
    PositionInfo storage _position = positions[_positionId];
    bool _isNew = _position.owner == address(0);
    int128 _liquidityBefore = _position.liquidity;

    if (_isNew) {
      _position.tickUpper = _tickUpper;
      _position.tickLower = _tickLower;
      _position.owner = msg.sender;
    }

    // Call modifyLiquidity first so tick init sets feeGrowthOutside correctly
    TokenDelta memory _tokenDelta =
      _modifyLiquidity(msg.sender, _tickUpper, _tickLower, _liquidity.toInt128());
    uint128 _amount0In = _tokenDelta.amount0.toUint128();
    uint128 _amount1In = _tokenDelta.amount1.toUint128();
    if (_amount0In > _amount0Max || _amount1In > _amount1Max) {
      revert FixedFeeSwap__InvalidLiquidityAmount();
    }

    // Update liquidity without overwriting fee fields
    _position.liquidity = _position.liquidity + _liquidity.toInt128();

    // Initialize snapshots when liquidity transitions from 0 -> positive
    // (isNew implies liquidityBefore == 0, so we only need to check liquidityBefore)
    if (_liquidityBefore == 0) _refreshFeeSnapshots(_position);

    if (_amount0In != 0) TOKEN0.safeTransferFrom(msg.sender, address(this), _amount0In);
    if (_amount1In != 0) TOKEN1.safeTransferFrom(msg.sender, address(this), _amount1In);
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
    PositionInfo storage _position = _requirePositionOwner(_positionId);
    int128 _liquidityBefore = _position.liquidity;

    // modifyLiquidity accrues fees internally and refreshes snapshots
    TokenDelta memory _tokenDelta =
      _modifyLiquidity(msg.sender, _position.tickUpper, _position.tickLower, _liquidity.toInt128());
    uint128 _amount0In = _tokenDelta.amount0.toUint128();
    uint128 _amount1In = _tokenDelta.amount1.toUint128();
    if (_amount0In > _amount0Max || _amount1In > _amount1Max) {
      revert FixedFeeSwap__InvalidLiquidityAmount();
    }

    // Update position liquidity without overwriting fee fields
    _position.liquidity = _position.liquidity + _liquidity.toInt128();

    // If the position had zero liquidity, refresh snapshots to prevent earning past fees
    if (_liquidityBefore == 0) _refreshFeeSnapshots(_position);

    if (_amount0In != 0) TOKEN0.safeTransferFrom(msg.sender, address(this), _amount0In);
    if (_amount1In != 0) TOKEN1.safeTransferFrom(msg.sender, address(this), _amount1In);
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
    PositionInfo storage _position = _requirePositionOwner(_positionId);
    if (_liquidity >= 0) revert FixedFeeSwap__LiquidityDeltaMustBeNegative();
    if (_position.liquidity < 0) revert FixedFeeSwap__InvalidLiquidityAmount();
    if (uint128(_position.liquidity) < uint128(_liquidity.abs())) {
      revert FixedFeeSwap__InsufficientPositionLiquidity();
    }

    // modifyLiquidity accrues fees owed before burning liquidity
    TokenDelta memory _tokenDelta =
      _modifyLiquidity(msg.sender, _position.tickUpper, _position.tickLower, _liquidity);
    uint128 _amount0Out = uint128(_tokenDelta.amount0.abs());
    uint128 _amount1Out = uint128(_tokenDelta.amount1.abs());
    if (_amount0Out < _amount0Min || _amount1Out < _amount1Min) {
      revert FixedFeeSwap__InvalidLiquidityAmount();
    }

    // Update position liquidity without overwriting fee fields
    _position.liquidity = _position.liquidity + _liquidity;

    if (_tokenDelta.amount0 < 0) TOKEN0.safeTransfer(msg.sender, _amount0Out);
    if (_tokenDelta.amount1 < 0) TOKEN1.safeTransfer(msg.sender, _amount1Out);
  }

  /// @notice Collects accumulated fees for a position
  /// @param _positionId The position identifier
  /// @param _recipient Address to receive the fees
  /// @param _amount0Requested Maximum TOKEN0 fees to collect, or 0 to collect all available
  /// @param _amount1Requested Maximum TOKEN1 fees to collect, or 0 to collect all available
  /// @return _amount0 Actual TOKEN0 fees collected
  /// @return _amount1 Actual TOKEN1 fees collected
  function collectFees(
    bytes32 _positionId,
    address _recipient,
    uint128 _amount0Requested,
    uint128 _amount1Requested
  ) external returns (uint128 _amount0, uint128 _amount1) {
    PositionInfo storage _position = _requirePositionOwner(_positionId);

    // Accrue pending fees before collection
    _accruePositionFees(_position);

    // Calculate amounts to collect (0 means collect all, otherwise min of requested and owed)
    _amount0 = (_amount0Requested == 0 || _amount0Requested > _position.tokensOwed0)
      ? _position.tokensOwed0
      : _amount0Requested;
    _amount1 = (_amount1Requested == 0 || _amount1Requested > _position.tokensOwed1)
      ? _position.tokensOwed1
      : _amount1Requested;

    // Update owed amounts (CEI: update state before transfers)
    _position.tokensOwed0 -= _amount0;
    _position.tokensOwed1 -= _amount1;

    // Transfer fees
    if (_amount0 > 0) TOKEN0.safeTransfer(_recipient, _amount0);
    if (_amount1 > 0) TOKEN1.safeTransfer(_recipient, _amount1);

    emit FeesCollected(_positionId, _recipient, _amount0, _amount1);
  }

  // ============ Internal Functions - Hook Overrides ============

  /// @notice Hook called before liquidity is added via PoolManager
  /// @dev Always reverts because liquidity must be managed through this contract's mint/increase
  /// functions
  function _beforeAddLiquidity(
    address,
    PoolKey calldata,
    ModifyLiquidityParams calldata,
    bytes calldata
  ) internal virtual override returns (bytes4) {
    revert LiquidityOnlyViaHook();
  }

  /// @notice Hook called before liquidity is removed via PoolManager
  /// @dev Always reverts because liquidity must be managed through this contract's decrease
  /// function
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
  /// @param _hookParams Encoded swap parameters containing amountIn, principalForCash, and
  /// priceLimitWad @return The hook selector, a zero delta because the swap is handled internally,
  /// and zero fee override
  function _beforeSwap(
    address _sender,
    PoolKey calldata,
    SwapParams calldata,
    bytes calldata _hookParams
  ) internal virtual override returns (bytes4, BeforeSwapDelta, uint24) {
    if (_hookParams.length == 0) {
      return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
    }
    if (_hookParams.length != SWAP_HOOK_PARAMS_LENGTH) revert FixedFeeSwap__InvalidHookParams();

    (int256 _amountIn, bool _principalForCash, uint256 _priceLimitWad) =
      abi.decode(_hookParams, (int256, bool, uint256));
    if (_amountIn <= 0) revert FixedFeeSwap__SwapAmountCannotBeZero();
    if (activeLiquidity == 0) revert FixedFeeSwap__NoActiveLiquidity();
    currentPrice = tickToPrice(currentTick);

    (uint256 _amountInUsed, uint256 _amountOutCalculated) =
      _executeSwapLoop(uint256(_amountIn), _principalForCash, _priceLimitWad);

    // Execute token transfers
    // TOKEN0 = principal token, TOKEN1 = cash token
    if (_principalForCash) {
      // User sends principal (TOKEN0), receives cash (TOKEN1)
      if (_amountInUsed != 0) TOKEN0.safeTransferFrom(_sender, address(this), _amountInUsed);
      if (_amountOutCalculated != 0) TOKEN1.safeTransfer(_sender, _amountOutCalculated);
    } else {
      // User sends cash (TOKEN1), receives principal (TOKEN0)
      if (_amountInUsed != 0) TOKEN1.safeTransferFrom(_sender, address(this), _amountInUsed);
      if (_amountOutCalculated != 0) TOKEN0.safeTransfer(_sender, _amountOutCalculated);
    }

    emit Swap(_sender, _principalForCash, _amountInUsed, _amountOutCalculated);
    return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
  }

  // ============ Internal Functions - Swap Execution ============

  /// @notice Executes the main swap loop, iterating through ticks until input is consumed or price
  /// limit is hit
  /// @param _amountInGross The gross input amount (before fees)
  /// @param _principalForCash True for PT→cash swap, false for cash→PT swap
  /// @param _priceLimitWad Price limit in WAD; 0 means no limit
  /// @return _amountInUsed Total gross input consumed
  /// @return _amountOutCalculated Total output tokens to send to trader
  function _executeSwapLoop(uint256 _amountInGross, bool _principalForCash, uint256 _priceLimitWad)
    internal
    returns (uint256 _amountInUsed, uint256 _amountOutCalculated)
  {
    uint256 _amountInNet = _netOfFee(_amountInGross);
    uint256 _amountInRemainingNet = _amountInNet;
    SwapContext memory _ctx = SwapContext({
      principalForCash: _principalForCash,
      tickMovingLeft: !_principalForCash,
      priceLimitWad: _priceLimitWad
    });

    while (_amountInRemainingNet != 0) {
      // Slippage protection: stop the swap if the price has moved past the caller's limit.
      // For principal→cash swaps, price decreases so we stop when price falls to the limit.
      // For cash→principal swaps, price increases so we stop when price rises to the limit.
      if (_ctx.priceLimitWad != 0) {
        uint256 _price = uint256(currentPrice);
        if (_ctx.principalForCash ? _price <= _ctx.priceLimitWad : _price >= _ctx.priceLimitWad) {
          break;
        }
      }

      // Find next initialized tick
      int24 _nextTick;
      bool _initialized;
      {
        int24 _searchTick = (_ctx.tickMovingLeft && currentTick != type(int24).min)
          ? currentTick - YIELD_PER_TICK
          : currentTick;
        (_nextTick, _initialized) = tickBitmap.nextInitializedTickWithinOneWord(
          _searchTick, YIELD_PER_TICK, _ctx.tickMovingLeft
        );
      }

      // Compute swap step and update state
      (uint256 _stepNet, uint256 _stepOut, int24 _newTick) =
        _executeSwapStep(_amountInRemainingNet, _nextTick, _initialized, _ctx);

      // If the step couldn't produce output (swap too small to move a full tick), stop.
      if (_stepNet == 0) break;

      _amountInRemainingNet -= _stepNet;
      _amountOutCalculated += _stepOut;
      currentTick = _newTick;
    }

    uint256 _totalNetUsed = _amountInNet - _amountInRemainingNet;
    _amountInUsed =
      FixedPointMathLib.mulDivUp(_totalNetUsed, FEE_DENOMINATOR, FEE_DENOMINATOR - FEE_RATE);
    if (_amountInUsed > _amountInGross) _amountInUsed = _amountInGross;
  }

  /// @notice Executes a single swap step: calculates amounts, updates fees, crosses tick if needed
  /// @param _amountInNet Net input amount (after fees) available for this step
  /// @param _nextTick The next initialized tick boundary
  /// @param _initialized Whether _nextTick is an initialized tick with liquidity changes
  /// @param _ctx Swap context containing direction flags
  function _executeSwapStep(
    uint256 _amountInNet,
    int24 _nextTick,
    bool _initialized,
    SwapContext memory _ctx
  ) internal returns (uint256, uint256, int24) {
    (uint256 _netConsumed, uint256 _amountOut, int256 _stepPrice, int24 _stepTick) = _calculateSwap(
      _amountInNet.toInt256(), currentPrice, _nextTick, _ctx.principalForCash, _ctx.priceLimitWad
    );
    // If the swap step couldn't move a full tick (sub-tick snap to zero), stop gracefully.
    if (_netConsumed == 0 || _amountOut == 0) return (0, 0, currentTick);

    // Compute fee for this step directly from net consumed and attribute to LPs.
    // Per-step tracking is needed because activeLiquidity changes at tick crossings.
    uint256 _stepFee =
      FixedPointMathLib.mulDivUp(_netConsumed, FEE_RATE, FEE_DENOMINATOR - FEE_RATE);
    if (_stepFee > 0 && activeLiquidity > 0) {
      if (_ctx.principalForCash) {
        feeGrowthGlobal0X128 += FixedPointMathLib.mulDiv(_stepFee, Q128, activeLiquidity);
      } else {
        feeGrowthGlobal1X128 += FixedPointMathLib.mulDiv(_stepFee, Q128, activeLiquidity);
      }
    }

    // Cross tick if needed
    bool _hitBoundary = _stepTick == _nextTick;
    if (_hitBoundary && _initialized) {
      _crossTick(_nextTick);
      int128 _liquidityNet = ticks[_nextTick].liquidityNet;
      if (_ctx.tickMovingLeft) _liquidityNet = -_liquidityNet;
      activeLiquidity = LiquidityMath.addDelta(activeLiquidity, _liquidityNet);
    }

    // Update price and calculate new tick.
    // The search offset (currentTick - YIELD_PER_TICK) is already applied in _executeSwapLoop,
    // so we do NOT subtract here — that would double-adjust, pushing currentTick below the
    // actually-traded price and inflating LP cash claims on withdrawal.
    currentPrice = _stepPrice;
    return (_netConsumed, _amountOut, _stepTick);
  }

  /// @notice Routes swap calculation to the appropriate direction-specific function
  /// @param _amountIn The input amount to swap
  /// @param _currentPrice The current price at the start of this step
  /// @param _nextTick The next initialized tick boundary
  /// @param _principalToCash True for PT→cash, false for cash→PT
  /// @param _priceLimitWad Price limit in WAD; 0 means no limit
  /// @return amountInConsumed Amount of input consumed
  /// @return amountOut Amount of output produced
  /// @return newPrice Price after the swap step
  /// @return newTick Tick after the swap step
  function _calculateSwap(
    int256 _amountIn,
    int256 _currentPrice,
    int24 _nextTick,
    bool _principalToCash,
    uint256 _priceLimitWad
  ) internal view returns (uint256, uint256, int256, int24) {
    if (_principalToCash) {
      return _getCashSwapAmount(_amountIn, _currentPrice, _nextTick, _priceLimitWad);
    }
    return _getPrincipalSwapAmount(_amountIn, _currentPrice, _nextTick, _priceLimitWad);
  }

  // ============ Internal Functions - PT→Cash Swap Math ============
  //
  // Worked example — PT→cash swap crossing an initialized tick boundary
  //
  // This function computes a single segment; `_executeSwapLoop` orchestrates multiple segments
  // and handles tick crossing.
  //
  // Scenario: trader sells 9,000 PT for cash. Active segment liquidity L0 = 3,000,000.
  // Next initialized tick is 25 bips away (650 − 625 = 25 bips).
  //
  // PT required to traverse exactly to the next boundary:
  //     PT_in_seg = L0 * (r0 − rNext)
  // where r0 is the start yield, rNext is the boundary yield, L0 is the segment liquidity.
  // Here 7,500 PT reaches the boundary; 1,500 PT remains for the next segment.
  // (25 bips = 0.0025, so L0 = 7,500 / 0.0025 = 3,000,000 = 300 PT per bip.)
  //
  // Cash out for any segment is the integral of the discount-factor price over the yield move:
  //     CashOut = (Lseg / t) * (exp(-r0 * t) - exp(-r1 * t))
  // where t is time-to-maturity, r0/r1 are the start/end yields for the segment.
  //
  // After crossing, the remaining PT moves yield within the next segment (L1 = 1,000,000):
  //     Δr = X / L1
  // (1,500 / 1,000,000 = 0.0015 = 15 bips; L1 = 100 PT per bip.)
  //
  // Within-tick completion delegates to `_getCashSwapAmountWithinTick`.
  // Total cash out = sum of per-segment cash outs.

  /// @notice Calculate cash out for PT in, up to the next tick boundary
  /// @param _amountIn The amount of PT available to trade for cash
  /// @param _currentPrice The price calculated with the current yield tick
  /// @param _nextTick The next initialized tick boundary
  /// @param _priceLimitWad Price limit in WAD; 0 means no limit
  /// @return _amountInConsumed PT consumed in this step
  /// @return _cashOut Cash tokens to send to the trader
  /// @return _newPrice Price after this step
  /// @return _newTick Tick after this step; if equal to `_nextTick`, caller should cross the tick
  function _getCashSwapAmount(
    int256 _amountIn,
    int256 _currentPrice,
    int24 _nextTick,
    uint256 _priceLimitWad
  )
    internal
    view
    returns (uint256 _amountInConsumed, uint256 _cashOut, int256 _newPrice, int24 _newTick)
  {
    if (_amountIn <= 0) revert FixedFeeSwap__SwapAmountCannotBeZero();
    if (_currentPrice <= 0) revert FixedFeeSwap__InvalidPriceDirection();

    uint256 _scaledTime = _scaledTimeElapsedWad();
    int256 _startYieldWad = _yieldWadFromPrice(_currentPrice, _scaledTime);

    int256 _nextTickPrice = tickToPrice(_nextTick);
    if (_nextTickPrice > _currentPrice) revert FixedFeeSwap__InvalidPriceDirection();

    // For PT→cash, price decreases so the limit is a minimum price.
    // Use the limit as target if it's higher (closer) than the tick boundary.
    int256 _targetPrice = _nextTickPrice;
    int256 _targetYieldWad = int256(_nextTick) * int256(WAD);
    if (_targetYieldWad <= _startYieldWad) revert FixedFeeSwap__InvalidTickTraversal();
    if (_priceLimitWad != 0 && int256(_priceLimitWad) > _targetPrice) {
      _targetPrice = int256(_priceLimitWad);
      _targetYieldWad = _yieldWadFromPrice(_targetPrice, _scaledTime);
    }

    if (_targetPrice > _currentPrice) revert FixedFeeSwap__InvalidPriceDirection();
    if (_targetYieldWad <= _startYieldWad) revert FixedFeeSwap__InvalidTickTraversal();

    uint256 _principalToTarget = FixedPointMathLib.mulDivUp(
      uint256(_targetYieldWad - _startYieldWad), uint256(activeLiquidity), BIPS * WAD
    );
    if (_principalToTarget == 0) revert FixedFeeSwap__InvalidTickTraversal();

    if (uint256(_amountIn) >= _principalToTarget) {
      _amountInConsumed = _principalToTarget;
      if (_targetPrice == _nextTickPrice) {
        // Exact tick boundary — no snapping needed
        _newTick = _nextTick;
        _newPrice = _targetPrice;
      } else {
        // Price limit mid-tick — snap to floored tick for consistent accounting
        _newTick = _wadToTick(_targetYieldWad);
        _newPrice = _priceFromYieldWad(int256(_newTick) * int256(WAD), _scaledTime);
        // If snapping pushed the price back to or past the start, the limit is unreachable
        if (_newPrice >= _currentPrice) return (0, 0, 0, 0);
      }
      _cashOut = FixedPointMathLib.mulDiv(
        uint256(activeLiquidity), uint256(_currentPrice - _newPrice), _scaledTime
      );
      return (_amountInConsumed, _cashOut, _newPrice, _newTick);
    }

    return _getCashSwapAmountWithinTick(uint256(_amountIn), _currentPrice, _startYieldWad);
  }

  /// @notice Computes within-tick swap for PT→cash using exact exponential math
  /// @dev Uses expWad to handle fractional tick movements: endPrice = exp(-endYield / BIPS *
  /// scaledTime) @param _amountIn The amount of principal tokens to swap
  /// @param _startPrice The price at the start of this swap step
  /// @param _startYieldWad The WAD-scaled yield at the start of this swap step
  /// @return _amountInConsumed Amount of input consumed
  /// @return _cashOut Amount of cash tokens output
  /// @return _newPrice Price after the swap
  /// @return _newTick Tick after the swap
  function _getCashSwapAmountWithinTick(
    uint256 _amountIn,
    int256 _startPrice,
    int256 _startYieldWad
  )
    internal
    view
    returns (uint256 _amountInConsumed, uint256 _cashOut, int256 _newPrice, int24 _newTick)
  {
    _amountInConsumed = _amountIn;
    uint256 _scaledTime = _scaledTimeElapsedWad();

    // Yield movement is linear in PT: Δyield = PT_in * BIPS / L
    int256 _endYieldWad = _startYieldWad
      + int256(FixedPointMathLib.mulDiv(_amountIn, BIPS * WAD, uint256(activeLiquidity)));

    // Snap to floored integer tick so swap output matches LP composition accounting.
    // Returns zero consumed/output if the tick didn't move (swap too small).
    _newTick = _wadToTick(_endYieldWad);
    _newPrice = _priceFromYieldWad(int256(_newTick) * int256(WAD), _scaledTime);

    if (_newPrice >= _startPrice) return (0, 0, _startPrice, _wadToTick(_startYieldWad));

    // Cash_out = (L / scaledTime) * (startPrice - newPrice)
    _cashOut = FixedPointMathLib.mulDiv(
      uint256(activeLiquidity), uint256(_startPrice - _newPrice), _scaledTime
    );
  }

  // ============ Internal Functions - Cash→PT Swap Math ============
  //
  // Worked example — cash→PT swap crossing an initialized tick boundary
  //
  // This function computes a single segment; `_executeSwapLoop` orchestrates multiple segments
  // and handles tick crossing.
  //
  // Scenario: t = 0.5, initial yield r0 = 665, next initialized tick rNext = 650.
  // Segment 1 liquidity L1 = 3,500,000; after crossing, L2 = 1,000,000. Trader sells 6,000 cash.
  //
  // Cash required to reach the next tick boundary:
  //     Cash_in_seg = (L / t) * (exp(-rNext * t) - exp(-r * t))
  //
  // If cash budget >= Cash_in_seg, the swap reaches the boundary. The caller crosses the tick
  // (updating feeGrowthOutside and activeLiquidity) then re-invokes with remaining cash.
  //
  // If cash budget < Cash_in_seg, the swap stays within the segment. Solving for end yield:
  //     r1 = -(1 / t) * ln( exp(-r0 * t) + (t / L) * C )
  //
  // Within-tick completion delegates to `_getPrincipalSwapAmountWithinTick`.
  // Total PT out = sum of per-segment PT outs.

  /// @notice Calculate PT out for cash in, up to the next tick boundary
  /// @param _amountIn The amount of cash available to trade for PT
  /// @param _currentPrice The price calculated with the current yield tick
  /// @param _nextTick The next initialized tick boundary
  /// @param _priceLimitWad Price limit in WAD; 0 means no limit
  /// @return _amountInConsumed Cash consumed in this step
  /// @return _principalOut PT tokens to send to the trader
  /// @return _newPrice Price after this step
  /// @return _newTick Tick after this step; if equal to `_nextTick`, caller should cross the tick
  function _getPrincipalSwapAmount(
    int256 _amountIn,
    int256 _currentPrice,
    int24 _nextTick,
    uint256 _priceLimitWad
  )
    internal
    view
    returns (uint256 _amountInConsumed, uint256 _principalOut, int256 _newPrice, int24 _newTick)
  {
    if (_amountIn <= 0) revert FixedFeeSwap__SwapAmountCannotBeZero();
    if (_currentPrice <= 0) revert FixedFeeSwap__InvalidPriceDirection();

    uint256 _scaledTime = _scaledTimeElapsedWad();
    int256 _startYieldWad = _yieldWadFromPrice(_currentPrice, _scaledTime);

    int256 _nextTickPrice = tickToPrice(_nextTick);
    if (_nextTickPrice < _currentPrice) revert FixedFeeSwap__InvalidPriceDirection();

    // For cash→PT, price increases so the limit is a maximum price.
    // Use the limit as target if it's lower (closer) than the tick boundary.
    int256 _targetPrice = _nextTickPrice;
    int256 _targetYieldWad = int256(_nextTick) * int256(WAD);
    if (_targetYieldWad >= _startYieldWad) revert FixedFeeSwap__InvalidTickTraversal();
    if (_priceLimitWad != 0 && int256(_priceLimitWad) < _targetPrice) {
      _targetPrice = int256(_priceLimitWad);
      _targetYieldWad = _yieldWadFromPrice(_targetPrice, _scaledTime);
    }

    if (_targetPrice < _currentPrice) revert FixedFeeSwap__InvalidPriceDirection();
    if (_targetYieldWad >= _startYieldWad) revert FixedFeeSwap__InvalidTickTraversal();

    uint256 _priceDiff = uint256(_targetPrice - _currentPrice);
    uint256 _cashInToTarget =
      FixedPointMathLib.mulDivUp(_priceDiff, uint256(activeLiquidity), _scaledTime);
    if (_cashInToTarget == 0) revert FixedFeeSwap__InvalidTickTraversal();

    if (uint256(_amountIn) >= _cashInToTarget) {
      _amountInConsumed = _cashInToTarget;
      uint256 _yieldDeltaWad;
      if (_targetPrice == _nextTickPrice) {
        // Exact tick boundary — no snapping needed
        _newTick = _nextTick;
        _newPrice = _targetPrice;
        _yieldDeltaWad = uint256(_startYieldWad - _targetYieldWad);
      } else {
        // Price limit mid-tick — snap to ceiled tick (Cash→PT: yield decreasing, ceil rounds in pool's favor)
        _newTick = _wadToTickCeil(_targetYieldWad);
        _newPrice = _priceFromYieldWad(int256(_newTick) * int256(WAD), _scaledTime);
        // If snapping pushed the price back to or past the start, the limit is unreachable
        if (_newPrice <= _currentPrice) return (0, 0, 0, 0);
        _yieldDeltaWad = uint256(_startYieldWad - int256(_newTick) * int256(WAD));
      }
      _principalOut =
        FixedPointMathLib.mulDiv(uint256(activeLiquidity), _yieldDeltaWad, BIPS * WAD);
      return (_amountInConsumed, _principalOut, _newPrice, _newTick);
    }

    return _getPrincipalSwapAmountWithinTick(uint256(_amountIn), _currentPrice, _startYieldWad);
  }

  /// @notice Computes within-tick swap for cash→PT using exact logarithm math
  /// @dev Uses lnWad to compute: endYield = -ln(newPrice) / scaledTime * BIPS, then PT_out = L *
  /// (startYield - endYield) / BIPS @param _amountIn The amount of cash tokens to swap
  /// @param _startPrice The price at the start of this swap step
  /// @param _startYieldWad The WAD-scaled yield at the start of this swap step
  /// @return _amountInConsumed Amount of input consumed
  /// @return _principalOut Amount of principal tokens output
  /// @return _newPrice Price after the swap
  /// @return _newTick Tick after the swap
  function _getPrincipalSwapAmountWithinTick(
    uint256 _amountIn,
    int256 _startPrice,
    int256 _startYieldWad
  )
    internal
    view
    returns (uint256 _amountInConsumed, uint256 _principalOut, int256 _newPrice, int24 _newTick)
  {
    _amountInConsumed = _amountIn;
    uint256 _scaledTime = _scaledTimeElapsedWad();

    // newPrice = startPrice + (scaledTime / L) * cashIn
    int256 _exactNewPrice = _startPrice
      + int256(FixedPointMathLib.mulDiv(_scaledTime, _amountIn, uint256(activeLiquidity)));
    if (_exactNewPrice < _startPrice) revert FixedFeeSwap__InvalidPriceDirection();

    // endYieldWad = -ln(newPrice) / scaledTime * BIPS * WAD
    int256 _endYieldWad = _yieldWadFromPrice(_exactNewPrice, _scaledTime);

    // Snap to ceiled integer tick so swap output matches LP composition accounting.
    // Cash→PT decreases yield, so ceiling rounds in favor of the pool (less PT output, higher price).
    // Returns zero consumed/output if the tick didn't move (swap too small).
    _newTick = _wadToTickCeil(_endYieldWad);
    int256 _snappedYieldWad = int256(_newTick) * int256(WAD);
    _newPrice = _priceFromYieldWad(_snappedYieldWad, _scaledTime);

    // PT_out = L * (startYield - snappedYield) / BIPS using WAD precision
    int256 _yieldMovedWad = _startYieldWad - _snappedYieldWad;
    if (_yieldMovedWad <= 0) return (0, 0, _startPrice, _wadToTickCeil(_startYieldWad));
    _principalOut =
      FixedPointMathLib.mulDiv(uint256(activeLiquidity), uint256(_yieldMovedWad), BIPS * WAD);
  }

  // ============ Internal Functions - Liquidity Management ============

  /// @notice Internal function to modify liquidity for a position
  /// @dev Handles tick updates, bitmap flips, active liquidity changes, and fee accrual
  /// @param _owner The position owner address
  /// @param _tickUpper The upper tick boundary of the position
  /// @param _tickLower The lower tick boundary of the position
  /// @param _liquidity The liquidity delta (positive to add, negative to remove)
  /// @return The token amounts required to deposit (positive) or to withdraw (negative)
  function _modifyLiquidity(address _owner, int24 _tickUpper, int24 _tickLower, int128 _liquidity)
    internal
    returns (TokenDelta memory)
  {
    if (_tickLower >= _tickUpper) revert FixedFeeSwap__InvalidTickRange();
    if (_liquidity == 0) return TokenDelta({amount0: 0, amount1: 0});

    bytes32 _positionId = _getPositionId(_owner, _tickUpper, _tickLower);
    PositionInfo storage _position = positions[_positionId];

    // Accrue fees before mutating ticks (must happen before tick data is cleared)
    if (_position.owner != address(0)) _accruePositionFees(_position);

    // Mutate ticks / bitmap / activeLiquidity
    (bool _flippedLower,) = _updateTickLiquidity(_tickLower, _liquidity, false);
    (bool _flippedUpper,) = _updateTickLiquidity(_tickUpper, _liquidity, true);

    if (_flippedLower) {
      tickBitmap.flipTick(_tickLower, YIELD_PER_TICK);
      if (_liquidity < 0) delete ticks[_tickLower];
    }
    if (_flippedUpper) {
      tickBitmap.flipTick(_tickUpper, YIELD_PER_TICK);
      if (_liquidity < 0) delete ticks[_tickUpper];
    }

    // Get token amounts owed for the liquidity
    // TOKEN0 = PT, TOKEN1 = Cash
    // Below current tick (unvisited yields) → LP holds cash (TOKEN1)
    // Above current tick (visited yields) → LP holds principal (TOKEN0)
    TokenDelta memory _delta;
    if (currentTick < _tickLower) {
      // All liquidity at higher yields (unvisited) — LP holds only cash
      _delta = TokenDelta({
        amount0: 0, amount1: _getAmountCashDelta(_tickLower, _tickUpper, _liquidity).toInt128()
      });
    } else if (currentTick < _tickUpper) {
      activeLiquidity = LiquidityMath.addDelta(activeLiquidity, _liquidity);

      // Split at current position:
      // [tickLower, currentTick] visited → principal (TOKEN0)
      // [currentTick, tickUpper] unvisited → cash (TOKEN1)
      _delta = TokenDelta({
        amount0: _getAmountPrincipalDelta(_tickLower, currentTick, _liquidity).toInt128(),
        amount1: _getAmountCashDelta(currentTick, _tickUpper, _liquidity).toInt128()
      });
    } else {
      // All liquidity at lower yields (visited) — LP holds only principal
      _delta = TokenDelta({
        amount0: _getAmountPrincipalDelta(_tickLower, _tickUpper, _liquidity).toInt128(), amount1: 0
      });
    }

    emit LiquidityModified(
      _positionId, _owner, _tickLower, _tickUpper, _liquidity, _delta.amount0, _delta.amount1
    );
    return _delta;
  }

  /// @notice Updates the liquidity at a tick and initializes fee growth if tick is newly
  /// initialized @param _tick The tick that will be updated
  /// @param _liquidityDelta Amount of liquidity to be added when tick is crossed from left to
  /// right, or subtracted when crossed from right to left
  /// @param _upper true for updating a position's upper tick, or
  /// false for updating a position's lower tick
  /// @return flipped Whether the tick was flipped from initialized to uninitialized or vice versa
  /// @return liquidityGrossAfter The gross liquidity at the tick after the update
  function _updateTickLiquidity(int24 _tick, int128 _liquidityDelta, bool _upper)
    internal
    returns (bool, uint128)
  {
    TickInfo storage _info = ticks[_tick];

    uint128 _liquidityGrossBefore = _info.liquidityGross;
    int128 _liquidityNetBefore = _info.liquidityNet;

    uint128 _liquidityGrossAfter;
    if (_liquidityDelta > 0) {
      _liquidityGrossAfter = _liquidityGrossBefore + _liquidityDelta.toUint128();
    } else {
      if (_liquidityGrossBefore < _liquidityDelta.abs()) {
        revert FixedFeeSwap__TickLiquidityGrossUnderflow();
      }
      _liquidityGrossAfter = _liquidityGrossBefore - uint128(_liquidityDelta.abs());
    }

    bool _flipped = (_liquidityGrossAfter == 0) != (_liquidityGrossBefore == 0);

    // Initialize fee growth outside when tick becomes initialized
    // By convention, assume all prior fee growth occurred below this tick
    if (_liquidityGrossBefore == 0 && _liquidityGrossAfter > 0) {
      if (_tick <= currentTick) {
        _info.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
        _info.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
      }
      // If tick > currentTick, feeGrowthOutside stays 0 (all growth is below)
    }

    // when the lower (upper) tick is crossed left to right, liquidity must be added (removed)
    // when the lower (upper) tick is crossed right to left, liquidity must be removed (added)
    int128 _liquidityNet =
      _upper ? _liquidityNetBefore - _liquidityDelta : _liquidityNetBefore + _liquidityDelta;

    _info.liquidityGross = _liquidityGrossAfter;
    _info.liquidityNet = _liquidityNet;

    return (_flipped, _liquidityGrossAfter);
  }

  /// @notice Validates position exists and caller is owner, returns storage pointer
  function _requirePositionOwner(bytes32 _positionId)
    internal
    view
    returns (PositionInfo storage _position)
  {
    _position = positions[_positionId];
    if (_position.owner == address(0)) revert FixedFeeSwap__PositionNotFound();
    if (_position.owner != msg.sender) revert FixedFeeSwap__NotPositionOwner();
  }

  // ============ Internal Functions - Token Amount Calculations ============

  /// @notice Calculates the principal token amount for a liquidity position across a tick range
  /// @dev Amount = liquidity * (upperYield - lowerYield) / BIPS, consistent with swap math
  /// @param _lowerYield The lower tick boundary of the range
  /// @param _upperYield The upper tick boundary of the range
  /// @param _liquidity The liquidity amount, positive for mint and negative for burn
  /// @return The principal token delta: positive values indicate deposit required, negative values
  /// indicate withdrawal
  function _getAmountPrincipalDelta(int24 _lowerYield, int24 _upperYield, int128 _liquidity)
    internal
    pure
    returns (int256)
  {
    int256 _liq = int256(_liquidity);
    uint256 _absLiquidity = _liq.abs();
    uint256 _amount =
      FixedPointMathLib.mulDiv(_absLiquidity, uint256(uint24(_upperYield - _lowerYield)), BIPS);
    return _liq < 0 ? -int256(_amount) : int256(_amount);
  }

  /// @notice Calculates the cash token amount for a liquidity position across a tick range
  /// @dev Amount depends on time: amount = liquidity * (priceLower - priceUpper) / scaledTime
  /// @param _lowerYield The lower tick boundary of the range
  /// @param _upperYield The upper tick boundary of the range
  /// @param _liquidity The liquidity amount, positive for mint and negative for burn
  /// @return The cash token delta: positive values indicate deposit required, negative values
  /// indicate withdrawal
  function _getAmountCashDelta(int24 _lowerYield, int24 _upperYield, int128 _liquidity)
    internal
    view
    returns (int256)
  {
    int256 _liq = int256(_liquidity);
    uint256 _absLiquidity = _liq.abs();
    int256 _upperTickPrice = tickToPrice(_upperYield);
    int256 _lowerTickPrice = tickToPrice(_lowerYield);
    uint256 _scaledTimeWad = _scaledTimeElapsedWad();
    if (_lowerTickPrice < _upperTickPrice) revert FixedFeeSwap__InvalidPriceDirection();
    uint256 _priceDiff = uint256(_lowerTickPrice - _upperTickPrice);
    uint256 _amount = FixedPointMathLib.mulDiv(_absLiquidity, _priceDiff, _scaledTimeWad);
    return _liq < 0 ? -int256(_amount) : int256(_amount);
  }

  // ============ Internal Functions - Fee Tracking ============

  /// @notice Accrues pending fees for a position and updates its fee growth snapshots
  /// @param _position The position storage pointer to update
  function _accruePositionFees(PositionInfo storage _position) internal {
    if (_position.liquidity <= 0) return;

    (uint256 _fg0, uint256 _fg1) = _getFeeGrowthInside(_position.tickLower, _position.tickUpper);
    uint256 _liq = uint256(uint128(_position.liquidity));

    // Note: Cast to uint128 assumes fee amounts won't exceed type(uint128).max.
    // This is safe in practice as it would require mass fee accumulation beyond realistic volumes.
    _position.tokensOwed0 += uint128(
      FixedPointMathLib.mulDiv(_fg0 - _position.feeGrowthInside0LastX128, _liq, Q128)
    );
    _position.tokensOwed1 += uint128(
      FixedPointMathLib.mulDiv(_fg1 - _position.feeGrowthInside1LastX128, _liq, Q128)
    );

    _position.feeGrowthInside0LastX128 = _fg0;
    _position.feeGrowthInside1LastX128 = _fg1;
  }

  /// @notice Refreshes fee growth snapshots for a position (used when liquidity goes from 0 to
  /// positive)
  /// @param _position The position storage pointer to update
  function _refreshFeeSnapshots(PositionInfo storage _position) internal {
    (uint256 _fg0, uint256 _fg1) = _getFeeGrowthInside(_position.tickLower, _position.tickUpper);
    _position.feeGrowthInside0LastX128 = _fg0;
    _position.feeGrowthInside1LastX128 = _fg1;
  }

  /// @notice Calculates fee growth inside a tick range
  /// @param _tickLower The lower tick boundary
  /// @param _tickUpper The upper tick boundary
  /// @return _fg0 Fee growth for TOKEN0 inside the range
  /// @return _fg1 Fee growth for TOKEN1 inside the range
  function _getFeeGrowthInside(int24 _tickLower, int24 _tickUpper)
    internal
    view
    returns (uint256 _fg0, uint256 _fg1)
  {
    TickInfo storage _lower = ticks[_tickLower];
    TickInfo storage _upper = ticks[_tickUpper];

    bool _belowLower = currentTick < _tickLower;
    bool _aboveUpper = currentTick >= _tickUpper;

    uint256 _below0 = _belowLower
      ? feeGrowthGlobal0X128 - _lower.feeGrowthOutside0X128
      : _lower.feeGrowthOutside0X128;
    uint256 _below1 = _belowLower
      ? feeGrowthGlobal1X128 - _lower.feeGrowthOutside1X128
      : _lower.feeGrowthOutside1X128;
    uint256 _above0 = _aboveUpper
      ? feeGrowthGlobal0X128 - _upper.feeGrowthOutside0X128
      : _upper.feeGrowthOutside0X128;
    uint256 _above1 = _aboveUpper
      ? feeGrowthGlobal1X128 - _upper.feeGrowthOutside1X128
      : _upper.feeGrowthOutside1X128;

    _fg0 = feeGrowthGlobal0X128 - _below0 - _above0;
    _fg1 = feeGrowthGlobal1X128 - _below1 - _above1;
  }

  /// @notice Updates fee growth outside values when crossing a tick
  /// @dev Crossing a tick flips the meaning of "outside" - subtracting from global inverts
  ///      the above/below perspective. This is the standard Uniswap v3 tick crossing pattern.
  /// @param _tick The tick being crossed
  function _crossTick(int24 _tick) internal {
    TickInfo storage _info = ticks[_tick];
    _info.feeGrowthOutside0X128 = feeGrowthGlobal0X128 - _info.feeGrowthOutside0X128;
    _info.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - _info.feeGrowthOutside1X128;
  }

  // ============ Internal Functions - Fee Helpers ============

  /// @notice Returns the amount available to swap after fees, given a gross exact-in amount.
  function _netOfFee(uint256 _amountInGross) internal view returns (uint256) {
    return FixedPointMathLib.mulDiv(_amountInGross, FEE_DENOMINATOR - FEE_RATE, FEE_DENOMINATOR);
  }

  // ============ Internal Functions - Price/Yield Conversions ============

  /// @notice Calculates the scaled time elapsed since market start as a fraction of total duration
  /// @dev Returns a WAD-scaled value where 1e18 represents the full duration from START_TIME to
  /// MATURITY @return The scaled time elapsed in WAD precision, where 1e18 represents 100% of the
  /// duration
  function _scaledTimeElapsedWad() internal view returns (uint256) {
    uint256 _elapsed = block.timestamp - START_TIME;
    if (_elapsed == 0) revert FixedFeeSwap__TimeElapsedIsZero();
    uint256 _duration = MATURITY - START_TIME;
    if (_elapsed > _duration) _elapsed = _duration;
    return (_elapsed * WAD) / _duration;
  }

  /// @notice Converts a WAD-scaled yield value to an int24 tick using floor division
  /// @param _yieldWad The WAD-scaled yield value to convert
  /// @return The tick as int24, floored toward negative infinity
  function _wadToTick(int256 _yieldWad) internal pure returns (int24) {
    int256 _oneWad = int256(WAD);
    if (_yieldWad >= 0) return int24(_yieldWad / _oneWad);
    return int24((_yieldWad - _oneWad + 1) / _oneWad);
  }

  /// @notice Converts a WAD-scaled yield to an int24 tick using ceiling division
  /// @dev Rounds toward positive infinity, the opposite of _wadToTick
  /// @param _yieldWad The WAD-scaled yield value to convert
  /// @return The tick as int24, ceiled toward positive infinity
  function _wadToTickCeil(int256 _yieldWad) internal pure returns (int24) {
    int256 _oneWad = int256(WAD);
    if (_yieldWad >= 0) return int24((_yieldWad + _oneWad - 1) / _oneWad);
    return int24(_yieldWad / _oneWad);
  }

  /// @notice Derives the WAD-scaled yield from a discount factor price
  /// @dev Uses the formula: yield = -ln(price) / scaledTime * BIPS
  /// @param _price The discount factor price in WAD
  /// @param _scaledTime The scaled time elapsed since market start
  /// @return The yield in WAD-scaled basis points
  function _yieldWadFromPrice(int256 _price, uint256 _scaledTime) internal pure returns (int256) {
    int256 _lnP = FixedPointMathLib.lnWad(_price);
    if (_lnP <= 0) {
      return int256(FixedPointMathLib.mulDiv(uint256(-_lnP), BIPS * WAD, _scaledTime));
    }
    return -int256(FixedPointMathLib.mulDiv(uint256(_lnP), BIPS * WAD, _scaledTime));
  }

  /// @notice Derives a discount factor price from a WAD-scaled yield
  /// @dev Uses the formula: price = exp(-yield / BIPS * scaledTime)
  /// @param _yieldWad The yield in WAD-scaled basis points
  /// @param _scaledTime The scaled time elapsed since market start
  /// @return The discount factor price in WAD
  function _priceFromYieldWad(int256 _yieldWad, uint256 _scaledTime)
    internal
    pure
    returns (int256)
  {
    int256 _exponentWad;
    if (_yieldWad >= 0) {
      _exponentWad = -int256(FixedPointMathLib.mulDiv(uint256(_yieldWad), _scaledTime, BIPS * WAD));
    } else {
      _exponentWad = int256(FixedPointMathLib.mulDiv(uint256(-_yieldWad), _scaledTime, BIPS * WAD));
    }
    return _exponentWad.expWad();
  }

  /// @dev Position IDs are hashed as keccak256(abi.encodePacked(tickUpper, tickLower, owner)).
  function _getPositionId(address _owner, int24 _tickUpper, int24 _tickLower)
    internal
    pure
    returns (bytes32)
  {
    return keccak256(abi.encodePacked(_tickUpper, _tickLower, _owner));
  }
}
