// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Mock FixedFeeSwapMarket for Zapper unit tests.
/// @dev Provides controllable swap behavior without requiring actual liquidity.
///      Uses mockPrice for direction-dependent pricing:
///      - PT→Cash: output = input * price / WAD (PT is worth less than cash)
///      - Cash→PT: output = input * WAD / price (cash buys more PT since PT is discounted)
contract FixedFeeSwapMarketMock {
  using SafeERC20 for IERC20;

  IERC20 public immutable TOKEN0; // Principal token
  IERC20 public immutable TOKEN1; // Cash token (VST)

  /// @notice Mock price in WAD (1e18 = 1.0)
  int256 public mockPrice;

  constructor(address _token0, address _token1) {
    TOKEN0 = IERC20(_token0);
    TOKEN1 = IERC20(_token1);
    mockPrice = 0.98e18; // Default: 0.98 price
  }

  /// @notice Set the price the mock's swaps fill at
  function setMockPrice(int256 _price) external {
    mockPrice = _price;
  }

  /// @notice Mock swap function with direction-dependent pricing based on mockPrice
  /// @param _amountIn Amount of input tokens
  /// @param _principalForCash True = PT->cash, False = cash->PT
  /// @return amountInUsed Amount of input consumed (always full amount in mock)
  /// @return amountOut Amount of output tokens
  function swap(
    uint256 _amountIn,
    bool _principalForCash,
    int24 /* _tickLimit */
  )
    external
    returns (uint256 amountInUsed, uint256 amountOut)
  {
    amountInUsed = _amountIn;
    uint256 _price = uint256(mockPrice);

    if (_principalForCash) {
      // PT in -> Cash out: 1 PT = price cash (e.g., 0.98 VST)
      amountOut = (_amountIn * _price) / 1e18;
      TOKEN0.safeTransferFrom(msg.sender, address(this), amountInUsed);
      TOKEN1.safeTransfer(msg.sender, amountOut);
    } else {
      // Cash in -> PT out: 1 cash = 1/price PT (e.g., ~1.0204 PT)
      amountOut = (_amountIn * 1e18) / _price;
      TOKEN1.safeTransferFrom(msg.sender, address(this), amountInUsed);
      TOKEN0.safeTransfer(msg.sender, amountOut);
    }
  }
}
