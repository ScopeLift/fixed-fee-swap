// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {LPVault} from "src/LPVault.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {Position} from "v4-core/libraries/Position.sol";

contract LPVaultTest is Test, Deployers {
  using PoolIdLibrary for PoolKey;
  using StateLibrary for IPoolManager;

  int24 constant MIN_TICK = -887_272;
  int24 constant MAX_TICK = 887_272;

  uint16 constant BIPS = 10_000;
  uint24 constant DEFAULT_FEE = 3000;
  int24 constant DEFAULT_TICK_SPACING = 60;

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
    vault = new LPVault(manager, defaultPoolKey, defaultPositions, DEFAULT_NAME, DEFAULT_SYMBOL);
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
    vm.assume(_addr != address(0) && _addr != address(manager) && _addr != address(vault));
  }
}

contract Constructor is LPVaultTest {
  function testFuzz_SinglePosition(int24 _tickLower, int24 _tickUpper, address _deployer) public {
    _tickLower = _boundTick(_tickLower);
    _tickUpper = _boundTick(_tickUpper);
    vm.assume(_tickLower < _tickUpper);
    vm.assume(_deployer != address(0));

    LPVault.LiquidityPosition[] memory _positions = new LPVault.LiquidityPosition[](1);
    _positions[0] = LPVault.LiquidityPosition({
      tickLower: _tickLower, tickUpper: _tickUpper, weight: BIPS, liquidity: 0
    });

    vm.prank(_deployer);
    LPVault _newVault =
      new LPVault(manager, defaultPoolKey, _positions, DEFAULT_NAME, DEFAULT_SYMBOL);

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

    LPVault _newVault =
      new LPVault(manager, defaultPoolKey, _positions, DEFAULT_NAME, DEFAULT_SYMBOL);

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
      LPVault.LiquidityPosition({tickLower: -100, tickUpper: 100, weight: BIPS, liquidity: 0});

    LPVault _newVault = new LPVault(manager, _poolKey, _positions, DEFAULT_NAME, DEFAULT_SYMBOL);

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
    new LPVault(manager, defaultPoolKey, _positions, DEFAULT_NAME, DEFAULT_SYMBOL);
  }

  function testFuzz_RevertIf_WeightDoesNotSumToFullWeight(uint16 _weight) public {
    vm.assume(_weight != BIPS);

    LPVault.LiquidityPosition[] memory _positions = new LPVault.LiquidityPosition[](1);
    _positions[0] =
      LPVault.LiquidityPosition({tickLower: -100, tickUpper: 100, weight: _weight, liquidity: 0});

    vm.expectRevert(LPVault.LPVault__InvalidLiquidityDistribution.selector);
    new LPVault(manager, defaultPoolKey, _positions, DEFAULT_NAME, DEFAULT_SYMBOL);
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
    new LPVault(manager, defaultPoolKey, _positions, DEFAULT_NAME, DEFAULT_SYMBOL);
  }

  function testFuzz_RevertIf_InvalidTickRange(int24 _tickLower, int24 _tickUpper) public {
    _tickLower = _boundTick(_tickLower);
    _tickUpper = _boundTick(_tickUpper);
    vm.assume(_tickLower >= _tickUpper);

    LPVault.LiquidityPosition[] memory _positions = new LPVault.LiquidityPosition[](1);
    _positions[0] = LPVault.LiquidityPosition({
      tickLower: _tickLower, tickUpper: _tickUpper, weight: BIPS, liquidity: 0
    });

    vm.expectRevert(LPVault.LPVault__InvalidTickRange.selector);
    new LPVault(manager, defaultPoolKey, _positions, DEFAULT_NAME, DEFAULT_SYMBOL);
  }

  function test_EmitsPoolManagerSetEvent() public {
    LPVault.LiquidityPosition[] memory _positions = new LPVault.LiquidityPosition[](1);
    _positions[0] =
      LPVault.LiquidityPosition({tickLower: -100, tickUpper: 100, weight: BIPS, liquidity: 0});

    vm.expectEmit();
    emit LPVault.PoolManagerSet(address(manager));
    new LPVault(manager, defaultPoolKey, _positions, DEFAULT_NAME, DEFAULT_SYMBOL);
  }

  function test_EmitsTokensSetEvent() public {
    LPVault.LiquidityPosition[] memory _positions = new LPVault.LiquidityPosition[](1);
    _positions[0] =
      LPVault.LiquidityPosition({tickLower: -100, tickUpper: 100, weight: BIPS, liquidity: 0});

    vm.expectEmit();
    emit LPVault.TokensSet(Currency.unwrap(currency0), Currency.unwrap(currency1));
    new LPVault(manager, defaultPoolKey, _positions, DEFAULT_NAME, DEFAULT_SYMBOL);
  }
}

contract Deposit is LPVaultTest {
  address depositor = makeAddr("depositor");

  /// @dev Sets up approvals for a depositor to interact with the vault.
  function _approveTokensForVault(address _depositor, uint256 _amount0, uint256 _amount1) internal {
    vm.startPrank(_depositor);
    MockERC20(Currency.unwrap(currency0)).approve(address(vault), _amount0);
    MockERC20(Currency.unwrap(currency1)).approve(address(vault), _amount1);
    vm.stopPrank();
  }

  /// @dev Calculates expected deposit outputs (shares = first position's liquidity).
  function _calculateExpectedDeposit(uint256 _amount0, uint256 _amount1)
    internal
    view
    returns (uint128 _expectedShares, uint256 _expectedAmount0, uint256 _expectedAmount1)
  {
    PoolId _poolId = defaultPoolKey.toId();
    (uint160 _sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, _poolId);

    for (uint256 _i = 0; _i < defaultPositions.length; _i++) {
      LPVault.LiquidityPosition memory _position = defaultPositions[_i];

      uint256 _amount0ForPosition = (_amount0 * _position.weight) / BIPS;
      uint256 _amount1ForPosition = (_amount1 * _position.weight) / BIPS;

      uint160 _sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(_position.tickLower);
      uint160 _sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(_position.tickUpper);

      uint128 _liquidity = LiquidityAmounts.getLiquidityForAmounts(
        _sqrtPriceX96,
        _sqrtPriceLowerX96,
        _sqrtPriceUpperX96,
        _amount0ForPosition,
        _amount1ForPosition
      );

      // Calculate amounts needed for this liquidity based on position's range relative to current
      // price.
      uint256 _amount0delta;
      uint256 _amount1delta;

      if (_sqrtPriceX96 <= _sqrtPriceLowerX96) {
        // Current price below position - only token0 needed.
        _amount0delta =
          SqrtPriceMath.getAmount0Delta(_sqrtPriceLowerX96, _sqrtPriceUpperX96, _liquidity, true);
      } else if (_sqrtPriceX96 >= _sqrtPriceUpperX96) {
        // Current price above position - only token1 needed.
        _amount1delta =
          SqrtPriceMath.getAmount1Delta(_sqrtPriceLowerX96, _sqrtPriceUpperX96, _liquidity, true);
      } else {
        // In range - both tokens needed.
        _amount0delta =
          SqrtPriceMath.getAmount0Delta(_sqrtPriceX96, _sqrtPriceUpperX96, _liquidity, true);
        _amount1delta =
          SqrtPriceMath.getAmount1Delta(_sqrtPriceLowerX96, _sqrtPriceX96, _liquidity, true);
      }

      // Shares are based on first position's liquidity only.
      if (_i == 0) _expectedShares = _liquidity;
      _expectedAmount0 += _amount0delta;
      _expectedAmount1 += _amount1delta;
    }
  }

  function testFuzz_MintsSharesAndTransfersTokens(uint256 _amount0, uint256 _amount1) public {
    _amount0 = bound(_amount0, 1e12, type(uint96).max);
    _amount1 = bound(_amount1, 1e12, type(uint96).max);
    deal(Currency.unwrap(currency0), depositor, _amount0);
    deal(Currency.unwrap(currency1), depositor, _amount1);

    (uint128 _expectedShares, uint256 _expectedAmount0, uint256 _expectedAmount1) =
      _calculateExpectedDeposit(_amount0, _amount1);

    _approveTokensForVault(depositor, _amount0, _amount1);
    uint256 _token0BalanceBefore = MockERC20(Currency.unwrap(currency0)).balanceOf(depositor);
    uint256 _token1BalanceBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(depositor);

    vm.prank(depositor);
    (uint256 _shares, uint256 _amount0Used, uint256 _amount1Used) =
      vault.deposit(_amount0, _amount1);

    // Verify shares were minted.
    assertEq(_shares, _expectedShares);
    assertEq(vault.balanceOf(depositor), _shares);

    // Verify tokens were transferred.
    assertEq(_amount0Used, _expectedAmount0);
    assertEq(_amount1Used, _expectedAmount1);

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

  function testFuzz_DistributesLiquidityAcrossPositions(uint256 _amount0, uint256 _amount1) public {
    _amount0 = bound(_amount0, 1e12, type(uint96).max);
    _amount1 = bound(_amount1, 1e12, type(uint96).max);
    deal(Currency.unwrap(currency0), depositor, _amount0);
    deal(Currency.unwrap(currency1), depositor, _amount1);
    _approveTokensForVault(depositor, _amount0, _amount1);

    PoolId _poolId = defaultPoolKey.toId();
    (uint160 _sqrtPriceX96,,,) = StateLibrary.getSlot0(manager, _poolId);

    // Calculate expected liquidity for each position.
    uint128[] memory _expectedLiquidity = new uint128[](defaultPositions.length);
    for (uint256 _i = 0; _i < defaultPositions.length; _i++) {
      LPVault.LiquidityPosition memory _position = defaultPositions[_i];

      uint256 _amount0ForPosition = (_amount0 * _position.weight) / BIPS;
      uint256 _amount1ForPosition = (_amount1 * _position.weight) / BIPS;

      uint160 _sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(_position.tickLower);
      uint160 _sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(_position.tickUpper);

      _expectedLiquidity[_i] = LiquidityAmounts.getLiquidityForAmounts(
        _sqrtPriceX96,
        _sqrtPriceLowerX96,
        _sqrtPriceUpperX96,
        _amount0ForPosition,
        _amount1ForPosition
      );
    }

    vm.prank(depositor);
    vault.deposit(_amount0, _amount1);

    // Verify each position's liquidity was updated correctly.
    for (uint256 _i = 0; _i < defaultPositions.length; _i++) {
      (,,, uint128 _storedLiquidity) = vault.positions(_i);
      assertEq(_storedLiquidity, _expectedLiquidity[_i]);
    }
  }

  function testFuzz_DepositEmitsDepositedEvent(uint256 _amount0, uint256 _amount1) public {
    _amount0 = bound(_amount0, 1e12, type(uint96).max);
    _amount1 = bound(_amount1, 1e12, type(uint96).max);
    deal(Currency.unwrap(currency0), depositor, _amount0);
    deal(Currency.unwrap(currency1), depositor, _amount1);
    _approveTokensForVault(depositor, _amount0, _amount1);

    (uint128 _expectedShares, uint256 _expectedAmount0, uint256 _expectedAmount1) =
      _calculateExpectedDeposit(_amount0, _amount1);

    vm.prank(depositor);
    vm.expectEmit();
    emit LPVault.Deposited(depositor, _expectedShares, _expectedAmount0, _expectedAmount1);
    vault.deposit(_amount0, _amount1);
  }

  function testFuzz_MultipleDeposits(uint256 _amount0, uint256 _amount1) public {
    _amount0 = bound(_amount0, 1e12, type(uint96).max / 2);
    _amount1 = bound(_amount1, 1e12, type(uint96).max / 2);
    deal(Currency.unwrap(currency0), depositor, _amount0 * 2);
    deal(Currency.unwrap(currency1), depositor, _amount1 * 2);
    _approveTokensForVault(depositor, _amount0 * 2, _amount1 * 2);

    // First deposit.
    vm.prank(depositor);
    (uint256 _shares1,,) = vault.deposit(_amount0, _amount1);

    // Second deposit.
    vm.prank(depositor);
    (uint256 _shares2,,) = vault.deposit(_amount0, _amount1);

    // Verify equal deposits yield equal shares (share parity).
    assertEq(_shares1, _shares2);

    // Verify total shares.
    assertEq(vault.balanceOf(depositor), _shares1 + _shares2);
    assertEq(vault.totalSupply(), _shares1 + _shares2);
  }

  function test_RevertIf_ZeroLiquidity() public {
    vm.prank(depositor);
    vm.expectRevert(Position.CannotUpdateEmptyPosition.selector);
    vault.deposit(0, 0);
  }

  function testFuzz_RevertIf_UnlockCallbackCalledByNonPoolManager(
    address _caller,
    uint256 _amount0Max,
    uint256 _amount1Max
  ) public {
    vm.assume(_caller != address(manager));

    LPVault.DepositCallbackData memory _callbackData = LPVault.DepositCallbackData({
      sender: address(this), amount0Max: _amount0Max, amount1Max: _amount1Max
    });

    vm.prank(_caller);
    vm.expectRevert(LPVault.LPVault__OnlyPoolManager.selector);
    vault.unlockCallback(abi.encode(_callbackData));
  }
}

contract Withdraw is LPVaultTest {
  function _setupDepositor(address _depositor) internal {
    deal(Currency.unwrap(currency0), _depositor, 1e18 ether);
    deal(Currency.unwrap(currency1), _depositor, 1e18 ether);

    vm.startPrank(_depositor);
    MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
    MockERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
    vm.stopPrank();
  }

  function _deposit(address _depositor, uint256 _amount0, uint256 _amount1)
    internal
    returns (uint256 _shares, uint256 _amount0Used, uint256 _amount1Used)
  {
    _setupDepositor(_depositor);
    _amount0 = bound(_amount0, 1e6, 1e18);
    _amount1 = bound(_amount1, 1e6, 1e18);

    vm.prank(_depositor);
    (_shares, _amount0Used, _amount1Used) = vault.deposit(_amount0, _amount1);
  }

  function testFuzz_WithdrawBurnsSharesAndTransfersTokens(
    address _depositor,
    uint256 _amount0,
    uint256 _amount1,
    address _receiver
  ) public {
    _assumeSafeAddress(_depositor);
    _assumeSafeAddress(_receiver);
    vm.assume(_depositor != _receiver);

    (uint256 _shares, uint256 _amount0Deposited, uint256 _amount1Deposited) =
      _deposit(_depositor, _amount0, _amount1);

    uint256 _receiverToken0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(_receiver);
    uint256 _receiverToken1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(_receiver);

    // Withdraw all shares.
    vm.prank(_depositor);
    (uint256 _amount0Received, uint256 _amount1Received) = vault.withdraw(_shares, _receiver);

    // Verify shares were burned.
    assertEq(vault.balanceOf(_depositor), 0);
    assertEq(vault.totalSupply(), 0);

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
    assertApproxEqAbs(_amount0Received, _amount0Deposited, 1);
    assertApproxEqAbs(_amount1Received, _amount1Deposited, 1);

    // Verify position liquidity is zero after full withdrawal.
    (,,, uint128 _positionLiquidity) = vault.positions(0);
    assertEq(_positionLiquidity, 0);
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

    vm.prank(_depositor);
    vm.expectEmit(true, true, false, false);
    emit LPVault.Withdraw(_depositor, _receiver, _shares, 0, 0);
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

    (uint256 _shares,,) = _deposit(_depositor, _amount0, _amount1);

    uint256 _sharesToWithdraw = (_shares * _withdrawPercent) / 100;
    uint256 _expectedRemainingShares = _shares - _sharesToWithdraw;

    uint256 _receiverToken0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(_receiver);
    uint256 _receiverToken1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(_receiver);

    vm.prank(_depositor);
    (uint256 _amount0Received, uint256 _amount1Received) =
      vault.withdraw(_sharesToWithdraw, _receiver);

    assertEq(vault.balanceOf(_depositor), _expectedRemainingShares);
    assertEq(vault.totalSupply(), _expectedRemainingShares);
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

    // Withdraw all.
    vm.prank(_depositor);
    (uint256 _amount0Received, uint256 _amount1Received) = vault.withdraw(_shares1, _receiver);

    // Verify all shares burned.
    assertEq(vault.balanceOf(_depositor), 0);
    assertEq(vault.totalSupply(), 0);

    // Verify amounts received match total deposited (within rounding tolerance).
    assertApproxEqAbs(_amount0Received, _amount0Used1, 2);
    assertApproxEqAbs(_amount1Received, _amount1Used1, 2);
  }

  function testFuzz_RevertIf_ZeroShares(address _depositor, address _receiver) public {
    _assumeSafeAddress(_depositor);
    vm.assume(_receiver != address(0));

    vm.prank(_depositor);
    vm.expectRevert(LPVault.LPVault__ZeroShares.selector);
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
}
