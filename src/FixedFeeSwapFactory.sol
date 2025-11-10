// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/// @notice A factory for creating fixed fee swaps for a specific liquidity
/// distribution. Fixed Fee swaps can be created in the future, but they should
/// not aceept liquidity until they take a snapshot of the fees.
contract FixedFeeSwapFactory {

  /// @notice Create a Fixed fee swap for a given maturity length.
  /// On creation the current fee accumulator for the static positions
  /// will be snapshotted, and if the epoch has passed a new YT token
  /// will be deployed There is always 1 PT for YT token. There must be
  /// a mechanism for existing PT holders to roll their tokens into the
  /// next YT. If we had a two pool design at maturity and after PT
  /// holders can remove the principle and fees and move to the next
  /// fixed fee swap pool. This is another way of illustrating that
  /// an old PT token is equivelent to the current PT and YT token combinded.
  /// Maybe we allow for PT and YT tokens to be split? But then you run into
  /// the issue where it becomes more difficult to track the growth in fees
  /// from the last snapshot. Maybe we have two distrbutions old and new.
  /// To move from old to new will require an action by the old PT holder.
  /// Actually since we have new tokens, for both PT and YT a new FFS pool
  /// should be created on the factory.
  function createFixedFeeSwap() external {
		  // Game plan, create pool with FixedFeeHook, starting price should
		  // track historic yield per day.

		  // 1. Make Uniswap v4 pool


  }
}
