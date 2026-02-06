// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {FixedFeeSwapMarket, TickInfo, BalanceDelta, PositionInfo} from "src/FixedFeeSwapMarket.sol";
import {FixedFeeSwapMarketHarness} from "test/harness/FixedFeeSwapMarketHarness.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

abstract contract FixedFeeSwapMarketTest is Test {
  FixedFeeSwapMarketHarness public hook;
  MockERC20 public token0;
  MockERC20 public token1;

  uint48 public constant MARKET_LENGTH = 365 days;
  // Large balance to support very large fuzzed liquidity ranges without incidental ERC20 reverts.
  uint256 public constant INITIAL_BALANCE = 1_000_000_000_000e18;
  uint256 public constant SCALE_FACTOR = 1e18;
  uint256 public constant BIPS = 10_000;
  // Fee rate in hundredths of a bip (3000 = 0.30%)
  // Set to 0 for existing tests to pass without fee impact
  uint24 public constant FEE_RATE = 0;

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
      MARKET_LENGTH, address(token0), address(token1), FEE_RATE, IPoolManager(mockManager)
    );

    // Warp forward to avoid division by zero in _getAmountCashDelta
    // The contract divides by (block.timestamp - START_TIME), which is 0 at deployment
    vm.warp(block.timestamp + 1 days);

    // Fund users
    _fundUser(alice);
    _fundUser(bob);

    // Approvals
    _approveUser(alice);
    _approveUser(bob);
  }

  // ============ Helper Functions ============

  function _fundUser(address user) internal {
    token0.mint(user, INITIAL_BALANCE);
    token1.mint(user, INITIAL_BALANCE);
  }

  function _approveUser(address user) internal {
    vm.startPrank(user);
    token0.approve(address(hook), type(uint256).max);
    token1.approve(address(hook), type(uint256).max);
    vm.stopPrank();
  }

  function _boundTick(int24 tick) internal pure returns (int24) {
    return int24(bound(int256(tick), -100_000, 100_000));
  }

  // TODO: Consider increasing these bounds
  function _boundTickRange(int24 lower, int24 upper) internal pure returns (int24, int24) {
    lower = int24(bound(int256(lower), -10_000, 9999));
    upper = int24(bound(int256(upper), int256(lower) + 1, 10_000));
    return (lower, upper);
  }

  function _boundLiquidity(uint128 liquidity) internal pure returns (uint128) {
    // Liquidity needs to be large enough to avoid rounding to 0 in _getAmountCashDelta
    // With 1 day elapsed, scaledTimeSinceMaturity ≈ 2.74e15, so liquidity must be > that
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
      expected0 = hook.exposed_getAmountPrincipleDelta(tickLower, tickUpper, liq);
    } else if (currentTick < tickUpper) {
      expected0 = hook.exposed_getAmountPrincipleDelta(currentTick, tickUpper, liq);
      expected1 = hook.exposed_getAmountCashDelta(tickLower, currentTick, liq);
    } else {
      expected1 = hook.exposed_getAmountCashDelta(tickLower, tickUpper, liq);
    }
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
    return bound(amount, 1e15, 100e18);
  }

  function _mintDefaultLiquidity(address user) internal returns (bytes32) {
    vm.prank(user);
    hook.mintLiquidity(-100, 100, 1e18, type(uint256).max, type(uint256).max);
    return keccak256(abi.encodePacked(int24(100), int24(-100), user));
  }

  function _mintLiquidityAtTicks(address user, int24 lower, int24 upper, uint128 liquidity)
    internal
    returns (bytes32)
  {
    vm.prank(user);
    hook.mintLiquidity(lower, upper, liquidity, type(uint256).max, type(uint256).max);
    return keccak256(abi.encodePacked(upper, lower, user));
  }

  function _getPositionId(int24 tickUpper, int24 tickLower, address owner)
    internal
    pure
    returns (bytes32)
  {
    return keccak256(abi.encodePacked(tickUpper, tickLower, owner));
  }
}

contract TickToPrice is FixedFeeSwapMarketTest {
  using FixedPointMathLib for int256;

  /// @dev Price is always positive for any tick and time
  function testFuzz_PriceAlwaysPositive(int24 tick, uint256 timeElapsed) public {
    tick = _boundTick(tick);
    timeElapsed = _boundTimeElapsed(timeElapsed);

    _warpFromStart(timeElapsed);
    int256 price = hook.tickToPrice(tick);

    assertGt(price, 0, "Price must always be positive");
  }

  /// @dev Price monotonically decreases with increasing yield (tick)
  /// @notice The implementation uses exp(-yield * time) so higher tick = lower price
  function testFuzz_PriceMonotonicInYield(int24 tickA, int24 tickB, uint256 timeElapsed) public {
    tickA = _boundTick(tickA);
    tickB = _boundTick(tickB);
    vm.assume(tickA < tickB);
    timeElapsed = bound(timeElapsed, 1, MARKET_LENGTH - 1);

    _warpFromStart(timeElapsed);
    int256 priceA = hook.tickToPrice(tickA);
    int256 priceB = hook.tickToPrice(tickB);

    assertGe(priceA, priceB, "Higher tick (yield) should have lower or equal price");
  }

  /// @dev For any positive time, moving one tick higher strictly reduces price.
  function testFuzz_PriceStrictlyDecreasesWithOneTickStep(int24 tick, uint256 timeElapsed) public {
    tick = int24(bound(int256(tick), -10_000, 9999));
    timeElapsed = bound(timeElapsed, 1, MARKET_LENGTH);

    _warpFromStart(timeElapsed);
    int256 priceA = hook.tickToPrice(tick);
    int256 priceB = hook.tickToPrice(tick + 1);

    assertGt(priceA, priceB, "tick+1 should have strictly lower price for t>0");
  }

  /// @dev Price decreases over time for positive yields (deeper discount)
  /// @notice With exp(-yield * time_elapsed), larger time = more negative exponent = lower price
  function testFuzz_PriceDecreasesOverTimeForPositiveYield(int24 tick, uint256 time1, uint256 time2)
    public
  {
    tick = int24(bound(int256(tick), 1, 10_000)); // Positive yield only
    time1 = bound(time1, 0, MARKET_LENGTH - 2);
    time2 = bound(time2, time1 + 1, MARKET_LENGTH - 1);

    _warpFromStart(time1);
    int256 price1 = hook.tickToPrice(tick);

    _warpFromStart(time2);
    int256 price2 = hook.tickToPrice(tick);

    assertLe(price2, price1, "Price should decrease over time for positive yield");
  }

  /// @dev Price increases over time for negative yields (appreciating premium)
  /// @notice With exp(-yield * time_elapsed), negative yield = positive exponent growth
  function testFuzz_PriceIncreasesOverTimeForNegativeYield(int24 tick, uint256 time1, uint256 time2)
    public
  {
    tick = int24(bound(int256(tick), -10_000, -1)); // Negative yield only
    time1 = bound(time1, 0, MARKET_LENGTH - 2);
    time2 = bound(time2, time1 + 1, MARKET_LENGTH - 1);

    _warpFromStart(time1);
    int256 price1 = hook.tickToPrice(tick);

    _warpFromStart(time2);
    int256 price2 = hook.tickToPrice(tick);

    assertGe(price2, price1, "Price should increase over time for negative yield");
  }

  /// @dev Price symmetry: price(tick) * price(-tick) = 1
  /// @notice This follows from exp(-x) * exp(x) = exp(0) = 1
  function testFuzz_PriceSymmetry(int24 tick, uint256 timeElapsed) public {
    tick = int24(bound(int256(tick), 1, 10_000)); // Use positive tick, test against its negative
    timeElapsed = bound(timeElapsed, 1, MARKET_LENGTH - 1);

    _warpFromStart(timeElapsed);
    int256 pricePositive = hook.tickToPrice(tick);
    int256 priceNegative = hook.tickToPrice(-tick);

    // price(tick) * price(-tick) should equal 1e18 (in WAD terms: 1e18 * 1e18 / 1e18 = 1e18)
    int256 product = (pricePositive * priceNegative) / 1e18;
    assertApproxEqRel(product, 1e18, 1e14, "price(tick) * price(-tick) should equal 1");
  }

  /// @dev At time = 0, price equals 1 regardless of tick
  /// @notice exp(0) = 1, and at start time the exponent is 0
  function testFuzz_PriceAtTimeZeroIsOne(int24 tick) public {
    tick = _boundTick(tick);
    _warpFromStart(0);
    int256 price = hook.tickToPrice(tick);
    assertEq(price, 1e18, "Price at time 0 should be 1 regardless of tick");
  }

  /// @dev Price ratio between ticks follows exponential relationship
  /// @notice price(tickA) / price(tickB) = exp(-(tickA - tickB) * time_factor)
  function testFuzz_PriceRatioConsistency(int24 tickA, int24 tickB, uint256 timeElapsed) public {
    tickA = int24(bound(int256(tickA), -1000, 1000));
    tickB = int24(bound(int256(tickB), -1000, 1000));
    vm.assume(tickA != tickB);
    timeElapsed = bound(timeElapsed, 1, MARKET_LENGTH - 1);

    _warpFromStart(timeElapsed);
    int256 priceA = hook.tickToPrice(tickA);
    int256 priceB = hook.tickToPrice(tickB);
    int256 priceDiff = hook.tickToPrice(tickA - tickB);

    // priceA / priceB should equal price(tickA - tickB)
    // In WAD: (priceA * 1e18) / priceB
    int256 ratio = (priceA * 1e18) / priceB;
    assertApproxEqRel(ratio, priceDiff, 1e12, "Price ratio should equal price of tick difference");
  }

  /// @dev Price at tick 0 equals 1e18 regardless of time
  function testFuzz_ZeroTickPriceIsOne(uint256 timeElapsed) public {
    timeElapsed = _boundTimeElapsed(timeElapsed);
    _warpFromStart(timeElapsed);

    int256 price = hook.tickToPrice(0);
    assertEq(price, 1e18, "Price at tick 0 should always be 1e18");
  }

  /// @dev Negative tick (negative yield) gives price > 1 (premium)
  /// @notice The implementation uses exp(-yield * time), so negative tick = exp(positive) > 1
  function testFuzz_NegativeTickHigherPrice(int24 tick, uint256 timeElapsed) public {
    tick = int24(bound(int256(tick), -10_000, -1));
    timeElapsed = bound(timeElapsed, 1, MARKET_LENGTH - 1);

    _warpFromStart(timeElapsed);
    int256 price = hook.tickToPrice(tick);

    assertGt(price, 1e18, "Negative tick should give price > 1");
  }

  /// @dev Positive tick (positive yield) gives price < 1 (discount)
  /// @notice The implementation uses exp(-yield * time), so positive tick = exp(negative) < 1
  function testFuzz_PositiveTickLowerPrice(int24 tick, uint256 timeElapsed) public {
    tick = int24(bound(int256(tick), 1, 10_000));
    timeElapsed = bound(timeElapsed, 1, MARKET_LENGTH - 1);

    _warpFromStart(timeElapsed);
    int256 price = hook.tickToPrice(tick);

    assertLt(price, 1e18, "Positive tick should give price < 1");
  }

  /// @dev Time additivity: price(t, t1+t2) == price(t,t1) * price(t,t2)
  function testFuzz_PriceTimeAdditivity(int24 tick, uint256 time1, uint256 time2) public {
    tick = int24(bound(int256(tick), -10_000, 10_000));
    time1 = bound(time1, 0, MARKET_LENGTH);
    time2 = bound(time2, 0, MARKET_LENGTH - time1);

    _warpFromStart(time1);
    int256 price1 = hook.tickToPrice(tick);

    _warpFromStart(time2);
    int256 price2 = hook.tickToPrice(tick);

    _warpFromStart(time1 + time2);
    int256 price12 = hook.tickToPrice(tick);

    int256 combined = (price1 * price2) / 1e18;
    assertApproxEqRel(
      price12, combined, 1e12, "price(t1+t2) should factor into price(t1)*price(t2)"
    );
  }

  /// @dev At maturity, the exponent reduces to -tick/BIPS (in WAD), so price matches
  /// exp(-tick/BIPS).
  function testFuzz_PriceAtMaturityMatchesClosedForm(int24 tick) public {
    tick = _boundTick(tick);

    vm.warp(hook.getMaturity());
    int256 actual = hook.tickToPrice(tick);

    int256 exponent = (-int256(tick) * 1e18) / int256(BIPS);
    int256 expected = exponent.expWad();
    assertApproxEqRel(actual, expected, 1e12, "price at maturity should match exp(-tick/BIPS)");
  }

  /// @dev Verify prices against precomputed values
  /// @notice Values computed from exp(-tick * timeElapsed / (BIPS * MARKET_LENGTH))
  function test_PrecomputedPriceValues() public {
    // At full maturity (MARKET_LENGTH), exponent = -tick / BIPS
    // tick=10000: exp(-1) ≈ 0.3678794411714423
    // tick=1000: exp(-0.1) ≈ 0.9048374180359595
    // tick=100: exp(-0.01) ≈ 0.9900498337491681
    // tick=-1000: exp(0.1) ≈ 1.1051709180756477
    // tick=-10000: exp(1) ≈ 2.7182818284590452
    // At half time, tick=1000: exp(-0.05) ≈ 0.9512294245007139

    int24[7] memory ticks =
      [int24(10_000), int24(1000), int24(100), int24(-1000), int24(-10_000), int24(1000), int24(0)];
    uint256[7] memory times = [
      uint256(MARKET_LENGTH),
      uint256(MARKET_LENGTH),
      uint256(MARKET_LENGTH),
      uint256(MARKET_LENGTH),
      uint256(MARKET_LENGTH),
      uint256(MARKET_LENGTH) / 2,
      uint256(MARKET_LENGTH)
    ];
    int256[7] memory expected = [
      int256(367_879_441_171_442_321), // exp(-1)
      int256(904_837_418_035_959_573), // exp(-0.1)
      int256(990_049_833_749_168_054), // exp(-0.01)
      int256(1_105_170_918_075_647_625), // exp(0.1)
      int256(2_718_281_828_459_045_235), // exp(1)
      int256(951_229_424_500_713_880), // exp(-0.05)
      int256(1e18) // exp(0)
    ];

    for (uint256 i = 0; i < 7; i++) {
      _warpFromStart(times[i]);
      int256 actualPrice = hook.tickToPrice(ticks[i]);

      assertApproxEqRel(
        actualPrice,
        expected[i],
        1e10, // 0.000001% tolerance for rounding
        string.concat("Failed for case ", vm.toString(i))
      );
    }
  }

  /// @dev Price bounded within reasonable exponential range
  function testFuzz_PriceBounded(int24 tick, uint256 timeElapsed) public {
    tick = _boundTick(tick);
    timeElapsed = _boundTimeElapsed(timeElapsed);

    _warpFromStart(timeElapsed);
    int256 price = hook.tickToPrice(tick);

    int256 minPrice = int256(-10e18).expWad(); // exp(-10)
    int256 maxPrice = int256(10e18).expWad(); // exp(10)
    assertGe(price, minPrice, "Price below exp(-10)");
    assertLe(price, maxPrice, "Price above exp(10)");
  }
}

contract MintLiquidity is FixedFeeSwapMarketTest {
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

  // ============ Position Creation Tests ============

  /// @dev Minting creates position with correct parameters
  function testFuzz_CreatesPosition(int24 tickLower, int24 tickUpper, uint128 liquidity) public {
    (tickLower, tickUpper) = _boundTickRange(tickLower, tickUpper);
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);

    bytes32 positionId = _getPositionId(tickUpper, tickLower, alice);
    (address owner, int24 lower, int24 upper, int128 liq) = hook.getPositionInfo(positionId);

    assertEq(owner, alice, "Position owner should be alice");
    assertEq(lower, tickLower, "Position tickLower should match");
    assertEq(upper, tickUpper, "Position tickUpper should match");
    assertEq(uint128(liq), liquidity, "Position liquidity should match");
  }

  /// @dev Minting updates tick liquidity gross correctly
  function testFuzz_UpdatesTickLiquidityGross(int24 tickLower, int24 tickUpper, uint128 liquidity)
    public
  {
    (tickLower, tickUpper) = _boundTickRange(tickLower, tickUpper);
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);

    (uint128 lowerGross,) = hook.getTickInfo(tickLower);
    (uint128 upperGross,) = hook.getTickInfo(tickUpper);

    assertEq(lowerGross, liquidity, "Lower tick liquidityGross should equal liquidity");
    assertEq(upperGross, liquidity, "Upper tick liquidityGross should equal liquidity");
  }

  /// @dev Minting updates tick liquidity net correctly (lower positive, upper negative)
  function testFuzz_UpdatesTickLiquidityNet(int24 tickLower, int24 tickUpper, uint128 liquidity)
    public
  {
    (tickLower, tickUpper) = _boundTickRange(tickLower, tickUpper);
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);

    (, int128 lowerNet) = hook.getTickInfo(tickLower);
    (, int128 upperNet) = hook.getTickInfo(tickUpper);

    assertEq(lowerNet, int128(liquidity), "Lower tick liquidityNet should be positive");
    assertEq(upperNet, -int128(liquidity), "Upper tick liquidityNet should be negative");
  }

  function testFuzz_SetsTickBitmapBits(uint128 liquidity) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 200;
    int24 tickUpper = currentTick + 200;
    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);

    (int16 lowerWord, uint8 lowerBit) = _bitmapPosition(tickLower);
    (int16 upperWord, uint8 upperBit) = _bitmapPosition(tickUpper);

    uint256 lowerWordValue = hook.getTickBitmapWord(lowerWord);
    uint256 upperWordValue = hook.getTickBitmapWord(upperWord);

    uint256 lowerMask = uint256(1) << lowerBit;
    uint256 upperMask = uint256(1) << upperBit;
    assertTrue((lowerWordValue & lowerMask) != 0, "Lower tick bit should be set");
    assertTrue((upperWordValue & upperMask) != 0, "Upper tick bit should be set");
  }

  // ============ Token Transfer Tests ============

  /// @dev Minting transfers tokens from user to hook
  function testFuzz_TransfersTokens(int24 tickLower, int24 tickUpper, uint128 liquidity) public {
    (tickLower, tickUpper) = _boundTickRange(tickLower, tickUpper);
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, liquidity);

    uint256 balance0Before = token0.balanceOf(alice);
    uint256 balance1Before = token1.balanceOf(alice);
    uint256 hookBalance0Before = token0.balanceOf(address(hook));
    uint256 hookBalance1Before = token1.balanceOf(address(hook));

    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);

    uint256 balance0After = token0.balanceOf(alice);
    uint256 balance1After = token1.balanceOf(alice);
    uint256 hookBalance0After = token0.balanceOf(address(hook));
    uint256 hookBalance1After = token1.balanceOf(address(hook));

    assertEq(
      int256(balance0Before - balance0After), expected0, "User token0 debited should equal expected"
    );
    assertEq(
      int256(balance1Before - balance1After), expected1, "User token1 debited should equal expected"
    );
    assertEq(
      int256(hookBalance0After - hookBalance0Before),
      expected0,
      "Hook token0 credited should equal expected"
    );
    assertEq(
      int256(hookBalance1After - hookBalance1Before),
      expected1,
      "Hook token1 credited should equal expected"
    );
  }

  /// @dev Token conservation: total supply unchanged after mint
  function testFuzz_TokenConservation(int24 tickLower, int24 tickUpper, uint128 liquidity) public {
    (tickLower, tickUpper) = _boundTickRange(tickLower, tickUpper);
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    uint256 total0Before = token0.balanceOf(alice) + token0.balanceOf(address(hook));
    uint256 total1Before = token1.balanceOf(alice) + token1.balanceOf(address(hook));

    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);

    uint256 total0After = token0.balanceOf(alice) + token0.balanceOf(address(hook));
    uint256 total1After = token1.balanceOf(alice) + token1.balanceOf(address(hook));

    assertEq(total0After, total0Before, "Token0 total should be conserved");
    assertEq(total1After, total1Before, "Token1 total should be conserved");
  }

  // ============ Active Liquidity Tests ============

  /// @dev Minting updates active liquidity when position spans current tick
  function testFuzz_UpdatesActiveLiquidityWhenInRange(uint128 liquidity) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;
    uint128 activeBefore = hook.getActiveLiquidity();

    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);

    uint128 activeAfter = hook.getActiveLiquidity();

    assertEq(activeAfter, activeBefore + liquidity, "Active liquidity should increase by liquidity");
  }

  /// @dev Minting does not update active liquidity when position is below current tick
  function testFuzz_NoActiveLiquidityUpdateWhenBelow(uint128 liquidity) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickUpper = currentTick - 100;
    int24 tickLower = tickUpper - 100;
    uint128 activeBefore = hook.getActiveLiquidity();

    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);

    uint128 activeAfter = hook.getActiveLiquidity();

    assertEq(
      activeAfter, activeBefore, "Active liquidity should not change for below-range position"
    );
  }

  /// @dev Minting does not update active liquidity when position is above current tick
  function testFuzz_NoActiveLiquidityUpdateWhenAbove(uint128 liquidity) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick + 100;
    int24 tickUpper = tickLower + 100;
    uint128 activeBefore = hook.getActiveLiquidity();

    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);

    uint128 activeAfter = hook.getActiveLiquidity();

    assertEq(
      activeAfter, activeBefore, "Active liquidity should not change for above-range position"
    );
  }

  // ============ Multiple Users Tests ============

  /// @dev Multiple users can mint at same ticks
  function testFuzz_MultipleUsersCanMint(uint128 liquidityAlice, uint128 liquidityBob) public {
    liquidityAlice = _boundLiquidity(liquidityAlice);
    liquidityBob = _boundLiquidity(liquidityBob);

    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    _warpToMintTime();
    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidityAlice, type(uint256).max, type(uint256).max);

    _warpToMintTime();
    vm.prank(bob);
    hook.mintLiquidity(tickLower, tickUpper, liquidityBob, type(uint256).max, type(uint256).max);

    (uint128 lowerGross,) = hook.getTickInfo(tickLower);
    (uint128 upperGross,) = hook.getTickInfo(tickUpper);

    assertEq(lowerGross, liquidityAlice + liquidityBob, "Lower tick should have combined liquidity");
    assertEq(upperGross, liquidityAlice + liquidityBob, "Upper tick should have combined liquidity");
  }

  /// @dev Multiple users get separate positions
  function testFuzz_MultipleUsersSeparatePositions(uint128 liquidityAlice, uint128 liquidityBob)
    public
  {
    liquidityAlice = _boundLiquidity(liquidityAlice);
    liquidityBob = _boundLiquidity(liquidityBob);

    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    _warpToMintTime();
    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidityAlice, type(uint256).max, type(uint256).max);

    _warpToMintTime();
    vm.prank(bob);
    hook.mintLiquidity(tickLower, tickUpper, liquidityBob, type(uint256).max, type(uint256).max);

    bytes32 alicePositionId = _getPositionId(tickUpper, tickLower, alice);
    bytes32 bobPositionId = _getPositionId(tickUpper, tickLower, bob);

    (address aliceOwner,,, int128 aliceLiq) = hook.getPositionInfo(alicePositionId);
    (address bobOwner,,, int128 bobLiq) = hook.getPositionInfo(bobPositionId);

    assertEq(aliceOwner, alice, "Alice should own her position");
    assertEq(bobOwner, bob, "Bob should own his position");
    assertEq(uint128(aliceLiq), liquidityAlice, "Alice liquidity should match");
    assertEq(uint128(bobLiq), liquidityBob, "Bob liquidity should match");
  }

  // ============ Token Amount Tests Based on Position ============

  /// @dev Position below current tick requires only token1 (cash)
  function testFuzz_BelowRangeOnlyToken1(uint128 liquidity) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickUpper = currentTick - 100;
    int24 tickLower = tickUpper - 100;
    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, liquidity);
    assertEq(expected0, 0, "Below-range should not require token0");
    assertGt(expected1, 0, "Below-range should require token1");

    uint256 balance0Before = token0.balanceOf(alice);
    uint256 balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);

    uint256 balance0After = token0.balanceOf(alice);
    uint256 balance1After = token1.balanceOf(alice);

    assertEq(
      int256(balance0Before - balance0After), expected0, "Token0 amount should match expected"
    );
    assertEq(
      int256(balance1Before - balance1After), expected1, "Token1 amount should match expected"
    );
  }

  /// @dev Position above current tick requires only token0 (principal)
  function testFuzz_AboveRangeOnlyToken0(uint128 liquidity) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick + 100;
    int24 tickUpper = tickLower + 100;
    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, liquidity);
    assertGt(expected0, 0, "Above-range should require token0");
    assertEq(expected1, 0, "Above-range should not require token1");

    uint256 balance0Before = token0.balanceOf(alice);
    uint256 balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);

    uint256 balance0After = token0.balanceOf(alice);
    uint256 balance1After = token1.balanceOf(alice);

    assertEq(
      int256(balance0Before - balance0After), expected0, "Token0 amount should match expected"
    );
    assertEq(
      int256(balance1Before - balance1After), expected1, "Token1 amount should match expected"
    );
  }

  /// @dev Position spanning current tick requires both tokens
  function testFuzz_InRangeBothTokens(uint128 liquidity) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;
    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, liquidity);
    assertGt(expected0, 0, "In-range should require token0");
    assertGt(expected1, 0, "In-range should require token1");

    uint256 balance0Before = token0.balanceOf(alice);
    uint256 balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);

    uint256 balance0After = token0.balanceOf(alice);
    uint256 balance1After = token1.balanceOf(alice);

    assertEq(
      int256(balance0Before - balance0After), expected0, "Token0 amount should match expected"
    );
    assertEq(
      int256(balance1Before - balance1After), expected1, "Token1 amount should match expected"
    );
  }

  function testFuzz_TickLowerEqualsCurrentTick_OnlyToken0(uint128 liquidity) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick;
    int24 tickUpper = currentTick + 100;
    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, liquidity);
    assertGt(expected0, 0, "Expected token0 to be required");
    assertEq(expected1, 0, "Expected token1 not to be required");

    uint256 balance0Before = token0.balanceOf(alice);
    uint256 balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);

    assertEq(
      int256(balance0Before - token0.balanceOf(alice)),
      expected0,
      "Token0 amount should match expected"
    );
    assertEq(
      int256(balance1Before - token1.balanceOf(alice)),
      expected1,
      "Token1 amount should match expected"
    );
  }

  function testFuzz_TickUpperEqualsCurrentTick_OnlyToken1(uint128 liquidity) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick;
    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, liquidity);
    assertEq(expected0, 0, "Expected token0 not to be required");
    assertGt(expected1, 0, "Expected token1 to be required");

    uint256 balance0Before = token0.balanceOf(alice);
    uint256 balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);

    assertEq(
      int256(balance0Before - token0.balanceOf(alice)),
      expected0,
      "Token0 amount should match expected"
    );
    assertEq(
      int256(balance1Before - token1.balanceOf(alice)),
      expected1,
      "Token1 amount should match expected"
    );
  }

  // ============ Liquidity Scaling Tests ============

  /// @dev Larger liquidity requires proportionally more tokens
  function testFuzz_TokenAmountsScaleWithLiquidity(uint128 liquidity1, uint128 liquidity2) public {
    liquidity1 = uint128(bound(liquidity1, 1e17, 1e18));
    liquidity2 = uint128(bound(liquidity2, liquidity1 * 2, 1e20));

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;
    (int256 expected0_1, int256 expected1_1) =
      _expectedMintAmounts(tickLower, tickUpper, liquidity1);
    (int256 expected0_2, int256 expected1_2) =
      _expectedMintAmounts(tickLower, tickUpper, liquidity2);
    assertGt(expected0_1, 0, "Expected token0 to be required");
    assertGt(expected1_1, 0, "Expected token1 to be required");
    assertGe(expected0_2, expected0_1, "More liquidity should not require less token0");
    assertGe(expected1_2, expected1_1, "More liquidity should not require less token1");

    (uint256 token0Used1, uint256 token1Used1) =
      _mintLiquidity(alice, tickLower, tickUpper, liquidity1);
    assertEq(int256(token0Used1), expected0_1, "token0 used should match expected for liquidity1");
    assertEq(int256(token1Used1), expected1_1, "token1 used should match expected for liquidity1");

    _warpToMintTime();
    (uint256 token0Used2, uint256 token1Used2) =
      _mintLiquidity(bob, tickLower, tickUpper, liquidity2);
    assertEq(int256(token0Used2), expected0_2, "token0 used should match expected for liquidity2");
    assertEq(int256(token1Used2), expected1_2, "token1 used should match expected for liquidity2");

    assertGt(token0Used2, token0Used1, "More liquidity should require more token0");
    assertGt(token1Used2, token1Used1, "More liquidity should require more token1");
  }

  // ============ Tick Range Tests ============

  /// @dev Wider tick range requires more token0 (principal) for above-range
  function testFuzz_WiderRangeMorePrincipal(uint128 liquidity) public {
    liquidity = _boundLiquidity(liquidity);

    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick + 100;

    _warpToMintTime();
    uint256 balance0Before1 = token0.balanceOf(alice);
    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickLower + 10, liquidity, type(uint256).max, type(uint256).max);
    uint256 token0Used1 = balance0Before1 - token0.balanceOf(alice);

    _warpToMintTime();
    uint256 balance0Before2 = token0.balanceOf(bob);
    vm.prank(bob);
    hook.mintLiquidity(tickLower, tickLower + 100, liquidity, type(uint256).max, type(uint256).max);
    uint256 token0Used2 = balance0Before2 - token0.balanceOf(bob);

    assertGt(token0Used2, token0Used1, "Wider range should require more principal");
  }

  function testFuzz_AllowsWhen_SlippageExactlyMet(uint128 liquidity) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;
    (int256 required0, int256 required1) = _expectedMintAmounts(tickLower, tickUpper, liquidity);
    assertGt(required0, 0, "Expected token0 to be required");
    assertGt(required1, 0, "Expected token1 to be required");

    uint256 required0U = uint256(required0);
    uint256 required1U = uint256(required1);
    vm.prank(alice);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, required0U, required1U);
  }

  // ============ Revert Tests ============

  /// @dev Reverts when token0 amount exceeds max
  /// @notice Uses position above current tick (0) to ensure token0 is needed
  function testFuzz_RevertWhen_Token0SlippageExceeded(uint128 liquidity) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick + 100;
    int24 tickUpper = tickLower + 100;
    (int256 required0, int256 required1) = _expectedMintAmounts(tickLower, tickUpper, liquidity);
    assertGt(required0, 0, "Expected token0 to be required");
    assertEq(required1, 0, "Expected token1 not to be required");

    uint256 required0U = uint256(required0);
    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidLiquidityAmount.selector);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, required0U - 1, type(uint256).max);
  }

  /// @dev Reverts when token1 amount exceeds max
  /// @notice Uses position below current tick (0) to ensure token1 is needed
  function testFuzz_RevertWhen_Token1SlippageExceeded(uint128 liquidity) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickUpper = currentTick - 100;
    int24 tickLower = tickUpper - 100;
    (int256 required0, int256 required1) = _expectedMintAmounts(tickLower, tickUpper, liquidity);
    assertEq(required0, 0, "Expected token0 not to be required");
    assertGt(required1, 0, "Expected token1 to be required");

    uint256 required1U = uint256(required1);
    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidLiquidityAmount.selector);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, required1U - 1);
  }

  function testFuzz_RevertWhen_InvalidTickRange(int24 tickLower, int24 tickUpper, uint128 liquidity)
    public
  {
    tickLower = _boundTick(tickLower);
    tickUpper = _boundTick(tickUpper);
    vm.assume(tickLower > tickUpper);
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidTickRange.selector);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);
  }

  function testFuzz_RevertWhen_TicksEqual_ZeroWidthRange(int24 tick, uint128 liquidity) public {
    tick = _boundTick(tick);
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidTickRange.selector);
    hook.mintLiquidity(tick, tick, liquidity, type(uint256).max, type(uint256).max);
  }

  function testFuzz_RevertWhen_Token0AllowanceMissing(uint128 liquidity) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick + 100;
    int24 tickUpper = tickLower + 100;
    (int256 required0, int256 required1) = _expectedMintAmounts(tickLower, tickUpper, liquidity);
    assertGt(required0, 0, "Expected token0 to be required");
    assertEq(required1, 0, "Expected token1 not to be required");

    vm.startPrank(alice);
    token0.approve(address(hook), 0);
    vm.expectRevert(stdError.arithmeticError);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);
    vm.stopPrank();
  }

  function testFuzz_RevertWhen_Token1AllowanceMissing(uint128 liquidity) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickUpper = currentTick - 100;
    int24 tickLower = tickUpper - 100;
    (int256 required0, int256 required1) = _expectedMintAmounts(tickLower, tickUpper, liquidity);
    assertEq(required0, 0, "Expected token0 not to be required");
    assertGt(required1, 0, "Expected token1 to be required");

    vm.startPrank(alice);
    token1.approve(address(hook), 0);
    vm.expectRevert(stdError.arithmeticError);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);
    vm.stopPrank();
  }

  function testFuzz_RevertWhen_InsufficientBalanceToken0(uint128 liquidity) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick + 100;
    int24 tickUpper = tickLower + 100;
    (int256 required0, int256 required1) = _expectedMintAmounts(tickLower, tickUpper, liquidity);
    assertGt(required0, 0, "Expected token0 to be required");
    assertEq(required1, 0, "Expected token1 not to be required");

    vm.startPrank(alice);
    token0.transfer(makeAddr("sink"), token0.balanceOf(alice));
    vm.expectRevert(stdError.arithmeticError);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);
    vm.stopPrank();
  }

  function testFuzz_RevertWhen_InsufficientBalanceToken1(uint128 liquidity) public {
    liquidity = _boundLiquidity(liquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickUpper = currentTick - 100;
    int24 tickLower = tickUpper - 100;
    (int256 required0, int256 required1) = _expectedMintAmounts(tickLower, tickUpper, liquidity);
    assertEq(required0, 0, "Expected token0 not to be required");
    assertGt(required1, 0, "Expected token1 to be required");

    vm.startPrank(alice);
    token1.transfer(makeAddr("sink"), token1.balanceOf(alice));
    vm.expectRevert(stdError.arithmeticError);
    hook.mintLiquidity(tickLower, tickUpper, liquidity, type(uint256).max, type(uint256).max);
    vm.stopPrank();
  }
}

contract IncreaseLiquidity is FixedFeeSwapMarketTest {
  struct Amounts {
    int256 amount0;
    int256 amount1;
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

  // ============ Position Update Tests ============

  /// @dev Increasing liquidity adds to existing position
  function testFuzz_AddsToPosition(uint128 initialLiquidity, uint128 additionalLiquidity) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    vm.prank(alice);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);

    (,,, int128 totalLiquidity) = hook.getPositionInfo(positionId);
    assertEq(
      uint128(totalLiquidity),
      initialLiquidity + additionalLiquidity,
      "Position liquidity should increase"
    );
  }

  /// @dev Increasing liquidity does not change position ownership or ticks
  function testFuzz_OwnerUnchangedAfterIncrease(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (address ownerBefore, int24 lowerBefore, int24 upperBefore,) = hook.getPositionInfo(positionId);
    assertEq(ownerBefore, alice, "Owner should start as alice");
    assertEq(lowerBefore, tickLower, "tickLower should not change");
    assertEq(upperBefore, tickUpper, "tickUpper should not change");

    vm.prank(alice);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);

    (address ownerAfter, int24 lowerAfter, int24 upperAfter,) = hook.getPositionInfo(positionId);
    assertEq(ownerAfter, alice, "Owner should remain alice");
    assertEq(lowerAfter, tickLower, "tickLower should not change");
    assertEq(upperAfter, tickUpper, "tickUpper should not change");
  }

  /// @dev Increasing updates tick liquidity gross
  function testFuzz_UpdatesTickLiquidityGross(uint128 initialLiquidity, uint128 additionalLiquidity)
    public
  {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    vm.prank(alice);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);

    (uint128 lowerGross,) = hook.getTickInfo(tickLower);
    (uint128 upperGross,) = hook.getTickInfo(tickUpper);

    assertEq(
      lowerGross,
      initialLiquidity + additionalLiquidity,
      "Lower tick liquidityGross should equal total liquidity"
    );
    assertEq(
      upperGross,
      initialLiquidity + additionalLiquidity,
      "Upper tick liquidityGross should equal total liquidity"
    );
  }

  /// @dev Increasing updates tick liquidity net correctly
  function testFuzz_UpdatesTickLiquidityNet(uint128 initialLiquidity, uint128 additionalLiquidity)
    public
  {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    vm.prank(alice);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);

    (, int128 lowerNet) = hook.getTickInfo(tickLower);
    (, int128 upperNet) = hook.getTickInfo(tickUpper);

    int128 expectedTotal = int128(initialLiquidity) + int128(additionalLiquidity);
    assertEq(lowerNet, expectedTotal, "Lower tick liquidityNet should be positive total");
    assertEq(upperNet, -expectedTotal, "Upper tick liquidityNet should be negative total");
  }

  /// @dev Tick bitmap bits remain set after increase (no flip since already initialized)
  function testFuzz_TickBitmapBitsRemainSet(uint128 initialLiquidity, uint128 additionalLiquidity)
    public
  {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 200;
    int24 tickUpper = currentTick + 200;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int16 lowerWord, uint8 lowerBit) = _bitmapPosition(tickLower);
    (int16 upperWord, uint8 upperBit) = _bitmapPosition(tickUpper);

    uint256 lowerWordBefore = hook.getTickBitmapWord(lowerWord);
    uint256 upperWordBefore = hook.getTickBitmapWord(upperWord);

    vm.prank(alice);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);

    uint256 lowerWordAfter = hook.getTickBitmapWord(lowerWord);
    uint256 upperWordAfter = hook.getTickBitmapWord(upperWord);
    assertEq(lowerWordAfter, lowerWordBefore, "Lower bitmap word should not change");
    if (upperWord != lowerWord) {
      assertEq(upperWordAfter, upperWordBefore, "Upper bitmap word should not change");
    }

    uint256 lowerMask = uint256(1) << lowerBit;
    uint256 upperMask = uint256(1) << upperBit;
    assertTrue((lowerWordAfter & lowerMask) != 0, "Lower tick bit should remain set");
    assertTrue((upperWordAfter & upperMask) != 0, "Upper tick bit should remain set");
  }

  // ============ Token Transfer Tests ============

  /// @dev Increasing transfers correct token amounts
  function testFuzz_TransfersCorrectAmounts(uint128 initialLiquidity, uint128 additionalLiquidity)
    public
  {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 expected0, int256 expected1) =
      _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);

    uint256 balance0Before = token0.balanceOf(alice);
    uint256 balance1Before = token1.balanceOf(alice);
    uint256 hookBalance0Before = token0.balanceOf(address(hook));
    uint256 hookBalance1Before = token1.balanceOf(address(hook));

    vm.prank(alice);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);

    assertEq(
      int256(balance0Before - token0.balanceOf(alice)),
      expected0,
      "User token0 debited should match expected"
    );
    assertEq(
      int256(balance1Before - token1.balanceOf(alice)),
      expected1,
      "User token1 debited should match expected"
    );
    assertEq(
      int256(token0.balanceOf(address(hook)) - hookBalance0Before),
      expected0,
      "Hook token0 credited should match expected"
    );
    assertEq(
      int256(token1.balanceOf(address(hook)) - hookBalance1Before),
      expected1,
      "Hook token1 credited should match expected"
    );
  }

  /// @dev Token conservation: total supply unchanged after increase
  function testFuzz_TokenConservation(uint128 initialLiquidity, uint128 additionalLiquidity)
    public
  {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    uint256 total0Before = token0.balanceOf(alice) + token0.balanceOf(address(hook));
    uint256 total1Before = token1.balanceOf(alice) + token1.balanceOf(address(hook));

    vm.prank(alice);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);

    uint256 total0After = token0.balanceOf(alice) + token0.balanceOf(address(hook));
    uint256 total1After = token1.balanceOf(alice) + token1.balanceOf(address(hook));

    assertEq(total0After, total0Before, "Token0 total should be conserved");
    assertEq(total1After, total1Before, "Token1 total should be conserved");
  }

  // ============ Active Liquidity Tests ============

  /// @dev Increasing updates active liquidity when position spans current tick
  function testFuzz_UpdatesActiveLiquidityWhenInRange(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);
    uint128 activeBefore = hook.getActiveLiquidity();

    vm.prank(alice);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);

    uint128 activeAfter = hook.getActiveLiquidity();
    assertEq(
      activeAfter,
      activeBefore + additionalLiquidity,
      "Active liquidity should increase by additional"
    );
  }

  /// @dev Increasing does not update active liquidity when position is below current tick
  function testFuzz_NoActiveLiquidityUpdateWhenBelow(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickUpper = currentTick - 100;
    int24 tickLower = tickUpper - 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);
    uint128 activeBefore = hook.getActiveLiquidity();

    vm.prank(alice);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);

    uint128 activeAfter = hook.getActiveLiquidity();
    assertEq(
      activeAfter, activeBefore, "Active liquidity should not change for below-range position"
    );
  }

  /// @dev Increasing does not update active liquidity when position is above current tick
  function testFuzz_NoActiveLiquidityUpdateWhenAbove(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick + 100;
    int24 tickUpper = tickLower + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);
    uint128 activeBefore = hook.getActiveLiquidity();

    vm.prank(alice);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);

    uint128 activeAfter = hook.getActiveLiquidity();
    assertEq(
      activeAfter, activeBefore, "Active liquidity should not change for above-range position"
    );
  }

  // ============ Multiple Operations Tests ============

  /// @dev Multiple increases accumulate correctly
  function testFuzz_MultipleIncreasesAccumulate(
    uint128 initialLiquidity,
    uint128 increase1,
    uint128 increase2
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    increase1 = uint128(bound(increase1, 1e17, 1e20));
    increase2 = uint128(bound(increase2, 1e17, 1e20));

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    vm.startPrank(alice);
    hook.increaseLiquidity(positionId, increase1, type(uint256).max, type(uint256).max);
    hook.increaseLiquidity(positionId, increase2, type(uint256).max, type(uint256).max);
    vm.stopPrank();

    (,,, int128 totalLiquidity) = hook.getPositionInfo(positionId);
    assertEq(
      uint128(totalLiquidity),
      initialLiquidity + increase1 + increase2,
      "Position liquidity should equal sum of all additions"
    );

    (uint128 lowerGross,) = hook.getTickInfo(tickLower);
    assertEq(
      lowerGross,
      initialLiquidity + increase1 + increase2,
      "Tick liquidity should equal sum of all additions"
    );
  }

  /// @dev Different users can increase their own positions at same ticks
  function testFuzz_MultipleUsersCanIncrease(uint128 aliceInitial, uint128 aliceIncrease) public {
    aliceInitial = _boundLiquidity(aliceInitial);
    aliceIncrease = uint128(bound(aliceIncrease, 1e17, 1e20));
    // Use fixed values for bob to avoid stack too deep
    uint128 bobInitial = 1e18;
    uint128 bobIncrease = 1e18;

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 alicePositionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, aliceInitial);
    bytes32 bobPositionId = _mintLiquidityAtTicks(bob, tickLower, tickUpper, bobInitial);

    vm.prank(alice);
    hook.increaseLiquidity(alicePositionId, aliceIncrease, type(uint256).max, type(uint256).max);

    vm.prank(bob);
    hook.increaseLiquidity(bobPositionId, bobIncrease, type(uint256).max, type(uint256).max);

    (,,, int128 aliceLiq) = hook.getPositionInfo(alicePositionId);
    (,,, int128 bobLiq) = hook.getPositionInfo(bobPositionId);

    assertEq(uint128(aliceLiq), aliceInitial + aliceIncrease, "Alice liquidity should match");
    assertEq(uint128(bobLiq), bobInitial + bobIncrease, "Bob liquidity should match");

    (uint128 lowerGross,) = hook.getTickInfo(tickLower);
    uint128 expectedTotal = aliceInitial + bobInitial + aliceIncrease + bobIncrease;
    assertEq(lowerGross, expectedTotal, "Tick should have combined liquidity");
  }

  // ============ Token Amount Tests Based on Position ============

  /// @dev Position below current tick: increase requires only token1 (cash)
  function testFuzz_BelowRangeOnlyToken1(uint128 initialLiquidity, uint128 additionalLiquidity)
    public
  {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickUpper = currentTick - 100;
    int24 tickLower = tickUpper - 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 expected0, int256 expected1) =
      _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);
    assertEq(expected0, 0, "Below-range increase should not require token0");
    assertGt(expected1, 0, "Below-range increase should require token1");

    uint256 balance0Before = token0.balanceOf(alice);
    uint256 balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);

    assertEq(
      int256(balance0Before - token0.balanceOf(alice)),
      expected0,
      "Token0 amount should match expected"
    );
    assertEq(
      int256(balance1Before - token1.balanceOf(alice)),
      expected1,
      "Token1 amount should match expected"
    );
  }

  /// @dev Position above current tick: increase requires only token0 (principal)
  function testFuzz_AboveRangeOnlyToken0(uint128 initialLiquidity, uint128 additionalLiquidity)
    public
  {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick + 100;
    int24 tickUpper = tickLower + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 expected0, int256 expected1) =
      _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);
    assertGt(expected0, 0, "Above-range increase should require token0");
    assertEq(expected1, 0, "Above-range increase should not require token1");

    uint256 balance0Before = token0.balanceOf(alice);
    uint256 balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);

    assertEq(
      int256(balance0Before - token0.balanceOf(alice)),
      expected0,
      "Token0 amount should match expected"
    );
    assertEq(
      int256(balance1Before - token1.balanceOf(alice)),
      expected1,
      "Token1 amount should match expected"
    );
  }

  /// @dev Position spanning current tick: increase requires both tokens
  function testFuzz_InRangeBothTokens(uint128 initialLiquidity, uint128 additionalLiquidity)
    public
  {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 expected0, int256 expected1) =
      _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);
    assertGt(expected0, 0, "In-range increase should require token0");
    assertGt(expected1, 0, "In-range increase should require token1");

    uint256 balance0Before = token0.balanceOf(alice);
    uint256 balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);

    assertEq(
      int256(balance0Before - token0.balanceOf(alice)),
      expected0,
      "Token0 amount should match expected"
    );
    assertEq(
      int256(balance1Before - token1.balanceOf(alice)),
      expected1,
      "Token1 amount should match expected"
    );
  }

  /// @dev Cash required for in-range increases changes over time (principal is time-invariant)
  function test_IncreaseCashRequiredChangesWithTime() public {
    uint128 initialLiquidity = 1e18;
    uint128 additionalLiquidity = 1e24;

    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 200;
    int24 tickUpper = currentTick + 200;

    _warpFromStart(1);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);
    uint256 snapshot = vm.snapshot();

    _warpFromStart(1);
    Amounts memory expected_t1;
    (expected_t1.amount0, expected_t1.amount1) =
      _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);
    Amounts memory used_t1;
    (used_t1.amount0, used_t1.amount1) = _increaseLiquidity(alice, positionId, additionalLiquidity);
    assertEq(used_t1.amount0, expected_t1.amount0, "Token0 at t1 should match expected");
    assertEq(used_t1.amount1, expected_t1.amount1, "Token1 at t1 should match expected");
    assertGt(expected_t1.amount0, 0, "Expected principal to be required");
    assertGt(expected_t1.amount1, 0, "Expected cash to be required");

    vm.revertTo(snapshot);
    _warpFromStart(30 days);
    Amounts memory expected_t2;
    (expected_t2.amount0, expected_t2.amount1) =
      _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);
    Amounts memory used_t2;
    (used_t2.amount0, used_t2.amount1) = _increaseLiquidity(alice, positionId, additionalLiquidity);
    assertEq(used_t2.amount0, expected_t2.amount0, "Token0 at t2 should match expected");
    assertEq(used_t2.amount1, expected_t2.amount1, "Token1 at t2 should match expected");
    assertEq(
      expected_t2.amount0, expected_t1.amount0, "Principal requirement should be time-invariant"
    );
    assertTrue(
      expected_t2.amount1 != expected_t1.amount1, "Cash requirement should change with time"
    );
  }

  // ============ Slippage Tests ============

  /// @dev Allows increase when slippage exactly met
  function testFuzz_AllowsWhen_SlippageExactlyMet(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 required0, int256 required1) =
      _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);

    uint256 required0U = uint256(required0);
    uint256 required1U = uint256(required1);
    vm.prank(alice);
    hook.increaseLiquidity(positionId, additionalLiquidity, required0U, required1U);

    // If we get here without reverting, the test passes
    (,,, int128 totalLiquidity) = hook.getPositionInfo(positionId);
    assertEq(
      uint128(totalLiquidity),
      initialLiquidity + additionalLiquidity,
      "Liquidity should be increased"
    );
  }

  // ============ Revert Tests ============

  function test_RevertWhen_PositionNotFound() public {
    bytes32 missingPositionId = keccak256("missing position");

    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__PositionNotFound.selector);
    hook.increaseLiquidity(missingPositionId, 1e18, type(uint256).max, type(uint256).max);
  }

  function testFuzz_RevertWhen_NotPositionOwner(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    vm.prank(bob);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__NotPositionOwner.selector);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);
  }

  /// @dev Reverts when token0 amount exceeds max (above-range position)
  function testFuzz_RevertWhen_Token0SlippageExceeded(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick + 100;
    int24 tickUpper = tickLower + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 required0, int256 required1) =
      _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);
    assertGt(required0, 0, "Expected token0 to be required");
    assertEq(required1, 0, "Expected token1 not to be required");

    uint256 required0U = uint256(required0);
    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidLiquidityAmount.selector);
    hook.increaseLiquidity(positionId, additionalLiquidity, required0U - 1, type(uint256).max);
  }

  /// @dev Reverts when token1 amount exceeds max (below-range position)
  function testFuzz_RevertWhen_Token1SlippageExceeded(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickUpper = currentTick - 100;
    int24 tickLower = tickUpper - 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 required0, int256 required1) =
      _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);
    assertEq(required0, 0, "Expected token0 not to be required");
    assertGt(required1, 0, "Expected token1 to be required");

    uint256 required1U = uint256(required1);
    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidLiquidityAmount.selector);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, required1U - 1);
  }

  /// @dev Reverts when token0 allowance is missing
  function testFuzz_RevertWhen_Token0AllowanceMissing(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick + 100;
    int24 tickUpper = tickLower + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 required0, int256 required1) =
      _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);
    assertGt(required0, 0, "Expected token0 to be required");
    assertEq(required1, 0, "Expected token1 not to be required");

    vm.startPrank(alice);
    token0.approve(address(hook), 0);
    vm.expectRevert(stdError.arithmeticError);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);
    vm.stopPrank();
  }

  /// @dev Reverts when token1 allowance is missing
  function testFuzz_RevertWhen_Token1AllowanceMissing(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickUpper = currentTick - 100;
    int24 tickLower = tickUpper - 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 required0, int256 required1) =
      _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);
    assertEq(required0, 0, "Expected token0 not to be required");
    assertGt(required1, 0, "Expected token1 to be required");

    vm.startPrank(alice);
    token1.approve(address(hook), 0);
    vm.expectRevert(stdError.arithmeticError);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);
    vm.stopPrank();
  }

  /// @dev Reverts when user has insufficient token0 balance
  function testFuzz_RevertWhen_InsufficientBalanceToken0(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick + 100;
    int24 tickUpper = tickLower + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 required0, int256 required1) =
      _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);
    assertGt(required0, 0, "Expected token0 to be required");
    assertEq(required1, 0, "Expected token1 not to be required");

    vm.startPrank(alice);
    token0.transfer(makeAddr("sink"), token0.balanceOf(alice));
    vm.expectRevert(stdError.arithmeticError);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);
    vm.stopPrank();
  }

  /// @dev Reverts when user has insufficient token1 balance
  function testFuzz_RevertWhen_InsufficientBalanceToken1(
    uint128 initialLiquidity,
    uint128 additionalLiquidity
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    additionalLiquidity = _boundLiquidity(additionalLiquidity);

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickUpper = currentTick - 100;
    int24 tickLower = tickUpper - 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 required0, int256 required1) =
      _expectedMintAmounts(tickLower, tickUpper, additionalLiquidity);
    assertEq(required0, 0, "Expected token0 not to be required");
    assertGt(required1, 0, "Expected token1 to be required");

    vm.startPrank(alice);
    token1.transfer(makeAddr("sink"), token1.balanceOf(alice));
    vm.expectRevert(stdError.arithmeticError);
    hook.increaseLiquidity(positionId, additionalLiquidity, type(uint256).max, type(uint256).max);
    vm.stopPrank();
  }
}

contract DecreaseLiquidity is FixedFeeSwapMarketTest {
  struct Amounts {
    uint256 amount0;
    uint256 amount1;
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

  // ============ Position Update Tests ============

  /// @dev Decreasing removes liquidity from position
  function testFuzz_RemovesFromPosition(uint128 initialLiquidity, uint128 removeAmount) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);

    (,,, int128 remainingLiquidity) = hook.getPositionInfo(positionId);
    assertEq(
      uint128(remainingLiquidity),
      initialLiquidity - removeAmount,
      "Position liquidity should decrease"
    );
  }

  /// @dev Decreasing does not change position ownership or ticks
  function testFuzz_OwnerUnchangedAfterDecrease(uint128 initialLiquidity, uint128 removeAmount)
    public
  {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (address ownerBefore, int24 lowerBefore, int24 upperBefore,) = hook.getPositionInfo(positionId);

    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);

    (address ownerAfter, int24 lowerAfter, int24 upperAfter,) = hook.getPositionInfo(positionId);
    assertEq(ownerAfter, ownerBefore, "Owner should not change");
    assertEq(lowerAfter, lowerBefore, "tickLower should not change");
    assertEq(upperAfter, upperBefore, "tickUpper should not change");
  }

  /// @dev Decreasing updates tick liquidity gross
  function testFuzz_UpdatesTickLiquidityGross(uint128 initialLiquidity, uint128 removeAmount)
    public
  {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);

    (uint128 lowerGross,) = hook.getTickInfo(tickLower);
    (uint128 upperGross,) = hook.getTickInfo(tickUpper);

    assertEq(
      lowerGross, initialLiquidity - removeAmount, "Lower tick liquidityGross should decrease"
    );
    assertEq(
      upperGross, initialLiquidity - removeAmount, "Upper tick liquidityGross should decrease"
    );
  }

  /// @dev Decreasing updates tick liquidity net correctly
  function testFuzz_UpdatesTickLiquidityNet(uint128 initialLiquidity, uint128 removeAmount) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);

    (, int128 lowerNet) = hook.getTickInfo(tickLower);
    (, int128 upperNet) = hook.getTickInfo(tickUpper);

    int128 expectedRemaining = int128(initialLiquidity) - int128(removeAmount);
    assertEq(lowerNet, expectedRemaining, "Lower tick liquidityNet should decrease");
    assertEq(upperNet, -expectedRemaining, "Upper tick liquidityNet should decrease (negative)");
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

  /// @dev Decreasing returns correct token amounts to user
  function testFuzz_ReturnsCorrectAmounts(uint128 initialLiquidity, uint128 removeAmount) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, removeAmount);

    uint256 balance0Before = token0.balanceOf(alice);
    uint256 balance1Before = token1.balanceOf(alice);
    uint256 hookBalance0Before = token0.balanceOf(address(hook));
    uint256 hookBalance1Before = token1.balanceOf(address(hook));

    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);

    assertEq(
      int256(token0.balanceOf(alice) - balance0Before),
      expected0,
      "User token0 received should match expected"
    );
    assertEq(
      int256(token1.balanceOf(alice) - balance1Before),
      expected1,
      "User token1 received should match expected"
    );
    assertEq(
      int256(hookBalance0Before - token0.balanceOf(address(hook))),
      expected0,
      "Hook token0 debited should match expected"
    );
    assertEq(
      int256(hookBalance1Before - token1.balanceOf(address(hook))),
      expected1,
      "Hook token1 debited should match expected"
    );
  }

  /// @dev Token conservation: total supply unchanged after decrease
  function testFuzz_TokenConservation(uint128 initialLiquidity, uint128 removeAmount) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    uint256 total0Before = token0.balanceOf(alice) + token0.balanceOf(address(hook));
    uint256 total1Before = token1.balanceOf(alice) + token1.balanceOf(address(hook));

    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);

    uint256 total0After = token0.balanceOf(alice) + token0.balanceOf(address(hook));
    uint256 total1After = token1.balanceOf(alice) + token1.balanceOf(address(hook));

    assertEq(total0After, total0Before, "Token0 total should be conserved");
    assertEq(total1After, total1Before, "Token1 total should be conserved");
  }

  // ============ Active Liquidity Tests ============

  /// @dev Decreasing updates active liquidity when position spans current tick
  function testFuzz_UpdatesActiveLiquidityWhenInRange(
    uint128 initialLiquidity,
    uint128 removeAmount
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);
    uint128 activeBefore = hook.getActiveLiquidity();

    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);

    uint128 activeAfter = hook.getActiveLiquidity();
    assertEq(activeAfter, activeBefore - removeAmount, "Active liquidity should decrease");
  }

  /// @dev Decreasing does not update active liquidity when position is below current tick
  function testFuzz_NoActiveLiquidityUpdateWhenBelow(uint128 initialLiquidity, uint128 removeAmount)
    public
  {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickUpper = currentTick - 100;
    int24 tickLower = tickUpper - 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);
    uint128 activeBefore = hook.getActiveLiquidity();

    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);

    uint128 activeAfter = hook.getActiveLiquidity();
    assertEq(
      activeAfter, activeBefore, "Active liquidity should not change for below-range position"
    );
  }

  /// @dev Decreasing does not update active liquidity when position is above current tick
  function testFuzz_NoActiveLiquidityUpdateWhenAbove(uint128 initialLiquidity, uint128 removeAmount)
    public
  {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick + 100;
    int24 tickUpper = tickLower + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);
    uint128 activeBefore = hook.getActiveLiquidity();

    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);

    uint128 activeAfter = hook.getActiveLiquidity();
    assertEq(
      activeAfter, activeBefore, "Active liquidity should not change for above-range position"
    );
  }

  // ============ Multiple Operations Tests ============

  /// @dev Multiple decreases accumulate correctly
  function testFuzz_MultipleDecreasesAccumulate(
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
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

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
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, baseAmount);

    uint256 balance0Before = token0.balanceOf(alice);
    uint256 balance1Before = token1.balanceOf(alice);

    vm.startPrank(alice);
    hook.decreaseLiquidity(positionId, -int128(deltaAmount), 0, 0);
    hook.increaseLiquidity(positionId, deltaAmount, type(uint256).max, type(uint256).max);
    vm.stopPrank();

    // Balances should be unchanged (decrease gives tokens, increase takes them back)
    assertEq(token0.balanceOf(alice), balance0Before, "Token0 should be symmetric");
    assertEq(token1.balanceOf(alice), balance1Before, "Token1 should be symmetric");

    // Liquidity should be back to original
    (,,, int128 finalLiquidity) = hook.getPositionInfo(positionId);
    assertEq(uint128(finalLiquidity), baseAmount, "Liquidity should return to original");
  }

  /// @dev Different users decreasing their own positions at same ticks
  function testFuzz_MultipleUsersCanDecrease(uint128 aliceInitial, uint128 aliceDecrease) public {
    aliceInitial = _boundLiquidity(aliceInitial);
    aliceDecrease = uint128(bound(aliceDecrease, 1e17, aliceInitial));
    uint128 bobInitial = 1e18;
    uint128 bobDecrease = 5e17;

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

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

  /// @dev Position below current tick: decrease returns only token1 (cash)
  function testFuzz_BelowRangeOnlyToken1(uint128 initialLiquidity, uint128 removeAmount) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickUpper = currentTick - 100;
    int24 tickLower = tickUpper - 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, removeAmount);
    assertEq(expected0, 0, "Below-range decrease should not return token0");
    assertGt(expected1, 0, "Below-range decrease should return token1");

    uint256 balance0Before = token0.balanceOf(alice);
    uint256 balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);

    assertEq(
      int256(token0.balanceOf(alice) - balance0Before),
      expected0,
      "Token0 received should match expected"
    );
    assertEq(
      int256(token1.balanceOf(alice) - balance1Before),
      expected1,
      "Token1 received should match expected"
    );
  }

  /// @dev Position above current tick: decrease returns only token0 (principal)
  function testFuzz_AboveRangeOnlyToken0(uint128 initialLiquidity, uint128 removeAmount) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick + 100;
    int24 tickUpper = tickLower + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, removeAmount);
    assertGt(expected0, 0, "Above-range decrease should return token0");
    assertEq(expected1, 0, "Above-range decrease should not return token1");

    uint256 balance0Before = token0.balanceOf(alice);
    uint256 balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);

    assertEq(
      int256(token0.balanceOf(alice) - balance0Before),
      expected0,
      "Token0 received should match expected"
    );
    assertEq(
      int256(token1.balanceOf(alice) - balance1Before),
      expected1,
      "Token1 received should match expected"
    );
  }

  /// @dev Position spanning current tick: decrease returns both tokens
  function testFuzz_InRangeBothTokens(uint128 initialLiquidity, uint128 removeAmount) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, removeAmount);
    assertGt(expected0, 0, "In-range decrease should return token0");
    assertGt(expected1, 0, "In-range decrease should return token1");

    uint256 balance0Before = token0.balanceOf(alice);
    uint256 balance1Before = token1.balanceOf(alice);

    vm.prank(alice);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);

    assertEq(
      int256(token0.balanceOf(alice) - balance0Before),
      expected0,
      "Token0 received should match expected"
    );
    assertEq(
      int256(token1.balanceOf(alice) - balance1Before),
      expected1,
      "Token1 received should match expected"
    );
  }

  /// @dev Cash returned for in-range decreases changes over time
  function test_DecreaseCashReturnedChangesWithTime() public {
    uint128 initialLiquidity = 1e24;
    uint128 removeAmount = 5e23;

    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 200;
    int24 tickUpper = currentTick + 200;

    _warpFromStart(1);
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);
    uint256 snapshot = vm.snapshot();

    // Decrease at time t1
    _warpFromStart(1);
    Amounts memory expected_t1;
    {
      (int256 e0, int256 e1) = _expectedMintAmounts(tickLower, tickUpper, removeAmount);
      expected_t1.amount0 = uint256(e0);
      expected_t1.amount1 = uint256(e1);
    }
    Amounts memory received_t1;
    (received_t1.amount0, received_t1.amount1) = _decreaseLiquidity(alice, positionId, removeAmount);
    assertEq(received_t1.amount0, expected_t1.amount0, "Token0 at t1 should match expected");
    assertEq(received_t1.amount1, expected_t1.amount1, "Token1 at t1 should match expected");

    vm.revertTo(snapshot);

    // Decrease at time t2
    _warpFromStart(30 days);
    Amounts memory expected_t2;
    {
      (int256 e0, int256 e1) = _expectedMintAmounts(tickLower, tickUpper, removeAmount);
      expected_t2.amount0 = uint256(e0);
      expected_t2.amount1 = uint256(e1);
    }
    Amounts memory received_t2;
    (received_t2.amount0, received_t2.amount1) = _decreaseLiquidity(alice, positionId, removeAmount);
    assertEq(received_t2.amount0, expected_t2.amount0, "Token0 at t2 should match expected");
    assertEq(received_t2.amount1, expected_t2.amount1, "Token1 at t2 should match expected");

    // Principal should be same, cash should differ
    assertEq(
      expected_t2.amount0, expected_t1.amount0, "Principal returned should be time-invariant"
    );
    assertNotEq(expected_t2.amount1, expected_t1.amount1, "Cash returned should change with time");
  }

  // ============ Slippage Tests ============

  /// @dev Allows decrease when slippage exactly met
  function testFuzz_AllowsWhen_SlippageExactlyMet(uint128 initialLiquidity, uint128 removeAmount)
    public
  {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, removeAmount);

    vm.prank(alice);
    hook.decreaseLiquidity(
      positionId, -int128(removeAmount), uint256(expected0), uint256(expected1)
    );

    // If we get here without reverting, the test passes
    (,,, int128 remainingLiquidity) = hook.getPositionInfo(positionId);
    assertEq(
      uint128(remainingLiquidity), initialLiquidity - removeAmount, "Liquidity should be decreased"
    );
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
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;
    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    vm.prank(bob);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__NotPositionOwner.selector);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, 0);
  }

  /// @dev Reverts when token0 amount is below min (above-range position)
  function testFuzz_RevertWhen_Token0SlippageExceeded(
    uint128 initialLiquidity,
    uint128 removeAmount
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick + 100;
    int24 tickUpper = tickLower + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, removeAmount);
    assertGt(expected0, 0, "Expected token0 to be returned");
    assertEq(expected1, 0, "Expected token1 not to be returned");

    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidLiquidityAmount.selector);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), uint256(expected0) + 1, 0);
  }

  /// @dev Reverts when token1 amount is below min (below-range position)
  function testFuzz_RevertWhen_Token1SlippageExceeded(
    uint128 initialLiquidity,
    uint128 removeAmount
  ) public {
    initialLiquidity = _boundLiquidity(initialLiquidity);
    removeAmount = uint128(bound(removeAmount, 1e17, initialLiquidity));

    _warpToMintTime();
    int24 currentTick = hook.getCurrentTick();
    int24 tickUpper = currentTick - 100;
    int24 tickLower = tickUpper - 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, removeAmount);
    assertEq(expected0, 0, "Expected token0 not to be returned");
    assertGt(expected1, 0, "Expected token1 to be returned");

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
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, removeAmount);
    assertGt(expected0, 0, "Expected token0 to be returned");
    assertGt(expected1, 0, "Expected token1 to be returned");

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
    int24 currentTick = hook.getCurrentTick();
    int24 tickLower = currentTick - 100;
    int24 tickUpper = currentTick + 100;

    bytes32 positionId = _mintLiquidityAtTicks(alice, tickLower, tickUpper, initialLiquidity);

    (int256 expected0, int256 expected1) = _expectedMintAmounts(tickLower, tickUpper, removeAmount);
    assertGt(expected0, 0, "Expected token0 to be returned");
    assertGt(expected1, 0, "Expected token1 to be returned");

    vm.prank(alice);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidLiquidityAmount.selector);
    hook.decreaseLiquidity(positionId, -int128(removeAmount), 0, uint256(expected1) + 1);
  }
}

// ============================================================================
// BeforeSwap Tests - Direct testing of the _beforeSwap hook function
// ============================================================================

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

    // Add liquidity for swap tests
    _warpToMintTime();
    // Main liquidity spanning a wide range
    _mintLiquidityAtTicks(alice, -1000, 1000, 1e22);
  }

  // ============ Helper Functions ============

  function _encodeHookParams(int256 amountIn, bool principalForCash, uint256 priceLimitWad)
    internal
    pure
    returns (bytes memory)
  {
    return abi.encode(amountIn, principalForCash, priceLimitWad);
  }

  function _swap(address sender, int256 amountIn, bool principalForCash, uint256 priceLimitWad)
    internal
    returns (bytes4, BeforeSwapDelta, uint24)
  {
    bytes memory hookParams = _encodeHookParams(amountIn, principalForCash, priceLimitWad);
    return hook.exposed_beforeSwap(sender, poolKey, defaultSwapParams, hookParams);
  }

  function _ptForOneBip() internal view returns (uint256) {
    return uint256(hook.getActiveLiquidity()) / BIPS;
  }

  function _initializePrice() internal returns (int256) {
    if (hook.getCurrentPrice() != 0) return hook.getCurrentPrice();

    int24 tick = hook.getCurrentTick();
    int256 expectedPrice = hook.tickToPrice(tick);
    _swap(bob, 1, true, uint256(expectedPrice));

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

    _swap(bob, int256(amountIn), true, 0);

    // User should have less TOKEN0
    assertLt(token0.balanceOf(bob), balance0Before, "User should send TOKEN0");
    // User may receive TOKEN1 (could be 0 for very small swaps due to precision)
    assertGe(token1.balanceOf(bob), balance1Before, "User should receive TOKEN1 or same");

    // Hook should have more TOKEN0
    assertGt(token0.balanceOf(address(hook)), hookBalance0Before, "Hook should receive TOKEN0");
    // Hook may send TOKEN1
    assertLe(token1.balanceOf(address(hook)), hookBalance1Before, "Hook should send TOKEN1 or same");
  }

  /// @dev Cash for principal: user sends TOKEN1, receives TOKEN0
  function testFuzz_CashForPrincipal_TransfersCorrectTokens(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);

    uint256 balance0Before = token0.balanceOf(bob);
    uint256 balance1Before = token1.balanceOf(bob);

    _swap(bob, int256(amountIn), false, 0);

    // User should have more TOKEN0, less TOKEN1
    assertGt(token0.balanceOf(bob), balance0Before, "User should receive TOKEN0");
    assertLt(token1.balanceOf(bob), balance1Before, "User should send TOKEN1");
  }

  /// @dev Token conservation: no tokens created or destroyed (principal->cash)
  function testFuzz_TokenConservation_PrincipalForCash(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);

    uint256 totalSupply0Before =
      token0.balanceOf(alice) + token0.balanceOf(bob) + token0.balanceOf(address(hook));
    uint256 totalSupply1Before =
      token1.balanceOf(alice) + token1.balanceOf(bob) + token1.balanceOf(address(hook));

    _swap(bob, int256(amountIn), true, 0);

    uint256 totalSupply0After =
      token0.balanceOf(alice) + token0.balanceOf(bob) + token0.balanceOf(address(hook));
    uint256 totalSupply1After =
      token1.balanceOf(alice) + token1.balanceOf(bob) + token1.balanceOf(address(hook));

    assertEq(totalSupply0After, totalSupply0Before, "TOKEN0 supply should be conserved");
    assertEq(totalSupply1After, totalSupply1Before, "TOKEN1 supply should be conserved");
  }

  /// @dev Token conservation: no tokens created or destroyed (cash->principal)
  function testFuzz_TokenConservation_CashForPrincipal(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);

    uint256 totalSupply0Before =
      token0.balanceOf(alice) + token0.balanceOf(bob) + token0.balanceOf(address(hook));
    uint256 totalSupply1Before =
      token1.balanceOf(alice) + token1.balanceOf(bob) + token1.balanceOf(address(hook));

    _swap(bob, int256(amountIn), false, 0);

    uint256 totalSupply0After =
      token0.balanceOf(alice) + token0.balanceOf(bob) + token0.balanceOf(address(hook));
    uint256 totalSupply1After =
      token1.balanceOf(alice) + token1.balanceOf(bob) + token1.balanceOf(address(hook));

    assertEq(totalSupply0After, totalSupply0Before, "TOKEN0 supply should be conserved");
    assertEq(totalSupply1After, totalSupply1Before, "TOKEN1 supply should be conserved");
  }

  /// @dev Input amount is consumed correctly for principal->cash
  function testFuzz_PrincipalInputConsumed(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);

    uint256 balance0Before = token0.balanceOf(bob);

    _swap(bob, int256(amountIn), true, 0);

    uint256 consumed = balance0Before - token0.balanceOf(bob);
    assertLe(consumed, amountIn, "Consumed should not exceed amountIn");
    assertGt(consumed, 0, "Some input should be consumed");
  }

  /// @dev Input amount is consumed correctly for cash->principal
  function testFuzz_CashInputConsumed(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);

    uint256 balance1Before = token1.balanceOf(bob);

    _swap(bob, int256(amountIn), false, 0);

    uint256 consumed = balance1Before - token1.balanceOf(bob);
    assertLe(consumed, amountIn, "Consumed should not exceed amountIn");
    assertGt(consumed, 0, "Some input should be consumed");
  }

  // ============ State Update Tests ============

  /// @dev Swap updates currentTick in correct direction for principal->cash
  function testFuzz_UpdatesCurrentTick_PrincipalForCash(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);
    int24 tickBefore = hook.getCurrentTick();

    _swap(bob, int256(amountIn), true, 0);

    int24 tickAfter = hook.getCurrentTick();
    assertGe(tickAfter, tickBefore, "Tick should increase for principal->cash");
  }

  /// @dev Swap updates currentTick in correct direction for cash->principal
  function testFuzz_UpdatesCurrentTick_CashForPrincipal(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);

    int24 tickBefore = hook.getCurrentTick();

    _swap(bob, int256(amountIn), false, 0);

    int24 tickAfter = hook.getCurrentTick();
    assertLe(tickAfter, tickBefore, "Tick should decrease for cash->principal");
  }

  /// @dev Swap updates currentPrice for principal->cash
  function testFuzz_UpdatesCurrentPrice_PrincipalForCash(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);

    // Initialize price if not set
    int256 priceBefore = hook.getCurrentPrice();
    if (priceBefore == 0) priceBefore = hook.tickToPrice(hook.getCurrentTick());

    _swap(bob, int256(amountIn), true, 0);

    int256 priceAfter = hook.getCurrentPrice();
    assertLe(priceAfter, priceBefore, "Price should decrease for principal->cash");
  }

  /// @dev Swap updates currentPrice for cash->principal
  function testFuzz_UpdatesCurrentPrice_CashForPrincipal(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);

    // Initialize price if not set
    int256 priceBefore = hook.getCurrentPrice();
    if (priceBefore == 0) priceBefore = hook.tickToPrice(hook.getCurrentTick());

    _swap(bob, int256(amountIn), false, 0);

    int256 priceAfter = hook.getCurrentPrice();
    assertGe(priceAfter, priceBefore, "Price should increase for cash->principal");
  }

  /// @dev Active liquidity unchanged when not crossing ticks
  function testFuzz_ActiveLiquidityUnchangedWithinTick(uint256 amountIn) public {
    // Use small amount to stay within current tick range
    amountIn = bound(amountIn, 1e15, 1e17);

    uint128 activeBefore = hook.getActiveLiquidity();

    _swap(bob, int256(amountIn), true, 0);

    // If no tick was crossed, active liquidity should be unchanged
    // (This may not hold if the swap crosses a tick boundary)
    uint128 activeAfter = hook.getActiveLiquidity();
    assertEq(activeAfter, activeBefore, "Active liquidity unchanged within tick");
  }

  // ============ Within-Tick Tests ============

  function testFuzz_WithinTick_SmallPTSwapProducesNonZeroCash(uint256 smallAmount) public {
    _warpFromStart(MARKET_LENGTH / 2);
    _initializePrice();

    uint256 ptForOneBip = _ptForOneBip();
    smallAmount = bound(smallAmount, ptForOneBip / 100, ptForOneBip - 1);

    uint128 liquidityBefore = hook.getActiveLiquidity();
    int24 tickBefore = hook.getCurrentTick();
    int256 priceBefore = hook.getCurrentPrice();
    int256 tickPriceBefore = hook.tickToPrice(tickBefore);
    uint256 cashBefore = token1.balanceOf(bob);

    _swap(bob, int256(smallAmount), true, 0);

    assertEq(
      hook.getActiveLiquidity(), liquidityBefore, "Active liquidity should not change within tick"
    );
    assertEq(hook.getCurrentTick(), tickBefore, "Tick should not change for sub-1-bip PT->cash");

    int256 priceAfter = hook.getCurrentPrice();
    uint256 cashOut = token1.balanceOf(bob) - cashBefore;

    assertTrue(priceAfter < priceBefore, "Price should decrease for PT->cash");
    assertTrue(cashOut > 0, "Small PT swap should produce non-zero cash output");
    assertTrue(priceAfter < tickPriceBefore, "Price should be strictly below tick price");
  }

  function testFuzz_WithinTick_SmallCashSwapProducesNonZeroPT(uint256 smallAmount) public {
    _warpFromStart(MARKET_LENGTH / 2);
    _initializePrice();

    // Move yield positive so we have room to swap back.
    uint256 setupAmount = _ptForOneBip() * 100;
    _swap(bob, int256(setupAmount), true, 0);

    smallAmount = bound(smallAmount, 1e16, 1e18);

    uint128 liquidityBefore = hook.getActiveLiquidity();
    int24 tickBefore = hook.getCurrentTick();
    int256 priceBefore = hook.getCurrentPrice();
    uint256 ptBefore = token0.balanceOf(bob);

    _swap(bob, int256(smallAmount), false, 0);

    assertEq(
      hook.getActiveLiquidity(), liquidityBefore, "Active liquidity should not change within tick"
    );

    int24 tickAfter = hook.getCurrentTick();
    int256 priceAfter = hook.getCurrentPrice();
    uint256 ptOut = token0.balanceOf(bob) - ptBefore;

    assertTrue(ptOut > 0, "Cash swap should produce non-zero PT output");
    assertTrue(priceAfter > priceBefore, "Price should increase for cash->PT");
    assertLe(tickAfter, tickBefore, "Tick should not increase for cash->PT");
  }

  function testFuzz_WithinTick_SmallPTSwap_ApproximatesLinear(uint256 smallAmount) public {
    _warpFromStart(MARKET_LENGTH / 2);
    _initializePrice();

    uint256 ptForOneBip = _ptForOneBip();
    smallAmount = bound(smallAmount, ptForOneBip / 1000, ptForOneBip / 10);

    uint128 liquidityBefore = hook.getActiveLiquidity();
    int24 tickBefore = hook.getCurrentTick();
    int256 priceBefore = hook.getCurrentPrice();
    uint256 cashBefore = token1.balanceOf(bob);

    _swap(bob, int256(smallAmount), true, 0);

    assertEq(
      hook.getActiveLiquidity(), liquidityBefore, "Active liquidity should not change within tick"
    );
    assertEq(hook.getCurrentTick(), tickBefore, "Tick should not change for sub-1-bip swap");

    uint256 cashOut = token1.balanceOf(bob) - cashBefore;
    uint256 expectedLinear = (uint256(priceBefore) * smallAmount) / SCALE_FACTOR;

    _assertApproxEqRelBps(cashOut, expectedLinear, 500, "Small PT swap should approximate linear");
  }

  function testFuzz_WithinTick_SmallCashSwap_ApproximatesLinear(uint256 smallAmount) public {
    _warpFromStart(MARKET_LENGTH / 2);
    _initializePrice();

    uint256 setupAmount = _ptForOneBip() * 100;
    _swap(bob, int256(setupAmount), true, 0);

    smallAmount = bound(smallAmount, 1e15, 1e17);

    uint128 liquidityBefore = hook.getActiveLiquidity();
    int24 tickBefore = hook.getCurrentTick();
    int256 priceBefore = hook.getCurrentPrice();
    assertTrue(priceBefore > 0, "Price must be initialized");
    uint256 ptBefore = token0.balanceOf(bob);

    _swap(bob, int256(smallAmount), false, 0);

    assertEq(
      hook.getActiveLiquidity(), liquidityBefore, "Active liquidity should not change within tick"
    );
    assertLe(hook.getCurrentTick(), tickBefore, "Tick should not increase for cash->PT swap");

    uint256 ptOut = token0.balanceOf(bob) - ptBefore;
    uint256 expectedLinear = (smallAmount * SCALE_FACTOR) / uint256(priceBefore);

    _assertApproxEqRelBps(ptOut, expectedLinear, 2000, "Cash swap should approximate linear");
  }

  function test_WithinTick_FractionalMove_UpdatesPriceButNotTick() public {
    _warpFromStart(MARKET_LENGTH / 2);
    _initializePrice();

    uint256 subBipAmount = _ptForOneBip() / 10;

    uint128 liquidityBefore = hook.getActiveLiquidity();
    int24 tickBefore = hook.getCurrentTick();
    int256 priceBefore = hook.getCurrentPrice();
    int256 tickPriceBefore = hook.tickToPrice(tickBefore);
    uint256 cashBefore = token1.balanceOf(bob);

    _swap(bob, int256(subBipAmount), true, 0);

    assertEq(
      hook.getActiveLiquidity(), liquidityBefore, "Active liquidity should not change within tick"
    );
    assertEq(hook.getCurrentTick(), tickBefore, "Tick should not change for sub-1-bip PT->cash");

    int256 priceAfter = hook.getCurrentPrice();
    uint256 cashOut = token1.balanceOf(bob) - cashBefore;

    assertTrue(priceAfter != priceBefore, "Price must change even for sub-bip swaps");
    assertTrue(priceAfter < priceBefore, "Price should decrease for PT->cash");
    assertTrue(cashOut > 0, "Fractional swap should produce non-zero output");
    assertTrue(priceAfter < tickPriceBefore, "Price should be strictly below tick price");

    _swap(bob, int256(subBipAmount), true, 0);
    assertEq(hook.getCurrentTick(), tickBefore, "Tick should remain unchanged across repeats");
    assertEq(
      hook.getActiveLiquidity(),
      liquidityBefore,
      "Active liquidity should remain unchanged across repeats"
    );
    int256 priceAfter2 = hook.getCurrentPrice();
    assertTrue(priceAfter2 <= priceAfter, "Price should not increase for repeated PT->cash");
    assertTrue(priceAfter2 < tickPriceBefore, "Price should remain below tick price");
  }

  // ============ Tick Crossing Tests ============

  /// @dev Crossing tick updates active liquidity
  function test_CrossingTickUpdatesActiveLiquidity() public {
    // Setup: narrow position that we'll cross out of
    uint128 narrowLiquidity = 1e21;
    _mintLiquidityAtTicks(alice, -10, 10, narrowLiquidity);

    uint128 activeBefore = hook.getActiveLiquidity();
    uint256 swapAmount = uint256(activeBefore) * 11 / BIPS; // > 10 ticks worth of principal
    _swap(bob, int256(swapAmount), true, 0);

    assertGe(int256(hook.getCurrentTick()), int256(10), "Should cross tick +10");
    assertLt(
      uint256(hook.getActiveLiquidity()), uint256(activeBefore), "Active liquidity should decrease"
    );
  }

  /// @dev Multiple positions at different tick ranges
  function test_MultipleTickCrossings() public {
    // Setup positions at multiple tick ranges
    _mintLiquidityAtTicks(alice, -200, -100, 1e20);
    _mintLiquidityAtTicks(alice, -100, 100, 1e20);
    _mintLiquidityAtTicks(alice, 100, 200, 1e20);

    int24 tickBefore = hook.getCurrentTick();

    // Move far enough to cross multiple initialized ticks in this word.
    uint256 swapAmount = uint256(hook.getActiveLiquidity()) * 400 / BIPS;
    _swap(bob, int256(swapAmount), true, 0);

    int24 tickAfter = hook.getCurrentTick();
    assertGt(int256(tickAfter), int256(tickBefore), "Tick should increase");
    assertGe(int256(tickAfter), int256(200), "Should cross tick +200");
  }

  /// @dev Swap into position from below increases active liquidity
  function test_CrossingIntoPositionIncreasesLiquidity() public {
    // Create position above current tick
    int24 currentTick = hook.getCurrentTick();
    _mintLiquidityAtTicks(alice, currentTick + 50, currentTick + 150, 1e20);

    uint128 activeBefore = hook.getActiveLiquidity();

    // Cross into the position by crossing its lower tick.
    uint256 swapAmount = uint256(activeBefore) * 60 / BIPS;
    _swap(bob, int256(swapAmount), true, 0);

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
    _mintLiquidityAtTicks(alice, -1000, 1000, extraLiquidity);

    uint128 activeBefore = hook.getActiveLiquidity();
    int24 tickBefore = hook.getCurrentTick();
    int256 priceBefore = hook.tickToPrice(tickBefore);

    int24 nextTick = 255;
    (uint256 principalInToBoundary,, int256 boundaryPrice, int24 stepTick) =
      hook.exposed_getCashSwapAmount(int256(1e36), priceBefore, nextTick);
    assertEq(stepTick, nextTick, "Should step to the word boundary tick");

    _swap(bob, int256(principalInToBoundary), true, 0);

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
    _mintLiquidityAtTicks(alice, -20, -10, belowRangeLiquidity);

    uint128 activeBefore = hook.getActiveLiquidity();
    int24 tickBefore = hook.getCurrentTick();
    int256 priceBefore = hook.tickToPrice(tickBefore);

    (uint256 cashInToBoundary,, int256 boundaryPrice, int24 stepTick) =
      hook.exposed_getPrincipalSwapAmount(int256(1e36), priceBefore, -10);
    assertEq(stepTick, int24(-10), "Should step to upper tick");

    uint256 balance1Before = token1.balanceOf(bob);
    _swap(bob, int256(cashInToBoundary), false, 0);

    assertEq(
      balance1Before - token1.balanceOf(bob), cashInToBoundary, "Should consume cash to boundary"
    );
    assertEq(hook.getCurrentPrice(), boundaryPrice, "Price should move to boundary price");
    assertEq(hook.getCurrentTick(), int24(-11), "Moving left leaves tick just below boundary");
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
    _mintLiquidityAtTicks(alice, -10, 10, narrowLiquidity);

    uint128 activeBefore = hook.getActiveLiquidity();
    int24 tickBefore = hook.getCurrentTick();
    int256 priceBefore = hook.tickToPrice(tickBefore);

    (uint256 cashInToBoundary,, int256 boundaryPrice, int24 stepTick) =
      hook.exposed_getPrincipalSwapAmount(int256(1e36), priceBefore, -10);
    assertEq(stepTick, int24(-10), "Should step to lower tick");

    uint256 balance1Before = token1.balanceOf(bob);
    _swap(bob, int256(cashInToBoundary), false, 0);

    assertEq(
      balance1Before - token1.balanceOf(bob), cashInToBoundary, "Should consume cash to boundary"
    );
    assertEq(hook.getCurrentPrice(), boundaryPrice, "Price should move to boundary price");
    assertEq(hook.getCurrentTick(), int24(-11), "Moving left leaves tick just below boundary");
    assertEq(
      uint256(hook.getActiveLiquidity()),
      uint256(activeBefore) - uint256(narrowLiquidity),
      "Active liquidity should decrease"
    );
  }

  // ============ Price Limit Tests ============

  /// @dev Price limit stops swap for principal->cash
  function testFuzz_PriceLimitStopsSwap_PrincipalForCash(uint256 amountIn) public {
    amountIn = bound(amountIn, 1e17, 1e20);

    int256 currentPrice = hook.tickToPrice(hook.getCurrentTick());
    // Set limit slightly below current price (95%)
    uint256 priceLimit = uint256(currentPrice) * 95 / 100;

    uint256 balance0Before = token0.balanceOf(bob);

    _swap(bob, int256(amountIn), true, priceLimit);

    // Might not consume full amountIn due to limit
    uint256 consumed = balance0Before - token0.balanceOf(bob);
    assertLe(consumed, amountIn, "Should not exceed amountIn");

    if (consumed < amountIn) {
      int256 finalPrice = hook.getCurrentPrice();
      assertLe(uint256(finalPrice.abs()), priceLimit, "Price should meet/cross limit");
    }
  }

  /// @dev If the price limit is already satisfied at entry, the swap should be a no-op (except lazy
  /// price init).
  function testFuzz_PriceLimitAlreadyHit_PrincipalForCash_NoOp(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);
    assertEq(
      hook.getCurrentPrice(), hook.tickToPrice(hook.getCurrentTick()), "Assumes lazy price init"
    );
    int24 tickBefore = hook.getCurrentTick();
    uint128 activeBefore = hook.getActiveLiquidity();
    int256 expectedPrice = hook.tickToPrice(tickBefore);

    uint256 balance0Before = token0.balanceOf(bob);
    uint256 balance1Before = token1.balanceOf(bob);
    uint256 hookBalance0Before = token0.balanceOf(address(hook));
    uint256 hookBalance1Before = token1.balanceOf(address(hook));

    // For principal->cash we stop when `currentPrice <= priceLimit`.
    (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
      _swap(bob, int256(amountIn), true, uint256(expectedPrice));

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

  /// @dev If the price limit is already satisfied at entry, the swap should be a no-op (except lazy
  /// price init).
  function testFuzz_PriceLimitAlreadyHit_CashForPrincipal_NoOp(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);
    assertEq(
      hook.getCurrentPrice(), hook.tickToPrice(hook.getCurrentTick()), "Assumes lazy price init"
    );
    int24 tickBefore = hook.getCurrentTick();
    uint128 activeBefore = hook.getActiveLiquidity();
    int256 expectedPrice = hook.tickToPrice(tickBefore);

    uint256 balance0Before = token0.balanceOf(bob);
    uint256 balance1Before = token1.balanceOf(bob);
    uint256 hookBalance0Before = token0.balanceOf(address(hook));
    uint256 hookBalance1Before = token1.balanceOf(address(hook));

    // For cash->principal we stop when `currentPrice >= priceLimit`.
    (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
      _swap(bob, int256(amountIn), false, uint256(expectedPrice));

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

  /// @dev Zero price limit allows full swap
  function testFuzz_ZeroPriceLimitAllowsFullSwap(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);

    uint256 balance0Before = token0.balanceOf(bob);

    _swap(bob, int256(amountIn), true, 0);

    // Should consume the full amountIn (or until liquidity exhausted)
    uint256 consumed = balance0Before - token0.balanceOf(bob);
    // With enough liquidity, full amount should be consumed
    assertEq(consumed, amountIn, "Full amount should be consumed with no price limit");
  }

  /// @dev Zero price limit allows full swap (cash->principal).
  function testFuzz_ZeroPriceLimitAllowsFullSwap_CashForPrincipal(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);

    uint256 balance1Before = token1.balanceOf(bob);

    _swap(bob, int256(amountIn), false, 0);

    uint256 consumed = balance1Before - token1.balanceOf(bob);
    assertEq(consumed, amountIn, "Full amount should be consumed with no price limit");
  }

  /// @dev Price limit for cash->principal
  function testFuzz_PriceLimitStopsSwap_CashForPrincipal(uint256 amountIn) public {
    amountIn = bound(amountIn, 1e17, 1e20);

    int256 currentPrice = hook.tickToPrice(hook.getCurrentTick());
    // Set limit above current price (105%)
    uint256 priceLimit = uint256(currentPrice) * 105 / 100;

    uint256 balance1Before = token1.balanceOf(bob);

    _swap(bob, int256(amountIn), false, priceLimit);

    // Might not consume full amountIn due to limit
    uint256 consumed = balance1Before - token1.balanceOf(bob);
    assertLe(consumed, amountIn, "Should not exceed amountIn");

    if (consumed < amountIn) {
      int256 finalPrice = hook.getCurrentPrice();
      assertGe(uint256(finalPrice.abs()), priceLimit, "Price should meet/cross limit");
    }
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

    // Swap should still work
    uint256 balance0Before = token0.balanceOf(bob);

    _swap(bob, int256(1e17), true, 0);

    assertLt(token0.balanceOf(bob), balance0Before, "Swap should work near maturity");
  }

  /// @dev Minimum swap amount
  function test_MinimumSwapAmount() public {
    // Smallest reasonable swap
    uint256 minAmount = 1e15;

    uint256 balance0Before = token0.balanceOf(bob);

    _swap(bob, int256(minAmount), true, 0);

    uint256 consumed = balance0Before - token0.balanceOf(bob);
    assertGt(consumed, 0, "Minimum swap should consume some input");
  }

  /// @dev Sequential swaps in same direction
  function testFuzz_SequentialSwaps_SameDirection(uint256 amount1, uint256 amount2) public {
    amount1 = _boundSwapAmount(amount1);
    amount2 = _boundSwapAmount(amount2);

    int24 tickBefore = hook.getCurrentTick();

    _swap(bob, int256(amount1), true, 0);
    int24 tickAfter1 = hook.getCurrentTick();

    _swap(bob, int256(amount2), true, 0);
    int24 tickAfter2 = hook.getCurrentTick();

    // Each swap should increase tick (or stay same)
    assertGe(tickAfter1, tickBefore, "First swap increases tick");
    assertGe(tickAfter2, tickAfter1, "Second swap increases tick further");
  }

  /// @dev Sequential swaps in opposite directions
  function testFuzz_SequentialSwaps_OppositeDirections(uint256 amount1, uint256 amount2) public {
    // Use smaller bounded amounts to avoid hitting tick boundary edge cases
    amount1 = bound(amount1, 1e15, 1e18);
    amount2 = bound(amount2, 1e15, 1e18);

    int24 tickBefore = hook.getCurrentTick();

    // Swap principal for cash (tick increases)
    _swap(bob, int256(amount1), true, 0);
    int24 tickAfter1 = hook.getCurrentTick();

    // Swap cash for principal (tick decreases)
    _swap(bob, int256(amount2), false, 0);
    int24 tickAfter2 = hook.getCurrentTick();

    // First swap increases, second decreases
    assertGe(tickAfter1, tickBefore, "First swap increases tick");
    assertLe(tickAfter2, tickAfter1, "Second swap decreases tick");
  }

  /// @dev Different users can swap
  function testFuzz_MultipleUsersSwap(uint256 amountAlice, uint256 amountBob) public {
    amountAlice = _boundSwapAmount(amountAlice);
    amountBob = _boundSwapAmount(amountBob);

    uint256 aliceBalance0Before = token0.balanceOf(alice);
    uint256 bobBalance0Before = token0.balanceOf(bob);

    _swap(alice, int256(amountAlice), true, 0);
    _swap(bob, int256(amountBob), true, 0);

    assertLt(token0.balanceOf(alice), aliceBalance0Before, "Alice spent tokens");
    assertLt(token0.balanceOf(bob), bobBalance0Before, "Bob spent tokens");
  }

  // ============ Return Value Tests ============

  /// @dev Returns correct selector
  function testFuzz_ReturnsCorrectSelector(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);

    (bytes4 selector,,) = _swap(bob, int256(amountIn), true, 0);

    assertEq(selector, BaseHook.beforeSwap.selector, "Should return beforeSwap selector");
  }

  /// @dev Returns zero delta (direct transfer model)
  function testFuzz_ReturnsZeroDelta_PrincipalForCash(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);

    (, BeforeSwapDelta delta,) = _swap(bob, int256(amountIn), true, 0);

    // Our hook uses direct transfers, so it returns (0, 0) delta
    assertEq(BeforeSwapDelta.unwrap(delta), 0, "Should return zero delta");
  }

  function testFuzz_ReturnsZeroDelta_CashForPrincipal(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);

    (, BeforeSwapDelta delta,) = _swap(bob, int256(amountIn), false, 0);
    assertEq(BeforeSwapDelta.unwrap(delta), 0, "Should return zero delta");
  }

  /// @dev Returns zero fee
  function testFuzz_ReturnsZeroFee_PrincipalForCash(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);

    (,, uint24 fee) = _swap(bob, int256(amountIn), true, 0);

    assertEq(fee, 0, "Should return zero fee");
  }

  function testFuzz_ReturnsZeroFee_CashForPrincipal(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);

    (,, uint24 fee) = _swap(bob, int256(amountIn), false, 0);
    assertEq(fee, 0, "Should return zero fee");
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
    bytes memory hookParams = _encodeHookParams(0, true, 0);

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__SwapAmountCannotBeZero.selector);
    hook.exposed_beforeSwap(bob, poolKey, defaultSwapParams, hookParams);
  }

  /// @dev Reverts when amountIn is negative
  function testFuzz_RevertWhen_AmountInIsNegative(int256 amountIn) public {
    amountIn = bound(amountIn, type(int256).min, -1);
    bytes memory hookParams = _encodeHookParams(amountIn, true, 0);

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__SwapAmountCannotBeZero.selector);
    hook.exposed_beforeSwap(bob, poolKey, defaultSwapParams, hookParams);
  }

  function test_RevertWhen_TimeElapsedIsZero() public {
    vm.warp(hook.getStartTime());
    bytes memory hookParams = _encodeHookParams(1e18, true, 0);

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__TimeElapsedIsZero.selector);
    hook.exposed_beforeSwap(bob, poolKey, defaultSwapParams, hookParams);
  }

  /// @dev Reverts when no active liquidity
  function test_RevertWhen_NoActiveLiquidity() public {
    // Deploy fresh hook with no liquidity
    address mockManager = makeAddr("freshMockManager");
    FixedFeeSwapMarketHarness freshHook = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH, address(token0), address(token1), FEE_RATE, IPoolManager(mockManager)
    );

    vm.warp(block.timestamp + 1 days);

    PoolKey memory freshPoolKey = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 0,
      tickSpacing: 1,
      hooks: IHooks(address(freshHook))
    });

    bytes memory hookParams = _encodeHookParams(1e18, true, 0);

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__NoActiveLiquidity.selector);
    freshHook.exposed_beforeSwap(bob, freshPoolKey, defaultSwapParams, hookParams);
  }

  /// @dev Reverts if liquidity is exhausted mid-swap and there is remaining input
  /// (principal->cash).
  function testFuzz_RevertWhen_LiquidityExhaustedMidSwap_PrincipalForCash(uint128 liq) public {
    address mockManager = makeAddr("freshMockManager2");
    FixedFeeSwapMarketHarness freshHook = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH, address(token0), address(token1), FEE_RATE, IPoolManager(mockManager)
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
    freshHook.mintLiquidity(-10, 10, liq, type(uint256).max, type(uint256).max);
    vm.stopPrank();

    int256 price = freshHook.tickToPrice(freshHook.getCurrentTick());
    (uint256 principalToBoundary,,,) = freshHook.exposed_getCashSwapAmount(int256(1e36), price, 10);

    bytes memory hookParams = _encodeHookParams(int256(principalToBoundary + 1), true, 0);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidTickTraversal.selector);
    freshHook.exposed_beforeSwap(bob, freshPoolKey, defaultSwapParams, hookParams);
  }

  /// @dev Reverts if liquidity is exhausted mid-swap and there is remaining input
  /// (cash->principal).
  function testFuzz_RevertWhen_LiquidityExhaustedMidSwap_CashForPrincipal(uint128 liq) public {
    address mockManager = makeAddr("freshMockManager3");
    FixedFeeSwapMarketHarness freshHook = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH, address(token0), address(token1), FEE_RATE, IPoolManager(mockManager)
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
    freshHook.mintLiquidity(-10, 10, liq, type(uint256).max, type(uint256).max);
    vm.stopPrank();

    int256 price = freshHook.tickToPrice(freshHook.getCurrentTick());
    (uint256 cashInToBoundary,,,) =
      freshHook.exposed_getPrincipalSwapAmount(int256(1e36), price, -10);

    bytes memory hookParams = _encodeHookParams(int256(cashInToBoundary + 1), false, 0);
    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InvalidTickTraversal.selector);
    freshHook.exposed_beforeSwap(bob, freshPoolKey, defaultSwapParams, hookParams);
  }

  /// @dev Reverts when insufficient allowance for principal->cash
  function testFuzz_RevertWhen_InsufficientAllowance_PrincipalForCash(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);

    // Remove approval for token0
    vm.prank(bob);
    token0.approve(address(hook), 0);

    bytes memory hookParams = _encodeHookParams(int256(amountIn), true, 0);

    vm.expectRevert(stdError.arithmeticError);
    hook.exposed_beforeSwap(bob, poolKey, defaultSwapParams, hookParams);
  }

  /// @dev Reverts when insufficient allowance for cash->principal
  function testFuzz_RevertWhen_InsufficientAllowance_CashForPrincipal(uint256 amountIn) public {
    amountIn = _boundSwapAmount(amountIn);

    // Remove approval for token1
    vm.prank(bob);
    token1.approve(address(hook), 0);

    bytes memory hookParams = _encodeHookParams(int256(amountIn), false, 0);

    vm.expectRevert(stdError.arithmeticError);
    hook.exposed_beforeSwap(bob, poolKey, defaultSwapParams, hookParams);
  }

  /// @dev Reverts when insufficient balance
  function test_RevertWhen_InsufficientBalance() public {
    address poorUser = makeAddr("poorUser");

    // Approve but no balance
    vm.prank(poorUser);
    token0.approve(address(hook), type(uint256).max);

    bytes memory hookParams = _encodeHookParams(1e18, true, 0);

    vm.expectRevert(stdError.arithmeticError);
    hook.exposed_beforeSwap(poorUser, poolKey, defaultSwapParams, hookParams);
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
      MARKET_LENGTH, address(token0), address(token1), TEST_FEE_RATE, IPoolManager(mockManager)
    );

    // Warp forward to avoid TimeElapsedIsZero
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
    feeHook.mintLiquidity(-100, 100, 1e20, type(uint256).max, type(uint256).max);

    uint256 feeGrowthBefore = feeHook.feeGrowthGlobal0X128();
    assertEq(feeGrowthBefore, 0);

    // Swap principal for cash
    bytes memory hookParams = abi.encode(int256(1e18), true, uint256(0));
    feeHook.exposed_beforeSwap(bob, feePoolKey, defaultSwapParams, hookParams);

    uint256 feeGrowthAfter = feeHook.feeGrowthGlobal0X128();
    assertGt(feeGrowthAfter, 0, "Fee growth should increase after swap");
  }

  /// @dev Swapper receives less output due to fees
  function test_SwapOutputIsReducedByFees() public {
    // Mint liquidity on both hooks
    vm.prank(alice);
    hook.mintLiquidity(-100, 100, 1e20, type(uint256).max, type(uint256).max);

    vm.prank(alice);
    feeHook.mintLiquidity(-100, 100, 1e20, type(uint256).max, type(uint256).max);

    uint256 swapAmount = 1e18;

    // Swap on zero-fee hook
    uint256 bob0Before = token0.balanceOf(bob);
    uint256 bob1Before = token1.balanceOf(bob);

    bytes memory hookParams = abi.encode(int256(swapAmount), true, uint256(0));
    hook.exposed_beforeSwap(bob, poolKey, defaultSwapParams, hookParams);

    uint256 outputNoFee = token1.balanceOf(bob) - bob1Before;
    uint256 inputNoFee = bob0Before - token0.balanceOf(bob);

    // Reset bob's balances for second swap
    token0.mint(bob, inputNoFee);

    // Swap on fee hook
    bob0Before = token0.balanceOf(bob);
    bob1Before = token1.balanceOf(bob);

    feeHook.exposed_beforeSwap(bob, feePoolKey, defaultSwapParams, hookParams);

    uint256 outputWithFee = token1.balanceOf(bob) - bob1Before;
    uint256 inputWithFee = bob0Before - token0.balanceOf(bob);

    // Output should be less with fees
    assertLt(outputWithFee, outputNoFee, "Output should be less with fees");
    // Input should be the same (gross amount)
    assertEq(inputWithFee, inputNoFee, "Input should be the same");
  }

  /// @dev LP can collect fees after swaps
  function test_CollectFees_AfterSwaps() public {
    // Mint wide liquidity range
    vm.prank(alice);
    feeHook.mintLiquidity(-100, 200, 1e20, type(uint256).max, type(uint256).max);

    bytes32 positionId = keccak256(abi.encodePacked(int24(200), int24(-100), alice));

    // Multiple swaps to accumulate fees (smaller amounts to stay in range)
    for (uint256 i = 0; i < 5; i++) {
      bytes memory hookParams = abi.encode(int256(1e17), true, uint256(0));
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
    feeHook.mintLiquidity(-100, 100, 1e20, type(uint256).max, type(uint256).max);

    bytes32 positionId = keccak256(abi.encodePacked(int24(100), int24(-100), alice));

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__NotPositionOwner.selector);
    vm.prank(bob);
    feeHook.collectFees(positionId, bob, 0, 0);
  }

  /// @dev Fees are split proportionally among LPs in range
  function test_FeesProportionalToLiquidity() public {
    // Alice and Bob both mint wide positions, but Alice has 2x liquidity
    vm.prank(alice);
    feeHook.mintLiquidity(-100, 200, 2e20, type(uint256).max, type(uint256).max);

    vm.prank(bob);
    feeHook.mintLiquidity(-100, 200, 1e20, type(uint256).max, type(uint256).max);

    bytes32 alicePositionId = keccak256(abi.encodePacked(int24(200), int24(-100), alice));
    bytes32 bobPositionId = keccak256(abi.encodePacked(int24(200), int24(-100), bob));

    // Execute swaps (smaller amounts to stay in range)
    address carol = makeAddr("carol");
    _fundUser(carol);
    vm.prank(carol);
    token0.approve(address(feeHook), type(uint256).max);

    for (uint256 i = 0; i < 10; i++) {
      bytes memory hookParams = abi.encode(int256(1e17), true, uint256(0));
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
    feeHook.mintLiquidity(-100, 200, 1e20, type(uint256).max, type(uint256).max);

    // Bob mints out-of-range position (only cash side, below current tick)
    vm.prank(bob);
    feeHook.mintLiquidity(-200, -150, 1e20, type(uint256).max, type(uint256).max);

    bytes32 alicePositionId = keccak256(abi.encodePacked(int24(200), int24(-100), alice));
    bytes32 bobPositionId = keccak256(abi.encodePacked(int24(-150), int24(-200), bob));

    // Execute principal->cash swaps (tick moves up, away from Bob's position)
    // Use smaller amounts to stay in range
    address carol = makeAddr("carol");
    _fundUser(carol);
    vm.prank(carol);
    token0.approve(address(feeHook), type(uint256).max);

    for (uint256 i = 0; i < 5; i++) {
      bytes memory hookParams = abi.encode(int256(1e17), true, uint256(0));
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
    feeHook.mintLiquidity(-100, 100, 1e20, type(uint256).max, type(uint256).max);

    bytes32 positionId = keccak256(abi.encodePacked(int24(100), int24(-100), alice));

    // Execute some swaps to generate fees
    bytes memory hookParams = abi.encode(int256(1e18), true, uint256(0));
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
    feeHook.mintLiquidity(-100, 200, 2e20, type(uint256).max, type(uint256).max);

    vm.prank(alice);
    feeHook.mintLiquidity(-100, 200, 1e20, type(uint256).max, type(uint256).max);

    bytes32 alicePositionId = keccak256(abi.encodePacked(int24(200), int24(-100), alice));

    // Generate some fees while Alice is in range, then fully burn and collect to zero owed
    bytes memory hookParams = abi.encode(int256(1e18), true, uint256(0));
    feeHook.exposed_beforeSwap(bob, feePoolKey, defaultSwapParams, hookParams);

    (,,, int128 liqBefore) = feeHook.getPositionInfo(alicePositionId);
    vm.prank(alice);
    feeHook.decreaseLiquidity(alicePositionId, -liqBefore, 0, 0);

    vm.prank(alice);
    feeHook.collectFees(alicePositionId, alice, 0, 0);

    // Generate fees while Alice has zero liquidity
    for (uint256 i = 0; i < 5; i++) {
      bytes memory stepParams = abi.encode(int256(1e17), true, uint256(0));
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
    feeHook.mintLiquidity(-100, 100, 1e20, type(uint256).max, type(uint256).max);

    bytes32 positionId = keccak256(abi.encodePacked(int24(100), int24(-100), alice));

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__LiquidityDeltaMustBeNegative.selector);
    vm.prank(alice);
    feeHook.decreaseLiquidity(positionId, int128(1), 0, 0);
  }

  function test_RevertWhen_DecreaseLiquidityExceedsPositionLiquidity() public {
    vm.prank(alice);
    feeHook.mintLiquidity(-100, 100, 1e20, type(uint256).max, type(uint256).max);

    bytes32 positionId = keccak256(abi.encodePacked(int24(100), int24(-100), alice));
    (,,, int128 liqBefore) = feeHook.getPositionInfo(positionId);

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwap__InsufficientPositionLiquidity.selector);
    vm.prank(alice);
    feeHook.decreaseLiquidity(positionId, -(liqBefore + 1), 0, 0);
  }
}

// ============================================================================
// WithinTickExactMath - Tests for ln/exp exact math implementation
// ============================================================================

/// @notice Tests verifying the exact math implementation in within-tick calculations
/// @dev These tests validate that _getCashSwapAmountWithinTick (using expWad) and
/// _getPrincipalSwapAmountWithinTick (using lnWad) produce correct results for
/// fractional tick movements.
/// @dev Deprecated: these tests were moved into `_BeforeSwap` to match the file's test
/// organization. Kept abstract to avoid running twice in CI while preserving history.
abstract contract WithinTickExactMath is FixedFeeSwapMarketTest {
  using FixedPointMathLib for int256;
  using FixedPointMathLib for uint256;

  PoolKey internal poolKey;
  SwapParams internal defaultSwapParams;

  // Large liquidity to allow testing sub-1-bip swaps
  uint128 internal constant TEST_LIQUIDITY = 1e24;

  function setUp() public virtual override {
    super.setUp();

    poolKey = PoolKey({
      currency0: Currency.wrap(address(token0)),
      currency1: Currency.wrap(address(token1)),
      fee: 0,
      tickSpacing: 1,
      hooks: IHooks(address(hook))
    });

    defaultSwapParams = SwapParams({zeroForOne: true, amountSpecified: -1e18, sqrtPriceLimitX96: 0});

    // Use a stable, non-trivial time fraction so cash deltas and rounding are measurable.
    _warpFromStart(MARKET_LENGTH / 2);
    // Mint large liquidity to allow testing very small relative swaps
    _mintLiquidityAtTicks(alice, -1000, 1000, TEST_LIQUIDITY);
  }

  // ============ Helper Functions ============

  function _encodeHookParams(int256 amountIn, bool principalForCash, uint256 priceLimitWad)
    internal
    pure
    returns (bytes memory)
  {
    return abi.encode(amountIn, principalForCash, priceLimitWad);
  }

  function _swap(address sender, int256 amountIn, bool principalForCash, uint256 priceLimitWad)
    internal
    returns (bytes4, BeforeSwapDelta, uint24)
  {
    bytes memory hookParams = _encodeHookParams(amountIn, principalForCash, priceLimitWad);
    return hook.exposed_beforeSwap(sender, poolKey, defaultSwapParams, hookParams);
  }

  /// @notice Returns the PT amount needed to move exactly 1 bip
  function _ptForOneBip() internal view returns (uint256) {
    return uint256(hook.getActiveLiquidity()) / BIPS;
  }

  /// @notice Asserts two values are approximately equal within a relative tolerance (in bps)
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

  // ============ Category 1: Fractional Yield / Small Swap Behavior ============

  /// @notice Initialize price by doing a small swap, returns the price after initialization
  function _initializePrice() internal returns (int256) {
    // `currentPrice` is lazily initialized in `_beforeSwap`. Use a minimal swap to trigger it.
    if (hook.getCurrentPrice() == 0) _swap(bob, 1, true, 0);
    int256 price = hook.getCurrentPrice();
    assertTrue(price > 0, "Price must be initialized");
    return price;
  }

  /// @notice Verify small PT→cash swaps (sub-1-bip) produce non-zero cash output
  /// @dev The key improvement of exact math: fractional tick movements still produce output
  function testFuzz_SmallPTSwapProducesNonZeroCash(uint256 smallAmount) public {
    // Initialize price first
    _initializePrice();

    uint256 ptForOneBip = _ptForOneBip();
    // Bound to sub-1-bip amounts (but not too small to avoid rounding to 0)
    smallAmount = bound(smallAmount, ptForOneBip / 100, ptForOneBip - 1);

    uint128 liquidityBefore = hook.getActiveLiquidity();
    int24 tickBefore = hook.getCurrentTick();
    int256 priceBefore = hook.getCurrentPrice();
    int256 tickPriceBefore = hook.tickToPrice(tickBefore);
    uint256 cashBefore = token1.balanceOf(bob);

    _swap(bob, int256(smallAmount), true, 0); // PT→cash

    int24 tickAfter = hook.getCurrentTick();
    int256 priceAfter = hook.getCurrentPrice();
    uint256 cashAfter = token1.balanceOf(bob);
    uint256 cashOut = cashAfter - cashBefore;

    assertEq(
      hook.getActiveLiquidity(), liquidityBefore, "Active liquidity should not change within tick"
    );

    // Price should change (decrease for PT→cash)
    assertTrue(priceAfter < priceBefore, "Price should decrease for PT->cash swap");

    // Cash output should be non-zero for reasonable input sizes
    assertTrue(cashOut > 0, "Small PT swap should produce non-zero cash output");

    // Sub-1-bip inputs should not advance the discrete tick.
    assertEq(tickAfter, tickBefore, "Tick should not change for sub-1-bip PT->cash swap");

    // Prevent "snap-to-tick" price updates: if tick didn't change, the new price must still move.
    assertTrue(
      priceAfter < tickPriceBefore,
      "Price should be strictly below tick price after fractional move"
    );
  }

  /// @notice Verify small cash→PT swaps produce non-zero PT output
  function testFuzz_SmallCashSwapProducesNonZeroPT(uint256 smallAmount) public {
    // First do a PT→cash swap to move tick positive (so we have room to swap back)
    uint256 setupAmount = _ptForOneBip() * 100; // Move 100 bips to ensure we're well into positive
    // territory
    _swap(bob, int256(setupAmount), true, 0);

    // Use a range of cash amounts - not tied to exact boundary calculations
    smallAmount = bound(smallAmount, 1e16, 1e18); // 0.01 to 1 token

    uint128 liquidityBefore = hook.getActiveLiquidity();
    int24 tickBefore = hook.getCurrentTick();
    int256 priceBefore = hook.getCurrentPrice();
    uint256 ptBefore = token0.balanceOf(bob);

    _swap(bob, int256(smallAmount), false, 0); // cash→PT

    int24 tickAfter = hook.getCurrentTick();
    int256 priceAfter = hook.getCurrentPrice();
    uint256 ptAfter = token0.balanceOf(bob);
    uint256 ptOut = ptAfter - ptBefore;

    assertEq(
      hook.getActiveLiquidity(), liquidityBefore, "Active liquidity should not change within tick"
    );

    // PT output should be non-zero for reasonable input sizes
    assertTrue(ptOut > 0, "Cash swap should produce non-zero PT output");

    // Price should increase for cash→PT swaps
    assertTrue(priceAfter > priceBefore, "Price should increase for cash->PT swap");

    // Tick should decrease or stay same (cash→PT decreases yield)
    assertLe(tickAfter, tickBefore, "Tick should not increase for cash->PT swap");
  }

  /// @notice First swap initializes price and produces output
  function test_FirstSwapInitializesPriceAndProducesOutput() public {
    // For a very first swap, currentPrice starts at 0 and gets initialized
    // Then the swap updates it. We test that it's properly initialized and updated.
    uint256 swapAmount = 1e18;

    assertEq(hook.getCurrentPrice(), 0, "Price should be 0 before first swap");

    uint256 cashBefore = token1.balanceOf(bob);
    _swap(bob, int256(swapAmount), true, 0); // PT→cash

    int256 priceAfter = hook.getCurrentPrice();
    uint256 cashOut = token1.balanceOf(bob) - cashBefore;

    // After swap, price should be initialized and non-zero
    assertTrue(priceAfter != 0, "Price should be non-zero after swap");

    // Cash output should be non-zero
    assertTrue(cashOut > 0, "Swap should produce non-zero output");
  }

  /// @notice Verify PT→cash output approximates linear relationship for small swaps
  /// @dev For small swaps: cashOut ≈ P0 * ptIn (first-order approximation)
  function testFuzz_SmallPTSwap_ApproximatesLinear(uint256 smallAmount) public {
    // Initialize price first
    _initializePrice();

    uint256 ptForOneBip = _ptForOneBip();
    // Use very small amounts where linear approximation is most accurate
    smallAmount = bound(smallAmount, ptForOneBip / 1000, ptForOneBip / 10);

    uint128 liquidityBefore = hook.getActiveLiquidity();
    int256 priceBefore = hook.getCurrentPrice();
    int24 tickBefore = hook.getCurrentTick();
    uint256 cashBefore = token1.balanceOf(bob);

    _swap(bob, int256(smallAmount), true, 0);

    assertEq(
      hook.getActiveLiquidity(), liquidityBefore, "Active liquidity should not change within tick"
    );
    assertEq(hook.getCurrentTick(), tickBefore, "Tick should not change for sub-1-bip swap");

    uint256 cashOut = token1.balanceOf(bob) - cashBefore;

    // Linear approximation: cashOut ≈ price * ptIn / 1e18 (price is WAD-scaled)
    uint256 expectedLinear = (uint256(priceBefore) * smallAmount) / SCALE_FACTOR;

    // Should be within 5% for small swaps (accounting for second-order effects and rounding)
    _assertApproxEqRelBps(cashOut, expectedLinear, 500, "Small PT swap should approximate linear");
  }

  /// @notice Verify cash→PT output approximates linear relationship for small swaps
  /// @dev For small swaps: ptOut ≈ cashIn / P0 (first-order approximation)
  function testFuzz_SmallCashSwap_ApproximatesLinear(uint256 smallAmount) public {
    // First move tick positive
    uint256 setupAmount = _ptForOneBip() * 100;
    _swap(bob, int256(setupAmount), true, 0);

    // Use a small but reasonable amount range
    smallAmount = bound(smallAmount, 1e15, 1e17); // 0.001 to 0.1 token

    uint128 liquidityBefore = hook.getActiveLiquidity();
    int256 priceBefore = hook.getCurrentPrice();
    assertTrue(priceBefore > 0, "Price must be initialized");
    int24 tickBefore = hook.getCurrentTick();
    uint256 ptBefore = token0.balanceOf(bob);

    _swap(bob, int256(smallAmount), false, 0);

    assertEq(
      hook.getActiveLiquidity(), liquidityBefore, "Active liquidity should not change within tick"
    );
    assertLe(hook.getCurrentTick(), tickBefore, "Tick should not increase for cash->PT swap");

    uint256 ptOut = token0.balanceOf(bob) - ptBefore;

    // Linear approximation: ptOut ≈ cashIn * 1e18 / price
    uint256 expectedLinear = (smallAmount * SCALE_FACTOR) / uint256(priceBefore);

    // Should be within 20% for these swap sizes (accounting for tick effects and time value)
    _assertApproxEqRelBps(
      ptOut, expectedLinear, 2000, "Cash swap should approximate linear relationship"
    );
  }

  /// @notice Verify that price updates even when tick doesn't change (fractional movement)
  function test_FractionalMove_UpdatesPriceButNotTick() public {
    // Initialize price first
    _initializePrice();

    // Use amount that's definitely less than 1 bip
    uint256 subBipAmount = _ptForOneBip() / 10;

    uint128 liquidityBefore = hook.getActiveLiquidity();
    int24 tickBefore = hook.getCurrentTick();
    int256 priceBefore = hook.getCurrentPrice();
    int256 tickPriceBefore = hook.tickToPrice(tickBefore);
    uint256 cashBefore = token1.balanceOf(bob);

    _swap(bob, int256(subBipAmount), true, 0);

    int24 tickAfter = hook.getCurrentTick();
    int256 priceAfter = hook.getCurrentPrice();
    uint256 cashAfter = token1.balanceOf(bob);
    uint256 cashOut = cashAfter - cashBefore;

    assertEq(
      hook.getActiveLiquidity(), liquidityBefore, "Active liquidity should not change within tick"
    );

    // For very small swaps, tick might not change (floor rounding)
    // But price MUST change - this is the key behavior we're testing
    assertTrue(priceAfter != priceBefore, "Price must change even for sub-bip swaps");
    assertTrue(priceAfter < priceBefore, "Price should decrease for PT->cash");
    assertTrue(cashOut > 0, "Fractional swap should produce non-zero output");

    // Sub-1-bip PT input should not advance the discrete tick.
    assertEq(tickAfter, tickBefore, "Tick should not change for sub-1-bip PT->cash swap");

    // Detect snap-to-tick bugs: if tick didn't change, price must not equal the discrete tick
    // price.
    assertTrue(
      priceAfter < tickPriceBefore,
      "Price should be strictly below tick price after fractional move"
    );

    // Repeat: a second fractional swap should not snap price back up to the discrete tick price.
    _swap(bob, int256(subBipAmount), true, 0);
    assertEq(
      hook.getCurrentTick(),
      tickBefore,
      "Tick should remain unchanged across repeated sub-bip swaps"
    );
    assertEq(
      hook.getActiveLiquidity(),
      liquidityBefore,
      "Active liquidity should remain unchanged across repeated swaps"
    );
    int256 priceAfter2 = hook.getCurrentPrice();
    assertTrue(priceAfter2 <= priceAfter, "Price should not increase for repeated PT->cash swaps");
    assertTrue(
      priceAfter2 < tickPriceBefore,
      "Price should remain below tick price after repeated fractional moves"
    );
  }
}
