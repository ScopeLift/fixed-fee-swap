// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Mock FixedFeeSwapMarket for Zapper unit tests.
/// @dev Provides controllable swap behavior without requiring actual liquidity.
contract FixedFeeSwapMarketMock {
  using SafeERC20 for IERC20;

  IERC20 public immutable TOKEN0; // Principal token
  IERC20 public immutable TOKEN1; // Cash token (VST)

  /// @notice Mock price in WAD (1e18 = 1.0)
  int256 public mockPrice;

  /// @notice Mock swap output ratio (percentage of input returned as output, in basis points)
  /// @dev 10000 = 100% (1:1 swap for simplicity in unit tests)
  uint256 public swapOutputRatioBps = 10_000;

  constructor(address _token0, address _token1) {
    TOKEN0 = IERC20(_token0);
    TOKEN1 = IERC20(_token1);
    mockPrice = 0.98e18; // Default: 0.98 price
  }

  /// @notice Set the mock price returned by getCurrentPrice()
  function setMockPrice(int256 _price) external {
    mockPrice = _price;
  }

  /// @notice Set the swap output ratio in basis points
  /// @param _ratioBps Output ratio (e.g., 9800 = 98% of input)
  function setSwapOutputRatioBps(uint256 _ratioBps) external {
    swapOutputRatioBps = _ratioBps;
  }

  /// @notice Returns the mock current price
  function getCurrentPrice() external view returns (int256) {
    return mockPrice;
  }

  /// @notice Mock swap function that simulates trading
  /// @param _amountIn Amount of input tokens
  /// @param _principalForCash True = PT->cash, False = cash->PT
  /// @param _priceLimitWad Price limit (ignored in mock)
  /// @return amountInUsed Amount of input consumed (always full amount in mock)
  /// @return amountOut Amount of output tokens
  function swap(uint256 _amountIn, bool _principalForCash, int24 _priceLimitWad)
    external
    returns (uint256 amountInUsed, uint256 amountOut)
  {
    // Silence unused variable warning
    _priceLimitWad;

    amountInUsed = _amountIn;
    amountOut = (_amountIn * swapOutputRatioBps) / 10_000;

    if (_principalForCash) {
      // PT in -> Cash out
      TOKEN0.safeTransferFrom(msg.sender, address(this), amountInUsed);
      TOKEN1.safeTransfer(msg.sender, amountOut);
    } else {
      // Cash in -> PT out
      TOKEN1.safeTransferFrom(msg.sender, address(this), amountInUsed);
      TOKEN0.safeTransfer(msg.sender, amountOut);
    }
  }

  /// @notice Convert tick to price (simplified mock - just returns mockPrice)
  function tickToPrice(int24) external view returns (int256) {
    return mockPrice;
  }

  /// @notice Returns mock current tick (always 0 in mock)
  function currentTick() external pure returns (int24) {
    return 0;
  }
}
