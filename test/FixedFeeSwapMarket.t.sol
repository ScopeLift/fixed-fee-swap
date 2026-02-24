// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {FixedFeeSwapMarket} from "src/FixedFeeSwapMarket.sol";
import {FixedFeeSwapMarketHarness} from "test/harness/FixedFeeSwapMarketHarness.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

struct Amounts {
  int256 amount0;
  int256 _amount1;
}

struct SharedWithdrawalCtx {
  uint128 _aliceLiquidity;
  uint128 _bobLiquidity;
  int24 _tickLower;
  int24 _tickUpper;
  bytes32 _alicePositionId;
  int16 lowerWord;
  uint8 lowerBit;
  int16 upperWord;
  uint8 upperBit;
  uint256 _lowerWordAfterMint;
  uint256 _upperWordAfterMint;
}

abstract contract FixedFeeSwapMarketTest is Test {
  FixedFeeSwapMarketHarness public hook;
  MockERC20 public token0;
  MockERC20 public token1;
  PoolKey internal poolKey;
  SwapParams internal defaultSwapParams;

  uint48 public constant MARKET_LENGTH = 365 days;
  // Large balance to support very large fuzzed _liquidity ranges without incidental ERC20 reverts.
  uint256 public constant INITIAL_BALANCE = 1_000_000_000_000e18;
  uint256 public constant SCALE_FACTOR = 1e18;
  uint256 public constant BIPS = 10_000;
  int24 internal constant MAX_TICK = 100_000;
  // Fee rate in hundredths of _a bip (3000 = 0.30%)
  // Set to 0 for existing tests to pass without fee impact
  uint24 public constant FEE_RATE = 0;
  uint24 internal constant LP_FEE_RATE = 3000; // 0.30%
  int24 public constant YIELD_PER_TICK = 1;
  int24 public constant NO_TICK_LIMIT = type(int24).max;

  enum RangeScenario {
    BelowCurrent,
    InRange,
    AboveCurrent,
    LowerAtCurrent,
    UpperAtCurrent
  }

  address public alice = makeAddr("alice");
  address public bob = makeAddr("bob");

  function setUp() public virtual {
    token0 = new MockERC20("Token0", "TKN0", 18);
    token1 = new MockERC20("Token1", "TKN1", 18);

    // Sort tokens
    if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

    // Use _a mock address for manager
    address _mockManager = makeAddr("_mockManager");

    // Deploy harness directly - validation is overridden to skip address checks
    hook = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH,
      address(token0),
      address(token1),
      FEE_RATE,
      YIELD_PER_TICK,
      IPoolManager(_mockManager),
      0
    );

    // Warp forward for realistic test conditions (prices are near-fully discounted at START_TIME)
    vm.warp(block.timestamp + 1 days);

    // Fund users
    _fundUser(alice);
    _fundUser(bob);

    // Approvals
    _approveUser(alice);
    _approveUser(bob);
  }

  // ============ Helper Functions ============

  function _deployHookWithSpacing(int24 _yieldPerTick)
    internal
    returns (FixedFeeSwapMarketHarness)
  {
    address _mockManager = makeAddr("yieldToTickManager");
    return new FixedFeeSwapMarketHarness(
      MARKET_LENGTH,
      address(token0),
      address(token1),
      FEE_RATE,
      _yieldPerTick,
      IPoolManager(_mockManager),
      0
    );
  }

  function _fundUser(address _user) internal {
    token0.mint(_user, INITIAL_BALANCE);
    token1.mint(_user, INITIAL_BALANCE);
  }

  function _resetHookWithInitialTick(int24 _initialTick, string memory _managerLabel) internal {
    hook = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH,
      address(token0),
      address(token1),
      FEE_RATE,
      YIELD_PER_TICK,
      IPoolManager(makeAddr(_managerLabel)),
      _initialTick
    );
    _approveUser(alice);
    _approveUser(bob);
  }

  function _approveUser(address _user) internal {
    vm.startPrank(_user);
    token0.approve(address(hook), type(uint256).max);
    token1.approve(address(hook), type(uint256).max);
    vm.stopPrank();
  }

  function _boundTick(int24 _tick) internal pure returns (int24) {
    return int24(bound(int256(_tick), 0, 100_000));
  }

  function _boundTickRange(int24 _lower, int24 _upper) internal pure returns (int24, int24) {
    _lower = int24(bound(int256(_lower), 0, 9999));
    _upper = int24(bound(int256(_upper), int256(_lower) + 1, 10_000));
    return (_lower, _upper);
  }

  function _boundLiquidity(uint128 _liquidity) internal pure returns (uint128) {
    // Liquidity needs to be large enough to avoid rounding to 0 in _getAmountCashDelta
    // With _remaining-_time pricing near START_TIME, scaledTime ≈ WAD, so 1e17 is adequate
    // But not too large to cause overflow in other calculations
    return uint128(bound(_liquidity, 1e17, 3e24));
  }

  function _boundFeeSwapAmount(uint256 _amount, uint128 _liquidity)
    internal
    pure
    returns (uint256)
  {
    uint256 _minSwap = uint256(_liquidity) * 2 / BIPS;
    uint256 _maxSwap = uint256(_liquidity) * 200 / BIPS;
    return bound(_amount, _minSwap, _maxSwap);
  }

  function _boundSwapForRange(
    uint256 _amount,
    uint128 _liquidity,
    int24 _tickUpper,
    uint256 _maxBipsDesired
  ) internal pure returns (uint256) {
    uint256 _maxBips = uint256(int256(_tickUpper)) - 2;
    if (_maxBips > _maxBipsDesired) _maxBips = _maxBipsDesired;
    return bound(_amount, uint256(_liquidity) * 2 / BIPS, uint256(_liquidity) * _maxBips / BIPS);
  }

  function _boundTimeElapsed(uint256 _time) internal view returns (uint256) {
    return bound(_time, 0, MARKET_LENGTH);
  }

  function _warpFromStart(uint256 _timeElapsed) internal {
    vm.warp(hook.getStartTime() + _timeElapsed);
  }

  function _warpToMintTime() internal {
    _warpFromStart(1);
  }

  function _expectedMintAmounts(int24 _tickLower, int24 _tickUpper, uint128 _liquidity)
    internal
    returns (int256 expected0, int256 expected1)
  {
    int24 _currentTick = hook.getCurrentTick();
    int128 _liq = int128(uint128(_liquidity));

    if (_currentTick < _tickLower) {
      expected1 = hook.exposed_getAmountCashDelta(_tickLower, _tickUpper, _liq);
    } else if (_currentTick < _tickUpper) {
      expected0 = hook.exposed_getAmountPrincipalDelta(_tickLower, _currentTick, _liq);
      expected1 = hook.exposed_getAmountCashDelta(_currentTick, _tickUpper, _liq);
    } else {
      expected0 = hook.exposed_getAmountPrincipalDelta(_tickLower, _tickUpper, _liq);
    }
  }

  function _boundScenario(uint8 _scenario) internal pure returns (RangeScenario) {
    return RangeScenario(uint8(bound(_scenario, 0, uint8(type(RangeScenario).max))));
  }

  function _rangeForScenario(int24 _currentTick, RangeScenario _scenario, int24 _width)
    internal
    pure
    returns (int24 _tickLower, int24 _tickUpper)
  {
    require(_width > 0, "Width must be positive");

    if (_scenario == RangeScenario.BelowCurrent) {
      _tickUpper = _currentTick - _width;
      _tickLower = _tickUpper - _width;
    } else if (_scenario == RangeScenario.InRange) {
      _tickLower = _currentTick - _width;
      _tickUpper = _currentTick + _width;
    } else if (_scenario == RangeScenario.AboveCurrent) {
      _tickLower = _currentTick + _width;
      _tickUpper = _tickLower + _width;
    } else if (_scenario == RangeScenario.LowerAtCurrent) {
      _tickLower = _currentTick;
      _tickUpper = _currentTick + _width;
    } else {
      _tickLower = _currentTick - _width;
      _tickUpper = _currentTick;
    }
  }

  function _standardRange(RangeScenario _scenario)
    internal
    view
    returns (int24 _tickLower, int24 _tickUpper)
  {
    return _rangeForScenario(hook.getCurrentTick(), _scenario, 100);
  }

  /// @notice Computes the packed bitmap slot/bit for _a given _tick.
  /// @dev Mirrors `TickBitmap.position` with `tickSpacing = 1` (so the compressed _tick equals
  /// `_tick`). @param _tick The _tick to locate in the bitmap.
  /// @return wordPos The bitmap word key (`_tick >> 8`).
  /// @return bitPos The bit index within the word (`_tick & 0xff`).
  function _bitmapPosition(int24 _tick) internal pure returns (int16 wordPos, uint8 bitPos) {
    assembly ("memory-safe") {
      wordPos := sar(8, signextend(2, _tick))
      bitPos := and(_tick, 0xff)
    }
  }

  function _boundSwapAmount(uint256 _amount) internal pure returns (uint256) {
    return bound(_amount, 1e16, 1e20);
  }

  function _mintDefaultLiquidity(address _user) internal returns (bytes32) {
    vm.prank(_user);
    hook.mintLiquidity(0, 200, 1e18, type(uint256).max, type(uint256).max);
    return keccak256(abi.encodePacked(int24(200), int24(0), _user));
  }

  function _mintLiquidityAtTicks(address _user, int24 _lower, int24 _upper, uint128 _liquidity)
    internal
    returns (bytes32)
  {
    vm.prank(_user);
    hook.mintLiquidity(_lower, _upper, _liquidity, type(uint256).max, type(uint256).max);
    return keccak256(abi.encodePacked(_upper, _lower, _user));
  }

  function _mintLiquidity(address _user, int24 _tickLower, int24 _tickUpper, uint128 _liquidity)
    internal
    returns (uint256 token0Used, uint256 token1Used)
  {
    uint256 _balance0Before = token0.balanceOf(_user);
    uint256 _balance1Before = token1.balanceOf(_user);

    vm.prank(_user);
    hook.mintLiquidity(_tickLower, _tickUpper, _liquidity, type(uint256).max, type(uint256).max);

    token0Used = _balance0Before - token0.balanceOf(_user);
    token1Used = _balance1Before - token1.balanceOf(_user);
  }

  function _increaseLiquidity(address _user, bytes32 _positionId, uint128 _additionalLiquidity)
    internal
    returns (int256 token0Used, int256 token1Used)
  {
    uint256 _balance0Before = token0.balanceOf(_user);
    uint256 _balance1Before = token1.balanceOf(_user);

    vm.prank(_user);
    hook.increaseLiquidity(_positionId, _additionalLiquidity, type(uint256).max, type(uint256).max);

    token0Used = int256(_balance0Before - token0.balanceOf(_user));
    token1Used = int256(_balance1Before - token1.balanceOf(_user));
  }

  function _decreaseAllLiquidity(address _user, bytes32 _positionId, uint128 _liquidity) internal {
    vm.prank(_user);
    hook.decreaseLiquidity(_positionId, -int128(_liquidity), 0, 0);
  }

  function _decreaseLiquidity(address _user, bytes32 _positionId, uint128 _removeAmount)
    internal
    returns (uint256 token0Received, uint256 token1Received)
  {
    uint256 _balance0Before = token0.balanceOf(_user);
    uint256 _balance1Before = token1.balanceOf(_user);

    vm.prank(_user);
    hook.decreaseLiquidity(_positionId, -int128(_removeAmount), 0, 0);

    token0Received = token0.balanceOf(_user) - _balance0Before;
    token1Received = token1.balanceOf(_user) - _balance1Before;
  }

  function _getPositionId(int24 _tickUpper, int24 _tickLower, address _owner)
    internal
    pure
    returns (bytes32)
  {
    return keccak256(abi.encodePacked(_tickUpper, _tickLower, _owner));
  }

  /// @dev Mints _liquidity at _a high range and swaps to move _currentTick to _target.
  /// Uses high _tick values to avoid contaminating _ticks used by normal tests.
  function _moveTickTo(int24 _target) internal {
    require(_target > 0, "Target must be positive");
    _warpToMintTime();
    // Use _a range far above normal test bounds to avoid contaminating _tick _liquidity
    _mintLiquidityAtTicks(alice, 0, _target + 500, 1e22);
    PoolKey memory _poolKey = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 0,
      tickSpacing: 1,
      hooks: IHooks(address(hook))
    });
    SwapParams memory _swapParams =
      SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
    bytes memory _hookParams = abi.encode(int256(100e22), true, _target);
    hook.exposed_beforeSwap(bob, _poolKey, _swapParams, _hookParams);
  }

  function _encodeHookParams(int256 _amountIn, bool _principalForCash, int24 _tickLimit)
    internal
    pure
    returns (bytes memory)
  {
    return abi.encode(_amountIn, _principalForCash, _tickLimit);
  }

  function _swap(address _sender, int256 _amountIn, bool _principalForCash, int24 _tickLimit)
    internal
    returns (bytes4, BeforeSwapDelta, uint24)
  {
    bytes memory _hookParams = _encodeHookParams(_amountIn, _principalForCash, _tickLimit);
    return hook.exposed_beforeSwap(_sender, poolKey, defaultSwapParams, _hookParams);
  }

  function _deployHookForBeforeSwapTests(uint24 _feeRate, string memory _managerLabel)
    internal
    returns (FixedFeeSwapMarketHarness _localHook, PoolKey memory _localPoolKey)
  {
    uint256 _currentTimestamp = block.timestamp;
    vm.warp(1);

    _localHook = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH,
      address(token0),
      address(token1),
      _feeRate,
      YIELD_PER_TICK,
      IPoolManager(makeAddr(_managerLabel)),
      0
    );

    uint256 _resumeTimestamp = _currentTimestamp > 1 days ? _currentTimestamp : 1 days + 1;
    vm.warp(_resumeTimestamp);

    _localPoolKey = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 0,
      tickSpacing: 1,
      hooks: IHooks(address(_localHook))
    });

    vm.startPrank(alice);
    token0.approve(address(_localHook), type(uint256).max);
    token1.approve(address(_localHook), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(bob);
    token0.approve(address(_localHook), type(uint256).max);
    token1.approve(address(_localHook), type(uint256).max);
    vm.stopPrank();
  }

  function _swapOnHook(
    FixedFeeSwapMarketHarness _localHook,
    PoolKey memory _localPoolKey,
    address _sender,
    int256 _amountIn,
    bool _principalForCash,
    int24 _tickLimit
  ) internal {
    bytes memory _hookParams = _encodeHookParams(_amountIn, _principalForCash, _tickLimit);
    _localHook.exposed_beforeSwap(_sender, _localPoolKey, defaultSwapParams, _hookParams);
  }

  function _mintOnHook(
    FixedFeeSwapMarketHarness _localHook,
    address _user,
    int24 _tickLower,
    int24 _tickUpper,
    uint128 _liquidity
  ) internal returns (bytes32 _positionId) {
    vm.prank(_user);
    _localHook.mintLiquidity(
      _tickLower, _tickUpper, _liquidity, type(uint256).max, type(uint256).max
    );
    _positionId = keccak256(abi.encodePacked(_tickUpper, _tickLower, _user));
  }

  function _measurePrincipalForCashSwap(
    FixedFeeSwapMarketHarness _localHook,
    PoolKey memory _localPoolKey,
    uint256 _amountIn
  ) internal returns (uint256 inputConsumed, uint256 outputReceived) {
    uint256 _balance0Before = token0.balanceOf(bob);
    uint256 _balance1Before = token1.balanceOf(bob);
    _swapOnHook(_localHook, _localPoolKey, bob, int256(_amountIn), true, NO_TICK_LIMIT);
    inputConsumed = _balance0Before - token0.balanceOf(bob);
    outputReceived = token1.balanceOf(bob) - _balance1Before;
  }

  function _ptForOneBip() internal view returns (uint256) {
    return uint256(hook.getActiveLiquidity()) / BIPS;
  }

  function _initializePrice() internal returns (int256) {
    if (hook.getCurrentPrice() != 0) return hook.getCurrentPrice();

    _swap(bob, 1, true, hook.getCurrentTick());

    int256 _price = hook.getCurrentPrice();
    assertTrue(_price > 0, "Price must be initialized");
    return _price;
  }

  /// @notice Upper bound on _tick movement for _a given swap input and active _liquidity.
  /// @dev Each _tick consumes ~_activeLiquidity/BIPS of input, so _ticks ≈ _amountIn * BIPS /
  /// _activeLiquidity. +1 for Solidity integer division truncation, +1 for the swap's _tick
  /// snapping to integers.
  function _maxTickMove(uint256 _amountIn, uint128 _activeLiquidity) internal pure returns (int24) {
    return int24(int256(_amountIn * BIPS / uint256(_activeLiquidity))) + 2;
  }

  /// @notice Minimum input required to move the _tick by _a given number of _ticks.
  /// @dev Inverse of `_maxTickMove`. Each _tick consumes ~_activeLiquidity/BIPS of input.
  function _minInputForTicks(uint24 _ticks) internal view returns (uint256) {
    return _ptForOneBip() * uint256(_ticks);
  }

  /// @notice Expected fee growth (Q128-scaled) for _a given _consumed _amount and active
  /// _liquidity. @dev fee ≈ _consumed * FEE_RATE / FEE_DENOMINATOR; growth = fee * Q128 /
  /// _liquidity.
  function _expectedFeeGrowth(uint256 _consumed, uint128 _liquidity)
    internal
    pure
    returns (uint256)
  {
    uint256 _fee = _consumed * LP_FEE_RATE / 1_000_000;
    return _fee * (1 << 128) / uint256(_liquidity);
  }

  /// @notice Max fee growth rounding error from per-step accumulation across _tick crossings.
  /// @dev The contract accumulates fee growth per _tick step, each independently rounding the fee
  ///      (mulDivUp, +1 wei) and the Q128-scaled growth (mulDiv, -1 unit). Combined this introduces
  ///      up to (Q128 / _liquidity + 1) of error per _tick crossed. For typical values (1e20
  /// _liquidity, 100 _ticks) the _tolerance is ~3.4e20 in Q128 units — about 1e-13 relative to
  /// _expected growth.
  function _feeGrowthRoundingTolerance(uint256 _amountIn, uint128 _liquidity)
    internal
    pure
    returns (uint256)
  {
    return uint256(int256(_maxTickMove(_amountIn, _liquidity)))
      * ((1 << 128) / uint256(_liquidity) + 1);
  }

  function _assertApproxEqRelBps(uint256 _a, uint256 _b, uint256 _toleranceBps, string memory _err)
    internal
    pure
  {
    if (_a == 0 && _b == 0) return;
    uint256 _diff = _a > _b ? _a - _b : _b - _a;
    uint256 _maxVal = _a > _b ? _a : _b;
    uint256 _maxDiff = (_maxVal * _toleranceBps) / BIPS;
    assertTrue(_diff <= _maxDiff, _err);
  }
}

contract Constructor is FixedFeeSwapMarketTest {
  function testFuzz_SetsAllConstructorArgs(
    uint48 _marketLength,
    uint24 _feeRate,
    int24 _yieldPerTick,
    int24 _initialTick,
    address _mockManager
  ) public {
    uint48 _startTime = uint48(block.timestamp);
    uint48 _maxMarketLength = type(uint48).max - _startTime;

    _marketLength = uint48(bound(uint256(_marketLength), 0, uint256(_maxMarketLength)));
    _feeRate = uint24(bound(_feeRate, 0, 999_999));
    _yieldPerTick = int24(bound(int256(_yieldPerTick), 1, type(int24).max));

    FixedFeeSwapMarketHarness _hook = new FixedFeeSwapMarketHarness(
      _marketLength,
      address(token0),
      address(token1),
      _feeRate,
      _yieldPerTick,
      IPoolManager(_mockManager),
      _initialTick
    );

    assertEq(_hook.getStartTime(), _startTime, "start _time");
    assertEq(_hook.getMaturity(), _startTime + _marketLength, "maturity");
    assertEq(_hook.getToken0(), address(token0), "token0");
    assertEq(_hook.getToken1(), address(token1), "token1");
    assertEq(_hook.FEE_RATE(), _feeRate, "fee rate");
    assertEq(_hook.YIELD_PER_TICK(), _yieldPerTick, "yield per _tick");
    assertEq(address(_hook.poolManager()), _mockManager, "pool manager");
    assertEq(_hook.getCurrentTick(), _initialTick, "initial _tick");
  }

  function testFuzz_RevertIf_FeeRateTooHigh(uint24 _feeRate) public {
    _feeRate = uint24(bound(_feeRate, 1_000_000, type(uint24).max));
    address _mockManager = makeAddr("constructorMockManager");
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_FeeRateTooHigh.selector);
    new FixedFeeSwapMarketHarness(
      MARKET_LENGTH,
      address(token0),
      address(token1),
      _feeRate,
      YIELD_PER_TICK,
      IPoolManager(_mockManager),
      0
    );
  }

  function testFuzz_RevertIf_InvalidYieldSpacing(int24 _yieldPerTick) public {
    _yieldPerTick = int24(bound(int256(_yieldPerTick), type(int24).min, 0));
    address _mockManager = makeAddr("constructorMockManagerSpacing");
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_InvalidYieldSpacing.selector);
    new FixedFeeSwapMarketHarness(
      MARKET_LENGTH,
      address(token0),
      address(token1),
      FEE_RATE,
      _yieldPerTick,
      IPoolManager(_mockManager),
      0
    );
  }
}

contract GetHookPermissions is FixedFeeSwapMarketTest {
  function test_ReturnsCorrectPermissions() public view {
    Hooks.Permissions memory _perms = hook.getHookPermissions();
    assertTrue(_perms.beforeAddLiquidity, "beforeAddLiquidity should be true");
    assertTrue(_perms.beforeRemoveLiquidity, "beforeRemoveLiquidity should be true");
    assertTrue(_perms.beforeSwap, "beforeSwap should be true");
    assertFalse(_perms.beforeInitialize, "beforeInitialize should be false");
    assertFalse(_perms.afterInitialize, "afterInitialize should be false");
    assertFalse(_perms.afterAddLiquidity, "afterAddLiquidity should be false");
    assertFalse(_perms.afterRemoveLiquidity, "afterRemoveLiquidity should be false");
    assertFalse(_perms.afterSwap, "afterSwap should be false");
    assertFalse(_perms.beforeDonate, "beforeDonate should be false");
    assertFalse(_perms.afterDonate, "afterDonate should be false");
    assertFalse(_perms.beforeSwapReturnDelta, "beforeSwapReturnDelta should be false");
    assertFalse(_perms.afterSwapReturnDelta, "afterSwapReturnDelta should be false");
    assertFalse(_perms.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta should be false");
    assertFalse(
      _perms.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta should be false"
    );
  }
}

contract YieldToTick is FixedFeeSwapMarketTest {
  function testFuzz_MatchesIntegerDivisionForAnySpacing(int24 _yieldPerTick, int256 _yieldBps)
    public
  {
    _yieldPerTick = int24(bound(int256(_yieldPerTick), 1, type(int24).max));
    FixedFeeSwapMarketHarness _hook = _deployHookWithSpacing(_yieldPerTick);

    assertEq(
      _hook.yieldToTick(_yieldBps),
      int24(_yieldBps / int256(_yieldPerTick)),
      "yieldToTick should divide by configured spacing"
    );
  }

  function testFuzz_RawYieldMatchesTickMultipliedBySpacing(int24 _yieldPerTick, int24 _tick)
    public
  {
    _yieldPerTick = int24(bound(int256(_yieldPerTick), 1, type(int24).max));
    FixedFeeSwapMarketHarness _hook = _deployHookWithSpacing(_yieldPerTick);

    int256 _alignedYield = int256(_tick) * int256(_yieldPerTick);
    assertEq(_hook.yieldToTick(_alignedYield), _tick, "Aligned yields should round-trip exactly");
  }
}

contract TickToPrice is FixedFeeSwapMarketTest {
  using FixedPointMathLib for int256;

  function _priceAtElapsed(int24 _tick, uint256 _timeElapsed) internal returns (int256) {
    _warpFromStart(_timeElapsed);
    return hook.tickToPrice(_tick);
  }

  /// @dev At START_TIME, _remaining = duration so scaledTime = WAD and the _exponent reduces to
  /// -_tick/BIPS, so _price matches exp(-_tick/BIPS).
  function testFuzz_PriceAtStartMatchesExpected(int24 _tick) public {
    _tick = int24(bound(int256(_tick), 0, MAX_TICK));

    int256 _actual = _priceAtElapsed(_tick, 0);

    int256 _exponent = (-int256(_tick) * 1e18) / int256(BIPS);
    int256 _expected = _exponent.expWad();
    assertApproxEqRel(_actual, _expected, 1e12, "_price at start should match exp(-_tick/BIPS)");
  }

  /// @dev For any non-mature timestamp, strictly higher yield (_tick) implies strictly _lower
  /// _price.
  function testFuzz_PriceDecreasesAsYieldIncreases(int24 _tickA, int24 _tickB, uint256 _timeElapsed)
    public
  {
    _tickA = int24(bound(int256(_tickA), 0, MAX_TICK - 1));
    _tickB = int24(bound(int256(_tickB), _tickA + 1, MAX_TICK));
    _timeElapsed = bound(_timeElapsed, 1, MARKET_LENGTH - 1);

    int256 _priceA = _priceAtElapsed(_tickA, _timeElapsed);
    int256 _priceB = _priceAtElapsed(_tickB, _timeElapsed);

    assertGt(_priceA, _priceB, "Higher _tick should have strictly _lower _price before maturity");
  }

  /// @dev Price increases over _time for positive yields (converges to 1.0 at maturity)
  /// @notice With exp(-yield * time_remaining), less _remaining _time => less discount.
  function testFuzz_PriceIncreasesOverTimeSameYield(int24 _tick, uint256 _time1, uint256 _time2)
    public
  {
    _tick = int24(bound(int256(_tick), 1, MAX_TICK));
    _time1 = bound(_time1, 0, MARKET_LENGTH - 2);
    _time2 = bound(_time2, _time1 + 1, MARKET_LENGTH - 1);

    int256 _price1 = _priceAtElapsed(_tick, _time1);
    int256 _price2 = _priceAtElapsed(_tick, _time2);

    assertGe(_price2, _price1, "Price should increase over _time (converge to 1)");
  }

  /// @dev At maturity, _price equals 1 regardless of _tick (PT redeemable 1:1)
  /// @notice At maturity, _remaining _time = 0, so tickToPrice returns WAD directly
  function testFuzz_PriceAtMaturityIsOne(int24 _tick) public {
    _tick = int24(bound(int256(_tick), 0, MAX_TICK));
    vm.warp(hook.getMaturity());
    int256 _price = hook.tickToPrice(_tick);
    assertEq(_price, 1e18, "Price at maturity should be 1 regardless of _tick");
  }

  /// @dev Remaining-_time additivity: _price(_rem1+_rem2) == _price(_rem1) * _price(_rem2)
  /// @notice exp(-y*(r1+r2)/d) = exp(-y*r1/d) * exp(-y*r2/d) where r = _remaining _time
  function testFuzz_RemainingTimeAdditivitiveWithPrice(int24 _tick, uint256 _rem1, uint256 _rem2)
    public
  {
    _tick = int24(bound(int256(_tick), -MAX_TICK, MAX_TICK));
    _rem1 = bound(_rem1, 0, MARKET_LENGTH);
    _rem2 = bound(_rem2, 0, MARKET_LENGTH - _rem1);

    vm.warp(hook.getMaturity() - _rem1);
    int256 _price1 = hook.tickToPrice(_tick);

    vm.warp(hook.getMaturity() - _rem2);
    int256 _price2 = hook.tickToPrice(_tick);

    vm.warp(hook.getMaturity() - (_rem1 + _rem2));
    int256 _price12 = hook.tickToPrice(_tick);

    int256 _combined = (_price1 * _price2) / 1e18;
    assertApproxEqRel(
      _price12, _combined, 1e12, "_price(_rem1+_rem2) should equal _price(_rem1)*_price(_rem2)"
    );
  }
}

contract MintLiquidity is FixedFeeSwapMarketTest {
  function setUp() public virtual override {
    super.setUp();
    _resetHookWithInitialTick(500, "mintLiquidityManager");
  }

  function testFuzz_CreatesPositionAndUpdatesTickState(
    int24 _tickLower,
    int24 _tickUpper,
    uint128 _liquidity
  ) public {
    (_tickLower, _tickUpper) = _boundTickRange(_tickLower, _tickUpper);
    _liquidity = _boundLiquidity(_liquidity);

    _warpToMintTime();

    (uint128 lowerGrossBefore, int128 lowerNetBefore) = hook.getTickInfo(_tickLower);
    (uint128 upperGrossBefore, int128 upperNetBefore) = hook.getTickInfo(_tickUpper);

    vm.prank(alice);
    hook.mintLiquidity(_tickLower, _tickUpper, _liquidity, type(uint256).max, type(uint256).max);

    {
      bytes32 _positionId = _getPositionId(_tickUpper, _tickLower, alice);
      (address _owner, int24 _lower, int24 _upper, int128 _liq) = hook.getPositionInfo(_positionId);
      assertEq(_owner, alice, "position _owner");
      assertEq(_lower, _tickLower, "position _tickLower");
      assertEq(_upper, _tickUpper, "position _tickUpper");
      assertEq(uint128(_liq), _liquidity, "position _liquidity");
    }

    {
      (uint128 lowerGrossAfter, int128 lowerNetAfter) = hook.getTickInfo(_tickLower);
      (uint128 upperGrossAfter, int128 upperNetAfter) = hook.getTickInfo(_tickUpper);
      assertEq(lowerGrossAfter - lowerGrossBefore, _liquidity, "_lower gross delta");
      assertEq(upperGrossAfter - upperGrossBefore, _liquidity, "_upper gross delta");
      assertEq(lowerNetAfter - lowerNetBefore, int128(_liquidity), "_lower net delta");
      assertEq(upperNetAfter - upperNetBefore, -int128(_liquidity), "_upper net delta");
    }

    {
      (int16 lowerWord, uint8 lowerBit) = _bitmapPosition(_tickLower);
      (int16 upperWord, uint8 upperBit) = _bitmapPosition(_tickUpper);
      uint256 _lowerWordValue = hook.getTickBitmapWord(lowerWord);
      uint256 _upperWordValue = hook.getTickBitmapWord(upperWord);
      assertTrue((_lowerWordValue & (uint256(1) << lowerBit)) != 0, "_lower bitmap bit set");
      assertTrue((_upperWordValue & (uint256(1) << upperBit)) != 0, "_upper bitmap bit set");
    }
  }

  function testFuzz_TransfersExpectedAmounts(
    int24 _tickLower,
    int24 _tickUpper,
    uint128 _liquidity,
    uint256 _timeElapsed
  ) public {
    (_tickLower, _tickUpper) = _boundTickRange(_tickLower, _tickUpper);
    _liquidity = _boundLiquidity(_liquidity);
    _timeElapsed = bound(_timeElapsed, 1, MARKET_LENGTH - 1);

    _warpFromStart(_timeElapsed);

    (int256 expected0, int256 expected1) = _expectedMintAmounts(_tickLower, _tickUpper, _liquidity);
    uint256 _user0Before = token0.balanceOf(alice);
    uint256 _user1Before = token1.balanceOf(alice);
    uint256 _hook0Before = token0.balanceOf(address(hook));
    uint256 _hook1Before = token1.balanceOf(address(hook));
    uint256 _total0Before = _user0Before + _hook0Before;
    uint256 _total1Before = _user1Before + _hook1Before;

    vm.prank(alice);
    hook.mintLiquidity(_tickLower, _tickUpper, _liquidity, type(uint256).max, type(uint256).max);

    uint256 _user0After = token0.balanceOf(alice);
    uint256 _user1After = token1.balanceOf(alice);
    uint256 _hook0After = token0.balanceOf(address(hook));
    uint256 _hook1After = token1.balanceOf(address(hook));
    assertEq(int256(_user0Before - _user0After), expected0, "_user token0 debit");
    assertEq(int256(_user1Before - _user1After), expected1, "_user token1 debit");
    assertEq(int256(_hook0After - _hook0Before), expected0, "hook token0 credit");
    assertEq(int256(_hook1After - _hook1Before), expected1, "hook token1 credit");
    assertEq(_user0After + _hook0After, _total0Before, "token0 conservation");
    assertEq(_user1After + _hook1After, _total1Before, "token1 conservation");
  }

  function testFuzz_UpdatesActiveLiquidityWhenRangeIncludesCurrentTick(
    uint128 _liquidity,
    uint8 _scenario
  ) public {
    _liquidity = _boundLiquidity(_liquidity);

    _warpToMintTime();

    // Map to the two inclusive cases: InRange or LowerAtCurrent.
    uint8 _boundedScenario = uint8(bound(_scenario, 0, 1));
    RangeScenario _rangeScenario =
      _boundedScenario == 0 ? RangeScenario.InRange : RangeScenario.LowerAtCurrent;
    (int24 _tickLower, int24 _tickUpper) = _standardRange(_rangeScenario);
    uint128 _activeBefore = hook.getActiveLiquidity();

    vm.prank(alice);
    hook.mintLiquidity(_tickLower, _tickUpper, _liquidity, type(uint256).max, type(uint256).max);

    assertEq(hook.getActiveLiquidity(), _activeBefore + _liquidity, "active _liquidity increase");
  }

  function testFuzz_DoesNotUpdateActiveLiquidityWhenRangeExcludesCurrentTick(
    uint128 _liquidity,
    uint8 _scenario
  ) public {
    _liquidity = _boundLiquidity(_liquidity);

    _warpToMintTime();

    // Map to excluded cases: BelowCurrent, AboveCurrent, UpperAtCurrent.
    uint8 _boundedScenario = uint8(bound(_scenario, 0, 2));
    RangeScenario _rangeScenario = _boundedScenario == 0
      ? RangeScenario.BelowCurrent
      : _boundedScenario == 1 ? RangeScenario.AboveCurrent : RangeScenario.UpperAtCurrent;
    (int24 _tickLower, int24 _tickUpper) = _standardRange(_rangeScenario);
    uint128 _activeBefore = hook.getActiveLiquidity();

    vm.prank(alice);
    hook.mintLiquidity(_tickLower, _tickUpper, _liquidity, type(uint256).max, type(uint256).max);

    assertEq(hook.getActiveLiquidity(), _activeBefore, "active _liquidity unchanged");
  }

  function testFuzz_MultipleUsersMintInSameRange(
    uint128 _liquidityAlice,
    uint128 _liquidityBob,
    uint8 _scenario
  ) public {
    _liquidityAlice = _boundLiquidity(_liquidityAlice);
    _liquidityBob = _boundLiquidity(_liquidityBob);

    _warpToMintTime();

    (int24 _tickLower, int24 _tickUpper) = _standardRange(_boundScenario(_scenario));

    vm.prank(alice);
    hook.mintLiquidity(
      _tickLower, _tickUpper, _liquidityAlice, type(uint256).max, type(uint256).max
    );
    vm.prank(bob);
    hook.mintLiquidity(_tickLower, _tickUpper, _liquidityBob, type(uint256).max, type(uint256).max);

    (uint128 lowerGross,) = hook.getTickInfo(_tickLower);
    (uint128 upperGross,) = hook.getTickInfo(_tickUpper);
    assertEq(lowerGross, _liquidityAlice + _liquidityBob, "_lower gross _combined");
    assertEq(upperGross, _liquidityAlice + _liquidityBob, "_upper gross _combined");

    bytes32 _alicePositionId = _getPositionId(_tickUpper, _tickLower, alice);
    bytes32 _bobPositionId = _getPositionId(_tickUpper, _tickLower, bob);
    (address aliceOwner,,, int128 aliceLiq) = hook.getPositionInfo(_alicePositionId);
    (address bobOwner,,, int128 bobLiq) = hook.getPositionInfo(_bobPositionId);
    assertEq(aliceOwner, alice, "alice _owner");
    assertEq(bobOwner, bob, "bob _owner");
    assertEq(uint128(aliceLiq), _liquidityAlice, "alice _liquidity");
    assertEq(uint128(bobLiq), _liquidityBob, "bob _liquidity");
  }

  function testFuzz_LiquidityBelowCurrentTickIsOnlyToken0(uint128 _liquidity, uint8 _scenario)
    public
  {
    _liquidity = _boundLiquidity(_liquidity);

    _warpToMintTime();

    uint8 _boundedScenario = uint8(bound(_scenario, 0, 1));
    RangeScenario _rangeScenario =
      _boundedScenario == 0 ? RangeScenario.BelowCurrent : RangeScenario.UpperAtCurrent;
    int24 _currentTick = hook.getCurrentTick();
    (int24 _tickLower, int24 _tickUpper) = _rangeForScenario(_currentTick, _rangeScenario, 100);
    (int256 expected0, int256 expected1) = _expectedMintAmounts(_tickLower, _tickUpper, _liquidity);

    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.mintLiquidity(_tickLower, _tickUpper, _liquidity, type(uint256).max, type(uint256).max);

    assertGt(expected0, 0, "requires token0");
    assertEq(expected1, 0, "does not require token1");
    assertEq(int256(_balance0Before - token0.balanceOf(alice)), expected0, "token0 _amount");
    assertEq(int256(_balance1Before - token1.balanceOf(alice)), expected1, "token1 _amount");
  }

  function testFuzz_LiquidityAboveCurrentTickIsOnlyToken1(uint128 _liquidity, uint8 _scenario)
    public
  {
    _liquidity = _boundLiquidity(_liquidity);

    _warpToMintTime();

    uint8 _boundedScenario = uint8(bound(_scenario, 0, 1));
    RangeScenario _rangeScenario =
      _boundedScenario == 0 ? RangeScenario.AboveCurrent : RangeScenario.LowerAtCurrent;
    int24 _currentTick = hook.getCurrentTick();
    (int24 _tickLower, int24 _tickUpper) = _rangeForScenario(_currentTick, _rangeScenario, 100);
    (int256 expected0, int256 expected1) = _expectedMintAmounts(_tickLower, _tickUpper, _liquidity);

    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.mintLiquidity(_tickLower, _tickUpper, _liquidity, type(uint256).max, type(uint256).max);

    assertEq(expected0, 0, "does not require token0");
    assertGt(expected1, 0, "requires token1");
    assertEq(int256(_balance0Before - token0.balanceOf(alice)), expected0, "token0 _amount");
    assertEq(int256(_balance1Before - token1.balanceOf(alice)), expected1, "token1 _amount");
  }

  function testFuzz_CurrentTickIsInLiquidityRange(uint128 _liquidity) public {
    _liquidity = _boundLiquidity(_liquidity);

    _warpToMintTime();

    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);
    (int256 expected0, int256 expected1) = _expectedMintAmounts(_tickLower, _tickUpper, _liquidity);

    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.mintLiquidity(_tickLower, _tickUpper, _liquidity, type(uint256).max, type(uint256).max);

    assertGt(expected0, 0, "requires token0");
    assertGt(expected1, 0, "requires token1");
    assertEq(int256(_balance0Before - token0.balanceOf(alice)), expected0, "token0 _amount");
    assertEq(int256(_balance1Before - token1.balanceOf(alice)), expected1, "token1 _amount");
  }

  function testFuzz_TokenAmountsScaleWithLiquidity_BelowOrUpperAtCurrent(
    uint128 _liquidity1,
    uint128 _liquidity2,
    uint8 _scenario
  ) public {
    _liquidity1 = uint128(bound(_liquidity1, 1e17, 1e18));
    _liquidity2 = uint128(bound(_liquidity2, _liquidity1 * 2, 1e20));

    _warpToMintTime();

    uint8 _boundedScenario = uint8(bound(_scenario, 0, 1));
    RangeScenario _rangeScenario =
      _boundedScenario == 0 ? RangeScenario.BelowCurrent : RangeScenario.UpperAtCurrent;
    (int24 _tickLower, int24 _tickUpper) = _standardRange(_rangeScenario);
    (int256 expected0_1,) = _expectedMintAmounts(_tickLower, _tickUpper, _liquidity1);
    (int256 expected0_2,) = _expectedMintAmounts(_tickLower, _tickUpper, _liquidity2);
    assertGe(expected0_2, expected0_1, "_expected token0 monotonic");

    (uint256 token0Used1, uint256 token1Used1) =
      _mintLiquidity(alice, _tickLower, _tickUpper, _liquidity1);
    (uint256 token0Used2, uint256 token1Used2) =
      _mintLiquidity(bob, _tickLower, _tickUpper, _liquidity2);
    assertEq(int256(token0Used1), expected0_1, "token0 used _liquidity1");
    assertEq(token1Used1, 0, "zero _liquidity1 token1");
    assertEq(int256(token0Used2), expected0_2, "token0 used _liquidity2");
    assertEq(token1Used2, 0, "zero _liquidity2 token1");
    assertGt(token0Used2, token0Used1, "larger _liquidity token0");
  }

  function testFuzz_AddingLiquidityAboveCurrentTickIncreasesToken1Used(
    uint128 _liquidity1,
    uint128 _liquidity2,
    uint8 _scenario
  ) public {
    _liquidity1 = uint128(bound(_liquidity1, 1e17, 1e18));
    _liquidity2 = uint128(bound(_liquidity2, _liquidity1 * 2, 1e20));

    _warpToMintTime();

    uint8 _boundedScenario = uint8(bound(_scenario, 0, 1));
    RangeScenario _rangeScenario =
      _boundedScenario == 0 ? RangeScenario.AboveCurrent : RangeScenario.LowerAtCurrent;
    (int24 _tickLower, int24 _tickUpper) = _standardRange(_rangeScenario);
    (, int256 expected1_1) = _expectedMintAmounts(_tickLower, _tickUpper, _liquidity1);
    (, int256 expected1_2) = _expectedMintAmounts(_tickLower, _tickUpper, _liquidity2);

    (uint256 token0Used1, uint256 token1Used1) =
      _mintLiquidity(alice, _tickLower, _tickUpper, _liquidity1);
    (uint256 token0Used2, uint256 token1Used2) =
      _mintLiquidity(bob, _tickLower, _tickUpper, _liquidity2);
    assertEq(int256(token1Used1), expected1_1, "token1 used _liquidity1");
    assertEq(int256(token1Used2), expected1_2, "token1 used _liquidity2");
    assertEq(token0Used1, 0, "zero _liquidity1 token0");
    assertEq(token0Used2, 0, "zero _liquidity2 token0");
    assertGt(token1Used2, token1Used1, "larger _liquidity token1");
  }

  function testFuzz_AddingLiquidityAboveCurrentTickIncreasesToken1Used(
    uint128 _liquidity1,
    uint128 _liquidity2
  ) public {
    _liquidity1 = uint128(bound(_liquidity1, 1e17, 1e18));
    _liquidity2 = uint128(bound(_liquidity2, _liquidity1 * 2, 1e20));

    _warpToMintTime();

    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);
    (int256 expected0_1, int256 expected1_1) =
      _expectedMintAmounts(_tickLower, _tickUpper, _liquidity1);
    (int256 expected0_2, int256 expected1_2) =
      _expectedMintAmounts(_tickLower, _tickUpper, _liquidity2);

    (uint256 token0Used1, uint256 token1Used1) =
      _mintLiquidity(alice, _tickLower, _tickUpper, _liquidity1);
    (uint256 token0Used2, uint256 token1Used2) =
      _mintLiquidity(bob, _tickLower, _tickUpper, _liquidity2);
    assertEq(int256(token0Used1), expected0_1, "token0 used _liquidity1");
    assertEq(int256(token1Used1), expected1_1, "token1 used _liquidity1");
    assertEq(int256(token0Used2), expected0_2, "token0 used _liquidity2");
    assertEq(int256(token1Used2), expected1_2, "token1 used _liquidity2");
    assertGt(token0Used2, token0Used1, "larger _liquidity token0");
    assertGt(token1Used2, token1Used1, "larger _liquidity token1");
  }

  function testFuzz_AWiderLiquidityRangeBelowTheCurrentTickRequiresMoreToken1(
    uint128 _liquidity,
    int24 _narrowWidth,
    int24 _wideWidth
  ) public {
    _liquidity = _boundLiquidity(_liquidity);
    _narrowWidth = int24(bound(int256(_narrowWidth), 1, 50));
    _wideWidth = int24(bound(int256(_wideWidth), int256(_narrowWidth) + 1, 200));

    _warpToMintTime();

    (, int24 _tickUpper) = _standardRange(RangeScenario.UpperAtCurrent);
    (uint256 token0Narrow, uint256 token1Narrow) =
      _mintLiquidity(alice, _tickUpper - _narrowWidth, _tickUpper, _liquidity);
    (uint256 token0Wide, uint256 token1Wide) =
      _mintLiquidity(bob, _tickUpper - _wideWidth, _tickUpper, _liquidity);

    assertGt(token0Wide, token0Narrow, "wider range token0");
    assertEq(token1Narrow, 0, "below-range narrow token1");
    assertEq(token1Wide, 0, "below-range wide token1");
  }

  function testFuzz_MintIsSuccessfulWhenAmountsEqualSpecifiedMax(
    int24 _tickLower,
    int24 _tickUpper,
    uint128 _liquidity
  ) public {
    (_tickLower, _tickUpper) = _boundTickRange(_tickLower, _tickUpper);
    _liquidity = _boundLiquidity(_liquidity);

    _warpToMintTime();

    (int256 required0, int256 required1) = _expectedMintAmounts(_tickLower, _tickUpper, _liquidity);

    vm.prank(alice);
    hook.mintLiquidity(_tickLower, _tickUpper, _liquidity, uint256(required0), uint256(required1));
  }

  function testFuzz_MintingToExistingPositionAccumulatesLiquidity(
    uint128 _liq1,
    uint128 _liq2,
    uint8 _scenario
  ) public {
    _liq1 = _boundLiquidity(_liq1);
    _liq2 = _boundLiquidity(_liq2);

    _warpToMintTime();

    (int24 _tickLower, int24 _tickUpper) = _standardRange(_boundScenario(_scenario));

    bytes32 _positionId1 = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _liq1);

    vm.prank(alice);
    hook.mintLiquidity(_tickLower, _tickUpper, _liq2, type(uint256).max, type(uint256).max);
    bytes32 _positionId2 = _getPositionId(_tickUpper, _tickLower, alice);

    assertEq(_positionId1, _positionId2, "same position id");

    (address _owner,,, int128 totalLiquidity) = hook.getPositionInfo(_positionId1);
    assertEq(_owner, alice, "_owner");
    assertEq(uint128(totalLiquidity), _liq1 + _liq2, "position _liquidity sum");

    (uint128 lowerGross,) = hook.getTickInfo(_tickLower);
    (uint128 upperGross,) = hook.getTickInfo(_tickUpper);
    assertEq(lowerGross, _liq1 + _liq2, "_lower gross sum");
    assertEq(upperGross, _liq1 + _liq2, "_upper gross sum");
  }

  function testFuzz_EmitsLiquidityModified(int24 _tickLower, int24 _tickUpper, uint128 _liquidity)
    public
  {
    (_tickLower, _tickUpper) = _boundTickRange(_tickLower, _tickUpper);
    _liquidity = _boundLiquidity(_liquidity);

    _warpToMintTime();

    bytes32 _positionId = _getPositionId(_tickUpper, _tickLower, alice);
    (int256 expected0, int256 expected1) = _expectedMintAmounts(_tickLower, _tickUpper, _liquidity);

    vm.expectEmit();
    emit FixedFeeSwapMarket.LiquidityModified(
      _positionId,
      alice,
      _tickLower,
      _tickUpper,
      int128(_liquidity),
      int128(expected0),
      int128(expected1)
    );

    vm.prank(alice);
    hook.mintLiquidity(_tickLower, _tickUpper, _liquidity, type(uint256).max, type(uint256).max);
  }

  function test_MintLiquidityIsAllowedAtMaturity() public {
    vm.warp(hook.getMaturity());

    bytes32 _positionId = _mintLiquidityAtTicks(alice, 0, 500, 1e22);

    (address _owner,,, int128 _liq) = hook.getPositionInfo(_positionId);
    assertEq(_owner, alice, "Position should be created");
    assertEq(uint128(_liq), 1e22, "Liquidity should match");
  }

  // ============ Revert Tests ============

  function testFuzz_RevertIf_TickRangeIsInvalid(
    int24 _tickLower,
    int24 _tickUpper,
    uint128 _liquidity
  ) public {
    _liquidity = _boundLiquidity(_liquidity);
    vm.assume(_tickLower < 0 || _tickLower >= _tickUpper);

    _warpToMintTime();
    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_InvalidTickRange.selector);
    hook.mintLiquidity(_tickLower, _tickUpper, _liquidity, type(uint256).max, type(uint256).max);
  }

  function testFuzz_RevertIf_MaxTokenAmountTooLow(uint128 _liquidity, bool _checkToken0) public {
    _liquidity = _boundLiquidity(_liquidity);

    _warpToMintTime();

    RangeScenario _scenario = _checkToken0 ? RangeScenario.BelowCurrent : RangeScenario.AboveCurrent;
    (int24 _tickLower, int24 _tickUpper) = _standardRange(_scenario);

    (int256 required0, int256 required1) = _expectedMintAmounts(_tickLower, _tickUpper, _liquidity);

    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_InvalidLiquidityAmount.selector);
    hook.mintLiquidity(
      _tickLower,
      _tickUpper,
      _liquidity,
      _checkToken0 ? uint256(required0) - 1 : type(uint256).max,
      _checkToken0 ? type(uint256).max : uint256(required1) - 1
    );
  }

  function testFuzz_RevertIf_NoTokenAllowance(uint128 _liquidity, bool _checkToken0) public {
    _liquidity = _boundLiquidity(_liquidity);

    _warpToMintTime();

    RangeScenario _scenario = _checkToken0 ? RangeScenario.BelowCurrent : RangeScenario.AboveCurrent;
    (int24 _tickLower, int24 _tickUpper) = _standardRange(_scenario);

    vm.startPrank(alice);
    token0.approve(address(hook), 0);
    token1.approve(address(hook), 0);
    vm.expectRevert(stdError.arithmeticError);
    hook.mintLiquidity(_tickLower, _tickUpper, _liquidity, type(uint256).max, type(uint256).max);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_TokenBalanceIsTooLow(uint128 _liquidity, bool _checkToken0) public {
    _liquidity = _boundLiquidity(_liquidity);

    _warpToMintTime();

    RangeScenario _scenario = _checkToken0 ? RangeScenario.BelowCurrent : RangeScenario.AboveCurrent;
    (int24 _tickLower, int24 _tickUpper) = _standardRange(_scenario);

    vm.startPrank(alice);
    token0.transfer(makeAddr("sink"), token0.balanceOf(alice));
    token1.transfer(makeAddr("sink"), token1.balanceOf(alice));

    vm.expectRevert(stdError.arithmeticError);
    hook.mintLiquidity(_tickLower, _tickUpper, _liquidity, type(uint256).max, type(uint256).max);
    vm.stopPrank();
  }
}

contract IncreaseLiquidity is FixedFeeSwapMarketTest {
  function setUp() public virtual override {
    super.setUp();
    _resetHookWithInitialTick(500, "increaseLiquidityManager");
  }

  // ============ State Update Tests ============

  function testFuzz_UpdatesPositionAndTickState(
    uint128 _initialLiquidity,
    uint128 _additionalLiquidity
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _additionalLiquidity = _boundLiquidity(_additionalLiquidity);

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);

    vm.prank(alice);
    hook.increaseLiquidity(_positionId, _additionalLiquidity, type(uint256).max, type(uint256).max);

    (address _owner, int24 _lower, int24 _upper, int128 totalLiquidity) =
      hook.getPositionInfo(_positionId);
    (uint128 lowerGross, int128 lowerNet) = hook.getTickInfo(_tickLower);
    (uint128 upperGross, int128 upperNet) = hook.getTickInfo(_tickUpper);
    uint128 _expectedTotal = _initialLiquidity + _additionalLiquidity;

    assertEq(_owner, alice, "_owner");
    assertEq(_lower, _tickLower, "_tickLower");
    assertEq(_upper, _tickUpper, "_tickUpper");
    assertEq(uint128(totalLiquidity), _expectedTotal, "position _liquidity");
    assertEq(lowerGross, _expectedTotal, "_lower gross");
    assertEq(upperGross, _expectedTotal, "_upper gross");
    assertEq(lowerNet, int128(_expectedTotal), "_lower net");
    assertEq(upperNet, -int128(_expectedTotal), "_upper net");
  }

  function testFuzz_TickBitmapBitsRemainSetAfterIncrease(
    uint128 _initialLiquidity,
    uint128 _additionalLiquidity
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _additionalLiquidity = _boundLiquidity(_additionalLiquidity);

    _warpToMintTime();
    int24 _currentTick = hook.getCurrentTick();
    (int24 _tickLower, int24 _tickUpper) =
      _rangeForScenario(_currentTick, RangeScenario.InRange, 200);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);

    (int16 lowerWord, uint8 lowerBit) = _bitmapPosition(_tickLower);
    (int16 upperWord, uint8 upperBit) = _bitmapPosition(_tickUpper);
    uint256 _lowerWordBefore = hook.getTickBitmapWord(lowerWord);
    uint256 _upperWordBefore = hook.getTickBitmapWord(upperWord);

    vm.prank(alice);
    hook.increaseLiquidity(_positionId, _additionalLiquidity, type(uint256).max, type(uint256).max);

    uint256 _lowerWordAfter = hook.getTickBitmapWord(lowerWord);
    uint256 _upperWordAfter = hook.getTickBitmapWord(upperWord);

    assertEq(_lowerWordAfter, _lowerWordBefore, "_lower bitmap word");
    if (upperWord != lowerWord) assertEq(_upperWordAfter, _upperWordBefore, "_upper bitmap word");
    assertTrue((_lowerWordAfter & (uint256(1) << lowerBit)) != 0, "_lower bitmap bit set");
    assertTrue((_upperWordAfter & (uint256(1) << upperBit)) != 0, "_upper bitmap bit set");
  }

  // ============ Token Accounting Tests ============

  function testFuzz_TransfersExpectedAmountsAndConservesTotals(
    uint128 _initialLiquidity,
    uint128 _additionalLiquidity
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _additionalLiquidity = _boundLiquidity(_additionalLiquidity);

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);
    (int256 expected0, int256 expected1) =
      _expectedMintAmounts(_tickLower, _tickUpper, _additionalLiquidity);

    uint256 _user0Before = token0.balanceOf(alice);
    uint256 _user1Before = token1.balanceOf(alice);
    uint256 _hook0Before = token0.balanceOf(address(hook));
    uint256 _hook1Before = token1.balanceOf(address(hook));
    uint256 _total0Before = _user0Before + _hook0Before;
    uint256 _total1Before = _user1Before + _hook1Before;

    vm.prank(alice);
    hook.increaseLiquidity(_positionId, _additionalLiquidity, type(uint256).max, type(uint256).max);

    uint256 _user0After = token0.balanceOf(alice);
    uint256 _user1After = token1.balanceOf(alice);
    uint256 _hook0After = token0.balanceOf(address(hook));
    uint256 _hook1After = token1.balanceOf(address(hook));

    assertEq(int256(_user0Before - _user0After), expected0, "_user token0 debit");
    assertEq(int256(_user1Before - _user1After), expected1, "_user token1 debit");
    assertEq(int256(_hook0After - _hook0Before), expected0, "hook token0 credit");
    assertEq(int256(_hook1After - _hook1Before), expected1, "hook token1 credit");
    assertEq(_user0After + _hook0After, _total0Before, "token0 conservation");
    assertEq(_user1After + _hook1After, _total1Before, "token1 conservation");
  }

  function testFuzz_BelowCurrentRangeIncreaseUsesOnlyToken0(
    uint128 _initialLiquidity,
    uint128 _additionalLiquidity
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _additionalLiquidity = _boundLiquidity(_additionalLiquidity);

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.BelowCurrent);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);
    (int256 expected0, int256 expected1) =
      _expectedMintAmounts(_tickLower, _tickUpper, _additionalLiquidity);
    (int256 used0, int256 used1) = _increaseLiquidity(alice, _positionId, _additionalLiquidity);

    assertGt(expected0, 0, "_expected token0");
    assertEq(expected1, 0, "_expected token1");
    assertEq(used0, expected0, "token0 used");
    assertEq(used1, expected1, "token1 used");
  }

  function testFuzz_AboveCurrentRangeIncreaseUsesOnlyToken1(
    uint128 _initialLiquidity,
    uint128 _additionalLiquidity
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _additionalLiquidity = _boundLiquidity(_additionalLiquidity);

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.AboveCurrent);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);
    (int256 expected0, int256 expected1) =
      _expectedMintAmounts(_tickLower, _tickUpper, _additionalLiquidity);
    (int256 used0, int256 used1) = _increaseLiquidity(alice, _positionId, _additionalLiquidity);

    assertEq(expected0, 0, "_expected token0");
    assertGt(expected1, 0, "_expected token1");
    assertEq(used0, expected0, "token0 used");
    assertEq(used1, expected1, "token1 used");
  }

  function testFuzz_InRangeIncreaseUsesBothTokens(
    uint128 _initialLiquidity,
    uint128 _additionalLiquidity
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _additionalLiquidity = _boundLiquidity(_additionalLiquidity);

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);
    (int256 expected0, int256 expected1) =
      _expectedMintAmounts(_tickLower, _tickUpper, _additionalLiquidity);
    (int256 used0, int256 used1) = _increaseLiquidity(alice, _positionId, _additionalLiquidity);

    assertGt(expected0, 0, "_expected token0");
    assertGt(expected1, 0, "_expected token1");
    assertEq(used0, expected0, "token0 used");
    assertEq(used1, expected1, "token1 used");
  }

  function test_CashRequiredForLiquidityIncreasesOverTime() public {
    uint128 _initialLiquidity = 1e18;
    uint128 _additionalLiquidity = 1e24;

    _warpFromStart(1);
    int24 _currentTick = hook.getCurrentTick();
    (int24 _tickLower, int24 _tickUpper) =
      _rangeForScenario(_currentTick, RangeScenario.InRange, 200);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);
    uint256 _snapshot = vm.snapshotState();

    _warpFromStart(1);
    Amounts memory _expectedAtT1;
    (_expectedAtT1.amount0, _expectedAtT1._amount1) =
      _expectedMintAmounts(_tickLower, _tickUpper, _additionalLiquidity);
    Amounts memory _usedAtT1;
    (_usedAtT1.amount0, _usedAtT1._amount1) =
      _increaseLiquidity(alice, _positionId, _additionalLiquidity);

    vm.revertToState(_snapshot);
    _warpFromStart(30 days);
    Amounts memory _expectedAtT2;
    (_expectedAtT2.amount0, _expectedAtT2._amount1) =
      _expectedMintAmounts(_tickLower, _tickUpper, _additionalLiquidity);
    Amounts memory _usedAtT2;
    (_usedAtT2.amount0, _usedAtT2._amount1) =
      _increaseLiquidity(alice, _positionId, _additionalLiquidity);

    assertEq(_usedAtT1.amount0, _expectedAtT1.amount0, "t1 token0");
    assertEq(_usedAtT1._amount1, _expectedAtT1._amount1, "t1 token1");
    assertEq(_usedAtT2.amount0, _expectedAtT2.amount0, "t2 token0");
    assertEq(_usedAtT2._amount1, _expectedAtT2._amount1, "t2 token1");
    assertGt(_expectedAtT1.amount0, 0, "t1 token0 required");
    assertGt(_expectedAtT1._amount1, 0, "t1 token1 required");
    assertEq(_expectedAtT2.amount0, _expectedAtT1.amount0, "principal invariant");
    assertTrue(_expectedAtT2._amount1 != _expectedAtT1._amount1, "cash changes over _time");
  }

  // ============ Active Liquidity Tests ============

  function testFuzz_InRangeIncreaseUpdatesActiveLiquidity(
    uint128 _initialLiquidity,
    uint128 _additionalLiquidity
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _additionalLiquidity = _boundLiquidity(_additionalLiquidity);

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);
    uint128 _activeBefore = hook.getActiveLiquidity();

    vm.prank(alice);
    hook.increaseLiquidity(_positionId, _additionalLiquidity, type(uint256).max, type(uint256).max);

    uint128 _activeAfter = hook.getActiveLiquidity();
    assertEq(_activeAfter, _activeBefore + _additionalLiquidity, "active _liquidity increase");
  }

  function testFuzz_OutOfRangeIncreaseDoesNotUpdateActiveLiquidity(
    uint128 _initialLiquidity,
    uint128 _additionalLiquidity,
    uint8 _scenario
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _additionalLiquidity = _boundLiquidity(_additionalLiquidity);

    _warpToMintTime();
    uint8 _boundedScenario = uint8(bound(_scenario, 0, 1));
    RangeScenario _rangeScenario =
      _boundedScenario == 0 ? RangeScenario.BelowCurrent : RangeScenario.AboveCurrent;
    (int24 _tickLower, int24 _tickUpper) = _standardRange(_rangeScenario);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);
    uint128 _activeBefore = hook.getActiveLiquidity();

    vm.prank(alice);
    hook.increaseLiquidity(_positionId, _additionalLiquidity, type(uint256).max, type(uint256).max);

    uint128 _activeAfter = hook.getActiveLiquidity();
    assertEq(_activeAfter, _activeBefore, "active _liquidity unchanged");
  }

  // ============ Multiple Operations Tests ============

  function testFuzz_MultipleIncreasesAccumulateLiquidity(
    uint128 _initialLiquidity,
    uint128 _increase1,
    uint128 _increase2
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _increase1 = _boundLiquidity(_increase1);
    _increase2 = _boundLiquidity(_increase2);

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);

    vm.startPrank(alice);
    hook.increaseLiquidity(_positionId, _increase1, type(uint256).max, type(uint256).max);
    hook.increaseLiquidity(_positionId, _increase2, type(uint256).max, type(uint256).max);
    vm.stopPrank();

    (,,, int128 totalLiquidity) = hook.getPositionInfo(_positionId);
    (uint128 lowerGross,) = hook.getTickInfo(_tickLower);
    (uint128 upperGross,) = hook.getTickInfo(_tickUpper);
    uint128 _expectedTotal = _initialLiquidity + _increase1 + _increase2;

    assertEq(uint128(totalLiquidity), _expectedTotal, "position _liquidity");
    assertEq(lowerGross, _expectedTotal, "_lower gross");
    assertEq(upperGross, _expectedTotal, "_upper gross");
  }

  function testFuzz_MultipleUsersIncreaseIndependentPositions(
    uint128 _aliceInitial,
    uint128 _aliceIncrease
  ) public {
    _aliceInitial = _boundLiquidity(_aliceInitial);
    _aliceIncrease = _boundLiquidity(_aliceIncrease);
    uint128 _bobInitial = 1e18;
    uint128 _bobIncrease = 1e18;

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);
    bytes32 _alicePositionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _aliceInitial);
    bytes32 _bobPositionId = _mintLiquidityAtTicks(bob, _tickLower, _tickUpper, _bobInitial);

    vm.prank(alice);
    hook.increaseLiquidity(_alicePositionId, _aliceIncrease, type(uint256).max, type(uint256).max);
    vm.prank(bob);
    hook.increaseLiquidity(_bobPositionId, _bobIncrease, type(uint256).max, type(uint256).max);

    (,,, int128 aliceLiq) = hook.getPositionInfo(_alicePositionId);
    (,,, int128 bobLiq) = hook.getPositionInfo(_bobPositionId);
    (uint128 lowerGross,) = hook.getTickInfo(_tickLower);
    (uint128 upperGross,) = hook.getTickInfo(_tickUpper);
    uint128 _expectedTotal = _aliceInitial + _aliceIncrease + _bobInitial + _bobIncrease;

    assertEq(uint128(aliceLiq), _aliceInitial + _aliceIncrease, "alice _liquidity");
    assertEq(uint128(bobLiq), _bobInitial + _bobIncrease, "bob _liquidity");
    assertEq(lowerGross, _expectedTotal, "_lower gross");
    assertEq(upperGross, _expectedTotal, "_upper gross");
  }

  function testFuzz_EmitsLiquidityModified(uint128 _initialLiquidity, uint128 _additionalLiquidity)
    public
  {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _additionalLiquidity = _boundLiquidity(_additionalLiquidity);

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);
    (int256 expected0, int256 expected1) =
      _expectedMintAmounts(_tickLower, _tickUpper, _additionalLiquidity);

    vm.expectEmit();
    emit FixedFeeSwapMarket.LiquidityModified(
      _positionId,
      alice,
      _tickLower,
      _tickUpper,
      int128(_additionalLiquidity),
      int128(expected0),
      int128(expected1)
    );

    vm.prank(alice);
    hook.increaseLiquidity(_positionId, _additionalLiquidity, type(uint256).max, type(uint256).max);
  }

  function testFuzz_LiquidityAddedWhenAmountEqualMaxAmounts(
    uint128 _initialLiquidity,
    uint128 _additionalLiquidity
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _additionalLiquidity = _boundLiquidity(_additionalLiquidity);

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);
    (int256 required0, int256 required1) =
      _expectedMintAmounts(_tickLower, _tickUpper, _additionalLiquidity);

    vm.prank(alice);
    hook.increaseLiquidity(
      _positionId, _additionalLiquidity, uint256(required0), uint256(required1)
    );

    (,,, int128 totalLiquidity) = hook.getPositionInfo(_positionId);
    assertEq(
      uint128(totalLiquidity), _initialLiquidity + _additionalLiquidity, "_liquidity increased"
    );
  }

  function test_RevertIf_PositionNotFound() public {
    bytes32 _missingPositionId = keccak256("missing position");

    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_PositionNotFound.selector);
    hook.increaseLiquidity(_missingPositionId, 1e18, type(uint256).max, type(uint256).max);
  }

  function testFuzz_RevertIf_NotCalledByPositionOwner(
    uint128 _initialLiquidity,
    uint128 _additionalLiquidity
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _additionalLiquidity = _boundLiquidity(_additionalLiquidity);

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);

    vm.prank(bob);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_NotPositionOwner.selector);
    hook.increaseLiquidity(_positionId, _additionalLiquidity, type(uint256).max, type(uint256).max);
  }

  function testFuzz_RevertIf_MaxToken0AmountIsTooLow(
    uint128 _initialLiquidity,
    uint128 _additionalLiquidity
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _additionalLiquidity = _boundLiquidity(_additionalLiquidity);

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.BelowCurrent);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);
    (int256 required0,) = _expectedMintAmounts(_tickLower, _tickUpper, _additionalLiquidity);

    uint256 _required0U = uint256(required0);
    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_InvalidLiquidityAmount.selector);
    hook.increaseLiquidity(_positionId, _additionalLiquidity, _required0U - 1, type(uint256).max);
  }

  function testFuzz_RevertIf_MaxToken1AmountIsTooLow(
    uint128 _initialLiquidity,
    uint128 _additionalLiquidity
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _additionalLiquidity = _boundLiquidity(_additionalLiquidity);

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.AboveCurrent);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);
    (, int256 required1) = _expectedMintAmounts(_tickLower, _tickUpper, _additionalLiquidity);

    uint256 _required1U = uint256(required1);
    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_InvalidLiquidityAmount.selector);
    hook.increaseLiquidity(_positionId, _additionalLiquidity, type(uint256).max, _required1U - 1);
  }

  function testFuzz_RevertIf_Token0AllowanceMissing(
    uint128 _initialLiquidity,
    uint128 _additionalLiquidity
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _additionalLiquidity = _boundLiquidity(_additionalLiquidity);

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.BelowCurrent);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);

    vm.startPrank(alice);
    token0.approve(address(hook), 0);
    vm.expectRevert(stdError.arithmeticError);
    hook.increaseLiquidity(_positionId, _additionalLiquidity, type(uint256).max, type(uint256).max);
    vm.stopPrank();
  }

  function testFuzz_RevertWhen_Token1AllowanceMissing(
    uint128 _initialLiquidity,
    uint128 _additionalLiquidity
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _additionalLiquidity = _boundLiquidity(_additionalLiquidity);

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.AboveCurrent);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);

    vm.startPrank(alice);
    token1.approve(address(hook), 0);
    vm.expectRevert(stdError.arithmeticError);
    hook.increaseLiquidity(_positionId, _additionalLiquidity, type(uint256).max, type(uint256).max);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_Token0BalanceInsufficient(
    uint128 _initialLiquidity,
    uint128 _additionalLiquidity
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _additionalLiquidity = _boundLiquidity(_additionalLiquidity);

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.BelowCurrent);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);

    vm.startPrank(alice);
    token0.transfer(makeAddr("sink"), token0.balanceOf(alice));
    vm.expectRevert(stdError.arithmeticError);
    hook.increaseLiquidity(_positionId, _additionalLiquidity, type(uint256).max, type(uint256).max);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_Token1BalanceInsufficient(
    uint128 _initialLiquidity,
    uint128 _additionalLiquidity
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _additionalLiquidity = _boundLiquidity(_additionalLiquidity);

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.AboveCurrent);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);

    vm.startPrank(alice);
    token1.transfer(makeAddr("sink"), token1.balanceOf(alice));
    vm.expectRevert(stdError.arithmeticError);
    hook.increaseLiquidity(_positionId, _additionalLiquidity, type(uint256).max, type(uint256).max);
    vm.stopPrank();
  }
}

contract DecreaseLiquidity is FixedFeeSwapMarketTest {
  uint24 internal constant SOLVENCY_FEE_RATE = 3000;

  function setUp() public virtual override {
    super.setUp();
    defaultSwapParams = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
    _moveTickTo(500);
  }

  function _poolKeyForHook(FixedFeeSwapMarketHarness _localHook)
    internal
    view
    returns (PoolKey memory)
  {
    return PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 0,
      tickSpacing: 1,
      hooks: IHooks(address(_localHook))
    });
  }

  function _deployHookForSolvency(uint24 _feeRate, string memory _managerLabel)
    internal
    returns (FixedFeeSwapMarketHarness _localHook, PoolKey memory _localPoolKey, address charlie)
  {
    uint256 _currentTimestamp = block.timestamp;
    vm.warp(1);

    _localHook = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH,
      address(token0),
      address(token1),
      _feeRate,
      YIELD_PER_TICK,
      IPoolManager(makeAddr(_managerLabel)),
      0
    );

    uint256 _resumeTimestamp = _currentTimestamp > 1 days ? _currentTimestamp : 1 days + 1;
    vm.warp(_resumeTimestamp);

    _localPoolKey = _poolKeyForHook(_localHook);
    charlie = makeAddr(string.concat(_managerLabel, "-charlie"));
    _fundUser(charlie);

    vm.startPrank(alice);
    token0.approve(address(_localHook), type(uint256).max);
    token1.approve(address(_localHook), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(bob);
    token0.approve(address(_localHook), type(uint256).max);
    token1.approve(address(_localHook), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(charlie);
    token0.approve(address(_localHook), type(uint256).max);
    token1.approve(address(_localHook), type(uint256).max);
    vm.stopPrank();
  }

  function _warpFromHookStart(FixedFeeSwapMarketHarness _localHook, uint256 _timeElapsed) internal {
    vm.warp(_localHook.getStartTime() + _timeElapsed);
  }

  function _trySwapOnHook(
    FixedFeeSwapMarketHarness _localHook,
    PoolKey memory _localPoolKey,
    address _sender,
    int256 _amountIn,
    bool _principalForCash,
    int24 _tickLimit
  ) internal returns (bool) {
    bytes memory _hookParams = _encodeHookParams(_amountIn, _principalForCash, _tickLimit);
    try _localHook.exposed_beforeSwap(_sender, _localPoolKey, defaultSwapParams, _hookParams) {
      return true;
    } catch {
      return false;
    }
  }

  // ============ Position Update Tests ============

  /// @dev Decreasing updates the position and both _tick accounting dimensions consistently.
  function testFuzz_UpdatesPositionAndTickState(uint128 _initialLiquidity, uint128 _removeAmount)
    public
  {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _removeAmount = uint128(bound(_removeAmount, 1e17, _initialLiquidity));

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);

    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);

    vm.prank(alice);
    hook.decreaseLiquidity(_positionId, -int128(_removeAmount), 0, 0);

    uint128 _expectedRemaining = _initialLiquidity - _removeAmount;

    {
      (address _owner, int24 _lower, int24 _upper, int128 remainingLiquidity) =
        hook.getPositionInfo(_positionId);
      assertEq(_owner, alice, "_owner");
      assertEq(_lower, _tickLower, "_tickLower");
      assertEq(_upper, _tickUpper, "_tickUpper");
      assertEq(uint128(remainingLiquidity), _expectedRemaining, "position _liquidity");
    }

    {
      (uint128 lowerGross, int128 lowerNet) = hook.getTickInfo(_tickLower);
      (uint128 upperGross, int128 upperNet) = hook.getTickInfo(_tickUpper);
      assertEq(lowerGross, _expectedRemaining, "_lower gross");
      assertEq(upperGross, _expectedRemaining, "_upper gross");
      assertEq(lowerNet, int128(_expectedRemaining), "_lower net");
      assertEq(upperNet, -int128(_expectedRemaining), "_upper net");
    }
  }

  /// @dev Full withdrawal clears _tick bitmap bits
  function testFuzz_FullWithdrawalClearsTickBitmap(uint128 _liquidity) public {
    _liquidity = _boundLiquidity(_liquidity);

    _warpToMintTime();
    int24 _currentTick = hook.getCurrentTick();
    int24 _tickLower = _currentTick - 300;
    int24 _tickUpper = _currentTick + 300;

    (int16 lowerWord, uint8 lowerBit) = _bitmapPosition(_tickLower);
    (int16 upperWord, uint8 upperBit) = _bitmapPosition(_tickUpper);

    uint256 _lowerWordBefore = hook.getTickBitmapWord(lowerWord);
    uint256 _upperWordBefore = hook.getTickBitmapWord(upperWord);

    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _liquidity);

    // Verify bits are set after mint
    uint256 _lowerMask = uint256(1) << lowerBit;
    uint256 _upperMask = uint256(1) << upperBit;
    assertTrue(
      (hook.getTickBitmapWord(lowerWord) & _lowerMask) != 0,
      "Lower _tick bit should be set after mint"
    );
    assertTrue(
      (hook.getTickBitmapWord(upperWord) & _upperMask) != 0,
      "Upper _tick bit should be set after mint"
    );

    // Full withdrawal
    vm.prank(alice);
    hook.decreaseLiquidity(_positionId, -int128(_liquidity), 0, 0);

    // Verify words are restored exactly
    assertEq(
      hook.getTickBitmapWord(lowerWord), _lowerWordBefore, "Lower bitmap word should be restored"
    );
    if (upperWord != lowerWord) {
      assertEq(
        hook.getTickBitmapWord(upperWord), _upperWordBefore, "Upper bitmap word should be restored"
      );
    }

    // Verify _tick _liquidity is zero
    (uint128 lowerGross,) = hook.getTickInfo(_tickLower);
    (uint128 upperGross,) = hook.getTickInfo(_tickUpper);
    assertEq(lowerGross, 0, "Lower _tick should have zero _liquidity");
    assertEq(upperGross, 0, "Upper _tick should have zero _liquidity");
  }

  /// @dev Full withdrawal does not clear bitmap when other _liquidity remains at the same _ticks
  function testFuzz_FullWithdrawalDoesNotClearBitmapWhenOtherLiquidityRemains(
    uint128 _aliceLiquidity,
    uint128 _bobLiquidity
  ) public {
    SharedWithdrawalCtx memory _ctx;
    _ctx._aliceLiquidity = _boundLiquidity(_aliceLiquidity);
    _ctx._bobLiquidity = _boundLiquidity(_bobLiquidity);

    _warpToMintTime();
    int24 _currentTick = hook.getCurrentTick();
    _ctx._tickLower = _currentTick - 300;
    _ctx._tickUpper = _currentTick + 300;

    _ctx._alicePositionId =
      _mintLiquidityAtTicks(alice, _ctx._tickLower, _ctx._tickUpper, _ctx._aliceLiquidity);
    _warpToMintTime();
    _mintLiquidityAtTicks(bob, _ctx._tickLower, _ctx._tickUpper, _ctx._bobLiquidity);

    (_ctx.lowerWord, _ctx.lowerBit) = _bitmapPosition(_ctx._tickLower);
    (_ctx.upperWord, _ctx.upperBit) = _bitmapPosition(_ctx._tickUpper);
    _ctx._lowerWordAfterMint = hook.getTickBitmapWord(_ctx.lowerWord);
    _ctx._upperWordAfterMint = hook.getTickBitmapWord(_ctx.upperWord);

    uint256 _lowerMask = uint256(1) << _ctx.lowerBit;
    uint256 _upperMask = uint256(1) << _ctx.upperBit;
    assertTrue((_ctx._lowerWordAfterMint & _lowerMask) != 0, "Lower _tick bit should be set");
    assertTrue((_ctx._upperWordAfterMint & _upperMask) != 0, "Upper _tick bit should be set");

    // Alice fully withdraws; Bob remains
    _decreaseAllLiquidity(alice, _ctx._alicePositionId, _ctx._aliceLiquidity);

    assertEq(
      hook.getTickBitmapWord(_ctx.lowerWord),
      _ctx._lowerWordAfterMint,
      "Lower bitmap word should not change"
    );
    if (_ctx.upperWord != _ctx.lowerWord) {
      assertEq(
        hook.getTickBitmapWord(_ctx.upperWord),
        _ctx._upperWordAfterMint,
        "Upper bitmap word should not change"
      );
    }

    // Tick _liquidity should reflect _remaining _liquidity
    (uint128 lowerGross,) = hook.getTickInfo(_ctx._tickLower);
    (uint128 upperGross,) = hook.getTickInfo(_ctx._tickUpper);
    assertEq(lowerGross, _ctx._bobLiquidity, "Lower _tick gross should equal _remaining _liquidity");
    assertEq(upperGross, _ctx._bobLiquidity, "Upper _tick gross should equal _remaining _liquidity");
  }

  /// @dev Partial withdrawal keeps _tick bitmap bits set
  function testFuzz_PartialWithdrawalKeepsBitmapSet(
    uint128 _initialLiquidity,
    uint128 _removeAmount
  ) public {
    // Need at least 2e17 to leave 1e17 _remaining after partial withdrawal
    _initialLiquidity = uint128(bound(_initialLiquidity, 2e17, 3e24));
    // Ensure we leave at least 1e17 _remaining
    _removeAmount = uint128(bound(_removeAmount, 1e17, _initialLiquidity - 1e17));
    vm.assume(_removeAmount < _initialLiquidity);

    _warpToMintTime();
    int24 _currentTick = hook.getCurrentTick();
    int24 _tickLower = _currentTick - 300;
    int24 _tickUpper = _currentTick + 300;

    (int16 lowerWord, uint8 lowerBit) = _bitmapPosition(_tickLower);
    (int16 upperWord, uint8 upperBit) = _bitmapPosition(_tickUpper);
    uint256 _lowerWordBefore = hook.getTickBitmapWord(lowerWord);
    uint256 _upperWordBefore = hook.getTickBitmapWord(upperWord);

    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);

    uint256 _lowerWordAfterMint = hook.getTickBitmapWord(lowerWord);
    uint256 _upperWordAfterMint = hook.getTickBitmapWord(upperWord);
    assertNotEq(_lowerWordAfterMint, _lowerWordBefore, "Lower word should change on mint");
    if (upperWord != lowerWord) {
      assertNotEq(_upperWordAfterMint, _upperWordBefore, "Upper word should change on mint");
    }

    vm.prank(alice);
    hook.decreaseLiquidity(_positionId, -int128(_removeAmount), 0, 0);

    uint256 _lowerMask = uint256(1) << lowerBit;
    uint256 _upperMask = uint256(1) << upperBit;
    assertEq(
      hook.getTickBitmapWord(lowerWord), _lowerWordAfterMint, "Lower bitmap word should not change"
    );
    if (upperWord != lowerWord) {
      assertEq(
        hook.getTickBitmapWord(upperWord),
        _upperWordAfterMint,
        "Upper bitmap word should not change"
      );
    }
    assertTrue(
      (hook.getTickBitmapWord(lowerWord) & _lowerMask) != 0,
      "Lower _tick bit should remain set after partial withdrawal"
    );
    assertTrue(
      (hook.getTickBitmapWord(upperWord) & _upperMask) != 0,
      "Upper _tick bit should remain set after partial withdrawal"
    );
  }

  // ============ Token Transfer Tests ============

  /// @dev Decrease transfers _expected token amounts and preserves token conservation.
  function testFuzz_TransfersExpectedAmountsAndConservesTotals(
    uint128 _initialLiquidity,
    uint128 _removeAmount
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _removeAmount = uint128(bound(_removeAmount, 1e17, _initialLiquidity));

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);

    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);

    (int256 expected0, int256 expected1) =
      _expectedMintAmounts(_tickLower, _tickUpper, _removeAmount);

    uint256 _user0Before = token0.balanceOf(alice);
    uint256 _user1Before = token1.balanceOf(alice);
    uint256 _hook0Before = token0.balanceOf(address(hook));
    uint256 _hook1Before = token1.balanceOf(address(hook));
    uint256 _total0Before = _user0Before + _hook0Before;
    uint256 _total1Before = _user1Before + _hook1Before;

    vm.prank(alice);
    hook.decreaseLiquidity(_positionId, -int128(_removeAmount), 0, 0);

    uint256 _user0After = token0.balanceOf(alice);
    uint256 _user1After = token1.balanceOf(alice);
    uint256 _hook0After = token0.balanceOf(address(hook));
    uint256 _hook1After = token1.balanceOf(address(hook));

    assertEq(int256(_user0After - _user0Before), expected0, "_user token0 _received");
    assertEq(int256(_user1After - _user1Before), expected1, "_user token1 _received");
    assertEq(int256(_hook0Before - _hook0After), expected0, "hook token0 debited");
    assertEq(int256(_hook1Before - _hook1After), expected1, "hook token1 debited");
    assertEq(_user0After + _hook0After, _total0Before, "token0 conservation");
    assertEq(_user1After + _hook1After, _total1Before, "token1 conservation");
  }

  // ============ Active Liquidity Tests ============

  /// @dev In-range decreases reduce active _liquidity by the removed _amount.
  function testFuzz_InRangeDecreaseUpdatesActiveLiquidity(
    uint128 _initialLiquidity,
    uint128 _removeAmount
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _removeAmount = uint128(bound(_removeAmount, 1e17, _initialLiquidity));

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);

    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);
    uint128 _activeBefore = hook.getActiveLiquidity();

    vm.prank(alice);
    hook.decreaseLiquidity(_positionId, -int128(_removeAmount), 0, 0);

    assertEq(hook.getActiveLiquidity(), _activeBefore - _removeAmount, "active _liquidity decrease");
  }

  /// @dev Out-of-range decreases do not change active _liquidity.
  function testFuzz_OutOfRangeDecreaseDoesNotUpdateActiveLiquidity(
    uint128 _initialLiquidity,
    uint128 _removeAmount,
    uint8 _scenario
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _removeAmount = uint128(bound(_removeAmount, 1e17, _initialLiquidity));

    _warpToMintTime();
    uint8 _boundedScenario = uint8(bound(_scenario, 0, 1));
    RangeScenario _rangeScenario =
      _boundedScenario == 0 ? RangeScenario.BelowCurrent : RangeScenario.AboveCurrent;
    (int24 _tickLower, int24 _tickUpper) = _standardRange(_rangeScenario);

    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);
    uint128 _activeBefore = hook.getActiveLiquidity();

    vm.prank(alice);
    hook.decreaseLiquidity(_positionId, -int128(_removeAmount), 0, 0);

    assertEq(hook.getActiveLiquidity(), _activeBefore, "active _liquidity unchanged");
  }

  // ============ Multiple Operations Tests ============

  /// @dev Multiple decreases on one position add up to the same final state.
  function testFuzz_MultipleDecreasesAccumulateLiquidity(
    uint128 _initialLiquidity,
    uint128 _decrease1,
    uint128 _decrease2
  ) public {
    // Need at least 3e17 so that _maxDecrease >= 1e17
    _initialLiquidity = uint128(bound(_initialLiquidity, 3e17, 3e24));
    // Ensure we can do two decreases
    uint128 _maxDecrease = _initialLiquidity / 3;
    _decrease1 = uint128(bound(_decrease1, 1e17, _maxDecrease));
    _decrease2 = uint128(bound(_decrease2, 1e17, _maxDecrease));

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);

    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);

    vm.startPrank(alice);
    hook.decreaseLiquidity(_positionId, -int128(_decrease1), 0, 0);
    hook.decreaseLiquidity(_positionId, -int128(_decrease2), 0, 0);
    vm.stopPrank();

    (,,, int128 remainingLiquidity) = hook.getPositionInfo(_positionId);
    assertEq(
      uint128(remainingLiquidity),
      _initialLiquidity - _decrease1 - _decrease2,
      "Position _liquidity should equal initial minus all decreases"
    );

    (uint128 lowerGross,) = hook.getTickInfo(_tickLower);
    assertEq(
      lowerGross,
      _initialLiquidity - _decrease1 - _decrease2,
      "Tick _liquidity should equal initial minus all decreases"
    );
  }

  /// @dev Decrease then increase is symmetric (same token amounts)
  function testFuzz_DecreaseIncreaseSymmetry(uint128 _baseAmount, uint128 _deltaAmount) public {
    // Need at least 2e17 so that _baseAmount / 2 >= 1e17
    _baseAmount = uint128(bound(_baseAmount, 2e17, 3e24));
    _deltaAmount = uint128(bound(_deltaAmount, 1e17, _baseAmount / 2));

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);

    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _baseAmount);

    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);

    vm.startPrank(alice);
    hook.decreaseLiquidity(_positionId, -int128(_deltaAmount), 0, 0);
    hook.increaseLiquidity(_positionId, _deltaAmount, type(uint256).max, type(uint256).max);
    vm.stopPrank();

    (,,, int128 finalLiquidity) = hook.getPositionInfo(_positionId);
    assertEq(token0.balanceOf(alice), _balance0Before, "token0 symmetric");
    assertEq(token1.balanceOf(alice), _balance1Before, "token1 symmetric");
    assertEq(uint128(finalLiquidity), _baseAmount, "_liquidity restored");
  }

  /// @dev Different users can decrease independent positions in the same range.
  function testFuzz_MultipleUsersDecreaseIndependentPositions(
    uint128 _aliceInitial,
    uint128 _aliceDecrease
  ) public {
    _aliceInitial = _boundLiquidity(_aliceInitial);
    _aliceDecrease = uint128(bound(_aliceDecrease, 1e17, _aliceInitial));
    uint128 _bobInitial = 1e18;
    uint128 _bobDecrease = 5e17;

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);

    bytes32 _alicePositionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _aliceInitial);
    bytes32 _bobPositionId = _mintLiquidityAtTicks(bob, _tickLower, _tickUpper, _bobInitial);

    vm.prank(alice);
    hook.decreaseLiquidity(_alicePositionId, -int128(_aliceDecrease), 0, 0);

    vm.prank(bob);
    hook.decreaseLiquidity(_bobPositionId, -int128(_bobDecrease), 0, 0);

    (,,, int128 aliceLiq) = hook.getPositionInfo(_alicePositionId);
    (,,, int128 bobLiq) = hook.getPositionInfo(_bobPositionId);

    assertEq(uint128(aliceLiq), _aliceInitial - _aliceDecrease, "Alice _liquidity should match");
    assertEq(uint128(bobLiq), _bobInitial - _bobDecrease, "Bob _liquidity should match");

    (uint128 lowerGross,) = hook.getTickInfo(_tickLower);
    uint128 _expectedTotal = (_aliceInitial - _aliceDecrease) + (_bobInitial - _bobDecrease);
    assertEq(lowerGross, _expectedTotal, "Tick should have _combined _remaining _liquidity");
  }

  // ============ Token Amount Tests Based on Position ============

  /// @dev Below-current positions return only token0 on decrease.
  function testFuzz_BelowCurrentRangeDecreaseReturnsOnlyToken0(
    uint128 _initialLiquidity,
    uint128 _removeAmount
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _removeAmount = uint128(bound(_removeAmount, 1e17, _initialLiquidity));

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.BelowCurrent);

    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);

    (int256 expected0, int256 expected1) =
      _expectedMintAmounts(_tickLower, _tickUpper, _removeAmount);

    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.decreaseLiquidity(_positionId, -int128(_removeAmount), 0, 0);

    assertGt(expected0, 0, "_expected token0");
    assertEq(expected1, 0, "_expected token1");
    assertEq(int256(token0.balanceOf(alice) - _balance0Before), expected0, "token0 _received");
    assertEq(int256(token1.balanceOf(alice) - _balance1Before), expected1, "token1 _received");
  }

  /// @dev Above-current positions return only token1 on decrease.
  function testFuzz_AboveCurrentRangeDecreaseReturnsOnlyToken1(
    uint128 _initialLiquidity,
    uint128 _removeAmount
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _removeAmount = uint128(bound(_removeAmount, 1e17, _initialLiquidity));

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.AboveCurrent);

    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);

    (int256 expected0, int256 expected1) =
      _expectedMintAmounts(_tickLower, _tickUpper, _removeAmount);

    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.decreaseLiquidity(_positionId, -int128(_removeAmount), 0, 0);

    assertEq(expected0, 0, "_expected token0");
    assertGt(expected1, 0, "_expected token1");
    assertEq(int256(token0.balanceOf(alice) - _balance0Before), expected0, "token0 _received");
    assertEq(int256(token1.balanceOf(alice) - _balance1Before), expected1, "token1 _received");
  }

  /// @dev In-range positions return both tokens on decrease.
  function testFuzz_InRangeDecreaseReturnsBothTokens(
    uint128 _initialLiquidity,
    uint128 _removeAmount
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _removeAmount = uint128(bound(_removeAmount, 1e17, _initialLiquidity));

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);

    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);

    (int256 expected0, int256 expected1) =
      _expectedMintAmounts(_tickLower, _tickUpper, _removeAmount);

    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.decreaseLiquidity(_positionId, -int128(_removeAmount), 0, 0);

    assertGt(expected0, 0, "_expected token0");
    assertGt(expected1, 0, "_expected token1");
    assertEq(int256(token0.balanceOf(alice) - _balance0Before), expected0, "token0 _received");
    assertEq(int256(token1.balanceOf(alice) - _balance1Before), expected1, "token1 _received");
  }

  /// @dev For the same in-range burn size, token0 stays constant while token1 changes with _time.
  function test_DecreaseCashReturnedChangesWithTime_ForInRangePosition() public {
    uint128 _initialLiquidity = 1e24;
    uint128 _removeAmount = 5e23;

    (int24 _tickLower, int24 _tickUpper) =
      _rangeForScenario(hook.getCurrentTick(), RangeScenario.InRange, 200);

    _warpFromStart(1);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);
    uint256 _snapshot = vm.snapshotState();

    _warpFromStart(1);
    Amounts memory _expectedAtT1;
    {
      (int256 e0, int256 e1) = _expectedMintAmounts(_tickLower, _tickUpper, _removeAmount);
      _expectedAtT1.amount0 = e0;
      _expectedAtT1._amount1 = e1;
    }
    Amounts memory _receivedAtT1;
    {
      (uint256 received0, uint256 received1) = _decreaseLiquidity(alice, _positionId, _removeAmount);
      _receivedAtT1.amount0 = int256(received0);
      _receivedAtT1._amount1 = int256(received1);
    }

    vm.revertToState(_snapshot);

    _warpFromStart(30 days);
    Amounts memory _expectedAtT2;
    {
      (int256 e0, int256 e1) = _expectedMintAmounts(_tickLower, _tickUpper, _removeAmount);
      _expectedAtT2.amount0 = e0;
      _expectedAtT2._amount1 = e1;
    }
    Amounts memory _receivedAtT2;
    {
      (uint256 received0, uint256 received1) = _decreaseLiquidity(alice, _positionId, _removeAmount);
      _receivedAtT2.amount0 = int256(received0);
      _receivedAtT2._amount1 = int256(received1);
    }

    assertEq(_receivedAtT1.amount0, _expectedAtT1.amount0, "t1 token0");
    assertEq(_receivedAtT1._amount1, _expectedAtT1._amount1, "t1 token1");
    assertEq(_receivedAtT2.amount0, _expectedAtT2.amount0, "t2 token0");
    assertEq(_receivedAtT2._amount1, _expectedAtT2._amount1, "t2 token1");
    assertEq(_expectedAtT2.amount0, _expectedAtT1.amount0, "principal invariant");
    assertNotEq(_expectedAtT2._amount1, _expectedAtT1._amount1, "cash changes over _time");
  }

  // ============ Slippage Tests ============

  /// @dev Decrease succeeds when min amounts equal the exact returned amounts.
  function testFuzz_AllowsWhen_MinTokenAmountsEqualReturnedAmounts(
    uint128 _initialLiquidity,
    uint128 _removeAmount
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _removeAmount = uint128(bound(_removeAmount, 1e17, _initialLiquidity));

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);

    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);

    (int256 expected0, int256 expected1) =
      _expectedMintAmounts(_tickLower, _tickUpper, _removeAmount);

    vm.prank(alice);
    hook.decreaseLiquidity(
      _positionId, -int128(_removeAmount), uint256(expected0), uint256(expected1)
    );

    (,,, int128 remainingLiquidity) = hook.getPositionInfo(_positionId);
    assertEq(uint128(remainingLiquidity), _initialLiquidity - _removeAmount, "_liquidity decreased");
  }

  // ============ Revert Tests ============

  /// @dev Reverts when position not found
  function test_RevertWhen_PositionNotFound() public {
    bytes32 _missingPositionId = keccak256("missing position");

    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_PositionNotFound.selector);
    hook.decreaseLiquidity(_missingPositionId, -1e18, 0, 0);
  }

  /// @dev Reverts when caller is not position _owner
  function testFuzz_RevertWhen_NotPositionOwner(uint128 _initialLiquidity, uint128 _removeAmount)
    public
  {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _removeAmount = uint128(bound(_removeAmount, 1e17, _initialLiquidity));

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);

    vm.prank(bob);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_NotPositionOwner.selector);
    hook.decreaseLiquidity(_positionId, -int128(_removeAmount), 0, 0);
  }

  /// @dev Reverts when min token0 exceeds what _a below-current decrease can return.
  function testFuzz_RevertWhen_BelowCurrentToken0SlippageExceeded(
    uint128 _initialLiquidity,
    uint128 _removeAmount
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _removeAmount = uint128(bound(_removeAmount, 1e17, _initialLiquidity));

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.BelowCurrent);

    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);

    (int256 expected0,) = _expectedMintAmounts(_tickLower, _tickUpper, _removeAmount);

    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_InvalidLiquidityAmount.selector);
    hook.decreaseLiquidity(_positionId, -int128(_removeAmount), uint256(expected0) + 1, 0);
  }

  /// @dev Reverts when min token1 exceeds what an above-current decrease can return.
  function testFuzz_RevertWhen_AboveCurrentToken1SlippageExceeded(
    uint128 _initialLiquidity,
    uint128 _removeAmount
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _removeAmount = uint128(bound(_removeAmount, 1e17, _initialLiquidity));

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.AboveCurrent);

    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);

    (, int256 expected1) = _expectedMintAmounts(_tickLower, _tickUpper, _removeAmount);

    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_InvalidLiquidityAmount.selector);
    hook.decreaseLiquidity(_positionId, -int128(_removeAmount), 0, uint256(expected1) + 1);
  }

  /// @dev Reverts when token0 _amount is below min (in-range position)
  function testFuzz_RevertWhen_InRangeToken0SlippageExceeded(
    uint128 _initialLiquidity,
    uint128 _removeAmount
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _removeAmount = uint128(bound(_removeAmount, 1e17, _initialLiquidity));

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);

    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);

    (int256 expected0,) = _expectedMintAmounts(_tickLower, _tickUpper, _removeAmount);

    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_InvalidLiquidityAmount.selector);
    hook.decreaseLiquidity(_positionId, -int128(_removeAmount), uint256(expected0) + 1, 0);
  }

  /// @dev Reverts when token1 _amount is below min (in-range position)
  function testFuzz_RevertWhen_InRangeToken1SlippageExceeded(
    uint128 _initialLiquidity,
    uint128 _removeAmount
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _removeAmount = uint128(bound(_removeAmount, 1e17, _initialLiquidity));

    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);

    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);

    (, int256 expected1) = _expectedMintAmounts(_tickLower, _tickUpper, _removeAmount);

    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_InvalidLiquidityAmount.selector);
    hook.decreaseLiquidity(_positionId, -int128(_removeAmount), 0, uint256(expected1) + 1);
  }

  // ============ Fuzzed Time Tests ============

  /// @dev Decrease at any valid _time preserves conservation and updates _liquidity.
  function testFuzz_DecreaseMaintainsConservationAtAnyTime(
    uint128 _initialLiquidity,
    uint128 _removeAmount,
    uint256 _timeElapsed
  ) public {
    _initialLiquidity = _boundLiquidity(_initialLiquidity);
    _removeAmount = uint128(bound(_removeAmount, 1e17, _initialLiquidity));
    _timeElapsed = bound(_timeElapsed, 1, MARKET_LENGTH - 1);
    _warpFromStart(_timeElapsed);

    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _initialLiquidity);

    uint256 _total0Before = token0.balanceOf(alice) + token0.balanceOf(address(hook));
    uint256 _total1Before = token1.balanceOf(alice) + token1.balanceOf(address(hook));

    vm.prank(alice);
    hook.decreaseLiquidity(_positionId, -int128(_removeAmount), 0, 0);

    (,,, int128 remainingLiquidity) = hook.getPositionInfo(_positionId);
    uint256 _total0After = token0.balanceOf(alice) + token0.balanceOf(address(hook));
    uint256 _total1After = token1.balanceOf(alice) + token1.balanceOf(address(hook));

    assertEq(uint128(remainingLiquidity), _initialLiquidity - _removeAmount, "_liquidity decrease");
    assertEq(_total0After, _total0Before, "token0 conservation");
    assertEq(_total1After, _total1Before, "token1 conservation");
  }

  function test_EmitsLiquidityModified_OnDecrease() public {
    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);
    uint128 _liquidity = 1e20;

    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _liquidity);

    uint128 _removeAmount = 5e19;

    vm.expectEmit(true, true, false, false, address(hook));
    emit FixedFeeSwapMarket.LiquidityModified(_positionId, alice, _tickLower, _tickUpper, 0, 0, 0);

    vm.prank(alice);
    hook.decreaseLiquidity(_positionId, -int128(_removeAmount), 0, 0);
  }

  function test_RevertWhen_LiquidityDeltaIsZero_OnDecrease() public {
    _warpToMintTime();
    (int24 _tickLower, int24 _tickUpper) = _standardRange(RangeScenario.InRange);

    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, 1e20);

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_LiquidityDeltaMustBeNegative.selector);
    vm.prank(alice);
    hook.decreaseLiquidity(_positionId, 0, 0, 0);
  }

  // ============ Solvency Tests ============

  function testFuzz_SingleLPCanWithdrawAfterPrincipalForCashSwap(
    int24 _tickUpper,
    uint128 _liquidity,
    uint256 _swapAmount,
    uint256 _timeElapsed
  ) public {
    (FixedFeeSwapMarketHarness _localHook, PoolKey memory _localPoolKey,) =
      _deployHookForSolvency(0, "solvencySinglePrincipalForCash");

    _tickUpper = int24(bound(int256(_tickUpper), 4, 2000));
    _liquidity = uint128(bound(_liquidity, 1e18, 1e24));
    _swapAmount = _boundSwapForRange(_swapAmount, _liquidity, _tickUpper, 500);
    _timeElapsed = bound(_timeElapsed, 1 days, MARKET_LENGTH - 1);

    _warpFromHookStart(_localHook, 1);
    bytes32 _positionId = _mintOnHook(_localHook, alice, 0, _tickUpper, _liquidity);

    _warpFromHookStart(_localHook, _timeElapsed);

    _swapOnHook(_localHook, _localPoolKey, bob, int256(_swapAmount), true, NO_TICK_LIMIT);

    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);
    vm.prank(alice);
    _localHook.decreaseLiquidity(_positionId, -int128(uint128(_liquidity)), 0, 0);

    assertGe(token0.balanceOf(alice), _balance0Before, "LP should receive token0");
    assertGe(token1.balanceOf(alice), _balance1Before, "LP should receive token1");
  }

  function testFuzz_SingleLPCanWithdrawAfterRoundTripSwap(
    int24 _tickUpper,
    uint128 _liquidity,
    uint256 _swapAmount1,
    uint256 _swapAmount2,
    uint256 _timeElapsed
  ) public {
    (FixedFeeSwapMarketHarness _localHook, PoolKey memory _localPoolKey,) =
      _deployHookForSolvency(0, "solvencySingleRoundTrip");

    _tickUpper = int24(bound(int256(_tickUpper), 4, 2000));
    _liquidity = uint128(bound(_liquidity, 1e18, 1e24));
    _swapAmount1 = _boundSwapForRange(_swapAmount1, _liquidity, _tickUpper, 500);
    _swapAmount2 =
      bound(_swapAmount2, uint256(_liquidity) * 2 / BIPS, uint256(_liquidity) * 500 / BIPS);
    _timeElapsed = bound(_timeElapsed, 1 days, MARKET_LENGTH - 1);

    _warpFromHookStart(_localHook, 1);
    bytes32 _positionId = _mintOnHook(_localHook, alice, 0, _tickUpper, _liquidity);

    _warpFromHookStart(_localHook, _timeElapsed);

    _swapOnHook(_localHook, _localPoolKey, bob, int256(_swapAmount1), true, NO_TICK_LIMIT);
    _trySwapOnHook(_localHook, _localPoolKey, bob, int256(_swapAmount2), false, NO_TICK_LIMIT);

    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);
    vm.prank(alice);
    _localHook.decreaseLiquidity(_positionId, -int128(uint128(_liquidity)), 0, 0);

    assertGe(token0.balanceOf(alice), _balance0Before, "LP should receive token0");
    assertGe(token1.balanceOf(alice), _balance1Before, "LP should receive token1");
  }

  function testFuzz_TwoLpsCanBothWithdrawAfterSwap(
    int24 _tickUpper1,
    int24 _tickLower2,
    int24 _tickUpper2,
    uint128 _liquidity1,
    uint128 _liquidity2,
    uint256 _swapAmount,
    uint256 _timeElapsed
  ) public {
    (FixedFeeSwapMarketHarness _localHook, PoolKey memory _localPoolKey, address charlie) =
      _deployHookForSolvency(0, "solvencyTwoLps");

    _tickUpper1 = int24(bound(int256(_tickUpper1), 4, 2000));
    _tickLower2 = int24(bound(int256(_tickLower2), 0, 1999));
    _tickUpper2 = int24(bound(int256(_tickUpper2), int256(_tickLower2) + 1, 2000));
    _liquidity1 = uint128(bound(_liquidity1, 1e18, 1e24));
    _liquidity2 = uint128(bound(_liquidity2, 1e18, 1e24));
    _swapAmount = _boundSwapForRange(_swapAmount, _liquidity1, _tickUpper1, 500);
    _timeElapsed = bound(_timeElapsed, 1 days, MARKET_LENGTH - 1);

    _warpFromHookStart(_localHook, 1);
    bytes32 _positionId1 = _mintOnHook(_localHook, alice, 0, _tickUpper1, _liquidity1);
    bytes32 _positionId2 = _mintOnHook(_localHook, charlie, _tickLower2, _tickUpper2, _liquidity2);

    _warpFromHookStart(_localHook, _timeElapsed);

    _swapOnHook(_localHook, _localPoolKey, bob, int256(_swapAmount), true, NO_TICK_LIMIT);

    vm.prank(alice);
    _localHook.decreaseLiquidity(_positionId1, -int128(uint128(_liquidity1)), 0, 0);
    vm.prank(charlie);
    _localHook.decreaseLiquidity(_positionId2, -int128(uint128(_liquidity2)), 0, 0);
  }

  function testFuzz_PartialThenFullWithdrawIsSolventAcrossSwaps(
    int24 _tickUpper,
    uint128 _liquidity,
    uint128 _partialRemove,
    uint256 _swapAmount1,
    uint256 _swapAmount2,
    uint256 _timeElapsed
  ) public {
    (FixedFeeSwapMarketHarness _localHook, PoolKey memory _localPoolKey,) =
      _deployHookForSolvency(0, "solvencyPartialFull");

    _tickUpper = int24(bound(int256(_tickUpper), 4, 2000));
    _liquidity = uint128(bound(_liquidity, 1e18, 1e24));
    _partialRemove = uint128(bound(_partialRemove, 1e17, uint256(_liquidity) / 2));
    _swapAmount1 = _boundSwapForRange(_swapAmount1, _liquidity, _tickUpper, 500);
    _swapAmount2 =
      bound(_swapAmount2, uint256(_liquidity) * 2 / BIPS, uint256(_liquidity) * 500 / BIPS);
    _timeElapsed = bound(_timeElapsed, 1 days, MARKET_LENGTH - 1);

    _warpFromHookStart(_localHook, 1);
    bytes32 _positionId = _mintOnHook(_localHook, alice, 0, _tickUpper, _liquidity);

    _warpFromHookStart(_localHook, _timeElapsed);

    _swapOnHook(_localHook, _localPoolKey, bob, int256(_swapAmount1), true, NO_TICK_LIMIT);

    vm.prank(alice);
    _localHook.decreaseLiquidity(_positionId, -int128(_partialRemove), 0, 0);

    _trySwapOnHook(_localHook, _localPoolKey, bob, int256(_swapAmount2), true, NO_TICK_LIMIT);

    uint128 _remaining = _liquidity - _partialRemove;
    vm.prank(alice);
    _localHook.decreaseLiquidity(_positionId, -int128(_remaining), 0, 0);
  }

  function testFuzz_SingleLPCanWithdrawAfterCashForPrincipalSwap(
    int24 _tickUpper,
    uint128 _liquidity,
    uint256 _setupSwapAmount,
    uint256 _cashSwapAmount,
    uint256 _timeElapsed
  ) public {
    (FixedFeeSwapMarketHarness _localHook, PoolKey memory _localPoolKey,) =
      _deployHookForSolvency(0, "solvencySingleCashForPrincipal");

    _tickUpper = int24(bound(int256(_tickUpper), 4, 2000));
    _liquidity = uint128(bound(_liquidity, 1e18, 1e24));
    _setupSwapAmount = _boundSwapForRange(_setupSwapAmount, _liquidity, _tickUpper, 500);
    _cashSwapAmount =
      bound(_cashSwapAmount, uint256(_liquidity) * 2 / BIPS, uint256(_liquidity) * 500 / BIPS);
    _timeElapsed = bound(_timeElapsed, 1 days, MARKET_LENGTH - 1);

    _warpFromHookStart(_localHook, 1);
    bytes32 _positionId = _mintOnHook(_localHook, alice, 0, _tickUpper, _liquidity);

    _warpFromHookStart(_localHook, _timeElapsed);

    _swapOnHook(_localHook, _localPoolKey, bob, int256(_setupSwapAmount), true, NO_TICK_LIMIT);

    _trySwapOnHook(_localHook, _localPoolKey, bob, int256(_cashSwapAmount), false, NO_TICK_LIMIT);

    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);
    vm.prank(alice);
    _localHook.decreaseLiquidity(_positionId, -int128(uint128(_liquidity)), 0, 0);

    assertGe(token0.balanceOf(alice), _balance0Before, "LP should receive token0");
    assertGe(token1.balanceOf(alice), _balance1Before, "LP should receive token1");
  }

  function testFuzz_SingleLPCanWithdrawAfterCashThenPrincipalRoundTrip(
    int24 _tickUpper,
    uint128 _liquidity,
    uint256 _setupAmount,
    uint256 _cashForPrincipalAmount,
    uint256 _principalForCashAmount,
    uint256 _timeElapsed
  ) public {
    (FixedFeeSwapMarketHarness _localHook, PoolKey memory _localPoolKey,) =
      _deployHookForSolvency(0, "solvencyCashThenPrincipal");

    _tickUpper = int24(bound(int256(_tickUpper), 104, 2000));
    _liquidity = uint128(bound(_liquidity, 1e18, 1e24));
    _setupAmount = _boundSwapForRange(_setupAmount, _liquidity, _tickUpper, 500);
    _cashForPrincipalAmount = bound(
      _cashForPrincipalAmount, uint256(_liquidity) * 2 / BIPS, uint256(_liquidity) * 250 / BIPS
    );
    _principalForCashAmount = bound(
      _principalForCashAmount, uint256(_liquidity) * 2 / BIPS, uint256(_liquidity) * 250 / BIPS
    );
    _timeElapsed = bound(_timeElapsed, 1 days, MARKET_LENGTH - 1);

    _warpFromHookStart(_localHook, 1);
    bytes32 _positionId = _mintOnHook(_localHook, alice, 0, _tickUpper, _liquidity);

    _warpFromHookStart(_localHook, _timeElapsed);

    _swapOnHook(_localHook, _localPoolKey, bob, int256(_setupAmount), true, NO_TICK_LIMIT);

    _trySwapOnHook(
      _localHook, _localPoolKey, bob, int256(_cashForPrincipalAmount), false, NO_TICK_LIMIT
    );
    _trySwapOnHook(
      _localHook, _localPoolKey, bob, int256(_principalForCashAmount), true, NO_TICK_LIMIT
    );

    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);
    vm.prank(alice);
    _localHook.decreaseLiquidity(_positionId, -int128(uint128(_liquidity)), 0, 0);

    assertGe(token0.balanceOf(alice), _balance0Before, "LP should receive token0");
    assertGe(token1.balanceOf(alice), _balance1Before, "LP should receive token1");
  }

  function testFuzz_MintSwapWaitWithdrawIsSolvent(
    int24 _tickUpper,
    uint128 _liquidity,
    uint256 _swapAmount,
    uint256 _swapTime,
    uint256 _withdrawTime
  ) public {
    (FixedFeeSwapMarketHarness _localHook, PoolKey memory _localPoolKey,) =
      _deployHookForSolvency(0, "solvencyMintSwapWaitWithdraw");

    _tickUpper = int24(bound(int256(_tickUpper), 4, 2000));
    _liquidity = uint128(bound(_liquidity, 1e18, 1e24));
    _swapAmount = _boundSwapForRange(_swapAmount, _liquidity, _tickUpper, 500);
    _swapTime = bound(_swapTime, 1 days, MARKET_LENGTH / 2);
    _withdrawTime = bound(_withdrawTime, _swapTime + 1, MARKET_LENGTH - 1);

    _warpFromHookStart(_localHook, 1);
    bytes32 _positionId = _mintOnHook(_localHook, alice, 0, _tickUpper, _liquidity);

    _warpFromHookStart(_localHook, _swapTime);
    _swapOnHook(_localHook, _localPoolKey, bob, int256(_swapAmount), true, NO_TICK_LIMIT);

    _warpFromHookStart(_localHook, _withdrawTime);

    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);
    vm.prank(alice);
    _localHook.decreaseLiquidity(_positionId, -int128(uint128(_liquidity)), 0, 0);

    assertGe(token0.balanceOf(alice), _balance0Before, "LP should receive token0");
    assertGe(token1.balanceOf(alice), _balance1Before, "LP should receive token1");
  }

  function testFuzz_SingleLPCanWithdrawAfterPrincipalForCashSwap_WithFees(
    int24 _tickUpper,
    uint128 _liquidity,
    uint256 _swapAmount,
    uint256 _timeElapsed
  ) public {
    (FixedFeeSwapMarketHarness feeHook, PoolKey memory feePoolKey,) =
      _deployHookForSolvency(SOLVENCY_FEE_RATE, "solvencySinglePrincipalForCashFees");

    _tickUpper = int24(bound(int256(_tickUpper), 4, 2000));
    _liquidity = uint128(bound(_liquidity, 1e18, 1e24));
    _swapAmount = _boundSwapForRange(_swapAmount, _liquidity, _tickUpper, 500);
    _timeElapsed = bound(_timeElapsed, 1 days, MARKET_LENGTH - 1);

    _warpFromHookStart(feeHook, 1);
    bytes32 _positionId = _mintOnHook(feeHook, alice, 0, _tickUpper, _liquidity);

    _warpFromHookStart(feeHook, _timeElapsed);

    _swapOnHook(feeHook, feePoolKey, bob, int256(_swapAmount), true, NO_TICK_LIMIT);

    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);
    vm.prank(alice);
    feeHook.decreaseLiquidity(_positionId, -int128(uint128(_liquidity)), 0, 0);

    assertGe(token0.balanceOf(alice), _balance0Before, "LP should receive token0");
    assertGe(token1.balanceOf(alice), _balance1Before, "LP should receive token1");
  }

  function testFuzz_SingleLPCanWithdrawAfterCashForPrincipalSwap_WithFees(
    int24 _tickUpper,
    uint128 _liquidity,
    uint256 _setupSwapAmount,
    uint256 _cashSwapAmount,
    uint256 _timeElapsed
  ) public {
    (FixedFeeSwapMarketHarness feeHook, PoolKey memory feePoolKey,) =
      _deployHookForSolvency(SOLVENCY_FEE_RATE, "solvencySingleCashForPrincipalFees");

    _tickUpper = int24(bound(int256(_tickUpper), 4, 2000));
    _liquidity = uint128(bound(_liquidity, 1e18, 1e24));
    _setupSwapAmount = _boundSwapForRange(_setupSwapAmount, _liquidity, _tickUpper, 500);
    _cashSwapAmount =
      bound(_cashSwapAmount, uint256(_liquidity) * 2 / BIPS, uint256(_liquidity) * 500 / BIPS);
    _timeElapsed = bound(_timeElapsed, 1 days, MARKET_LENGTH - 1);

    _warpFromHookStart(feeHook, 1);
    bytes32 _positionId = _mintOnHook(feeHook, alice, 0, _tickUpper, _liquidity);

    _warpFromHookStart(feeHook, _timeElapsed);

    _swapOnHook(feeHook, feePoolKey, bob, int256(_setupSwapAmount), true, NO_TICK_LIMIT);

    _trySwapOnHook(feeHook, feePoolKey, bob, int256(_cashSwapAmount), false, NO_TICK_LIMIT);

    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);
    vm.prank(alice);
    feeHook.decreaseLiquidity(_positionId, -int128(uint128(_liquidity)), 0, 0);

    assertGe(token0.balanceOf(alice), _balance0Before, "LP should receive token0");
    assertGe(token1.balanceOf(alice), _balance1Before, "LP should receive token1");
  }

  function testFuzz_TwoLpsCanBothWithdrawAfterSwap_WithFees(
    int24 _tickUpper1,
    int24 _tickLower2,
    int24 _tickUpper2,
    uint128 _liquidity1,
    uint128 _liquidity2,
    uint256 _swapAmount,
    uint256 _timeElapsed
  ) public {
    (FixedFeeSwapMarketHarness feeHook, PoolKey memory feePoolKey, address charlie) =
      _deployHookForSolvency(SOLVENCY_FEE_RATE, "solvencyTwoLpsFees");

    _tickUpper1 = int24(bound(int256(_tickUpper1), 4, 2000));
    _tickLower2 = int24(bound(int256(_tickLower2), 0, 1999));
    _tickUpper2 = int24(bound(int256(_tickUpper2), int256(_tickLower2) + 1, 2000));
    _liquidity1 = uint128(bound(_liquidity1, 1e18, 1e24));
    _liquidity2 = uint128(bound(_liquidity2, 1e18, 1e24));
    _swapAmount = _boundSwapForRange(_swapAmount, _liquidity1, _tickUpper1, 500);
    _timeElapsed = bound(_timeElapsed, 1 days, MARKET_LENGTH - 1);

    _warpFromHookStart(feeHook, 1);
    bytes32 _positionId1 = _mintOnHook(feeHook, alice, 0, _tickUpper1, _liquidity1);
    bytes32 _positionId2 = _mintOnHook(feeHook, charlie, _tickLower2, _tickUpper2, _liquidity2);

    _warpFromHookStart(feeHook, _timeElapsed);

    _swapOnHook(feeHook, feePoolKey, bob, int256(_swapAmount), true, NO_TICK_LIMIT);

    vm.prank(alice);
    feeHook.decreaseLiquidity(_positionId1, -int128(uint128(_liquidity1)), 0, 0);
    vm.prank(charlie);
    feeHook.decreaseLiquidity(_positionId2, -int128(uint128(_liquidity2)), 0, 0);
  }

  function testFuzz_WithdrawAfterFeeCollectionIsSolvent(
    int24 _tickUpper,
    uint128 _liquidity,
    uint256 _swapAmount,
    uint256 _timeElapsed
  ) public {
    (FixedFeeSwapMarketHarness feeHook, PoolKey memory feePoolKey,) =
      _deployHookForSolvency(SOLVENCY_FEE_RATE, "solvencyWithdrawAfterCollectFees");

    _tickUpper = int24(bound(int256(_tickUpper), 4, 2000));
    _liquidity = uint128(bound(_liquidity, 1e18, 1e24));
    _swapAmount = _boundSwapForRange(_swapAmount, _liquidity, _tickUpper, 500);
    _timeElapsed = bound(_timeElapsed, 1 days, MARKET_LENGTH - 1);

    _warpFromHookStart(feeHook, 1);
    bytes32 _positionId = _mintOnHook(feeHook, alice, 0, _tickUpper, _liquidity);

    _warpFromHookStart(feeHook, _timeElapsed);

    _swapOnHook(feeHook, feePoolKey, bob, int256(_swapAmount), true, NO_TICK_LIMIT);

    vm.prank(alice);
    feeHook.collectFees(_positionId, alice, 0, 0);

    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);
    vm.prank(alice);
    feeHook.decreaseLiquidity(_positionId, -int128(uint128(_liquidity)), 0, 0);

    assertGe(token0.balanceOf(alice), _balance0Before, "LP should receive token0");
    assertGe(token1.balanceOf(alice), _balance1Before, "LP should receive token1");
  }

  function test_WithdrawIsAllowedAtMaturity() public {
    (FixedFeeSwapMarketHarness _localHook, PoolKey memory _localPoolKey,) =
      _deployHookForSolvency(0, "maturityWithdraw");

    _warpFromHookStart(_localHook, 1);
    bytes32 _positionId = _mintOnHook(_localHook, alice, 0, 500, 1e22);

    _warpFromHookStart(_localHook, MARKET_LENGTH / 2);
    _swapOnHook(_localHook, _localPoolKey, bob, int256(1e18), true, NO_TICK_LIMIT);

    vm.warp(_localHook.getMaturity());

    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);
    vm.prank(alice);
    _localHook.decreaseLiquidity(_positionId, -int128(uint128(1e22)), 0, 0);

    assertGe(token0.balanceOf(alice), _balance0Before, "LP should receive token0");
    assertGe(token1.balanceOf(alice), _balance1Before, "LP should receive token1");
  }
}

contract _BeforeSwap is FixedFeeSwapMarketTest {
  function setUp() public virtual override {
    super.setUp();

    // Create _a mock pool key - only the hooks field matters for _beforeSwap
    poolKey = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 0,
      tickSpacing: 1,
      hooks: IHooks(address(hook))
    });

    // Default swap params (ignored by our hook, but required)
    defaultSwapParams = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

    // Add _liquidity for swap tests and move _tick to 100 so below-range positions are possible
    _moveTickTo(100);
    // Main _liquidity spanning _a wide range
    _mintLiquidityAtTicks(alice, 0, 2000, 1e22);
  }

  // ============ Token Transfer Tests ============

  /// @dev Principal for cash: _user sends TOKEN0, receives TOKEN1
  function testFuzz_PrincipalForCashSwapTransfersCorrectTokens(uint256 _amountIn) public {
    _amountIn = _boundSwapAmount(_amountIn);

    uint256 _balance0Before = token0.balanceOf(bob);
    uint256 _balance1Before = token1.balanceOf(bob);
    uint256 _hookBalance0Before = token0.balanceOf(address(hook));
    uint256 _hookBalance1Before = token1.balanceOf(address(hook));

    _swap(bob, int256(_amountIn), true, NO_TICK_LIMIT);

    // Sub-_tick swaps may produce zero output; skip those runs
    uint256 _consumed = _balance0Before - token0.balanceOf(bob);
    vm.assume(_consumed > 0);

    uint256 _received = token1.balanceOf(bob) - _balance1Before;
    uint256 _hookGained0 = token0.balanceOf(address(hook)) - _hookBalance0Before;
    uint256 _hookLost1 = _hookBalance1Before - token1.balanceOf(address(hook));

    // User sends token0, receives token1
    assertGt(_received, 0, "User should receive TOKEN1");
    assertLe(_consumed, _amountIn, "Consumed should not exceed _amountIn");

    // Token conservation: what the _user sends is what the hook receives and vice versa
    assertEq(_consumed, _hookGained0, "Hook TOKEN0 gain should equal _user TOKEN0 spent");
    assertEq(_received, _hookLost1, "Hook TOKEN1 loss should equal _user TOKEN1 _received");
  }

  /// @dev Cash for principal: _user sends TOKEN1, receives TOKEN0
  function testFuzz_CashForPrincipalSwapTransfersCorrectTokens(uint256 _amountIn) public {
    _amountIn = _boundSwapAmount(_amountIn);

    uint256 _balance0Before = token0.balanceOf(bob);
    uint256 _balance1Before = token1.balanceOf(bob);
    uint256 _hookBalance0Before = token0.balanceOf(address(hook));
    uint256 _hookBalance1Before = token1.balanceOf(address(hook));

    _swap(bob, int256(_amountIn), false, NO_TICK_LIMIT);

    // Sub-_tick swaps may produce zero output; skip those runs
    uint256 _received = token0.balanceOf(bob) - _balance0Before;
    vm.assume(_received > 0);

    uint256 _consumed = _balance1Before - token1.balanceOf(bob);
    uint256 _hookGained1 = token1.balanceOf(address(hook)) - _hookBalance1Before;
    uint256 _hookLost0 = _hookBalance0Before - token0.balanceOf(address(hook));

    // User sends token1, receives token0
    assertGt(_consumed, 0, "User should send TOKEN1");
    assertLe(_consumed, _amountIn, "Consumed should not exceed _amountIn");

    // Token conservation: what the _user sends is what the hook receives and vice versa
    assertEq(_consumed, _hookGained1, "Hook TOKEN1 gain should equal _user TOKEN1 spent");
    assertEq(_received, _hookLost0, "Hook TOKEN0 loss should equal _user TOKEN0 _received");
  }

  /// @dev Zero-output swaps are no-ops: no balances change for _user or hook.
  function testFuzz_SmallAmountInCausesNoOpSwap(uint256 _amountIn, bool _principalForCash) public {
    _amountIn = _boundSwapAmount(_amountIn);

    uint256 _balance0Before = token0.balanceOf(bob);
    uint256 _balance1Before = token1.balanceOf(bob);
    uint256 _hookBalance0Before = token0.balanceOf(address(hook));
    uint256 _hookBalance1Before = token1.balanceOf(address(hook));

    _swap(bob, int256(_amountIn), _principalForCash, NO_TICK_LIMIT);

    uint256 _outputToken = _principalForCash
      ? token1.balanceOf(bob) - _balance1Before
      : token0.balanceOf(bob) - _balance0Before;
    vm.assume(_outputToken == 0);

    assertEq(token0.balanceOf(bob), _balance0Before, "User TOKEN0 should be unchanged");
    assertEq(token1.balanceOf(bob), _balance1Before, "User TOKEN1 should be unchanged");
    assertEq(
      token0.balanceOf(address(hook)), _hookBalance0Before, "Hook TOKEN0 should be unchanged"
    );
    assertEq(
      token1.balanceOf(address(hook)), _hookBalance1Before, "Hook TOKEN1 should be unchanged"
    );
  }

  // ============ State Update Tests ============

  function testFuzz_PrincipalForCashSwapIncreasesCurrentTick(uint256 _amountIn) public {
    _amountIn = _boundSwapAmount(_amountIn);

    int24 _tickBefore = hook.getCurrentTick();
    uint128 _activeLiq = hook.getActiveLiquidity();

    _swap(bob, int256(_amountIn), true, NO_TICK_LIMIT);

    int24 _tickAfter = hook.getCurrentTick();
    int24 _maxTickMove = _maxTickMove(_amountIn, _activeLiq);

    assertGe(_tickAfter, _tickBefore, "Tick should increase for principal->cash");
    assertLe(_tickAfter - _tickBefore, _maxTickMove, "Tick should not move more than _expected");
  }

  function testFuzz_CashForPrincipalSwapDecreasesCurrentTick(uint256 _amountIn) public {
    _amountIn = _boundSwapAmount(_amountIn);

    int24 _tickBefore = hook.getCurrentTick();
    uint128 _activeLiq = hook.getActiveLiquidity();

    _swap(bob, int256(_amountIn), false, NO_TICK_LIMIT);

    int24 _tickAfter = hook.getCurrentTick();
    int24 _maxTickMove = _maxTickMove(_amountIn, _activeLiq);

    assertLe(_tickAfter, _tickBefore, "Tick should decrease for cash->principal");
    assertLe(_tickBefore - _tickAfter, _maxTickMove, "Tick should not move more than _expected");
  }

  /// @dev Active _liquidity unchanged when not crossing _ticks
  function testFuzz_WithinTickSwapDoesNotUpdateActiveLiquidity(uint256 _amountIn) public {
    // Use small _amount to stay within current _tick range
    _amountIn = bound(_amountIn, 1e15, 1e17);

    uint128 _activeBefore = hook.getActiveLiquidity();

    _swap(bob, int256(_amountIn), true, NO_TICK_LIMIT);

    // If no _tick was crossed, active _liquidity should be unchanged
    // (This may not hold if the swap crosses _a _tick boundary)
    uint128 _activeAfter = hook.getActiveLiquidity();
    assertEq(_activeAfter, _activeBefore, "Active _liquidity unchanged within _tick");
  }

  // ============ Tick Crossing Tests ============

  function testFuzz_PrincipalForCashSwapCrossingLpUpperTickAndDecreasesActiveLiquidity(uint128 _narrowLiquidity)
    public
  {
    _narrowLiquidity = uint128(bound(uint256(_narrowLiquidity), 1e18, 1e22));
    int24 _currentTick = hook.getCurrentTick();
    int24 _narrowUpper = _currentTick + 10;
    _mintLiquidityAtTicks(alice, _currentTick - 10, _narrowUpper, _narrowLiquidity);

    uint128 _activeBefore = hook.getActiveLiquidity();
    int256 _priceBefore = hook.tickToPrice(_currentTick);

    (uint256 principalInToBoundary,, int256 boundaryPrice, int24 stepTick) =
      hook.exposed_getCashSwapAmount(int256(1e36), _priceBefore, _narrowUpper);

    _swap(bob, int256(principalInToBoundary), true, NO_TICK_LIMIT);

    assertEq(stepTick, _narrowUpper, "Should step to _upper _tick");
    assertEq(hook.getCurrentTick(), _narrowUpper, "Should land on the _upper _tick");
    assertEq(hook.getCurrentPrice(), boundaryPrice, "Price should move to boundary _price");
    assertEq(
      uint256(hook.getActiveLiquidity()),
      uint256(_activeBefore) - uint256(_narrowLiquidity),
      "Active _liquidity should decrease by narrow position's _liquidity"
    );
  }

  function testFuzz_PrincipalForCashSwapCrossingIntoLpPositionIncreasesActiveLiquidity(uint128 _aboveLiquidity)
    public
  {
    _aboveLiquidity = uint128(bound(uint256(_aboveLiquidity), 1e18, 1e22));
    int24 _currentTick = hook.getCurrentTick();
    int24 _aboveLower = _currentTick + 50;
    _mintLiquidityAtTicks(alice, _aboveLower, _currentTick + 150, _aboveLiquidity);

    uint128 _activeBefore = hook.getActiveLiquidity();
    int256 _priceBefore = hook.tickToPrice(_currentTick);

    (uint256 principalInToBoundary,, int256 boundaryPrice, int24 stepTick) =
      hook.exposed_getCashSwapAmount(int256(1e36), _priceBefore, _aboveLower);

    _swap(bob, int256(principalInToBoundary), true, NO_TICK_LIMIT);

    assertEq(stepTick, _aboveLower, "Should step to _lower _tick of above position");
    assertEq(hook.getCurrentTick(), _aboveLower, "Should land on the _lower _tick");
    assertEq(hook.getCurrentPrice(), boundaryPrice, "Price should move to boundary _price");
    assertEq(
      uint256(hook.getActiveLiquidity()),
      uint256(_activeBefore) + uint256(_aboveLiquidity),
      "Active _liquidity should increase by above position's _liquidity"
    );
  }

  function testFuzz_PrincipalForCashWithMultipleTickCrossings(
    uint128 _posLiquidity,
    uint128 _bgLiquidity
  ) public {
    _posLiquidity = uint128(bound(uint256(_posLiquidity), 1e18, 1e22));
    _bgLiquidity = uint128(bound(uint256(_bgLiquidity), 1e18, 1e22));
    int24 _currentTick = hook.getCurrentTick();

    // Add fuzzed background _liquidity spanning the full range
    _mintLiquidityAtTicks(alice, 0, 2000, _bgLiquidity);

    // Two adjacent positions: A at [current, current+100], B at [current+100, current+200]
    // A's _lower _tick == _currentTick so A is already in-range at mint _time
    _mintLiquidityAtTicks(alice, _currentTick, _currentTick + 100, _posLiquidity);
    _mintLiquidityAtTicks(alice, _currentTick + 100, _currentTick + 200, _posLiquidity);

    uint128 _activeBefore = hook.getActiveLiquidity();

    // Need > 200 _ticks; +1 for integer division truncation in this formula
    uint256 _swapAmount = uint256(_activeBefore) * 201 / BIPS;
    _swap(bob, int256(_swapAmount), true, NO_TICK_LIMIT);

    int24 _tickAfter = hook.getCurrentTick();
    assertGe(_tickAfter, _currentTick + 200, "Should cross both _upper _ticks");
    // Crossing _currentTick+100: _upper of A (-posLiq), _lower of B (+posLiq) → net 0
    // Crossing _currentTick+200: _upper of B (-posLiq) → net -posLiq
    // Total change from _activeBefore: -_posLiquidity
    assertEq(
      uint256(hook.getActiveLiquidity()),
      uint256(_activeBefore) - uint256(_posLiquidity),
      "Active _liquidity should decrease by one position's _liquidity"
    );
  }

  function testFuzz_CrossingUninitializedBoundaryDoesNotChangeActiveLiquidity(uint128 _extraLiquidity)
    public
  {
    _extraLiquidity = uint128(bound(uint256(_extraLiquidity), 1e18, 1e22));
    _mintLiquidityAtTicks(alice, 0, 2000, _extraLiquidity);

    uint128 _activeBefore = hook.getActiveLiquidity();
    int24 _tickBefore = hook.getCurrentTick();
    int256 _priceBefore = hook.tickToPrice(_tickBefore);

    // Pick the next uninitialized word boundary above current _tick
    int24 _nextTick = int24((int256(_tickBefore) / 256 + 1) * 256 - 1);
    (uint256 principalInToBoundary,, int256 boundaryPrice, int24 stepTick) =
      hook.exposed_getCashSwapAmount(int256(1e36), _priceBefore, _nextTick);

    _swap(bob, int256(principalInToBoundary), true, NO_TICK_LIMIT);

    assertEq(stepTick, _nextTick, "Should step to the word boundary _tick");
    assertEq(hook.getCurrentTick(), _nextTick, "Should land on the boundary _tick");
    assertEq(hook.getCurrentPrice(), boundaryPrice, "Price should move to the boundary _price");
    assertEq(hook.getActiveLiquidity(), _activeBefore, "Active _liquidity should be unchanged");
  }

  function testFuzz_CashForPrincipalSwapCrossingLpUpperTickIncreasesActiveLiquidity(uint128 _belowRangeLiquidity)
    public
  {
    _belowRangeLiquidity = uint128(bound(uint256(_belowRangeLiquidity), 1e18, 1e22));
    int24 _currentTick = hook.getCurrentTick();
    int24 _belowLower = _currentTick - 20;
    int24 _belowUpper = _currentTick - 10;
    _mintLiquidityAtTicks(alice, _belowLower, _belowUpper, _belowRangeLiquidity);

    uint128 _activeBefore = hook.getActiveLiquidity();
    int256 _priceBefore = hook.tickToPrice(_currentTick);

    (uint256 cashInToBoundary,, int256 boundaryPrice, int24 stepTick) =
      hook.exposed_getPrincipalSwapAmount(int256(1e36), _priceBefore, _belowUpper);

    uint256 _balance1Before = token1.balanceOf(bob);
    _swap(bob, int256(cashInToBoundary), false, NO_TICK_LIMIT);

    assertEq(stepTick, _belowUpper, "Should step to _upper _tick");
    assertEq(
      _balance1Before - token1.balanceOf(bob), cashInToBoundary, "Should consume cash to boundary"
    );
    assertEq(hook.getCurrentPrice(), boundaryPrice, "Price should move to boundary _price");
    assertEq(hook.getCurrentTick(), _belowUpper, "Moving left leaves _tick at boundary");
    assertEq(
      uint256(hook.getActiveLiquidity()),
      uint256(_activeBefore) + uint256(_belowRangeLiquidity),
      "Active _liquidity should increase"
    );
  }

  function testFuzz_CashForPrincipalSwapCrossingLpLowerTickDecreasesActiveLiquidity(uint128 _narrowLiquidity)
    public
  {
    _narrowLiquidity = uint128(bound(uint256(_narrowLiquidity), 1e18, 1e22));
    int24 _currentTick = hook.getCurrentTick();
    int24 _narrowLower = _currentTick - 10;
    int24 _narrowUpper = _currentTick + 10;
    _mintLiquidityAtTicks(alice, _narrowLower, _narrowUpper, _narrowLiquidity);

    uint128 _activeBefore = hook.getActiveLiquidity();
    int256 _priceBefore = hook.tickToPrice(_currentTick);

    (uint256 cashInToBoundary,, int256 boundaryPrice, int24 stepTick) =
      hook.exposed_getPrincipalSwapAmount(int256(1e36), _priceBefore, _narrowLower);

    uint256 _balance1Before = token1.balanceOf(bob);
    _swap(bob, int256(cashInToBoundary), false, NO_TICK_LIMIT);

    assertEq(stepTick, _narrowLower, "Should step to _lower _tick");
    assertEq(
      _balance1Before - token1.balanceOf(bob), cashInToBoundary, "Should consume cash to boundary"
    );
    assertEq(hook.getCurrentPrice(), boundaryPrice, "Price should move to boundary _price");
    assertEq(hook.getCurrentTick(), _narrowLower, "Moving left leaves _tick at boundary");
    assertEq(
      uint256(hook.getActiveLiquidity()),
      uint256(_activeBefore) - uint256(_narrowLiquidity),
      "Active _liquidity should decrease"
    );
  }

  // ============ Tick Limit Tests ============

  function testFuzz_PrincipalForCashSwapHitsTickLimitAndStopsEarly(
    uint256 _amountIn,
    uint24 _tickOffset
  ) public {
    _tickOffset = uint24(bound(_tickOffset, 5, 95));
    int24 _currentTick = hook.getCurrentTick();
    int24 _limitTick = _currentTick + int24(_tickOffset);

    uint256 _minAmount = _minInputForTicks(_tickOffset + 10);
    _amountIn = bound(_amountIn, _minAmount, _minAmount * 5);

    uint256 _balance0Before = token0.balanceOf(bob);
    uint256 _balance1Before = token1.balanceOf(bob);
    uint256 _hookBalance0Before = token0.balanceOf(address(hook));
    uint256 _hookBalance1Before = token1.balanceOf(address(hook));

    _swap(bob, int256(_amountIn), true, _limitTick);

    uint256 _consumed = _balance0Before - token0.balanceOf(bob);
    uint256 _received = token1.balanceOf(bob) - _balance1Before;
    uint256 _hookGained0 = token0.balanceOf(address(hook)) - _hookBalance0Before;
    uint256 _hookLost1 = _hookBalance1Before - token1.balanceOf(address(hook));

    assertLt(_consumed, _amountIn, "Should stop early due to _tick limit");
    assertEq(hook.getCurrentTick(), _limitTick, "Tick should stop exactly at limit");
    assertEq(_consumed, _hookGained0, "Hook TOKEN0 gain should equal _user TOKEN0 spent");
    assertEq(_received, _hookLost1, "Hook TOKEN1 loss should equal _user TOKEN1 _received");
  }

  function testFuzz_CashForPrincipalSwapHitsTickLimitStopsEarly(
    uint256 _amountIn,
    uint24 _tickOffset
  ) public {
    _tickOffset = uint24(bound(_tickOffset, 5, 95));
    int24 _currentTick = hook.getCurrentTick();
    int24 _limitTick = _currentTick - int24(_tickOffset);

    uint256 _minAmount = _minInputForTicks(_tickOffset + 10);
    _amountIn = bound(_amountIn, _minAmount, _minAmount * 5);

    uint256 _balance0Before = token0.balanceOf(bob);
    uint256 _balance1Before = token1.balanceOf(bob);
    uint256 _hookBalance0Before = token0.balanceOf(address(hook));
    uint256 _hookBalance1Before = token1.balanceOf(address(hook));

    _swap(bob, int256(_amountIn), false, _limitTick);

    uint256 _consumed = _balance1Before - token1.balanceOf(bob);
    uint256 _received = token0.balanceOf(bob) - _balance0Before;
    uint256 _hookGained1 = token1.balanceOf(address(hook)) - _hookBalance1Before;
    uint256 _hookLost0 = _hookBalance0Before - token0.balanceOf(address(hook));

    assertLt(_consumed, _amountIn, "Should stop early due to _tick limit");
    assertEq(hook.getCurrentTick(), _limitTick, "Tick should stop exactly at limit");
    assertEq(_consumed, _hookGained1, "Hook TOKEN1 gain should equal _user TOKEN1 spent");
    assertEq(_received, _hookLost0, "Hook TOKEN0 loss should equal _user TOKEN0 _received");
  }

  function testFuzz_UsingTheCurrentTickAsTheLimitIsANoOp(uint256 _amountIn, bool _principalForCash)
    public
  {
    _amountIn = _boundSwapAmount(_amountIn);
    int24 _currentTick = hook.getCurrentTick();
    uint128 _activeBefore = hook.getActiveLiquidity();
    int256 _expectedPrice = hook.tickToPrice(_currentTick);

    uint256 _balance0Before = token0.balanceOf(bob);
    uint256 _balance1Before = token1.balanceOf(bob);
    uint256 _hookBalance0Before = token0.balanceOf(address(hook));
    uint256 _hookBalance1Before = token1.balanceOf(address(hook));

    (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
      _swap(bob, int256(_amountIn), _principalForCash, _currentTick);

    assertEq(selector, BaseHook.beforeSwap.selector, "Selector");
    assertEq(BeforeSwapDelta.unwrap(delta), 0, "Delta");
    assertEq(fee, 0, "Fee");

    assertEq(hook.getCurrentTick(), _currentTick, "Tick unchanged");
    assertEq(hook.getActiveLiquidity(), _activeBefore, "Liquidity unchanged");
    assertEq(hook.getCurrentPrice(), _expectedPrice, "Price initialized");

    assertEq(token0.balanceOf(bob), _balance0Before, "TOKEN0 unchanged");
    assertEq(token1.balanceOf(bob), _balance1Before, "TOKEN1 unchanged");
    assertEq(token0.balanceOf(address(hook)), _hookBalance0Before, "Hook TOKEN0 unchanged");
    assertEq(token1.balanceOf(address(hook)), _hookBalance1Before, "Hook TOKEN1 unchanged");
  }

  function testFuzz_PrincipalForCashSwapWithNoTickLimit(uint256 _amountIn) public {
    // 2 bips minimum covers exp/ln rounding. _moveTickTo(100) creates _a position from 0-600
    // (_activeLiq 2e22), and setUp adds another from 0-2000 (total 2e22 up to _tick 600, then
    // 1e22). Cap at 500 _ticks so input is _consumed before the _liquidity drop at _tick 600, since
    // _minInputForTicks assumes constant _liquidity.
    _amountIn = bound(_amountIn, _ptForOneBip() * 2, _minInputForTicks(500));

    uint256 _balanceBefore = token0.balanceOf(bob);
    _swap(bob, int256(_amountIn), true, NO_TICK_LIMIT);

    uint256 _consumed = _balanceBefore - token0.balanceOf(bob);
    assertLe(_consumed, _amountIn, "Full _amount should be _consumed with no _tick limit");
  }

  function testFuzz_CashForPrincipalSwapWithNoTickLimit(uint256 _amountIn) public {
    // 2 bips minimum covers exp/ln rounding. Cash→PT moves _tick down from 100; _liquidity ends
    // at
    // _tick 0 so cap at 95 _ticks to stay within range.
    _amountIn = bound(_amountIn, _ptForOneBip() * 2, _minInputForTicks(95));

    uint256 _balanceBefore = token1.balanceOf(bob);
    _swap(bob, int256(_amountIn), false, NO_TICK_LIMIT);

    uint256 _consumed = _balanceBefore - token1.balanceOf(bob);
    assertLe(_consumed, _amountIn, "Full _amount should be _consumed with no _tick limit");
  }

  // ============ Edge Case Tests ============

  function test_EmptyHookParamsIsNoOp() public {
    uint256 _balance0Before = token0.balanceOf(bob);
    uint256 _balance1Before = token1.balanceOf(bob);
    uint256 _hookBalance0Before = token0.balanceOf(address(hook));
    uint256 _hookBalance1Before = token1.balanceOf(address(hook));

    (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
      hook.exposed_beforeSwap(bob, poolKey, defaultSwapParams, "");

    // Should return the correct selector
    assertEq(selector, BaseHook.beforeSwap.selector, "Should return beforeSwap selector");

    // No tokens should be transferred
    assertEq(token0.balanceOf(bob), _balance0Before, "TOKEN0 unchanged");
    assertEq(token1.balanceOf(bob), _balance1Before, "TOKEN1 unchanged");
    assertEq(token0.balanceOf(address(hook)), _hookBalance0Before, "Hook TOKEN0 unchanged");
    assertEq(token1.balanceOf(address(hook)), _hookBalance1Before, "Hook TOKEN1 unchanged");
    assertEq(BeforeSwapDelta.unwrap(delta), 0, "Delta should be zero");
    assertEq(fee, 0, "Fee should be zero");
  }

  function testFuzz_PrincipalForCashSwapNearMaturity(uint256 _timeToMaturity) public {
    _timeToMaturity = bound(_timeToMaturity, 1, 1 days);
    vm.warp(hook.getMaturity() - _timeToMaturity);

    // Use at least 2 bips to ensure output with integer-_tick snapping and exp/ln rounding
    uint256 _swapAmount = _ptForOneBip() * 2;

    int24 _tickBefore = hook.getCurrentTick();
    uint256 _balance0Before = token0.balanceOf(bob);
    uint256 _balance1Before = token1.balanceOf(bob);
    uint256 _hookBalance0Before = token0.balanceOf(address(hook));
    uint256 _hookBalance1Before = token1.balanceOf(address(hook));

    _swap(bob, int256(_swapAmount), true, NO_TICK_LIMIT);

    uint256 _consumed = _balance0Before - token0.balanceOf(bob);
    uint256 _received = token1.balanceOf(bob) - _balance1Before;
    uint256 _hookGained0 = token0.balanceOf(address(hook)) - _hookBalance0Before;
    uint256 _hookLost1 = _hookBalance1Before - token1.balanceOf(address(hook));

    assertLe(_consumed, _swapAmount, "Consumed should not exceed input");
    assertGt(hook.getCurrentTick(), _tickBefore, "Tick should increase");
    assertEq(_consumed, _hookGained0, "Hook TOKEN0 gain should equal _user TOKEN0 spent");
    assertEq(_received, _hookLost1, "Hook TOKEN1 loss should equal _user TOKEN1 _received");
  }

  function testFuzz_CashForPrincipalSwapNearMaturity(uint256 _timeToMaturity) public {
    _timeToMaturity = bound(_timeToMaturity, 1, 1 days);
    vm.warp(hook.getMaturity() - _timeToMaturity);

    // Use at least 2 bips to ensure output with integer-_tick snapping and exp/ln rounding
    uint256 _swapAmount = _ptForOneBip() * 2;

    int24 _tickBefore = hook.getCurrentTick();
    uint256 _balance0Before = token0.balanceOf(bob);
    uint256 _balance1Before = token1.balanceOf(bob);
    uint256 _hookBalance0Before = token0.balanceOf(address(hook));
    uint256 _hookBalance1Before = token1.balanceOf(address(hook));

    _swap(bob, int256(_swapAmount), false, NO_TICK_LIMIT);

    uint256 _consumed = _balance1Before - token1.balanceOf(bob);
    uint256 _received = token0.balanceOf(bob) - _balance0Before;
    uint256 _hookGained1 = token1.balanceOf(address(hook)) - _hookBalance1Before;
    uint256 _hookLost0 = _hookBalance0Before - token0.balanceOf(address(hook));

    assertLe(_consumed, _swapAmount, "Consumed should not exceed input");
    assertLt(hook.getCurrentTick(), _tickBefore, "Tick should decrease");
    assertEq(_consumed, _hookGained1, "Hook TOKEN1 gain should equal _user TOKEN1 spent");
    assertEq(_received, _hookLost0, "Hook TOKEN0 loss should equal _user TOKEN0 _received");
  }

  function testFuzz_SequentialSwapsInTheSameDirection(uint256 _amount1, uint256 _amount2) public {
    // Use amounts large enough to always move at least 1 _tick (2 bips covers exp/ln rounding)
    _amount1 = bound(_amount1, _ptForOneBip() * 2, 100e18);
    _amount2 = bound(_amount2, _ptForOneBip() * 2, 100e18);

    int24 _tickBefore = hook.getCurrentTick();

    _swap(bob, int256(_amount1), true, NO_TICK_LIMIT);
    int24 _tickAfter1 = hook.getCurrentTick();

    _swap(bob, int256(_amount2), true, NO_TICK_LIMIT);
    int24 _tickAfter2 = hook.getCurrentTick();

    assertGt(_tickAfter1, _tickBefore, "First swap increases _tick");
    assertGt(_tickAfter2, _tickAfter1, "Second swap increases _tick further");
  }

  function testFuzz_SequentialSwapsInOppositeDirections(
    uint256 _amount1,
    uint256 _amount2,
    uint256 _timeElapsed
  ) public {
    _amount1 = bound(_amount1, 1e15, 1e18);
    _amount2 = bound(_amount2, 1e15, 1e18);
    _timeElapsed = bound(_timeElapsed, 1 days, MARKET_LENGTH - 1);
    _warpFromStart(_timeElapsed);

    int24 _tickBefore = hook.getCurrentTick();

    // Swap principal for cash (_tick increases)
    _swap(bob, int256(_amount1), true, NO_TICK_LIMIT);
    int24 _tickAfter1 = hook.getCurrentTick();

    // Swap cash for principal (_tick decreases)
    _swap(bob, int256(_amount2), false, NO_TICK_LIMIT);
    int24 _tickAfter2 = hook.getCurrentTick();

    // First swap increases, second decreases
    assertGe(_tickAfter1, _tickBefore, "First swap increases _tick");
    assertLe(_tickAfter2, _tickAfter1, "Second swap decreases _tick");
  }

  // ============ Revert Tests ============

  function testFuzz_RevertIf_HookParamsHaveAnIncorrectLength(uint256 _length) public {
    // Valid _hookParams is exactly 96 bytes (int256, bool, int24 encoded).
    // Length 0 is _a valid no-op (empty _hookParams), so exclude it.
    _length = bound(_length, 1, 256);
    vm.assume(_length != 96);

    bytes memory _wrongLength = new bytes(_length);

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_InvalidHookParams.selector);
    hook.exposed_beforeSwap(bob, poolKey, defaultSwapParams, _wrongLength);
  }

  function testFuzz_RevertIf_AmountInIsNotPositive(int256 _amountIn) public {
    _amountIn = bound(_amountIn, type(int256).min, 0);
    bytes memory _hookParams = _encodeHookParams(_amountIn, true, NO_TICK_LIMIT);

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_SwapAmountCannotBeZero.selector);
    hook.exposed_beforeSwap(bob, poolKey, defaultSwapParams, _hookParams);
  }

  function testFuzz_RevertIf_MarketHasExpired(uint256 _secondsAfterMaturity) public {
    _secondsAfterMaturity = bound(_secondsAfterMaturity, 0, 30 days);
    vm.warp(hook.getMaturity() + _secondsAfterMaturity);
    bytes memory _hookParams = _encodeHookParams(1e18, true, NO_TICK_LIMIT);

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_MarketExpired.selector);
    hook.exposed_beforeSwap(bob, poolKey, defaultSwapParams, _hookParams);
  }

  function test_RevertIf_NoActiveLiquidity() public {
    // Deploy fresh hook with no _liquidity
    address _mockManager = makeAddr("freshMockManager");
    FixedFeeSwapMarketHarness _freshHook = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH,
      address(token0),
      address(token1),
      FEE_RATE,
      YIELD_PER_TICK,
      IPoolManager(_mockManager),
      0
    );

    vm.warp(block.timestamp + 1 days);

    PoolKey memory _freshPoolKey = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 0,
      tickSpacing: 1,
      hooks: IHooks(address(_freshHook))
    });

    bytes memory _hookParams = _encodeHookParams(1e18, true, NO_TICK_LIMIT);

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_NoActiveLiquidity.selector);
    _freshHook.exposed_beforeSwap(bob, _freshPoolKey, defaultSwapParams, _hookParams);
  }

  function testFuzz_RevertIf_PrincipalForCashSwapExhaustsLiquidity(uint128 _liq) public {
    address _mockManager = makeAddr("freshMockManager2");
    FixedFeeSwapMarketHarness _freshHook = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH,
      address(token0),
      address(token1),
      FEE_RATE,
      YIELD_PER_TICK,
      IPoolManager(_mockManager),
      0
    );
    vm.warp(block.timestamp + 1 days);

    PoolKey memory _freshPoolKey = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 0,
      tickSpacing: 1,
      hooks: IHooks(address(_freshHook))
    });

    _liq = uint128(bound(uint256(_liq), 1e18, 1e22));
    vm.startPrank(alice);
    token0.approve(address(_freshHook), type(uint256).max);
    token1.approve(address(_freshHook), type(uint256).max);
    _freshHook.mintLiquidity(0, 20, _liq, type(uint256).max, type(uint256).max);
    vm.stopPrank();

    int256 _price = _freshHook.tickToPrice(_freshHook.getCurrentTick());
    (uint256 principalToBoundary,,,) =
      _freshHook.exposed_getCashSwapAmount(int256(1e36), _price, 20);

    bytes memory _hookParams =
      _encodeHookParams(int256(principalToBoundary + 1), true, NO_TICK_LIMIT);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_InvalidTickTraversal.selector);
    _freshHook.exposed_beforeSwap(bob, _freshPoolKey, defaultSwapParams, _hookParams);
  }

  function testFuzz_RevertIf_CashForPrincipalSwapExhaustsLiquidity(uint128 _liq) public {
    address _mockManager = makeAddr("freshMockManager3");
    FixedFeeSwapMarketHarness _freshHook = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH,
      address(token0),
      address(token1),
      FEE_RATE,
      YIELD_PER_TICK,
      IPoolManager(_mockManager),
      0
    );
    vm.warp(block.timestamp + 1 days);

    PoolKey memory _freshPoolKey = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 0,
      tickSpacing: 1,
      hooks: IHooks(address(_freshHook))
    });

    _liq = uint128(bound(uint256(_liq), 1e18, 1e22));
    vm.startPrank(alice);
    token0.approve(address(_freshHook), type(uint256).max);
    token1.approve(address(_freshHook), type(uint256).max);
    _freshHook.mintLiquidity(0, 20, _liq, type(uint256).max, type(uint256).max);
    vm.stopPrank();

    vm.startPrank(bob);
    token0.approve(address(_freshHook), type(uint256).max);
    token1.approve(address(_freshHook), type(uint256).max);
    vm.stopPrank();

    // Push _tick to middle of range so cash->principal has room to move left
    int256 _price = _freshHook.tickToPrice(_freshHook.getCurrentTick());
    bytes memory _pushParams = abi.encode(int256(1e36), true, int24(10));
    _freshHook.exposed_beforeSwap(bob, _freshPoolKey, defaultSwapParams, _pushParams);

    // Now try to exhaust all _liquidity going cash->principal past _lower _tick
    _price = _freshHook.tickToPrice(_freshHook.getCurrentTick());
    (uint256 cashInToBoundary,,,) =
      _freshHook.exposed_getPrincipalSwapAmount(int256(1e36), _price, 0);

    bytes memory _hookParams = _encodeHookParams(int256(cashInToBoundary + 1), false, NO_TICK_LIMIT);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_InvalidTickTraversal.selector);
    _freshHook.exposed_beforeSwap(bob, _freshPoolKey, defaultSwapParams, _hookParams);
  }

  function testFuzz_RevertIf_InsufficientInputTokenAllowance(
    uint256 _amountIn,
    bool _principalForCash
  ) public {
    // Use amounts large enough to always move _a _tick (2 bips covers exp/ln rounding)
    _amountIn = bound(_amountIn, _ptForOneBip() * 2, 100e18);

    vm.prank(bob);
    if (_principalForCash) token0.approve(address(hook), 0);
    else token1.approve(address(hook), 0);

    bytes memory _hookParams =
      _encodeHookParams(int256(_amountIn), _principalForCash, NO_TICK_LIMIT);

    vm.expectRevert(stdError.arithmeticError);
    hook.exposed_beforeSwap(bob, poolKey, defaultSwapParams, _hookParams);
  }

  function testFuzz_ReverIf_InsufficientBalance(uint256 _amountIn, bool _principalForCash) public {
    // Use amounts large enough to always move at least 1 _tick (2 bips covers exp/ln rounding)
    _amountIn = bound(_amountIn, _ptForOneBip() * 2, 100e18);

    address _poorUser = makeAddr("_poorUser");

    // Approve but no balance
    vm.startPrank(_poorUser);
    token0.approve(address(hook), type(uint256).max);
    token1.approve(address(hook), type(uint256).max);
    vm.stopPrank();

    bytes memory _hookParams =
      _encodeHookParams(int256(_amountIn), _principalForCash, NO_TICK_LIMIT);

    vm.expectRevert(stdError.arithmeticError);
    hook.exposed_beforeSwap(_poorUser, poolKey, defaultSwapParams, _hookParams);
  }

  // ============ Swap Event Tests ============

  function testFuzz_PrincipalForCashSwapEmitsSwapEvent(uint256 _amountIn) public {
    _amountIn = _boundSwapAmount(_amountIn);

    vm.expectEmit(true, false, false, false, address(hook));
    emit FixedFeeSwapMarket.Swap(bob, true, 0, 0);
    _swap(bob, int256(_amountIn), true, NO_TICK_LIMIT);
  }

  function testFuzz_CashForPrincipalSwapEmitsSwap(uint256 _amountIn) public {
    _amountIn = _boundSwapAmount(_amountIn);

    vm.expectEmit(true, false, false, false, address(hook));
    emit FixedFeeSwapMarket.Swap(bob, false, 0, 0);
    _swap(bob, int256(_amountIn), false, NO_TICK_LIMIT);
  }

  // ============ LP Fee Tests ============

  function testFuzz_FeeRateIsSetAndInitialFeeGrowthIsZero(uint24 _feeRate) public {
    _feeRate = uint24(bound(uint256(_feeRate), 0, 999_999));
    (FixedFeeSwapMarketHarness feeHook,) =
      _deployHookForBeforeSwapTests(_feeRate, "feeRateHookManager");

    assertEq(feeHook.FEE_RATE(), _feeRate);
    assertEq(feeHook.feeGrowthGlobal0X128(), 0);
    assertEq(feeHook.feeGrowthGlobal1X128(), 0);
  }

  function testFuzz_PrincipalForCashSwapAccumulatesToken0FeeGrowth(uint256 _amountIn) public {
    uint128 _liquidity = 1e23;
    _amountIn = bound(_amountIn, 2e19, 2e21);
    (FixedFeeSwapMarketHarness feeHook, PoolKey memory feePoolKey) =
      _deployHookForBeforeSwapTests(LP_FEE_RATE, "feeGrowth0Manager");
    _mintOnHook(feeHook, alice, 0, 200, _liquidity);

    uint256 _balance0Before = token0.balanceOf(bob);
    _swapOnHook(feeHook, feePoolKey, bob, int256(_amountIn), true, NO_TICK_LIMIT);
    uint256 _consumed = _balance0Before - token0.balanceOf(bob);

    // Per-step rounding (mulDivUp for fee, mulDiv for growth) introduces error bounded by
    // ~(Q128 / _liquidity + 1) per _tick crossed. Use _maxTickMove as an _upper bound on _tick
    // count.
    uint256 _expected = _expectedFeeGrowth(_consumed, _liquidity);
    uint256 _feeGrowth0 = feeHook.feeGrowthGlobal0X128();

    assertApproxEqAbs(
      _feeGrowth0,
      _expected,
      _feeGrowthRoundingTolerance(_amountIn, _liquidity),
      "Fee growth should match _expected"
    );
  }

  function testFuzz_SwapWithFeesDoesNotIncreaseOutputComparedToNoFee(uint256 _amountIn) public {
    uint128 _liquidity = 1e23;
    _amountIn = bound(_amountIn, 2e19, 2e21);

    (FixedFeeSwapMarketHarness feeHook, PoolKey memory feePoolKey) =
      _deployHookForBeforeSwapTests(LP_FEE_RATE, "feeOutputManager");
    (FixedFeeSwapMarketHarness noFeeHook, PoolKey memory noFeePoolKey) =
      _deployHookForBeforeSwapTests(0, "noFeeOutputManager");

    _mintOnHook(feeHook, alice, 0, 200, _liquidity);
    _mintOnHook(noFeeHook, alice, 0, 200, _liquidity);

    uint256 _feeGrowth0Before = feeHook.feeGrowthGlobal0X128();
    (uint256 inputWithFee, uint256 outputWithFee) =
      _measurePrincipalForCashSwap(feeHook, feePoolKey, _amountIn);
    uint256 _feeGrowth0After = feeHook.feeGrowthGlobal0X128();

    token0.mint(bob, inputWithFee);

    (uint256 inputNoFee, uint256 outputNoFee) =
      _measurePrincipalForCashSwap(noFeeHook, noFeePoolKey, _amountIn);

    assertLe(outputWithFee, outputNoFee, "Output should not increase with fees");
    assertApproxEqAbs(inputWithFee, inputNoFee, 1, "Consumed input should match within 1 wei");
    assertLe(inputWithFee, _amountIn, "Consumed input should never exceed _amountIn");
    assertGt(
      _feeGrowth0After, _feeGrowth0Before, "Fee growth should increase when fees are enabled"
    );
  }

  function testFuzz_CollectFeesAfterPrincipalForCashSwaps(uint8 _swapCount, uint256 _amountIn)
    public
  {
    _swapCount = uint8(bound(uint256(_swapCount), 1, 10));
    _amountIn = bound(_amountIn, 1e17, 2e17);

    (FixedFeeSwapMarketHarness feeHook, PoolKey memory feePoolKey) =
      _deployHookForBeforeSwapTests(LP_FEE_RATE, "collectFeeManager");
    bytes32 _positionId = _mintOnHook(feeHook, alice, 0, 300, 1e20);

    for (uint256 _i = 0; _i < _swapCount; _i++) {
      _swapOnHook(feeHook, feePoolKey, bob, int256(_amountIn), true, NO_TICK_LIMIT);
    }

    uint256 _aliceToken0Before = token0.balanceOf(alice);
    vm.prank(alice);
    (uint128 collected0, uint128 collected1) = feeHook.collectFees(_positionId, alice, 0, 0);
    uint256 _aliceToken0After = token0.balanceOf(alice);

    assertGt(collected0, 0, "Should collect TOKEN0 fees");
    assertEq(collected1, 0, "Should not collect TOKEN1 fees from one-way swaps");
    assertEq(
      _aliceToken0After - _aliceToken0Before, collected0, "Balance increase should match fees"
    );
  }

  function testFuzz_FeeCollectionScalesWithLiquidityShare(uint8 _swapCount, uint256 _amountIn)
    public
  {
    _swapCount = uint8(bound(uint256(_swapCount), 2, 20));
    _amountIn = bound(_amountIn, 5e16, 2e17);

    (FixedFeeSwapMarketHarness feeHook, PoolKey memory feePoolKey) =
      _deployHookForBeforeSwapTests(LP_FEE_RATE, "feeSplitManager");

    bytes32 _alicePositionId = _mintOnHook(feeHook, alice, 0, 300, 2e20);
    bytes32 _bobPositionId = _mintOnHook(feeHook, bob, 0, 300, 1e20);

    address _carol = makeAddr("feeSplitCarol");
    _fundUser(_carol);
    vm.startPrank(_carol);
    token0.approve(address(feeHook), type(uint256).max);
    token1.approve(address(feeHook), type(uint256).max);
    vm.stopPrank();

    for (uint256 _i = 0; _i < _swapCount; _i++) {
      _swapOnHook(feeHook, feePoolKey, _carol, int256(_amountIn), true, NO_TICK_LIMIT);
    }

    vm.prank(alice);
    (uint128 aliceFees0,) = feeHook.collectFees(_alicePositionId, alice, 0, 0);
    vm.prank(bob);
    (uint128 bobFees0,) = feeHook.collectFees(_bobPositionId, bob, 0, 0);

    vm.assume(bobFees0 > 0);
    uint256 _expectedAliceFees = uint256(bobFees0) * 2;
    uint256 _tolerance = _expectedAliceFees / 20 + 1;
    assertApproxEqAbs(aliceFees0, _expectedAliceFees, _tolerance, "Alice should collect ~2x Bob");
  }

  function testFuzz_OutOfRangeLiquidityDoesNotEarnFees(uint8 _swapCount, uint256 _amountIn) public {
    _swapCount = uint8(bound(uint256(_swapCount), 1, 10));
    _amountIn = bound(_amountIn, 5e16, 1e17);

    (FixedFeeSwapMarketHarness feeHook, PoolKey memory feePoolKey) =
      _deployHookForBeforeSwapTests(LP_FEE_RATE, "outOfRangeFeeManager");

    bytes32 _alicePositionId = _mintOnHook(feeHook, alice, 0, 300, 1e20);
    bytes32 _bobPositionId = _mintOnHook(feeHook, bob, 500, 600, 1e20);

    address _carol = makeAddr("outOfRangeCarol");
    _fundUser(_carol);
    vm.startPrank(_carol);
    token0.approve(address(feeHook), type(uint256).max);
    token1.approve(address(feeHook), type(uint256).max);
    vm.stopPrank();

    for (uint256 _i = 0; _i < _swapCount; _i++) {
      _swapOnHook(feeHook, feePoolKey, _carol, int256(_amountIn), true, NO_TICK_LIMIT);
    }

    vm.prank(alice);
    (uint128 aliceFees0,) = feeHook.collectFees(_alicePositionId, alice, 0, 0);
    vm.prank(bob);
    (uint128 bobFees0,) = feeHook.collectFees(_bobPositionId, bob, 0, 0);

    assertGt(aliceFees0, 0, "In-range LP should collect fees");
    assertEq(bobFees0, 0, "Out-of-range LP should not collect fees");
  }

  function testFuzz_IncreaseLiquidityDoesNotLoseAccruedFees(
    uint256 _amountIn,
    uint128 _additionalLiquidity
  ) public {
    _amountIn = bound(_amountIn, 1e17, 5e17);
    _additionalLiquidity = uint128(bound(uint256(_additionalLiquidity), 1e18, 1e20));

    (FixedFeeSwapMarketHarness feeHook, PoolKey memory feePoolKey) =
      _deployHookForBeforeSwapTests(LP_FEE_RATE, "increaseFeeManager");
    bytes32 _positionId = _mintOnHook(feeHook, alice, 0, 200, 1e20);

    _swapOnHook(feeHook, feePoolKey, bob, int256(_amountIn), true, NO_TICK_LIMIT);

    (,,, int128 liquidityBefore) = feeHook.getPositionInfo(_positionId);
    vm.prank(alice);
    feeHook.increaseLiquidity(
      _positionId, _additionalLiquidity, type(uint256).max, type(uint256).max
    );
    (,,, int128 liquidityAfter) = feeHook.getPositionInfo(_positionId);

    vm.prank(alice);
    (uint128 collected0,) = feeHook.collectFees(_positionId, alice, 0, 0);

    assertEq(
      liquidityAfter,
      liquidityBefore + int128(_additionalLiquidity),
      "Liquidity should increase by delta"
    );
    assertGt(collected0, 0, "Accrued fees should remain collectible after increase");
  }

  function testFuzz_ReAddingLiquidityDoesNotBackfillPastFees(uint8 _swapCount, uint256 _amountIn)
    public
  {
    _swapCount = uint8(bound(uint256(_swapCount), 1, 8));
    _amountIn = bound(_amountIn, 1e17, 2e17);

    (FixedFeeSwapMarketHarness feeHook, PoolKey memory feePoolKey) =
      _deployHookForBeforeSwapTests(LP_FEE_RATE, "reAddFeeManager");
    _mintOnHook(feeHook, bob, 0, 300, 2e20);
    bytes32 _alicePositionId = _mintOnHook(feeHook, alice, 0, 300, 1e20);

    _swapOnHook(feeHook, feePoolKey, bob, int256(_amountIn), true, NO_TICK_LIMIT);

    (,,, int128 liquidityBefore) = feeHook.getPositionInfo(_alicePositionId);
    vm.prank(alice);
    feeHook.decreaseLiquidity(_alicePositionId, -liquidityBefore, 0, 0);

    vm.prank(alice);
    feeHook.collectFees(_alicePositionId, alice, 0, 0);

    for (uint256 _i = 0; _i < _swapCount; _i++) {
      _swapOnHook(feeHook, feePoolKey, bob, int256(_amountIn), true, NO_TICK_LIMIT);
    }

    vm.prank(alice);
    feeHook.increaseLiquidity(_alicePositionId, 1e20, type(uint256).max, type(uint256).max);
    vm.prank(alice);
    (uint128 fees0, uint128 fees1) = feeHook.collectFees(_alicePositionId, alice, 0, 0);

    assertEq(fees0, 0, "Re-added _liquidity should not backfill TOKEN0 fees");
    assertEq(fees1, 0, "Re-added _liquidity should not backfill TOKEN1 fees");
  }

  function testFuzz_RevertIf_NonOwnerCollectsFees(address _caller) public {
    vm.assume(_caller != alice && _caller != address(0));
    (FixedFeeSwapMarketHarness feeHook,) =
      _deployHookForBeforeSwapTests(LP_FEE_RATE, "notOwnerCollectManager");
    bytes32 _positionId = _mintOnHook(feeHook, alice, 0, 200, 1e20);

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_NotPositionOwner.selector);
    vm.prank(_caller);
    feeHook.collectFees(_positionId, _caller, 0, 0);
  }
}

contract _BeforeAddLiquidity is FixedFeeSwapMarketTest {
  function test_RevertWhen_CalledDirectly() public {
    PoolKey memory _poolKey = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 0,
      tickSpacing: 1,
      hooks: IHooks(address(hook))
    });
    ModifyLiquidityParams memory _params =
      ModifyLiquidityParams({tickLower: 0, tickUpper: 100, liquidityDelta: 1e18, salt: bytes32(0)});

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_LiquidityOnlyViaHook.selector);
    hook.exposed_beforeAddLiquidity(alice, _poolKey, _params, "");
  }
}

contract _BeforeRemoveLiquidity is FixedFeeSwapMarketTest {
  function test_RevertWhen_CalledDirectly() public {
    PoolKey memory _poolKey = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 0,
      tickSpacing: 1,
      hooks: IHooks(address(hook))
    });
    ModifyLiquidityParams memory _params = ModifyLiquidityParams({
      tickLower: 0, tickUpper: 100, liquidityDelta: -1e18, salt: bytes32(0)
    });

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_LiquidityOnlyViaHook.selector);
    hook.exposed_beforeRemoveLiquidity(alice, _poolKey, _params, "");
  }
}

contract CollectFees is FixedFeeSwapMarketTest {
  FixedFeeSwapMarketHarness public feeHook;
  PoolKey internal feePoolKey;

  function setUp() public override {
    super.setUp();
    vm.warp(1);
    address _mockManager = makeAddr("collectFeesMockManager");
    feeHook = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH,
      address(token0),
      address(token1),
      LP_FEE_RATE,
      YIELD_PER_TICK,
      IPoolManager(_mockManager),
      0
    );
    vm.warp(block.timestamp + 1 days);
    feePoolKey = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 0,
      tickSpacing: 1,
      hooks: IHooks(address(feeHook))
    });
    defaultSwapParams = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
    vm.startPrank(alice);
    token0.approve(address(feeHook), type(uint256).max);
    token1.approve(address(feeHook), type(uint256).max);
    vm.stopPrank();
    vm.startPrank(bob);
    token0.approve(address(feeHook), type(uint256).max);
    token1.approve(address(feeHook), type(uint256).max);
    vm.stopPrank();
  }

  function _feeSwap(address _sender, int256 _amountIn, bool _principalForCash) internal {
    bytes memory _hookParams = abi.encode(_amountIn, _principalForCash, int24(type(int24).max));
    feeHook.exposed_beforeSwap(_sender, feePoolKey, defaultSwapParams, _hookParams);
  }

  function testFuzz_PartialFeeCollection(uint128 _liquidity, uint256 _swapAmount) public {
    _liquidity = _boundLiquidity(_liquidity);
    // 3 same-direction swaps, cap each at 90 bips so total stays within 300-_tick range
    uint256 _minSwap = uint256(_liquidity) * 2 / BIPS;
    uint256 _maxSwap = uint256(_liquidity) * 90 / BIPS;
    _swapAmount = bound(_swapAmount, _minSwap, _maxSwap);

    vm.prank(alice);
    feeHook.mintLiquidity(0, 300, _liquidity, type(uint256).max, type(uint256).max);
    bytes32 _positionId = keccak256(abi.encodePacked(int24(300), int24(0), alice));

    _feeSwap(bob, int256(_swapAmount), true);

    // Collect all
    vm.prank(alice);
    (uint128 _collected0,) = feeHook.collectFees(_positionId, alice, 0, 0);
    assertGt(_collected0, 0, "Should have fees to collect");

    // Generate more fees and collect all
    _feeSwap(bob, int256(_swapAmount), true);
    vm.prank(alice);
    feeHook.collectFees(_positionId, alice, 0, 0);
    // Generate fees again since we just collected all
    _feeSwap(bob, int256(_swapAmount), true);

    // Now request only 1 wei
    vm.prank(alice);
    (uint128 _partial0,) = feeHook.collectFees(_positionId, alice, 1, 0);
    assertEq(_partial0, 1, "Should collect exactly requested _amount");

    // Remainder still available
    vm.prank(alice);
    (uint128 _remainder0,) = feeHook.collectFees(_positionId, alice, 0, 0);
    assertGt(_remainder0, 0, "Should still have _remaining fees");
  }

  function testFuzz_AlreadyCollectedFeesCannotCollectMore(uint128 _liquidity, uint256 _swapAmount)
    public
  {
    _liquidity = _boundLiquidity(_liquidity);
    _swapAmount = _boundFeeSwapAmount(_swapAmount, _liquidity);

    vm.prank(alice);
    feeHook.mintLiquidity(0, 300, _liquidity, type(uint256).max, type(uint256).max);
    bytes32 _positionId = keccak256(abi.encodePacked(int24(300), int24(0), alice));

    _feeSwap(bob, int256(_swapAmount), true);

    vm.prank(alice);
    feeHook.collectFees(_positionId, alice, 0, 0);

    vm.prank(alice);
    (uint128 _collected0, uint128 _collected1) = feeHook.collectFees(_positionId, alice, 0, 0);
    assertEq(_collected0, 0, "Second collect should yield zero TOKEN0");
    assertEq(_collected1, 0, "Second collect should yield zero TOKEN1");
  }

  function testFuzz_FeesSentToDifferentRecipient(
    uint128 _liquidity,
    uint256 _swapAmount,
    address _recipient
  ) public {
    _liquidity = _boundLiquidity(_liquidity);
    _swapAmount = _boundFeeSwapAmount(_swapAmount, _liquidity);
    vm.assume(_recipient != address(0) && _recipient != address(feeHook));

    vm.prank(alice);
    feeHook.mintLiquidity(0, 300, _liquidity, type(uint256).max, type(uint256).max);
    bytes32 _positionId = keccak256(abi.encodePacked(int24(300), int24(0), alice));

    _feeSwap(bob, int256(_swapAmount), true);

    uint256 _recipientToken0Before = token0.balanceOf(_recipient);
    vm.prank(alice);
    (uint128 _collected0,) = feeHook.collectFees(_positionId, _recipient, 0, 0);
    assertGt(_collected0, 0, "Should collect fees");
    assertEq(
      token0.balanceOf(_recipient) - _recipientToken0Before,
      _collected0,
      "Recipient should receive the fees"
    );
  }

  function testFuzz_SwapInBothDirectionsCollectsBothTokenFees(
    uint128 _liquidity,
    uint256 _pushAmount,
    uint256 _reverseAmount
  ) public {
    _liquidity = _boundLiquidity(_liquidity);
    // Push: 4-200 bips of _liquidity
    uint256 _minPush = uint256(_liquidity) * 4 / BIPS;
    uint256 _maxPush = uint256(_liquidity) * 200 / BIPS;
    _pushAmount = bound(_pushAmount, _minPush, _maxPush);
    // Reverse: 2 bips to half of push
    uint256 _minReverse = uint256(_liquidity) * 2 / BIPS;
    uint256 _maxReverse = _pushAmount / 2;
    vm.assume(_maxReverse >= _minReverse);
    _reverseAmount = bound(_reverseAmount, _minReverse, _maxReverse);

    vm.prank(alice);
    feeHook.mintLiquidity(0, 300, _liquidity, type(uint256).max, type(uint256).max);
    bytes32 _positionId = keccak256(abi.encodePacked(int24(300), int24(0), alice));

    // PT→Cash — push _tick up to create room for cash→PT
    _feeSwap(bob, int256(_pushAmount), true);
    // Cash→PT (smaller than push to stay in range)
    _feeSwap(bob, int256(_reverseAmount), false);

    assertGt(feeHook.feeGrowthGlobal1X128(), 0, "feeGrowthGlobal1X128 should be > 0");

    vm.prank(alice);
    (uint128 _collected0, uint128 _collected1) = feeHook.collectFees(_positionId, alice, 0, 0);
    assertGt(_collected0, 0, "Should have collected TOKEN0 fees");
    assertGt(_collected1, 0, "Should have collected TOKEN1 fees");
  }

  function testFuzz_EmitsFeesCollected(uint128 _liquidity, uint256 _swapAmount) public {
    _liquidity = _boundLiquidity(_liquidity);
    _swapAmount = _boundFeeSwapAmount(_swapAmount, _liquidity);

    vm.prank(alice);
    feeHook.mintLiquidity(0, 300, _liquidity, type(uint256).max, type(uint256).max);
    bytes32 _positionId = keccak256(abi.encodePacked(int24(300), int24(0), alice));

    _feeSwap(bob, int256(_swapAmount), true);

    vm.expectEmit(true, true, false, false, address(feeHook));
    emit FixedFeeSwapMarket.FeesCollected(_positionId, alice, 0, 0);

    vm.prank(alice);
    feeHook.collectFees(_positionId, alice, 0, 0);
  }
}

// ============================================================================
// Liquidity Gap Tests - Swaps across ranges with zero _liquidity gaps
// ============================================================================

contract LiquidityGap is FixedFeeSwapMarketTest {
  function setUp() public override {
    super.setUp();
    poolKey = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 0,
      tickSpacing: 1,
      hooks: IHooks(address(hook))
    });
    defaultSwapParams = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
  }

  /// @dev Swap PT->Cash across contiguous positions: A at [0, 100], B at [100, 300]
  function testFuzz_SwapAcrossContiguousPositions_PrincipalForCash(uint128 _liqA, uint128 _liqB)
    public
  {
    _liqA = _boundLiquidity(_liqA);
    _liqB = _boundLiquidity(_liqB);
    _warpFromStart(1);

    // Position A: [0, 100], Position B: [100, 300] (contiguous, B is wider)
    _mintLiquidityAtTicks(alice, 0, 100, _liqA);
    _mintLiquidityAtTicks(bob, 100, 300, _liqB);

    // Swap enough to cross from A into B (_price limit at 150 caps traversal)
    // 100 bips exhausts A, 110 gives margin to enter B
    uint256 _swapAmount = uint256(_liqA) * 110 / BIPS;
    _swap(alice, int256(_swapAmount), true, int24(150));

    int24 _currentTick = hook.getCurrentTick();
    assertGe(_currentTick, 100, "Tick should cross into Position B's range");
    assertLt(_currentTick, 300, "Tick should be within Position B's range");
    // Active _liquidity should now include only B (A ends at 100)
    assertEq(hook.getActiveLiquidity(), _liqB, "Active _liquidity should match Position B");
  }

  /// @dev Swap Cash->PT across contiguous positions (reverse direction)
  function testFuzz_SwapAcrossContiguousPositions_CashForPrincipal(uint128 _liqA, uint128 _liqB)
    public
  {
    _liqA = _boundLiquidity(_liqA);
    _liqB = _boundLiquidity(_liqB);
    _warpFromStart(1);

    // Position A: [0, 100], Position B: [100, 300]
    _mintLiquidityAtTicks(alice, 0, 100, _liqA);
    _mintLiquidityAtTicks(bob, 100, 300, _liqB);

    // Push _tick well into B's range: exhaust A's 100 _ticks + 20 _ticks into B (_price limit at
    // 150)
    uint256 _pushAmount = uint256(_liqA) * 100 / BIPS + uint256(_liqB) * 20 / BIPS;
    _swap(alice, int256(_pushAmount), true, int24(150));
    assertGt(hook.getCurrentTick(), 100, "Should be past boundary into B's range after push");

    // Swap cash->principal back into A: enough for B's _ticks + A's _ticks (_tick limit at 50)
    uint256 _reverseAmount = uint256(_liqB) * 20 / BIPS + uint256(_liqA) * 100 / BIPS;
    _swap(alice, int256(_reverseAmount), false, int24(50));

    int24 _currentTick = hook.getCurrentTick();
    assertLe(_currentTick, 100, "Tick should be back in Position A's range");
    assertGe(_currentTick, 0, "Tick should be within Position A's range");
  }

  /// @dev Swap reverts when trying to continue past the only position's range (gap beyond)
  function testFuzz_RevertIf_SwapExceedsRangePrincipalForCash(uint128 _liq) public {
    _liq = _boundLiquidity(_liq);
    _warpFromStart(1);

    // Only position at [0, 100], gap beyond _tick 100
    _mintLiquidityAtTicks(alice, 0, 100, _liq);

    // Compute exact _amount to exhaust the range
    int256 _priceAtStart = hook.tickToPrice(hook.getCurrentTick());
    (uint256 _principalToBoundary,,,) =
      hook.exposed_getCashSwapAmount(int256(1e36), _priceAtStart, 100);

    // Try to swap past the boundary — should revert because there's no _liquidity beyond
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_InvalidTickTraversal.selector);
    _swap(bob, int256(_principalToBoundary + 1), true, NO_TICK_LIMIT);
  }

  /// @dev Swap reverts when _liquidity is exhausted going cash->principal past _lower _tick
  function testFuzz_RevertIf_SwapExceedsRangeCashForPrincipal(uint128 _liq) public {
    _liq = _boundLiquidity(_liq);
    _warpFromStart(1);

    // Position at [0, 100] — starts in range at _tick 0
    _mintLiquidityAtTicks(alice, 0, 100, _liq);

    // Push _tick positive into the range so cash->principal has room to move left
    uint256 _pushAmount = uint256(_liq) * 50 / BIPS;
    _swap(bob, int256(_pushAmount), true, NO_TICK_LIMIT);
    assertGt(hook.getCurrentTick(), 0, "Should be above _lower _tick after push");

    // Try to exhaust all _liquidity going cash->principal past _lower _tick (_tick 0)
    int256 _price = hook.tickToPrice(hook.getCurrentTick());
    (uint256 _cashInToBoundary,,,) = hook.exposed_getPrincipalSwapAmount(int256(1e36), _price, 0);

    // Going past the _lower boundary with extra should revert
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_InvalidTickTraversal.selector);
    _swap(bob, int256(_cashInToBoundary + 1), false, NO_TICK_LIMIT);
  }
}
