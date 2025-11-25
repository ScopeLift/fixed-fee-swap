// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LPVault} from "src/LPVault.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

contract LPVaultTest is Test {
  address constant POOL_MANAGER = address(0x1);
  address constant TOKEN0 = address(0x2);
  address constant TOKEN1 = address(0x3);

  int24 constant MIN_TICK = -887_272;
  int24 constant MAX_TICK = 887_272;

  uint256 constant TOTAL_WEIGHT = 10_000;
  uint24 constant DEFAULT_FEE = 3000;
  int24 constant DEFAULT_TICK_SPACING = 60;

  PoolKey defaultPoolKey;
  LPVault.LiquidityPosition[] defaultPositions;
  LPVault vault;

  function setUp() public virtual {
    defaultPoolKey = PoolKey({
      currency0: Currency.wrap(TOKEN0),
      currency1: Currency.wrap(TOKEN1),
      fee: DEFAULT_FEE,
      tickSpacing: DEFAULT_TICK_SPACING,
      hooks: IHooks(address(0))
    });

    defaultPositions.push(
      LPVault.LiquidityPosition({tickLower: -100, tickUpper: 100, weight: TOTAL_WEIGHT})
    );

    vault = new LPVault(IPoolManager(POOL_MANAGER), defaultPoolKey, defaultPositions);
  }

  function _boundTick(int24 _tick) internal pure returns (int24) {
    return int24(bound(int256(_tick), int256(MIN_TICK), int256(MAX_TICK)));
  }
}

contract Constructor is LPVaultTest {
  function setUp() public override {
    super.setUp();
  }

  function testFuzz_SinglePosition(int24 _tickLower, int24 _tickUpper) public {
    _tickLower = _boundTick(_tickLower);
    _tickUpper = _boundTick(_tickUpper);
    vm.assume(_tickLower < _tickUpper);

    LPVault.LiquidityPosition[] memory _positions = new LPVault.LiquidityPosition[](1);
    _positions[0] = LPVault.LiquidityPosition({
      tickLower: _tickLower, tickUpper: _tickUpper, weight: TOTAL_WEIGHT
    });

    LPVault _newVault = new LPVault(IPoolManager(POOL_MANAGER), defaultPoolKey, _positions);

    assertEq(address(_newVault.POOL_MANAGER()), POOL_MANAGER);
    assertEq(_newVault.TOKEN0(), TOKEN0);
    assertEq(_newVault.TOKEN1(), TOKEN1);

    (int24 storedTickLower, int24 storedTickUpper, uint256 storedWeight) = _newVault.positions(0);
    assertEq(storedTickLower, _tickLower);
    assertEq(storedTickUpper, _tickUpper);
    assertEq(storedWeight, TOTAL_WEIGHT);
  }

  function testFuzz_MultiplePositionsWithWeights(uint256 _weight1, uint256 _weight2) public {
    _weight1 = bound(_weight1, 1, 9998);
    _weight2 = bound(_weight2, 1, 9999 - _weight1);
    uint256 _weight3 = TOTAL_WEIGHT - _weight1 - _weight2;

    LPVault.LiquidityPosition[] memory _positions = new LPVault.LiquidityPosition[](3);
    _positions[0] = LPVault.LiquidityPosition({tickLower: -300, tickUpper: -200, weight: _weight1});
    _positions[1] = LPVault.LiquidityPosition({tickLower: -200, tickUpper: -100, weight: _weight2});
    _positions[2] = LPVault.LiquidityPosition({tickLower: -100, tickUpper: 0, weight: _weight3});

    LPVault _newVault = new LPVault(IPoolManager(POOL_MANAGER), defaultPoolKey, _positions);

    (,, uint256 position0Weight) = _newVault.positions(0);
    (,, uint256 position1Weight) = _newVault.positions(1);
    (,, uint256 position2Weight) = _newVault.positions(2);
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
    vm.assume(_token0 != _token1 && _token0 != address(0) && _token1 != address(0));
    if (_token0 > _token1) (_token0, _token1) = (_token1, _token0);

    _fee = uint24(bound(_fee, 0, 1_000_000));
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
      LPVault.LiquidityPosition({tickLower: -100, tickUpper: 100, weight: TOTAL_WEIGHT});

    LPVault _newVault = new LPVault(IPoolManager(POOL_MANAGER), _poolKey, _positions);

    (
      Currency currency0,
      Currency currency1,
      uint24 storedFee,
      int24 storedTickSpacing,
      IHooks storedHooks
    ) = _newVault.targetPoolKey();

    assertEq(Currency.unwrap(currency0), _token0);
    assertEq(Currency.unwrap(currency1), _token1);
    assertEq(storedFee, _fee);
    assertEq(storedTickSpacing, _tickSpacing);
    assertEq(address(storedHooks), _hook);
  }

  function test_RevertIf_NoPositions() public {
    LPVault.LiquidityPosition[] memory _positions = new LPVault.LiquidityPosition[](0);

    vm.expectRevert(LPVault.LPVault__NoPositions.selector);
    new LPVault(IPoolManager(POOL_MANAGER), defaultPoolKey, _positions);
  }

  function testFuzz_RevertIf_WeightDoesNotSumToFullWeight(uint256 _weight) public {
    vm.assume(_weight != TOTAL_WEIGHT);

    LPVault.LiquidityPosition[] memory _positions = new LPVault.LiquidityPosition[](1);
    _positions[0] = LPVault.LiquidityPosition({tickLower: -100, tickUpper: 100, weight: _weight});

    vm.expectRevert(LPVault.LPVault__InvalidLiquidityDistribution.selector);
    new LPVault(IPoolManager(POOL_MANAGER), defaultPoolKey, _positions);
  }

  function testFuzz_RevertIf_MultiplePositionsWeightMismatch(uint256 _weight1, uint256 _weight2)
    public
  {
    _weight1 = bound(_weight1, 0, 9999);
    _weight2 = bound(_weight2, 0, 9999 - _weight1);

    LPVault.LiquidityPosition[] memory _positions = new LPVault.LiquidityPosition[](2);
    _positions[0] = LPVault.LiquidityPosition({tickLower: -200, tickUpper: -100, weight: _weight1});
    _positions[1] = LPVault.LiquidityPosition({tickLower: -100, tickUpper: 0, weight: _weight2});

    vm.expectRevert(LPVault.LPVault__InvalidLiquidityDistribution.selector);
    new LPVault(IPoolManager(POOL_MANAGER), defaultPoolKey, _positions);
  }

  function testFuzz_RevertIf_InvalidTickRange(int24 _tickLower, int24 _tickUpper) public {
    _tickLower = _boundTick(_tickLower);
    _tickUpper = _boundTick(_tickUpper);
    vm.assume(_tickLower >= _tickUpper);

    LPVault.LiquidityPosition[] memory _positions = new LPVault.LiquidityPosition[](1);
    _positions[0] = LPVault.LiquidityPosition({
      tickLower: _tickLower, tickUpper: _tickUpper, weight: TOTAL_WEIGHT
    });

    vm.expectRevert(LPVault.LPVault__InvalidTickRange.selector);
    new LPVault(IPoolManager(POOL_MANAGER), defaultPoolKey, _positions);
  }
}
