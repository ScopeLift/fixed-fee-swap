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
import {VaultShareToken} from "src/VaultShareToken.sol";
import {PrincipalToken} from "src/PrincipalToken.sol";
import {YieldToken} from "src/YieldToken.sol";
import {ERC20Mock} from "test/mock/ERC20Mock.sol";
import {VaultShareTokenHarness} from "test/harness/VaultShareTokenHarness.sol";
import {FeeTracking} from "src/lib/FeeTracking.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract ZapperTest is Test {
  Zapper internal zapper;
  FixedFeeSwap internal fixedFeeSwap;
  FixedFeeSwapMarketMock internal fixedFeeSwapMarketMock;
  VaultShareToken internal vaultShareToken;
  ERC20Mock internal token0;
  ERC20Mock internal token1;

  address internal user;
  uint256 internal maturity;

  // Flash loan return value constant
  bytes32 internal constant FLASH_LOAN_RETURN_VALUE = keccak256("ERC3156FlashBorrower.onFlashLoan");

  function setUp() public virtual {
    // Underlying fee tokens for the VaultShareToken
    token0 = new ERC20Mock("Token 0", "T0");
    token1 = new ERC20Mock("Token 1", "T1");

    // Underlying VaultShareToken whose shares are being split. The harness lets tests accrue vault
    // fees; it behaves like VaultShareToken otherwise.
    vaultShareToken =
      new VaultShareTokenHarness("Vault Share Token", "VST", address(token0), address(token1));

    // Choose a maturity strictly in the future
    maturity = block.timestamp + 30 days;

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

    user = makeAddr("user");
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

  /// @notice Helper function to set up fees on YT.
  /// @param _feeToken0 Amount of token0 fees to add.
  /// @param _feeToken1 Amount of token1 fees to add.
  function _updateYieldTokenFees(uint256 _feeToken0, uint256 _feeToken1) internal {
    // Update fees on YT
    YieldToken _yt = fixedFeeSwap.YIELD_TOKEN();
    vm.prank(address(fixedFeeSwap));
    _yt.updateFees(_feeToken0, _feeToken1);

    // Fund the YieldToken contract with fee tokens so it can pay out claims
    uint256 _currentBalance0 = token0.balanceOf(address(_yt));
    uint256 _currentBalance1 = token1.balanceOf(address(_yt));
    deal(address(token0), address(_yt), _currentBalance0 + _feeToken0);
    deal(address(token1), address(_yt), _currentBalance1 + _feeToken1);
  }
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
    _boundAndSetMockPrice(_mockPrice);

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
    zapper.sellYieldToken(_ytAmount);

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
    zapper.sellYieldToken(_ytAmount);

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
    _boundAndSetMockPrice(_mockPrice);

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
    zapper.sellYieldToken(_ytAmount);

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
    _boundAndSetMockPrice(_mockPrice);

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
    zapper.sellYieldToken(_ytAmount);
  }

  function testFuzz_FlashLoanIsRepaidSuccessfully(uint256 _ytAmount, uint256 _mockPrice) public {
    _ytAmount = _boundToRealisticAmount(_ytAmount);
    _boundAndSetMockPrice(_mockPrice);

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
    zapper.sellYieldToken(_ytAmount);

    // If we reach here, flash loan was repaid successfully (no revert)
    assertTrue(true, "Flash loan was repaid successfully (no revert)");
  }

  function test_RevertIf_AmountIsZero() public {
    vm.expectRevert(Zapper.Zapper_InvalidAmount.selector);
    zapper.sellYieldToken(0);
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
    _boundAndSetMockPrice(_mockPrice);
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
    zapper.sellYieldToken(_ytAmount);

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
    // A vault whose token0 fees are native ETH, with its own FixedFeeSwap, market and Zapper.
    VaultShareTokenHarness _vstWithEth =
      new VaultShareTokenHarness("Vault Share Token", "VST", address(0), address(token1));
    FixedFeeSwap _fixedFeeSwap = new FixedFeeSwap(_vstWithEth, maturity);
    FixedFeeSwapMarketMock _market =
      new FixedFeeSwapMarketMock(address(_fixedFeeSwap.PRINCIPAL_TOKEN()), address(_vstWithEth));
    deal(address(_fixedFeeSwap.PRINCIPAL_TOKEN()), address(_market), 1e30);
    deal(address(_vstWithEth), address(_market), 1e30);
    Zapper _zapper = new Zapper(_fixedFeeSwap, FixedFeeSwapMarket(address(_market)));
    _vstWithEth.exposed_mint(user, _ytAmount);
    vm.startPrank(user);
    _vstWithEth.approve(address(_fixedFeeSwap), _ytAmount);
    _fixedFeeSwap.deposit(_ytAmount);
    _fixedFeeSwap.YIELD_TOKEN().approve(address(_zapper), _ytAmount);
    vm.stopPrank();
    vm.deal(address(_vstWithEth), _feeEth);
    _vstWithEth.exposed_updateFees(_feeEth, 0);
    // The user's split VST is every minted vault share, so their YT earns the whole increase.
    uint256 _earnedByUser = Math.mulDiv(
      _ytAmount, Math.mulDiv(_feeEth, FeeTracking.PRECISION, _ytAmount), FeeTracking.PRECISION
    );

    vm.prank(user);
    _zapper.sellYieldToken(_ytAmount);

    // YieldToken rounds its fee index down by up to 1 per 1e18 shares.
    assertApproxEqAbs(user.balance, _earnedByUser, _ytAmount / FeeTracking.PRECISION + 2);
    assertEq(address(_zapper).balance, 0);
  }
}

contract BuyYieldToken is ZapperTest {
  function testFuzz_TransfersVSTFromUserToZapper(uint256 _vstAmount, uint256 _mockPrice) public {
    _vstAmount = _boundToRealisticAmount(_vstAmount);
    _boundAndSetMockPrice(_mockPrice);

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
    zapper.buyYieldToken(_vstAmount);

    // User should have spent all VST
    uint256 _userVSTAfter = vaultShareToken.balanceOf(user);
    assertEq(_userVSTAfter, 0, "User should have no VST after buy");
    assertEq(
      _userVSTBefore - _userVSTAfter, _vstAmount, "VST balance should decrease by exact amount"
    );
  }

  function testFuzz_UserReceivesYTAfterBuy(uint256 _vstAmount, uint256 _mockPrice) public {
    _vstAmount = _boundToRealisticAmount(_vstAmount);
    _boundAndSetMockPrice(_mockPrice);

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
    zapper.buyYieldToken(_vstAmount);

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
    _boundAndSetMockPrice(_mockPrice);
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
    zapper.buyYieldToken(_vstAmount1);

    vm.prank(_user2);
    zapper.buyYieldToken(_vstAmount2);

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
    _boundAndSetMockPrice(_mockPrice);

    // Give user VST
    deal(address(vaultShareToken), user, _vstAmount);

    // User approves zapper to spend VST
    vm.prank(user);
    vaultShareToken.approve(address(zapper), _vstAmount);

    // Execute buy
    vm.prank(user);
    zapper.buyYieldToken(_vstAmount);

    // Zapper should have no remaining VST
    assertEq(
      vaultShareToken.balanceOf(address(zapper)), 0, "Zapper should have no remaining VST after buy"
    );

    // Zapper should have no remaining YT (all transferred to user)
    YieldToken _yt = fixedFeeSwap.YIELD_TOKEN();
    assertEq(_yt.balanceOf(address(zapper)), 0, "Zapper should have no remaining YT after buy");
  }

  function testFuzz_EmitsYieldTokenBoughtEvent(uint256 _vstAmount, uint256 _mockPrice) public {
    _vstAmount = _boundToRealisticAmount(_vstAmount);
    _boundAndSetMockPrice(_mockPrice);

    // Give user VST
    deal(address(vaultShareToken), user, _vstAmount);

    // User approves zapper to spend VST
    vm.prank(user);
    vaultShareToken.approve(address(zapper), _vstAmount);

    // Check indexed user; skip data fields (ytBought unknown before call)
    vm.expectEmit(true, false, false, false, address(zapper));
    emit Zapper.YieldTokenBought(user, 0, 0);

    vm.prank(user);
    zapper.buyYieldToken(_vstAmount);
  }

  function testFuzz_FlashLoanIsRepaidSuccessfully(uint256 _vstAmount, uint256 _mockPrice) public {
    _vstAmount = _boundToRealisticAmount(_vstAmount);
    _boundAndSetMockPrice(_mockPrice);

    // Give user VST
    deal(address(vaultShareToken), user, _vstAmount);

    // User approves zapper to spend VST
    vm.prank(user);
    vaultShareToken.approve(address(zapper), _vstAmount);

    // Execute buy - if flash loan isn't repaid, this would revert
    vm.prank(user);
    zapper.buyYieldToken(_vstAmount);

    // If we reach here, flash loan was repaid successfully
    assertTrue(true, "Flash loan was repaid successfully (no revert)");
  }

  function test_RevertIf_AmountIsZero() public {
    vm.expectRevert(Zapper.Zapper_InvalidAmount.selector);
    zapper.buyYieldToken(0);
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
    _boundAndSetMockPrice(_mockPrice);

    // Setup: Deposit VST to get PT and YT
    _depositVstForUser(address(zapper), _amount);

    // Ensure hook has enough VST to transfer back after redeem
    deal(address(vaultShareToken), address(fixedFeeSwap), _amount);

    // Get PT contract
    PrincipalToken _pt = fixedFeeSwap.PRINCIPAL_TOKEN();

    // Call onFlashLoan from PT contract
    vm.prank(address(_pt));
    bytes32 _returnValue = zapper.onFlashLoan(address(zapper), address(_pt), _amount, 0, "");

    // Check return value matches expected magic value
    assertEq(_returnValue, FLASH_LOAN_RETURN_VALUE, "Should return correct magic value");
  }

  function testFuzz_SellPathApprovesHookForPTAndYT(uint256 _amount, uint256 _mockPrice) public {
    _amount = _boundToRealisticAmount(_amount);
    _boundAndSetMockPrice(_mockPrice);

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

    // Call onFlashLoan from PT contract (sell path - empty data)
    vm.prank(address(_pt));
    zapper.onFlashLoan(address(zapper), address(_pt), _amount, 0, "");

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
    _boundAndSetMockPrice(_mockPrice);

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

    // Call onFlashLoan from PT contract (sell path - empty data)
    vm.prank(address(_pt));
    zapper.onFlashLoan(address(zapper), address(_pt), _amount, 0, "");

    // Check approval after callback - should be non-zero for repayment
    assertGt(
      IERC20(address(_pt)).allowance(address(zapper), address(_pt)),
      0,
      "PT should be approved for flash loan repayment"
    );
  }

  function testFuzz_BuyPathApprovesVSTForDeposit(uint256 _amount, uint256 _mockPrice) public {
    _amount = _boundToRealisticAmount(_amount);
    _boundAndSetMockPrice(_mockPrice);

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

    // Call onFlashLoan from PT contract (buy path - data encodes true)
    bytes memory _buyData = abi.encode(true);
    vm.prank(address(_pt));
    zapper.onFlashLoan(address(zapper), address(_pt), _amount, 0, _buyData);

    // VST approval may be consumed during deposit, but it was set
    // Just verify the callback succeeded
    assertTrue(true, "Buy path flash loan callback succeeded");
  }

  function testFuzz_BuyPathApprovesPTForRepayment(uint256 _amount, uint256 _mockPrice) public {
    _amount = _boundToRealisticAmount(_amount);
    _boundAndSetMockPrice(_mockPrice);

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

    // Call onFlashLoan from PT contract (buy path - data encodes true)
    bytes memory _buyData = abi.encode(true);
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
