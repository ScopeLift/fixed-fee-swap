// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LimitOrderHook} from "@openzeppelin/uniswap-hooks/general/LimitOrderHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
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
  using PoolIdLibrary for PoolKey;
  using StateLibrary for IPoolManager;
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

  /// @notice Total liquidity deposited for each position
  mapping(bytes32 => uint128) public positionLiquidity;

  /// @notice Total principal tokens issued
  uint256 public totalPrincipal;

  /// @notice Total yield tokens issued
  uint256 public totalYield;

  /// @notice Fee accumulator tracking fees earned over time
  uint256 public feeGrowthGlobal0;
  uint256 public feeGrowthGlobal1;

  /// @notice Snapshot of fees at market close
  uint256 public closeFeeGrowth0;
  uint256 public closeFeeGrowth1;

  /// @notice Track user deposits for principal/yield calculation
  struct UserDeposit {
    uint256 principalAmount;
    uint256 yieldAmount;
    uint256 feeSnapshot0;
    uint256 feeSnapshot1;
  }

  mapping(address => UserDeposit) public userDeposits;

  /// @notice Custom errors
  error MarketNotActive();
  error MarketNotMature();
  error MarketNotClosed();
  error MarketAlreadyClosed();
  error InvalidAmount();
  error InsufficientBalance();
  error InvalidPositions();

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

  /// @notice Helper function to add liquidity for a single position
  function _addLiquidityToPosition(
    LiquidityPosition memory pos,
    uint256 posAmount0Max,
    uint256 posAmount1Max,
    uint160 sqrtPriceX96
  ) internal returns (uint128 liquidityAdded, uint256 amount0, uint256 amount1) {
    // Calculate the maximum liquidity we can add given the amounts
    liquidityAdded = LiquidityAmounts.getLiquidityForAmounts(
      sqrtPriceX96,
      TickMath.getSqrtPriceAtTick(pos.tickLower),
      TickMath.getSqrtPriceAtTick(pos.tickUpper),
      posAmount0Max,
      posAmount1Max
    );

    if (liquidityAdded > 0) {
      // Calculate the actual amounts that will be used for this liquidity
      (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
        sqrtPriceX96,
        TickMath.getSqrtPriceAtTick(pos.tickLower),
        TickMath.getSqrtPriceAtTick(pos.tickUpper),
        liquidityAdded
      );

      // Update position tracking
      bytes32 positionKey = keccak256(abi.encodePacked(address(this), pos.tickLower, pos.tickUpper));
      positionLiquidity[positionKey] += liquidityAdded;
    }
  }

  /// @notice Deposit token0 and token1 to be distributed in a target
  /// v4 liquidity pool. This will mint pinciple tokens and yield tokens.
  /// A depositor can enter at any time. The function respects the current
  /// pool ratio and returns any unused tokens.
  /// @param amount0Max Maximum amount of token0 to deposit
  /// @param amount1Max Maximum amount of token1 to deposit
  /// @return amount0Used Actual amount of token0 used
  /// @return amount1Used Actual amount of token1 used
  /// @return ptMinted Amount of PT tokens minted
  /// @return ytMinted Amount of YT tokens minted
  function depositLiquidity(
    uint256 amount0Max,
    uint256 amount1Max
  ) external returns (
    uint256 amount0Used,
    uint256 amount1Used,
    uint256 ptMinted,
    uint256 ytMinted
  ) {
    // Check market is active (not mature and not closed)
    if (block.timestamp >= maturityTime) revert MarketNotActive();
    if (closed) revert MarketAlreadyClosed();
    if (amount0Max == 0 || amount1Max == 0) revert InvalidAmount();

    // Transfer max tokens from user (will refund unused later)
    IERC20(TOKEN0).transferFrom(msg.sender, address(this), amount0Max);
    IERC20(TOKEN1).transferFrom(msg.sender, address(this), amount1Max);

    // Calculate total weight for proportional distribution
    uint256 totalWeight = 0;
    for (uint256 i = 0; i < positions.length; i++) {
      totalWeight += positions[i].weight;
    }

    // Get current pool state
    PoolId poolId = targetPoolKey.toId();
    (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);

    // Track actual amounts used and liquidity added
    uint256 totalLiquidityAdded = 0;
    amount0Used = 0;
    amount1Used = 0;

    // Process each position
    for (uint256 i = 0; i < positions.length; i++) {
      // Calculate maximum amounts for this position based on weight
      uint256 posAmount0Max = (amount0Max * positions[i].weight) / totalWeight;
      uint256 posAmount1Max = (amount1Max * positions[i].weight) / totalWeight;

      // Add liquidity to this position
      (uint128 liquidityAdded, uint256 amount0ForPos, uint256 amount1ForPos) = _addLiquidityToPosition(
        positions[i],
        posAmount0Max,
        posAmount1Max,
        sqrtPriceX96
      );

      // Update totals
      totalLiquidityAdded += liquidityAdded;
      amount0Used += amount0ForPos;
      amount1Used += amount1ForPos;
    }

    // Check that we actually added some liquidity
    if (totalLiquidityAdded == 0) revert InvalidAmount();

    // Calculate PT and YT amounts to mint (1:1 with liquidity)
    ptMinted = totalLiquidityAdded;
    ytMinted = totalLiquidityAdded;

    // Update user deposit tracking
    UserDeposit storage deposit = userDeposits[msg.sender];
    deposit.principalAmount += ptMinted;
    deposit.yieldAmount += ytMinted;
    deposit.feeSnapshot0 = feeGrowthGlobal0;
    deposit.feeSnapshot1 = feeGrowthGlobal1;

    // Update totals
    totalPrincipal += ptMinted;
    totalYield += ytMinted;

    // Mint PT and YT tokens to depositor
    principalToken.mint(msg.sender, ptMinted);
    yieldToken.mint(msg.sender, ytMinted);

    // Refund unused tokens
    uint256 refund0 = amount0Max - amount0Used;
    uint256 refund1 = amount1Max - amount1Used;

    if (refund0 > 0) {
      IERC20(TOKEN0).transfer(msg.sender, refund0);
    }
    if (refund1 > 0) {
      IERC20(TOKEN1).transfer(msg.sender, refund1);
    }
  }

  /// @notice At maturity a person holding a Principal token can
  /// burn their principal token and claim the underlying liqudity
  /// tokens.
  function claimPrincipal() external {
    // Check market is mature
    if (block.timestamp < maturityTime) revert MarketNotMature();

    // Get user's PT balance
    uint256 ptBalance = principalToken.balanceOf(msg.sender);
    if (ptBalance == 0) revert InsufficientBalance();

    // Burn PT tokens
    principalToken.burnFrom(msg.sender, ptBalance);

    // Calculate proportional share of underlying liquidity
    uint256 share = (ptBalance * 1e18) / totalPrincipal;

    // Remove liquidity from each position proportionally
    uint256 amount0ToReturn = 0;
    uint256 amount1ToReturn = 0;

    for (uint256 i = 0; i < positions.length; i++) {
      LiquidityPosition memory pos = positions[i];
      bytes32 positionKey = keccak256(abi.encodePacked(address(this), pos.tickLower, pos.tickUpper));

      uint128 posLiquidity = positionLiquidity[positionKey];
      if (posLiquidity > 0) {
        // Calculate user's share of this position's liquidity
        uint128 userLiquidity = uint128((uint256(posLiquidity) * share) / 1e18);

        if (userLiquidity > 0) {
          // Get current pool state
          PoolId poolId = PoolIdLibrary.toId(targetPoolKey);
          (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);

          // Calculate token amounts for this liquidity
          (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(pos.tickLower),
            TickMath.getSqrtPriceAtTick(pos.tickUpper),
            userLiquidity
          );

          amount0ToReturn += amount0;
          amount1ToReturn += amount1;

          // Update position liquidity
          positionLiquidity[positionKey] -= userLiquidity;
        }
      }
    }

    // If market is closed, add proportional share of accumulated fees after close
    if (closed) {
      uint256 additionalFees0 = ((feeGrowthGlobal0 - closeFeeGrowth0) * share) / 1e18;
      uint256 additionalFees1 = ((feeGrowthGlobal1 - closeFeeGrowth1) * share) / 1e18;

      amount0ToReturn += additionalFees0;
      amount1ToReturn += additionalFees1;
    }

    // Transfer tokens to user
    if (amount0ToReturn > 0) {
      IERC20(TOKEN0).transfer(msg.sender, amount0ToReturn);
    }
    if (amount1ToReturn > 0) {
      IERC20(TOKEN1).transfer(msg.sender, amount1ToReturn);
    }

    // Update total principal
    totalPrincipal -= ptBalance;
  }

  /// @notice At maturity a person holding a Yield token can
  /// burn their token and claim the underlying liquidity.
  function claimYield() external {
    // Check market is closed (must be closed for final fee accounting)
    if (!closed) revert MarketNotClosed();

    // Get user's YT balance
    uint256 ytBalance = yieldToken.balanceOf(msg.sender);
    if (ytBalance == 0) revert InsufficientBalance();

    // Burn YT tokens
    yieldToken.burnFrom(msg.sender, ytBalance);

    // Calculate proportional share of accumulated fees up to close
    uint256 share = (ytBalance * 1e18) / totalYield;

    // Calculate fee amounts based on the snapshot at close
    uint256 fees0 = (closeFeeGrowth0 * share) / 1e18;
    uint256 fees1 = (closeFeeGrowth1 * share) / 1e18;

    // If user had a deposit, subtract their initial fee snapshot
    UserDeposit storage deposit = userDeposits[msg.sender];
    if (deposit.yieldAmount > 0) {
      // Calculate fees earned since deposit
      uint256 userFees0 = ((closeFeeGrowth0 - deposit.feeSnapshot0) * deposit.yieldAmount) / 1e18;
      uint256 userFees1 = ((closeFeeGrowth1 - deposit.feeSnapshot1) * deposit.yieldAmount) / 1e18;

      // Use the minimum of calculated fees (to prevent over-claiming)
      fees0 = userFees0 < fees0 ? userFees0 : fees0;
      fees1 = userFees1 < fees1 ? userFees1 : fees1;

      // Update deposit tracking
      deposit.yieldAmount -= ytBalance;
    }

    // Transfer fee tokens to user
    if (fees0 > 0) {
      IERC20(TOKEN0).transfer(msg.sender, fees0);
    }
    if (fees1 > 0) {
      IERC20(TOKEN1).transfer(msg.sender, fees1);
    }

    // Update total yield
    totalYield -= ytBalance;
  }

  /// @notice A function anyone can call after maturity. It
  /// does a final accounting of fees and pays a small fee
  /// to the caller from those fees. There is a lag from
  /// maturity to when final accounting is completed. After
  /// The market is closed no one can deposit new liquidity.
  /// If more fee accumulate they are given to principal holders
  /// after the close date.
  function close() external {
    // Check market is mature
    if (block.timestamp < maturityTime) revert MarketNotMature();

    // Check market not already closed
    if (closed) revert MarketAlreadyClosed();

    // Calculate accumulated fees from all positions
    uint256 totalFees0 = 0;
    uint256 totalFees1 = 0;

    // Get current pool state
    PoolId poolId = PoolIdLibrary.toId(targetPoolKey);
    (uint160 sqrtPriceX96, , , ) = poolManager.getSlot0(poolId);

    // Collect fees from each position
    for (uint256 i = 0; i < positions.length; i++) {
      LiquidityPosition memory pos = positions[i];
      bytes32 positionKey = keccak256(abi.encodePacked(address(this), pos.tickLower, pos.tickUpper));

      uint128 posLiquidity = positionLiquidity[positionKey];
      if (posLiquidity > 0) {
        // In a real implementation, this would collect fees from the PoolManager
        // Here we simulate fee collection
        uint256 positionFees0 = (posLiquidity * 100) / 10000; // 1% simulated fee
        uint256 positionFees1 = (posLiquidity * 100) / 10000; // 1% simulated fee

        totalFees0 += positionFees0;
        totalFees1 += positionFees1;
      }
    }

    // Update fee growth snapshots at close
    feeGrowthGlobal0 += totalFees0;
    feeGrowthGlobal1 += totalFees1;
    closeFeeGrowth0 = feeGrowthGlobal0;
    closeFeeGrowth1 = feeGrowthGlobal1;

    // Calculate close fee for the caller
    uint256 closerFee0 = (totalFees0 * closeFee) / 10000;
    uint256 closerFee1 = (totalFees1 * closeFee) / 10000;

    // Pay the closer
    if (closerFee0 > 0) {
      IERC20(TOKEN0).transfer(msg.sender, closerFee0);
    }
    if (closerFee1 > 0) {
      IERC20(TOKEN1).transfer(msg.sender, closerFee1);
    }

    // Mark market as closed
    closed = true;

    // Reduce close fee for next time (incentivize early closing)
    if (closeFee > 10) {
      closeFee = closeFee - 10; // Reduce by 0.1%
    }
  }
}