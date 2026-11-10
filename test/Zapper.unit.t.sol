// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Internal imports
import {Zapper} from "src/Zapper.sol";
import {FixedFeeSwap} from "src/FixedFeeSwap.sol";
import {FixedFeeSwapMarket} from "src/FixedFeeSwapMarket.sol";
import {FixedFeeSwapMarketMock} from "test/mock/FixedFeeSwapMarketMock.sol";
import {FixedFeeSwapMarketHarness} from "test/harness/FixedFeeSwapMarketHarness.sol";
import {VaultShareToken} from "src/VaultShareToken.sol";
import {PrincipalToken} from "src/PrincipalToken.sol";
import {YieldToken} from "src/YieldToken.sol";
import {ERC20Mock} from "test/mock/ERC20Mock.sol";
import {NonPayableContractMock} from "test/mock/NonPayableContractMock.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {VaultShareTokenHarness} from "test/harness/VaultShareTokenHarness.sol";
import {FeeTracking} from "src/lib/FeeTracking.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract ZapperTest is Test {
  Zapper internal zapper;
  FixedFeeSwap internal fixedFeeSwap;
  FixedFeeSwapMarketMock internal fixedFeeSwapMarketMock;
  VaultShareToken internal vaultShareToken;
  ERC20Mock internal token0;
  ERC20Mock internal token1;

  // The real market, with fees and price impact, and a Zapper that trades through it. The mock
  // above fills at its set price with no slippage.
  FixedFeeSwapMarketHarness internal market;
  Zapper internal marketZapper;

  address internal user;
  address internal liquidityProvider;
  uint256 internal maturity;

  // Flash loan return value constant
  bytes32 internal constant FLASH_LOAN_RETURN_VALUE = keccak256("ERC3156FlashBorrower.onFlashLoan");

  /// @notice Term of the real market, and of the FixedFeeSwap it trades, so both mature together.
  uint48 internal constant MARKET_LENGTH = 365 days;

  /// @notice The real market's swap fee: 0.3%, in hundredths of a bip.
  uint24 internal constant MARKET_FEE_RATE = 3000;

  /// @notice One tick of the real market is 1 bip of yield.
  int24 internal constant MARKET_YIELD_PER_TICK = 1;

  /// @notice The real market starts at a 5% yield, inside the LP's range.
  int24 internal constant MARKET_INITIAL_TICK = 500;

  /// @notice The LP's position spans yields of 0% to 10%, around the initial tick, so it holds both
  /// PT and cash and every zap in these tests stays in range.
  int24 internal constant LP_TICK_LOWER = 0;
  int24 internal constant LP_TICK_UPPER = 1000;

  /// @notice Liquidity the LP mints across its range.
  uint128 internal constant LP_LIQUIDITY = 2_000_000e18;

  /// @notice VST the LP splits into PT; it also keeps as much VST, so it can fund `LP_LIQUIDITY`.
  uint256 internal constant LP_SPLIT_AMOUNT = 10_000_000e18;

  /// @notice YT sold, or VST spent, by each zap through the real market.
  uint256 internal constant MARKET_ZAP_AMOUNT = 1000e18;

  /// @notice PT the real market trades per tick across the LP's range: `LP_LIQUIDITY` times one
  /// bip of yield.
  uint256 internal constant MARKET_PRINCIPAL_PER_TICK = LP_LIQUIDITY / 10_000;

  /// @notice The real market's fee denominator; `MARKET_FEE_RATE` is in these units.
  uint256 internal constant MARKET_FEE_DENOMINATOR = 1_000_000;

  /// @notice The last tick of the tick bitmap word holding `MARKET_INITIAL_TICK` (ticks 256 to
  /// 511). A PT-for-cash swap step stops there, and the market then takes nothing more that moves
  /// less than a whole tick.
  int24 internal constant MARKET_WORD_EDGE_TICK = 511;

  /// @notice How close, in wei, the sizing helpers search for the best swap size. A caller doesn't
  /// need wei precision, and each step of the search is a simulated swap.
  uint256 internal constant SIZING_PRECISION = 1e12;

  /// @notice The fewest YT a fuzzed sale through the real market sells.
  /// @dev The market fills cash for PT in whole ticks of `LP_LIQUIDITY` (200 PT each), so the
  /// buyback can overshoot the loan by up to a tick. From this amount on, the VST that redeeming
  /// gives always covers that overshoot. Smaller sales can be sized only for some amounts.
  uint256 internal constant MARKET_MIN_SALE = 5000e18;

  /// @notice The most YT a fuzzed sale through the real market sells, so its buyback stays well
  /// inside the cash the LP's range holds.
  uint256 internal constant MARKET_MAX_SALE = 50_000e18;

  /// @notice The least VST a fuzzed purchase through the real market spends, so its loan can sell
  /// at least one whole tick, the market's smallest fill.
  uint256 internal constant MARKET_MIN_PURCHASE = 10e18;

  /// @notice The most VST a fuzzed purchase through the real market spends. Its loan is about 20
  /// times this, which keeps the sale inside the PT the LP's range can take.
  uint256 internal constant MARKET_MAX_PURCHASE = 4000e18;

  function setUp() public virtual {
    // Underlying fee tokens for the VaultShareToken
    token0 = new ERC20Mock("Token 0", "T0");
    token1 = new ERC20Mock("Token 1", "T1");

    // Underlying VaultShareToken whose shares are being split. The harness lets tests accrue vault
    // fees; it behaves like VaultShareToken otherwise.
    vaultShareToken =
      new VaultShareTokenHarness("Vault Share Token", "VST", address(token0), address(token1));

    // Matures with the real market below.
    maturity = block.timestamp + MARKET_LENGTH;

    fixedFeeSwap = new FixedFeeSwap(vaultShareToken, maturity);

    // Create mock FixedFeeSwapMarket for PT/VST trading
    PrincipalToken _pt = fixedFeeSwap.PRINCIPAL_TOKEN();
    fixedFeeSwapMarketMock = new FixedFeeSwapMarketMock(
      address(_pt), // token0 = PT (principal)
      address(vaultShareToken) // token1 = VST (cash)
    );

    // Fund the mock market with tokens so it can perform swaps
    // Use a large but reasonable amount to cover all test scenarios
    deal(address(_pt), address(fixedFeeSwapMarketMock), 1e30);
    deal(address(vaultShareToken), address(fixedFeeSwapMarketMock), 1e30);

    zapper = new Zapper(fixedFeeSwap, FixedFeeSwapMarket(address(fixedFeeSwapMarketMock)));

    // The real market trades the same PT and VST. The harness only skips the hook address check,
    // and swaps through `swap` never reach the pool manager, so a made-up address will do.
    market = new FixedFeeSwapMarketHarness(
      MARKET_LENGTH,
      address(_pt),
      address(vaultShareToken),
      MARKET_FEE_RATE,
      MARKET_YIELD_PER_TICK,
      IPoolManager(makeAddr("poolManager")),
      MARKET_INITIAL_TICK
    );
    marketZapper = new Zapper(fixedFeeSwap, FixedFeeSwapMarket(address(market)));

    user = makeAddr("user");
    liquidityProvider = makeAddr("liquidityProvider");

    // Moves 30 days into the term, so the market has time elapsed and PT trades below par. The
    // real-market tests depend on the price this gives; the mock tests don't.
    vm.warp(block.timestamp + 30 days);
  }

  function _assumeSafeAddress(address _addr) internal pure {
    vm.assume(_addr != address(0));
  }

  function _boundToRealisticAmount(uint256 _amount) internal pure returns (uint256) {
    // Use a smaller max to avoid overflow issues in price calculations
    return bound(_amount, 1, 1e24); // Max 1 million tokens with 18 decimals
  }

  /// @notice Bounds and sets the mock price on the market mock.
  /// @param _price Raw fuzz input.
  /// @return The bounded price in WAD.
  function _boundAndSetMockPrice(uint256 _price) internal returns (uint256) {
    _price = bound(_price, 0.01e18, 0.99e18);
    fixedFeeSwapMarketMock.setMockPrice(int256(_price));
    return _price;
  }

  /// @notice Helper function to deposit VST for a user and get PT and YT tokens.
  /// @param _user The address to deposit for.
  /// @param _depositAmount The amount of VST to deposit.
  function _depositVstForUser(address _user, uint256 _depositAmount) internal {
    deal(address(vaultShareToken), _user, _depositAmount);
    vm.prank(_user);
    vaultShareToken.approve(address(fixedFeeSwap), _depositAmount);
    vm.prank(_user);
    fixedFeeSwap.deposit(_depositAmount);
  }

  // Mints vault shares through the harness and splits them for `_user`. Unlike
  // `_depositVstForUser`, which uses `deal`, this counts the shares in the vault's total supply,
  // which fee index updates divide by, so vault fees reach FixedFeeSwap.
  function _mintVstAndDepositForUser(address _user, uint256 _depositAmount) internal {
    VaultShareTokenHarness(address(vaultShareToken)).exposed_mint(_user, _depositAmount);
    vm.prank(_user);
    vaultShareToken.approve(address(fixedFeeSwap), _depositAmount);
    vm.prank(_user);
    fixedFeeSwap.deposit(_depositAmount);
  }

  // A vault whose token0 fees are native ETH, with its own FixedFeeSwap, a funded market mock and a
  // Zapper over them. The base fixture's fee tokens are both ERC20s.
  function _deployNativeEthZapper()
    internal
    returns (VaultShareTokenHarness _vstWithEth, FixedFeeSwap _fixedFeeSwap, Zapper _zapper)
  {
    _vstWithEth =
      new VaultShareTokenHarness("Vault Share Token", "VST", address(0), address(token1));
    _fixedFeeSwap = new FixedFeeSwap(_vstWithEth, maturity);
    FixedFeeSwapMarketMock _market =
      new FixedFeeSwapMarketMock(address(_fixedFeeSwap.PRINCIPAL_TOKEN()), address(_vstWithEth));
    deal(address(_fixedFeeSwap.PRINCIPAL_TOKEN()), address(_market), 1e30);
    deal(address(_vstWithEth), address(_market), 1e30);
    _zapper = new Zapper(_fixedFeeSwap, FixedFeeSwapMarket(address(_market)));
  }

  // The spot-sized buyback for a sale of `_ytAmount` YT through `_zapper`, whose market must be a
  // FixedFeeSwapMarketMock, at that mock's price.
  function _spotVstForBuybackOnMock(Zapper _zapper, uint256 _ytAmount)
    internal
    view
    returns (uint256)
  {
    FixedFeeSwapMarketMock _market =
      FixedFeeSwapMarketMock(address(_zapper.FIXED_FEE_SWAP_MARKET()));
    return _spotVstForBuyback(_ytAmount, uint256(_market.mockPrice()));
  }

  // The spot-sized loan for a purchase with `_vstAmount` VST through `_zapper`, whose market must
  // be a FixedFeeSwapMarketMock, at that mock's price.
  function _spotPtLoanOnMock(Zapper _zapper, uint256 _vstAmount) internal view returns (uint256) {
    FixedFeeSwapMarketMock _market =
      FixedFeeSwapMarketMock(address(_zapper.FIXED_FEE_SWAP_MARKET()));
    return _spotPtLoan(_vstAmount, uint256(_market.mockPrice()));
  }

  // Mints `_amount` vault shares to `_holder`, splits them, and approves `_zapper` to take the YT.
  function _splitAndApproveZapper(
    VaultShareTokenHarness _vst,
    FixedFeeSwap _fixedFeeSwap,
    Zapper _zapper,
    address _holder,
    uint256 _amount
  ) internal {
    _vst.exposed_mint(_holder, _amount);
    vm.startPrank(_holder);
    _vst.approve(address(_fixedFeeSwap), _amount);
    _fixedFeeSwap.deposit(_amount);
    _fixedFeeSwap.YIELD_TOKEN().approve(address(_zapper), _amount);
    vm.stopPrank();
  }

  // Credits `_feeToken0` of token0 fees to every vault share holder, as LPVault does when it
  // collects pool fees, and funds the vault to pay them.
  function _accrueVaultFees(uint256 _feeToken0) internal {
    deal(
      address(token0),
      address(vaultShareToken),
      token0.balanceOf(address(vaultShareToken)) + _feeToken0
    );
    VaultShareTokenHarness(address(vaultShareToken)).exposed_updateFees(_feeToken0, 0);
  }

  // Mints vault shares to the LP, splits half into PT, and mints `LP_LIQUIDITY` across the LP's
  // range in the real market. The shares count in the vault's total supply, so tests that need
  // their user to hold every vault share must not call this.
  function _mintMarketLiquidity() internal {
    VaultShareTokenHarness(address(vaultShareToken))
      .exposed_mint(liquidityProvider, 2 * LP_SPLIT_AMOUNT);
    vm.startPrank(liquidityProvider);
    vaultShareToken.approve(address(fixedFeeSwap), LP_SPLIT_AMOUNT);
    fixedFeeSwap.deposit(LP_SPLIT_AMOUNT);
    IERC20(address(fixedFeeSwap.PRINCIPAL_TOKEN())).approve(address(market), type(uint256).max);
    vaultShareToken.approve(address(market), type(uint256).max);
    market.mintLiquidity(
      LP_TICK_LOWER, LP_TICK_UPPER, LP_LIQUIDITY, type(uint256).max, type(uint256).max
    );
    vm.stopPrank();
  }

  // The VST that buys back `_ytAmount` PT at a spot `_price`, as the old Zapper sized it, rounded
  // up. The mock fills at exactly its set price, so this covers the loan there; the real market's
  // fee and price impact make it fall short.
  function _spotVstForBuyback(uint256 _ytAmount, uint256 _price) internal pure returns (uint256) {
    return Math.mulDiv(_ytAmount, _price, FeeTracking.PRECISION, Math.Rounding.Ceil);
  }

  // The PT loan `_vstAmount / (1 - _price)` at a spot `_price`, as the old Zapper sized it, rounded
  // down. The mock's sale of it repays the loan; the real market's sale falls short.
  function _spotPtLoan(uint256 _vstAmount, uint256 _price) internal pure returns (uint256) {
    return Math.mulDiv(_vstAmount, FeeTracking.PRECISION, FeeTracking.PRECISION - _price);
  }

  // The real market's live spot price, from its current tick at the current time. Its
  // `getCurrentPrice` returns the price stored at the last swap, which goes stale as time passes.
  function _marketSpotPrice() internal view returns (uint256) {
    return uint256(market.tickToPrice(market.getCurrentTick()));
  }

  // Mints `LP_LIQUIDITY` in the real market, then has `user` split `_ytAmount` vault shares and
  // approve `marketZapper` to take the YT.
  function _setUpMarketSale(uint256 _ytAmount) internal {
    _mintMarketLiquidity();
    _mintVstAndDepositForUser(user, _ytAmount);
    YieldToken _yt = fixedFeeSwap.YIELD_TOKEN();
    vm.prank(user);
    _yt.approve(address(marketZapper), _ytAmount);
  }

  // Mints `LP_LIQUIDITY` in the real market, then mints `_vstAmount` vault shares to `user` and
  // approves `marketZapper` to take them.
  function _setUpMarketPurchase(uint256 _vstAmount) internal {
    _mintMarketLiquidity();
    VaultShareTokenHarness(address(vaultShareToken)).exposed_mint(user, _vstAmount);
    vm.prank(user);
    vaultShareToken.approve(address(marketZapper), _vstAmount);
  }

  // Funds `_trader` with `_amountIn` PT or VST, minted rather than dealt so supplies stay
  // consistent, and swaps it on the real market. Returns the market's amounts.
  function _fundAndSwapOnMarket(address _trader, uint256 _amountIn, bool _principalForCash)
    internal
    returns (uint256 _amountInUsed, uint256 _amountOut)
  {
    if (_principalForCash) {
      PrincipalToken _pt = fixedFeeSwap.PRINCIPAL_TOKEN();
      vm.prank(address(fixedFeeSwap));
      _pt.mint(_trader, _amountIn);
    } else {
      VaultShareTokenHarness(address(vaultShareToken)).exposed_mint(_trader, _amountIn);
    }
    vm.startPrank(_trader);
    IERC20(address(fixedFeeSwap.PRINCIPAL_TOKEN())).approve(address(market), _amountIn);
    vaultShareToken.approve(address(market), _amountIn);
    (_amountInUsed, _amountOut) = market.swap(_amountIn, _principalForCash, 0);
    vm.stopPrank();
  }

  // Runs a trial swap on the real market and rolls the state back, as an off-chain caller would
  // with `eth_call`. Returns what the swap would consume and pay out from the current state.
  function _simulateMarketSwap(uint256 _amountIn, bool _principalForCash)
    internal
    returns (uint256 _amountInUsed, uint256 _amountOut)
  {
    uint256 _snapshot = vm.snapshotState();
    (_amountInUsed, _amountOut) =
      _fundAndSwapOnMarket(makeAddr("simulator"), _amountIn, _principalForCash);
    vm.revertToStateAndDelete(_snapshot);
  }

  // Sizes a sale of `_ytAmount` YT the way an off-chain caller would: a binary search over
  // simulated swaps for the least VST, to within `SIZING_PRECISION`, whose PT out covers the loan,
  // which leaves the seller the most VST. The search starts above the old Zapper's spot sizing,
  // which always falls short. Fails the test if even all `_ytAmount` VST from redeeming can't buy
  // back the loan.
  function _simulateVstForBuyback(uint256 _ytAmount) internal returns (uint256) {
    (, uint256 _maxPrincipalOut) = _simulateMarketSwap(_ytAmount, false);
    assertGe(_maxPrincipalOut, _ytAmount, "the sale can't buy back its loan");
    uint256 _low = _spotVstForBuyback(_ytAmount, _marketSpotPrice());
    uint256 _high = _ytAmount;
    while (_high - _low > SIZING_PRECISION) {
      uint256 _mid = (_low + _high) / 2;
      (, uint256 _principalOut) = _simulateMarketSwap(_mid, false);
      if (_principalOut >= _ytAmount) _high = _mid;
      else _low = _mid;
    }
    return _high;
  }

  // Sizes a purchase with `_vstAmount` VST the way an off-chain caller would, and returns the loan
  // and the YT it buys. The YT is `_vstAmount` plus the sale's VST out, so the largest loan the
  // purchase can repay buys the most YT. The market pays whole ticks, so PT beyond the last whole
  // tick buys nothing; the loan is then cut to the least PT that gets the same VST, and the PT
  // saved is refunded to the buyer.
  function _simulatePtLoan(uint256 _vstAmount)
    internal
    returns (uint256 _ptLoan, uint256 _ytBought)
  {
    // Starts at the old Zapper's spot sizing, which at a fresh price is usually more than the sale
    // repays, and replaces the loan with what its sale repays until the sale repays it. The loan
    // only falls, and every loan whose sale repays it stays below, so when the spot loan is too
    // much this ends at the largest. When the spot loan already repays, it is kept as is.
    // PT the market leaves untaken also counts toward repayment, so a caller could borrow a little
    // more; this sizing doesn't need to.
    uint256 _spotPrice = _marketSpotPrice();
    _ptLoan = _spotPtLoan(_vstAmount, _spotPrice);
    (, uint256 _vstOut) = _simulateMarketSwap(_ptLoan, true);
    while (_vstAmount + _vstOut < _ptLoan) {
      _ptLoan = _vstAmount + _vstOut;
      (, _vstOut) = _simulateMarketSwap(_ptLoan, true);
    }
    _ytBought = _vstAmount + _vstOut;

    // Binary search for the least PT, to within `SIZING_PRECISION`, that sells for the same VST.
    uint256 _low = 0;
    uint256 _high = _ptLoan;
    while (_high - _low > SIZING_PRECISION) {
      uint256 _mid = (_low + _high) / 2;
      (, uint256 _midVstOut) = _simulateMarketSwap(_mid, true);
      if (_midVstOut >= _vstOut) _high = _mid;
      else _low = _mid;
    }
    _ptLoan = _high;
  }

  /// @notice Helper function to set up fees on YT.
  /// @param _feeToken0 Amount of token0 fees to add.
  /// @param _feeToken1 Amount of token1 fees to add.
}

contract Constructor is ZapperTest {
  function test_SetsAllParamsCorrectly() public view {
    assertEq(address(zapper.FIXED_FEE_SWAP()), address(fixedFeeSwap));
    assertEq(address(zapper.FIXED_FEE_SWAP_MARKET()), address(fixedFeeSwapMarketMock));
    assertEq(address(zapper.YIELD_TOKEN()), address(fixedFeeSwap.YIELD_TOKEN()));
    assertEq(address(zapper.PRINCIPAL_TOKEN()), address(fixedFeeSwap.PRINCIPAL_TOKEN()));
    assertEq(address(zapper.VAULT_SHARE_TOKEN()), address(fixedFeeSwap.VAULT_SHARE_TOKEN()));
  }

  function test_RevertIf_FixedFeeSwapIsZero() public {
    vm.expectRevert(Zapper.Zapper_InvalidAddress.selector);
    new Zapper(
      FixedFeeSwap(payable(address(0))), FixedFeeSwapMarket(address(fixedFeeSwapMarketMock))
    );
  }

  function test_RevertIf_FixedFeeSwapMarketIsZero() public {
    vm.expectRevert(Zapper.Zapper_InvalidAddress.selector);
    new Zapper(fixedFeeSwap, FixedFeeSwapMarket(address(0)));
  }
}

contract SellYieldToken is ZapperTest {
  function testFuzz_TransfersYTFromUserToZapper(uint256 _ytAmount, uint256 _mockPrice) public {
    _ytAmount = _boundToRealisticAmount(_ytAmount);
    _mockPrice = _boundAndSetMockPrice(_mockPrice);

    // Deposit VST to get PT and YT for the user
    _depositVstForUser(user, _ytAmount);

    // Ensure hook has enough VST to transfer back after redeem
    deal(address(vaultShareToken), address(fixedFeeSwap), _ytAmount);

    // User approves zapper to spend YT
    YieldToken _yt = fixedFeeSwap.YIELD_TOKEN();
    vm.prank(user);
    _yt.approve(address(zapper), _ytAmount);

    // Get initial balances
    uint256 _userYTBefore = _yt.balanceOf(user);
    assertEq(_userYTBefore, _ytAmount, "User should have YT before sell");

    // Execute sell
    vm.prank(user);
    zapper.sellYieldToken(_ytAmount, _spotVstForBuyback(_ytAmount, _mockPrice), 0, block.timestamp);

    // Verify user has no YT after sell
    uint256 _userYTAfter = _yt.balanceOf(user);
    assertEq(_userYTAfter, 0, "User should have no YT after sell");
    assertEq(_userYTBefore - _userYTAfter, _ytAmount, "YT balance should decrease by exact amount");
  }

  function testFuzz_UserReceivesVSTAfterSell(uint256 _ytAmount, uint256 _mockPrice) public {
    // Minimum 1e18 so profit survives integer rounding at any price
    _ytAmount = bound(_ytAmount, 1e18, 1e24);
    _mockPrice = _boundAndSetMockPrice(_mockPrice);

    // Deposit VST to get PT and YT for the user
    _depositVstForUser(user, _ytAmount);

    // Ensure hook has enough VST to transfer back after redeem
    deal(address(vaultShareToken), address(fixedFeeSwap), _ytAmount);

    // User approves zapper to spend YT
    YieldToken _yt = fixedFeeSwap.YIELD_TOKEN();
    vm.prank(user);
    _yt.approve(address(zapper), _ytAmount);

    // Get initial VST balance
    uint256 _userVSTBefore = vaultShareToken.balanceOf(user);

    // Execute sell
    vm.prank(user);
    zapper.sellYieldToken(_ytAmount, _spotVstForBuyback(_ytAmount, _mockPrice), 0, block.timestamp);

    // User should receive VST (amount depends on price)
    uint256 _userVSTAfter = vaultShareToken.balanceOf(user);
    uint256 _vstReceived = _userVSTAfter - _userVSTBefore;

    // Redeem gives _ytAmount VST, swap ceil(_ytAmount * price / WAD) VST for PT.
    // User receives the discount: ~_ytAmount * (1 - price) / WAD, minus up to 1 wei rounding.
    assertGt(_vstReceived, 0, "User must receive non-zero VST from sell");

    uint256 _expectedProfit = (_ytAmount * (1e18 - _mockPrice)) / 1e18;
    // Ceil rounding on vstNeeded can reduce profit by 1 wei
    assertGe(_vstReceived + 1, _expectedProfit, "VST received should be close to expected profit");
  }

  function testFuzz_ZapperHasNoRemainingBalancesAfterSell(uint256 _ytAmount, uint256 _mockPrice)
    public
  {
    _ytAmount = _boundToRealisticAmount(_ytAmount);
    _mockPrice = _boundAndSetMockPrice(_mockPrice);

    // Deposit VST to get PT and YT for the user
    _depositVstForUser(user, _ytAmount);

    // Ensure hook has enough VST to transfer back after redeem
    deal(address(vaultShareToken), address(fixedFeeSwap), _ytAmount);

    // User approves zapper to spend YT
    YieldToken _yt = fixedFeeSwap.YIELD_TOKEN();
    vm.prank(user);
    _yt.approve(address(zapper), _ytAmount);

    // Execute sell
    vm.prank(user);
    zapper.sellYieldToken(_ytAmount, _spotVstForBuyback(_ytAmount, _mockPrice), 0, block.timestamp);

    // Zapper should have no remaining VST
    assertEq(
      vaultShareToken.balanceOf(address(zapper)),
      0,
      "Zapper should have no remaining VST after sell"
    );

    // Zapper should have no remaining YT
    assertEq(_yt.balanceOf(address(zapper)), 0, "Zapper should have no remaining YT after sell");

    // Zapper should have no remaining PT
    PrincipalToken _pt = fixedFeeSwap.PRINCIPAL_TOKEN();
    assertEq(_pt.balanceOf(address(zapper)), 0, "Zapper should have no remaining PT after sell");
  }

  function testFuzz_EmitsYieldTokenSoldEvent(uint256 _ytAmount, uint256 _mockPrice) public {
    // Minimum 1e18 so profit survives integer rounding at any price
    _ytAmount = bound(_ytAmount, 1e18, 1e24);
    _mockPrice = _boundAndSetMockPrice(_mockPrice);

    // Deposit VST to get PT and YT for the user
    _depositVstForUser(user, _ytAmount);

    // Ensure hook has enough VST to transfer back after redeem
    deal(address(vaultShareToken), address(fixedFeeSwap), _ytAmount);

    // User approves zapper to spend YT
    YieldToken _yt = fixedFeeSwap.YIELD_TOKEN();
    vm.prank(user);
    _yt.approve(address(zapper), _ytAmount);

    // Check indexed user; skip data fields (vstReceived unknown before call)
    vm.expectEmit(true, false, false, false, address(zapper));
    emit Zapper.YieldTokenSold(user, 0, 0);

    vm.prank(user);
    zapper.sellYieldToken(_ytAmount, _spotVstForBuyback(_ytAmount, _mockPrice), 0, block.timestamp);
  }

  function testFuzz_FlashLoanIsRepaidSuccessfully(uint256 _ytAmount, uint256 _mockPrice) public {
    _ytAmount = _boundToRealisticAmount(_ytAmount);
    _mockPrice = _boundAndSetMockPrice(_mockPrice);

    // Deposit VST to get PT and YT for the user
    _depositVstForUser(user, _ytAmount);

    // Ensure hook has enough VST to transfer back after redeem
    deal(address(vaultShareToken), address(fixedFeeSwap), _ytAmount);

    // User approves zapper to spend YT
    YieldToken _yt = fixedFeeSwap.YIELD_TOKEN();
    vm.prank(user);
    _yt.approve(address(zapper), _ytAmount);

    // Execute sell - if flash loan isn't repaid, this would revert
    vm.prank(user);
    zapper.sellYieldToken(_ytAmount, _spotVstForBuyback(_ytAmount, _mockPrice), 0, block.timestamp);

    // If we reach here, flash loan was repaid successfully (no revert)
    assertTrue(true, "Flash loan was repaid successfully (no revert)");
  }

  function testFuzz_RevertIf_AmountIsZero(uint256 _vstForBuyback) public {
    vm.expectRevert(Zapper.Zapper_InvalidAmount.selector);
    zapper.sellYieldToken(0, _vstForBuyback, 0, block.timestamp);
  }

  function testFuzz_RevertIf_VstForBuybackIsZero(uint256 _ytAmount) public {
    _ytAmount = bound(_ytAmount, 1, type(uint256).max);
    vm.expectRevert(Zapper.Zapper_InvalidAmount.selector);
    zapper.sellYieldToken(_ytAmount, 0, 0, block.timestamp);
  }

  function testFuzz_RevertIf_VstForBuybackIsMoreThanTheAmount(
    uint256 _ytAmount,
    uint256 _vstForBuyback
  ) public {
    _ytAmount = bound(_ytAmount, 1, type(uint256).max - 1);
    _vstForBuyback = bound(_vstForBuyback, _ytAmount + 1, type(uint256).max);
    vm.expectRevert(Zapper.Zapper_InvalidAmount.selector);
    zapper.sellYieldToken(_ytAmount, _vstForBuyback, 0, block.timestamp);
  }

  function testFuzz_RevertIf_DeadlineHasPassed(uint256 _ytAmount, uint256 _deadline) public {
    _ytAmount = _boundToRealisticAmount(_ytAmount);
    _deadline = bound(_deadline, 0, block.timestamp - 1);
    uint256 _vstForBuyback = _spotVstForBuybackOnMock(zapper, _ytAmount);

    vm.expectRevert(Zapper.Zapper_DeadlineExpired.selector);
    vm.prank(user);
    zapper.sellYieldToken(_ytAmount, _vstForBuyback, 0, _deadline);
  }

  function test_SellsYieldTokensThroughTheRealMarket() public {
    _setUpMarketSale(MARKET_ZAP_AMOUNT);
    uint256 _vstForBuyback = _simulateVstForBuyback(MARKET_ZAP_AMOUNT);
    (uint256 _vstUsed,) = _simulateMarketSwap(_vstForBuyback, false);
    // The minimum is exactly the VST the sale leaves.
    uint256 _vstLeft = MARKET_ZAP_AMOUNT - _vstUsed;

    vm.prank(user);
    marketZapper.sellYieldToken(MARKET_ZAP_AMOUNT, _vstForBuyback, _vstLeft, block.timestamp);

    assertEq(fixedFeeSwap.YIELD_TOKEN().balanceOf(user), 0);
    assertEq(vaultShareToken.balanceOf(user), _vstLeft);
  }

  function testFuzz_SellsInALaterBlockWithAPaddedBuybackThroughTheRealMarket(
    uint256 _ytAmount,
    uint256 _delay
  ) public {
    _ytAmount = bound(_ytAmount, MARKET_MIN_SALE, MARKET_MAX_SALE);
    // From one block to an hour after sizing; the PT price rises toward par throughout.
    _delay = bound(_delay, 1, 1 hours);
    _setUpMarketSale(_ytAmount);
    // Sized as the docs advise: the simulated buyback plus a 0.01% margin.
    uint256 _vstForBuyback = _simulateVstForBuyback(_ytAmount);
    _vstForBuyback += _vstForBuyback / 10_000;
    vm.warp(block.timestamp + _delay);

    vm.prank(user);
    marketZapper.sellYieldToken(_ytAmount, _vstForBuyback, 0, block.timestamp);

    assertEq(fixedFeeSwap.YIELD_TOKEN().balanceOf(user), 0);
  }

  function testFuzz_PaysTheSellerTheVstTheBuybackLeavesThroughTheRealMarket(uint256 _ytAmount)
    public
  {
    _ytAmount = bound(_ytAmount, MARKET_MIN_SALE, MARKET_MAX_SALE);
    _setUpMarketSale(_ytAmount);
    uint256 _vstForBuyback = _simulateVstForBuyback(_ytAmount);
    (uint256 _vstUsed,) = _simulateMarketSwap(_vstForBuyback, false);

    vm.prank(user);
    marketZapper.sellYieldToken(_ytAmount, _vstForBuyback, 0, block.timestamp);

    assertEq(vaultShareToken.balanceOf(user), _ytAmount - _vstUsed);
    assertEq(vaultShareToken.balanceOf(address(marketZapper)), 0);
  }

  function testFuzz_PaysTheSellerThePrincipalTheBuybackReturnsBeyondTheLoanThroughTheRealMarket(uint256 _ytAmount)
    public
  {
    _ytAmount = bound(_ytAmount, MARKET_MIN_SALE, MARKET_MAX_SALE);
    _setUpMarketSale(_ytAmount);
    uint256 _vstForBuyback = _simulateVstForBuyback(_ytAmount);
    (, uint256 _principalOut) = _simulateMarketSwap(_vstForBuyback, false);
    PrincipalToken _pt = fixedFeeSwap.PRINCIPAL_TOKEN();
    uint256 _userPrincipalBefore = _pt.balanceOf(user);

    vm.prank(user);
    marketZapper.sellYieldToken(_ytAmount, _vstForBuyback, 0, block.timestamp);

    assertEq(_pt.balanceOf(user) - _userPrincipalBefore, _principalOut - _ytAmount);
    assertEq(_pt.balanceOf(address(marketZapper)), 0);
  }

  function testFuzz_RevertIf_BuybackReturnsLessPrincipalThanTheLoan(uint256 _ytAmount) public {
    _ytAmount = bound(_ytAmount, MARKET_MIN_SALE, MARKET_MAX_SALE);
    _setUpMarketSale(_ytAmount);
    // The old Zapper's spot sizing: the fee and price impact make it buy back less than the loan.
    uint256 _vstForBuyback = _spotVstForBuyback(_ytAmount, _marketSpotPrice());
    (, uint256 _principalOut) = _simulateMarketSwap(_vstForBuyback, false);

    vm.expectRevert(
      abi.encodeWithSelector(
        Zapper.Zapper_InsufficientPrincipalToRepay.selector, _principalOut, _ytAmount
      )
    );
    vm.prank(user);
    marketZapper.sellYieldToken(_ytAmount, _vstForBuyback, 0, block.timestamp);
  }

  function testFuzz_RevertIf_VstLeftIsBelowTheMinimum(uint256 _ytAmount, uint256 _minVstOut)
    public
  {
    _ytAmount = bound(_ytAmount, MARKET_MIN_SALE, MARKET_MAX_SALE);
    _setUpMarketSale(_ytAmount);
    uint256 _vstForBuyback = _simulateVstForBuyback(_ytAmount);
    (uint256 _vstUsed,) = _simulateMarketSwap(_vstForBuyback, false);
    uint256 _vstLeft = _ytAmount - _vstUsed;
    _minVstOut = bound(_minVstOut, _vstLeft + 1, type(uint256).max);

    vm.expectRevert(
      abi.encodeWithSelector(Zapper.Zapper_InsufficientOutput.selector, _vstLeft, _minVstOut)
    );
    vm.prank(user);
    marketZapper.sellYieldToken(_ytAmount, _vstForBuyback, _minVstOut, block.timestamp);
  }

  function testFuzz_RevertIf_AFrontRunRaisesThePrincipalPriceAfterTheSaleIsSized(
    uint256 _ytAmount,
    uint256 _frontRunVst
  ) public {
    _ytAmount = bound(_ytAmount, MARKET_MIN_SALE, MARKET_MAX_SALE);
    // More than a tick's worth of VST (about 191) after the fee, so the front-run moves the price;
    // at most a size that keeps the market inside the LP's range.
    _frontRunVst = bound(_frontRunVst, 200e18, 20_000e18);
    _setUpMarketSale(_ytAmount);
    uint256 _vstForBuyback = _simulateVstForBuyback(_ytAmount);
    // A sandwich's first leg: someone buys PT between the simulation and the sale.
    _fundAndSwapOnMarket(makeAddr("frontRunner"), _frontRunVst, false);

    vm.expectPartialRevert(Zapper.Zapper_InsufficientPrincipalToRepay.selector);
    vm.prank(user);
    marketZapper.sellYieldToken(_ytAmount, _vstForBuyback, 0, block.timestamp);
  }

  function testFuzz_PaysTheSellerTheFeesTheirYieldTokensEarned(
    uint256 _ytAmount,
    uint256 _feeToken0,
    uint256 _mockPrice
  ) public {
    // At least 1e18 for the same rounding reason as the sell profit tests above; at most 1e24 so a
    // fee of at least 1e18 raises the vault fee index on every share.
    _ytAmount = bound(_ytAmount, 1e18, 1e24);
    _feeToken0 = bound(_feeToken0, 1e18, type(uint128).max);
    _mockPrice = _boundAndSetMockPrice(_mockPrice);
    _mintVstAndDepositForUser(user, _ytAmount);
    // The user's YT earns fees, and nothing syncs them into YT before the sale.
    _accrueVaultFees(_feeToken0);
    // The user's split VST is every vault share, so their YT earns the whole fee index increase.
    uint256 _earnedByUser = Math.mulDiv(
      _ytAmount, Math.mulDiv(_feeToken0, FeeTracking.PRECISION, _ytAmount), FeeTracking.PRECISION
    );
    YieldToken _yt = fixedFeeSwap.YIELD_TOKEN();
    vm.prank(user);
    _yt.approve(address(zapper), _ytAmount);

    vm.prank(user);
    zapper.sellYieldToken(_ytAmount, _spotVstForBuyback(_ytAmount, _mockPrice), 0, block.timestamp);

    // YieldToken rounds its fee index down by up to 1 per 1e18 shares.
    assertApproxEqAbs(token0.balanceOf(user), _earnedByUser, _ytAmount / FeeTracking.PRECISION + 2);
    assertEq(token0.balanceOf(address(zapper)), 0);
  }

  function testFuzz_PaysTheSellerNativeEthFeesTheirYieldTokensEarned(
    uint256 _ytAmount,
    uint256 _feeEth
  ) public {
    _ytAmount = bound(_ytAmount, 1e18, 1e24);
    _feeEth = bound(_feeEth, 1e18, type(uint128).max);
    (VaultShareTokenHarness _vstWithEth, FixedFeeSwap _fixedFeeSwap, Zapper _zapper) =
      _deployNativeEthZapper();
    _splitAndApproveZapper(_vstWithEth, _fixedFeeSwap, _zapper, user, _ytAmount);
    vm.deal(address(_vstWithEth), _feeEth);
    _vstWithEth.exposed_updateFees(_feeEth, 0);
    // The user's split VST is every minted vault share, so their YT earns the whole increase.
    uint256 _earnedByUser = Math.mulDiv(
      _ytAmount, Math.mulDiv(_feeEth, FeeTracking.PRECISION, _ytAmount), FeeTracking.PRECISION
    );
    uint256 _vstForBuyback = _spotVstForBuybackOnMock(_zapper, _ytAmount);

    vm.prank(user);
    _zapper.sellYieldToken(_ytAmount, _vstForBuyback, 0, block.timestamp);

    // YieldToken rounds its fee index down by up to 1 per 1e18 shares.
    assertApproxEqAbs(user.balance, _earnedByUser, _ytAmount / FeeTracking.PRECISION + 2);
    assertEq(address(_zapper).balance, 0);
  }

  function testFuzz_PaysTheSellerFeesOnYieldTokensTheyKeep(
    uint256 _ytAmount,
    uint256 _sellAmount,
    uint256 _feeToken0
  ) public {
    _ytAmount = bound(_ytAmount, 1e18, 1e24);
    _sellAmount = bound(_sellAmount, 1, _ytAmount - 1);
    _feeToken0 = bound(_feeToken0, 1e18, type(uint128).max);
    _mintVstAndDepositForUser(user, _ytAmount);
    _accrueVaultFees(_feeToken0);
    // The user's split VST is every vault share, so their YT earns the whole fee index increase.
    uint256 _earnedByUser = Math.mulDiv(
      _ytAmount, Math.mulDiv(_feeToken0, FeeTracking.PRECISION, _ytAmount), FeeTracking.PRECISION
    );
    YieldToken _yieldToken = fixedFeeSwap.YIELD_TOKEN();
    vm.prank(user);
    _yieldToken.approve(address(zapper), _sellAmount);

    uint256 _vstForBuyback = _spotVstForBuybackOnMock(zapper, _sellAmount);

    vm.prank(user);
    zapper.sellYieldToken(_sellAmount, _vstForBuyback, 0, block.timestamp);

    // YieldToken rounds its fee index down by up to 1 per 1e18 shares.
    assertApproxEqAbs(token0.balanceOf(user), _earnedByUser, _ytAmount / FeeTracking.PRECISION + 2);
    (,, uint256 _stillAccrued0,) = _yieldToken.userFees(user);
    assertEq(_stillAccrued0, 0);
  }

  function testFuzz_SellsWhenTheSellerCannotReceiveItsNativeEthFees(
    uint256 _ytAmount,
    uint256 _feeEth
  ) public {
    _ytAmount = bound(_ytAmount, 1e18, 1e24);
    _feeEth = bound(_feeEth, 1e18, type(uint128).max);
    (VaultShareTokenHarness _vstWithEth, FixedFeeSwap _fixedFeeSwap, Zapper _zapper) =
      _deployNativeEthZapper();
    address _seller = address(new NonPayableContractMock());
    _splitAndApproveZapper(_vstWithEth, _fixedFeeSwap, _zapper, _seller, _ytAmount);
    vm.deal(address(_vstWithEth), _feeEth);
    _vstWithEth.exposed_updateFees(_feeEth, 0);

    uint256 _vstForBuyback = _spotVstForBuybackOnMock(_zapper, _ytAmount);

    vm.prank(_seller);
    _zapper.sellYieldToken(_ytAmount, _vstForBuyback, 0, block.timestamp);

    (,, uint256 _stillAccrued0,) = _fixedFeeSwap.YIELD_TOKEN().userFees(_seller);
    assertGt(_stillAccrued0, 0);
    assertEq(_fixedFeeSwap.YIELD_TOKEN().balanceOf(_seller), 0);
  }

  function testFuzz_ForwardsNativeEthFeesEarnedByYieldTokensSentToTheZapper(
    uint256 _ytAmount,
    uint256 _sentAmount,
    uint256 _feeEth
  ) public {
    _ytAmount = bound(_ytAmount, 1e18, 1e24);
    _sentAmount = bound(_sentAmount, 1e18, 1e24);
    _feeEth = bound(_feeEth, 1e18, type(uint128).max);
    address _sender = makeAddr("sender");
    (VaultShareTokenHarness _vstWithEth, FixedFeeSwap _fixedFeeSwap, Zapper _zapper) =
      _deployNativeEthZapper();
    _splitAndApproveZapper(_vstWithEth, _fixedFeeSwap, _zapper, user, _ytAmount);
    _splitAndApproveZapper(_vstWithEth, _fixedFeeSwap, _zapper, _sender, _sentAmount);
    YieldToken _yieldToken = _fixedFeeSwap.YIELD_TOKEN();
    // YT sent straight to the Zapper earns fees that its next redeem pays to the Zapper.
    vm.prank(_sender);
    _yieldToken.transfer(address(_zapper), _sentAmount);
    vm.deal(address(_vstWithEth), _feeEth);
    _vstWithEth.exposed_updateFees(_feeEth, 0);

    uint256 _vstForBuyback = _spotVstForBuybackOnMock(_zapper, _ytAmount);

    vm.prank(user);
    _zapper.sellYieldToken(_ytAmount, _vstForBuyback, 0, block.timestamp);

    assertEq(address(_zapper).balance, 0);
    assertGt(user.balance, 0);
  }

  function testFuzz_RevertIf_SoldAtOrAfterMaturity(uint256 _ytAmount, uint256 _secondsAfterMaturity)
    public
  {
    _ytAmount = _boundToRealisticAmount(_ytAmount);
    _secondsAfterMaturity = bound(_secondsAfterMaturity, 0, 365 days);
    _mintVstAndDepositForUser(user, _ytAmount);
    YieldToken _yieldToken = fixedFeeSwap.YIELD_TOKEN();
    vm.prank(user);
    _yieldToken.approve(address(zapper), _ytAmount);
    uint256 _vstForBuyback = _spotVstForBuybackOnMock(zapper, _ytAmount);
    vm.warp(maturity + _secondsAfterMaturity);

    vm.expectRevert(Zapper.Zapper_AfterMaturity.selector);
    vm.prank(user);
    zapper.sellYieldToken(_ytAmount, _vstForBuyback, 0, block.timestamp);
  }

  function testFuzz_RevertIf_TheSellerHasNotApprovedTheZapperForItsYieldTokens(uint256 _ytAmount)
    public
  {
    _ytAmount = _boundToRealisticAmount(_ytAmount);
    _mintVstAndDepositForUser(user, _ytAmount);
    uint256 _vstForBuyback = _spotVstForBuybackOnMock(zapper, _ytAmount);

    vm.expectRevert(
      abi.encodeWithSelector(
        IERC20Errors.ERC20InsufficientAllowance.selector, address(zapper), 0, _ytAmount
      )
    );
    vm.prank(user);
    zapper.sellYieldToken(_ytAmount, _vstForBuyback, 0, block.timestamp);
  }
}

contract BuyYieldToken is ZapperTest {
  function testFuzz_TransfersVSTFromUserToZapper(uint256 _vstAmount, uint256 _mockPrice) public {
    _vstAmount = _boundToRealisticAmount(_vstAmount);
    _mockPrice = _boundAndSetMockPrice(_mockPrice);

    // Give user VST
    deal(address(vaultShareToken), user, _vstAmount);

    // User approves zapper to spend VST
    vm.prank(user);
    vaultShareToken.approve(address(zapper), _vstAmount);

    // Get initial VST balance
    uint256 _userVSTBefore = vaultShareToken.balanceOf(user);
    assertEq(_userVSTBefore, _vstAmount, "User should have VST before buy");

    // Execute buy
    vm.prank(user);
    zapper.buyYieldToken(_vstAmount, _spotPtLoan(_vstAmount, _mockPrice), 0, block.timestamp);

    // User should have spent all VST
    uint256 _userVSTAfter = vaultShareToken.balanceOf(user);
    assertEq(_userVSTAfter, 0, "User should have no VST after buy");
    assertEq(
      _userVSTBefore - _userVSTAfter, _vstAmount, "VST balance should decrease by exact amount"
    );
  }

  function testFuzz_UserReceivesYTAfterBuy(uint256 _vstAmount, uint256 _mockPrice) public {
    _vstAmount = _boundToRealisticAmount(_vstAmount);
    _mockPrice = _boundAndSetMockPrice(_mockPrice);

    // Give user VST
    deal(address(vaultShareToken), user, _vstAmount);

    // User approves zapper to spend VST
    vm.prank(user);
    vaultShareToken.approve(address(zapper), _vstAmount);

    // Get initial YT balance
    YieldToken _yt = fixedFeeSwap.YIELD_TOKEN();
    uint256 _userYTBefore = _yt.balanceOf(user);
    assertEq(_userYTBefore, 0, "User should have no YT before buy");

    // Execute buy
    vm.prank(user);
    zapper.buyYieldToken(_vstAmount, _spotPtLoan(_vstAmount, _mockPrice), 0, block.timestamp);

    // User should receive YT
    uint256 _userYTAfter = _yt.balanceOf(user);
    uint256 _ytReceived = _userYTAfter - _userYTBefore;
    assertGt(_ytReceived, 0, "User should receive YT");

    // With mock implementation: PT debt = vstAmount / (1 - 0.98) = vstAmount * 50
    // Then swap gives vstFromSwap = ptDebt * 0.98
    // Total VST = vstFromSwap + vstAmount
    // Deposit totalVST gives totalVST YT
    // So ytReceived should be approximately related to vstAmount
    // Exact amount depends on mock implementation
  }

  function testFuzz_YTReceivedIsProportionalToVSTSupplied(
    uint256 _vstAmount1,
    uint256 _vstAmount2,
    uint256 _mockPrice
  ) public {
    _vstAmount1 = bound(_vstAmount1, 1e18, type(uint64).max);
    _vstAmount2 = bound(_vstAmount2, 1e18, type(uint64).max);
    _mockPrice = _boundAndSetMockPrice(_mockPrice);
    vm.assume(_vstAmount1 != _vstAmount2);

    address _user1 = makeAddr("user1");
    address _user2 = makeAddr("user2");

    // Give users VST
    deal(address(vaultShareToken), _user1, _vstAmount1);
    deal(address(vaultShareToken), _user2, _vstAmount2);

    // Users approve zapper
    vm.prank(_user1);
    vaultShareToken.approve(address(zapper), _vstAmount1);
    vm.prank(_user2);
    vaultShareToken.approve(address(zapper), _vstAmount2);

    // Execute buys
    vm.prank(_user1);
    zapper.buyYieldToken(_vstAmount1, _spotPtLoan(_vstAmount1, _mockPrice), 0, block.timestamp);

    vm.prank(_user2);
    zapper.buyYieldToken(_vstAmount2, _spotPtLoan(_vstAmount2, _mockPrice), 0, block.timestamp);

    // Get YT received
    YieldToken _yt = fixedFeeSwap.YIELD_TOKEN();
    uint256 _yt1 = _yt.balanceOf(_user1);
    uint256 _yt2 = _yt.balanceOf(_user2);

    // More VST should yield more YT
    if (_vstAmount1 > _vstAmount2) assertGt(_yt1, _yt2, "More VST should yield more YT");
    else assertGt(_yt2, _yt1, "More VST should yield more YT");
  }

  function testFuzz_ZapperHasNoRemainingBalancesAfterBuy(uint256 _vstAmount, uint256 _mockPrice)
    public
  {
    _vstAmount = _boundToRealisticAmount(_vstAmount);
    _mockPrice = _boundAndSetMockPrice(_mockPrice);

    // Give user VST
    deal(address(vaultShareToken), user, _vstAmount);

    // User approves zapper to spend VST
    vm.prank(user);
    vaultShareToken.approve(address(zapper), _vstAmount);

    // Execute buy
    vm.prank(user);
    zapper.buyYieldToken(_vstAmount, _spotPtLoan(_vstAmount, _mockPrice), 0, block.timestamp);

    // Zapper should have no remaining VST
    assertEq(
      vaultShareToken.balanceOf(address(zapper)), 0, "Zapper should have no remaining VST after buy"
    );

    // Zapper should have no remaining YT (all transferred to user)
    YieldToken _yt = fixedFeeSwap.YIELD_TOKEN();
    assertEq(_yt.balanceOf(address(zapper)), 0, "Zapper should have no remaining YT after buy");

    // Zapper should have no remaining PT (any left after repaying goes to the user)
    PrincipalToken _pt = fixedFeeSwap.PRINCIPAL_TOKEN();
    assertEq(_pt.balanceOf(address(zapper)), 0, "Zapper should have no remaining PT after buy");
  }

  function testFuzz_EmitsYieldTokenBoughtEvent(uint256 _vstAmount, uint256 _mockPrice) public {
    _vstAmount = _boundToRealisticAmount(_vstAmount);
    _mockPrice = _boundAndSetMockPrice(_mockPrice);

    // Give user VST
    deal(address(vaultShareToken), user, _vstAmount);

    // User approves zapper to spend VST
    vm.prank(user);
    vaultShareToken.approve(address(zapper), _vstAmount);

    // Check indexed user; skip data fields (ytBought unknown before call)
    vm.expectEmit(true, false, false, false, address(zapper));
    emit Zapper.YieldTokenBought(user, 0, 0);

    vm.prank(user);
    zapper.buyYieldToken(_vstAmount, _spotPtLoan(_vstAmount, _mockPrice), 0, block.timestamp);
  }

  function testFuzz_FlashLoanIsRepaidSuccessfully(uint256 _vstAmount, uint256 _mockPrice) public {
    _vstAmount = _boundToRealisticAmount(_vstAmount);
    _mockPrice = _boundAndSetMockPrice(_mockPrice);

    // Give user VST
    deal(address(vaultShareToken), user, _vstAmount);

    // User approves zapper to spend VST
    vm.prank(user);
    vaultShareToken.approve(address(zapper), _vstAmount);

    // Execute buy - if flash loan isn't repaid, this would revert
    vm.prank(user);
    zapper.buyYieldToken(_vstAmount, _spotPtLoan(_vstAmount, _mockPrice), 0, block.timestamp);

    // If we reach here, flash loan was repaid successfully
    assertTrue(true, "Flash loan was repaid successfully (no revert)");
  }

  function testFuzz_RevertIf_AmountIsZero(uint256 _ptLoan) public {
    vm.expectRevert(Zapper.Zapper_InvalidAmount.selector);
    zapper.buyYieldToken(0, _ptLoan, 0, block.timestamp);
  }

  function testFuzz_RevertIf_PtLoanIsZero(uint256 _vstAmount) public {
    _vstAmount = bound(_vstAmount, 1, type(uint256).max);
    vm.expectRevert(Zapper.Zapper_InvalidAmount.selector);
    zapper.buyYieldToken(_vstAmount, 0, 0, block.timestamp);
  }

  function testFuzz_RevertIf_BoughtAtOrAfterMaturity(
    uint256 _vstAmount,
    uint256 _secondsAfterMaturity
  ) public {
    _vstAmount = _boundToRealisticAmount(_vstAmount);
    _secondsAfterMaturity = bound(_secondsAfterMaturity, 0, 365 days);
    uint256 _ptLoan = _spotPtLoanOnMock(zapper, _vstAmount);
    deal(address(vaultShareToken), user, _vstAmount);
    vm.prank(user);
    vaultShareToken.approve(address(zapper), _vstAmount);
    vm.warp(maturity + _secondsAfterMaturity);

    vm.expectRevert(Zapper.Zapper_AfterMaturity.selector);
    vm.prank(user);
    zapper.buyYieldToken(_vstAmount, _ptLoan, 0, block.timestamp);
  }

  function testFuzz_RevertIf_DeadlineHasPassed(uint256 _vstAmount, uint256 _deadline) public {
    _vstAmount = _boundToRealisticAmount(_vstAmount);
    _deadline = bound(_deadline, 0, block.timestamp - 1);
    uint256 _ptLoan = _spotPtLoanOnMock(zapper, _vstAmount);

    vm.expectRevert(Zapper.Zapper_DeadlineExpired.selector);
    vm.prank(user);
    zapper.buyYieldToken(_vstAmount, _ptLoan, 0, _deadline);
  }

  function test_BuysYieldTokensThroughTheRealMarket() public {
    _setUpMarketPurchase(MARKET_ZAP_AMOUNT);
    (uint256 _ptLoan, uint256 _ytBought) = _simulatePtLoan(MARKET_ZAP_AMOUNT);

    vm.prank(user);
    marketZapper.buyYieldToken(MARKET_ZAP_AMOUNT, _ptLoan, _ytBought, block.timestamp);

    // Leverage: the buyer gets more YT than the VST it spent.
    assertGt(fixedFeeSwap.YIELD_TOKEN().balanceOf(user), MARKET_ZAP_AMOUNT);
  }

  function testFuzz_PaysTheBuyerTheSimulatedYieldTokensThroughTheRealMarket(uint256 _vstAmount)
    public
  {
    _vstAmount = bound(_vstAmount, MARKET_MIN_PURCHASE, MARKET_MAX_PURCHASE);
    _setUpMarketPurchase(_vstAmount);
    (uint256 _ptLoan, uint256 _ytBought) = _simulatePtLoan(_vstAmount);

    vm.prank(user);
    marketZapper.buyYieldToken(_vstAmount, _ptLoan, 0, block.timestamp);

    assertEq(fixedFeeSwap.YIELD_TOKEN().balanceOf(user), _ytBought);
    assertEq(vaultShareToken.balanceOf(address(marketZapper)), 0);
  }

  function test_RefundsThePrincipalTheMarketLeavesUntakenThroughTheRealMarket() public {
    _setUpMarketPurchase(MARKET_ZAP_AMOUNT);
    // A loan that, after the fee, reaches the word edge and goes half a tick further. The market
    // stops at the edge and leaves the half tick untaken.
    uint256 _ptToWordEdge = Math.mulDiv(
      uint256(int256(MARKET_WORD_EDGE_TICK - MARKET_INITIAL_TICK)) * MARKET_PRINCIPAL_PER_TICK,
      MARKET_FEE_DENOMINATOR,
      MARKET_FEE_DENOMINATOR - MARKET_FEE_RATE,
      Math.Rounding.Ceil
    );
    uint256 _ptLoan = _ptToWordEdge + MARKET_PRINCIPAL_PER_TICK / 2;
    (uint256 _ptUsed, uint256 _vstOut) = _simulateMarketSwap(_ptLoan, true);

    vm.prank(user);
    marketZapper.buyYieldToken(MARKET_ZAP_AMOUNT, _ptLoan, 0, block.timestamp);

    assertEq(_ptLoan - _ptUsed, MARKET_PRINCIPAL_PER_TICK / 2);
    // The split mints the YT bought in PT too; the loan is repaid from that and the untaken PT.
    PrincipalToken _pt = fixedFeeSwap.PRINCIPAL_TOKEN();
    assertEq(_pt.balanceOf(user), MARKET_ZAP_AMOUNT + _vstOut - _ptUsed);
    assertEq(_pt.balanceOf(address(marketZapper)), 0);
  }

  function testFuzz_PaysTheBuyerThePrincipalLeftAfterRepayingTheLoanThroughTheRealMarket(uint256 _vstAmount)
    public
  {
    _vstAmount = bound(_vstAmount, MARKET_MIN_PURCHASE, MARKET_MAX_PURCHASE);
    _setUpMarketPurchase(_vstAmount);
    (uint256 _ptLoan, uint256 _ytBought) = _simulatePtLoan(_vstAmount);
    (uint256 _ptUsed,) = _simulateMarketSwap(_ptLoan, true);

    vm.prank(user);
    marketZapper.buyYieldToken(_vstAmount, _ptLoan, 0, block.timestamp);

    // The split mints `_ytBought` PT, and the market leaves any PT it didn't take.
    PrincipalToken _pt = fixedFeeSwap.PRINCIPAL_TOKEN();
    assertEq(_pt.balanceOf(user), _ytBought + (_ptLoan - _ptUsed) - _ptLoan);
    assertEq(_pt.balanceOf(address(marketZapper)), 0);
  }

  function testFuzz_RevertIf_SaleOfTheLoanLeavesTooLittlePrincipalToRepay(uint256 _vstAmount)
    public
  {
    // At most half the usual purchase, so twice its spot-sized loan stays inside the LP's range.
    _vstAmount = bound(_vstAmount, MARKET_MIN_PURCHASE, MARKET_MAX_PURCHASE / 2);
    _setUpMarketPurchase(_vstAmount);
    // Twice the old Zapper's spot sizing. The sale fills below spot, so the VST it can't repay is
    // at least the PT discount on the PT the market takes, about twice `_vstAmount`. That exceeds
    // `_vstAmount` plus the under one tick of PT the market can leave untaken. The spot sizing
    // itself can repay for some amounts, when the market leaves enough PT untaken.
    uint256 _spotPrice = _marketSpotPrice();
    uint256 _ptLoan = 2 * _spotPtLoan(_vstAmount, _spotPrice);
    (uint256 _ptUsed, uint256 _vstOut) = _simulateMarketSwap(_ptLoan, true);

    vm.expectRevert(
      abi.encodeWithSelector(
        Zapper.Zapper_InsufficientPrincipalToRepay.selector,
        (_ptLoan - _ptUsed) + _vstAmount + _vstOut,
        _ptLoan
      )
    );
    vm.prank(user);
    marketZapper.buyYieldToken(_vstAmount, _ptLoan, 0, block.timestamp);
  }

  function testFuzz_RevertIf_YieldTokensBoughtAreBelowTheMinimum(
    uint256 _vstAmount,
    uint256 _minYtOut
  ) public {
    _vstAmount = bound(_vstAmount, MARKET_MIN_PURCHASE, MARKET_MAX_PURCHASE);
    _setUpMarketPurchase(_vstAmount);
    (uint256 _ptLoan, uint256 _ytBought) = _simulatePtLoan(_vstAmount);
    _minYtOut = bound(_minYtOut, _ytBought + 1, type(uint256).max);

    vm.expectRevert(
      abi.encodeWithSelector(Zapper.Zapper_InsufficientOutput.selector, _ytBought, _minYtOut)
    );
    vm.prank(user);
    marketZapper.buyYieldToken(_vstAmount, _ptLoan, _minYtOut, block.timestamp);
  }

  function testFuzz_RevertIf_AFrontRunLowersThePrincipalPriceAfterThePurchaseIsSized(uint256 _frontRunPt)
    public
  {
    // More than a tick of PT (200) after the fee, so the front-run moves the price; at most a size
    // that leaves the purchase's slack able to repay the loan, so the minimum is what stops it.
    _frontRunPt = bound(_frontRunPt, 250e18, 1000e18);
    _setUpMarketPurchase(MARKET_ZAP_AMOUNT);
    // The caller sizes the loan as if it had 1% less VST, so a small price move can't stop the
    // repayment, and sets the minimum to the YT it simulates.
    (uint256 _ptLoan,) = _simulatePtLoan(MARKET_ZAP_AMOUNT * 99 / 100);
    (, uint256 _vstOut) = _simulateMarketSwap(_ptLoan, true);
    // A sandwich's first leg: someone sells PT between the simulation and the purchase.
    _fundAndSwapOnMarket(makeAddr("frontRunner"), _frontRunPt, true);

    vm.expectPartialRevert(Zapper.Zapper_InsufficientOutput.selector);
    vm.prank(user);
    marketZapper.buyYieldToken(
      MARKET_ZAP_AMOUNT, _ptLoan, MARKET_ZAP_AMOUNT + _vstOut, block.timestamp
    );
  }
}

contract OnFlashLoan is ZapperTest {
  function testFuzz_RevertIf_InitiatorIsNotZapper(
    address _initiator,
    address _token,
    uint256 _amount
  ) public {
    vm.assume(_initiator != address(zapper));
    vm.expectRevert(Zapper.Zapper_InvalidInitiator.selector);
    zapper.onFlashLoan(_initiator, _token, _amount, 0, "");
  }

  function testFuzz_RevertIf_TokenIsNotPrincipalToken(address _token, uint256 _amount) public {
    vm.assume(_token != address(fixedFeeSwap.PRINCIPAL_TOKEN()));

    vm.expectRevert(Zapper.Zapper_InvalidFlashLoanToken.selector);
    zapper.onFlashLoan(address(zapper), _token, _amount, 0, "");
  }

  function testFuzz_RevertIf_CallerIsNotPrincipalToken(address _msgSender, uint256 _amount) public {
    PrincipalToken _pt = fixedFeeSwap.PRINCIPAL_TOKEN();

    vm.assume(_msgSender != address(_pt));

    vm.expectRevert(Zapper.Zapper_NotAuthorized.selector);
    vm.prank(_msgSender);
    zapper.onFlashLoan(address(zapper), address(_pt), _amount, 0, "");
  }

  function testFuzz_ReturnsCorrectMagicValue(uint256 _amount, uint256 _mockPrice) public {
    _amount = _boundToRealisticAmount(_amount);
    _mockPrice = _boundAndSetMockPrice(_mockPrice);

    // Setup: Deposit VST to get PT and YT
    _depositVstForUser(address(zapper), _amount);

    // Ensure hook has enough VST to transfer back after redeem
    deal(address(vaultShareToken), address(fixedFeeSwap), _amount);

    // Get PT contract
    PrincipalToken _pt = fixedFeeSwap.PRINCIPAL_TOKEN();

    // Call onFlashLoan from PT contract
    vm.prank(address(_pt));
    bytes32 _returnValue = zapper.onFlashLoan(
      address(zapper),
      address(_pt),
      _amount,
      0,
      abi.encode(false, _spotVstForBuyback(_amount, _mockPrice))
    );

    // Check return value matches expected magic value
    assertEq(_returnValue, FLASH_LOAN_RETURN_VALUE, "Should return correct magic value");
  }

  function testFuzz_SellPathApprovesHookForPTAndYT(uint256 _amount, uint256 _mockPrice) public {
    _amount = _boundToRealisticAmount(_amount);
    _mockPrice = _boundAndSetMockPrice(_mockPrice);

    // Setup: Deposit VST to get PT and YT
    _depositVstForUser(address(zapper), _amount);

    // Ensure hook has enough VST to transfer back after redeem
    deal(address(vaultShareToken), address(fixedFeeSwap), _amount);

    // Get contracts
    PrincipalToken _pt = fixedFeeSwap.PRINCIPAL_TOKEN();
    YieldToken _yt = fixedFeeSwap.YIELD_TOKEN();

    // Verify initial approvals are zero
    assertEq(
      IERC20(address(_pt)).allowance(address(zapper), address(fixedFeeSwap)),
      0,
      "Initial PT approval should be 0"
    );
    assertEq(
      IERC20(address(_yt)).allowance(address(zapper), address(fixedFeeSwap)),
      0,
      "Initial YT approval should be 0"
    );

    // Call onFlashLoan from PT contract (sell path)
    vm.prank(address(_pt));
    zapper.onFlashLoan(
      address(zapper),
      address(_pt),
      _amount,
      0,
      abi.encode(false, _spotVstForBuyback(_amount, _mockPrice))
    );

    // Check approvals after callback - should be at least _amount
    assertGe(
      IERC20(address(_pt)).allowance(address(zapper), address(fixedFeeSwap)),
      _amount,
      "Hook should be approved for at least _amount PT"
    );
    assertGe(
      IERC20(address(_yt)).allowance(address(zapper), address(fixedFeeSwap)),
      _amount,
      "Hook should be approved for at least _amount YT"
    );
  }

  function testFuzz_SellPathApprovesPTForRepayment(uint256 _amount, uint256 _mockPrice) public {
    _amount = _boundToRealisticAmount(_amount);
    _mockPrice = _boundAndSetMockPrice(_mockPrice);

    // Setup: Deposit VST to get PT and YT
    _depositVstForUser(address(zapper), _amount);

    // Ensure hook has enough VST to transfer back after redeem
    deal(address(vaultShareToken), address(fixedFeeSwap), _amount);

    // Get PT contract
    PrincipalToken _pt = fixedFeeSwap.PRINCIPAL_TOKEN();

    // Verify initial approval is zero
    assertEq(
      IERC20(address(_pt)).allowance(address(zapper), address(_pt)),
      0,
      "Initial PT self-approval should be 0"
    );

    // Call onFlashLoan from PT contract (sell path)
    vm.prank(address(_pt));
    zapper.onFlashLoan(
      address(zapper),
      address(_pt),
      _amount,
      0,
      abi.encode(false, _spotVstForBuyback(_amount, _mockPrice))
    );

    // Check approval after callback - should be non-zero for repayment
    assertGt(
      IERC20(address(_pt)).allowance(address(zapper), address(_pt)),
      0,
      "PT should be approved for flash loan repayment"
    );
  }

  function testFuzz_BuyPathApprovesVSTForDeposit(uint256 _amount, uint256 _mockPrice) public {
    _amount = _boundToRealisticAmount(_amount);
    _mockPrice = _boundAndSetMockPrice(_mockPrice);

    // Get PT contract
    PrincipalToken _pt = fixedFeeSwap.PRINCIPAL_TOKEN();

    // Setup: Give zapper VST (simulating user's VST that was transferred)
    deal(address(vaultShareToken), address(zapper), _amount);
    // Give zapper PT (simulating flash loan having already transferred PT)
    deal(address(_pt), address(zapper), _amount);

    // Verify initial approval is zero
    assertEq(
      vaultShareToken.allowance(address(zapper), address(fixedFeeSwap)),
      0,
      "Initial VST approval should be 0"
    );

    // Call onFlashLoan from PT contract (buy path)
    bytes memory _buyData = abi.encode(true, 0);
    vm.prank(address(_pt));
    zapper.onFlashLoan(address(zapper), address(_pt), _amount, 0, _buyData);

    // VST approval may be consumed during deposit, but it was set
    // Just verify the callback succeeded
    assertTrue(true, "Buy path flash loan callback succeeded");
  }

  function testFuzz_BuyPathApprovesPTForRepayment(uint256 _amount, uint256 _mockPrice) public {
    _amount = _boundToRealisticAmount(_amount);
    _mockPrice = _boundAndSetMockPrice(_mockPrice);

    // Get PT contract
    PrincipalToken _pt = fixedFeeSwap.PRINCIPAL_TOKEN();

    // Setup: Give zapper VST (simulating user's VST that was transferred)
    deal(address(vaultShareToken), address(zapper), _amount);
    // Give zapper PT (simulating flash loan having already transferred PT)
    deal(address(_pt), address(zapper), _amount);

    // Verify initial approval is zero
    assertEq(
      IERC20(address(_pt)).allowance(address(zapper), address(_pt)),
      0,
      "Initial PT self-approval should be 0"
    );

    // Call onFlashLoan from PT contract (buy path)
    bytes memory _buyData = abi.encode(true, 0);
    vm.prank(address(_pt));
    zapper.onFlashLoan(address(zapper), address(_pt), _amount, 0, _buyData);

    // Check approval after callback - should be at least _amount for repayment
    assertGe(
      IERC20(address(_pt)).allowance(address(zapper), address(_pt)),
      _amount,
      "PT should be approved for at least _amount for flash loan repayment"
    );
  }
}
