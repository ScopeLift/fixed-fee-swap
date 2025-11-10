// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LimitOrderHook} from "@openzeppelin/uniswap-hooks/general/LimitOrderHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice A Hook to manage a fixed fee swap. A user can deposit liquidity
/// to a target pool outside of this hook conforming to a predefined set of
/// positions with a predefined amount of liquidity for each position. The
/// user receives a Principal (PT) and Yield (YT) token. These tokens can
/// be sold via limit orders in this hook while the market is active. Once
/// the market hits maturity deposits are disabled and new fees accumulate
/// to principal holders. Also, users can burn their PT and YT to receive
/// The principal and yield respectively.
contract FixedFeeSwapHook is LimitOrderHook {
  /// @notice The length from the start of the market to maturity.
  uint48 immutable MARKET_LENGTH;

  /// @notice The maximum the close fee can be set.
  uint256 immutable MAX_CLOSE_FEE;

  /// @notice The max fee a closer can request when closing the market.
  uint256 closeFee;

  /// @notice Indicating whether the morket is closed or not.
  bool closed = false;

  /// @notice The token0 in the target liquidity distribution pool
  address immutable TOKEN0;

  /// @notice The token1 in the target liquidity distribution pool
  address immutable TOKEN1;


  constructor(IPoolManager _poolManager) LimitOrderHook(_poolManager) {}

  /// @notice Deposit token0 and token1 to be distributed in a target
  /// v4 liquidity pool. This will mint pinciple tokens and yield tokens.
  /// A depositor can enter at any time. They must provide the number of
  /// tokens for a PT an YT at the time they enter. Fees are tracked as
  /// an accumulator for token1 and token0 over time. The nececssary
  /// principal is determined by the distribution of liquidity in the
  /// pool
  function depositLiquity() external {}

  /// @notice At maturity a person holding a Principal token can
  /// burn their principal token and claim the underlying liqudity
  /// tokens.
  function claimPrincipal() external {}

  /// @notice At maturity a person holding a Yield token can
  /// burn their token and claim the underlying liquidity.
  function claimYield() external {}

  /// @notice A function anyone can call after maturity. It
  /// does a final accounting of fees and pays a small fee
  /// to the caller from those fees. There is a lag from
  /// maturity to when final accounting is completed. After
  /// The market is closed no one can deposit new liquidity.
  /// If more fee accumulate they are given to principal holders
  /// after the close date.
  function close() external {}
}