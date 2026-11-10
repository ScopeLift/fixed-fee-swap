// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFixedFeeSwap} from "src/interface/IFixedFeeSwap.sol";
import {YieldToken} from "src/YieldToken.sol";

/// @notice Mock FixedFeeSwap for YieldToken unit tests: implements collectFeesToYT and
///         transferFeesToUser for the pull model where YieldToken requests fee transfers.
contract FixedFeeSwapMock is IFixedFeeSwap {
  address public yieldToken;
  address public token0;
  address public token1;
  uint256 public pendingFee0;
  uint256 public pendingFee1;

  constructor(address _token0, address _token1) {
    token0 = _token0;
    token1 = _token1;
  }

  function setYieldToken(address _yt) external {
    yieldToken = _yt;
  }

  /// @notice Sets fees the next `syncFees` credits to the YieldToken, standing in for vault fees
  ///         FixedFeeSwap hasn't synced yet.
  function setPendingFees(uint256 _fee0, uint256 _fee1) external {
    pendingFee0 = _fee0;
    pendingFee1 = _fee1;
  }

  /// @notice Called by YieldToken before a transfer. Credits any pending fees to the YieldToken
  ///         once, as FixedFeeSwap would.
  function syncFees() external override {
    (uint256 _fee0, uint256 _fee1) = (pendingFee0, pendingFee1);
    if (_fee0 == 0 && _fee1 == 0) return;
    pendingFee0 = 0;
    pendingFee1 = 0;
    YieldToken(yieldToken).updateFees(_fee0, _fee1);
  }

  /// @notice Called by YieldToken to sync fee accounting. No-op in mock since
  ///         we don't simulate the full VST fee accounting.
  function collectFeesToYT() external override {}

  /// @notice Transfers fee tokens directly from this mock to the user.
  /// @param _user The address to transfer fees to.
  /// @param _amount0 Amount of token0 to transfer.
  /// @param _amount1 Amount of token1 to transfer.
  function transferFeesToUser(address _user, uint256 _amount0, uint256 _amount1) external override {
    if (_amount0 > 0) {
      if (token0 == address(0)) {
        (bool ok,) = payable(_user).call{value: _amount0}("");
        require(ok, "ETH transfer failed");
      } else {
        IERC20(token0).transfer(_user, _amount0);
      }
    }
    if (_amount1 > 0) IERC20(token1).transfer(_user, _amount1);
  }

  receive() external payable {}
}
