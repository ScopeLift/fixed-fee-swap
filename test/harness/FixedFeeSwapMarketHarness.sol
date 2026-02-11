// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FixedFeeSwapMarket, TickInfo, PositionInfo} from "src/FixedFeeSwapMarket.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

contract FixedFeeSwapMarketHarness is FixedFeeSwapMarket {
  constructor(
    uint48 _length,
    address _t0,
    address _t1,
    uint24 _feeRate,
    int24 _yieldPerTick,
    IPoolManager _mgr,
    int24 _initialTick
  ) FixedFeeSwapMarket(_length, _t0, _t1, _feeRate, _yieldPerTick, _mgr, _initialTick) {}

  /// @notice Skip hook address validation for testing
  function validateHookAddress(BaseHook) internal pure override {
    // No-op for testing - allows deploying to any address
  }

  function exposed_calculateSwap(
    int256 amountIn,
    int256 price,
    int24 nextTick,
    bool principalToCash
  ) external returns (uint256, uint256, int256, int24) {
    return _calculateSwap(amountIn, price, nextTick, principalToCash, NO_TICK_LIMIT);
  }

  function exposed_getCashSwapAmount(int256 amountIn, int256 price, int24 nextTick)
    external
    returns (uint256, uint256, int256, int24)
  {
    return _getCashSwapAmount(amountIn, price, nextTick, NO_TICK_LIMIT);
  }

  function exposed_getPrincipalSwapAmount(int256 amountIn, int256 price, int24 nextTick)
    external
    returns (uint256, uint256, int256, int24)
  {
    return _getPrincipalSwapAmount(amountIn, price, nextTick, NO_TICK_LIMIT);
  }

  function exposed_getAmountPrincipalDelta(int24 lowerYield, int24 upperYield, int128 liquidity)
    external
    returns (int256)
  {
    return _getAmountPrincipalDelta(lowerYield, upperYield, liquidity);
  }

  function exposed_getAmountCashDelta(int24 lowerYield, int24 upperYield, int128 liquidity)
    external
    returns (int256)
  {
    return _getAmountCashDelta(lowerYield, upperYield, liquidity);
  }

  function exposed_updateTickLiquidity(int24 tick, int128 liquidityDelta, bool upper)
    external
    returns (bool, uint128)
  {
    return _updateTickLiquidity(tick, liquidityDelta, upper);
  }

  /// @notice Exposes _beforeSwap for direct testing
  /// @dev The sender is the actual caller - in tests, use vm.prank to set the sender
  function exposed_beforeSwap(
    address sender,
    PoolKey calldata key,
    SwapParams calldata params,
    bytes calldata hookParams
  ) external returns (bytes4 selector, BeforeSwapDelta delta, uint24 fee) {
    return _beforeSwap(sender, key, params, hookParams);
  }

  function exposed_beforeAddLiquidity(
    address sender,
    PoolKey calldata key,
    ModifyLiquidityParams calldata params,
    bytes calldata hookData
  ) external returns (bytes4) {
    return _beforeAddLiquidity(sender, key, params, hookData);
  }

  function exposed_beforeRemoveLiquidity(
    address sender,
    PoolKey calldata key,
    ModifyLiquidityParams calldata params,
    bytes calldata hookData
  ) external returns (bytes4) {
    return _beforeRemoveLiquidity(sender, key, params, hookData);
  }

  // State getters
  function getActiveLiquidity() external view returns (uint128) {
    return activeLiquidity;
  }

  function getCurrentTick() external view returns (int24) {
    return currentTick;
  }

  function getCurrentPrice() external view returns (int256) {
    return currentPrice;
  }

  function getTickInfo(int24 tick)
    external
    view
    returns (uint128 liquidityGross, int128 liquidityNet)
  {
    TickInfo storage info = ticks[tick];
    return (info.liquidityGross, info.liquidityNet);
  }

  function getTickBitmapWord(int16 wordPos) external view returns (uint256) {
    return tickBitmap[wordPos];
  }

  function getMaturity() external view returns (uint48) {
    return MATURITY;
  }

  function getStartTime() external view returns (uint48) {
    return START_TIME;
  }

  function getToken0() external view returns (address) {
    return address(TOKEN0);
  }

  function getToken1() external view returns (address) {
    return address(TOKEN1);
  }

  function getPositionInfo(bytes32 positionId)
    external
    view
    returns (address owner, int24 tickLower, int24 tickUpper, int128 liquidity)
  {
    PositionInfo storage info = positions[positionId];
    return (info.owner, info.tickLower, info.tickUpper, info.liquidity);
  }
}
