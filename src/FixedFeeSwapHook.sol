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
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
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
  using Strings for uint256;
  /// @notice Structure for liquidity position configuration
  struct LiquidityPosition {
    int24 tickLower;
    int24 tickUpper;
    uint256 weight;
  }

  /// @notice The length from the start of the market to maturity.
  uint48 public immutable MARKET_LENGTH;

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

  uint256 public totalPositionWeight;

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
    LiquidityPosition[] memory _positions
  ) LimitOrderHook(_poolManager) {
    // Store target pool info
    targetPoolKey = _targetPoolKey;
    TOKEN0 = Currency.unwrap(_targetPoolKey.currency0);
    TOKEN1 = Currency.unwrap(_targetPoolKey.currency1);

    // Store market parameters
    MARKET_LENGTH = _marketLength;

    // Store liquidity positions
    for (uint256 i = 0; i < _positions.length; i++) {
      positions.push(_positions[i]);
	  totalPositionWeight += _positions[i].weight;
    }

    // Set market timing
    marketStartTime = block.timestamp;
    maturityTime = marketStartTime + _marketLength;

    // Deploy PT and YT tokens
    // Create unique names based on the underlying tokens and maturity
    string memory ptName = string(abi.encodePacked("PT-", _getTokenSymbol(TOKEN0), "-", _getTokenSymbol(TOKEN1)));
    string memory ptSymbol = string(abi.encodePacked("PT", _toString(maturityTime), _toString(MARKET_LENGTH)));

    string memory ytName = string(abi.encodePacked("YT-", _getTokenSymbol(TOKEN0), "-", _getTokenSymbol(TOKEN1)));
    string memory ytSymbol = string(abi.encodePacked("YT", _toString(maturityTime), _toString(MARKET_LENGTH)));

    principalToken = new PrincipalToken(ptName, ptSymbol, address(this));
    yieldToken = new YieldToken(ytName, ytSymbol, address(this));
  }

  /// @notice Helper to get token symbol.
  function _getTokenSymbol(address _token) internal view returns (string memory) {
    return ERC20(_token).symbol(); 
  }

  /// @notice Helper to convert maturity to string 
  function _toString(uint256 _value) internal pure returns (string memory) {
    return _value.toString();  
  }

  /// @notice Internal function to ensure market is closed after maturity
  function _closeMatureMarket() internal {
    if (block.timestamp >= maturityTime && !closed) {
      _closeMarket();
    }
  }

  /// @notice Internal function to collect fees from all positions
  /// @return fees0 Total fees collected in token0
  /// @return fees1 Total fees collected in token1
  function _collectFeesFromPositions() internal returns (uint256 fees0, uint256 fees1) {
    fees0 = 0;
    fees1 = 0;

    // Collect fees from each position by calling modifyLiquidity with 0 delta
    for (uint256 i = 0; i < positions.length; i++) {
      LiquidityPosition memory pos = positions[i];
      bytes32 positionKey = keccak256(abi.encodePacked(address(this), pos.tickLower, pos.tickUpper));

      uint128 posLiquidity = positionLiquidity[positionKey];
      if (posLiquidity > 0) {
        // Call modifyLiquidity with 0 liquidity delta to collect fees
        // This returns a BalanceDelta with the fees collected
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
          tickLower: pos.tickLower,
          tickUpper: pos.tickUpper,
          liquidityDelta: 0,  // 0 delta just collects fees
          salt: bytes32(0)
        });

        (,BalanceDelta _fees) = poolManager.modifyLiquidity(targetPoolKey, params, "");
        fees0 += uint256(uint128(_fees.amount0()));  // Positive amount = fees collected
        fees1 += uint256(uint128(_fees.amount1()));
      }
    }

    // Update our internal fee accumulator
    if (fees0 > 0 || fees1 > 0) {
      feeGrowthGlobal0 += fees0;
      feeGrowthGlobal1 += fees1;
    }
  }

  /// @notice Internal function to close the market
  function _closeMarket() internal {
    if (closed) return; // Already closed

    // Collect all outstanding fees from positions
    _collectFeesFromPositions();

    // Snapshot the fee growth at close time
    // These snapshots are used to calculate yield for YT holders
    closeFeeGrowth0 = feeGrowthGlobal0;
    closeFeeGrowth1 = feeGrowthGlobal1;

    // Mark market as closed
    closed = true;
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
	// If a market isn't active it is also closed.
    if (block.timestamp >= maturityTime) revert MarketNotActive();
    if (amount0Max == 0 || amount1Max == 0) revert InvalidAmount();

    // Collect fees from existing positions before deposit
    // This ensures proper fee accounting for yield tokens
    _collectFeesFromPositions();

    // Transfer max tokens from user (will refund unused later)
    IERC20(TOKEN0).transferFrom(msg.sender, address(this), amount0Max);
    IERC20(TOKEN1).transferFrom(msg.sender, address(this), amount1Max);

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
      uint256 posAmount0Max = (amount0Max * positions[i].weight) / totalPositionWeight;
      uint256 posAmount1Max = (amount1Max * positions[i].weight) / totalPositionWeight;

      // Add liquidity to this position
	  // TODO: Double check this. Does one liquidity at any given price also equate to the
	  // amount of shares that should be minted.
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

    // Ensure market is closed if mature
    _closeMatureMarket();
	// Collect any remaining fees
    _collectFeesFromPositions();

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
    // Ensure market is closed if mature
    _closeMatureMarket();

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

  /// @notice A function anyone can call after maturity to close the market.
  /// This performs final fee accounting. After the market is closed,
  /// no new liquidity can be deposited. Any fees that accumulate after
  /// closing are given to principal holders.
  function close() external {
    // Check market is mature
    if (block.timestamp < maturityTime) revert MarketNotMature();

    // Check market not already closed
    if (closed) revert MarketAlreadyClosed();

    // Close the market
    _closeMarket();
  }
}
