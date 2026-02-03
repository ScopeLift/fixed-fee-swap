// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFixedFeeSwap} from "src/interface/IFixedFeeSwap.sol";

/// @notice Mock FixedFeeSwap for YieldToken unit tests: implements collectFeesToYT by
///         transferring token0 and token1 from this contract to the YieldToken.
contract FixedFeeSwapMock is IFixedFeeSwap {
  address public yieldToken;
  address public token0;
  address public token1;

  constructor(address _token0, address _token1) {
    token0 = _token0;
    token1 = _token1;
  }

  function setYieldToken(address _yt) external {
    yieldToken = _yt;
  }

  receive() external payable {}

  function collectFeesToYT() external override {
    if (yieldToken == address(0)) return;
    if (token0 == address(0)) {
      uint256 ethBal = address(this).balance;
      if (ethBal > 0) {
        (bool ok,) = payable(yieldToken).call{value: ethBal}("");
        require(ok, "ETH transfer failed");
      }
    } else {
      uint256 b0 = IERC20(token0).balanceOf(address(this));
      if (b0 > 0) IERC20(token0).transfer(yieldToken, b0);
    }
    uint256 b1 = IERC20(token1).balanceOf(address(this));
    if (b1 > 0) IERC20(token1).transfer(yieldToken, b1);
  }
}
