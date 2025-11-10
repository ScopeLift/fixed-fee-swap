// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LimitOrderHook} from "@openzeppelin/uniswap-hooks/general/LimitOrderHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PrincipalToken} from "./PrincipalToken.sol";
import {YieldToken} from "./YieldToken.sol";

/// @notice A Hook to manage a fixed fee swap. A user can deposit liquidity
/// to a target pool outside of this hook conforming to a predefined set of
/// positions with a predefined amount of liquidity for each position. The
/// user receives a Principal (PT) and Yield (YT) token. These tokens can
/// be sold via limit orders in this hook while the market is active. Once
/// the market hits maturity deposits are disabled and new fees accumulate
/// to principal holders. Also, users can burn their PT and YT to receive
/// The principal and yield respectively.
contract FixedFeeSwapHook is LimitOrderHook {
  /// @notice Structure for liquidity position configuration
  struct LiquidityPosition {
    int24 tickLower;
    int24 tickUpper;
    uint256 weight;
  }

  /// @notice The length from the start of the market to maturity.
  uint48 public immutable MARKET_LENGTH;

  /// @notice The maximum the close fee can be set.
  uint256 public immutable MAX_CLOSE_FEE;

  /// @notice The max fee a closer can request when closing the market.
  uint256 public closeFee;

  /// @notice Indicating whether the market is closed or not.
  bool public closed = false;

  /// @notice The token0 in the target liquidity distribution pool
  address public immutable TOKEN0;

  /// @notice The token1 in the target liquidity distribution pool
  address public immutable TOKEN1;

  /// @notice The target pool that this hook manages liquidity for
  PoolKey public targetPoolKey;

  /// @notice The predefined liquidity positions for this market
  LiquidityPosition[] public positions;

  /// @notice The principal token for this fixed fee swap
  PrincipalToken public principalToken;

  /// @notice The yield token for this fixed fee swap
  YieldToken public yieldToken;

  /// @notice Market timing
  uint256 public marketStartTime;
  uint256 public maturityTime;

  constructor(
    IPoolManager _poolManager,
    PoolKey memory _targetPoolKey,
    uint48 _marketLength,
    uint256 _maxCloseFee,
    LiquidityPosition[] memory _positions
  ) LimitOrderHook(_poolManager) {
    // Store target pool info
    targetPoolKey = _targetPoolKey;
    TOKEN0 = Currency.unwrap(_targetPoolKey.currency0);
    TOKEN1 = Currency.unwrap(_targetPoolKey.currency1);

    // Store market parameters
    MARKET_LENGTH = _marketLength;
    MAX_CLOSE_FEE = _maxCloseFee;
    closeFee = _maxCloseFee; // Initialize to max

    // Store liquidity positions
    for (uint256 i = 0; i < _positions.length; i++) {
      positions.push(_positions[i]);
    }

    // Set market timing
    marketStartTime = block.timestamp;
    maturityTime = marketStartTime + _marketLength;

    // Deploy PT and YT tokens
    // Create unique names based on the underlying tokens and maturity
    string memory ptName = string(abi.encodePacked("PT-", _getTokenSymbol(TOKEN0), "-", _getTokenSymbol(TOKEN1)));
    string memory ptSymbol = string(abi.encodePacked("PT", _toMaturityString(maturityTime)));

    string memory ytName = string(abi.encodePacked("YT-", _getTokenSymbol(TOKEN0), "-", _getTokenSymbol(TOKEN1)));
    string memory ytSymbol = string(abi.encodePacked("YT", _toMaturityString(maturityTime)));

    principalToken = new PrincipalToken(ptName, ptSymbol, address(this));
    yieldToken = new YieldToken(ytName, ytSymbol, address(this));
  }

  /// @notice Helper to get token symbol (simplified - in production would query token)
  function _getTokenSymbol(address) internal pure returns (string memory) {
    return "TKN"; // Simplified - would query actual symbol in production
  }

  /// @notice Helper to convert maturity to string (simplified)
  function _toMaturityString(uint256) internal pure returns (string memory) {
    return "2025"; // Simplified - would format actual date in production
  }

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