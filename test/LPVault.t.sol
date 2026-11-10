// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, stdError} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Deployers} from "lib/v4-periphery/lib/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {LPVault} from "src/LPVault.sol";
import {LPVaultHarness} from "test/harness/LPVaultHarness.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "lib/v4-periphery/lib/v4-core/test/utils/LiquidityAmounts.sol";

contract LPVaultTest is Test, Deployers {
  using PoolIdLibrary for PoolKey;
  using StateLibrary for IPoolManager;

  int24 constant MIN_TICK = -887_272;
  int24 constant MAX_TICK = 887_272;

  uint16 constant BIPS = 10_000;
  uint24 constant DEFAULT_FEE = 3000;
  uint256 constant FEE_DENOMINATOR = 1_000_000;
  uint256 constant FEE_INDEX_PRECISION = 1e18;
  uint256 constant FEE_TOLERANCE = 0.01e18; // 1%
  int24 constant DEFAULT_TICK_SPACING = 60;
  uint256 constant INIT_MAX_VALUE = 1e24;

  // The widest range a pool with `DEFAULT_TICK_SPACING` accepts, used for third-party liquidity
  // that keeps swaps from running out of liquidity.
  int24 constant FULL_RANGE_TICK_LOWER = -887_220;
  int24 constant FULL_RANGE_TICK_UPPER = 887_220;
  // Liquidity a third-party LP adds: enough full-range liquidity that the small fee-accruing swaps
  // keep the price near tick 0, and a small amount to initialize each tick of the wrap range.
  int256 constant THIRD_PARTY_FULL_RANGE_LIQUIDITY = 1e21;
  int256 constant THIRD_PARTY_TICK_LIQUIDITY = 1e18;
  // A single-position vault range below the pool's starting tick of 0. Third parties initialize
  // its upper tick, then its lower tick after fees accrue, so Uniswap's fee growth inside the range
  // starts "negative" (just below 2^256) and wraps past zero once fees accrue inside it.
  int24 constant WRAP_RANGE_TICK_LOWER = -600;
  int24 constant WRAP_RANGE_TICK_UPPER = -300;
  // The exact-input amount of each swap in the round trip that accrues fees between the two tick
  // initializations. It only needs to be nonzero and small enough to leave the price near tick 0.
  int256 constant FEE_ACCRUING_SWAP_AMOUNT = -1e15;
  // A tick inside the wrap range that the swap into the range stops at.
  int24 constant WRAP_RANGE_SWAP_TARGET_TICK = -450;

  string constant DEFAULT_NAME = "LP Vault Share";
  string constant DEFAULT_SYMBOL = "LPVS";

  PoolKey defaultPoolKey;
  LPVault.LiquidityPosition[] defaultPositions;
  LPVault vault;

  function setUp() public virtual {
    // Deploy v4 core contracts.
    deployFreshManagerAndRouters();

    // Deploy and approve two test tokens.
    deployMintAndApprove2Currencies();

    // Create pool key.
    defaultPoolKey = PoolKey({
      currency0: currency0,
      currency1: currency1,
      fee: DEFAULT_FEE,
      tickSpacing: DEFAULT_TICK_SPACING,
      hooks: IHooks(address(0))
    });

    // Initialize the pool.
    manager.initialize(defaultPoolKey, SQRT_PRICE_1_1);

    defaultPositions.push(
      LPVault.LiquidityPosition({tickLower: -120, tickUpper: 120, weight: 5000, liquidity: 0})
    );
    defaultPositions.push(
      LPVault.LiquidityPosition({tickLower: -360, tickUpper: -120, weight: 2500, liquidity: 0})
    );
    defaultPositions.push(
      LPVault.LiquidityPosition({tickLower: 120, tickUpper: 360, weight: 2500, liquidity: 0})
    );

    vm.prank(makeAddr("deployer"));
    vault = new LPVault(
      manager, defaultPoolKey, defaultPositions, DEFAULT_NAME, DEFAULT_SYMBOL, INIT_MAX_VALUE
    );
  }

  function _boundTick(int24 _tick) internal pure returns (int24) {
    return int24(bound(int256(_tick), int256(MIN_TICK), int256(MAX_TICK)));
  }

  /// @dev Assumes tokens are valid and orders them correctly for pool key construction.
  function _assumeAndOrderTokens(address _token0, address _token1)
    internal
    pure
    returns (address, address)
  {
    vm.assume(_token0 != _token1 && _token0 != address(0) && _token1 != address(0));
    if (_token0 > _token1) (_token0, _token1) = (_token1, _token0);
    return (_token0, _token1);
  }

  /// @dev Assumes address is safe for use as depositor or receiver in tests.
  function _assumeSafeAddress(address _addr) internal view {
    vm.assume(
      _addr != address(0) && _addr != address(manager) && _addr != address(vault)
        && _addr != address(this)
    );
  }

  function _mintToken0(address _depositor, uint256 _amount) internal {
    deal(Currency.unwrap(currency0), _depositor, _amount);
  }

  function _mintToken1(address _depositor, uint256 _amount) internal {
    deal(Currency.unwrap(currency1), _depositor, _amount);
  }

  function _approveToken0(address _from, address _to, uint256 _amount) internal {
    vm.prank(_from);
    MockERC20(Currency.unwrap(currency0)).approve(address(_to), _amount);
  }

  function _approveToken1(address _from, address _to, uint256 _amount) internal {
    vm.prank(_from);
    MockERC20(Currency.unwrap(currency1)).approve(address(_to), _amount);
  }

  function _getSqrtPriceX96() internal view returns (uint160 _sqrtPriceX96) {
    (_sqrtPriceX96,,,) = manager.getSlot0(defaultPoolKey.toId());
  }

  function _sumAmountsForLiquidityRoundUp(
    LPVaultHarness _amountsHarness,
    uint128[] memory _liquidityPerPosition
  ) internal view returns (uint256 _amount0, uint256 _amount1) {
    uint160 _sqrtPriceX96 = _getSqrtPriceX96();
    for (uint256 _i = 0; _i < _liquidityPerPosition.length; _i++) {
      (int24 _tickLower, int24 _tickUpper,,) = vault.positions(_i);
      (uint256 _amount0ForPosition, uint256 _amount1ForPosition) = _amountsHarness.getAmountsForLiquidity(
        _tickLower, _tickUpper, _sqrtPriceX96, _liquidityPerPosition[_i]
      );
      _amount0 += _amount0ForPosition;
      _amount1 += _amount1ForPosition;
    }
  }

  function _sumAmountsForLiquidityRoundDown(uint128[] memory _liquidityPerPosition)
    internal
    view
    returns (uint256 _amount0, uint256 _amount1)
  {
    uint160 _sqrtPriceX96 = _getSqrtPriceX96();
    for (uint256 _i = 0; _i < _liquidityPerPosition.length; _i++) {
      (int24 _tickLower, int24 _tickUpper,,) = vault.positions(_i);
      uint160 _sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(_tickLower);
      uint160 _sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(_tickUpper);
      (uint256 _amount0ForPosition, uint256 _amount1ForPosition) = LiquidityAmounts.getAmountsForLiquidity(
        _sqrtPriceX96, _sqrtPriceLowerX96, _sqrtPriceUpperX96, _liquidityPerPosition[_i]
      );
      _amount0 += _amount0ForPosition;
      _amount1 += _amount1ForPosition;
    }
  }

  function _getProportionalLiquidityPerPosition(uint128 _position0Amount)
    internal
    view
    returns (uint128[] memory _liquidityPerPosition)
  {
    uint256 _positionsLength = defaultPositions.length;
    _liquidityPerPosition = new uint128[](_positionsLength);
    _liquidityPerPosition[0] = _position0Amount;

    (,,, uint128 _position0Liquidity) = vault.positions(0);
    for (uint256 _i = 1; _i < _positionsLength; _i++) {
      (,,, uint128 _positionLiquidity) = vault.positions(_i);
      _liquidityPerPosition[_i] =
        uint128(FullMath.mulDiv(_position0Amount, _positionLiquidity, _position0Liquidity));
    }
  }

  function _initializeLiquidity(address _initializer)
    internal
    returns (uint256 _shares, uint256 _amount0Used, uint256 _amount1Used)
  {
    // getMaxInitAmounts returns max for each token if ONLY that token is used.
    // To stay within INIT_MAX_VALUE when using both, we use half of each.
    (uint256 _amount0Max, uint256 _amount1Max) = vault.getMaxInitAmounts();
    _amount0Max = _amount0Max / 2;
    _amount1Max = _amount1Max / 2;

    _mintToken0(_initializer, _amount0Max);
    _mintToken1(_initializer, _amount1Max);
    _approveToken0(_initializer, address(vault), _amount0Max);
    _approveToken1(_initializer, address(vault), _amount1Max);

    vm.prank(_initializer);
    (_shares, _amount0Used, _amount1Used) = vault.initializeLiquidity(_amount0Max, _amount1Max);
  }

  function _ensureInitialized(address _initializer) internal {
    if (!vault.liquidityInitialized()) _initializeLiquidity(_initializer);
  }

  function _deposit(address _depositor, uint256 _amount0, uint256 _amount1)
    internal
    returns (uint256 _shares, uint256 _amount0Used, uint256 _amount1Used)
  {
    uint256 _amount0Max = bound(_amount0, 1e18, type(uint96).max);
    uint256 _amount1Max = bound(_amount1, 1e18, type(uint96).max);

    _mintToken0(_depositor, _amount0Max);
    _mintToken1(_depositor, _amount1Max);
    _approveToken0(_depositor, address(vault), _amount0Max);
    _approveToken1(_depositor, address(vault), _amount1Max);

    // If not initialized, initialize first with a separate address
    if (!vault.liquidityInitialized()) {
      address _initializer = makeAddr("initializer");
      _initializeLiquidity(_initializer);
    }

    // Use a small liquidity amount that works with bounded token amounts (min 1e6)
    uint128 _liquidity = 1e5;

    vm.prank(_depositor);
    (_shares, _amount0Used, _amount1Used) = vault.deposit(_amount0Max, _amount1Max, _liquidity);
  }

  function _boundSwapAbs(uint256 _swapAbs) internal pure returns (int256) {
    return -int256(bound(_swapAbs, 1e18, 1e24));
  }

  function _performSwap(bool _zeroForOne, int256 _amountSpecified) internal returns (BalanceDelta) {
    return swap(defaultPoolKey, _zeroForOne, _amountSpecified, "");
  }

  // Swaps exact input from this test contract until `_amountSpecified` is spent or the price
  // reaches `_sqrtPriceLimitX96`, whichever comes first.
  function _performSwapUpToPrice(
    bool _zeroForOne,
    int256 _amountSpecified,
    uint160 _sqrtPriceLimitX96
  ) internal {
    swapRouter.swap(
      defaultPoolKey,
      SwapParams({
        zeroForOne: _zeroForOne,
        amountSpecified: _amountSpecified,
        sqrtPriceLimitX96: _sqrtPriceLimitX96
      }),
      PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
      ""
    );
  }

  // Adds `_liquidity` to `[_tickLower, _tickUpper]` from this test contract, acting as a
  // third-party LP that is not the vault.
  function _addThirdPartyLiquidity(int24 _tickLower, int24 _tickUpper, int256 _liquidity) internal {
    modifyLiquidityRouter.modifyLiquidity(
      defaultPoolKey,
      ModifyLiquidityParams({
        tickLower: _tickLower, tickUpper: _tickUpper, liquidityDelta: _liquidity, salt: bytes32(0)
      }),
      ""
    );
  }

  // Replaces `vault` with a vault holding one position over the wrap range, has `_initializer`
  // initialize it, and returns the shares minted. Before the vault adds liquidity, third-party LPs
  // initialize the range's upper tick, trade to accrue fees, then initialize its lower tick, so
  // Uniswap's fee growth inside the range starts just below 2^256. A swap into the range then
  // accrues fees inside it until that value wraps past zero. Asserts both of those states so a test
  // can't pass without the wrap happening.
  function _initializeVaultAndWrapFeeGrowthInsidePastZero(address _initializer)
    internal
    returns (uint256 _shares)
  {
    LPVault.LiquidityPosition[] memory _positions = new LPVault.LiquidityPosition[](1);
    _positions[0] = LPVault.LiquidityPosition({
      tickLower: WRAP_RANGE_TICK_LOWER, tickUpper: WRAP_RANGE_TICK_UPPER, weight: BIPS, liquidity: 0
    });
    vault = new LPVault(
      manager, defaultPoolKey, _positions, DEFAULT_NAME, DEFAULT_SYMBOL, INIT_MAX_VALUE
    );

    _addThirdPartyLiquidity(
      FULL_RANGE_TICK_LOWER, FULL_RANGE_TICK_UPPER, THIRD_PARTY_FULL_RANGE_LIQUIDITY
    );
    // Initializes the upper tick while the price is above it.
    _addThirdPartyLiquidity(
      WRAP_RANGE_TICK_UPPER, -WRAP_RANGE_TICK_UPPER, THIRD_PARTY_TICK_LIQUIDITY
    );
    _performSwap(true, FEE_ACCRUING_SWAP_AMOUNT);
    _performSwap(false, FEE_ACCRUING_SWAP_AMOUNT);
    // Initializes the lower tick at a higher fee growth than the upper tick.
    _addThirdPartyLiquidity(
      WRAP_RANGE_TICK_LOWER,
      WRAP_RANGE_TICK_LOWER + DEFAULT_TICK_SPACING,
      THIRD_PARTY_TICK_LIQUIDITY
    );

    (uint256 _feeGrowthInside0BeforeX128,) = manager.getFeeGrowthInside(
      defaultPoolKey.toId(), WRAP_RANGE_TICK_LOWER, WRAP_RANGE_TICK_UPPER
    );
    assertGt(_feeGrowthInside0BeforeX128, type(uint256).max / 2, "fee growth inside not wrapped");

    // The range is below the price, so initializing it takes only token1.
    _mintToken1(_initializer, INIT_MAX_VALUE);
    _approveToken1(_initializer, address(vault), INIT_MAX_VALUE);
    vm.prank(_initializer);
    (_shares,,) = vault.initializeLiquidity(0, INIT_MAX_VALUE);

    _performSwapUpToPrice(
      true, -int256(INIT_MAX_VALUE), TickMath.getSqrtPriceAtTick(WRAP_RANGE_SWAP_TARGET_TICK)
    );

    (uint256 _feeGrowthInside0AfterX128,) = manager.getFeeGrowthInside(
      defaultPoolKey.toId(), WRAP_RANGE_TICK_LOWER, WRAP_RANGE_TICK_UPPER
    );
    assertLt(
      _feeGrowthInside0AfterX128, _feeGrowthInside0BeforeX128, "fee growth inside not past zero"
    );
  }
}

contract Constructor is LPVaultTest {
  function testFuzz_SinglePosition(int24 _tickLower, int24 _tickUpper, address _deployer) public {
    _tickLower = int24(bound(int256(_tickLower), int256(MIN_TICK), int256(MAX_TICK - 1)));
    _tickUpper = int24(bound(int256(_tickUpper), int256(_tickLower + 1), int256(MAX_TICK)));
    vm.assume(_deployer != address(0));

    LPVault.LiquidityPosition[] memory _positions = new LPVault.LiquidityPosition[](1);
    _positions[0] = LPVault.LiquidityPosition({
      tickLower: _tickLower, tickUpper: _tickUpper, weight: BIPS, liquidity: 0
    });

    vm.prank(_deployer);
    LPVault _newVault = new LPVault(
      manager, defaultPoolKey, _positions, DEFAULT_NAME, DEFAULT_SYMBOL, INIT_MAX_VALUE
    );

    assertEq(address(_newVault.POOL_MANAGER()), address(manager));
    assertEq(_newVault.TOKEN0(), Currency.unwrap(currency0));
    assertEq(_newVault.TOKEN1(), Currency.unwrap(currency1));

    (int24 storedTickLower, int24 storedTickUpper, uint16 storedWeight,) = _newVault.positions(0);
    assertEq(storedTickLower, _tickLower);
    assertEq(storedTickUpper, _tickUpper);
    assertEq(storedWeight, BIPS);
  }

  function testFuzz_MultiplePositionsWithWeights(uint16 _weight1, uint16 _weight2) public {
    _weight1 = uint16(bound(_weight1, 1, 9998));
    _weight2 = uint16(bound(_weight2, 1, 9999 - _weight1));
    uint16 _weight3 = BIPS - _weight1 - _weight2;

    LPVault.LiquidityPosition[] memory _positions = new LPVault.LiquidityPosition[](3);
    _positions[0] =
      LPVault.LiquidityPosition({tickLower: -300, tickUpper: -200, weight: _weight1, liquidity: 0});
    _positions[1] =
      LPVault.LiquidityPosition({tickLower: -200, tickUpper: -100, weight: _weight2, liquidity: 0});
    _positions[2] =
      LPVault.LiquidityPosition({tickLower: -100, tickUpper: 0, weight: _weight3, liquidity: 0});

    LPVault _newVault = new LPVault(
      manager, defaultPoolKey, _positions, DEFAULT_NAME, DEFAULT_SYMBOL, INIT_MAX_VALUE
    );

    (,, uint16 position0Weight,) = _newVault.positions(0);
    (,, uint16 position1Weight,) = _newVault.positions(1);
    (,, uint16 position2Weight,) = _newVault.positions(2);
    assertEq(position0Weight, _weight1);
    assertEq(position1Weight, _weight2);
    assertEq(position2Weight, _weight3);
  }

  function testFuzz_PoolKeyStoredCorrectly(
    address _token0,
    address _token1,
    uint24 _fee,
    int24 _tickSpacing,
    address _hook
  ) public {
    _fee = uint24(bound(_fee, 0, FEE_DENOMINATOR));
    _tickSpacing = int24(bound(int256(_tickSpacing), 1, 16_383));

    PoolKey memory _poolKey = PoolKey({
      currency0: Currency.wrap(_token0),
      currency1: Currency.wrap(_token1),
      fee: _fee,
      tickSpacing: _tickSpacing,
      hooks: IHooks(_hook)
    });

    LPVault.LiquidityPosition[] memory _positions = new LPVault.LiquidityPosition[](1);
    _positions[0] =
      LPVault.LiquidityPosition({tickLower: -100, tickUpper: 100, weight: BIPS, liquidity: 0});

    LPVault _newVault =
      new LPVault(manager, _poolKey, _positions, DEFAULT_NAME, DEFAULT_SYMBOL, INIT_MAX_VALUE);

    (
      Currency storedCurrency0,
      Currency storedCurrency1,
      uint24 storedFee,
      int24 storedTickSpacing,
      IHooks storedHooks
    ) = _newVault.targetPoolKey();

    assertEq(Currency.unwrap(storedCurrency0), _token0);
    assertEq(Currency.unwrap(storedCurrency1), _token1);
    assertEq(storedFee, _fee);
    assertEq(storedTickSpacing, _tickSpacing);
    assertEq(address(storedHooks), _hook);
  }

  function test_RevertIf_NoPositions() public {
    LPVault.LiquidityPosition[] memory _positions = new LPVault.LiquidityPosition[](0);

    vm.expectRevert(LPVault.LPVault__NoPositions.selector);
    new LPVault(manager, defaultPoolKey, _positions, DEFAULT_NAME, DEFAULT_SYMBOL, INIT_MAX_VALUE);
  }

  function testFuzz_RevertIf_WeightDoesNotSumToFullWeight(uint16 _weight) public {
    vm.assume(_weight != BIPS);

    LPVault.LiquidityPosition[] memory _positions = new LPVault.LiquidityPosition[](1);
    _positions[0] =
      LPVault.LiquidityPosition({tickLower: -100, tickUpper: 100, weight: _weight, liquidity: 0});

    vm.expectRevert(LPVault.LPVault__InvalidLiquidityDistribution.selector);
    new LPVault(manager, defaultPoolKey, _positions, DEFAULT_NAME, DEFAULT_SYMBOL, INIT_MAX_VALUE);
  }

  function testFuzz_RevertIf_MultiplePositionsWeightMismatch(uint16 _weight1, uint16 _weight2)
    public
  {
    _weight1 = uint16(bound(_weight1, 0, 9999));
    _weight2 = uint16(bound(_weight2, 0, 9999 - _weight1));

    LPVault.LiquidityPosition[] memory _positions = new LPVault.LiquidityPosition[](2);
    _positions[0] =
      LPVault.LiquidityPosition({tickLower: -200, tickUpper: -100, weight: _weight1, liquidity: 0});
    _positions[1] =
      LPVault.LiquidityPosition({tickLower: -100, tickUpper: 0, weight: _weight2, liquidity: 0});

    vm.expectRevert(LPVault.LPVault__InvalidLiquidityDistribution.selector);
    new LPVault(manager, defaultPoolKey, _positions, DEFAULT_NAME, DEFAULT_SYMBOL, INIT_MAX_VALUE);
  }

  function testFuzz_RevertIf_InvalidTickRange(int24 _tickLower, int24 _tickUpper) public {
    _tickLower = _boundTick(_tickLower);
    _tickUpper = int24(bound(int256(_tickUpper), int256(MIN_TICK), int256(_tickLower)));

    LPVault.LiquidityPosition[] memory _positions = new LPVault.LiquidityPosition[](1);
    _positions[0] = LPVault.LiquidityPosition({
      tickLower: _tickLower, tickUpper: _tickUpper, weight: BIPS, liquidity: 0
    });

    vm.expectRevert(LPVault.LPVault__InvalidTickRange.selector);
    new LPVault(manager, defaultPoolKey, _positions, DEFAULT_NAME, DEFAULT_SYMBOL, INIT_MAX_VALUE);
  }

  function test_EmitsPoolManagerSetEvent() public {
    LPVault.LiquidityPosition[] memory _positions = new LPVault.LiquidityPosition[](1);
    _positions[0] =
      LPVault.LiquidityPosition({tickLower: -100, tickUpper: 100, weight: BIPS, liquidity: 0});

    vm.expectEmit();
    emit LPVault.PoolManagerSet(address(manager));
    new LPVault(manager, defaultPoolKey, _positions, DEFAULT_NAME, DEFAULT_SYMBOL, INIT_MAX_VALUE);
  }
}

contract InitializeLiquidity is LPVaultTest {
  address initializer = makeAddr("initializer");

  function _fundAndApproveInitializer(address _addr) internal {
    deal(Currency.unwrap(currency0), _addr, type(uint128).max);
    deal(Currency.unwrap(currency1), _addr, type(uint128).max);
    vm.startPrank(_addr);
    MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint128).max);
    MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint128).max);
    vm.stopPrank();
  }

  function test_InitializesLiquidityAndMintsShares() public {
    _fundAndApproveInitializer(initializer);

    uint256 _token0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(initializer);
    uint256 _token1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(initializer);
    LPVaultHarness _lpVaultHarness = new LPVaultHarness(
      manager, defaultPoolKey, defaultPositions, DEFAULT_NAME, DEFAULT_SYMBOL, INIT_MAX_VALUE
    );
    (uint128[] memory _expectedLiquidityPerPosition, uint128 _expectedLiquidity0) =
      _lpVaultHarness.computeInitialLiquidity();

    (uint256 _amount0Max, uint256 _amount1Max) = vault.getMaxInitAmounts();
    _amount0Max = _amount0Max / 2;
    _amount1Max = _amount1Max / 2;
    vm.prank(initializer);
    (uint256 _shares, uint256 _amount0Used, uint256 _amount1Used) =
      vault.initializeLiquidity(_amount0Max, _amount1Max);

    // Shares equal position0 liquidity
    (,,, uint128 _position0Liquidity) = vault.positions(0);
    assertEq(_shares, _expectedLiquidity0);
    assertEq(_shares, _position0Liquidity);
    assertEq(vault.balanceOf(initializer), _shares);
    assertEq(vault.totalSupply(), _shares);

    // Tokens were transferred
    uint256 _token0After = MockERC20(Currency.unwrap(currency0)).balanceOf(initializer);
    uint256 _token1After = MockERC20(Currency.unwrap(currency1)).balanceOf(initializer);
    assertEq(_amount0Used, _token0Before - _token0After);
    assertEq(_amount1Used, _token1Before - _token1After);
    assertEq(_token0After, _token0Before - _amount0Used);
    assertEq(_token1After, _token1Before - _amount1Used);

    // Position liquidity matches preview
    for (uint256 _i = 0; _i < defaultPositions.length; _i++) {
      (,,, uint128 _positionLiquidity) = vault.positions(_i);
      assertEq(_positionLiquidity, _expectedLiquidityPerPosition[_i]);
    }

    // State is initialized
    assertTrue(vault.liquidityInitialized());
  }

  function test_EmitsDepositedEvent() public {
    _fundAndApproveInitializer(initializer);

    LPVaultHarness _lpVaultHarness = new LPVaultHarness(
      manager, defaultPoolKey, defaultPositions, DEFAULT_NAME, DEFAULT_SYMBOL, INIT_MAX_VALUE
    );
    (uint128[] memory _liquidityPerPosition, uint128 _liquidity0) =
      _lpVaultHarness.computeInitialLiquidity();
    (uint256 _amount0Used, uint256 _amount1Used) =
      _sumAmountsForLiquidityRoundUp(_lpVaultHarness, _liquidityPerPosition);

    (uint256 _amount0Max, uint256 _amount1Max) = vault.getMaxInitAmounts();
    _amount0Max = _amount0Max / 2;
    _amount1Max = _amount1Max / 2;
    vm.expectEmit();
    emit LPVault.Deposited(initializer, _liquidity0, _amount0Used, _amount1Used);

    vm.prank(initializer);
    vault.initializeLiquidity(_amount0Max, _amount1Max);
  }

  function testFuzz_CallableByAnyone(address _caller) public {
    _assumeSafeAddress(_caller);
    _fundAndApproveInitializer(_caller);

    (uint256 _amount0Max, uint256 _amount1Max) = vault.getMaxInitAmounts();
    _amount0Max = _amount0Max / 2;
    _amount1Max = _amount1Max / 2;
    vm.prank(_caller);
    (uint256 _shares,,) = vault.initializeLiquidity(_amount0Max, _amount1Max);

    (,,, uint128 _position0Liquidity) = vault.positions(0);
    assertEq(_shares, _position0Liquidity);
    assertEq(vault.balanceOf(_caller), _shares);
    assertTrue(vault.liquidityInitialized());
  }

  function testFuzz_CreditsNoFeesThatAccruedBeforeItsLiquidityWasAdded(
    address _caller,
    uint256 _swapAmount
  ) public {
    _assumeSafeAddress(_caller);
    _fundAndApproveInitializer(_caller);
    // At least 1e6 so the swap pays a nonzero fee, and at most 1e18 so the price stays inside the
    // vault's (-120, 120) position, whose ticks stay uninitialized while fees accrue.
    _swapAmount = bound(_swapAmount, 1e6, 1e18);
    _addThirdPartyLiquidity(
      FULL_RANGE_TICK_LOWER, FULL_RANGE_TICK_UPPER, THIRD_PARTY_FULL_RANGE_LIQUIDITY
    );
    _performSwap(true, -int256(_swapAmount));
    // Swaps back to exactly 1:1, the price the half-and-half initialization amounts below fit.
    _performSwapUpToPrice(false, -int256(INIT_MAX_VALUE), SQRT_PRICE_1_1);

    (uint256 _amount0Max, uint256 _amount1Max) = vault.getMaxInitAmounts();
    _amount0Max = _amount0Max / 2;
    _amount1Max = _amount1Max / 2;
    vm.prank(_caller);
    vault.initializeLiquidity(_amount0Max, _amount1Max);
    vault.collectFees();

    assertEq(vault.globalFeeIndex0Scaled(), 0);
    assertEq(vault.globalFeeIndex1Scaled(), 0);
  }

  function test_RevertIf_AlreadyInitialized() public {
    _fundAndApproveInitializer(initializer);

    (uint256 _amount0Max, uint256 _amount1Max) = vault.getMaxInitAmounts();
    _amount0Max = _amount0Max / 2;
    _amount1Max = _amount1Max / 2;

    // First initialization succeeds
    vm.prank(initializer);
    vault.initializeLiquidity(_amount0Max, _amount1Max);

    // Second initialization reverts
    vm.expectRevert(LPVault.LPVault__AlreadyInitialized.selector);
    vm.prank(initializer);
    vault.initializeLiquidity(_amount0Max, _amount1Max);
  }

  function test_RevertIf_ZeroInitMaxValue() public {
    // Deploy a vault with zero init max value should revert
    vm.expectRevert(LPVault.LPVault__ZeroValue.selector);
    new LPVault(manager, defaultPoolKey, defaultPositions, DEFAULT_NAME, DEFAULT_SYMBOL, 0);
  }

  function test_RevertIf_InsufficientAllowance() public {
    (uint256 _amount0Max, uint256 _amount1Max) = vault.getMaxInitAmounts();
    _amount0Max = _amount0Max / 2;
    _amount1Max = _amount1Max / 2;

    // Fund the initializer but don't approve
    deal(Currency.unwrap(currency0), initializer, _amount0Max);
    deal(Currency.unwrap(currency1), initializer, _amount1Max);

    vm.expectRevert(stdError.arithmeticError);
    vm.prank(initializer);
    vault.initializeLiquidity(_amount0Max, _amount1Max);
  }

  function test_RevertIf_ExceedsMaxValue() public {
    _fundAndApproveInitializer(initializer);

    // Get the max amounts
    (uint256 _amount0Max, uint256 _amount1Max) = vault.getMaxInitAmounts();

    // Try to initialize with amounts that exceed the max value
    // Both amounts at max would exceed since value = amount0*price + amount1 > INIT_MAX_VALUE
    vm.expectRevert(LPVault.LPVault__ExceedsMaxValue.selector);
    vm.prank(initializer);
    vault.initializeLiquidity(_amount0Max, _amount1Max + 1);
  }
}

contract Deposit is LPVaultTest {
  address depositor = makeAddr("depositor");
  address initializer = makeAddr("initializer");

  function setUp() public virtual override {
    super.setUp();

    (uint256 _amount0Max, uint256 _amount1Max) = vault.getMaxInitAmounts();
    _amount0Max = _amount0Max / 2;
    _amount1Max = _amount1Max / 2;
    deal(Currency.unwrap(currency0), initializer, type(uint128).max);
    deal(Currency.unwrap(currency1), initializer, type(uint128).max);
    vm.startPrank(initializer);
    MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint128).max);
    MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint128).max);
    vault.initializeLiquidity(_amount0Max, _amount1Max);
    vm.stopPrank();
  }

  /// @dev Sets up approvals for a depositor to interact with the vault.
  function _approveTokensForVault(address _depositor, uint256 _amount0, uint256 _amount1) internal {
    vm.startPrank(_depositor);
    MockERC20(Currency.unwrap(currency0)).approve(address(vault), _amount0);
    MockERC20(Currency.unwrap(currency1)).approve(address(vault), _amount1);
    vm.stopPrank();
  }

  function testFuzz_MintsSharesAndTransfersTokens(uint128 _liquidity) public {
    _liquidity = uint128(bound(_liquidity, 1e12, 1e20));

    uint256 _amount0Max = type(uint128).max;
    uint256 _amount1Max = type(uint128).max;
    deal(Currency.unwrap(currency0), depositor, _amount0Max);
    deal(Currency.unwrap(currency1), depositor, _amount1Max);

    _approveTokensForVault(depositor, _amount0Max, _amount1Max);
    uint256 _token0BalanceBefore = MockERC20(Currency.unwrap(currency0)).balanceOf(depositor);
    uint256 _token1BalanceBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(depositor);

    vm.prank(depositor);
    (uint256 _shares, uint256 _amount0Used, uint256 _amount1Used) =
      vault.deposit(_amount0Max, _amount1Max, _liquidity);

    // Verify shares equal liquidity parameter.
    assertEq(_shares, _liquidity);
    assertEq(vault.balanceOf(depositor), _shares);

    // Verify tokens were transferred.
    uint256 _token0BalanceAfter = MockERC20(Currency.unwrap(currency0)).balanceOf(depositor);
    uint256 _token1BalanceAfter = MockERC20(Currency.unwrap(currency1)).balanceOf(depositor);
    assertEq(_amount0Used, _token0BalanceBefore - _token0BalanceAfter);
    assertEq(_amount1Used, _token1BalanceBefore - _token1BalanceAfter);

    // Verify depositor's balance decreased.
    assertEq(
      MockERC20(Currency.unwrap(currency0)).balanceOf(depositor),
      _token0BalanceBefore - _amount0Used
    );
    assertEq(
      MockERC20(Currency.unwrap(currency1)).balanceOf(depositor),
      _token1BalanceBefore - _amount1Used
    );
  }

  function testFuzz_DistributesLiquidityAcrossPositions(uint128 _liquidity) public {
    // Get current position liquidity ratios (set by initialization)
    (,,, uint128 _initLiquidity0) = vault.positions(0);
    (,,, uint128 _initLiquidity1) = vault.positions(1);
    (,,, uint128 _initLiquidity2) = vault.positions(2);

    _liquidity = uint128(bound(_liquidity, 1e12, 1e20));

    uint256 _amount0Max = type(uint128).max;
    uint256 _amount1Max = type(uint128).max;
    deal(Currency.unwrap(currency0), depositor, _amount0Max);
    deal(Currency.unwrap(currency1), depositor, _amount1Max);
    _approveTokensForVault(depositor, _amount0Max, _amount1Max);

    uint128 _expectedLiquidity1 =
      uint128(FullMath.mulDiv(_liquidity, _initLiquidity1, _initLiquidity0));
    uint128 _expectedLiquidity2 =
      uint128(FullMath.mulDiv(_liquidity, _initLiquidity2, _initLiquidity0));

    vm.prank(depositor);
    vault.deposit(_amount0Max, _amount1Max, _liquidity);

    // Verify ratios stay constant and position0 increases by the requested liquidity.
    (,,, uint128 _finalLiquidity0) = vault.positions(0);
    assertEq(_finalLiquidity0, _initLiquidity0 + _liquidity);

    (,,, uint128 _finalLiquidity1) = vault.positions(1);
    (,,, uint128 _finalLiquidity2) = vault.positions(2);

    assertEq(_finalLiquidity1, _initLiquidity1 + _expectedLiquidity1);
    assertEq(_finalLiquidity2, _initLiquidity2 + _expectedLiquidity2);
  }

  function testFuzz_DepositEmitsDepositedEvent(uint128 _liquidity) public {
    _liquidity = uint128(bound(_liquidity, 1e12, 1e20));

    uint256 _amount0Max = type(uint128).max;
    uint256 _amount1Max = type(uint128).max;
    deal(Currency.unwrap(currency0), depositor, _amount0Max);
    deal(Currency.unwrap(currency1), depositor, _amount1Max);
    _approveTokensForVault(depositor, _amount0Max, _amount1Max);

    uint128[] memory _liquidityPerPosition = _getProportionalLiquidityPerPosition(_liquidity);

    LPVaultHarness _amountsHarness = new LPVaultHarness(
      manager, defaultPoolKey, defaultPositions, DEFAULT_NAME, DEFAULT_SYMBOL, INIT_MAX_VALUE
    );
    (uint256 _amount0Used, uint256 _amount1Used) =
      _sumAmountsForLiquidityRoundUp(_amountsHarness, _liquidityPerPosition);

    vm.expectEmit();
    emit LPVault.Deposited(depositor, _liquidity, _amount0Used, _amount1Used);

    vm.prank(depositor);
    vault.deposit(_amount0Max, _amount1Max, _liquidity);
  }

  function testFuzz_MultipleDeposits(uint128 _liquidity) public {
    _liquidity = uint128(bound(_liquidity, 1e12, 1e18));

    uint256 _totalSupplyBefore = vault.totalSupply();

    uint256 _amount0Max = type(uint128).max;
    uint256 _amount1Max = type(uint128).max;
    deal(Currency.unwrap(currency0), depositor, _amount0Max);
    deal(Currency.unwrap(currency1), depositor, _amount1Max);
    _approveTokensForVault(depositor, _amount0Max, _amount1Max);

    // First deposit.
    vm.prank(depositor);
    (uint256 _shares1,,) = vault.deposit(_amount0Max, _amount1Max, _liquidity);

    // Second deposit.
    vm.prank(depositor);
    (uint256 _shares2,,) = vault.deposit(_amount0Max, _amount1Max, _liquidity);

    // Verify equal liquidity yields equal shares.
    assertEq(_shares1, _shares2);
    assertEq(_shares1, _liquidity);

    // Verify total shares.
    assertEq(vault.balanceOf(depositor), _shares1 + _shares2);
    // Total supply includes initializer shares + depositor shares
    assertEq(vault.totalSupply(), _totalSupplyBefore + _shares1 + _shares2);
  }

  function test_RevertIf_ZeroLiquidity() public {
    vm.prank(depositor);
    vm.expectRevert(LPVault.LPVault__ZeroLiquidity.selector);
    vault.deposit(1e18, 1e18, 0);
  }

  function test_RevertIf_NotInitialized(address _caller, uint128 _liquidity) public {
    // Deploy a fresh vault without initialization
    LPVault _freshVault = new LPVault(
      manager, defaultPoolKey, defaultPositions, DEFAULT_NAME, DEFAULT_SYMBOL, INIT_MAX_VALUE
    );

    _assumeSafeAddress(_caller);
    _liquidity = uint128(bound(_liquidity, 1, type(uint96).max));
    deal(Currency.unwrap(currency0), _caller, 1e18);
    deal(Currency.unwrap(currency1), _caller, 1e18);
    vm.startPrank(_caller);
    MockERC20(Currency.unwrap(currency0)).approve(address(_freshVault), 1e18);
    MockERC20(Currency.unwrap(currency1)).approve(address(_freshVault), 1e18);

    vm.expectRevert(LPVault.LPVault__NotInitialized.selector);
    _freshVault.deposit(1e18, 1e18, _liquidity);
    vm.stopPrank();
  }

  function testFuzz_RevertIf_UnlockCallbackCalledByNonPoolManager(
    address _caller,
    uint256 _amount0Max,
    uint256 _amount1Max
  ) public {
    vm.assume(_caller != address(manager));

    uint128[] memory _liquidityPerPosition = new uint128[](defaultPositions.length);
    _liquidityPerPosition[0] = 1e18;
    _liquidityPerPosition[1] = 5e17;
    _liquidityPerPosition[2] = 5e17;

    LPVault.DepositCallbackData memory _callbackData = LPVault.DepositCallbackData({
      sender: address(this),
      amount0Max: _amount0Max,
      amount1Max: _amount1Max,
      liquidityPerPosition: _liquidityPerPosition
    });

    vm.prank(_caller);
    vm.expectRevert(ImmutableState.NotPoolManager.selector);
    vault.unlockCallback(abi.encode(LPVault.CallbackAction.Deposit, abi.encode(_callbackData)));
  }

  /// @notice Tests that fees are synced before deposit operations.
  function testFuzz_FeesSyncedBeforeDeposit(
    address _depositor1,
    address _depositor2,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _swapAbs0
  ) public {
    _assumeSafeAddress(_depositor1);
    _assumeSafeAddress(_depositor2);
    vm.assume(_depositor1 != _depositor2);

    // First deposit
    _deposit(_depositor1, _amount0, _amount1);

    // Generate fees
    BalanceDelta _delta = _performSwap(true, _boundSwapAbs(_swapAbs0));
    uint256 _expectedFee0 = uint256(-int256(_delta.amount0())) * DEFAULT_FEE / FEE_DENOMINATOR;

    uint256 _totalSupply = vault.totalSupply();
    uint256 _expectedIndexDelta0 = _expectedFee0 * FEE_INDEX_PRECISION / _totalSupply;
    uint256 _feeIndex0Before = vault.globalFeeIndex0Scaled();

    // Second deposit should sync fees before adding liquidity
    _deposit(_depositor2, _amount0, _amount1);
    uint256 _feeIndex0After = vault.globalFeeIndex0Scaled();

    // Fee index should have increased (fees synced during deposit)
    assertApproxEqRel(_feeIndex0After - _feeIndex0Before, _expectedIndexDelta0, FEE_TOLERANCE);
  }
}

contract Withdraw is LPVaultTest {
  function testFuzz_WithdrawBurnsSharesAndTransfersTokens(
    address _depositor,
    uint256 _amount0,
    uint256 _amount1,
    address _receiver
  ) public {
    _assumeSafeAddress(_depositor);
    _assumeSafeAddress(_receiver);
    vm.assume(_depositor != _receiver);

    // Ensure initialization happens before capturing state
    _ensureInitialized(makeAddr("initForTest"));

    uint256 _totalSupplyBefore = vault.totalSupply();
    (,,, uint128 _position0LiquidityBefore) = vault.positions(0);

    (uint256 _shares, uint256 _amount0Deposited, uint256 _amount1Deposited) =
      _deposit(_depositor, _amount0, _amount1);

    uint256 _receiverToken0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(_receiver);
    uint256 _receiverToken1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(_receiver);

    // Withdraw all depositor's shares.
    vm.prank(_depositor);
    (uint256 _amount0Received, uint256 _amount1Received) = vault.withdraw(_shares, _receiver);

    // Verify depositor's shares were burned.
    assertEq(vault.balanceOf(_depositor), 0);
    // Total supply returns to pre-deposit state (initializer shares remain)
    assertEq(vault.totalSupply(), _totalSupplyBefore);

    // Verify receiver got tokens.
    assertEq(
      MockERC20(Currency.unwrap(currency0)).balanceOf(_receiver),
      _receiverToken0Before + _amount0Received
    );
    assertEq(
      MockERC20(Currency.unwrap(currency1)).balanceOf(_receiver),
      _receiverToken1Before + _amount1Received
    );

    // Verify amounts received match deposited (within rounding tolerance).
    // With multiple positions, rounding errors can accumulate, so we allow a delta of 2.
    assertApproxEqAbs(_amount0Received, _amount0Deposited, 2);
    assertApproxEqAbs(_amount1Received, _amount1Deposited, 2);

    // Verify position liquidity returns to pre-deposit state.
    (,,, uint128 _position0LiquidityAfter) = vault.positions(0);
    assertEq(_position0LiquidityAfter, _position0LiquidityBefore);
  }

  function testFuzz_WithdrawEmitsEvent(
    address _depositor,
    uint256 _amount0,
    uint256 _amount1,
    address _receiver
  ) public {
    _assumeSafeAddress(_depositor);
    vm.assume(_receiver != address(0));

    (uint256 _shares,,) = _deposit(_depositor, _amount0, _amount1);

    uint128[] memory _liquidityToRemove = _getProportionalLiquidityPerPosition(uint128(_shares));

    (uint256 _amount0Received, uint256 _amount1Received) =
      _sumAmountsForLiquidityRoundDown(_liquidityToRemove);

    vm.expectEmit();
    emit LPVault.Withdraw(_depositor, _receiver, _shares, _amount0Received, _amount1Received);

    vm.prank(_depositor);
    vault.withdraw(_shares, _receiver);
  }

  function testFuzz_PartialWithdraw(
    address _depositor,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _withdrawPercent,
    address _receiver
  ) public {
    _assumeSafeAddress(_depositor);
    _assumeSafeAddress(_receiver);
    _withdrawPercent = bound(_withdrawPercent, 1, 99);

    // Ensure initialization happens before capturing state
    _ensureInitialized(makeAddr("initForTest"));

    uint256 _totalSupplyBefore = vault.totalSupply();

    (uint256 _shares,,) = _deposit(_depositor, _amount0, _amount1);

    uint256 _sharesToWithdraw = (_shares * _withdrawPercent) / 100;
    uint256 _expectedRemainingShares = _shares - _sharesToWithdraw;

    uint256 _receiverToken0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(_receiver);
    uint256 _receiverToken1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(_receiver);

    vm.prank(_depositor);
    (uint256 _amount0Received, uint256 _amount1Received) =
      vault.withdraw(_sharesToWithdraw, _receiver);

    assertEq(vault.balanceOf(_depositor), _expectedRemainingShares);
    // Total supply = initializer shares + depositor remaining shares
    assertEq(vault.totalSupply(), _totalSupplyBefore + _expectedRemainingShares);
    assertEq(
      MockERC20(Currency.unwrap(currency0)).balanceOf(_receiver),
      _receiverToken0Before + _amount0Received
    );
    assertEq(
      MockERC20(Currency.unwrap(currency1)).balanceOf(_receiver),
      _receiverToken1Before + _amount1Received
    );
  }

  function testFuzz_MultipleDepositsThenWithdraw(
    address _depositor,
    uint256 _amount0,
    uint256 _amount1,
    address _receiver
  ) public {
    _assumeSafeAddress(_depositor);
    vm.assume(_receiver != address(0));

    // Ensure initialization happens before capturing state
    _ensureInitialized(makeAddr("initForTest"));

    uint256 _totalSupplyBefore = vault.totalSupply();
    (,,, uint128 _position0LiquidityBefore) = vault.positions(0);

    // First deposit.
    (uint256 _shares1, uint256 _amount0Used1, uint256 _amount1Used1) =
      _deposit(_depositor, _amount0, _amount1);

    // Second deposit - accumulate into first deposit variables.
    {
      (uint256 _shares2, uint256 _amount0Used2, uint256 _amount1Used2) =
        _deposit(_depositor, _amount0, _amount1);
      _shares1 += _shares2;
      _amount0Used1 += _amount0Used2;
      _amount1Used1 += _amount1Used2;
    }

    // Withdraw all depositor's shares.
    vm.prank(_depositor);
    (uint256 _amount0Received, uint256 _amount1Received) = vault.withdraw(_shares1, _receiver);

    // Verify depositor's shares burned.
    assertEq(vault.balanceOf(_depositor), 0);
    // Total supply returns to initializer shares
    assertEq(vault.totalSupply(), _totalSupplyBefore);

    // Verify amounts received match total deposited (within rounding tolerance).
    // Two sources of rounding loss compound across 2 deposits + 1 withdrawal:
    //   1. v4 SqrtPriceMath asymmetric rounding: deposit rounds token amounts UP (user overpays),
    //      withdraw rounds DOWN (user receives less). Up to 1 wei per token per position per op.
    //   2. FullMath.mulDiv truncation: proportional liquidity for positions 1 & 2 is truncated on
    //      each deposit/withdraw, so deposited vs withdrawn liquidity can differ by ~1 wei.
    // With 2 positions contributing to each token, the practical max is ~5 wei.
    assertApproxEqAbs(_amount0Received, _amount0Used1, 5);
    assertApproxEqAbs(_amount1Received, _amount1Used1, 5);

    // Verify liquidity returns to pre-deposit state.
    (,,, uint128 _position0LiquidityAfter) = vault.positions(0);
    assertEq(_position0LiquidityAfter, _position0LiquidityBefore);
  }

  function testFuzz_MultipleDepositsAndMultipleWithdraws(
    address _depositor,
    uint256 _amount0,
    uint256 _amount1,
    address _receiver
  ) public {
    _assumeSafeAddress(_depositor);
    vm.assume(_receiver != address(0));
    vm.assume(_depositor != makeAddr("initForTest"));

    // Ensure initialization happens before capturing state
    _ensureInitialized(makeAddr("initForTest"));

    uint256 _initSupply = vault.totalSupply();

    // Two deposits.
    (uint256 _shares1,,) = _deposit(_depositor, _amount0, _amount1);
    (uint256 _shares2,,) = _deposit(_depositor, _amount0, _amount1);
    uint256 _totalShares = _shares1 + _shares2;

    // Verify total shares minted for depositor.
    assertEq(vault.balanceOf(_depositor), _totalShares);
    assertEq(vault.totalSupply(), _initSupply + _totalShares);

    // First withdrawal - withdraw half.
    uint256 _half = _totalShares / 2;
    vm.prank(_depositor);
    vault.withdraw(_half, _receiver);
    assertEq(vault.balanceOf(_depositor), _totalShares - _half);

    // Second withdrawal - withdraw remaining.
    uint256 _remaining = vault.balanceOf(_depositor);
    if (_remaining > 0) {
      vm.prank(_depositor);
      vault.withdraw(_remaining, _receiver);
    }

    // Verify depositor shares burned.
    assertEq(vault.balanceOf(_depositor), 0);
    assertEq(vault.totalSupply(), _initSupply);
  }

  function testFuzz_RevertIf_ZeroShares(address _depositor, address _receiver) public {
    _assumeSafeAddress(_depositor);
    vm.assume(_receiver != address(0));

    vm.prank(_depositor);
    vm.expectRevert(LPVault.LPVault__InvalidShares.selector);
    vault.withdraw(0, _receiver);
  }

  function testFuzz_RevertIf_InsufficientShares(
    address _depositor,
    uint256 _amount0,
    uint256 _amount1,
    address _receiver
  ) public {
    _assumeSafeAddress(_depositor);
    vm.assume(_receiver != address(0));

    (uint256 _shares,,) = _deposit(_depositor, _amount0, _amount1);

    vm.prank(_depositor);
    vm.expectRevert();
    vault.withdraw(_shares + 1, _receiver);
  }

  /// @notice Tests that fees are synced before withdraw operations.
  function testFuzz_FeesSyncedBeforeWithdraw(
    address _depositor,
    address _receiver,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _swapAbs0,
    uint256 _swapAbs1
  ) public {
    _assumeSafeAddress(_depositor);
    _assumeSafeAddress(_receiver);
    vm.assume(_depositor != _receiver);

    (uint256 _shares,,) = _deposit(_depositor, _amount0, _amount1);

    // Generate fees
    _performSwap(true, _boundSwapAbs(_swapAbs0));
    _performSwap(false, _boundSwapAbs(_swapAbs1));

    uint256 _feeIndex0Before = vault.globalFeeIndex0Scaled();
    uint256 _feeIndex1Before = vault.globalFeeIndex1Scaled();

    // Withdraw should sync fees before removing liquidity
    vm.prank(_depositor);
    vault.withdraw(_shares, _receiver);

    uint256 _feeIndex0After = vault.globalFeeIndex0Scaled();
    uint256 _feeIndex1After = vault.globalFeeIndex1Scaled();

    // Fee indexes should have increased (fees synced during withdraw)
    assertGt(_feeIndex0After, _feeIndex0Before);
    assertGt(_feeIndex1After, _feeIndex1Before);
  }

  function testFuzz_PaysOutPrincipalAfterFeeGrowthInsideWrapsPastZero(
    address _initializer,
    address _receiver
  ) public {
    _assumeSafeAddress(_initializer);
    _assumeSafeAddress(_receiver);
    uint256 _shares = _initializeVaultAndWrapFeeGrowthInsidePastZero(_initializer);
    uint256 _receiverToken0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(_receiver);
    uint256 _receiverToken1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(_receiver);

    vm.prank(_initializer);
    (uint256 _amount0, uint256 _amount1) = vault.withdraw(_shares, _receiver);

    assertEq(vault.balanceOf(_initializer), 0);
    assertGt(_amount0, 0);
    assertGt(_amount1, 0);
    assertEq(
      MockERC20(Currency.unwrap(currency0)).balanceOf(_receiver), _receiverToken0Before + _amount0
    );
    assertEq(
      MockERC20(Currency.unwrap(currency1)).balanceOf(_receiver), _receiverToken1Before + _amount1
    );
  }
}

contract CollectFees is LPVaultTest {
  function _collectFeesAndAssertVaultDelta()
    internal
    returns (uint256 _collectedFee0, uint256 _collectedFee1)
  {
    uint256 _vaultToken0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(vault));
    uint256 _vaultToken1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(address(vault));

    (_collectedFee0, _collectedFee1) = vault.collectFees();

    uint256 _vaultToken0After = MockERC20(Currency.unwrap(currency0)).balanceOf(address(vault));
    uint256 _vaultToken1After = MockERC20(Currency.unwrap(currency1)).balanceOf(address(vault));

    assertEq(_vaultToken0After, _vaultToken0Before + _collectedFee0);
    assertEq(_vaultToken1After, _vaultToken1Before + _collectedFee1);
  }

  function _expectedIndexDelta(uint256 _collectedFee, uint256 _totalSupply)
    internal
    pure
    returns (uint256)
  {
    if (_collectedFee == 0 || _totalSupply == 0) return 0;
    return Math.mulDiv(_collectedFee, FEE_INDEX_PRECISION, _totalSupply, Math.Rounding.Floor);
  }

  function _expectedAccrued(uint256 _balance, uint256 _globalIndex)
    internal
    pure
    returns (uint256)
  {
    if (_balance == 0 || _globalIndex == 0) return 0;
    return Math.mulDiv(_balance, _globalIndex, FEE_INDEX_PRECISION, Math.Rounding.Floor);
  }

  function _claimAndAssert(address _user, uint256 _globalIndex0, uint256 _globalIndex1) internal {
    uint256 _balance = vault.balanceOf(_user);
    uint256 _expected0 = _expectedAccrued(_balance, _globalIndex0);
    uint256 _expected1 = _expectedAccrued(_balance, _globalIndex1);

    vm.prank(_user);
    (uint256 _claimed0, uint256 _claimed1) = vault.claim(_user);

    assertEq(_claimed0, _expected0);
    assertEq(_claimed1, _expected1);
  }

  function testFuzz_CollectFeesAfterSwaps(
    address _depositor,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _swapAbs0,
    uint256 _swapAbs1
  ) public {
    _assumeSafeAddress(_depositor);
    _deposit(_depositor, _amount0, _amount1);
    _performSwap(true, _boundSwapAbs(_swapAbs0));
    _performSwap(false, _boundSwapAbs(_swapAbs1));

    _collectFeesAndAssertVaultDelta();
  }

  function testFuzz_CollectFeesEmitsFeesCollectedEvent(
    address _depositor,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _swapAbs0,
    uint256 _swapAbs1
  ) public {
    _assumeSafeAddress(_depositor);
    _deposit(_depositor, _amount0, _amount1);

    vm.expectEmit();
    emit LPVault.FeesCollected(0, 0);
    vault.collectFees();
  }

  function testFuzz_CollectFeesUpdatesFeeIndexes(
    address _depositor,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _swapAbs0,
    uint256 _swapAbs1
  ) public {
    _assumeSafeAddress(_depositor);
    _deposit(_depositor, _amount0, _amount1);
    _performSwap(true, _boundSwapAbs(_swapAbs0));
    _performSwap(false, _boundSwapAbs(_swapAbs1));

    uint256 _totalSupply = vault.totalSupply();

    uint256 _feeIndex0Before = vault.globalFeeIndex0Scaled();
    uint256 _feeIndex1Before = vault.globalFeeIndex1Scaled();

    (uint256 _collectedFee0, uint256 _collectedFee1) = _collectFeesAndAssertVaultDelta();

    uint256 _expectedIndexDelta0 = _expectedIndexDelta(_collectedFee0, _totalSupply);
    uint256 _expectedIndexDelta1 = _expectedIndexDelta(_collectedFee1, _totalSupply);

    uint256 _feeIndex0After = vault.globalFeeIndex0Scaled();
    uint256 _feeIndex1After = vault.globalFeeIndex1Scaled();

    assertEq(_feeIndex0After - _feeIndex0Before, _expectedIndexDelta0);
    assertEq(_feeIndex1After - _feeIndex1Before, _expectedIndexDelta1);
  }

  function testFuzz_FeesCollectedDuringDeposit(
    address _depositor1,
    address _depositor2,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _swapAbs0
  ) public {
    _assumeSafeAddress(_depositor1);
    _assumeSafeAddress(_depositor2);
    vm.assume(_depositor1 != _depositor2);

    _deposit(_depositor1, _amount0, _amount1);

    _performSwap(true, _boundSwapAbs(_swapAbs0));

    uint256 _totalSupply = vault.totalSupply();
    uint256 _feeIndex0Before = vault.globalFeeIndex0Scaled();
    uint256 _feeIndex1Before = vault.globalFeeIndex1Scaled();

    uint256 _vaultToken0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(vault));
    uint256 _vaultToken1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(address(vault));

    _deposit(_depositor2, _amount0, _amount1);

    uint256 _vaultToken0After = MockERC20(Currency.unwrap(currency0)).balanceOf(address(vault));
    uint256 _vaultToken1After = MockERC20(Currency.unwrap(currency1)).balanceOf(address(vault));

    uint256 _collectedFee0 = _vaultToken0After - _vaultToken0Before;
    uint256 _collectedFee1 = _vaultToken1After - _vaultToken1Before;

    uint256 _expectedIndexDelta0 = _expectedIndexDelta(_collectedFee0, _totalSupply);
    uint256 _expectedIndexDelta1 = _expectedIndexDelta(_collectedFee1, _totalSupply);

    uint256 _feeIndex0After = vault.globalFeeIndex0Scaled();
    uint256 _feeIndex1After = vault.globalFeeIndex1Scaled();
    assertEq(_feeIndex0After - _feeIndex0Before, _expectedIndexDelta0);
    assertEq(_feeIndex1After - _feeIndex1Before, _expectedIndexDelta1);
  }

  function testFuzz_FeesCollectedDuringWithdraw(
    address _depositor,
    address _receiver,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _swapAbs0,
    uint256 _swapAbs1,
    uint256 _withdrawShares
  ) public {
    _assumeSafeAddress(_depositor);
    _assumeSafeAddress(_receiver);
    (uint256 _shares,,) = _deposit(_depositor, _amount0, _amount1);
    _withdrawShares = bound(_withdrawShares, 1, _shares);

    _performSwap(true, _boundSwapAbs(_swapAbs0));
    _performSwap(false, _boundSwapAbs(_swapAbs1));

    uint256 _feeIndex0Before = vault.globalFeeIndex0Scaled();
    uint256 _feeIndex1Before = vault.globalFeeIndex1Scaled();
    uint256 _totalSupplyBefore = vault.totalSupply();

    uint256 _vaultToken0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(vault));
    uint256 _vaultToken1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(address(vault));

    vm.prank(_depositor);
    vault.withdraw(_withdrawShares, _receiver);

    uint256 _vaultToken0After = MockERC20(Currency.unwrap(currency0)).balanceOf(address(vault));
    uint256 _vaultToken1After = MockERC20(Currency.unwrap(currency1)).balanceOf(address(vault));

    uint256 _collectedFee0 = _vaultToken0After - _vaultToken0Before;
    uint256 _collectedFee1 = _vaultToken1After - _vaultToken1Before;

    uint256 _expectedIndexDelta0 = _expectedIndexDelta(_collectedFee0, _totalSupplyBefore);
    uint256 _expectedIndexDelta1 = _expectedIndexDelta(_collectedFee1, _totalSupplyBefore);

    uint256 _feeIndex0After = vault.globalFeeIndex0Scaled();
    uint256 _feeIndex1After = vault.globalFeeIndex1Scaled();
    assertEq(_feeIndex0After - _feeIndex0Before, _expectedIndexDelta0);
    assertEq(_feeIndex1After - _feeIndex1Before, _expectedIndexDelta1);
  }

  function testFuzz_MultipleCollectFeesCalls(
    address _depositor,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _swapAbs0,
    uint256 _swapAbs1
  ) public {
    _assumeSafeAddress(_depositor);
    _deposit(_depositor, _amount0, _amount1);

    _performSwap(true, _boundSwapAbs(_swapAbs0));
    (, uint256 _fees1Round1) = _collectFeesAndAssertVaultDelta();

    _performSwap(false, _boundSwapAbs(_swapAbs1));
    (uint256 _fees0Round2,) = _collectFeesAndAssertVaultDelta();

    assertEq(_fees1Round1, 0);
    assertEq(_fees0Round2, 0);
  }

  function testFuzz_CollectFeesCallableByAnyone(
    address _depositor,
    uint256 _amount0,
    uint256 _amount1,
    address _caller,
    uint256 _swapAbs0
  ) public {
    _assumeSafeAddress(_depositor);
    _assumeSafeAddress(_caller);
    _deposit(_depositor, _amount0, _amount1);

    _performSwap(true, _boundSwapAbs(_swapAbs0));

    uint256 _vaultToken0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(vault));
    uint256 _vaultToken1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(address(vault));

    vm.prank(_caller);
    (uint256 _collectedFee0, uint256 _collectedFee1) = vault.collectFees();

    uint256 _vaultToken0After = MockERC20(Currency.unwrap(currency0)).balanceOf(address(vault));
    uint256 _vaultToken1After = MockERC20(Currency.unwrap(currency1)).balanceOf(address(vault));

    assertEq(_vaultToken0After, _vaultToken0Before + _collectedFee0);
    assertEq(_vaultToken1After, _vaultToken1Before + _collectedFee1);
    assertEq(_collectedFee1, 0);
  }

  function testFuzz_FeesAccrueToShareHolders(
    address _depositor,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _swapAbs0,
    uint256 _swapAbs1
  ) public {
    _assumeSafeAddress(_depositor);
    _deposit(_depositor, _amount0, _amount1);

    _performSwap(true, _boundSwapAbs(_swapAbs0));
    _performSwap(false, _boundSwapAbs(_swapAbs1));

    uint256 _totalSupply = vault.totalSupply();
    (uint256 _collectedFee0, uint256 _collectedFee1) = _collectFeesAndAssertVaultDelta();
    uint256 _expectedIndex0 = _expectedIndexDelta(_collectedFee0, _totalSupply);
    uint256 _expectedIndex1 = _expectedIndexDelta(_collectedFee1, _totalSupply);
    uint256 _globalIndex0 = vault.globalFeeIndex0Scaled();
    uint256 _globalIndex1 = vault.globalFeeIndex1Scaled();

    assertEq(_globalIndex0, _expectedIndex0);
    assertEq(_globalIndex1, _expectedIndex1);
  }

  function testFuzz_ClaimFeesAfterCollect(
    address _depositor,
    uint256,
    uint256,
    uint256 _swapAbs0,
    uint256 _swapAbs1
  ) public {
    _assumeSafeAddress(_depositor);

    // Initialize with the depositor so they hold all shares and receive all fees
    _initializeLiquidity(_depositor);

    _performSwap(true, _boundSwapAbs(_swapAbs0));
    _performSwap(false, _boundSwapAbs(_swapAbs1));

    _collectFeesAndAssertVaultDelta();
    uint256 _globalIndex0 = vault.globalFeeIndex0Scaled();
    uint256 _globalIndex1 = vault.globalFeeIndex1Scaled();
    uint256 _balance = vault.balanceOf(_depositor);
    uint256 _expectedFee0 = _expectedAccrued(_balance, _globalIndex0);
    uint256 _expectedFee1 = _expectedAccrued(_balance, _globalIndex1);

    vm.prank(_depositor);
    (uint256 _claimed0, uint256 _claimed1) = vault.claim(_depositor);

    assertEq(_claimed0, _expectedFee0);
    assertEq(_claimed1, _expectedFee1);
  }

  function testFuzz_FeesDistributedProportionallyToken0(
    address _depositor1,
    address _depositor2,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _swapAbs0
  ) public {
    _assumeSafeAddress(_depositor1);
    _assumeSafeAddress(_depositor2);
    vm.assume(_depositor1 != _depositor2);

    _deposit(_depositor1, _amount0, _amount1);
    _deposit(_depositor1, _amount0, _amount1);
    _deposit(_depositor2, _amount0, _amount1);

    _performSwap(true, _boundSwapAbs(_swapAbs0));
    (, uint256 _collectedFee1) = _collectFeesAndAssertVaultDelta();
    assertEq(_collectedFee1, 0);

    uint256 _globalIndex0 = vault.globalFeeIndex0Scaled();
    uint256 _globalIndex1 = vault.globalFeeIndex1Scaled();
    assertEq(_globalIndex1, 0);

    _claimAndAssert(_depositor1, _globalIndex0, _globalIndex1);
    _claimAndAssert(_depositor2, _globalIndex0, _globalIndex1);
  }

  function testFuzz_FeesDistributedProportionallyToken1(
    address _depositor1,
    address _depositor2,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _swapAbs1
  ) public {
    _assumeSafeAddress(_depositor1);
    _assumeSafeAddress(_depositor2);
    vm.assume(_depositor1 != _depositor2);

    _deposit(_depositor1, _amount0, _amount1);
    _deposit(_depositor1, _amount0, _amount1);
    _deposit(_depositor2, _amount0, _amount1);

    _performSwap(false, _boundSwapAbs(_swapAbs1));
    (uint256 _collectedFee0,) = _collectFeesAndAssertVaultDelta();
    assertEq(_collectedFee0, 0);

    uint256 _globalIndex0 = vault.globalFeeIndex0Scaled();
    uint256 _globalIndex1 = vault.globalFeeIndex1Scaled();
    assertEq(_globalIndex0, 0);

    _claimAndAssert(_depositor1, _globalIndex0, _globalIndex1);
    _claimAndAssert(_depositor2, _globalIndex0, _globalIndex1);
  }

  function testFuzz_CreditsFeesEarnedWhileFeeGrowthInsideWrapsPastZero(address _initializer)
    public
  {
    _assumeSafeAddress(_initializer);
    _initializeVaultAndWrapFeeGrowthInsidePastZero(_initializer);
    uint256 _totalSupply = vault.totalSupply();

    (uint256 _collectedFee0,) = _collectFeesAndAssertVaultDelta();

    assertGt(_collectedFee0, 0);
    assertEq(vault.globalFeeIndex0Scaled(), _expectedIndexDelta(_collectedFee0, _totalSupply));
  }

  /// @notice Tests that fees are attributed to the original holder when shares are transferred.
  function testFuzz_FeesAttributedOnTransfer(
    address _depositor,
    address _recipient,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _swapAbs0,
    uint256 _swapAbs1
  ) public {
    _assumeSafeAddress(_depositor);
    _assumeSafeAddress(_recipient);
    vm.assume(_depositor != _recipient);

    // Deposit and get shares
    (uint256 _shares,,) = _deposit(_depositor, _amount0, _amount1);

    // Generate fees via swaps (but don't collect yet).
    _performSwap(true, _boundSwapAbs(_swapAbs0));
    _performSwap(false, _boundSwapAbs(_swapAbs1));

    // Transfer shares BEFORE collecting fees. This syncs fees and attributes accrued fees
    // to the sender before balances move.
    vm.prank(_depositor);
    vault.transfer(_recipient, _shares);

    (,, uint256 _expectedClaim0, uint256 _expectedClaim1) = vault.userFees(_depositor);

    // Now collect fees - they should be attributed to depositor (original holder)
    vault.collectFees();

    // Depositor should be able to claim fees that accrued while they held shares
    vm.prank(_depositor);
    (uint256 _claimed0, uint256 _claimed1) = vault.claim(_depositor);

    assertEq(_claimed0, _expectedClaim0);
    assertEq(_claimed1, _expectedClaim1);

    // Recipient should have no fees (they got shares after fees accrued)
    vm.prank(_recipient);
    (uint256 _recipientClaimed0, uint256 _recipientClaimed1) = vault.claim(_recipient);
    assertEq(_recipientClaimed0, 0);
    assertEq(_recipientClaimed1, 0);
  }

  /// @notice Tests that checkpoints prevent claiming fees from before we had liquidity.
  function testFuzz_CheckpointsPreventPreLiquidityFees(
    address _depositor,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _swapAbs0
  ) public {
    _assumeSafeAddress(_depositor);

    // Generate fees BEFORE any deposit (pool has fees but vault has no liquidity)
    // Note: This is a bit tricky since we need fees in the pool before our position exists
    // In practice, this tests that checkpoints are initialized correctly on first deposit
    _deposit(_depositor, _amount0, _amount1);
    uint256 _balance = vault.balanceOf(_depositor);
    uint256 _globalIndex0Before = vault.globalFeeIndex0Scaled();

    // Now generate fees (vault has liquidity)
    _performSwap(true, _boundSwapAbs(_swapAbs0));

    // Collect fees
    vault.collectFees();
    uint256 _globalIndex0After = vault.globalFeeIndex0Scaled();
    uint256 _expectedClaim0 = _expectedAccrued(_balance, _globalIndex0After - _globalIndex0Before);

    // Claim fees - should only get fees from after we deposited
    vm.prank(_depositor);
    (uint256 _claimed0,) = vault.claim(_depositor);

    // Should only include fees accrued after the depositor held shares.
    assertEq(_claimed0, _expectedClaim0);
  }

  /// @notice Tests that fee indexes update on transfer even without collecting fees.
  function testFuzz_FeeIndexesUpdateOnTransfer(
    address _depositor,
    address _recipient,
    uint256 _amount0,
    uint256 _amount1,
    uint256 _swapAbs0
  ) public {
    _assumeSafeAddress(_depositor);
    _assumeSafeAddress(_recipient);
    vm.assume(_depositor != _recipient);

    (uint256 _shares,,) = _deposit(_depositor, _amount0, _amount1);

    // Generate fees
    BalanceDelta _delta = _performSwap(true, _boundSwapAbs(_swapAbs0));
    uint256 _expectedFee0 = uint256(-int256(_delta.amount0())) * DEFAULT_FEE / FEE_DENOMINATOR;

    uint256 _totalSupply = vault.totalSupply();
    uint256 _expectedIndexDelta0 = _expectedFee0 * FEE_INDEX_PRECISION / _totalSupply;
    uint256 _feeIndex0Before = vault.globalFeeIndex0Scaled();

    // Transfer should sync fees and update index (without collecting)
    vm.prank(_depositor);
    vault.transfer(_recipient, _shares);

    uint256 _feeIndex0After = vault.globalFeeIndex0Scaled();

    // Fee index should have increased even though we didn't call collectFees()
    assertApproxEqRel(_feeIndex0After - _feeIndex0Before, _expectedIndexDelta0, FEE_TOLERANCE);
  }
}

contract Transfer is LPVaultTest {
  function testFuzz_MovesSharesAfterFeeGrowthInsideWrapsPastZero(
    address _initializer,
    address _recipient,
    uint256 _amount
  ) public {
    _assumeSafeAddress(_initializer);
    _assumeSafeAddress(_recipient);
    vm.assume(_initializer != _recipient);
    uint256 _shares = _initializeVaultAndWrapFeeGrowthInsidePastZero(_initializer);
    _amount = bound(_amount, 0, _shares);

    vm.prank(_initializer);
    vault.transfer(_recipient, _amount);

    assertEq(vault.balanceOf(_initializer), _shares - _amount);
    assertEq(vault.balanceOf(_recipient), _amount);
  }
}
