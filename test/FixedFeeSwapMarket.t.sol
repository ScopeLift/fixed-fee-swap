// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {FixedFeeSwapMarket, TickInfo, TokenDelta, PositionInfo} from "src/FixedFeeSwapMarket.sol";
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
  int256 amount1;
}

struct SharedWithdrawalCtx {
  uint128 aliceLiquidity;
  uint128 bobLiquidity;
  int24 tickLower;
  int24 tickUpper;
  bytes32 alicePositionId;
  int16 lowerWord;
  uint8 lowerBit;
  int16 upperWord;
  uint8 upperBit;
  uint256 lowerWordAfterMint;
  uint256 upperWordAfterMint;
}

abstract contract FixedFeeSwapMarketTest is Test {
  FixedFeeSwapMarketHarness public hook;
  MockERC20 public token0;
  MockERC20 public token1;

  uint48 public constant MARKET_LENGTH = 365 days;
  // Large balance to support very large fuzzed liquidity ranges without incidental ERC20 reverts.
  uint256 public constant INITIAL_BALANCE = 1_000_000_000_000e18;
  uint256 public constant SCALE_FACTOR = 1e18;
  uint256 public constant BIPS = 10_000;
  int24 internal constant MAX_TICK = 100_000;
  // Fee rate in hundredths of a bip (3000 = 0.30%)
  // Set to 0 for existing tests to pass without fee impact
  uint24 public constant FEE_RATE = 0;
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

    // Use a mock address for manager
    address mockManager = makeAddr("mockManager");

    // Deploy harness directly - validation is overridden to skip address checks
    hook = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH,
      address(token0),
      address(token1),
      FEE_RATE,
      YIELD_PER_TICK,
      IPoolManager(mockManager),
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

  function _fundUser(address user) internal {
    token0.mint(user, INITIAL_BALANCE);
    token1.mint(user, INITIAL_BALANCE);
  }

  function _resetHookWithInitialTick(int24 initialTick, string memory managerLabel) internal {
    hook = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH,
      address(token0),
      address(token1),
      FEE_RATE,
      YIELD_PER_TICK,
      IPoolManager(makeAddr(managerLabel)),
      initialTick
    );
    _approveUser(alice);
    _approveUser(bob);
  }

  function _approveUser(address user) internal {
    vm.startPrank(user);
    token0.approve(address(hook), type(uint256).max);
    token1.approve(address(hook), type(uint256).max);
    vm.stopPrank();
  }

  function _boundTick(int24 tick) internal pure returns (int24) {
    return int24(bound(int256(tick), 0, 100_000));
  }

  function _boundTickRange(int24 lower, int24 upper) internal pure returns (int24, int24) {
    lower = int24(bound(int256(lower), 0, 9999));
    upper = int24(bound(int256(upper), int256(lower) + 1, 10_000));
    return (lower, upper);
  }

  function _boundLiquidity(uint128 liquidity) internal pure returns (uint128) {
    // Liquidity needs to be large enough to avoid rounding to 0 in _getAmountCashDelta
    // With remaining-time pricing near START_TIME, scaledTime ≈ WAD, so 1e17 is adequate
    // But not too large to cause overflow in other calculations
    return uint128(bound(liquidity, 1e17, 3e24));
  }

  function _boundTimeElapsed(uint256 time) internal view returns (uint256) {
    return bound(time, 0, MARKET_LENGTH);
  }

  function _warpFromStart(uint256 timeElapsed) internal {
    vm.warp(hook.getStartTime() + timeElapsed);
  }

  function _warpToMintTime() internal {
    _warpFromStart(1);
  }

  function _expectedMintAmounts(int24 tickLower, int24 tickUpper, uint128 liquidity)
    internal
    returns (int256 expected0, int256 expected1)
  {
    int24 currentTick = hook.getCurrentTick();
    int128 liq = int128(uint128(liquidity));

    if (currentTick < tickLower) {
      expected1 = hook.exposed_getAmountCashDelta(tickLower, tickUpper, liq);
    } else if (currentTick < tickUpper) {
      expected0 = hook.exposed_getAmountPrincipalDelta(tickLower, currentTick, liq);
      expected1 = hook.exposed_getAmountCashDelta(currentTick, tickUpper, liq);
    } else {
      expected0 = hook.exposed_getAmountPrincipalDelta(tickLower, tickUpper, liq);
    }
  }

  function _boundScenario(uint8 scenario) internal pure returns (RangeScenario) {
    return RangeScenario(uint8(bound(scenario, 0, uint8(type(RangeScenario).max))));
  }

  function _rangeForScenario(int24 currentTick, RangeScenario scenario, int24 width)
    internal
    pure
    returns (int24 tickLower, int24 tickUpper)
  {
    require(width > 0, "Width must be positive");

    if (scenario == RangeScenario.BelowCurrent) {
      tickUpper = currentTick - width;
      tickLower = tickUpper - width;
    } else if (scenario == RangeScenario.InRange) {
      tickLower = currentTick - width;
      tickUpper = currentTick + width;
    } else if (scenario == RangeScenario.AboveCurrent) {
      tickLower = currentTick + width;
      tickUpper = tickLower + width;
    } else if (scenario == RangeScenario.LowerAtCurrent) {
      tickLower = currentTick;
      tickUpper = currentTick + width;
    } else {
      tickLower = currentTick - width;
      tickUpper = currentTick;
    }
  }

  function _standardRange(RangeScenario scenario)
    internal
    view
    returns (int24 tickLower, int24 tickUpper)
  {
    return _rangeForScenario(hook.getCurrentTick(), scenario, 100);
  }

  /// @notice Computes the packed bitmap slot/bit for a given tick.
  /// @dev Mirrors `TickBitmap.position` with `tickSpacing = 1` (so the compressed tick equals
  /// `tick`). @param tick The tick to locate in the bitmap.
  /// @return wordPos The bitmap word key (`tick >> 8`).
  /// @return bitPos The bit index within the word (`tick & 0xff`).
  function _bitmapPosition(int24 tick) internal pure returns (int16 wordPos, uint8 bitPos) {
    assembly ("memory-safe") {
      wordPos := sar(8, signextend(2, tick))
      bitPos := and(tick, 0xff)
    }
  }

  function _boundSwapAmount(uint256 amount) internal pure returns (uint256) {
    return bound(amount, 1e16, 1e20);
  }

  function _mintDefaultLiquidity(address user) internal returns (bytes32) {
    vm.prank(user);
    hook.mintLiquidity(0, 200, 1e18, type(uint256).max, type(uint256).max);
    return keccak256(abi.encodePacked(int24(200), int24(0), user));
  }

  function _mintLiquidityAtTicks(address user, int24 lower, int24 upper, uint128 liquidity)
    internal
    returns (bytes32)
  {
    vm.prank(user);
    hook.mintLiquidity(lower, upper, liquidity, type(uint256).max, type(uint256).max);
    return keccak256(abi.encodePacked(upper, lower, user));
  }

  function _mintLiquidity(address user, int24 tickLower, int24 tickUpper, uint128 liquidity)
    internal
    returns (uint256 token0Used, uint256 token1Used)
  {
    uint256 balance0Before = token0.balanceOf(user);
    uint256 balance1Before = token1.balanceOf(user);

    vm.prank(user);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);

    token0Used = balance0Before - token0.balanceOf(user);
    token1Used = balance1Before - token1.balanceOf(user);
  }

  function _increaseLiquidity(address user, bytes32 positionId, uint128 additionalLiquidity)
    internal
    returns (int256 token0Used, int256 token1Used)
  {
    uint256 balance0Before = token0.balanceOf(user);
    uint256 balance1Before = token1.balanceOf(user);

    vm.prank(user);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);

    token0Used = int256(balance0Before - token0.balanceOf(user));
    token1Used = int256(balance1Before - token1.balanceOf(user));
  }

  function _decreaseAllLiquidity(address user, bytes32 positionId, uint128 liquidity) internal {
    vm.prank(user);
    hook.decreaseLiquidity(positionId, -int128(liquidity), 0, 0);
  }

  function _decreaseLiquidity(address user, bytes32 positionId, uint128 removeAmount)
    internal
    returns (uint256 token0Received, uint256 token1Received)
  {
    uint256 balance0Before = token0.balanceOf(user);
    uint256 balance1Before = token1.balanceOf(user);

    vm.prank(user);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);

    token0Received = token0.balanceOf(user) - balance0Before;
    token1Received = token1.balanceOf(user) - balance1Before;
  }

  function _getPositionId(int24 tickUpper, int24 tickLower, address owner)
    internal
    pure
    returns (bytes32)
  {
    return keccak256(abi.encodePacked(tickUpper, tickLower, owner));
  }

  /// @dev Mints liquidity at a high range and swaps to move currentTick to _target.
  /// Uses high tick values to avoid contaminating ticks used by normal tests.
  function _moveTickTo(int24 _target) internal {
    require(_target > 0, "Target must be positive");
    _warpToMintTime();
    // Use a range far above normal test bounds to avoid contaminating tick liquidity
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

    assertEq(_hook.getStartTime(), _startTime, "start time");
    assertEq(_hook.getMaturity(), _startTime + _marketLength, "maturity");
    assertEq(_hook.getToken0(), address(token0), "token0");
    assertEq(_hook.getToken1(), address(token1), "token1");
    assertEq(_hook.FEE_RATE(), _feeRate, "fee rate");
    assertEq(_hook.YIELD_PER_TICK(), _yieldPerTick, "yield per tick");
    assertEq(address(_hook.poolManager()), _mockManager, "pool manager");
    assertEq(_hook.getCurrentTick(), _initialTick, "initial tick");
  }

  function testFuzz_RevertIf_FeeRateTooHigh(uint24 _feeRate) public {
    _feeRate = uint24(bound(_feeRate, 1_000_000, type(uint24).max));
    address _mockManager = makeAddr("constructorMockManager");
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__FeeRateTooHigh.selector);
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
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidYieldSpacing.selector);
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

  function _priceAtElapsed(int24 tick, uint256 timeElapsed) internal returns (int256) {
    _warpFromStart(timeElapsed);
    return hook.tickToPrice(tick);
  }

  /// @dev At START_TIME, remaining = duration so scaledTime = WAD and the exponent reduces to
  /// -tick/BIPS, so price matches exp(-tick/BIPS).
  function testFuzz_PriceAtStartMatchesExpected(int24 tick) public {
    tick = int24(bound(int256(tick), 0, MAX_TICK));

    int256 actual = _priceAtElapsed(tick, 0);

    int256 exponent = (-int256(tick) * 1e18) / int256(BIPS);
    int256 expected = exponent.expWad();
    assertApproxEqRel(actual, expected, 1e12, "price at start should match exp(-tick/BIPS)");
  }

  /// @dev For any non-mature timestamp, strictly higher yield (tick) implies strictly lower price.
  function testFuzz_PriceDecreasesAsYieldIncreases(int24 tickA, int24 tickB, uint256 timeElapsed)
    public
  {
    tickA = int24(bound(int256(tickA), 0, MAX_TICK - 1));
    tickB = int24(bound(int256(tickB), tickA + 1, MAX_TICK));
    timeElapsed = bound(timeElapsed, 1, MARKET_LENGTH - 1);

    int256 priceA = _priceAtElapsed(tickA, timeElapsed);
    int256 priceB = _priceAtElapsed(tickB, timeElapsed);

    assertGt(priceA, priceB, "Higher tick should have strictly lower price before maturity");
  }

  /// @dev Price increases over time for positive yields (converges to 1.0 at maturity)
  /// @notice With exp(-yield * time_remaining), less remaining time => less discount.
  function testFuzz_PriceIncreasesOverTimeSameYield(int24 tick, uint256 time1, uint256 time2)
    public
  {
    tick = int24(bound(int256(tick), 1, MAX_TICK));
    time1 = bound(time1, 0, MARKET_LENGTH - 2);
    time2 = bound(time2, time1 + 1, MARKET_LENGTH - 1);

    int256 price1 = _priceAtElapsed(tick, time1);
    int256 price2 = _priceAtElapsed(tick, time2);

    assertGe(price2, price1, "Price should increase over time (converge to 1)");
  }

  /// @dev At maturity, price equals 1 regardless of tick (PT redeemable 1:1)
  /// @notice At maturity, remaining time = 0, so tickToPrice returns WAD directly
  function testFuzz_PriceAtMaturityIsOne(int24 tick) public {
    tick = int24(bound(int256(tick), 0, MAX_TICK));
    vm.warp(hook.getMaturity());
    int256 price = hook.tickToPrice(tick);
    assertEq(price, 1e18, "Price at maturity should be 1 regardless of tick");
  }

  /// @dev Remaining-time additivity: price(rem1+rem2) == price(rem1) * price(rem2)
  /// @notice exp(-y*(r1+r2)/d) = exp(-y*r1/d) * exp(-y*r2/d) where r = remaining time
  function testFuzz_RemainingTimeAdditivitiveWithPrice(int24 tick, uint256 rem1, uint256 rem2)
    public
  {
    tick = int24(bound(int256(tick), -MAX_TICK, MAX_TICK));
    rem1 = bound(rem1, 0, MARKET_LENGTH);
    rem2 = bound(rem2, 0, MARKET_LENGTH - rem1);

    vm.warp(hook.getMaturity() - rem1);
    int256 price1 = hook.tickToPrice(tick);

    vm.warp(hook.getMaturity() - rem2);
    int256 price2 = hook.tickToPrice(tick);

    vm.warp(hook.getMaturity() - (rem1 + rem2));
    int256 price12 = hook.tickToPrice(tick);

    int256 combined = (price1 * price2) / 1e18;
    assertApproxEqRel(
      price12, combined, 1e12, "price(rem1+rem2) should equal price(rem1)*price(rem2)"
    );
  }
}

contract MintLiquidity is FixedFeeSwapMarketTest {
  function setUp() public virtual override {
    super.setUp();
    _resetHookWithInitialTick(500, "mintLiquidityManager");
  }

  function testFuzz_CreatesPositionAndUpdatesTickState(
    int24 tickLower,
    int24 tickUpper,
    uint128 liquidity
  ) public {
    (tickLower, tickUpper) = _boundTickRange(tickLower, tickUpper);
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();

    (uint128 lowerGrossBefore, int128 lowerNetBefore) = hook.getTickInfo(tickLower);
    (uint128 upperGrossBefore, int128 upperNetBefore) = hook.getTickInfo(tickUpper);

    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);

    {
      bytes32 positionId = _getPositionId(tickUpper, tickLower, alice);
      (address owner, int24 lower, int24 upper, int128 liq) = hook.getPositionInfo(positionId);
      assertEq(owner, alice, "position owner");
      assertEq(lower, tickLower, "position tickLower");
      assertEq(upper, tickUpper, "position tickUpper");
      assertEq(uint128(liq), liquidity, "position liquidity");
    }

    {
      (uint128 lowerGrossAfter, int128 lowerNetAfter) = hook.getTickInfo(tickLower);
      (uint128 upperGrossAfter, int128 upperNetAfter) = hook.getTickInfo(tickUpper);
      assertEq(lowerGrossAfter - lowerGrossBefore, liquidity, "lower gross delta");
      assertEq(upperGrossAfter - upperGrossBefore, liquidity, "upper gross delta");
      assertEq(lowerNetAfter - lowerNetBefore, int128(liquidity), "lower net delta");
      assertEq(upperNetAfter - upperNetBefore, -int128(liquidity), "upper net delta");
    }

    {
      (int16 lowerWord, uint8 lowerBit) = _bitmapPosition(tickLower);
      (int16 upperWord, uint8 upperBit) = _bitmapPosition(tickUpper);
      uint256 lowerWordValue = hook.getTickBitmapWord(lowerWord);
      uint256 upperWordValue = hook.getTickBitmapWord(upperWord);
      assertTrue((lowerWordValue & (uint256(1) << lowerBit)) != 0, "lower bitmap bit set");
      assertTrue((upperWordValue & (uint256(1) << upperBit)) != 0, "upper bitmap bit set");
    }
  }

  function testFuzz_TransfersExpectedAmounts(
    int24 tickLower,
    int24 tickUpper,
    uint128 liquidity,
    uint256 timeElapsed
  ) public {
    (tickLower, tickUpper) = _boundTickRange(tickLower, tickUpper);
    liquidity = _boundLiquidity(liquidity);
    timeElapsed = bound(timeElapsed, 1, MARKET_LENGTH - 1);

    _warpFromStart(timeElapsed);

    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, liquidity);
    uint256 user0Before = token0.balanceOf(alice);
    uint256 user1Before = token1.balanceOf(alice);
    uint256 hook0Before = token0.balanceOf(address(hook));
    uint256 hook1Before = token1.balanceOf(address(hook));
    uint256 total0Before = user0Before + hook0Before;
    uint256 total1Before = user1Before + hook1Before;

    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);

    uint256 user0After = token0.balanceOf(alice);
    uint256 user1After = token1.balanceOf(alice);
    uint256 hook0After = token0.balanceOf(address(hook));
    uint256 hook1After = token1.balanceOf(address(hook));
    assertEq(int256(user0Before - user0After), expected0, "user token0 debit");
    assertEq(int256(user1Before - user1After), expected1, "user token1 debit");
    assertEq(int256(hook0After - hook0Before), expected0, "hook token0 credit");
    assertEq(int256(hook1After - hook1Before), expected1, "hook token1 credit");
    assertEq(user0After + hook0After, total0Before, "token0 conservation");
    assertEq(user1After + hook1After, total1Before, "token1 conservation");
  }

  function testFuzz_UpdatesActiveLiquidityWhenRangeIncludesCurrentTick(
    uint128 liquidity,
    uint8 scenario
  ) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();

    // Map to the two inclusive cases: InRange or LowerAtCurrent.
    uint8 boundedScenario = uint8(bound(scenario, 0, 1));
    RangeScenario rangeScenario =
      boundedScenario == 0 ? RangeScenario.InRange : RangeScenario.LowerAtCurrent;
    (int24 tickLower, int24 tickUpper) = _standardRange(rangeScenario);
    uint128 activeBefore = hook.getActiveLiquidity();

    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);

    assertEq(hook.getActiveLiquidity(), activeBefore + liquidity, "active liquidity increase");
  }

  function testFuzz_DoesNotUpdateActiveLiquidityWhenRangeExcludesCurrentTick(
    uint128 liquidity,
    uint8 scenario
  ) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();

    // Map to excluded cases: BelowCurrent, AboveCurrent, UpperAtCurrent.
    uint8 boundedScenario = uint8(bound(scenario, 0, 2));
    RangeScenario rangeScenario = boundedScenario == 0
      ? RangeScenario.BelowCurrent
      : boundedScenario == 1 ? RangeScenario.AboveCurrent : RangeScenario.UpperAtCurrent;
    (int24 tickLower, int24 tickUpper) = _standardRange(rangeScenario);
    uint128 activeBefore = hook.getActiveLiquidity();

    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);

    assertEq(hook.getActiveLiquidity(), activeBefore, "active liquidity unchanged");
  }

  function testFuzz_MultipleUsersMintInSameRange(
    uint128 liquidityAlice,
    uint128 liquidityBob,
    uint8 scenario
  ) public {
    liquidityAlice = _boundLiquidity(liquidityAlice);
    liquidityBob = _boundLiquidity(liquidityBob);

    _warpToMintTime();

    (int24 tickLower, int24 tickUpper) = _standardRange(_boundScenario(scenario));

    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidityAlice, type(uint256).max, type(uint256).max);
    vm.prank(bob);
    hook.mintLiquidity(tickLower, tickUpper, liquidityBob, type(uint256).max, type(uint256).max);

    (uint128 lowerGross,) = hook.getTickInfo(tickLower);
    (uint128 upperGross,) = hook.getTickInfo(tickUpper);
    assertEq(lowerGross, liquidityAlice + liquidityBob, "lower gross combined");
    assertEq(upperGross, liquidityAlice + liquidityBob, "upper gross combined");

    bytes32 alicePositionId = _getPositionId(tickUpper, tickLower, alice);
    bytes32 bobPositionId = _getPositionId(tickUpper, tickLower, bob);
    (address aliceOwner,,, int128 aliceLiq) = hook.getPositionInfo(alicePositionId);
    (address bobOwner,,, int128 bobLiq) = hook.getPositionInfo(bobPositionId);
    assertEq(aliceOwner, alice, "alice owner");
    assertEq(bobOwner, bob, "bob owner");
    assertEq(uint128(aliceLiq), liquidityAlice, "alice liquidity");
    assertEq(uint128(bobLiq), liquidityBob, "bob liquidity");
  }

  function testFuzz_LiquidityBelowCurrentTickIsOnlyToken0(uint128 liquidity, uint8 scenario)
    public
  {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();

    uint8 boundedScenario = uint8(bound(scenario, 0, 1));
    RangeScenario rangeScenario =
      boundedScenario == 0 ? RangeScenario.BelowCurrent : RangeScenario.UpperAtCurrent;
    int24 currentTick = hook.getCurrentTick();
    (int24 tickLower, int24 tickUpper) = _rangeForScenario(currentTick, rangeScenario, 100);
    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, liquidity);

    uint256 balance0Before = token0.balanceOf(alice);
    uint256 balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);

    assertGt(expected0, 0, "requires token0");
    assertEq(expected1, 0, "does not require token1");
    assertEq(int256(balance0Before - token0.balanceOf(alice)), expected0, "token0 amount");
    assertEq(int256(balance1Before - token1.balanceOf(alice)), expected1, "token1 amount");
  }

  function testFuzz_LiquidityAboveCurrentTickIsOnlyToken1(uint128 liquidity, uint8 scenario)
    public
  {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();

    uint8 boundedScenario = uint8(bound(scenario, 0, 1));
    RangeScenario rangeScenario =
      boundedScenario == 0 ? RangeScenario.AboveCurrent : RangeScenario.LowerAtCurrent;
    int24 currentTick = hook.getCurrentTick();
    (int24 tickLower, int24 tickUpper) = _rangeForScenario(currentTick, rangeScenario, 100);
    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, liquidity);

    uint256 balance0Before = token0.balanceOf(alice);
    uint256 balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);

    assertEq(expected0, 0, "does not require token0");
    assertGt(expected1, 0, "requires token1");
    assertEq(int256(balance0Before - token0.balanceOf(alice)), expected0, "token0 amount");
    assertEq(int256(balance1Before - token1.balanceOf(alice)), expected1, "token1 amount");
  }

  function testFuzz_CurrentTickIsInLiquidityRange(uint128 liquidity) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();

    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);
    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, liquidity);

    uint256 balance0Before = token0.balanceOf(alice);
    uint256 balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);

    assertGt(expected0, 0, "requires token0");
    assertGt(expected1, 0, "requires token1");
    assertEq(int256(balance0Before - token0.balanceOf(alice)), expected0, "token0 amount");
    assertEq(int256(balance1Before - token1.balanceOf(alice)), expected1, "token1 amount");
  }

  function testFuzz_TokenAmountsScaleWithLiquidity_BelowOrUpperAtCurrent(
    uint128 liquidity1,
    uint128 liquidity2,
    uint8 scenario
  ) public {
    liquidity1 = uint128(bound(liquidity1, 1e17, 1e18));
    liquidity2 = uint128(bound(liquidity2, liquidity1 * 2, 1e20));

    _warpToMintTime();

    uint8 boundedScenario = uint8(bound(scenario, 0, 1));
    RangeScenario rangeScenario =
      boundedScenario == 0 ? RangeScenario.BelowCurrent : RangeScenario.UpperAtCurrent;
    (int24 tickLower, int24 tickUpper) = _standardRange(rangeScenario);
    (int256 expected0_1,) = _expectedMintAmounts(tickLower, tickUpper, liquidity1);
    (int256 expected0_2,) = _expectedMintAmounts(tickLower, tickUpper, liquidity2);
    assertGe(expected0_2, expected0_1, "expected token0 monotonic");

    (uint256 token0Used1, uint256 token1Used1) =
      _mintLiquidity(alice, tickLower, tickUpper, liquidity1);
    (uint256 token0Used2, uint256 token1Used2) =
      _mintLiquidity(bob, tickLower, tickUpper, liquidity2);
    assertEq(int256(token0Used1), expected0_1, "token0 used liquidity1");
    assertEq(token1Used1, 0, "zero liquidity1 token1");
    assertEq(int256(token0Used2), expected0_2, "token0 used liquidity2");
    assertEq(token1Used2, 0, "zero liquidity2 token1");
    assertGt(token0Used2, token0Used1, "larger liquidity token0");
  }

  function testFuzz_AddingLiquidityAboveCurrentTickIncreasesToken1Used(
    uint128 liquidity1,
    uint128 liquidity2,
    uint8 scenario
  ) public {
    liquidity1 = uint128(bound(liquidity1, 1e17, 1e18));
    liquidity2 = uint128(bound(liquidity2, liquidity1 * 2, 1e20));

    _warpToMintTime();

    uint8 boundedScenario = uint8(bound(scenario, 0, 1));
    RangeScenario rangeScenario =
      boundedScenario == 0 ? RangeScenario.AboveCurrent : RangeScenario.LowerAtCurrent;
    (int24 tickLower, int24 tickUpper) = _standardRange(rangeScenario);
    (, int256 expected1_1) = _expectedMintAmounts(tickLower, tickUpper, liquidity1);
    (, int256 expected1_2) = _expectedMintAmounts(tickLower, tickUpper, liquidity2);

    (uint256 token0Used1, uint256 token1Used1) =
      _mintLiquidity(alice, tickLower, tickUpper, liquidity1);
    (uint256 token0Used2, uint256 token1Used2) =
      _mintLiquidity(bob, tickLower, tickUpper, liquidity2);
    assertEq(int256(token1Used1), expected1_1, "token1 used liquidity1");
    assertEq(int256(token1Used2), expected1_2, "token1 used liquidity2");
    assertEq(token0Used1, 0, "zero liquidity1 token0");
    assertEq(token0Used2, 0, "zero liquidity2 token0");
    assertGt(token1Used2, token1Used1, "larger liquidity token1");
  }

  function testFuzz_AddingLiquidityAboveCurrentTickIncreasesToken1Used(
    uint128 liquidity1,
    uint128 liquidity2
  ) public {
    liquidity1 = uint128(bound(liquidity1, 1e17, 1e18));
    liquidity2 = uint128(bound(liquidity2, liquidity1 * 2, 1e20));

    _warpToMintTime();

    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);
    (int256 expected0_1, int256 expected1_1) =
      _expectedMintAmounts(tickLower, tickUpper, liquidity1);
    (int256 expected0_2, int256 expected1_2) =
      _expectedMintAmounts(tickLower, tickUpper, liquidity2);

    (uint256 token0Used1, uint256 token1Used1) =
      _mintLiquidity(alice, tickLower, tickUpper, liquidity1);
    (uint256 token0Used2, uint256 token1Used2) =
      _mintLiquidity(bob, tickLower, tickUpper, liquidity2);
    assertEq(int256(token0Used1), expected0_1, "token0 used liquidity1");
    assertEq(int256(token1Used1), expected1_1, "token1 used liquidity1");
    assertEq(int256(token0Used2), expected0_2, "token0 used liquidity2");
    assertEq(int256(token1Used2), expected1_2, "token1 used liquidity2");
    assertGt(token0Used2, token0Used1, "larger liquidity token0");
    assertGt(token1Used2, token1Used1, "larger liquidity token1");
  }

  function testFuzz_AWiderLiquidityRangeBelowTheCurrentTickRequiresMoreToken1(
    uint128 liquidity,
    int24 narrowWidth,
    int24 wideWidth
  ) public {
    liquidity = _boundLiquidity(liquidity);
    narrowWidth = int24(bound(int256(narrowWidth), 1, 50));
    wideWidth = int24(bound(int256(wideWidth), int256(narrowWidth) + 1, 200));

    _warpToMintTime();

    (, int24 tickUpper) = _standardRange(RangeScenario.UpperAtCurrent);
    (uint256 token0Narrow, uint256 token1Narrow) =
      _mintLiquidity(alice, tickUpper - narrowWidth, tickUpper, liquidity);
    (uint256 token0Wide, uint256 token1Wide) =
      _mintLiquidity(bob, tickUpper - wideWidth, tickUpper, liquidity);

    assertGt(token0Wide, token0Narrow, "wider range token0");
    assertEq(token1Narrow, 0, "below-range narrow token1");
    assertEq(token1Wide, 0, "below-range wide token1");
  }

  function testFuzz_MintIsSuccessfulWhenAmountsEqualSpecifiedMax(
    int24 tickLower,
    int24 tickUpper,
    uint128 liquidity
  ) public {
    (tickLower, tickUpper) = _boundTickRange(tickLower, tickUpper);
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();

    (int256 required0, int256 required1) = _expectedMintAmounts(tickLower, tickUpper, liquidity);

    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, uint256(required0), uint256(required1));
  }

  function testFuzz_MintingToExistingPositionAccumulatesLiquidity(
    uint128 liq1,
    uint128 liq2,
    uint8 scenario
  ) public {
    liq1 = _boundLiquidity(liq1);
    liq2 = _boundLiquidity(liq2);

    _warpToMintTime();

    (int24 tickLower, int24 tickUpper) = _standardRange(_boundScenario(scenario));

    bytes32 positionId1 = _mintLiquidityAtTicks(alice, tickLower, tickUpper, liq1);

    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liq2, type(uint256).max, type(uint256).max);
    bytes32 positionId2 = _getPositionId(tickUpper, tickLower, alice);

    assertEq(positionId1, positionId2, "same position id");

    (address owner,,, int128 totalLiquidity) = hook.getPositionInfo(positionId1);
    assertEq(owner, alice, "owner");
    assertEq(uint128(totalLiquidity), liq1 + liq2, "position liquidity sum");

    (uint128 lowerGross,) = hook.getTickInfo(tickLower);
    (uint128 upperGross,) = hook.getTickInfo(tickUpper);
    assertEq(lowerGross, liq1 + liq2, "lower gross sum");
    assertEq(upperGross, liq1 + liq2, "upper gross sum");
  }

  function testFuzz_EmitsLiquidityModified(int24 tickLower, int24 tickUpper, uint128 liquidity)
    public
  {
    (tickLower, tickUpper) = _boundTickRange(tickLower, tickUpper);
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();

    bytes32 positionId = _getPositionId(tickUpper, tickLower, alice);
    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, liquidity);

    vm.expectEmit();
    emit FixedFeeSwapMarket.LiquidityModified(
      positionId,
      alice,
      tickLower,
      tickUpper,
      int128(liquidity),
      int128(expected0),
      int128(expected1)
    );

    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);
  }

  // ============ Revert Tests ============

  function testFuzz_RevertIf_TickRangeIsInvalid(int24 tickLower, int24 tickUpper, uint128 liquidity)
    public
  {
    liquidity = _boundLiquidity(liquidity);
    vm.assume(tickLower < 0 || tickLower >= tickUpper);

    _warpToMintTime();
    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidTickRange.selector);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);
  }

  function testFuzz_RevertIf_MaxTokenAmountTooLow(uint128 liquidity, bool checkToken0) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();

    RangeScenario scenario = checkToken0 ? RangeScenario.BelowCurrent : RangeScenario.AboveCurrent;
    (int24 tickLower, int24 tickUpper) = _standardRange(scenario);

    (int256 required0, int256 required1) = _expectedMintAmounts(tickLower, tickUpper, liquidity);

    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidLiquidityAmount.selector);
    hook.mintLiquidity(
      tickLower,
      tickUpper,
      liquidity,
      checkToken0 ? uint256(required0) - 1 : type(uint256).max,
      checkToken0 ? type(uint256).max : uint256(required1) - 1
    );
  }

  function testFuzz_RevertIf_NoTokenAllowance(uint128 liquidity, bool checkToken0) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();

    RangeScenario scenario = checkToken0 ? RangeScenario.BelowCurrent : RangeScenario.AboveCurrent;
    (int24 tickLower, int24 tickUpper) = _standardRange(scenario);

    vm.startPrank(alice);
    token0.approve(address(hook), 0);
    token1.approve(address(hook), 0);
    vm.expectRevert(stdError.arithmeticError);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_TokenBalanceIsTooLow(uint128 liquidity, bool checkToken0) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();

    RangeScenario scenario = checkToken0 ? RangeScenario.BelowCurrent : RangeScenario.AboveCurrent;
    (int24 tickLower, int24 tickUpper) = _standardRange(scenario);

    vm.startPrank(alice);
    token0.transfer(makeAddr("sink"), token0.balanceOf(alice));
    token1.transfer(makeAddr("sink"), token1.balanceOf(alice));

    vm.expectRevert(stdError.arithmeticError);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);
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
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    vm.prank(alice);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);

    (address owner, int24 lower, int24 upper, int128 totalLiquidity) =
      hook.getPositionInfo(positionId);
    (uint128 lowerGross, int128 lowerNet) = hook.getTickInfo(tickLower);
    (uint128 upperGross, int128 upperNet) = hook.getTickInfo(tickUpper);
    uint128 expectedTotal = initialLiquidity + additionalLiquidity;

    assertEq(owner, alice, "owner");
    assertEq(lower, tickLower, "tickLower");
    assertEq(upper, tickUpper, "tickUpper");
    assertEq(uint128(totalLiquidity), expectedTotal, "position liquidity");
    assertEq(lowerGross, expectedTotal, "lower gross");
    assertEq(upperGross, expectedTotal, "upper gross");
    assertEq(lowerNet, int128(expectedTotal), "lower net");
    assertEq(upperNet, -int128(expectedTotal), "upper net");
  }

  function testFuzz_TickBitmapBitsRemainSetAfterIncrease(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    (int24 tickLower, int24 tickUpper) = _rangeForScenario(currentTick, RangeScenario.InRange, 200);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int16 lowerWord, uint8 lowerBit) = _bitmapPosition(tickLower);
    (int16 upperWord, uint8 upperBit) = _bitmapPosition(tickUpper);
    uint256 lowerWordBefore = hook.getTickBitmapWord(lowerWord);
    uint256 upperWordBefore = hook.getTickBitmapWord(upperWord);

    vm.prank(alice);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);

    uint256 lowerWordAfter = hook.getTickBitmapWord(lowerWord);
    uint256 upperWordAfter = hook.getTickBitmapWord(upperWord);

    assertEq(lowerWordAfter, lowerWordBefore, "lower bitmap word");
    if (upperWord != lowerWord) assertEq(upperWordAfter, upperWordBefore, "upper bitmap word");
    assertTrue((lowerWordAfter & (uint256(1) << lowerBit)) != 0, "lower bitmap bit set");
    assertTrue((upperWordAfter & (uint256(1) << upperBit)) != 0, "upper bitmap bit set");
  }

  // ============ Token Accounting Tests ============

  function testFuzz_TransfersExpectedAmountsAndConservesTotals(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);
    (int256 expected0, int256 expected1) =
      _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);

    uint256 user0Before = token0.balanceOf(alice);
    uint256 user1Before = token1.balanceOf(alice);
    uint256 hook0Before = token0.balanceOf(address(hook));
    uint256 hook1Before = token1.balanceOf(address(hook));
    uint256 total0Before = user0Before + hook0Before;
    uint256 total1Before = user1Before + hook1Before;

    vm.prank(alice);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);

    uint256 user0After = token0.balanceOf(alice);
    uint256 user1After = token1.balanceOf(alice);
    uint256 hook0After = token0.balanceOf(address(hook));
    uint256 hook1After = token1.balanceOf(address(hook));

    assertEq(int256(user0Before - user0After), expected0, "user token0 debit");
    assertEq(int256(user1Before - user1After), expected1, "user token1 debit");
    assertEq(int256(hook0After - hook0Before), expected0, "hook token0 credit");
    assertEq(int256(hook1After - hook1Before), expected1, "hook token1 credit");
    assertEq(user0After + hook0After, total0Before, "token0 conservation");
    assertEq(user1After + hook1After, total1Before, "token1 conservation");
  }

  function testFuzz_BelowCurrentRangeIncreaseUsesOnlyToken0(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.BelowCurrent);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);
    (int256 expected0, int256 expected1) =
      _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);
    (int256 used0, int256 used1) = _increaseLiquidity(alice, positionId, additionalLiquidity);

    assertGt(expected0, 0, "expected token0");
    assertEq(expected1, 0, "expected token1");
    assertEq(used0, expected0, "token0 used");
    assertEq(used1, expected1, "token1 used");
  }

  function testFuzz_AboveCurrentRangeIncreaseUsesOnlyToken1(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.AboveCurrent);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);
    (int256 expected0, int256 expected1) =
      _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);
    (int256 used0, int256 used1) = _increaseLiquidity(alice, positionId, additionalLiquidity);

    assertEq(expected0, 0, "expected token0");
    assertGt(expected1, 0, "expected token1");
    assertEq(used0, expected0, "token0 used");
    assertEq(used1, expected1, "token1 used");
  }

  function testFuzz_InRangeIncreaseUsesBothTokens(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);
    (int256 expected0, int256 expected1) =
      _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);
    (int256 used0, int256 used1) = _increaseLiquidity(alice, positionId, additionalLiquidity);

    assertGt(expected0, 0, "expected token0");
    assertGt(expected1, 0, "expected token1");
    assertEq(used0, expected0, "token0 used");
    assertEq(used1, expected1, "token1 used");
  }

  function test_CashRequiredForLiquidityIncreasesOverTime() public {
    uint128 initialLiquidity = 1e18;
    uint128 additionalLiquidity = 1e24;

    _warpFromStart(1);
    int24 currentTick = hook.getCurrentTick();
    (int24 tickLower, int24 tickUpper) = _rangeForScenario(currentTick, RangeScenario.InRange, 200);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);
    uint256 snapshot = vm.snapshot();

    _warpFromStart(1);
    Amounts memory expectedAtT1;
    (expectedAtT1.amount0, expectedAtT1.amount1) =
      _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);
    Amounts memory usedAtT1;
    (usedAtT1.amount0, usedAtT1.amount1) =
      _increaseLiquidity(alice, positionId, additionalLiquidity);

    vm.revertTo(snapshot);
    _warpFromStart(30 days);
    Amounts memory expectedAtT2;
    (expectedAtT2.amount0, expectedAtT2.amount1) =
      _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);
    Amounts memory usedAtT2;
    (usedAtT2.amount0, usedAtT2.amount1) =
      _increaseLiquidity(alice, positionId, additionalLiquidity);

    assertEq(usedAtT1.amount0, expectedAtT1.amount0, "t1 token0");
    assertEq(usedAtT1.amount1, expectedAtT1.amount1, "t1 token1");
    assertEq(usedAtT2.amount0, expectedAtT2.amount0, "t2 token0");
    assertEq(usedAtT2.amount1, expectedAtT2.amount1, "t2 token1");
    assertGt(expectedAtT1.amount0, 0, "t1 token0 required");
    assertGt(expectedAtT1.amount1, 0, "t1 token1 required");
    assertEq(expectedAtT2.amount0, expectedAtT1.amount0, "principal invariant");
    assertTrue(expectedAtT2.amount1 != expectedAtT1.amount1, "cash changes over time");
  }

  // ============ Active Liquidity Tests ============

  function testFuzz_InRangeIncreaseUpdatesActiveLiquidity(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);
    uint128 activeBefore = hook.getActiveLiquidity();

    vm.prank(alice);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);

    uint128 activeAfter = hook.getActiveLiquidity();
    assertEq(activeAfter, activeBefore + additionalLiquidity, "active liquidity increase");
  }

  function testFuzz_OutOfRangeIncreaseDoesNotUpdateActiveLiquidity(
    uint128 initialLiquidity,
    uint128 additionalLiquidity,
    uint8 scenario
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    uint8 boundedScenario = uint8(bound(scenario, 0, 1));
    RangeScenario rangeScenario =
      boundedScenario == 0 ? RangeScenario.BelowCurrent : RangeScenario.AboveCurrent;
    (int24 tickLower, int24 tickUpper) = _standardRange(rangeScenario);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);
    uint128 activeBefore = hook.getActiveLiquidity();

    vm.prank(alice);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);

    uint128 activeAfter = hook.getActiveLiquidity();
    assertEq(activeAfter, activeBefore, "active liquidity unchanged");
  }

  // ============ Multiple Operations Tests ============

  function testFuzz_MultipleIncreasesAccumulateLiquidity(
    uint128 initialLiquidity,
    uint128 increase1,
    uint128 increase2
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    increase1 = _boundLiquidity(increase1);
    increase2 = _boundLiquidity(increase2);

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    vm.startPrank(alice);
    hook.increaseLiquidity(positionId, increase1, type(uint256).max, type(uint256).max);
    hook.increaseLiquidity(positionId, increase2, type(uint256).max, type(uint256).max);
    vm.stopPrank();

    (,,, int128 totalLiquidity) = hook.getPositionInfo(positionId);
    (uint128 lowerGross,) = hook.getTickInfo(tickLower);
    (uint128 upperGross,) = hook.getTickInfo(tickUpper);
    uint128 expectedTotal = initialLiquidity + increase1 + increase2;

    assertEq(uint128(totalLiquidity), expectedTotal, "position liquidity");
    assertEq(lowerGross, expectedTotal, "lower gross");
    assertEq(upperGross, expectedTotal, "upper gross");
  }

  function testFuzz_MultipleUsersIncreaseIndependentPositions(
    uint128 aliceInitial,
    uint128 aliceIncrease
  ) public {
    aliceInitial = _boundLiquidity(aliceInitial);
    aliceIncrease = _boundLiquidity(aliceIncrease);
    uint128 bobInitial = 1e18;
    uint128 bobIncrease = 1e18;

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);
    bytes32 alicePositionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, aliceInitial);
    bytes32 bobPositionId = _mintLiquidityAtTicks(bob, tickLower, tickUpper, bobInitial);

    vm.prank(alice);
    hook.increaseLiquidity(alicePositionId, aliceIncrease, type(uint256).max, type(uint256).max);
    vm.prank(bob);
    hook.increaseLiquidity(bobPositionId, bobIncrease, type(uint256).max, type(uint256).max);

    (,,, int128 aliceLiq) = hook.getPositionInfo(alicePositionId);
    (,,, int128 bobLiq) = hook.getPositionInfo(bobPositionId);
    (uint128 lowerGross,) = hook.getTickInfo(tickLower);
    (uint128 upperGross,) = hook.getTickInfo(tickUpper);
    uint128 expectedTotal = aliceInitial + aliceIncrease + bobInitial + bobIncrease;

    assertEq(uint128(aliceLiq), aliceInitial + aliceIncrease, "alice liquidity");
    assertEq(uint128(bobLiq), bobInitial + bobIncrease, "bob liquidity");
    assertEq(lowerGross, expectedTotal, "lower gross");
    assertEq(upperGross, expectedTotal, "upper gross");
  }

  function testFuzz_EmitsLiquidityModified(uint128 initialLiquidity, uint128 additionalLiquidity)
    public
  {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);
    (int256 expected0, int256 expected1) =
      _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);

    vm.expectEmit();
    emit FixedFeeSwapMarket.LiquidityModified(
      positionId,
      alice,
      tickLower,
      tickUpper,
      int128(additionalLiquidity),
      int128(expected0),
      int128(expected1)
    );

    vm.prank(alice);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);
  }

  function testFuzz_LiquidityAddedWhenAmountEqualMaxAmounts(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);
    (int256 required0, int256 required1) =
      _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);

    vm.prank(alice);
    hook.increaseLiquidity(positionId, additionalLiquidity, uint256(required0), uint256(required1));

    (,,, int128 totalLiquidity) = hook.getPositionInfo(positionId);
    assertEq(uint128(totalLiquidity), initialLiquidity + additionalLiquidity, "liquidity increased");
  }

  function test_RevertIf_PositionNotFound() public {
    bytes32 missingPositionId = keccak256("missing position");

    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__PositionNotFound.selector);
    hook.increaseLiquidity(missingPositionId, 1e18, type(uint256).max, type(uint256).max);
  }

  function testFuzz_RevertIf_NotCalledByPositionOwner(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    vm.prank(bob);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__NotPositionOwner.selector);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);
  }

  function testFuzz_RevertIf_MaxToken0AmountIsTooLow(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.BelowCurrent);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);
    (int256 required0,) = _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);

    uint256 required0U = uint256(required0);
    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidLiquidityAmount.selector);
    hook.increaseLiquidity(positionId, additionalLiquidity, required0U - 1, type(uint256).max);
  }

  function testFuzz_RevertIf_MaxToken1AmountIsTooLow(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.AboveCurrent);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);
    (, int256 required1) = _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);

    uint256 required1U = uint256(required1);
    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidLiquidityAmount.selector);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, required1U - 1);
  }

  function testFuzz_RevertIf_Token0AllowanceMissing(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.BelowCurrent);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    vm.startPrank(alice);
    token0.approve(address(hook), 0);
    vm.expectRevert(stdError.arithmeticError);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);
    vm.stopPrank();
  }

  function testFuzz_RevertWhen_Token1AllowanceMissing(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.AboveCurrent);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    vm.startPrank(alice);
    token1.approve(address(hook), 0);
    vm.expectRevert(stdError.arithmeticError);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_Token0BalanceInsufficient(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.BelowCurrent);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    vm.startPrank(alice);
    token0.transfer(makeAddr("sink"), token0.balanceOf(alice));
    vm.expectRevert(stdError.arithmeticError);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_Token1BalanceInsufficient(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.AboveCurrent);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    vm.startPrank(alice);
    token1.transfer(makeAddr("sink"), token1.balanceOf(alice));
    vm.expectRevert(stdError.arithmeticError);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);
    vm.stopPrank();
  }
}

contract DecreaseLiquidity is FixedFeeSwapMarketTest {
  function setUp() public virtual override {
    super.setUp();
    _moveTickTo(500);
  }

  // ============ Position Update Tests ============

  /// @dev Decreasing updates the position and both tick accounting dimensions consistently.
  function testFuzz_UpdatesPositionAndTickState(uint128 initialLiquidity, uint128 removeAmount)
    public
  {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);

    uint128 expectedRemaining = initialLiquidity - removeAmount;

    {
      (address owner, int24 lower, int24 upper, int128 remainingLiquidity) =
        hook.getPositionInfo(positionId);
      assertEq(owner, alice, "owner");
      assertEq(lower, tickLower, "tickLower");
      assertEq(upper, tickUpper, "tickUpper");
      assertEq(uint128(remainingLiquidity), expectedRemaining, "position liquidity");
    }

    {
      (uint128 lowerGross, int128 lowerNet) = hook.getTickInfo(tickLower);
      (uint128 upperGross, int128 upperNet) = hook.getTickInfo(tickUpper);
      assertEq(lowerGross, expectedRemaining, "lower gross");
      assertEq(upperGross, expectedRemaining, "upper gross");
      assertEq(lowerNet, int128(expectedRemaining), "lower net");
      assertEq(upperNet, -int128(expectedRemaining), "upper net");
    }
  }

  /// @dev Full withdrawal clears tick bitmap bits
  function testFuzz_FullWithdrawalClearsTickBitmap(uint128 liquidity) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 300;
    int24 tickUpper = currentTick + 300;

    (int16 lowerWord, uint8 lowerBit) = _bitmapPosition(tickLower);
    (int16 upperWord, uint8 upperBit) = _bitmapPosition(tickUpper);

    uint256 lowerWordBefore = hook.getTickBitmapWord(lowerWord);
    uint256 upperWordBefore = hook.getTickBitmapWord(upperWord);

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, liquidity);

    // Verify bits are set after mint
    uint256 lowerMask = uint256(1) << lowerBit;
    uint256 upperMask = uint256(1) << upperBit;
    assertTrue(
      (hook.getTickBitmapWord(lowerWord) & lowerMask) != 0,
      "Lower tick bit should be set after mint"
    );
    assertTrue(
      (hook.getTickBitmapWord(upperWord) & upperMask) != 0,
      "Upper tick bit should be set after mint"
    );

    // Full withdrawal
    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(liquidity), 0, 0);

    // Verify words are restored exactly
    assertEq(
      hook.getTickBitmapWord(lowerWord), lowerWordBefore, "Lower bitmap word should be restored"
    );
    if (upperWord != lowerWord) {
      assertEq(
        hook.getTickBitmapWord(upperWord), upperWordBefore, "Upper bitmap word should be restored"
      );
    }

    // Verify tick liquidity is zero
    (uint128 lowerGross,) = hook.getTickInfo(tickLower);
    (uint128 upperGross,) = hook.getTickInfo(tickUpper);
    assertEq(lowerGross, 0, "Lower tick should have zero liquidity");
    assertEq(upperGross, 0, "Upper tick should have zero liquidity");
  }

  /// @dev Full withdrawal does not clear bitmap when other liquidity remains at the same ticks
  function testFuzz_FullWithdrawalDoesNotClearBitmapWhenOtherLiquidityRemains(
    uint128 aliceLiquidity,
    uint128 bobLiquidity
  ) public {
    SharedWithdrawalCtx memory ctx;
    ctx.aliceLiquidity = _boundLiquidity(aliceLiquidity);
    ctx.bobLiquidity = _boundLiquidity(bobLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    ctx.tickLower = currentTick - 300;
    ctx.tickUpper = currentTick + 300;

    ctx.alicePositionId =
      _mintLiquidityAtTicks(alice, ctx.tickLower, ctx.tickUpper, ctx.aliceLiquidity);
    _warpToMintTime();
    _mintLiquidityAtTicks(bob, ctx.tickLower, ctx.tickUpper, ctx.bobLiquidity);

    (ctx.lowerWord, ctx.lowerBit) = _bitmapPosition(ctx.tickLower);
    (ctx.upperWord, ctx.upperBit) = _bitmapPosition(ctx.tickUpper);
    ctx.lowerWordAfterMint = hook.getTickBitmapWord(ctx.lowerWord);
    ctx.upperWordAfterMint = hook.getTickBitmapWord(ctx.upperWord);

    uint256 lowerMask = uint256(1) << ctx.lowerBit;
    uint256 upperMask = uint256(1) << ctx.upperBit;
    assertTrue((ctx.lowerWordAfterMint & lowerMask) != 0, "Lower tick bit should be set");
    assertTrue((ctx.upperWordAfterMint & upperMask) != 0, "Upper tick bit should be set");

    // Alice fully withdraws; Bob remains
    _decreaseAllLiquidity(alice, ctx.alicePositionId, ctx.aliceLiquidity);

    assertEq(
      hook.getTickBitmapWord(ctx.lowerWord),
      ctx.lowerWordAfterMint,
      "Lower bitmap word should not change"
    );
    if (ctx.upperWord != ctx.lowerWord) {
      assertEq(
        hook.getTickBitmapWord(ctx.upperWord),
        ctx.upperWordAfterMint,
        "Upper bitmap word should not change"
      );
    }

    // Tick liquidity should reflect remaining liquidity
    (uint128 lowerGross,) = hook.getTickInfo(ctx.tickLower);
    (uint128 upperGross,) = hook.getTickInfo(ctx.tickUpper);
    assertEq(lowerGross, ctx.bobLiquidity, "Lower tick gross should equal remaining liquidity");
    assertEq(upperGross, ctx.bobLiquidity, "Upper tick gross should equal remaining liquidity");
  }

  /// @dev Partial withdrawal keeps tick bitmap bits set
  function testFuzz_PartialWithdrawalKeepsBitmapSet(uint128 initialLiquidity, uint128 removeAmount)
    public
  {
    // Need at least 2e17 to leave 1e17 remaining after partial withdrawal
    initialLiquidity = uint128(bound(initialLiquidity, 2e17, 3e24));
    // Ensure we leave at least 1e17 remaining
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity - 1e17));
    vm.assume(removeAmount < initialLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 300;
    int24 tickUpper = currentTick + 300;

    (int16 lowerWord, uint8 lowerBit) = _bitmapPosition(tickLower);
    (int16 upperWord, uint8 upperBit) = _bitmapPosition(tickUpper);
    uint256 lowerWordBefore = hook.getTickBitmapWord(lowerWord);
    uint256 upperWordBefore = hook.getTickBitmapWord(upperWord);

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    uint256 lowerWordAfterMint = hook.getTickBitmapWord(lowerWord);
    uint256 upperWordAfterMint = hook.getTickBitmapWord(upperWord);
    assertNotEq(lowerWordAfterMint, lowerWordBefore, "Lower word should change on mint");
    if (upperWord != lowerWord) {
      assertNotEq(upperWordAfterMint, upperWordBefore, "Upper word should change on mint");
    }

    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);

    uint256 lowerMask = uint256(1) << lowerBit;
    uint256 upperMask = uint256(1) << upperBit;
    assertEq(
      hook.getTickBitmapWord(lowerWord), lowerWordAfterMint, "Lower bitmap word should not change"
    );
    if (upperWord != lowerWord) {
      assertEq(
        hook.getTickBitmapWord(upperWord), upperWordAfterMint, "Upper bitmap word should not change"
      );
    }
    assertTrue(
      (hook.getTickBitmapWord(lowerWord) & lowerMask) != 0,
      "Lower tick bit should remain set after partial withdrawal"
    );
    assertTrue(
      (hook.getTickBitmapWord(upperWord) & upperMask) != 0,
      "Upper tick bit should remain set after partial withdrawal"
    );
  }

  // ============ Token Transfer Tests ============

  /// @dev Decrease transfers expected token amounts and preserves token conservation.
  function testFuzz_TransfersExpectedAmountsAndConservesTotals(
    uint128 initialLiquidity,
    uint128 removeAmount
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, removeAmount);

    uint256 user0Before = token0.balanceOf(alice);
    uint256 user1Before = token1.balanceOf(alice);
    uint256 hook0Before = token0.balanceOf(address(hook));
    uint256 hook1Before = token1.balanceOf(address(hook));
    uint256 total0Before = user0Before + hook0Before;
    uint256 total1Before = user1Before + hook1Before;

    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);

    uint256 user0After = token0.balanceOf(alice);
    uint256 user1After = token1.balanceOf(alice);
    uint256 hook0After = token0.balanceOf(address(hook));
    uint256 hook1After = token1.balanceOf(address(hook));

    assertEq(int256(user0After - user0Before), expected0, "user token0 received");
    assertEq(int256(user1After - user1Before), expected1, "user token1 received");
    assertEq(int256(hook0Before - hook0After), expected0, "hook token0 debited");
    assertEq(int256(hook1Before - hook1After), expected1, "hook token1 debited");
    assertEq(user0After + hook0After, total0Before, "token0 conservation");
    assertEq(user1After + hook1After, total1Before, "token1 conservation");
  }

  // ============ Active Liquidity Tests ============

  /// @dev In-range decreases reduce active liquidity by the removed amount.
  function testFuzz_InRangeDecreaseUpdatesActiveLiquidity(
    uint128 initialLiquidity,
    uint128 removeAmount
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);
    uint128 activeBefore = hook.getActiveLiquidity();

    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);

    assertEq(hook.getActiveLiquidity(), activeBefore - removeAmount, "active liquidity decrease");
  }

  /// @dev Out-of-range decreases do not change active liquidity.
  function testFuzz_OutOfRangeDecreaseDoesNotUpdateActiveLiquidity(
    uint128 initialLiquidity,
    uint128 removeAmount,
    uint8 scenario
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    uint8 boundedScenario = uint8(bound(scenario, 0, 1));
    RangeScenario rangeScenario =
      boundedScenario == 0 ? RangeScenario.BelowCurrent : RangeScenario.AboveCurrent;
    (int24 tickLower, int24 tickUpper) = _standardRange(rangeScenario);

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);
    uint128 activeBefore = hook.getActiveLiquidity();

    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);

    assertEq(hook.getActiveLiquidity(), activeBefore, "active liquidity unchanged");
  }

  // ============ Multiple Operations Tests ============

  /// @dev Multiple decreases on one position add up to the same final state.
  function testFuzz_MultipleDecreasesAccumulateLiquidity(
    uint128 initialLiquidity,
    uint128 decrease1,
    uint128 decrease2
  ) public {
    // Need at least 3e17 so that maxDecrease >= 1e17
    initialLiquidity = uint128(bound(initialLiquidity, 3e17, 3e24));
    // Ensure we can do two decreases
    uint128 maxDecrease = initialLiquidity / 3;
    decrease1 = uint128(bound(decrease1, 1e17, maxDecrease));
    decrease2 = uint128(bound(decrease2, 1e17, maxDecrease));

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    vm.startPrank(alice);
    hook.decreaseLiquidity(positionId, -int128(decrease1), 0, 0);
    hook.decreaseLiquidity(positionId, -int128(decrease2), 0, 0);
    vm.stopPrank();

    (,,, int128 remainingLiquidity) = hook.getPositionInfo(positionId);
    assertEq(
      uint128(remainingLiquidity),
      initialLiquidity - decrease1 - decrease2,
      "Position liquidity should equal initial minus all decreases"
    );

    (uint128 lowerGross,) = hook.getTickInfo(tickLower);
    assertEq(
      lowerGross,
      initialLiquidity - decrease1 - decrease2,
      "Tick liquidity should equal initial minus all decreases"
    );
  }

  /// @dev Decrease then increase is symmetric (same token amounts)
  function testFuzz_DecreaseIncreaseSymmetry(uint128 baseAmount, uint128 deltaAmount) public {
    // Need at least 2e17 so that baseAmount / 2 >= 1e17
    baseAmount = uint128(bound(baseAmount, 2e17, 3e24));
    deltaAmount = uint128(bound(deltaAmount, 1e17, baseAmount / 2));

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, baseAmount);

    uint256 balance0Before = token0.balanceOf(alice);
    uint256 balance1Before = token1.balanceOf(alice);

    vm.startPrank(alice);
    hook.decreaseLiquidity(positionId, -int128(deltaAmount), 0, 0);
    hook.increaseLiquidity(positionId, deltaAmount, type(uint256).max, type(uint256).max);
    vm.stopPrank();

    (,,, int128 finalLiquidity) = hook.getPositionInfo(positionId);
    assertEq(token0.balanceOf(alice), balance0Before, "token0 symmetric");
    assertEq(token1.balanceOf(alice), balance1Before, "token1 symmetric");
    assertEq(uint128(finalLiquidity), baseAmount, "liquidity restored");
  }

  /// @dev Different users can decrease independent positions in the same range.
  function testFuzz_MultipleUsersDecreaseIndependentPositions(
    uint128 aliceInitial,
    uint128 aliceDecrease
  ) public {
    aliceInitial = _boundLiquidity(aliceInitial);
    aliceDecrease = uint128(bound(aliceDecrease, 1e17, aliceInitial));
    uint128 bobInitial = 1e18;
    uint128 bobDecrease = 5e17;

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);

    bytes32 alicePositionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, aliceInitial);
    bytes32 bobPositionId = _mintLiquidityAtTicks(bob, tickLower, tickUpper, bobInitial);

    vm.prank(alice);
    hook.decreaseLiquidity(alicePositionId, -int128(aliceDecrease), 0, 0);

    vm.prank(bob);
    hook.decreaseLiquidity(bobPositionId, -int128(bobDecrease), 0, 0);

    (,,, int128 aliceLiq) = hook.getPositionInfo(alicePositionId);
    (,,, int128 bobLiq) = hook.getPositionInfo(bobPositionId);

    assertEq(uint128(aliceLiq), aliceInitial - aliceDecrease, "Alice liquidity should match");
    assertEq(uint128(bobLiq), bobInitial - bobDecrease, "Bob liquidity should match");

    (uint128 lowerGross,) = hook.getTickInfo(tickLower);
    uint128 expectedTotal = (aliceInitial - aliceDecrease) + (bobInitial - bobDecrease);
    assertEq(lowerGross, expectedTotal, "Tick should have combined remaining liquidity");
  }

  // ============ Token Amount Tests Based on Position ============

  /// @dev Below-current positions return only token0 on decrease.
  function testFuzz_BelowCurrentRangeDecreaseReturnsOnlyToken0(
    uint128 initialLiquidity,
    uint128 removeAmount
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.BelowCurrent);

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, removeAmount);

    uint256 balance0Before = token0.balanceOf(alice);
    uint256 balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);

    assertGt(expected0, 0, "expected token0");
    assertEq(expected1, 0, "expected token1");
    assertEq(int256(token0.balanceOf(alice) - balance0Before), expected0, "token0 received");
    assertEq(int256(token1.balanceOf(alice) - balance1Before), expected1, "token1 received");
  }

  /// @dev Above-current positions return only token1 on decrease.
  function testFuzz_AboveCurrentRangeDecreaseReturnsOnlyToken1(
    uint128 initialLiquidity,
    uint128 removeAmount
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.AboveCurrent);

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, removeAmount);

    uint256 balance0Before = token0.balanceOf(alice);
    uint256 balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);

    assertEq(expected0, 0, "expected token0");
    assertGt(expected1, 0, "expected token1");
    assertEq(int256(token0.balanceOf(alice) - balance0Before), expected0, "token0 received");
    assertEq(int256(token1.balanceOf(alice) - balance1Before), expected1, "token1 received");
  }

  /// @dev In-range positions return both tokens on decrease.
  function testFuzz_InRangeDecreaseReturnsBothTokens(uint128 initialLiquidity, uint128 removeAmount)
    public
  {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, removeAmount);

    uint256 balance0Before = token0.balanceOf(alice);
    uint256 balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);

    assertGt(expected0, 0, "expected token0");
    assertGt(expected1, 0, "expected token1");
    assertEq(int256(token0.balanceOf(alice) - balance0Before), expected0, "token0 received");
    assertEq(int256(token1.balanceOf(alice) - balance1Before), expected1, "token1 received");
  }

  /// @dev For the same in-range burn size, token0 stays constant while token1 changes with time.
  function test_DecreaseCashReturnedChangesWithTime_ForInRangePosition() public {
    uint128 initialLiquidity = 1e24;
    uint128 removeAmount = 5e23;

    (int24 tickLower, int24 tickUpper) =
      _rangeForScenario(hook.getCurrentTick(), RangeScenario.InRange, 200);

    _warpFromStart(1);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);
    uint256 snapshot = vm.snapshot();

    _warpFromStart(1);
    Amounts memory expectedAtT1;
    {
      (int256 e0, int256 e1) = _expectedMintAmounts(tickLower, tickUpper, removeAmount);
      expectedAtT1.amount0 = e0;
      expectedAtT1.amount1 = e1;
    }
    Amounts memory receivedAtT1;
    {
      (uint256 received0, uint256 received1) = _decreaseLiquidity(alice, positionId, removeAmount);
      receivedAtT1.amount0 = int256(received0);
      receivedAtT1.amount1 = int256(received1);
    }

    vm.revertTo(snapshot);

    _warpFromStart(30 days);
    Amounts memory expectedAtT2;
    {
      (int256 e0, int256 e1) = _expectedMintAmounts(tickLower, tickUpper, removeAmount);
      expectedAtT2.amount0 = e0;
      expectedAtT2.amount1 = e1;
    }
    Amounts memory receivedAtT2;
    {
      (uint256 received0, uint256 received1) = _decreaseLiquidity(alice, positionId, removeAmount);
      receivedAtT2.amount0 = int256(received0);
      receivedAtT2.amount1 = int256(received1);
    }

    assertEq(receivedAtT1.amount0, expectedAtT1.amount0, "t1 token0");
    assertEq(receivedAtT1.amount1, expectedAtT1.amount1, "t1 token1");
    assertEq(receivedAtT2.amount0, expectedAtT2.amount0, "t2 token0");
    assertEq(receivedAtT2.amount1, expectedAtT2.amount1, "t2 token1");
    assertEq(expectedAtT2.amount0, expectedAtT1.amount0, "principal invariant");
    assertNotEq(expectedAtT2.amount1, expectedAtT1.amount1, "cash changes over time");
  }

  // ============ Slippage Tests ============

  /// @dev Decrease succeeds when min amounts equal the exact returned amounts.
  function testFuzz_AllowsWhen_MinTokenAmountsEqualReturnedAmounts(
    uint128 initialLiquidity,
    uint128 removeAmount
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, removeAmount);

    vm.prank(alice);
    hook.decreaseLiquidity(
      positionId, -int128(removeAmount), uint256(expected0), uint256(expected1)
    );

    (,,, int128 remainingLiquidity) = hook.getPositionInfo(positionId);
    assertEq(uint128(remainingLiquidity), initialLiquidity - removeAmount, "liquidity decreased");
  }

  // ============ Revert Tests ============

  /// @dev Reverts when position not found
  function test_RevertWhen_PositionNotFound() public {
    bytes32 missingPositionId = keccak256("missing position");

    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__PositionNotFound.selector);
    hook.decreaseLiquidity(missingPositionId, -1e18, 0, 0);
  }

  /// @dev Reverts when caller is not position owner
  function testFuzz_RevertWhen_NotPositionOwner(uint128 initialLiquidity, uint128 removeAmount)
    public
  {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    vm.prank(bob);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__NotPositionOwner.selector);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);
  }

  /// @dev Reverts when min token0 exceeds what a below-current decrease can return.
  function testFuzz_RevertWhen_BelowCurrentToken0SlippageExceeded(
    uint128 initialLiquidity,
    uint128 removeAmount
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.BelowCurrent);

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 expected0,) = _expectedMintAmounts(tickLower, tickUpper, removeAmount);

    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidLiquidityAmount.selector);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), uint256(expected0) + 1, 0);
  }

  /// @dev Reverts when min token1 exceeds what an above-current decrease can return.
  function testFuzz_RevertWhen_AboveCurrentToken1SlippageExceeded(
    uint128 initialLiquidity,
    uint128 removeAmount
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.AboveCurrent);

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, removeAmount);

    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidLiquidityAmount.selector);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, uint256(expected1) + 1);
  }

  /// @dev Reverts when token0 amount is below min (in-range position)
  function testFuzz_RevertWhen_InRangeToken0SlippageExceeded(
    uint128 initialLiquidity,
    uint128 removeAmount
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 expected0,) = _expectedMintAmounts(tickLower, tickUpper, removeAmount);

    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidLiquidityAmount.selector);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), uint256(expected0) + 1, 0);
  }

  /// @dev Reverts when token1 amount is below min (in-range position)
  function testFuzz_RevertWhen_InRangeToken1SlippageExceeded(
    uint128 initialLiquidity,
    uint128 removeAmount
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, removeAmount);

    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidLiquidityAmount.selector);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, uint256(expected1) + 1);
  }

  // ============ Fuzzed Time Tests ============

  /// @dev Decrease at any valid time preserves conservation and updates liquidity.
  function testFuzz_DecreaseMaintainsConservationAtAnyTime(
    uint128 initialLiquidity,
    uint128 removeAmount,
    uint256 timeElapsed
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));
    timeElapsed = bound(timeElapsed, 1, MARKET_LENGTH - 1);
    _warpFromStart(timeElapsed);

    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    uint256 total0Before = token0.balanceOf(alice) + token0.balanceOf(address(hook));
    uint256 total1Before = token1.balanceOf(alice) + token1.balanceOf(address(hook));

    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);

    (,,, int128 remainingLiquidity) = hook.getPositionInfo(positionId);
    uint256 total0After = token0.balanceOf(alice) + token0.balanceOf(address(hook));
    uint256 total1After = token1.balanceOf(alice) + token1.balanceOf(address(hook));

    assertEq(uint128(remainingLiquidity), initialLiquidity - removeAmount, "liquidity decrease");
    assertEq(total0After, total0Before, "token0 conservation");
    assertEq(total1After, total1Before, "token1 conservation");
  }

  function test_EmitsLiquidityModified_OnDecrease() public {
    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);
    uint128 liquidity = 1e20;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, liquidity);

    uint128 removeAmount = 5e19;

    vm.expectEmit(true, true, false, false, address(hook));
    emit FixedFeeSwapMarket.LiquidityModified(positionId, alice, tickLower, tickUpper, 0, 0, 0);

    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);
  }

  function test_RevertWhen_LiquidityDeltaIsZero_OnDecrease() public {
    _warpToMintTime();
    (int24 tickLower, int24 tickUpper) = _standardRange(RangeScenario.InRange);

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, 1e20);

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__LiquidityDeltaMustBeNegative.selector);
    vm.prank(alice);
    hook.decreaseLiquidity(positionId, 0, 0, 0);
  }
}

contract _BeforeSwap is FixedFeeSwapMarketTest {
  using FixedPointMathLib for int256;

  PoolKey internal poolKey;
  SwapParams internal defaultSwapParams;

  function setUp() public virtual override {
    super.setUp();

    // Create a mock pool key - only the hooks field matters for _beforeSwap
    poolKey = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 0,
      tickSpacing: 1,
      hooks: IHooks(address(hook))
    });

    // Default swap params (ignored by our hook, but required)
    defaultSwapParams = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

    // Add liquidity for swap tests and move tick to 100 so below-range positions are possible
    _moveTickTo(100);
    // Main liquidity spanning a wide range
    _mintLiquidityAtTicks(alice, 0, 2000, 1e22);
  }

  // ============ Helper Functions ============

  function _encodeHookParams(int256 amountIn, bool principalForCash, int24 tickLimit)
    internal
    pure
    returns (bytes memory)
  {
    return abi.encode(amountIn, principalForCash, tickLimit);
  }

  function _swap(address sender, int256 amountIn, bool principalForCash, int24 tickLimit)
    internal
    returns (bytes4, BeforeSwapDelta, uint24)
  {
    bytes memory hookParams = _encodeHookParams(amountIn, principalForCash, tickLimit);
    return hook.exposed_beforeSwap(sender, poolKey, defaultSwapParams, hookParams);
  }

  function _ptForOneBip() internal view returns (uint256) {
    return uint256(hook.getActiveLiquidity()) / BIPS;
  }

  function _initializePrice() internal returns (int256) {
    if (hook.getCurrentPrice() != 0) return hook.getCurrentPrice();

    _swap(bob, 1, true, hook.getCurrentTick());

    int256 price = hook.getCurrentPrice();
    assertTrue(price > 0, "Price must be initialized");
    return price;
  }

  function _assertApproxEqRelBps(uint256 a, uint256 b, uint256 toleranceBps, string memory err)
    internal
    pure
  {
    if (a == 0 && b == 0) return;
    uint256 diff = a > b ? a - b : b - a;
    uint256 maxVal = a > b ? a : b;
    uint256 maxDiff = (maxVal * toleranceBps) / BIPS;
    assertTrue(diff <= maxDiff, err);
  }

  // ============ Token Transfer Tests ============

  /// @dev Principal for cash: user sends TOKEN0, receives TOKEN1
  function testFuzz_PrincipalForCash_TransfersCorrectTokens(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);

    uint256 balance0Before = token0.balanceOf(bob);
    uint256 balance1Before = token1.balanceOf(bob);
    uint256 hookBalance0Before = token0.balanceOf(address(hook));
    uint256 hookBalance1Before = token1.balanceOf(address(hook));

    _swap(bob, int256(amountIn), true, NO_TICK_LIMIT);

    // Sub-tick swaps may produce zero output; skip those runs
    uint256 consumed = balance0Before - token0.balanceOf(bob);
    vm.assume(consumed > 0);

    assertGt(token1.balanceOf(bob), balance1Before, "User should receive TOKEN1");
    assertGt(token0.balanceOf(address(hook)), hookBalance0Before, "Hook should receive TOKEN0");
    assertLe(token1.balanceOf(address(hook)), hookBalance1Before, "Hook should send TOKEN1 or same");
  }

  /// @dev Cash for principal: user sends TOKEN1, receives TOKEN0
  function testFuzz_CashForPrincipal_TransfersCorrectTokens(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);

    uint256 balance0Before = token0.balanceOf(bob);
    uint256 balance1Before = token1.balanceOf(bob);

    _swap(bob, int256(amountIn), false, NO_TICK_LIMIT);

    // Sub-tick swaps may produce zero output; skip those runs
    vm.assume(token0.balanceOf(bob) > balance0Before);

    assertLt(token1.balanceOf(bob), balance1Before, "User should send TOKEN1");
  }

  /// @dev Token conservation: no tokens created or destroyed in either direction.
  function testFuzz_TokenConservation_IsMaintainedInBothDirections(
    uint256 amountIn,
    bool principalForCash
  ) public {
    amountIn = _boundSwapAmount(amountIn);

    uint256 totalSupply0Before =
      token0.balanceOf(alice) + token0.balanceOf(bob) + token0.balanceOf(address(hook));
    uint256 totalSupply1Before =
      token1.balanceOf(alice) + token1.balanceOf(bob) + token1.balanceOf(address(hook));

    _swap(bob, int256(amountIn), principalForCash, NO_TICK_LIMIT);

    uint256 totalSupply0After =
      token0.balanceOf(alice) + token0.balanceOf(bob) + token0.balanceOf(address(hook));
    uint256 totalSupply1After =
      token1.balanceOf(alice) + token1.balanceOf(bob) + token1.balanceOf(address(hook));

    assertEq(totalSupply0After, totalSupply0Before, "TOKEN0 supply should be conserved");
    assertEq(totalSupply1After, totalSupply1Before, "TOKEN1 supply should be conserved");
  }

  /// @dev Input consumed never exceeds amountSpecified in either direction.
  function testFuzz_InputConsumed_DoesNotExceedAmountSpecified(
    uint256 amountIn,
    bool principalForCash
  ) public {
    amountIn = _boundSwapAmount(amountIn);

    uint256 balanceBefore = principalForCash ? token0.balanceOf(bob) : token1.balanceOf(bob);

    _swap(bob, int256(amountIn), principalForCash, NO_TICK_LIMIT);

    uint256 balanceAfter = principalForCash ? token0.balanceOf(bob) : token1.balanceOf(bob);
    uint256 consumed = balanceBefore - balanceAfter;
    // Sub-tick swaps may return zero due to integer-tick snapping
    vm.assume(consumed > 0);
    assertLe(consumed, amountIn, "Consumed should not exceed amountIn");
  }

  // ============ State Update Tests ============

  /// @dev currentTick moves in the expected direction and by a bounded amount.
  function testFuzz_CurrentTickMovesInExpectedDirection(uint256 amountIn, bool principalForCash)
    public
  {
    amountIn = _boundSwapAmount(amountIn);

    int24 tickBefore = hook.getCurrentTick();
    uint128 activeLiq = hook.getActiveLiquidity();

    _swap(bob, int256(amountIn), principalForCash, NO_TICK_LIMIT);

    int24 tickAfter = hook.getCurrentTick();
    // Magnitude bound: tick should not move more than amountIn * BIPS / activeLiquidity + 2
    int24 maxTickMove = int24(int256(amountIn * BIPS / uint256(activeLiq))) + 2;

    if (principalForCash) {
      assertGe(tickAfter, tickBefore, "Tick should increase for principal->cash");
      assertLe(tickAfter - tickBefore, maxTickMove, "Tick should not move more than expected");
      return;
    }

    assertLe(tickAfter, tickBefore, "Tick should decrease for cash->principal");
    assertLe(tickBefore - tickAfter, maxTickMove, "Tick should not move more than expected");
  }

  /// @dev currentPrice moves in the expected direction in both directions.
  function testFuzz_CurrentPriceMovesInExpectedDirection(uint256 amountIn, bool principalForCash)
    public
  {
    amountIn = _boundSwapAmount(amountIn);

    // Use tick-derived price to avoid stale stored price from different timestamps.
    int256 priceBefore = hook.tickToPrice(hook.getCurrentTick());

    _swap(bob, int256(amountIn), principalForCash, NO_TICK_LIMIT);

    int256 priceAfter = hook.getCurrentPrice();
    if (principalForCash) {
      assertLe(priceAfter, priceBefore, "Price should decrease for principal->cash");
      return;
    }
    assertGe(priceAfter, priceBefore, "Price should increase for cash->principal");
  }

  /// @dev Active liquidity unchanged when not crossing ticks
  function testFuzz_WithinTickSwap_DoesNotUpdateActiveLiquidity(uint256 amountIn) public {
    // Use small amount to stay within current tick range
    amountIn = bound(amountIn, 1e15, 1e17);

    uint128 activeBefore = hook.getActiveLiquidity();

    _swap(bob, int256(amountIn), true, NO_TICK_LIMIT);

    // If no tick was crossed, active liquidity should be unchanged
    // (This may not hold if the swap crosses a tick boundary)
    uint128 activeAfter = hook.getActiveLiquidity();
    assertEq(activeAfter, activeBefore, "Active liquidity unchanged within tick");
  }

  // Within-tick sub-bip tests removed: with integer-tick snapping, sub-bip swaps
  // produce zero output by design. This is correct AMM behavior — the small surplus
  // stays in the contract as a rounding buffer for solvency.

  // ============ Tick Crossing Tests ============

  /// @dev Crossing tick updates active liquidity
  function test_CrossingTickUpdatesActiveLiquidity() public {
    // Setup: narrow position that we'll cross out of
    uint128 narrowLiquidity = 1e21;
    int24 currentTick = hook.getCurrentTick();
    _mintLiquidityAtTicks(alice, currentTick - 10, currentTick + 10, narrowLiquidity);

    uint128 activeBefore = hook.getActiveLiquidity();
    uint256 swapAmount = uint256(activeBefore) * 11 / BIPS; // > 10 ticks worth of principal
    _swap(bob, int256(swapAmount), true, NO_TICK_LIMIT);

    assertGe(int256(hook.getCurrentTick()), int256(currentTick + 10), "Should cross upper tick");
    assertLt(
      uint256(hook.getActiveLiquidity()), uint256(activeBefore), "Active liquidity should decrease"
    );
  }

  /// @dev Multiple positions at different tick ranges
  function test_MultipleTickCrossings() public {
    // Setup positions at multiple tick ranges
    int24 currentTick = hook.getCurrentTick();
    _mintLiquidityAtTicks(alice, 0, currentTick, 1e20);
    _mintLiquidityAtTicks(alice, currentTick, currentTick + 200, 1e20);
    _mintLiquidityAtTicks(alice, currentTick + 200, currentTick + 300, 1e20);

    int24 tickBefore = hook.getCurrentTick();

    // Move far enough to cross multiple initialized ticks in this word.
    uint256 swapAmount = uint256(hook.getActiveLiquidity()) * 400 / BIPS;
    _swap(bob, int256(swapAmount), true, NO_TICK_LIMIT);

    int24 tickAfter = hook.getCurrentTick();
    assertGt(int256(tickAfter), int256(tickBefore), "Tick should increase");
    assertGe(int256(tickAfter), int256(currentTick + 200), "Should cross upper positions");
  }

  /// @dev Swap into position from below increases active liquidity
  function test_CrossingIntoPositionIncreasesLiquidity() public {
    // Create position above current tick
    int24 currentTick = hook.getCurrentTick();
    _mintLiquidityAtTicks(alice, currentTick + 50, currentTick + 150, 1e20);

    uint128 activeBefore = hook.getActiveLiquidity();

    // Cross into the position by crossing its lower tick.
    uint256 swapAmount = uint256(activeBefore) * 60 / BIPS;
    _swap(bob, int256(swapAmount), true, NO_TICK_LIMIT);

    assertGe(
      int256(hook.getCurrentTick()), int256(currentTick + 50), "Should cross into the new position"
    );
    assertGt(
      uint256(hook.getActiveLiquidity()), uint256(activeBefore), "Active liquidity should increase"
    );
  }

  /// @dev Crossing an uninitialized word boundary should not change active liquidity.
  /// @notice Uses the fact that only ticks ±1000 are initialized in `setUp`, so the first "next
  /// tick" to the right from tick 0 is the uninitialized word edge at tick 255.
  function testFuzz_CrossingUninitializedBoundaryDoesNotChangeActiveLiquidity(uint128 extraLiquidity)
    public
  {
    extraLiquidity = uint128(bound(uint256(extraLiquidity), 1e18, 1e22));
    _mintLiquidityAtTicks(alice, 0, 2000, extraLiquidity);

    uint128 activeBefore = hook.getActiveLiquidity();
    int24 tickBefore = hook.getCurrentTick();
    int256 priceBefore = hook.tickToPrice(tickBefore);

    // Pick the next uninitialized word boundary above current tick
    int24 nextTick = int24((int256(tickBefore) / 256 + 1) * 256 - 1);
    (uint256 principalInToBoundary,, int256 boundaryPrice, int24 stepTick) =
      hook.exposed_getCashSwapAmount(int256(1e36), priceBefore, nextTick);

    _swap(bob, int256(principalInToBoundary), true, NO_TICK_LIMIT);

    assertEq(stepTick, nextTick, "Should step to the word boundary tick");
    assertEq(hook.getCurrentTick(), nextTick, "Should land on the boundary tick");
    assertEq(hook.getCurrentPrice(), boundaryPrice, "Price should move to the boundary price");
    assertEq(hook.getActiveLiquidity(), activeBefore, "Active liquidity should be unchanged");
  }

  /// @dev Crossing the upper tick of a below-range position (cash->principal, moving left)
  /// increases liquidity.
  function testFuzz_CashForPrincipal_CrossingUpperTickIncreasesActiveLiquidity(uint128 belowRangeLiquidity)
    public
  {
    belowRangeLiquidity = uint128(bound(uint256(belowRangeLiquidity), 1e18, 1e22));
    int24 currentTick = hook.getCurrentTick();
    int24 belowLower = currentTick - 20;
    int24 belowUpper = currentTick - 10;
    _mintLiquidityAtTicks(alice, belowLower, belowUpper, belowRangeLiquidity);

    uint128 activeBefore = hook.getActiveLiquidity();
    int256 priceBefore = hook.tickToPrice(currentTick);

    (uint256 cashInToBoundary,, int256 boundaryPrice, int24 stepTick) =
      hook.exposed_getPrincipalSwapAmount(int256(1e36), priceBefore, belowUpper);

    uint256 balance1Before = token1.balanceOf(bob);
    _swap(bob, int256(cashInToBoundary), false, NO_TICK_LIMIT);

    assertEq(stepTick, belowUpper, "Should step to upper tick");
    assertEq(
      balance1Before - token1.balanceOf(bob), cashInToBoundary, "Should consume cash to boundary"
    );
    assertEq(hook.getCurrentPrice(), boundaryPrice, "Price should move to boundary price");
    assertEq(hook.getCurrentTick(), belowUpper, "Moving left leaves tick at boundary");
    assertEq(
      uint256(hook.getActiveLiquidity()),
      uint256(activeBefore) + uint256(belowRangeLiquidity),
      "Active liquidity should increase"
    );
  }

  /// @dev Crossing the lower tick of an in-range position (cash->principal, moving left) decreases
  /// liquidity.
  function testFuzz_CashForPrincipal_CrossingLowerTickDecreasesActiveLiquidity(uint128 narrowLiquidity)
    public
  {
    narrowLiquidity = uint128(bound(uint256(narrowLiquidity), 1e18, 1e22));
    int24 currentTick = hook.getCurrentTick();
    int24 narrowLower = currentTick - 10;
    int24 narrowUpper = currentTick + 10;
    _mintLiquidityAtTicks(alice, narrowLower, narrowUpper, narrowLiquidity);

    uint128 activeBefore = hook.getActiveLiquidity();
    int256 priceBefore = hook.tickToPrice(currentTick);

    (uint256 cashInToBoundary,, int256 boundaryPrice, int24 stepTick) =
      hook.exposed_getPrincipalSwapAmount(int256(1e36), priceBefore, narrowLower);

    uint256 balance1Before = token1.balanceOf(bob);
    _swap(bob, int256(cashInToBoundary), false, NO_TICK_LIMIT);

    assertEq(stepTick, narrowLower, "Should step to lower tick");
    assertEq(
      balance1Before - token1.balanceOf(bob), cashInToBoundary, "Should consume cash to boundary"
    );
    assertEq(hook.getCurrentPrice(), boundaryPrice, "Price should move to boundary price");
    assertEq(hook.getCurrentTick(), narrowLower, "Moving left leaves tick at boundary");
    assertEq(
      uint256(hook.getActiveLiquidity()),
      uint256(activeBefore) - uint256(narrowLiquidity),
      "Active liquidity should decrease"
    );
  }

  // ============ Tick Limit Tests ============

  /// @dev Tick limit can stop swaps early in either direction.
  function testFuzz_TickLimitStopsSwapBeforeConsumingAllInput(
    uint256 amountIn,
    bool principalForCash
  ) public {
    amountIn = bound(amountIn, 1e17, 1e20);

    int24 currentTick = hook.getCurrentTick();
    int24 tickLimit = principalForCash ? currentTick + 10 : currentTick - 10;

    uint256 balanceBefore = principalForCash ? token0.balanceOf(bob) : token1.balanceOf(bob);

    _swap(bob, int256(amountIn), principalForCash, tickLimit);

    // Might not consume full amountIn due to limit
    uint256 balanceAfter = principalForCash ? token0.balanceOf(bob) : token1.balanceOf(bob);
    uint256 consumed = balanceBefore - balanceAfter;
    assertLe(consumed, amountIn, "Should not exceed amountIn");

    // Only check the limit if the swap actually produced output
    if (consumed > 0 && consumed < amountIn) {
      int24 finalTick = hook.getCurrentTick();
      if (principalForCash) {
        assertLe(finalTick, tickLimit, "Tick should be at or below limit");
        return;
      }
      assertGe(finalTick, tickLimit, "Tick should be at or above limit");
    }
  }

  function test_TickLimitStopsSwap_PrincipalForCash_StopsExactlyAtLimit() public {
    _warpFromStart(MARKET_LENGTH / 2);
    _initializePrice();

    int24 limitTick = 250;
    uint256 amountIn = (uint256(hook.getActiveLiquidity()) * 260) / BIPS;

    uint256 balance0Before = token0.balanceOf(bob);
    _swap(bob, int256(amountIn), true, limitTick);

    uint256 consumed = balance0Before - token0.balanceOf(bob);
    assertLt(consumed, amountIn, "Should stop early due to tick limit");
    assertLe(hook.getCurrentTick(), limitTick, "Tick should be at or below limit");
  }

  /// @dev If the tick limit is already satisfied at entry, the swap should be a no-op (except lazy
  /// price init).
  function testFuzz_TickLimitAlreadySatisfied_ReturnsNoOp(uint256 amountIn, bool principalForCash)
    public
  {
    amountIn = _boundSwapAmount(amountIn);
    int24 tickBefore = hook.getCurrentTick();
    uint128 activeBefore = hook.getActiveLiquidity();
    int256 expectedPrice = hook.tickToPrice(tickBefore);

    uint256 balance0Before = token0.balanceOf(bob);
    uint256 balance1Before = token1.balanceOf(bob);
    uint256 hookBalance0Before = token0.balanceOf(address(hook));
    uint256 hookBalance1Before = token1.balanceOf(address(hook));

    (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
      _swap(bob, int256(amountIn), principalForCash, tickBefore);

    assertEq(selector, BaseHook.beforeSwap.selector, "Selector");
    assertEq(BeforeSwapDelta.unwrap(delta), 0, "Delta");
    assertEq(fee, 0, "Fee");

    assertEq(hook.getCurrentTick(), tickBefore, "Tick unchanged");
    assertEq(hook.getActiveLiquidity(), activeBefore, "Liquidity unchanged");
    assertEq(hook.getCurrentPrice(), expectedPrice, "Price initialized");

    assertEq(token0.balanceOf(bob), balance0Before, "TOKEN0 unchanged");
    assertEq(token1.balanceOf(bob), balance1Before, "TOKEN1 unchanged");
    assertEq(token0.balanceOf(address(hook)), hookBalance0Before, "Hook TOKEN0 unchanged");
    assertEq(token1.balanceOf(address(hook)), hookBalance1Before, "Hook TOKEN1 unchanged");
  }

  /// @dev NO_TICK_LIMIT allows consuming all input in both directions.
  function testFuzz_NoTickLimitConsumesEntireInput(uint256 amountIn, bool principalForCash) public {
    // Use amounts large enough to always move a tick (2 bips covers exp/ln rounding)
    amountIn = bound(amountIn, _ptForOneBip() * 2, 100e18);

    uint256 balanceBefore = principalForCash ? token0.balanceOf(bob) : token1.balanceOf(bob);

    _swap(bob, int256(amountIn), principalForCash, NO_TICK_LIMIT);

    uint256 balanceAfter = principalForCash ? token0.balanceOf(bob) : token1.balanceOf(bob);
    uint256 consumed = balanceBefore - balanceAfter;
    assertEq(consumed, amountIn, "Full amount should be consumed with no tick limit");
  }

  function test_TickLimitStopsSwap_CashForPrincipal_StopsExactlyAtLimit() public {
    _warpFromStart(MARKET_LENGTH / 2);
    _initializePrice();

    // Move yield positive so cash->principal has room to move back.
    _swap(bob, int256(_ptForOneBip() * 100), true, NO_TICK_LIMIT);

    // Limit at tick 50 (between current tick ~100 and tick 0).
    // Use ~500 bips of cash — well more than needed to cross 50 ticks,
    // ensuring the limit stops the swap before all input is consumed.
    int24 limitTick = 50;
    uint256 amountIn = (uint256(hook.getActiveLiquidity()) * 500) / BIPS;

    uint256 balance1Before = token1.balanceOf(bob);
    _swap(bob, int256(amountIn), false, limitTick);

    uint256 consumed = balance1Before - token1.balanceOf(bob);
    assertLt(consumed, amountIn, "Should stop early due to tick limit");
    assertGe(hook.getCurrentTick(), limitTick, "Tick should be at or above limit");
  }

  // ============ Edge Case Tests ============

  /// @dev Empty hookParams returns early (no-op)
  function test_EmptyHookParamsReturnsEarly() public {
    uint256 balance0Before = token0.balanceOf(bob);
    uint256 balance1Before = token1.balanceOf(bob);
    uint256 hookBalance0Before = token0.balanceOf(address(hook));
    uint256 hookBalance1Before = token1.balanceOf(address(hook));

    (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
      hook.exposed_beforeSwap(bob, poolKey, defaultSwapParams, "");

    // Should return the correct selector
    assertEq(selector, BaseHook.beforeSwap.selector, "Should return beforeSwap selector");

    // No tokens should be transferred
    assertEq(token0.balanceOf(bob), balance0Before, "TOKEN0 unchanged");
    assertEq(token1.balanceOf(bob), balance1Before, "TOKEN1 unchanged");
    assertEq(token0.balanceOf(address(hook)), hookBalance0Before, "Hook TOKEN0 unchanged");
    assertEq(token1.balanceOf(address(hook)), hookBalance1Before, "Hook TOKEN1 unchanged");
    assertEq(BeforeSwapDelta.unwrap(delta), 0, "Delta should be zero");
    assertEq(fee, 0, "Fee should be zero");
  }

  /// @dev Swap near maturity
  function test_SwapNearMaturity() public {
    // Warp to near maturity
    uint48 maturity = hook.getMaturity();
    vm.warp(maturity - 1);

    // Use at least 1 bip to ensure output with integer-tick snapping
    uint256 swapAmount = _ptForOneBip();
    uint256 balance0Before = token0.balanceOf(bob);

    _swap(bob, int256(swapAmount), true, NO_TICK_LIMIT);

    assertLt(token0.balanceOf(bob), balance0Before, "Swap should work near maturity");
  }

  /// @dev Minimum swap amount — must be at least 1 bip to produce output with integer-tick
  /// snapping
  function test_MinimumSwapAmount() public {
    // 1 bip of PT = L / BIPS — the minimum to move a full tick
    uint256 minAmount = _ptForOneBip();

    uint256 balance0Before = token0.balanceOf(bob);

    _swap(bob, int256(minAmount), true, NO_TICK_LIMIT);

    uint256 consumed = balance0Before - token0.balanceOf(bob);
    assertGt(consumed, 0, "Minimum swap should consume some input");
  }

  /// @dev Sequential swaps in same direction
  function testFuzz_SequentialSwaps_SameDirection(uint256 amount1, uint256 amount2) public {
    amount1 = _boundSwapAmount(amount1);
    amount2 = _boundSwapAmount(amount2);

    int24 tickBefore = hook.getCurrentTick();

    _swap(bob, int256(amount1), true, NO_TICK_LIMIT);
    int24 tickAfter1 = hook.getCurrentTick();

    _swap(bob, int256(amount2), true, NO_TICK_LIMIT);
    int24 tickAfter2 = hook.getCurrentTick();

    // Each swap should increase tick (or stay same)
    assertGe(tickAfter1, tickBefore, "First swap increases tick");
    assertGe(tickAfter2, tickAfter1, "Second swap increases tick further");
  }

  /// @dev Sequential swaps in opposite directions
  function testFuzz_SequentialSwaps_OppositeDirections(
    uint256 amount1,
    uint256 amount2,
    uint256 timeElapsed
  ) public {
    amount1 = bound(amount1, 1e15, 1e18);
    amount2 = bound(amount2, 1e15, 1e18);
    timeElapsed = bound(timeElapsed, 1 days, MARKET_LENGTH - 1);
    _warpFromStart(timeElapsed);

    int24 tickBefore = hook.getCurrentTick();

    // Swap principal for cash (tick increases)
    _swap(bob, int256(amount1), true, NO_TICK_LIMIT);
    int24 tickAfter1 = hook.getCurrentTick();

    // Swap cash for principal (tick decreases)
    _swap(bob, int256(amount2), false, NO_TICK_LIMIT);
    int24 tickAfter2 = hook.getCurrentTick();

    // First swap increases, second decreases
    assertGe(tickAfter1, tickBefore, "First swap increases tick");
    assertLe(tickAfter2, tickAfter1, "Second swap decreases tick");
  }

  /// @dev Different users can swap
  function testFuzz_MultipleUsersSwap(uint256 amountAlice, uint256 amountBob) public {
    // Use amounts large enough to always move at least 1 tick (2 bips covers exp/ln rounding)
    amountAlice = bound(amountAlice, _ptForOneBip() * 2, 100e18);
    amountBob = bound(amountBob, _ptForOneBip() * 2, 100e18);

    uint256 aliceBalance0Before = token0.balanceOf(alice);
    uint256 bobBalance0Before = token0.balanceOf(bob);

    _swap(alice, int256(amountAlice), true, NO_TICK_LIMIT);
    _swap(bob, int256(amountBob), true, NO_TICK_LIMIT);

    assertLt(token0.balanceOf(alice), aliceBalance0Before, "Alice spent tokens");
    assertLt(token0.balanceOf(bob), bobBalance0Before, "Bob spent tokens");
  }

  // ============ Return Value Tests ============

  /// @dev Returns correct selector
  function testFuzz_ReturnsCorrectSelector(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);

    (bytes4 selector,,) = _swap(bob, int256(amountIn), true, NO_TICK_LIMIT);

    assertEq(selector, BaseHook.beforeSwap.selector, "Should return beforeSwap selector");
  }

  /// @dev Returns zero delta (direct transfer model) in both directions.
  function testFuzz_ReturnsZeroDelta_InBothDirections(uint256 amountIn, bool principalForCash)
    public
  {
    amountIn = _boundSwapAmount(amountIn);

    (, BeforeSwapDelta delta,) = _swap(bob, int256(amountIn), principalForCash, NO_TICK_LIMIT);
    assertEq(BeforeSwapDelta.unwrap(delta), 0, "Should return zero delta");
  }

  // ============ Revert Tests ============

  /// @dev Reverts when hookParams is wrong length
  function test_RevertWhen_InvalidHookParamsLength() public {
    bytes memory wrongLength = abi.encode(1e18, true); // Only 2 params instead of 3

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidHookParams.selector);
    hook.exposed_beforeSwap(bob, poolKey, defaultSwapParams, wrongLength);
  }

  /// @dev Reverts when amountIn is zero
  function test_RevertWhen_AmountInIsZero() public {
    bytes memory hookParams = _encodeHookParams(0, true, NO_TICK_LIMIT);

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__SwapAmountCannotBeZero.selector);
    hook.exposed_beforeSwap(bob, poolKey, defaultSwapParams, hookParams);
  }

  /// @dev Reverts when amountIn is negative
  function testFuzz_RevertWhen_AmountInIsNegative(int256 amountIn) public {
    amountIn = bound(amountIn, type(int256).min, -1);
    bytes memory hookParams = _encodeHookParams(amountIn, true, NO_TICK_LIMIT);

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__SwapAmountCannotBeZero.selector);
    hook.exposed_beforeSwap(bob, poolKey, defaultSwapParams, hookParams);
  }

  function test_RevertWhen_MarketExpired() public {
    vm.warp(hook.getMaturity());
    bytes memory hookParams = _encodeHookParams(1e18, true, NO_TICK_LIMIT);

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__MarketExpired.selector);
    hook.exposed_beforeSwap(bob, poolKey, defaultSwapParams, hookParams);
  }

  /// @dev Reverts when no active liquidity
  function test_RevertWhen_NoActiveLiquidity() public {
    // Deploy fresh hook with no liquidity
    address mockManager = makeAddr("freshMockManager");
    FixedFeeSwapMarketHarness freshHook = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH,
      address(token0),
      address(token1),
      FEE_RATE,
      YIELD_PER_TICK,
      IPoolManager(mockManager),
      0
    );

    vm.warp(block.timestamp + 1 days);

    PoolKey memory freshPoolKey = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 0,
      tickSpacing: 1,
      hooks: IHooks(address(freshHook))
    });

    bytes memory hookParams = _encodeHookParams(1e18, true, NO_TICK_LIMIT);

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__NoActiveLiquidity.selector);
    freshHook.exposed_beforeSwap(bob, freshPoolKey, defaultSwapParams, hookParams);
  }

  /// @dev Reverts if liquidity is exhausted mid-swap and there is remaining input
  /// (principal->cash).
  function testFuzz_RevertWhen_LiquidityExhaustedMidSwap_PrincipalForCash(uint128 liq) public {
    address mockManager = makeAddr("freshMockManager2");
    FixedFeeSwapMarketHarness freshHook = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH,
      address(token0),
      address(token1),
      FEE_RATE,
      YIELD_PER_TICK,
      IPoolManager(mockManager),
      0
    );
    vm.warp(block.timestamp + 1 days);

    PoolKey memory freshPoolKey = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 0,
      tickSpacing: 1,
      hooks: IHooks(address(freshHook))
    });

    liq = uint128(bound(uint256(liq), 1e18, 1e22));
    vm.startPrank(alice);
    token0.approve(address(freshHook), type(uint256).max);
    token1.approve(address(freshHook), type(uint256).max);
    freshHook.mintLiquidity(0, 20, liq, type(uint256).max, type(uint256).max);
    vm.stopPrank();

    int256 price = freshHook.tickToPrice(freshHook.getCurrentTick());
    (uint256 principalToBoundary,,,) = freshHook.exposed_getCashSwapAmount(int256(1e36), price, 20);

    bytes memory hookParams =
      _encodeHookParams(int256(principalToBoundary + 1), true, NO_TICK_LIMIT);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidTickTraversal.selector);
    freshHook.exposed_beforeSwap(bob, freshPoolKey, defaultSwapParams, hookParams);
  }

  /// @dev Reverts if liquidity is exhausted mid-swap and there is remaining input
  /// (cash->principal).
  function testFuzz_RevertWhen_LiquidityExhaustedMidSwap_CashForPrincipal(uint128 liq) public {
    address mockManager = makeAddr("freshMockManager3");
    FixedFeeSwapMarketHarness freshHook = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH,
      address(token0),
      address(token1),
      FEE_RATE,
      YIELD_PER_TICK,
      IPoolManager(mockManager),
      0
    );
    vm.warp(block.timestamp + 1 days);

    PoolKey memory freshPoolKey = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 0,
      tickSpacing: 1,
      hooks: IHooks(address(freshHook))
    });

    liq = uint128(bound(uint256(liq), 1e18, 1e22));
    vm.startPrank(alice);
    token0.approve(address(freshHook), type(uint256).max);
    token1.approve(address(freshHook), type(uint256).max);
    freshHook.mintLiquidity(0, 20, liq, type(uint256).max, type(uint256).max);
    vm.stopPrank();

    vm.startPrank(bob);
    token0.approve(address(freshHook), type(uint256).max);
    token1.approve(address(freshHook), type(uint256).max);
    vm.stopPrank();

    // Push tick to middle of range so cash->principal has room to move left
    int256 price = freshHook.tickToPrice(freshHook.getCurrentTick());
    bytes memory pushParams = abi.encode(int256(1e36), true, int24(10));
    freshHook.exposed_beforeSwap(bob, freshPoolKey, defaultSwapParams, pushParams);

    // Now try to exhaust all liquidity going cash->principal past lower tick
    price = freshHook.tickToPrice(freshHook.getCurrentTick());
    (uint256 cashInToBoundary,,,) = freshHook.exposed_getPrincipalSwapAmount(int256(1e36), price, 0);

    bytes memory hookParams = _encodeHookParams(int256(cashInToBoundary + 1), false, NO_TICK_LIMIT);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidTickTraversal.selector);
    freshHook.exposed_beforeSwap(bob, freshPoolKey, defaultSwapParams, hookParams);
  }

  /// @dev Reverts when the input token allowance is missing in either direction.
  function testFuzz_RevertWhen_InsufficientInputTokenAllowance(
    uint256 amountIn,
    bool principalForCash
  ) public {
    // Use amounts large enough to always move a tick (2 bips covers exp/ln rounding)
    amountIn = bound(amountIn, _ptForOneBip() * 2, 100e18);

    vm.prank(bob);
    if (principalForCash) token0.approve(address(hook), 0);
    else token1.approve(address(hook), 0);

    bytes memory hookParams = _encodeHookParams(int256(amountIn), principalForCash, NO_TICK_LIMIT);

    vm.expectRevert(stdError.arithmeticError);
    hook.exposed_beforeSwap(bob, poolKey, defaultSwapParams, hookParams);
  }

  /// @dev Reverts when insufficient balance
  function test_RevertWhen_InsufficientBalance() public {
    address poorUser = makeAddr("poorUser");

    // Approve but no balance
    vm.prank(poorUser);
    token0.approve(address(hook), type(uint256).max);

    // Use amount large enough to move at least one tick (> 2 * activeLiquidity / BIPS)
    uint256 swapAmount = uint256(hook.getActiveLiquidity()) / BIPS * 3;
    bytes memory hookParams = _encodeHookParams(int256(swapAmount), true, NO_TICK_LIMIT);

    vm.expectRevert(stdError.arithmeticError);
    hook.exposed_beforeSwap(poorUser, poolKey, defaultSwapParams, hookParams);
  }

  // ============ Sub-Bip Swaps Are No-Ops ============

  /// @dev A sub-bip swap is a no-op in either direction.
  function testFuzz_SubBipSwapIsNoOp(bool principalForCash) public {
    _warpFromStart(MARKET_LENGTH / 2);
    _initializePrice();

    uint256 balance0Before = token0.balanceOf(bob);
    uint256 balance1Before = token1.balanceOf(bob);

    _swap(bob, 1, principalForCash, NO_TICK_LIMIT);

    assertEq(token0.balanceOf(bob), balance0Before, "No TOKEN0 transfer");
    assertEq(token1.balanceOf(bob), balance1Before, "No TOKEN1 transfer");
  }

  // ============ Swap Event Tests ============

  function testFuzz_EmitsSwap_InBothDirections(bool principalForCash) public {
    uint256 amountIn = 1e18;
    uint256 balance0Before = token0.balanceOf(bob);
    uint256 balance1Before = token1.balanceOf(bob);

    _swap(bob, int256(amountIn), principalForCash, NO_TICK_LIMIT);

    uint256 consumed;
    uint256 received;
    if (principalForCash) {
      consumed = balance0Before - token0.balanceOf(bob);
      received = token1.balanceOf(bob) - balance1Before;
      token0.mint(bob, consumed);
      deal(address(token1), bob, balance1Before);
    } else {
      received = token0.balanceOf(bob) - balance0Before;
      consumed = balance1Before - token1.balanceOf(bob);
      token1.mint(bob, consumed);
      deal(address(token0), bob, balance0Before);
    }

    // Re-run once we know exact consumed/received amounts to assert event payload.
    vm.expectEmit(true, false, false, true, address(hook));
    emit FixedFeeSwapMarket.Swap(bob, principalForCash, consumed, received);
    _swap(bob, int256(amountIn), principalForCash, NO_TICK_LIMIT);
  }
}

// ============ LP Fee Tests ============

contract LPFees is _BeforeSwap {
  // Use a non-zero fee rate for fee tests
  uint24 public constant TEST_FEE_RATE = 3000; // 0.30%
  FixedFeeSwapMarketHarness public feeHook;
  PoolKey public feePoolKey;

  function setUp() public override {
    super.setUp();

    // Reset timestamp so feeHook has fresh START_TIME
    vm.warp(1); // Reset to base time

    // Deploy a separate hook with fees enabled
    address mockManager = makeAddr("feeMockManager");
    feeHook = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH,
      address(token0),
      address(token1),
      TEST_FEE_RATE,
      YIELD_PER_TICK,
      IPoolManager(mockManager),
      0
    );

    // Warp forward for realistic test conditions
    vm.warp(block.timestamp + 1 days);

    feePoolKey = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 0,
      tickSpacing: 1,
      hooks: IHooks(address(feeHook))
    });

    // Approve feeHook for users
    vm.startPrank(alice);
    token0.approve(address(feeHook), type(uint256).max);
    token1.approve(address(feeHook), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(bob);
    token0.approve(address(feeHook), type(uint256).max);
    token1.approve(address(feeHook), type(uint256).max);
    vm.stopPrank();
  }

  /// @dev Verifies fee rate is set correctly
  function test_FeeRateIsSet() public view {
    assertEq(feeHook.FEE_RATE(), TEST_FEE_RATE);
  }

  /// @dev Verifies global fee growth starts at zero
  function test_InitialFeeGrowthIsZero() public view {
    assertEq(feeHook.feeGrowthGlobal0X128(), 0);
    assertEq(feeHook.feeGrowthGlobal1X128(), 0);
  }

  /// @dev Swapping principal for cash should accumulate TOKEN0 fees
  function test_PrincipalForCash_AccumulatesFeeGrowth0() public {
    // Mint liquidity
    vm.prank(alice);
    feeHook.mintLiquidity(0, 200, 1e20, type(uint256).max, type(uint256).max);

    uint256 feeGrowthBefore = feeHook.feeGrowthGlobal0X128();
    assertEq(feeGrowthBefore, 0);

    // Swap principal for cash
    bytes memory hookParams = abi.encode(int256(1e18), true, NO_TICK_LIMIT);
    feeHook.exposed_beforeSwap(bob, feePoolKey, defaultSwapParams, hookParams);

    uint256 feeGrowthAfter = feeHook.feeGrowthGlobal0X128();
    assertGt(feeGrowthAfter, 0, "Fee growth should increase after swap");
  }

  /// @dev Swapper receives less output due to fees
  function test_SwapOutputIsReducedByFees() public {
    // Mint same liquidity on both hooks at [0, 200]
    vm.prank(alice);
    feeHook.mintLiquidity(0, 200, 1e20, type(uint256).max, type(uint256).max);

    // Both hooks have 1e20 liquidity at [0, 200], so 1 bip = 1e16.
    // Use 50 bips (5e17) to stay well within the 200-tick range.
    uint256 swapAmount = 5e17;

    // Swap on fee hook first (clean state, only 1e20 liquidity)
    uint256 bob0Before = token0.balanceOf(bob);
    uint256 bob1Before = token1.balanceOf(bob);

    bytes memory hookParams = abi.encode(int256(swapAmount), true, NO_TICK_LIMIT);
    feeHook.exposed_beforeSwap(bob, feePoolKey, defaultSwapParams, hookParams);

    uint256 outputWithFee = token1.balanceOf(bob) - bob1Before;
    uint256 inputWithFee = bob0Before - token0.balanceOf(bob);

    // Deploy a fresh zero-fee hook with the same liquidity as feeHook.
    // Must deploy at an earlier timestamp so time has elapsed.
    uint256 savedTimestamp = block.timestamp;
    vm.warp(1);
    address freshMgr = makeAddr("freshFeeMgr");
    FixedFeeSwapMarketHarness noFeeHook = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH, address(token0), address(token1), 0, YIELD_PER_TICK, IPoolManager(freshMgr), 0
    );
    vm.warp(savedTimestamp); // restore original timestamp

    PoolKey memory noFeePoolKey = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 0,
      tickSpacing: 1,
      hooks: IHooks(address(noFeeHook))
    });

    vm.startPrank(alice);
    token0.approve(address(noFeeHook), type(uint256).max);
    token1.approve(address(noFeeHook), type(uint256).max);
    noFeeHook.mintLiquidity(0, 200, 1e20, type(uint256).max, type(uint256).max);
    vm.stopPrank();

    vm.prank(bob);
    token0.approve(address(noFeeHook), type(uint256).max);

    // Reset bob's PT balance
    token0.mint(bob, inputWithFee);

    bob0Before = token0.balanceOf(bob);
    bob1Before = token1.balanceOf(bob);

    noFeeHook.exposed_beforeSwap(bob, noFeePoolKey, defaultSwapParams, hookParams);

    uint256 outputNoFee = token1.balanceOf(bob) - bob1Before;
    uint256 inputNoFee = bob0Before - token0.balanceOf(bob);

    // Output should be less with fees
    assertGt(outputNoFee, 0, "No-fee output should be non-zero");
    assertGt(outputWithFee, 0, "Fee output should be non-zero");
    assertLt(outputWithFee, outputNoFee, "Output should be less with fees");
    // Input should be the same (gross amount)
    assertEq(inputWithFee, inputNoFee, "Input should be the same");
  }

  /// @dev LP can collect fees after swaps
  function test_CollectFees_AfterSwaps() public {
    // Mint wide liquidity range
    vm.prank(alice);
    feeHook.mintLiquidity(0, 300, 1e20, type(uint256).max, type(uint256).max);

    bytes32 positionId = keccak256(abi.encodePacked(int24(300), int24(0), alice));

    // Multiple swaps to accumulate fees (smaller amounts to stay in range)
    for (uint256 i = 0; i < 5; i++) {
      bytes memory hookParams = abi.encode(int256(1e17), true, NO_TICK_LIMIT);
      feeHook.exposed_beforeSwap(bob, feePoolKey, defaultSwapParams, hookParams);
    }

    // Check fees owed
    uint256 aliceToken0Before = token0.balanceOf(alice);

    vm.prank(alice);
    (uint128 collected0, uint128 collected1) = feeHook.collectFees(positionId, alice, 0, 0);

    uint256 aliceToken0After = token0.balanceOf(alice);

    assertGt(collected0, 0, "Should have collected TOKEN0 fees");
    assertEq(collected1, 0, "Should not have collected TOKEN1 fees (no cash->principal swaps)");
    assertEq(
      aliceToken0After - aliceToken0Before,
      collected0,
      "Balance should increase by collected amount"
    );
  }

  /// @dev Only position owner can collect fees
  function test_RevertWhen_NonOwnerCollectsFees() public {
    vm.prank(alice);
    feeHook.mintLiquidity(0, 200, 1e20, type(uint256).max, type(uint256).max);

    bytes32 positionId = keccak256(abi.encodePacked(int24(200), int24(0), alice));

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__NotPositionOwner.selector);
    vm.prank(bob);
    feeHook.collectFees(positionId, bob, 0, 0);
  }

  /// @dev Fees are split proportionally among LPs in range
  function test_FeesProportionalToLiquidity() public {
    // Alice and Bob both mint wide positions, but Alice has 2x liquidity
    vm.prank(alice);
    feeHook.mintLiquidity(0, 300, 2e20, type(uint256).max, type(uint256).max);

    vm.prank(bob);
    feeHook.mintLiquidity(0, 300, 1e20, type(uint256).max, type(uint256).max);

    bytes32 alicePositionId = keccak256(abi.encodePacked(int24(300), int24(0), alice));
    bytes32 bobPositionId = keccak256(abi.encodePacked(int24(300), int24(0), bob));

    // Execute swaps (smaller amounts to stay in range)
    address carol = makeAddr("carol");
    _fundUser(carol);
    vm.prank(carol);
    token0.approve(address(feeHook), type(uint256).max);

    for (uint256 i = 0; i < 10; i++) {
      bytes memory hookParams = abi.encode(int256(1e17), true, NO_TICK_LIMIT);
      feeHook.exposed_beforeSwap(carol, feePoolKey, defaultSwapParams, hookParams);
    }

    // Collect fees
    vm.prank(alice);
    (uint128 aliceFees0,) = feeHook.collectFees(alicePositionId, alice, 0, 0);

    vm.prank(bob);
    (uint128 bobFees0,) = feeHook.collectFees(bobPositionId, bob, 0, 0);

    // Alice should get ~2x the fees of Bob (within rounding tolerance)
    // Using a 5% tolerance for rounding
    uint256 expectedAliceFees = uint256(bobFees0) * 2;
    uint256 tolerance = expectedAliceFees / 20; // 5%

    assertApproxEqAbs(aliceFees0, expectedAliceFees, tolerance, "Alice should get ~2x Bob's fees");
  }

  /// @dev Position out of range doesn't earn fees
  function test_OutOfRangeLPDoesNotEarnFees() public {
    // Alice mints wide in-range position
    vm.prank(alice);
    feeHook.mintLiquidity(0, 300, 1e20, type(uint256).max, type(uint256).max);

    // Bob mints out-of-range position (above the swap range)
    vm.prank(bob);
    feeHook.mintLiquidity(500, 600, 1e20, type(uint256).max, type(uint256).max);

    bytes32 alicePositionId = keccak256(abi.encodePacked(int24(300), int24(0), alice));
    bytes32 bobPositionId = keccak256(abi.encodePacked(int24(600), int24(500), bob));

    // Execute principal->cash swaps (tick moves up but stays within Alice's range)
    // Use smaller amounts to stay in range
    address carol = makeAddr("carol");
    _fundUser(carol);
    vm.prank(carol);
    token0.approve(address(feeHook), type(uint256).max);

    for (uint256 i = 0; i < 5; i++) {
      bytes memory hookParams = abi.encode(int256(1e17), true, NO_TICK_LIMIT);
      feeHook.exposed_beforeSwap(carol, feePoolKey, defaultSwapParams, hookParams);
    }

    // Collect fees
    vm.prank(alice);
    (uint128 aliceFees0,) = feeHook.collectFees(alicePositionId, alice, 0, 0);

    vm.prank(bob);
    (uint128 bobFees0,) = feeHook.collectFees(bobPositionId, bob, 0, 0);

    assertGt(aliceFees0, 0, "Alice (in range) should earn fees");
    assertEq(bobFees0, 0, "Bob (out of range) should not earn fees");
  }

  /// @dev Fees are accrued correctly when increasing liquidity
  function test_FeesAccrued_OnIncreaseLiquidity() public {
    vm.prank(alice);
    feeHook.mintLiquidity(0, 200, 1e20, type(uint256).max, type(uint256).max);

    bytes32 positionId = keccak256(abi.encodePacked(int24(200), int24(0), alice));

    // Execute some swaps to generate fees
    bytes memory hookParams = abi.encode(int256(1e18), true, NO_TICK_LIMIT);
    feeHook.exposed_beforeSwap(bob, feePoolKey, defaultSwapParams, hookParams);

    // Check position before
    (,,, int128 liqBefore) = feeHook.getPositionInfo(positionId);

    // Increase liquidity - this should accrue pending fees
    vm.prank(alice);
    feeHook.increaseLiquidity(positionId, 1e19, type(uint256).max, type(uint256).max);

    // Check position after
    (,,, int128 liqAfter) = feeHook.getPositionInfo(positionId);
    assertEq(liqAfter, liqBefore + int128(1e19), "Liquidity should increase");

    // The fees should still be collectible
    vm.prank(alice);
    (uint128 fees0,) = feeHook.collectFees(positionId, alice, 0, 0);
    assertGt(fees0, 0, "Should have accrued fees");
  }

  /// @dev Newly added liquidity should not earn fees from before it was added
  function test_ReAddLiquidityDoesNotEarnPastFees() public {
    // Bob provides persistent in-range liquidity so swaps continue while Alice is out
    vm.prank(bob);
    feeHook.mintLiquidity(0, 300, 2e20, type(uint256).max, type(uint256).max);

    vm.prank(alice);
    feeHook.mintLiquidity(0, 300, 1e20, type(uint256).max, type(uint256).max);

    bytes32 alicePositionId = keccak256(abi.encodePacked(int24(300), int24(0), alice));

    // Generate some fees while Alice is in range, then fully burn and collect to zero owed
    bytes memory hookParams = abi.encode(int256(1e18), true, NO_TICK_LIMIT);
    feeHook.exposed_beforeSwap(bob, feePoolKey, defaultSwapParams, hookParams);

    (,,, int128 liqBefore) = feeHook.getPositionInfo(alicePositionId);
    vm.prank(alice);
    feeHook.decreaseLiquidity(alicePositionId, -liqBefore, 0, 0);

    vm.prank(alice);
    feeHook.collectFees(alicePositionId, alice, 0, 0);

    // Generate fees while Alice has zero liquidity
    for (uint256 i = 0; i < 5; i++) {
      bytes memory stepParams = abi.encode(int256(1e17), true, NO_TICK_LIMIT);
      feeHook.exposed_beforeSwap(bob, feePoolKey, defaultSwapParams, stepParams);
    }

    // Re-add liquidity; collecting immediately should yield 0
    vm.prank(alice);
    feeHook.increaseLiquidity(alicePositionId, 1e20, type(uint256).max, type(uint256).max);

    vm.prank(alice);
    (uint128 fees0, uint128 fees1) = feeHook.collectFees(alicePositionId, alice, 0, 0);
    assertEq(fees0, 0, "Re-added liquidity should not earn past TOKEN0 fees");
    assertEq(fees1, 0, "Re-added liquidity should not earn past TOKEN1 fees");
  }

  function test_RevertWhen_DecreaseLiquidityPositiveDelta() public {
    vm.prank(alice);
    feeHook.mintLiquidity(0, 200, 1e20, type(uint256).max, type(uint256).max);

    bytes32 positionId = keccak256(abi.encodePacked(int24(200), int24(0), alice));

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__LiquidityDeltaMustBeNegative.selector);
    vm.prank(alice);
    feeHook.decreaseLiquidity(positionId, int128(1), 0, 0);
  }

  function test_RevertWhen_DecreaseLiquidityExceedsPositionLiquidity() public {
    vm.prank(alice);
    feeHook.mintLiquidity(0, 200, 1e20, type(uint256).max, type(uint256).max);

    bytes32 positionId = keccak256(abi.encodePacked(int24(200), int24(0), alice));
    (,,, int128 liqBefore) = feeHook.getPositionInfo(positionId);

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InsufficientPositionLiquidity.selector);
    vm.prank(alice);
    feeHook.decreaseLiquidity(positionId, -(liqBefore + 1), 0, 0);
  }

  function testFuzz_SwapOutputReducedByFees(uint256 amountIn) public {
    amountIn = bound(amountIn, 1e16, 5e17);

    // Mint same liquidity on feeHook
    vm.prank(alice);
    feeHook.mintLiquidity(0, 200, 1e20, type(uint256).max, type(uint256).max);

    // Swap on fee hook
    uint256 _bob0Before = token0.balanceOf(bob);
    uint256 _bob1Before = token1.balanceOf(bob);

    bytes memory _hookParams = abi.encode(int256(amountIn), true, NO_TICK_LIMIT);
    feeHook.exposed_beforeSwap(bob, feePoolKey, defaultSwapParams, _hookParams);

    uint256 _outputWithFee = token1.balanceOf(bob) - _bob1Before;
    uint256 _inputWithFee = _bob0Before - token0.balanceOf(bob);

    // Deploy a fresh zero-fee hook with the same liquidity
    uint256 _savedTimestamp = block.timestamp;
    vm.warp(1);
    address _freshMgr = makeAddr("fuzzFeeMgr");
    FixedFeeSwapMarketHarness _noFeeHook = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH, address(token0), address(token1), 0, YIELD_PER_TICK, IPoolManager(_freshMgr), 0
    );
    vm.warp(_savedTimestamp);

    PoolKey memory _noFeePoolKey = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 0,
      tickSpacing: 1,
      hooks: IHooks(address(_noFeeHook))
    });

    vm.startPrank(alice);
    token0.approve(address(_noFeeHook), type(uint256).max);
    token1.approve(address(_noFeeHook), type(uint256).max);
    _noFeeHook.mintLiquidity(0, 200, 1e20, type(uint256).max, type(uint256).max);
    vm.stopPrank();

    vm.prank(bob);
    token0.approve(address(_noFeeHook), type(uint256).max);

    // Restore bob's PT
    token0.mint(bob, _inputWithFee);

    _bob0Before = token0.balanceOf(bob);
    _bob1Before = token1.balanceOf(bob);

    _noFeeHook.exposed_beforeSwap(bob, _noFeePoolKey, defaultSwapParams, _hookParams);

    uint256 _outputNoFee = token1.balanceOf(bob) - _bob1Before;

    // Skip if sub-bip swap produced zero on either side or rounding makes them equal
    vm.assume(_outputNoFee > 0 && _outputWithFee > 0);
    assertLe(_outputWithFee, _outputNoFee, "Output should be <= with fees");
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

    vm.expectRevert(FixedFeeSwapMarket.LiquidityOnlyViaHook.selector);
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

    vm.expectRevert(FixedFeeSwapMarket.LiquidityOnlyViaHook.selector);
    hook.exposed_beforeRemoveLiquidity(alice, _poolKey, _params, "");
  }
}

contract CollectFees is FixedFeeSwapMarketTest {
  uint24 public constant TEST_FEE_RATE = 3000;
  FixedFeeSwapMarketHarness public feeHook;
  PoolKey internal feePoolKey;
  SwapParams internal defaultSwapParams;

  function setUp() public override {
    super.setUp();
    vm.warp(1);
    address _mockManager = makeAddr("collectFeesMockManager");
    feeHook = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH,
      address(token0),
      address(token1),
      TEST_FEE_RATE,
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

  function test_PartialFeeCollection() public {
    vm.prank(alice);
    feeHook.mintLiquidity(0, 300, 1e20, type(uint256).max, type(uint256).max);
    bytes32 _positionId = keccak256(abi.encodePacked(int24(300), int24(0), alice));

    _feeSwap(bob, int256(1e18), true);

    // Collect half
    vm.prank(alice);
    (uint128 _collected0,) = feeHook.collectFees(_positionId, alice, 0, 0);
    assertGt(_collected0, 0, "Should have fees to collect");

    // Generate more fees and collect a partial amount
    _feeSwap(bob, int256(1e18), true);
    vm.prank(alice);
    (uint128 _fullOwed0,) = feeHook.collectFees(_positionId, alice, 0, 0);
    // We need to generate fees again since we just collected all
    _feeSwap(bob, int256(1e18), true);

    // Now request only half
    vm.prank(alice);
    (uint128 _partial0,) = feeHook.collectFees(_positionId, alice, 1, 0);
    assertEq(_partial0, 1, "Should collect exactly requested amount");

    // Remainder still available
    vm.prank(alice);
    (uint128 _remainder0,) = feeHook.collectFees(_positionId, alice, 0, 0);
    assertGt(_remainder0, 0, "Should still have remaining fees");
  }

  function test_DoubleCollectYieldsZero() public {
    vm.prank(alice);
    feeHook.mintLiquidity(0, 300, 1e20, type(uint256).max, type(uint256).max);
    bytes32 _positionId = keccak256(abi.encodePacked(int24(300), int24(0), alice));

    _feeSwap(bob, int256(1e18), true);

    vm.prank(alice);
    feeHook.collectFees(_positionId, alice, 0, 0);

    vm.prank(alice);
    (uint128 _collected0, uint128 _collected1) = feeHook.collectFees(_positionId, alice, 0, 0);
    assertEq(_collected0, 0, "Second collect should yield zero TOKEN0");
    assertEq(_collected1, 0, "Second collect should yield zero TOKEN1");
  }

  function test_FeesSentToDifferentRecipient() public {
    vm.prank(alice);
    feeHook.mintLiquidity(0, 300, 1e20, type(uint256).max, type(uint256).max);
    bytes32 _positionId = keccak256(abi.encodePacked(int24(300), int24(0), alice));

    _feeSwap(bob, int256(1e18), true);

    uint256 _bobToken0Before = token0.balanceOf(bob);
    vm.prank(alice);
    (uint128 _collected0,) = feeHook.collectFees(_positionId, bob, 0, 0);
    assertGt(_collected0, 0, "Should collect fees");
    assertEq(token0.balanceOf(bob) - _bobToken0Before, _collected0, "Bob should receive the fees");
  }

  function test_CollectWithNoFeesOwed() public {
    vm.prank(alice);
    feeHook.mintLiquidity(0, 300, 1e20, type(uint256).max, type(uint256).max);
    bytes32 _positionId = keccak256(abi.encodePacked(int24(300), int24(0), alice));

    // No swaps — no fees
    vm.prank(alice);
    (uint128 _collected0, uint128 _collected1) = feeHook.collectFees(_positionId, alice, 0, 0);
    assertEq(_collected0, 0, "Should be zero TOKEN0 fees");
    assertEq(_collected1, 0, "Should be zero TOKEN1 fees");
  }

  function test_CashForPrincipal_AccumulatesFeeGrowth1() public {
    vm.prank(alice);
    feeHook.mintLiquidity(0, 300, 1e20, type(uint256).max, type(uint256).max);
    bytes32 _positionId = keccak256(abi.encodePacked(int24(300), int24(0), alice));

    // Push tick up first so cash→PT has room to move left
    // 1e20 liquidity, 1 bip = 1e16, use 100 bips = 1e18 to stay well within 300-tick range
    _feeSwap(bob, int256(1e18), true);

    // Swap cash→PT (smaller than push to stay in range)
    _feeSwap(bob, int256(5e17), false);

    assertGt(feeHook.feeGrowthGlobal1X128(), 0, "feeGrowthGlobal1X128 should be > 0");

    vm.prank(alice);
    (, uint128 _collected1) = feeHook.collectFees(_positionId, alice, 0, 0);
    assertGt(_collected1, 0, "Should have collected TOKEN1 fees");
  }

  function test_BothDirections_CollectsBothTokenFees() public {
    vm.prank(alice);
    feeHook.mintLiquidity(0, 300, 1e20, type(uint256).max, type(uint256).max);
    bytes32 _positionId = keccak256(abi.encodePacked(int24(300), int24(0), alice));

    // PT→Cash — push tick up enough to create room for cash→PT
    // 1e20 liquidity, 1 bip = 1e16, use 100 bips = 1e18 to stay within 300-tick range
    _feeSwap(bob, int256(1e18), true);
    // Cash→PT (smaller than push to stay in range)
    _feeSwap(bob, int256(5e17), false);

    vm.prank(alice);
    (uint128 _collected0, uint128 _collected1) = feeHook.collectFees(_positionId, alice, 0, 0);
    assertGt(_collected0, 0, "Should have collected TOKEN0 fees");
    assertGt(_collected1, 0, "Should have collected TOKEN1 fees");
  }

  function test_EmitsFeesCollected() public {
    vm.prank(alice);
    feeHook.mintLiquidity(0, 300, 1e20, type(uint256).max, type(uint256).max);
    bytes32 _positionId = keccak256(abi.encodePacked(int24(300), int24(0), alice));

    _feeSwap(bob, int256(1e18), true);

    vm.expectEmit(true, true, false, false, address(feeHook));
    emit FixedFeeSwapMarket.FeesCollected(_positionId, alice, 0, 0);

    vm.prank(alice);
    feeHook.collectFees(_positionId, alice, 0, 0);
  }
}

contract Solvency is FixedFeeSwapMarketTest {
  PoolKey internal poolKey;
  SwapParams internal defaultSwapParams;
  address internal charlie = makeAddr("charlie");

  function setUp() public override {
    super.setUp();
    _fundUser(charlie);
    _approveUser(charlie);
    poolKey = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 0,
      tickSpacing: 1,
      hooks: IHooks(address(hook))
    });
    defaultSwapParams = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});
  }

  function _swap(address _sender, int256 _amountIn, bool _principalForCash, int24 _tickLimit)
    internal
  {
    bytes memory _hookParams = abi.encode(_amountIn, _principalForCash, _tickLimit);
    hook.exposed_beforeSwap(_sender, poolKey, defaultSwapParams, _hookParams);
  }

  function _trySwap(address _sender, int256 _amountIn, bool _principalForCash, int24 _tickLimit)
    internal
    returns (bool)
  {
    bytes memory _hookParams = abi.encode(_amountIn, _principalForCash, _tickLimit);
    try hook.exposed_beforeSwap(_sender, poolKey, defaultSwapParams, _hookParams) {
      return true;
    } catch {
      return false;
    }
  }

  /// @dev Single LP withdraws after a PT->Cash swap. decreaseLiquidity must not revert,
  /// proving the contract holds enough tokens to pay out the LP.
  function testFuzz_SingleLP_WithdrawAfterSwap(
    int24 _tickLower,
    int24 _tickUpper,
    uint128 _liquidity,
    uint256 _swapAmount,
    uint256 _timeElapsed
  ) public {
    _tickLower = int24(bound(int256(_tickLower), 0, 1999));
    _tickUpper = int24(bound(int256(_tickUpper), int256(_tickLower) + 1, 2000));
    _liquidity = uint128(bound(_liquidity, 1e18, 1e24));
    _swapAmount = bound(_swapAmount, uint256(_liquidity) / BIPS, uint256(_liquidity) * 500 / BIPS);
    _timeElapsed = bound(_timeElapsed, 1 days, MARKET_LENGTH - 1);

    _warpFromStart(1);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _liquidity);

    _warpFromStart(_timeElapsed);

    // PT->Cash swap — may revert for edge-case inputs, skip those runs
    bool _swapped = _trySwap(bob, int256(_swapAmount), true, NO_TICK_LIMIT);
    vm.assume(_swapped);

    // LP full withdrawal must succeed (no revert = solvent)
    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);
    vm.prank(alice);
    hook.decreaseLiquidity(_positionId, -int128(uint128(_liquidity)), 0, 0);

    assertGe(token0.balanceOf(alice), _balance0Before, "LP should receive token0");
    assertGe(token1.balanceOf(alice), _balance1Before, "LP should receive token1");
  }

  /// @dev Single LP withdraws after PT->Cash then Cash->PT swaps.
  function testFuzz_SingleLP_WithdrawAfterReverseSwap(
    int24 _tickLower,
    int24 _tickUpper,
    uint128 _liquidity,
    uint256 _swapAmount1,
    uint256 _swapAmount2,
    uint256 _timeElapsed
  ) public {
    _tickLower = int24(bound(int256(_tickLower), 0, 1999));
    _tickUpper = int24(bound(int256(_tickUpper), int256(_tickLower) + 1, 2000));
    _liquidity = uint128(bound(_liquidity, 1e18, 1e24));
    _swapAmount1 = bound(_swapAmount1, uint256(_liquidity) / BIPS, uint256(_liquidity) * 500 / BIPS);
    _swapAmount2 = bound(_swapAmount2, uint256(_liquidity) / BIPS, uint256(_liquidity) * 500 / BIPS);
    _timeElapsed = bound(_timeElapsed, 1 days, MARKET_LENGTH - 1);

    _warpFromStart(1);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _liquidity);

    _warpFromStart(_timeElapsed);

    // PT->Cash then Cash->PT
    bool _swapped = _trySwap(bob, int256(_swapAmount1), true, NO_TICK_LIMIT);
    vm.assume(_swapped);
    _trySwap(bob, int256(_swapAmount2), false, NO_TICK_LIMIT);

    // LP full withdrawal must succeed
    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);
    vm.prank(alice);
    hook.decreaseLiquidity(_positionId, -int128(uint128(_liquidity)), 0, 0);

    assertGe(token0.balanceOf(alice), _balance0Before, "LP should receive token0");
    assertGe(token1.balanceOf(alice), _balance1Before, "LP should receive token1");
  }

  /// @dev Two LPs with fuzzed overlapping ranges. After a swap, both can fully withdraw.
  function testFuzz_TwoLPs_BothCanWithdraw(
    int24 _tickLower1,
    int24 _tickUpper1,
    int24 _tickLower2,
    int24 _tickUpper2,
    uint128 _liquidity1,
    uint128 _liquidity2,
    uint256 _swapAmount,
    uint256 _timeElapsed
  ) public {
    _tickLower1 = int24(bound(int256(_tickLower1), 0, 1999));
    _tickUpper1 = int24(bound(int256(_tickUpper1), int256(_tickLower1) + 1, 2000));
    _tickLower2 = int24(bound(int256(_tickLower2), 0, 1999));
    _tickUpper2 = int24(bound(int256(_tickUpper2), int256(_tickLower2) + 1, 2000));
    _liquidity1 = uint128(bound(_liquidity1, 1e18, 1e24));
    _liquidity2 = uint128(bound(_liquidity2, 1e18, 1e24));
    _swapAmount = bound(_swapAmount, uint256(_liquidity1) / BIPS, uint256(_liquidity1) * 500 / BIPS);
    _timeElapsed = bound(_timeElapsed, 1 days, MARKET_LENGTH - 1);

    _warpFromStart(1);
    bytes32 _pos1 = _mintLiquidityAtTicks(alice, _tickLower1, _tickUpper1, _liquidity1);
    bytes32 _pos2 = _mintLiquidityAtTicks(charlie, _tickLower2, _tickUpper2, _liquidity2);

    _warpFromStart(_timeElapsed);

    bool _swapped = _trySwap(bob, int256(_swapAmount), true, NO_TICK_LIMIT);
    vm.assume(_swapped);

    // Both LPs withdraw — neither should revert
    vm.prank(alice);
    hook.decreaseLiquidity(_pos1, -int128(uint128(_liquidity1)), 0, 0);
    vm.prank(charlie);
    hook.decreaseLiquidity(_pos2, -int128(uint128(_liquidity2)), 0, 0);
  }

  /// @dev LP partially withdraws, then another swap happens, then LP withdraws the rest.
  function testFuzz_PartialWithdraw_ThenSwap_ThenFullWithdraw(
    int24 _tickLower,
    int24 _tickUpper,
    uint128 _liquidity,
    uint128 _partialRemove,
    uint256 _swapAmount1,
    uint256 _swapAmount2,
    uint256 _timeElapsed
  ) public {
    _tickLower = int24(bound(int256(_tickLower), 0, 1999));
    _tickUpper = int24(bound(int256(_tickUpper), int256(_tickLower) + 1, 2000));
    _liquidity = uint128(bound(_liquidity, 1e18, 1e24));
    _partialRemove = uint128(bound(_partialRemove, 1e17, uint256(_liquidity) / 2));
    _swapAmount1 = bound(_swapAmount1, uint256(_liquidity) / BIPS, uint256(_liquidity) * 500 / BIPS);
    _swapAmount2 = bound(_swapAmount2, uint256(_liquidity) / BIPS, uint256(_liquidity) * 500 / BIPS);
    _timeElapsed = bound(_timeElapsed, 1 days, MARKET_LENGTH - 1);

    _warpFromStart(1);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _liquidity);

    _warpFromStart(_timeElapsed);

    // First swap
    bool _swapped = _trySwap(bob, int256(_swapAmount1), true, NO_TICK_LIMIT);
    vm.assume(_swapped);

    // Partial withdraw
    vm.prank(alice);
    hook.decreaseLiquidity(_positionId, -int128(_partialRemove), 0, 0);

    // Second swap (may fail if tick moved past all liquidity)
    _trySwap(bob, int256(_swapAmount2), true, NO_TICK_LIMIT);

    // Full withdraw of remaining
    uint128 _remaining = _liquidity - _partialRemove;
    vm.prank(alice);
    hook.decreaseLiquidity(_positionId, -int128(_remaining), 0, 0);
  }

  /// @dev Single LP withdraws after a Cash->PT swap. Tests the reverse swap direction's
  /// solvency — different rounding (ceil vs floor), different tick-crossing direction.
  function testFuzz_SingleLP_WithdrawAfterCashForPrincipalSwap(
    int24 _tickLower,
    int24 _tickUpper,
    uint128 _liquidity,
    uint256 _swapAmountPT,
    uint256 _swapAmountCash,
    uint256 _timeElapsed
  ) public {
    _tickLower = int24(bound(int256(_tickLower), 0, 1999));
    _tickUpper = int24(bound(int256(_tickUpper), int256(_tickLower) + 1, 2000));
    _liquidity = uint128(bound(_liquidity, 1e18, 1e24));
    // First move tick positive with PT->Cash so there's room for Cash->PT
    _swapAmountPT =
      bound(_swapAmountPT, uint256(_liquidity) / BIPS, uint256(_liquidity) * 500 / BIPS);
    _swapAmountCash =
      bound(_swapAmountCash, uint256(_liquidity) / BIPS, uint256(_liquidity) * 500 / BIPS);
    _timeElapsed = bound(_timeElapsed, 1 days, MARKET_LENGTH - 1);

    _warpFromStart(1);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _liquidity);

    _warpFromStart(_timeElapsed);

    // PT->Cash to move tick positive (needed so Cash->PT has initialized ticks to traverse)
    bool _swapped = _trySwap(bob, int256(_swapAmountPT), true, NO_TICK_LIMIT);
    vm.assume(_swapped);

    // Cash->PT swap — the direction under test
    _trySwap(bob, int256(_swapAmountCash), false, NO_TICK_LIMIT);

    // LP full withdrawal must succeed (no revert = solvent)
    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);
    vm.prank(alice);
    hook.decreaseLiquidity(_positionId, -int128(uint128(_liquidity)), 0, 0);

    assertGe(token0.balanceOf(alice), _balance0Before, "LP should receive token0");
    assertGe(token1.balanceOf(alice), _balance1Before, "LP should receive token1");
  }

  /// @dev Single LP withdraws after Cash->PT then PT->Cash. Tests that a full round-trip
  /// in the reverse order maintains solvency.
  function testFuzz_SingleLP_WithdrawAfterCashForPrincipal_ThenPrincipalForCash(
    int24 _tickLower,
    int24 _tickUpper,
    uint128 _liquidity,
    uint256 _setupAmount,
    uint256 _swapAmount1,
    uint256 _swapAmount2,
    uint256 _timeElapsed
  ) public {
    _tickLower = int24(bound(int256(_tickLower), 0, 1999));
    _tickUpper = int24(bound(int256(_tickUpper), int256(_tickLower) + 1, 2000));
    _liquidity = uint128(bound(_liquidity, 1e18, 1e24));
    _setupAmount =
      bound(_setupAmount, uint256(_liquidity) * 100 / BIPS, uint256(_liquidity) * 500 / BIPS);
    _swapAmount1 = bound(_swapAmount1, uint256(_liquidity) / BIPS, uint256(_liquidity) * 250 / BIPS);
    _swapAmount2 = bound(_swapAmount2, uint256(_liquidity) / BIPS, uint256(_liquidity) * 250 / BIPS);
    _timeElapsed = bound(_timeElapsed, 1 days, MARKET_LENGTH - 1);

    _warpFromStart(1);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _liquidity);

    _warpFromStart(_timeElapsed);

    // Setup: PT->Cash to move tick positive
    bool _swapped = _trySwap(bob, int256(_setupAmount), true, NO_TICK_LIMIT);
    vm.assume(_swapped);

    // Cash->PT then PT->Cash round-trip
    _trySwap(bob, int256(_swapAmount1), false, NO_TICK_LIMIT);
    _trySwap(bob, int256(_swapAmount2), true, NO_TICK_LIMIT);

    // LP full withdrawal must succeed
    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);
    vm.prank(alice);
    hook.decreaseLiquidity(_positionId, -int128(uint128(_liquidity)), 0, 0);

    assertGe(token0.balanceOf(alice), _balance0Before, "LP should receive token0");
    assertGe(token1.balanceOf(alice), _balance1Before, "LP should receive token1");
  }

  /// @dev Mint at t1, swap at t2, time passes to t3, then withdraw.
  function testFuzz_MintSwapWaitWithdraw(
    int24 _tickLower,
    int24 _tickUpper,
    uint128 _liquidity,
    uint256 _swapAmount,
    uint256 _swapTime,
    uint256 _withdrawTime
  ) public {
    _tickLower = int24(bound(int256(_tickLower), 0, 1999));
    _tickUpper = int24(bound(int256(_tickUpper), int256(_tickLower) + 1, 2000));
    _liquidity = uint128(bound(_liquidity, 1e18, 1e24));
    _swapAmount = bound(_swapAmount, uint256(_liquidity) / BIPS, uint256(_liquidity) * 500 / BIPS);
    _swapTime = bound(_swapTime, 1 days, MARKET_LENGTH / 2);
    _withdrawTime = bound(_withdrawTime, _swapTime + 1, MARKET_LENGTH - 1);

    // Mint at t=1
    _warpFromStart(1);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, _tickLower, _tickUpper, _liquidity);

    // Swap at _swapTime
    _warpFromStart(_swapTime);
    bool _swapped = _trySwap(bob, int256(_swapAmount), true, NO_TICK_LIMIT);
    vm.assume(_swapped);

    // Warp to _withdrawTime (> _swapTime), then withdraw
    _warpFromStart(_withdrawTime);

    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);
    vm.prank(alice);
    hook.decreaseLiquidity(_positionId, -int128(uint128(_liquidity)), 0, 0);

    assertGe(token0.balanceOf(alice), _balance0Before, "LP should receive token0");
    assertGe(token1.balanceOf(alice), _balance1Before, "LP should receive token1");
  }
}

// ============================================================================
// SolvencyWithFees - Solvency fuzz tests with non-zero fee rate
// ============================================================================

contract SolvencyWithFees is FixedFeeSwapMarketTest {
  uint24 public constant TEST_FEE_RATE = 3000; // 0.30%
  FixedFeeSwapMarketHarness public feeHook;
  PoolKey internal feePoolKey;
  SwapParams internal defaultSwapParams;
  address internal charlie = makeAddr("charlie");

  function setUp() public override {
    super.setUp();
    _fundUser(charlie);
    _approveUser(charlie);

    // Reset timestamp so feeHook has fresh START_TIME
    vm.warp(1);

    // Deploy a separate hook with fees enabled
    address _mockManager = makeAddr("feeSolvencyMockManager");
    feeHook = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH,
      address(token0),
      address(token1),
      TEST_FEE_RATE,
      YIELD_PER_TICK,
      IPoolManager(_mockManager),
      0
    );

    // Warp forward for realistic test conditions
    vm.warp(block.timestamp + 1 days);

    feePoolKey = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 0,
      tickSpacing: 1,
      hooks: IHooks(address(feeHook))
    });

    defaultSwapParams = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

    // Approve feeHook for all users
    vm.startPrank(alice);
    token0.approve(address(feeHook), type(uint256).max);
    token1.approve(address(feeHook), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(bob);
    token0.approve(address(feeHook), type(uint256).max);
    token1.approve(address(feeHook), type(uint256).max);
    vm.stopPrank();

    vm.startPrank(charlie);
    token0.approve(address(feeHook), type(uint256).max);
    token1.approve(address(feeHook), type(uint256).max);
    vm.stopPrank();
  }

  function _feeWarpFromStart(uint256 _timeElapsed) internal {
    vm.warp(feeHook.getStartTime() + _timeElapsed);
  }

  function _feeMintLiquidityAtTicks(address _user, int24 _lower, int24 _upper, uint128 _liquidity)
    internal
    returns (bytes32)
  {
    vm.prank(_user);
    feeHook.mintLiquidity(_lower, _upper, _liquidity, type(uint256).max, type(uint256).max);
    return keccak256(abi.encodePacked(_upper, _lower, _user));
  }

  function _tryFeeSwap(address _sender, int256 _amountIn, bool _principalForCash, int24 _tickLimit)
    internal
    returns (bool)
  {
    bytes memory _hookParams = abi.encode(_amountIn, _principalForCash, _tickLimit);
    try feeHook.exposed_beforeSwap(_sender, feePoolKey, defaultSwapParams, _hookParams) {
      return true;
    } catch {
      return false;
    }
  }

  /// @dev Single LP withdraws after a PT->Cash swap with fees enabled.
  function testFuzz_SingleLP_WithdrawAfterSwap_WithFees(
    int24 _tickLower,
    int24 _tickUpper,
    uint128 _liquidity,
    uint256 _swapAmount,
    uint256 _timeElapsed
  ) public {
    _tickLower = int24(bound(int256(_tickLower), 0, 1999));
    _tickUpper = int24(bound(int256(_tickUpper), int256(_tickLower) + 1, 2000));
    _liquidity = uint128(bound(_liquidity, 1e18, 1e24));
    _swapAmount = bound(_swapAmount, uint256(_liquidity) / BIPS, uint256(_liquidity) * 500 / BIPS);
    _timeElapsed = bound(_timeElapsed, 1 days, MARKET_LENGTH - 1);

    _feeWarpFromStart(1);
    bytes32 _positionId = _feeMintLiquidityAtTicks(alice, _tickLower, _tickUpper, _liquidity);

    _feeWarpFromStart(_timeElapsed);

    bool _swapped = _tryFeeSwap(bob, int256(_swapAmount), true, NO_TICK_LIMIT);
    vm.assume(_swapped);

    // LP full withdrawal must succeed
    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);
    vm.prank(alice);
    feeHook.decreaseLiquidity(_positionId, -int128(uint128(_liquidity)), 0, 0);

    assertGe(token0.balanceOf(alice), _balance0Before, "LP should receive token0");
    assertGe(token1.balanceOf(alice), _balance1Before, "LP should receive token1");
  }

  /// @dev Single LP withdraws after Cash->PT swap with fees enabled.
  function testFuzz_SingleLP_WithdrawAfterCashSwap_WithFees(
    int24 _tickLower,
    int24 _tickUpper,
    uint128 _liquidity,
    uint256 _swapAmountPT,
    uint256 _swapAmountCash,
    uint256 _timeElapsed
  ) public {
    _tickLower = int24(bound(int256(_tickLower), 0, 1999));
    _tickUpper = int24(bound(int256(_tickUpper), int256(_tickLower) + 1, 2000));
    _liquidity = uint128(bound(_liquidity, 1e18, 1e24));
    _swapAmountPT =
      bound(_swapAmountPT, uint256(_liquidity) / BIPS, uint256(_liquidity) * 500 / BIPS);
    _swapAmountCash =
      bound(_swapAmountCash, uint256(_liquidity) / BIPS, uint256(_liquidity) * 500 / BIPS);
    _timeElapsed = bound(_timeElapsed, 1 days, MARKET_LENGTH - 1);

    _feeWarpFromStart(1);
    bytes32 _positionId = _feeMintLiquidityAtTicks(alice, _tickLower, _tickUpper, _liquidity);

    _feeWarpFromStart(_timeElapsed);

    // PT->Cash to move tick positive
    bool _swapped = _tryFeeSwap(bob, int256(_swapAmountPT), true, NO_TICK_LIMIT);
    vm.assume(_swapped);

    // Cash->PT swap
    _tryFeeSwap(bob, int256(_swapAmountCash), false, NO_TICK_LIMIT);

    // LP full withdrawal must succeed
    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);
    vm.prank(alice);
    feeHook.decreaseLiquidity(_positionId, -int128(uint128(_liquidity)), 0, 0);

    assertGe(token0.balanceOf(alice), _balance0Before, "LP should receive token0");
    assertGe(token1.balanceOf(alice), _balance1Before, "LP should receive token1");
  }

  /// @dev Two LPs withdraw after a swap with fees enabled.
  function testFuzz_TwoLPs_BothCanWithdraw_WithFees(
    int24 _tickLower1,
    int24 _tickUpper1,
    int24 _tickLower2,
    int24 _tickUpper2,
    uint128 _liquidity1,
    uint128 _liquidity2,
    uint256 _swapAmount,
    uint256 _timeElapsed
  ) public {
    _tickLower1 = int24(bound(int256(_tickLower1), 0, 1999));
    _tickUpper1 = int24(bound(int256(_tickUpper1), int256(_tickLower1) + 1, 2000));
    _tickLower2 = int24(bound(int256(_tickLower2), 0, 1999));
    _tickUpper2 = int24(bound(int256(_tickUpper2), int256(_tickLower2) + 1, 2000));
    _liquidity1 = uint128(bound(_liquidity1, 1e18, 1e24));
    _liquidity2 = uint128(bound(_liquidity2, 1e18, 1e24));
    _swapAmount = bound(_swapAmount, uint256(_liquidity1) / BIPS, uint256(_liquidity1) * 500 / BIPS);
    _timeElapsed = bound(_timeElapsed, 1 days, MARKET_LENGTH - 1);

    _feeWarpFromStart(1);
    bytes32 _pos1 = _feeMintLiquidityAtTicks(alice, _tickLower1, _tickUpper1, _liquidity1);
    bytes32 _pos2 = _feeMintLiquidityAtTicks(charlie, _tickLower2, _tickUpper2, _liquidity2);

    _feeWarpFromStart(_timeElapsed);

    bool _swapped = _tryFeeSwap(bob, int256(_swapAmount), true, NO_TICK_LIMIT);
    vm.assume(_swapped);

    // Both LPs withdraw — neither should revert
    vm.prank(alice);
    feeHook.decreaseLiquidity(_pos1, -int128(uint128(_liquidity1)), 0, 0);
    vm.prank(charlie);
    feeHook.decreaseLiquidity(_pos2, -int128(uint128(_liquidity2)), 0, 0);
  }

  /// @dev LP collects fees then withdraws — proves fee collection doesn't break solvency
  function testFuzz_WithdrawAfterCollect_WithFees(
    int24 _tickLower,
    int24 _tickUpper,
    uint128 _liquidity,
    uint256 _swapAmount,
    uint256 _timeElapsed
  ) public {
    _tickLower = int24(bound(int256(_tickLower), 0, 1999));
    _tickUpper = int24(bound(int256(_tickUpper), int256(_tickLower) + 1, 2000));
    _liquidity = uint128(bound(_liquidity, 1e18, 1e24));
    _swapAmount = bound(_swapAmount, uint256(_liquidity) / BIPS, uint256(_liquidity) * 500 / BIPS);
    _timeElapsed = bound(_timeElapsed, 1 days, MARKET_LENGTH - 1);

    _feeWarpFromStart(1);
    bytes32 _positionId = _feeMintLiquidityAtTicks(alice, _tickLower, _tickUpper, _liquidity);

    _feeWarpFromStart(_timeElapsed);

    bool _swapped = _tryFeeSwap(bob, int256(_swapAmount), true, NO_TICK_LIMIT);
    vm.assume(_swapped);

    // Collect fees first
    vm.prank(alice);
    feeHook.collectFees(_positionId, alice, 0, 0);

    // LP full withdrawal must still succeed
    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);
    vm.prank(alice);
    feeHook.decreaseLiquidity(_positionId, -int128(uint128(_liquidity)), 0, 0);

    assertGe(token0.balanceOf(alice), _balance0Before, "LP should receive token0");
    assertGe(token1.balanceOf(alice), _balance1Before, "LP should receive token1");
  }
}

// ============================================================================
// Maturity Tests - Swap, mint, and withdraw at/past maturity
// ============================================================================

contract MaturityTests is FixedFeeSwapMarketTest {
  using FixedPointMathLib for int256;

  PoolKey internal poolKey;
  SwapParams internal defaultSwapParams;

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

  function _swap(address _sender, int256 _amountIn, bool _principalForCash, int24 _tickLimit)
    internal
  {
    bytes memory _hookParams = abi.encode(_amountIn, _principalForCash, _tickLimit);
    hook.exposed_beforeSwap(_sender, poolKey, defaultSwapParams, _hookParams);
  }

  /// @dev Swap at exactly maturity should revert (users redeem PT 1:1 instead)
  function test_RevertWhen_SwapAtMaturity() public {
    _warpFromStart(1);
    _mintLiquidityAtTicks(alice, 0, 500, 1e22);

    vm.warp(hook.getMaturity());

    bytes memory _hookParams = abi.encode(int256(1e18), true, NO_TICK_LIMIT);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__MarketExpired.selector);
    hook.exposed_beforeSwap(bob, poolKey, defaultSwapParams, _hookParams);
  }

  /// @dev Swap past maturity should revert
  function test_RevertWhen_SwapPastMaturity() public {
    _warpFromStart(1);
    _mintLiquidityAtTicks(alice, 0, 500, 1e22);

    vm.warp(hook.getMaturity() + 30 days);

    bytes memory _hookParams = abi.encode(int256(1e18), true, NO_TICK_LIMIT);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__MarketExpired.selector);
    hook.exposed_beforeSwap(bob, poolKey, defaultSwapParams, _hookParams);
  }

  /// @dev Mint liquidity at maturity should work
  function test_MintLiquidityAtMaturity() public {
    vm.warp(hook.getMaturity());

    bytes32 _positionId = _mintLiquidityAtTicks(alice, 0, 500, 1e22);

    (address _owner,,, int128 _liq) = hook.getPositionInfo(_positionId);
    assertEq(_owner, alice, "Position should be created");
    assertEq(uint128(_liq), 1e22, "Liquidity should match");
  }

  /// @dev Mint, swap, warp to maturity, withdraw should succeed
  function test_WithdrawAtMaturity() public {
    _warpFromStart(1);
    bytes32 _positionId = _mintLiquidityAtTicks(alice, 0, 500, 1e22);

    // Swap to move tick
    _warpFromStart(MARKET_LENGTH / 2);
    _swap(bob, int256(1e18), true, NO_TICK_LIMIT);

    // Warp to maturity and withdraw
    vm.warp(hook.getMaturity());

    uint256 _balance0Before = token0.balanceOf(alice);
    uint256 _balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.decreaseLiquidity(_positionId, -int128(uint128(1e22)), 0, 0);

    assertGe(token0.balanceOf(alice), _balance0Before, "LP should receive token0");
    assertGe(token1.balanceOf(alice), _balance1Before, "LP should receive token1");
  }
}

// ============================================================================
// Liquidity Gap Tests - Swaps across ranges with zero liquidity gaps
// ============================================================================

contract LiquidityGap is FixedFeeSwapMarketTest {
  PoolKey internal poolKey;
  SwapParams internal defaultSwapParams;

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

  function _swap(address _sender, int256 _amountIn, bool _principalForCash, int24 _tickLimit)
    internal
  {
    bytes memory _hookParams = abi.encode(_amountIn, _principalForCash, _tickLimit);
    hook.exposed_beforeSwap(_sender, poolKey, defaultSwapParams, _hookParams);
  }

  /// @dev Swap PT->Cash across contiguous positions: A at [0, 100], B at [100, 300]
  function test_SwapAcrossContiguousPositions_PrincipalForCash() public {
    _warpFromStart(1);

    uint128 _liqA = 1e22;
    uint128 _liqB = 1e22;

    // Position A: [0, 100], Position B: [100, 300] (contiguous, B is wider)
    _mintLiquidityAtTicks(alice, 0, 100, _liqA);
    _mintLiquidityAtTicks(bob, 100, 300, _liqB);

    // Swap enough to cross from A into B but not exhaust B (use price limit)
    // 100 bips exhausts A, add 10 bips into B
    uint256 _swapAmount = uint256(_liqA) * 110 / BIPS;

    _swap(alice, int256(_swapAmount), true, int24(150));

    int24 _currentTick = hook.getCurrentTick();
    assertGe(_currentTick, 100, "Tick should cross into Position B's range");
    assertLt(_currentTick, 300, "Tick should be within Position B's range");
    // Active liquidity should now include only B (A ends at 100)
    assertEq(hook.getActiveLiquidity(), _liqB, "Active liquidity should match Position B");
  }

  /// @dev Swap Cash->PT across contiguous positions (reverse direction)
  function test_SwapAcrossContiguousPositions_CashForPrincipal() public {
    _warpFromStart(1);

    uint128 _liqA = 1e22;
    uint128 _liqB = 1e22;

    // Position A: [0, 100], Position B: [100, 300]
    _mintLiquidityAtTicks(alice, 0, 100, _liqA);
    _mintLiquidityAtTicks(bob, 100, 300, _liqB);

    // First, move tick into middle of Position B's range (use price limit at tick 150)
    uint256 _pushAmount = uint256(_liqA) * 200 / BIPS;
    _swap(alice, int256(_pushAmount), true, int24(150));
    assertGe(hook.getCurrentTick(), 100, "Should be in B's range after push");

    // Now swap cash->principal to go back into A (use tick limit at tick 50)
    uint256 _swapAmount = uint256(_liqB) * 200 / BIPS;
    _swap(alice, int256(_swapAmount), false, int24(50));

    int24 _currentTick = hook.getCurrentTick();
    assertLe(_currentTick, 100, "Tick should be back in Position A's range");
    assertGe(_currentTick, 0, "Tick should be within Position A's range");
  }

  /// @dev Swap reverts when trying to continue past the only position's range (gap beyond)
  function test_SwapRevertsAtGapBoundary_PrincipalForCash() public {
    _warpFromStart(1);

    // Only Position A exists at [0, 100], gap beyond tick 100
    uint128 _liqA = 1e22;
    _mintLiquidityAtTicks(alice, 0, 100, _liqA);

    // Compute exact amount to exhaust A's range
    int256 _priceAtStart = hook.tickToPrice(hook.getCurrentTick());
    (uint256 _principalToBoundary,,,) =
      hook.exposed_getCashSwapAmount(int256(1e36), _priceAtStart, 100);

    // Try to swap past the boundary — should revert because there's no liquidity beyond
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidTickTraversal.selector);
    _swap(bob, int256(_principalToBoundary + 1), true, NO_TICK_LIMIT);
  }

  /// @dev Swap reverts when liquidity is exhausted going cash->principal past lower tick
  function test_SwapRevertsAtGapBoundary_CashForPrincipal() public {
    _warpFromStart(1);

    // Position at [0, 100] — starts in range at tick 0
    uint128 _liq = 1e22;
    _mintLiquidityAtTicks(alice, 0, 100, _liq);

    // Push tick positive into the range so cash->principal has room to move left
    uint256 _pushAmount = uint256(_liq) * 50 / BIPS;
    _swap(bob, int256(_pushAmount), true, NO_TICK_LIMIT);
    assertGt(hook.getCurrentTick(), 0, "Should be above lower tick after push");

    // Try to exhaust all liquidity going cash->principal past lower tick (tick 0)
    int256 _price = hook.tickToPrice(hook.getCurrentTick());
    (uint256 _cashInToBoundary,,,) = hook.exposed_getPrincipalSwapAmount(int256(1e36), _price, 0);

    // Going past the lower boundary with extra should revert
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidTickTraversal.selector);
    _swap(bob, int256(_cashInToBoundary + 1), false, NO_TICK_LIMIT);
  }
}
