// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FixedFeeSwap} from "src/FixedFeeSwap.sol";
import {PrincipalToken} from "src/PrincipalToken.sol";
import {VaultShareToken} from "src/VaultShareToken.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {FixedFeeSwapMarketHarness} from "test/harness/FixedFeeSwapMarketHarness.sol";
import {VaultShareTokenHarness} from "test/harness/VaultShareTokenHarness.sol";
import {ERC20Mock} from "test/mock/ERC20Mock.sol";

/// @notice Tests a FixedFeeSwapMarket whose cash token is the VaultShareToken, as the Zapper wires
/// it, so the market's cash earns vault fees.
abstract contract FixedFeeSwapMarketVaultShareYieldTest is Test {
  FixedFeeSwap internal fixedFeeSwap;
  FixedFeeSwapMarketHarness internal market;
  VaultShareTokenHarness internal vaultShareToken;
  PrincipalToken internal principalToken;
  ERC20Mock internal feeToken0;
  ERC20Mock internal feeToken1;

  uint48 internal constant MARKET_LENGTH = 365 days;
  // The position spans ticks 0 to 1000 around the initial tick, so it holds both PT and cash.
  int24 internal constant TICK_LOWER = 0;
  int24 internal constant TICK_UPPER = 1000;
  int24 internal constant INITIAL_TICK = 500;
  // Liquidity that the LP's 1,000 PT and 1,000 VST can fund across that range.
  uint128 internal constant LIQUIDITY = 1e21;
  uint256 internal constant LP_VAULT_SHARES = 2000e18;
  uint256 internal constant LP_SPLIT_AMOUNT = 1000e18;

  address internal liquidityProvider = makeAddr("liquidityProvider");
  address internal anyone = makeAddr("anyone");

  function setUp() public virtual {
    feeToken0 = new ERC20Mock("Fee Token 0", "FT0");
    feeToken1 = new ERC20Mock("Fee Token 1", "FT1");
    vaultShareToken = new VaultShareTokenHarness(
      "Vault Share Token", "VST", address(feeToken0), address(feeToken1)
    );
    fixedFeeSwap =
      new FixedFeeSwap(VaultShareToken(address(vaultShareToken)), block.timestamp + MARKET_LENGTH);
    principalToken = fixedFeeSwap.PRINCIPAL_TOKEN();
    // Fee rate and pool manager don't matter here: nothing swaps, and liquidity is managed
    // directly on the market.
    market = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH,
      address(principalToken),
      address(vaultShareToken),
      0,
      1,
      IPoolManager(makeAddr("poolManager")),
      INITIAL_TICK
    );
    // Moves past the market's start time so minting liquidity has a nonzero elapsed time.
    vm.warp(block.timestamp + 1);
  }

  // Gives the LP vault shares, splits half into PT, and mints `LIQUIDITY` across the test range,
  // so the market holds part of the LP's VST as cash. Returns the position ID.
  function _mintLiquidityWithVaultShareCash() internal returns (bytes32) {
    vaultShareToken.exposed_mint(liquidityProvider, LP_VAULT_SHARES);
    vm.startPrank(liquidityProvider);
    vaultShareToken.approve(address(fixedFeeSwap), LP_SPLIT_AMOUNT);
    fixedFeeSwap.deposit(LP_SPLIT_AMOUNT);
    principalToken.approve(address(market), type(uint256).max);
    vaultShareToken.approve(address(market), type(uint256).max);
    market.mintLiquidity(TICK_LOWER, TICK_UPPER, LIQUIDITY, type(uint256).max, type(uint256).max);
    vm.stopPrank();
    return keccak256(abi.encodePacked(TICK_UPPER, TICK_LOWER, liquidityProvider));
  }

  // Credits `_amount` of fee token 0 to every vault share holder, as LPVault does when it
  // collects pool fees.
  function _accrueVaultFees(uint256 _amount) internal {
    feeToken0.mint(address(vaultShareToken), _amount);
    vaultShareToken.exposed_updateFees(_amount, 0);
  }
}

contract VaultShareYield is FixedFeeSwapMarketVaultShareYieldTest {
  function testFuzz_LeavesNoVaultShareYieldInTheMarketAfterTheLastLiquidityProviderExits(uint256 _vaultFees)
    public
  {
    // At least 1e18 so the market's pro rata share of the fees doesn't round to zero.
    _vaultFees = bound(_vaultFees, 1e18, 1e30);
    bytes32 _positionId = _mintLiquidityWithVaultShareCash();
    _accrueVaultFees(_vaultFees);

    // Anyone can push the market's share of the vault fees into the market.
    vm.prank(anyone);
    vaultShareToken.claim(address(market));

    vm.startPrank(liquidityProvider);
    market.decreaseLiquidity(_positionId, -int128(LIQUIDITY), 0, 0);
    market.collectFees(_positionId, liquidityProvider, 0, 0);
    vm.stopPrank();

    assertEq(feeToken0.balanceOf(address(market)), 0, "vault fee yield stranded in the market");
  }
}
