// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedFeeSwapMarket} from "src/FixedFeeSwapMarket.sol";
import {FixedFeeSwap} from "src/FixedFeeSwap.sol";
import {PrincipalToken} from "src/PrincipalToken.sol";
import {VaultShareToken} from "src/VaultShareToken.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {FixedFeeSwapMarketHarness} from "test/harness/FixedFeeSwapMarketHarness.sol";
import {VaultShareTokenHarness} from "test/harness/VaultShareTokenHarness.sol";
import {ERC20Mock} from "test/mock/ERC20Mock.sol";
import {NonPayableContractMock} from "test/mock/NonPayableContractMock.sol";

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
  address internal vaultYieldRecipient = makeAddr("vaultYieldRecipient");

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
      INITIAL_TICK,
      vaultYieldRecipient
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
    _accrueVaultFees(_amount, 0);
  }

  // Credits `_amount0` and `_amount1` of fee tokens 0 and 1 to every vault share holder.
  function _accrueVaultFees(uint256 _amount0, uint256 _amount1) internal {
    feeToken0.mint(address(vaultShareToken), _amount0);
    feeToken1.mint(address(vaultShareToken), _amount1);
    vaultShareToken.exposed_updateFees(_amount0, _amount1);
  }

  // The fees `_shares` vault shares earn when `_fees` are spread over every share, rounded down
  // as the vault rounds them.
  function _vaultFeesEarnedBy(uint256 _shares, uint256 _fees) internal view returns (uint256) {
    return Math.mulDiv(_shares, Math.mulDiv(_fees, 1e18, vaultShareToken.totalSupply()), 1e18);
  }
}

contract ForwardVaultYield is FixedFeeSwapMarketVaultShareYieldTest {
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

    vm.prank(anyone);
    market.forwardVaultYield();

    assertEq(feeToken0.balanceOf(address(market)), 0, "vault fee yield stranded in the market");
    assertGt(feeToken0.balanceOf(vaultYieldRecipient), 0);
  }

  function testFuzz_SendsTheMarketsShareOfVaultFeesToTheRecipient(
    uint256 _vaultFees0,
    uint256 _vaultFees1
  ) public {
    _vaultFees0 = bound(_vaultFees0, 1e18, 1e30);
    _vaultFees1 = bound(_vaultFees1, 1e18, 1e30);
    _mintLiquidityWithVaultShareCash();
    uint256 _marketShares = vaultShareToken.balanceOf(address(market));
    _accrueVaultFees(_vaultFees0, _vaultFees1);

    vm.prank(anyone);
    (uint256 _forwarded0, uint256 _forwarded1) = market.forwardVaultYield();

    assertEq(_forwarded0, _vaultFeesEarnedBy(_marketShares, _vaultFees0));
    assertEq(_forwarded1, _vaultFeesEarnedBy(_marketShares, _vaultFees1));
    assertEq(feeToken0.balanceOf(vaultYieldRecipient), _forwarded0);
    assertEq(feeToken1.balanceOf(vaultYieldRecipient), _forwarded1);
  }

  function testFuzz_LeavesTheMarketsPrincipalAndCashUntouched(uint256 _vaultFees) public {
    _vaultFees = bound(_vaultFees, 1e18, 1e30);
    _mintLiquidityWithVaultShareCash();
    _accrueVaultFees(_vaultFees);
    uint256 _principalBefore = principalToken.balanceOf(address(market));
    uint256 _cashBefore = vaultShareToken.balanceOf(address(market));

    market.forwardVaultYield();

    assertEq(principalToken.balanceOf(address(market)), _principalBefore);
    assertEq(vaultShareToken.balanceOf(address(market)), _cashBefore);
  }

  function testFuzz_EmitsVaultYieldForwarded(uint256 _vaultFees) public {
    _vaultFees = bound(_vaultFees, 1e18, 1e30);
    _mintLiquidityWithVaultShareCash();
    uint256 _marketShares = vaultShareToken.balanceOf(address(market));
    _accrueVaultFees(_vaultFees);

    vm.expectEmit();
    emit FixedFeeSwapMarket.VaultYieldForwarded(
      vaultYieldRecipient, _vaultFeesEarnedBy(_marketShares, _vaultFees), 0
    );
    market.forwardVaultYield();
  }

  function test_RevertIf_AFeeTokenIsOneOfTheMarketsTokens() public {
    // A cash token whose fee token0 is the market's own principal token, so forwarding fees would
    // send reserves.
    VaultShareTokenHarness _cash =
      new VaultShareTokenHarness("Cash", "CASH", address(feeToken0), address(feeToken1));
    FixedFeeSwapMarketHarness _market = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH,
      address(feeToken0),
      address(_cash),
      0,
      1,
      IPoolManager(makeAddr("poolManager")),
      INITIAL_TICK,
      vaultYieldRecipient
    );

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_FeeTokenIsAMarketToken.selector);
    _market.forwardVaultYield();
  }
}

contract ForwardVaultYieldInNativeEth is Test {
  // Deploys a cash token whose token0 fees are native ETH and token1 fees are `_feeToken1`, and a
  // market over it that forwards to `_recipient`. Mints `_shares` of the cash to the market, so
  // the market is the only holder and earns every fee, then credits `_feeEth` and `_fee1` of fees.
  function _deployMarketEarningNativeEth(
    address _recipient,
    ERC20Mock _feeToken1,
    uint256 _shares,
    uint256 _feeEth,
    uint256 _fee1
  ) internal returns (FixedFeeSwapMarketHarness _market) {
    VaultShareTokenHarness _cash =
      new VaultShareTokenHarness("Cash", "CASH", address(0), address(_feeToken1));
    _market = new FixedFeeSwapMarketHarness(
      365 days,
      address(new ERC20Mock("Principal", "PT")),
      address(_cash),
      0,
      1,
      IPoolManager(makeAddr("poolManager")),
      500,
      _recipient
    );
    _cash.exposed_mint(address(_market), _shares);
    vm.deal(address(_cash), _feeEth);
    _feeToken1.mint(address(_cash), _fee1);
    _cash.exposed_updateFees(_feeEth, _fee1);
  }

  function testFuzz_SendsNativeEthVaultFeesToTheRecipient(uint256 _shares, uint256 _vaultFees)
    public
  {
    _shares = bound(_shares, 1, 1e30);
    // At least 1e18 per share so the market's fees don't round to zero.
    _vaultFees = bound(_vaultFees, 1e18, 1e30);
    address _recipient = makeAddr("vaultYieldRecipient");
    FixedFeeSwapMarketHarness _market =
      _deployMarketEarningNativeEth(_recipient, new ERC20Mock("T1", "T1"), _shares, _vaultFees, 0);

    _market.forwardVaultYield();

    assertEq(_recipient.balance, Math.mulDiv(_shares, Math.mulDiv(_vaultFees, 1e18, _shares), 1e18));
    assertEq(address(_market).balance, 0);
  }

  function testFuzz_SendsTheOtherFeeTokenWhenTheRecipientRejectsNativeEth(
    uint256 _shares,
    uint256 _vaultFeesEth,
    uint256 _vaultFees1
  ) public {
    _shares = bound(_shares, 1, 1e30);
    _vaultFeesEth = bound(_vaultFeesEth, 1e18, 1e30);
    _vaultFees1 = bound(_vaultFees1, 1e18, 1e30);
    address _recipient = address(new NonPayableContractMock());
    ERC20Mock _feeToken1 = new ERC20Mock("T1", "T1");
    FixedFeeSwapMarketHarness _market =
      _deployMarketEarningNativeEth(_recipient, _feeToken1, _shares, _vaultFeesEth, _vaultFees1);

    (uint256 _forwardedEth, uint256 _forwarded1) = _market.forwardVaultYield();

    assertEq(_forwardedEth, 0);
    assertGt(address(_market).balance, 0);
    assertGt(_forwarded1, 0);
    assertEq(_feeToken1.balanceOf(_recipient), _forwarded1);
  }

  function testFuzz_RevertIf_NativeEthComesFromAnyoneButTheCashToken(
    address _sender,
    uint256 _amount
  ) public {
    FixedFeeSwapMarketHarness _market = _deployMarketEarningNativeEth(
      makeAddr("vaultYieldRecipient"), new ERC20Mock("T1", "T1"), 1, 0, 0
    );
    VaultShareTokenHarness _cash = VaultShareTokenHarness(_market.getToken1());
    vm.assume(_sender != address(_cash));
    vm.deal(_sender, _amount);

    vm.expectRevert(FixedFeeSwapMarket.FixedFeeSwapMarket_UnexpectedEth.selector);
    vm.prank(_sender);
    (bool _success,) = address(_market).call{value: _amount}("");
    _success;
  }
}
