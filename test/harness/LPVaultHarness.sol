// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LPVault} from "src/LPVault.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

contract LPVaultHarness is LPVault {
  constructor(
    IPoolManager _poolManager,
    PoolKey memory _targetPoolKey,
    LiquidityPosition[] memory _positions,
    string memory _name,
    string memory _symbol
  ) LPVault(_poolManager, _targetPoolKey, _positions, _name, _symbol) {}

  function computeInitialLiquidity(uint256 _amount0Max, uint256 _amount1Max)
    external
    view
    returns (uint128[] memory _liquidityPerPosition, uint128 _liquidity0)
  {
    (_liquidityPerPosition, _liquidity0) = _calculateInitialLiquidity(_amount0Max, _amount1Max);
  }

  function getAmountsForLiquidity(
    int24 _tickLower,
    int24 _tickUpper,
    uint160 _sqrtPriceX96,
    uint128 _liquidity
  ) external pure returns (uint256 _amount0, uint256 _amount1) {
    LiquidityPosition memory _position = LiquidityPosition({
      tickLower: _tickLower, tickUpper: _tickUpper, weight: 0, liquidity: 0
    });
    return _getAmountsForLiquidity(_position, _sqrtPriceX96, _liquidity);
  }
}
