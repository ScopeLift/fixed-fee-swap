// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {Test, Vm} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Internal imports
import {FixedFeeSwap} from "src/FixedFeeSwap.sol";
import {VaultShareToken} from "src/VaultShareToken.sol";
import {PrincipalToken} from "src/PrincipalToken.sol";
import {YieldToken} from "src/YieldToken.sol";
import {FeeTracking} from "src/lib/FeeTracking.sol";
import {ERC20Mock} from "test/mock/ERC20Mock.sol";
import {NonPayableContractMock} from "test/mock/NonPayableContractMock.sol";
import {VaultShareTokenHarness} from "test/harness/VaultShareTokenHarness.sol";

contract FixedFeeSwapTest is Test {
  /// @notice Native ETH address following Uniswap v4 `Currency` convention.
  /// @dev See: https://github.com/Uniswap/v4-core/blob/main/src/types/Currency.sol#L37-L38
  address internal constant NATIVE = address(0);

  FixedFeeSwap internal fixedFeeSwap;
  VaultShareToken internal vaultShareToken;
  ERC20Mock internal token0;
  ERC20Mock internal token1;

  address internal user;
  address internal userB;

  uint256 internal maturity;

  function setUp() public virtual {
    // Underlying fee tokens for the VaultShareToken
    token0 = new ERC20Mock("Token 0", "T0");
    token1 = new ERC20Mock("Token 1", "T1");

    // Underlying VaultShareToken whose shares are being split (use harness for fee testing)
    vaultShareToken =
      new VaultShareTokenHarness("Vault Share Token", "VST", address(token0), address(token1));

    // Choose a maturity strictly in the future
    maturity = block.timestamp + 30 days;

    fixedFeeSwap = new FixedFeeSwap(vaultShareToken, maturity);

    user = makeAddr("user");
    userB = makeAddr("userB");
  }

  function _assumeSafeAddress(address _addr) internal pure {
    vm.assume(_addr != address(0));
  }

  /// @notice Assumes the address is safe for native ETH transfers.
  /// @param _address The address to check.
  /// @dev Excludes precompile addresses and known problematic addresses (like console).
  ///      Allows both EOAs and contracts (contracts that can receive ETH will succeed,
  ///      contracts that can't will fail, which is tested separately).
  function _assumeSafeAddressForEth(address _address) internal pure {
    vm.assume(_address != address(0));
    // Exclude the console address (used by forge-std for logging, cannot receive ETH)
    vm.assume(_address != address(0x000000000000000000636F6e736F6c652e6c6f67));
    // Exclude precompile addresses (0x01-0x0F) which cannot receive ETH
    vm.assume(_address > address(0x0F));
  }

  function _boundToRealisticAmount(uint256 _amount) internal pure returns (uint256) {
    return bound(_amount, 1, type(uint128).max);
  }

  function _assumeSafeMaturity(uint256 _maturity) internal view {
    vm.assume(_maturity > block.timestamp);
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

  // At most 1e30 so that a fee of at least 1e18 raises the vault's fee index by at least 1e6 per
  // share, and the fee owed on these shares never rounds to zero.
  function _boundToFeeEarningDeposit(uint256 _amount) internal pure returns (uint256) {
    return bound(_amount, 1, 1e30);
  }

  // At least 1e18 so that the fee index rises on any deposit `_boundToFeeEarningDeposit` allows.
  function _boundToFeeAboveRounding(uint256 _fee) internal pure returns (uint256) {
    return bound(_fee, 1e18, type(uint128).max);
  }

  /// @notice Helper to fund the vault and update its fee indexes so collectFeesToYT can pull fees
  /// to the YT. @param _feeToken0 Amount of token0 fees to add (vault accounting).
  /// @param _feeToken1 Amount of token1 fees to add (vault accounting).
  function _updateYieldTokenFees(uint256 _feeToken0, uint256 _feeToken1) internal {
    uint256 _vault0 = token0.balanceOf(address(vaultShareToken));
    uint256 _vault1 = token1.balanceOf(address(vaultShareToken));
    deal(address(token0), address(vaultShareToken), _vault0 + _feeToken0);
    deal(address(token1), address(vaultShareToken), _vault1 + _feeToken1);
    VaultShareTokenHarness(address(vaultShareToken)).exposed_updateFees(_feeToken0, _feeToken1);
  }

  /// @notice Helper function to approve PT token for redeem.
  /// @param _user The address to approve for.
  /// @param _amount The amount to approve.
  function _approvePTForRedeem(address _user, uint256 _amount) internal {
    vm.prank(_user);
    fixedFeeSwap.PRINCIPAL_TOKEN().approve(address(fixedFeeSwap), _amount);
  }

  /// @notice Helper function to approve YT token for redeem.
  /// @param _user The address to approve for.
  /// @param _amount The amount to approve.
  function _approveYTForRedeem(address _user, uint256 _amount) internal {
    vm.prank(_user);
    fixedFeeSwap.YIELD_TOKEN().approve(address(fixedFeeSwap), _amount);
  }

  /// @notice Helper function to approve both PT and YT tokens for redeem.
  /// @param _user The address to approve for.
  /// @param _amount The amount to approve.
  function _approvePTAndYTForRedeem(address _user, uint256 _amount) internal {
    _approvePTForRedeem(_user, _amount);
    _approveYTForRedeem(_user, _amount);
  }
}

contract Constructor is FixedFeeSwapTest {
  function testFuzz_SetsInitialParameters(
    address _vaultShareToken0,
    address _vaultShareToken1,
    uint256 _maturity
  ) public {
    _assumeSafeAddress(_vaultShareToken0);
    _assumeSafeAddress(_vaultShareToken1);
    _assumeSafeMaturity(_maturity);

    VaultShareToken _vaultShareToken =
      new VaultShareToken("Vault Share Token", "VST", _vaultShareToken0, _vaultShareToken1);

    FixedFeeSwap _hook = new FixedFeeSwap(VaultShareToken(_vaultShareToken), _maturity);

    assertEq(address(_hook.VAULT_SHARE_TOKEN()), address(_vaultShareToken));
    assertEq(_hook.MATURITY(), _maturity);

    PrincipalToken _pt = _hook.PRINCIPAL_TOKEN();
    YieldToken _yt = _hook.YIELD_TOKEN();
    assertTrue(address(_pt) != address(0));
    assertTrue(address(_yt) != address(0));

    string memory _underlyingName = _vaultShareToken.name();
    string memory _underlyingSymbol = _vaultShareToken.symbol();

    assertEq(_pt.name(), string.concat("Principal ", _underlyingName));
    assertEq(_pt.symbol(), string.concat("PT-", _underlyingSymbol, "-", vm.toString(_maturity)));

    assertEq(_yt.name(), string.concat("Yield ", _underlyingName));
    assertEq(_yt.symbol(), string.concat("YT-", _underlyingSymbol, "-", vm.toString(_maturity)));

    assertEq(_pt.FIXED_FEE_SWAP(), address(_hook));
    assertEq(_yt.FIXED_FEE_SWAP(), address(_hook));
  }

  function testFuzz_EmitsInitializedEvent(uint256 _maturity) public {
    _assumeSafeMaturity(_maturity);

    // Record logs to capture the event
    vm.recordLogs();

    // Deploy the hook (this will emit the Initialized event)
    FixedFeeSwap _hook = new FixedFeeSwap(vaultShareToken, _maturity);

    // Get the actual PT and YT addresses from the deployed hook
    address _ptAddress = address(_hook.PRINCIPAL_TOKEN());
    address _ytAddress = address(_hook.YIELD_TOKEN());

    // Verify the event was emitted with correct values
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    assertEq(_logs.length, 1);

    // Decode and verify the event
    bytes32 _eventSignature = keccak256("Initialized(address,address,address,uint256)");
    assertEq(_logs[0].topics[0], _eventSignature);

    // Decode the event data using abi.decode
    (
      address _vstAddress,
      address _ptAddressFromEvent,
      address _ytAddressFromEvent,
      uint256 _maturityFromEvent
    ) = abi.decode(_logs[0].data, (address, address, address, uint256));

    assertEq(_vstAddress, address(vaultShareToken));
    assertEq(_ptAddressFromEvent, _ptAddress);
    assertEq(_ytAddressFromEvent, _ytAddress);
    assertEq(_maturityFromEvent, _maturity);
  }

  function test_RevertIf_VaultShareTokenIsZero() public {
    vm.expectRevert(FixedFeeSwap.FixedFeeSwap_InvalidVaultShareToken.selector);
    new FixedFeeSwap(VaultShareToken(address(0)), maturity);
  }

  function testFuzz_RevertIf_MaturityInPast(uint256 _maturity) public {
    _maturity = bound(_maturity, 0, block.timestamp);

    vm.expectRevert(FixedFeeSwap.FixedFeeSwap_InvalidMaturity.selector);
    new FixedFeeSwap(vaultShareToken, _maturity);
  }
}

contract Deposit is FixedFeeSwapTest {
  function testFuzz_SplitsVaultShareTokenToPTAndYT(uint256 _amount) public {
    _amount = _boundToRealisticAmount(_amount);
    deal(address(vaultShareToken), user, _amount);

    uint256 _initialUserVstBalance = vaultShareToken.balanceOf(user);
    uint256 _initialHookVstBalance = vaultShareToken.balanceOf(address(fixedFeeSwap));
    uint256 _initialPtSupply = fixedFeeSwap.PRINCIPAL_TOKEN().totalSupply();
    uint256 _initialYtSupply = fixedFeeSwap.YIELD_TOKEN().totalSupply();
    uint256 _initialPtUserBalance = fixedFeeSwap.PRINCIPAL_TOKEN().balanceOf(user);
    uint256 _initialYtUserBalance = fixedFeeSwap.YIELD_TOKEN().balanceOf(user);

    vm.prank(user);
    vaultShareToken.approve(address(fixedFeeSwap), _amount);

    vm.prank(user);
    fixedFeeSwap.deposit(_amount);

    assertEq(vaultShareToken.balanceOf(user), _initialUserVstBalance - _amount);
    assertEq(vaultShareToken.balanceOf(address(fixedFeeSwap)), _initialHookVstBalance + _amount);
    assertEq(fixedFeeSwap.PRINCIPAL_TOKEN().totalSupply(), _initialPtSupply + _amount);
    assertEq(fixedFeeSwap.YIELD_TOKEN().totalSupply(), _initialYtSupply + _amount);
    assertEq(fixedFeeSwap.PRINCIPAL_TOKEN().balanceOf(user), _initialPtUserBalance + _amount);
    assertEq(fixedFeeSwap.YIELD_TOKEN().balanceOf(user), _initialYtUserBalance + _amount);
  }

  function testFuzz_EmitsDepositEvent(uint256 _amount) public {
    _amount = _boundToRealisticAmount(_amount);
    deal(address(vaultShareToken), user, _amount);
    vm.prank(user);
    vaultShareToken.approve(address(fixedFeeSwap), _amount);

    vm.expectEmit();
    emit FixedFeeSwap.Deposit(user, _amount);
    vm.prank(user);
    fixedFeeSwap.deposit(_amount);
  }

  function testFuzz_UpdatesYTFeesOnDeposit(uint256 _depositAmount, uint256 _collectedFeeToken0)
    public
  {
    _depositAmount = _boundToRealisticAmount(_depositAmount);
    _collectedFeeToken0 = _boundToRealisticAmount(_collectedFeeToken0);
    // Ignore cases where no new vault fees are added.
    vm.assume(_collectedFeeToken0 > 0);

    VaultShareTokenHarness _vstHarness = VaultShareTokenHarness(address(vaultShareToken));

    // First deposit: move VST from user into the hook and mint PT/YT.
    _vstHarness.exposed_mint(user, _depositAmount);
    vm.prank(user);
    vaultShareToken.approve(address(fixedFeeSwap), _depositAmount);
    vm.prank(user);
    fixedFeeSwap.deposit(_depositAmount);

    YieldToken _yt = fixedFeeSwap.YIELD_TOKEN();

    // Record YT fee index before updating vault fees.
    uint256 _ytIndex0Before = _yt.globalFeeIndex0Scaled();

    // Simulate new vault fees accruing to VST.
    _vstHarness.exposed_updateFees(_collectedFeeToken0, 0);

    // Second deposit triggers `_syncFees` before doing the split.
    uint256 _secondDeposit = _boundToRealisticAmount(_depositAmount);
    _vstHarness.exposed_mint(user, _secondDeposit);
    vm.prank(user);
    vaultShareToken.approve(address(fixedFeeSwap), _secondDeposit);

    vm.prank(user);
    fixedFeeSwap.deposit(_secondDeposit);

    // YT fee index should never go down; when fees are non-zero it should stay the same or
    // increase.
    uint256 _ytIndex0After = _yt.globalFeeIndex0Scaled();
    assertGe(_ytIndex0After, _ytIndex0Before);
  }

  function testFuzz_RevertIf_DepositAfterMaturity(uint256 _amount) public {
    vm.warp(maturity + 1);
    vm.expectRevert(FixedFeeSwap.FixedFeeSwap_SplitAfterMaturity.selector);
    fixedFeeSwap.deposit(_amount);
  }

  function test_RevertIf_AmountIsZero() public {
    vm.expectRevert(FixedFeeSwap.FixedFeeSwap_InvalidAmount.selector);
    fixedFeeSwap.deposit(0);
  }

  function testFuzz_RevertIf_InsufficientAllowance(uint256 _amount, uint256 _approvalAmount)
    public
  {
    _amount = _boundToRealisticAmount(_amount);
    _approvalAmount = bound(_approvalAmount, 0, _amount - 1); // Approval must be less than amount

    deal(address(vaultShareToken), user, _amount);

    // Approve less than the deposit amount
    vm.prank(user);
    vaultShareToken.approve(address(fixedFeeSwap), _approvalAmount);

    // Attempt to deposit more than approved
    vm.prank(user);
    vm.expectRevert(
      abi.encodeWithSelector(
        IERC20Errors.ERC20InsufficientAllowance.selector,
        address(fixedFeeSwap),
        _approvalAmount,
        _amount
      )
    );
    fixedFeeSwap.deposit(_amount);
  }

  function testFuzz_RevertIf_InsufficientBalance(uint256 _amount, uint256 _userBalance) public {
    _amount = _boundToRealisticAmount(_amount);
    _userBalance = bound(_userBalance, 0, _amount - 1); // Balance must be less than amount

    // Give user less than the deposit amount
    deal(address(vaultShareToken), user, _userBalance);

    // Approve the full amount (even though user doesn't have it)
    vm.prank(user);
    vaultShareToken.approve(address(fixedFeeSwap), _amount);

    // Attempt to deposit more than user has
    vm.prank(user);
    vm.expectRevert(FixedFeeSwap.FixedFeeSwap_InsufficientBalance.selector);
    fixedFeeSwap.deposit(_amount);
  }
}

contract SyncFees is FixedFeeSwapTest {
  function testFuzz_NoOpWhenNoFeeIndexChange(uint256 _depositAmount) public {
    _depositAmount = bound(_depositAmount, 1, type(uint64).max);

    VaultShareTokenHarness _vstHarness = VaultShareTokenHarness(address(vaultShareToken));
    YieldToken _yt = fixedFeeSwap.YIELD_TOKEN();

    // First deposit syncs the checkpoint.
    _vstHarness.exposed_mint(user, _depositAmount * 2);
    vm.prank(user);
    vaultShareToken.approve(address(fixedFeeSwap), _depositAmount * 2);
    vm.prank(user);
    fixedFeeSwap.deposit(_depositAmount);

    uint256 _ytIndexBefore = _yt.globalFeeIndex0Scaled();

    // Second deposit WITHOUT updating VST fees - delta is 0, so YT index unchanged.
    vm.prank(user);
    fixedFeeSwap.deposit(_depositAmount);

    assertEq(_yt.globalFeeIndex0Scaled(), _ytIndexBefore);
  }

  function testFuzz_NoOpWhenZeroVSTBalance(uint256 _depositAmount, uint256 _feeAmount) public {
    _depositAmount = _boundToRealisticAmount(_depositAmount);
    _feeAmount = _boundToRealisticAmount(_feeAmount);
    vm.assume(_feeAmount > 0);

    VaultShareTokenHarness _vstHarness = VaultShareTokenHarness(address(vaultShareToken));
    YieldToken _yt = fixedFeeSwap.YIELD_TOKEN();

    // Update VST fees BEFORE any deposit (so delta > 0 but hook has 0 VST).
    _vstHarness.exposed_updateFees(_feeAmount, 0);

    uint256 _ytIndexBefore = _yt.globalFeeIndex0Scaled(); // Should be 0

    // Deposit triggers _syncFees, but hook has 0 VST, so early return.
    _vstHarness.exposed_mint(user, _depositAmount);
    vm.prank(user);
    vaultShareToken.approve(address(fixedFeeSwap), _depositAmount);
    vm.prank(user);
    fixedFeeSwap.deposit(_depositAmount);

    // YT index should still be 0 because _vstBalance was 0 during _syncFees.
    assertEq(_yt.globalFeeIndex0Scaled(), _ytIndexBefore);
  }
}

contract ClaimYTFeesAfterMaturity is FixedFeeSwapTest {
  function testFuzz_SuccessfulClaim_BurnsTokensAndClaimsFees(
    uint256 _depositAmount,
    uint256 _feeToken0,
    uint256 _feeToken1
  ) public {
    _depositAmount = _boundToRealisticAmount(_depositAmount);
    _feeToken0 = _boundToRealisticAmount(_feeToken0);
    _feeToken1 = _boundToRealisticAmount(_feeToken1);

    // Set up: user deposits VST to get PT and YT before maturity
    _depositVstForUser(user, _depositAmount);

    // Set up fees before maturity
    _updateYieldTokenFees(_feeToken0, _feeToken1);

    // Sync user fees by doing a 0-value transfer (this updates their accrued fees)
    vm.prank(user);
    fixedFeeSwap.YIELD_TOKEN().transfer(user, 0);

    // Get user's accrued fees before claiming
    (,, uint256 _accruedToken0, uint256 _accruedToken1) = fixedFeeSwap.YIELD_TOKEN().userFees(user);

    // Move past maturity
    vm.warp(maturity + 1);

    uint256 _ytBalance = fixedFeeSwap.YIELD_TOKEN().balanceOf(user);
    uint256 _initialYtSupply = fixedFeeSwap.YIELD_TOKEN().totalSupply();
    uint256 _initialUserToken0Balance = token0.balanceOf(user);
    uint256 _initialUserToken1Balance = token1.balanceOf(user);

    // Claim and burn
    vm.prank(user);
    fixedFeeSwap.claimYTFeesAfterMaturity();

    // Check tokens are burnt
    assertEq(fixedFeeSwap.YIELD_TOKEN().balanceOf(user), 0);
    assertEq(fixedFeeSwap.YIELD_TOKEN().totalSupply(), _initialYtSupply - _ytBalance);

    // Check fees are claimed (should match accrued fees)
    assertEq(token0.balanceOf(user), _initialUserToken0Balance + _accruedToken0);
    assertEq(token1.balanceOf(user), _initialUserToken1Balance + _accruedToken1);
  }

  function testFuzz_UpdatesYTFeesOnClaim(uint256 _depositAmount, uint256 _collectedFeeToken0)
    public
  {
    _depositAmount = _boundToRealisticAmount(_depositAmount);
    _collectedFeeToken0 = _boundToRealisticAmount(_collectedFeeToken0);
    // Ignore cases where no new vault fees are added.
    vm.assume(_collectedFeeToken0 > 0);

    VaultShareTokenHarness _vstHarness = VaultShareTokenHarness(address(vaultShareToken));

    // User deposits VST and receives PT/YT before maturity.
    _vstHarness.exposed_mint(user, _depositAmount);
    vm.prank(user);
    vaultShareToken.approve(address(fixedFeeSwap), _depositAmount);
    vm.prank(user);
    fixedFeeSwap.deposit(_depositAmount);

    YieldToken _yt = fixedFeeSwap.YIELD_TOKEN();

    // Record YT fee index before updating vault fees.
    uint256 _ytIndex0Before = _yt.globalFeeIndex0Scaled();

    // Fund vault and update vault fees so collectFeesToYT can pull to YT when user claims.
    _updateYieldTokenFees(_collectedFeeToken0, 0);

    // Move past maturity so `claimYTFeesAfterMaturity` is enabled.
    vm.warp(maturity + 1);

    // This call runs `_syncFees` then burns YT, which claims fees.
    vm.prank(user);
    fixedFeeSwap.claimYTFeesAfterMaturity();
    // YT fee index should never decrease; when fees are non-zero it should stay the same or
    // increase.
    uint256 _ytIndex0After = _yt.globalFeeIndex0Scaled();
    assertGe(_ytIndex0After, _ytIndex0Before);
  }

  function testFuzz_RevertIf_BalanceIsZero(address _newUser) public {
    _assumeSafeAddress(_newUser);
    // Ensure the user doesn't have any YT tokens
    vm.assume(fixedFeeSwap.YIELD_TOKEN().balanceOf(_newUser) == 0);

    // Move past maturity
    vm.warp(maturity + 1);

    // User has no YT tokens (they were already burned or never had any)
    vm.prank(_newUser);
    vm.expectRevert(FixedFeeSwap.FixedFeeSwap_InvalidAmount.selector);
    fixedFeeSwap.claimYTFeesAfterMaturity();
  }

  function testFuzz_RevertIf_MaturityNotHit(uint256 _depositAmount, uint256 _secondsBeforeMaturity)
    public
  {
    _depositAmount = _boundToRealisticAmount(_depositAmount);
    _secondsBeforeMaturity = bound(_secondsBeforeMaturity, 1, maturity - block.timestamp);

    // Set up: user deposits VST to get PT and YT before maturity
    _depositVstForUser(user, _depositAmount);

    // Try to claim before maturity
    vm.warp(maturity - _secondsBeforeMaturity);

    vm.prank(user);
    vm.expectRevert(FixedFeeSwap.FixedFeeSwap_BeforeMaturity.selector);
    fixedFeeSwap.claimYTFeesAfterMaturity();
  }

  function testFuzz_SucceedsAtExactlyMaturity(
    uint256 _depositAmount,
    uint256 _feeToken0,
    uint256 _feeToken1
  ) public {
    _depositAmount = _boundToRealisticAmount(_depositAmount);
    _feeToken0 = _boundToRealisticAmount(_feeToken0);
    _feeToken1 = _boundToRealisticAmount(_feeToken1);

    // Set up: user deposits VST to get PT and YT before maturity
    _depositVstForUser(user, _depositAmount);

    // Set up fees before maturity
    _updateYieldTokenFees(_feeToken0, _feeToken1);

    // Sync user fees
    vm.prank(user);
    fixedFeeSwap.YIELD_TOKEN().transfer(user, 0);

    // Get user's accrued fees before claiming
    (,, uint256 _accruedToken0, uint256 _accruedToken1) = fixedFeeSwap.YIELD_TOKEN().userFees(user);

    // Try to claim exactly at maturity (should succeed since we check <, not <=)
    vm.warp(maturity);

    uint256 _ytBalance = fixedFeeSwap.YIELD_TOKEN().balanceOf(user);
    uint256 _initialYtSupply = fixedFeeSwap.YIELD_TOKEN().totalSupply();
    uint256 _initialUserToken0Balance = token0.balanceOf(user);
    uint256 _initialUserToken1Balance = token1.balanceOf(user);

    // Should succeed at exactly maturity
    vm.prank(user);
    fixedFeeSwap.claimYTFeesAfterMaturity();

    // Check tokens are burnt
    assertEq(fixedFeeSwap.YIELD_TOKEN().balanceOf(user), 0);
    assertEq(fixedFeeSwap.YIELD_TOKEN().totalSupply(), _initialYtSupply - _ytBalance);

    // Check fees are claimed (should match accrued fees)
    assertEq(token0.balanceOf(user), _initialUserToken0Balance + _accruedToken0);
    assertEq(token1.balanceOf(user), _initialUserToken1Balance + _accruedToken1);
  }

  function testFuzz_PaysPreMaturityFeesAfterAnotherHolderRedeemsAtMaturity(
    uint256 _depositAmount,
    uint256 _otherDepositAmount,
    uint256 _feeToken0,
    uint256 _feeToken1
  ) public {
    _depositAmount = _boundToFeeEarningDeposit(_depositAmount);
    _otherDepositAmount = _boundToFeeEarningDeposit(_otherDepositAmount);
    _feeToken0 = _boundToFeeAboveRounding(_feeToken0);
    _feeToken1 = _boundToFeeAboveRounding(_feeToken1);
    _mintVstAndDepositForUser(user, _depositAmount);
    _mintVstAndDepositForUser(userB, _otherDepositAmount);
    _updateYieldTokenFees(_feeToken0, _feeToken1);
    fixedFeeSwap.collectFeesToYT();
    YieldToken _yieldToken = fixedFeeSwap.YIELD_TOKEN();
    // A zero transfer checkpoints the user's accrued fees so the test can read them.
    vm.prank(user);
    _yieldToken.transfer(user, 0);
    (,, uint256 _accruedToken0, uint256 _accruedToken1) = _yieldToken.userFees(user);
    vm.warp(maturity);

    vm.prank(userB);
    fixedFeeSwap.redeem(_otherDepositAmount);
    uint256 _token0Before = token0.balanceOf(user);
    uint256 _token1Before = token1.balanceOf(user);
    vm.prank(user);
    fixedFeeSwap.claimYTFeesAfterMaturity();

    assertEq(token0.balanceOf(user), _token0Before + _accruedToken0);
    assertEq(token1.balanceOf(user), _token1Before + _accruedToken1);
  }
}

contract TransferFeesToUser is FixedFeeSwapTest {
  function testFuzz_RevertIf_CallerIsNotYieldToken(
    address _caller,
    address _user,
    uint256 _amount0,
    uint256 _amount1
  ) public {
    vm.assume(_caller != address(fixedFeeSwap.YIELD_TOKEN()));
    _assumeSafeAddress(_user);

    vm.expectRevert(FixedFeeSwap.FixedFeeSwap_NotAuthorized.selector);
    vm.prank(_caller);
    fixedFeeSwap.transferFeesToUser(_user, _amount0, _amount1);
  }

  function testFuzz_TransfersToken0ToUser(uint256 _amount0) public {
    _amount0 = _boundToRealisticAmount(_amount0);
    vm.assume(_amount0 > 0);

    // Fund the hook with token0
    token0.mint(address(fixedFeeSwap), _amount0);

    uint256 _initialUserBalance = token0.balanceOf(user);
    uint256 _initialHookBalance = token0.balanceOf(address(fixedFeeSwap));

    // Call as YieldToken
    vm.prank(address(fixedFeeSwap.YIELD_TOKEN()));
    fixedFeeSwap.transferFeesToUser(user, _amount0, 0);

    assertEq(token0.balanceOf(user), _initialUserBalance + _amount0);
    assertEq(token0.balanceOf(address(fixedFeeSwap)), _initialHookBalance - _amount0);
  }

  function testFuzz_TransfersToken1ToUser(uint256 _amount1) public {
    _amount1 = _boundToRealisticAmount(_amount1);
    vm.assume(_amount1 > 0);

    // Fund the hook with token1
    token1.mint(address(fixedFeeSwap), _amount1);

    uint256 _initialUserBalance = token1.balanceOf(user);
    uint256 _initialHookBalance = token1.balanceOf(address(fixedFeeSwap));

    // Call as YieldToken
    vm.prank(address(fixedFeeSwap.YIELD_TOKEN()));
    fixedFeeSwap.transferFeesToUser(user, 0, _amount1);

    assertEq(token1.balanceOf(user), _initialUserBalance + _amount1);
    assertEq(token1.balanceOf(address(fixedFeeSwap)), _initialHookBalance - _amount1);
  }

  function testFuzz_TransfersBothTokensToUser(uint256 _amount0, uint256 _amount1) public {
    _amount0 = _boundToRealisticAmount(_amount0);
    _amount1 = _boundToRealisticAmount(_amount1);
    vm.assume(_amount0 > 0 && _amount1 > 0);

    // Fund the hook with both tokens
    token0.mint(address(fixedFeeSwap), _amount0);
    token1.mint(address(fixedFeeSwap), _amount1);

    uint256 _initialUserBalance0 = token0.balanceOf(user);
    uint256 _initialUserBalance1 = token1.balanceOf(user);

    // Call as YieldToken
    vm.prank(address(fixedFeeSwap.YIELD_TOKEN()));
    fixedFeeSwap.transferFeesToUser(user, _amount0, _amount1);

    assertEq(token0.balanceOf(user), _initialUserBalance0 + _amount0);
    assertEq(token1.balanceOf(user), _initialUserBalance1 + _amount1);
  }

  function testFuzz_NoTransferWhenAmountsAreZero(address _user) public {
    _assumeSafeAddress(_user);

    uint256 _initialUserBalance0 = token0.balanceOf(_user);
    uint256 _initialUserBalance1 = token1.balanceOf(_user);

    // Call as YieldToken with zero amounts
    vm.prank(address(fixedFeeSwap.YIELD_TOKEN()));
    fixedFeeSwap.transferFeesToUser(_user, 0, 0);

    // Balances should remain unchanged
    assertEq(token0.balanceOf(_user), _initialUserBalance0);
    assertEq(token1.balanceOf(_user), _initialUserBalance1);
  }

  function testFuzz_TransfersNativeEthToUser(uint256 _ethAmount, uint256 _token1Amount) public {
    _ethAmount = _boundToRealisticAmount(_ethAmount);
    _token1Amount = _boundToRealisticAmount(_token1Amount);
    vm.assume(_ethAmount > 0);

    // Create a new VST with native ETH as token0
    VaultShareToken _vstWithEth =
      new VaultShareToken("Vault Share Token", "VST", NATIVE, address(token1));
    FixedFeeSwap _hookWithEth = new FixedFeeSwap(_vstWithEth, maturity);

    // Fund the hook with ETH
    vm.deal(address(_hookWithEth), _ethAmount);

    uint256 _initialUserEthBalance = user.balance;

    // Call as YieldToken
    vm.prank(address(_hookWithEth.YIELD_TOKEN()));
    _hookWithEth.transferFeesToUser(user, _ethAmount, 0);

    assertEq(user.balance, _initialUserEthBalance + _ethAmount);
  }

  function testFuzz_RevertIf_NativeEthTransferFails(uint256 _ethAmount) public {
    _ethAmount = bound(_ethAmount, 1, 1e27);

    // Create a new VST with native ETH as token0
    VaultShareToken _vstWithEth =
      new VaultShareToken("Vault Share Token", "VST", NATIVE, address(token1));
    FixedFeeSwap _hookWithEth = new FixedFeeSwap(_vstWithEth, maturity);

    // Deploy a contract that rejects ETH transfers
    NonPayableContractMock _nonPayable = new NonPayableContractMock();

    // Fund the hook with ETH
    vm.deal(address(_hookWithEth), _ethAmount);

    // Get YieldToken address before expectRevert (expectRevert catches the NEXT call)
    address _yieldToken = address(_hookWithEth.YIELD_TOKEN());

    // Should revert when trying to send ETH to non-payable contract
    vm.expectRevert(FixedFeeSwap.FixedFeeSwap_TransferFailed.selector);
    vm.prank(_yieldToken);
    _hookWithEth.transferFeesToUser(address(_nonPayable), _ethAmount, 0);
  }
}

contract CollectFeesToYT is FixedFeeSwapTest {
  function testFuzz_TransfersFeesToFixedFeeSwap(
    uint256 _depositAmount,
    uint256 _feeToken0,
    uint256 _feeToken1
  ) public {
    _depositAmount = _boundToRealisticAmount(_depositAmount);
    _feeToken0 = _boundToRealisticAmount(_feeToken0);
    _feeToken1 = _boundToRealisticAmount(_feeToken1);
    vm.assume(_feeToken0 > 0 || _feeToken1 > 0);
    // Avoid vault Floor rounding giving 0: need fee * 1e18 / supply >= 1 so index delta >= 1
    vm.assume(_depositAmount >= 1e18);
    vm.assume(_feeToken0 * 1e18 >= _depositAmount);
    vm.assume(_feeToken1 * 1e18 >= _depositAmount);

    // Mint VST via harness so vault totalSupply is set (deal does not update totalSupply)
    VaultShareTokenHarness(address(vaultShareToken)).exposed_mint(user, _depositAmount);
    vm.prank(user);
    vaultShareToken.approve(address(fixedFeeSwap), _depositAmount);
    vm.prank(user);
    fixedFeeSwap.deposit(_depositAmount);

    uint256 _hookBalance0Before = token0.balanceOf(address(fixedFeeSwap));
    uint256 _hookBalance1Before = token1.balanceOf(address(fixedFeeSwap));

    // Fund vault and update vault fee indexes
    _updateYieldTokenFees(_feeToken0, _feeToken1);

    // Anyone can call; fees move from vault -> FixedFeeSwap (held for YT holders to claim)
    fixedFeeSwap.collectFeesToYT();

    uint256 _hook0After = token0.balanceOf(address(fixedFeeSwap));
    uint256 _hook1After = token1.balanceOf(address(fixedFeeSwap));
    assertGe(_hook0After, _hookBalance0Before, "FixedFeeSwap should receive token0");
    assertGe(_hook1After, _hookBalance1Before, "FixedFeeSwap should receive token1");
    if (_feeToken0 > 0) assertGt(_hook0After, _hookBalance0Before, "token0 fees to FixedFeeSwap");
    if (_feeToken1 > 0) assertGt(_hook1After, _hookBalance1Before, "token1 fees to FixedFeeSwap");
  }

  function testFuzz_KeepsFeesCollectedBeforeMaturityClaimableByYieldTokenHolders(
    uint256 _depositAmount,
    uint256 _feeToken0,
    uint256 _feeToken1
  ) public {
    _depositAmount = _boundToFeeEarningDeposit(_depositAmount);
    _feeToken0 = _boundToFeeAboveRounding(_feeToken0);
    _feeToken1 = _boundToFeeAboveRounding(_feeToken1);
    _mintVstAndDepositForUser(user, _depositAmount);
    _updateYieldTokenFees(_feeToken0, _feeToken1);
    fixedFeeSwap.collectFeesToYT();
    YieldToken _yieldToken = fixedFeeSwap.YIELD_TOKEN();
    // A zero transfer checkpoints the user's accrued fees so the test can read them.
    vm.prank(user);
    _yieldToken.transfer(user, 0);
    (,, uint256 _accrued0, uint256 _accrued1) = _yieldToken.userFees(user);
    vm.warp(maturity + 1);

    vm.prank(user);
    fixedFeeSwap.claimYTFeesAfterMaturity();

    assertEq(token0.balanceOf(user), _accrued0);
    assertEq(token1.balanceOf(user), _accrued1);
  }

  function testFuzz_LeavesFeesEarnedAfterMaturityToPrincipalRedeemers(
    uint256 _depositAmount,
    uint256 _otherDepositAmount,
    uint256 _feeToken0,
    uint256 _feeToken1
  ) public {
    _depositAmount = _boundToFeeEarningDeposit(_depositAmount);
    _otherDepositAmount = _boundToFeeEarningDeposit(_otherDepositAmount);
    _feeToken0 = _boundToFeeAboveRounding(_feeToken0);
    _feeToken1 = _boundToFeeAboveRounding(_feeToken1);
    _mintVstAndDepositForUser(user, _depositAmount);
    _mintVstAndDepositForUser(userB, _otherDepositAmount);
    vm.warp(maturity);
    fixedFeeSwap.collectFeesToYT();
    _updateYieldTokenFees(_feeToken0, _feeToken1);
    uint256 _feeIndexIncrease0 =
      Math.mulDiv(_feeToken0, FeeTracking.PRECISION, vaultShareToken.totalSupply());
    uint256 _feeIndexIncrease1 =
      Math.mulDiv(_feeToken1, FeeTracking.PRECISION, vaultShareToken.totalSupply());

    fixedFeeSwap.collectFeesToYT();
    vm.prank(userB);
    fixedFeeSwap.redeem(_otherDepositAmount);

    assertEq(
      token0.balanceOf(userB),
      Math.mulDiv(_otherDepositAmount, _feeIndexIncrease0, FeeTracking.PRECISION)
    );
    assertEq(
      token1.balanceOf(userB),
      Math.mulDiv(_otherDepositAmount, _feeIndexIncrease1, FeeTracking.PRECISION)
    );
  }

  function testFuzz_CreditsNoFeeEarnedAfterMaturityToTheYieldToken(
    uint256 _depositAmount,
    uint256 _feeToken0,
    uint256 _feeToken1,
    uint256 _secondsAfterMaturity
  ) public {
    _depositAmount = _boundToFeeEarningDeposit(_depositAmount);
    _feeToken0 = _boundToFeeAboveRounding(_feeToken0);
    _feeToken1 = _boundToFeeAboveRounding(_feeToken1);
    _secondsAfterMaturity = bound(_secondsAfterMaturity, 0, 365 days);
    _mintVstAndDepositForUser(user, _depositAmount);
    // Someone acts at maturity, so every fee the vault reports afterwards was earned after it.
    vm.warp(maturity);
    fixedFeeSwap.collectFeesToYT();
    YieldToken _yieldToken = fixedFeeSwap.YIELD_TOKEN();
    uint256 _index0Before = _yieldToken.globalFeeIndex0Scaled();
    uint256 _index1Before = _yieldToken.globalFeeIndex1Scaled();

    vm.warp(maturity + _secondsAfterMaturity);
    _updateYieldTokenFees(_feeToken0, _feeToken1);
    fixedFeeSwap.collectFeesToYT();

    assertEq(_yieldToken.globalFeeIndex0Scaled(), _index0Before);
    assertEq(_yieldToken.globalFeeIndex1Scaled(), _index1Before);
  }
}

contract Redeem is FixedFeeSwapTest {
  function testFuzz_RedeemsBeforeMaturity(
    uint256 _depositAmount,
    uint256 _redeemAmount,
    uint256 _feeToken0,
    uint256 _feeToken1
  ) public {
    _depositAmount = _boundToRealisticAmount(_depositAmount);
    _redeemAmount = _boundToRealisticAmount(_redeemAmount);
    _feeToken0 = _boundToRealisticAmount(_feeToken0);
    _feeToken1 = _boundToRealisticAmount(_feeToken1);

    // Set up: user deposits VST to get PT and YT before maturity
    _depositVstForUser(user, _depositAmount);

    // Ensure redeem amount doesn't exceed user's balance
    // After deposit, PT and YT balances are equal, so we only need to check one
    uint256 _userBalance = fixedFeeSwap.PRINCIPAL_TOKEN().balanceOf(user);
    _redeemAmount = bound(_redeemAmount, 1, _userBalance);

    // Set up fees before maturity
    _updateYieldTokenFees(_feeToken0, _feeToken1);

    // Sync user fees by doing a 0-value transfer (this updates their accrued fees)
    vm.prank(user);
    fixedFeeSwap.YIELD_TOKEN().transfer(user, 0);

    // Get user's accrued fees before redeeming
    (,, uint256 _accruedToken0, uint256 _accruedToken1) = fixedFeeSwap.YIELD_TOKEN().userFees(user);

    // Get initial balances
    uint256 _initialUserVstBalance = vaultShareToken.balanceOf(user);
    uint256 _initialHookVstBalance = vaultShareToken.balanceOf(address(fixedFeeSwap));
    uint256 _initialPtSupply = fixedFeeSwap.PRINCIPAL_TOKEN().totalSupply();
    uint256 _initialYtSupply = fixedFeeSwap.YIELD_TOKEN().totalSupply();
    uint256 _initialUserToken0Balance = token0.balanceOf(user);
    uint256 _initialUserToken1Balance = token1.balanceOf(user);

    // Approve PT and YT tokens
    _approvePTAndYTForRedeem(user, _redeemAmount);

    // Redeem
    vm.prank(user);
    uint256 _vstAmount = fixedFeeSwap.redeem(_redeemAmount);

    // Check VST is transferred
    assertEq(_vstAmount, _redeemAmount);
    assertEq(vaultShareToken.balanceOf(user), _initialUserVstBalance + _redeemAmount);
    assertEq(
      vaultShareToken.balanceOf(address(fixedFeeSwap)), _initialHookVstBalance - _redeemAmount
    );

    // Check PT is burned
    assertEq(fixedFeeSwap.PRINCIPAL_TOKEN().balanceOf(user), _userBalance - _redeemAmount);
    assertEq(fixedFeeSwap.PRINCIPAL_TOKEN().totalSupply(), _initialPtSupply - _redeemAmount);

    // Check YT is burned
    assertEq(fixedFeeSwap.YIELD_TOKEN().balanceOf(user), _userBalance - _redeemAmount);
    assertEq(fixedFeeSwap.YIELD_TOKEN().totalSupply(), _initialYtSupply - _redeemAmount);

    // Check YT fees are claimed
    assertEq(token0.balanceOf(user), _initialUserToken0Balance + _accruedToken0);
    assertEq(token1.balanceOf(user), _initialUserToken1Balance + _accruedToken1);
  }

  function testFuzz_PaysFeesEarnedAfterMaturityInNativeEth(
    uint256 _depositAmount,
    uint256 _feeEth,
    uint256 _feeToken1
  ) public {
    _depositAmount = _boundToFeeEarningDeposit(_depositAmount);
    _feeEth = _boundToFeeAboveRounding(_feeEth);
    _feeToken1 = _boundToFeeAboveRounding(_feeToken1);
    VaultShareTokenHarness _vstWithEth =
      new VaultShareTokenHarness("Vault Share Token", "VST", NATIVE, address(token1));
    FixedFeeSwap _hookWithEth = new FixedFeeSwap(_vstWithEth, maturity);
    _vstWithEth.exposed_mint(user, _depositAmount);
    vm.prank(user);
    _vstWithEth.approve(address(_hookWithEth), _depositAmount);
    vm.prank(user);
    _hookWithEth.deposit(_depositAmount);
    vm.warp(maturity);
    _hookWithEth.settle();
    vm.deal(address(_vstWithEth), _feeEth);
    deal(address(token1), address(_vstWithEth), _feeToken1);
    _vstWithEth.exposed_updateFees(_feeEth, _feeToken1);

    vm.prank(user);
    _hookWithEth.redeem(_depositAmount);

    // The user's PT stands for every vault share, so it earns the whole fee index increase.
    assertEq(
      user.balance,
      Math.mulDiv(
        _depositAmount,
        Math.mulDiv(_feeEth, FeeTracking.PRECISION, _depositAmount),
        FeeTracking.PRECISION
      )
    );
    assertEq(
      token1.balanceOf(user),
      Math.mulDiv(
        _depositAmount,
        Math.mulDiv(_feeToken1, FeeTracking.PRECISION, _depositAmount),
        FeeTracking.PRECISION
      )
    );
  }

  function testFuzz_EmitsFeesClaimedOnRedeemAfterMaturity(
    uint256 _depositAmount,
    uint256 _feeToken0,
    uint256 _feeToken1
  ) public {
    _depositAmount = _boundToFeeEarningDeposit(_depositAmount);
    _feeToken0 = _boundToFeeAboveRounding(_feeToken0);
    _feeToken1 = _boundToFeeAboveRounding(_feeToken1);
    _mintVstAndDepositForUser(user, _depositAmount);
    vm.warp(maturity);
    fixedFeeSwap.settle();
    _updateYieldTokenFees(_feeToken0, _feeToken1);
    // The user's PT stands for every vault share, so it earns the whole fee index increase.
    uint256 _expectedFee0 = Math.mulDiv(
      _depositAmount,
      Math.mulDiv(_feeToken0, FeeTracking.PRECISION, _depositAmount),
      FeeTracking.PRECISION
    );
    uint256 _expectedFee1 = Math.mulDiv(
      _depositAmount,
      Math.mulDiv(_feeToken1, FeeTracking.PRECISION, _depositAmount),
      FeeTracking.PRECISION
    );

    vm.expectEmit();
    emit FixedFeeSwap.FeesClaimed(
      user, address(token0), address(token1), _expectedFee0, _expectedFee1
    );
    vm.prank(user);
    fixedFeeSwap.redeem(_depositAmount);
  }

  function testFuzz_PaysPrincipalRedeemersNoFeesYieldTokenHoldersEarned(
    uint256 _depositAmount,
    uint256 _feeToken0
  ) public {
    _depositAmount = _boundToFeeEarningDeposit(_depositAmount);
    _feeToken0 = _boundToFeeAboveRounding(_feeToken0);
    _mintVstAndDepositForUser(user, _depositAmount);
    PrincipalToken _principalToken = fixedFeeSwap.PRINCIPAL_TOKEN();
    // The user keeps the YT and sells the PT, which a transfer stands in for.
    vm.prank(user);
    _principalToken.transfer(userB, _depositAmount);
    _updateYieldTokenFees(_feeToken0, 0);
    fixedFeeSwap.collectFeesToYT();
    // Nothing is earned after the fees above, so everything FixedFeeSwap holds is owed to YT.
    vm.warp(maturity + 1);

    vm.prank(userB);
    fixedFeeSwap.redeem(_depositAmount);

    assertEq(token0.balanceOf(userB), 0);
  }

  function testFuzz_RedeemsPrincipalWithoutYieldTokensAfterEveryYieldTokenIsBurned(
    uint256 _depositAmount,
    uint256 _secondsAfterMaturity
  ) public {
    _depositAmount = _boundToRealisticAmount(_depositAmount);
    _secondsAfterMaturity = bound(_secondsAfterMaturity, 0, 365 days);
    _mintVstAndDepositForUser(user, _depositAmount);
    PrincipalToken _principalToken = fixedFeeSwap.PRINCIPAL_TOKEN();
    // The user keeps the YT and sells the PT, which a transfer stands in for.
    vm.prank(user);
    _principalToken.transfer(userB, _depositAmount);
    vm.warp(maturity + _secondsAfterMaturity);
    vm.prank(user);
    fixedFeeSwap.claimYTFeesAfterMaturity();

    vm.prank(userB);
    fixedFeeSwap.redeem(_depositAmount);

    assertEq(vaultShareToken.balanceOf(userB), _depositAmount);
  }

  function testFuzz_PaysTheLastRedeemerEveryFeeEarnedAfterMaturity(
    uint256 _depositAmount,
    uint256 _otherDepositAmount,
    uint256 _feeToken0
  ) public {
    _depositAmount = _boundToFeeEarningDeposit(_depositAmount);
    _otherDepositAmount = _boundToFeeEarningDeposit(_otherDepositAmount);
    _feeToken0 = _boundToFeeAboveRounding(_feeToken0);
    _mintVstAndDepositForUser(user, _depositAmount);
    _mintVstAndDepositForUser(userB, _otherDepositAmount);
    vm.warp(maturity);
    vm.prank(userB);
    fixedFeeSwap.redeem(_otherDepositAmount);
    // Fees the vault earns after maturity, spread over every share, including userB's redeemed
    // ones.
    _updateYieldTokenFees(_feeToken0, 0);
    uint256 _feeIndexIncrease =
      Math.mulDiv(_feeToken0, FeeTracking.PRECISION, vaultShareToken.totalSupply());

    vm.prank(user);
    fixedFeeSwap.redeem(_depositAmount);

    assertEq(
      token0.balanceOf(user), Math.mulDiv(_depositAmount, _feeIndexIncrease, FeeTracking.PRECISION)
    );
  }

  function testFuzz_EmitsRedeemEvent(uint256 _depositAmount, uint256 _redeemAmount) public {
    _depositAmount = _boundToRealisticAmount(_depositAmount);

    // Set up: user deposits VST to get PT and YT before maturity
    _depositVstForUser(user, _depositAmount);

    // Ensure redeem amount doesn't exceed user's balance
    // After deposit, PT and YT balances are equal, so we only need to check one
    uint256 _userBalance = fixedFeeSwap.PRINCIPAL_TOKEN().balanceOf(user);
    _redeemAmount = bound(_redeemAmount, 1, _userBalance);

    // Approve PT and YT tokens
    _approvePTAndYTForRedeem(user, _redeemAmount);

    bool _maturityReached = block.timestamp >= fixedFeeSwap.MATURITY();

    vm.expectEmit();
    emit FixedFeeSwap.Redeem(user, _redeemAmount, _maturityReached);
    vm.prank(user);
    fixedFeeSwap.redeem(_redeemAmount);
  }

  function testFuzz_UpdatesYTFeesOnRedeem(uint256 _depositAmount, uint256 _collectedFeeToken0)
    public
  {
    _depositAmount = _boundToRealisticAmount(_depositAmount);
    _collectedFeeToken0 = _boundToRealisticAmount(_collectedFeeToken0);
    // Ignore cases where no new vault fees are added.
    vm.assume(_collectedFeeToken0 > 0);

    // Use harness to mint VST so that fee indexes can be updated via `_updateFees`.
    VaultShareTokenHarness _vstHarness = VaultShareTokenHarness(address(vaultShareToken));

    // Mint VST to the user and split into PT/YT via the hook.
    _vstHarness.exposed_mint(user, _depositAmount);
    vm.prank(user);
    vaultShareToken.approve(address(fixedFeeSwap), _depositAmount);
    vm.prank(user);
    fixedFeeSwap.deposit(_depositAmount);

    YieldToken _yt = fixedFeeSwap.YIELD_TOKEN();

    // Record YT fee index before updating vault fees.
    uint256 _ytIndex0Before = _yt.globalFeeIndex0Scaled();

    // Fund vault and update vault fees so collectFeesToYT can pull to YT when user redeems.
    _updateYieldTokenFees(_collectedFeeToken0, 0);

    // Approve PT and YT for redeem before maturity.
    _approvePTAndYTForRedeem(user, _depositAmount);

    // Redeem before maturity:
    //  - `_syncFees` runs, pushing vault fees into YT accounting.
    //  - YT is burned, which internally claims the user's accrued YT fees.
    vm.prank(user);
    fixedFeeSwap.redeem(_depositAmount);
    // YT fee index should never decrease; when fees are non-zero it should stay the same or
    // increase.
    uint256 _ytIndex0After = _yt.globalFeeIndex0Scaled();
    assertGe(_ytIndex0After, _ytIndex0Before);
  }

  function test_RevertIf_AmountIsZero() public {
    vm.expectRevert(FixedFeeSwap.FixedFeeSwap_InvalidAmount.selector);
    fixedFeeSwap.redeem(0);
  }

  function testFuzz_RevertIf_InsufficientPTBalance(uint256 _depositAmount, uint256 _redeemAmount)
    public
  {
    _depositAmount = _boundToRealisticAmount(_depositAmount);
    _redeemAmount = _boundToRealisticAmount(_redeemAmount);

    // Set up: user deposits VST to get PT and YT before maturity
    _depositVstForUser(user, _depositAmount);
    uint256 _actualPtBalance = fixedFeeSwap.PRINCIPAL_TOKEN().balanceOf(user);

    vm.assume(_redeemAmount > _actualPtBalance);

    vm.expectRevert(FixedFeeSwap.FixedFeeSwap_InsufficientBalance.selector);
    vm.prank(user);
    fixedFeeSwap.redeem(_redeemAmount);
  }

  function testFuzz_RevertIf_InsufficientYieldTokenBalance(uint256 _depositAmount) public {
    _depositAmount = _boundToRealisticAmount(_depositAmount);

    // User deposits to get PT and YT (equal amounts)
    _depositVstForUser(user, _depositAmount);

    uint256 _ytBalance = fixedFeeSwap.YIELD_TOKEN().balanceOf(user);

    // Set PT balance to be YT + 1 to create the scenario where user has enough PT
    // but not enough YT
    uint256 _redeemAmount = _ytBalance + 1;
    deal(address(fixedFeeSwap.PRINCIPAL_TOKEN()), user, _redeemAmount);

    // Approve PT tokens (only PT needed since YT check happens first)
    vm.prank(user);
    fixedFeeSwap.PRINCIPAL_TOKEN().approve(address(fixedFeeSwap), _redeemAmount);

    vm.expectRevert(FixedFeeSwap.FixedFeeSwap_InsufficientBalance.selector);
    vm.prank(user);
    fixedFeeSwap.redeem(_redeemAmount);
  }

  function testFuzz_RevertIf_InsufficientVSTBalanceInHook(
    uint256 _depositAmount,
    uint256 _redeemAmount
  ) public {
    _depositAmount = _boundToRealisticAmount(_depositAmount);
    _redeemAmount = _boundToRealisticAmount(_redeemAmount);

    // Set up: user deposits VST to get PT and YT
    _depositVstForUser(user, _depositAmount);

    // Ensure redeem amount doesn't exceed user's PT balance
    uint256 _userBalance = fixedFeeSwap.PRINCIPAL_TOKEN().balanceOf(user);
    _redeemAmount = bound(_redeemAmount, 1, _userBalance);

    // Manually reduce hook's VST balance to create insufficient balance scenario
    // Set hook's balance to be less than the redeem amount
    uint256 _insufficientBalance = _redeemAmount > 0 ? _redeemAmount - 1 : 0;
    deal(address(vaultShareToken), address(fixedFeeSwap), _insufficientBalance);

    // Approve PT tokens
    vm.prank(user);
    fixedFeeSwap.PRINCIPAL_TOKEN().approve(address(fixedFeeSwap), _redeemAmount);

    // Approve YT tokens if before maturity
    if (block.timestamp < fixedFeeSwap.MATURITY()) {
      vm.prank(user);
      fixedFeeSwap.YIELD_TOKEN().approve(address(fixedFeeSwap), _redeemAmount);
    }

    // Should revert because hook doesn't have enough VST
    vm.expectRevert(FixedFeeSwap.FixedFeeSwap_InsufficientBalance.selector);
    vm.prank(user);
    fixedFeeSwap.redeem(_redeemAmount);
  }

  /// @notice Tests revert when native ETH transfer fails (non-payable contract).
  function testFuzz_RevertIf_NativeEthTransferFails(uint256 _depositAmount, uint256 _feeEth)
    public
  {
    _depositAmount = _boundToFeeEarningDeposit(_depositAmount);
    _feeEth = _boundToFeeAboveRounding(_feeEth);
    VaultShareTokenHarness _vstWithEth =
      new VaultShareTokenHarness("Vault Share Token", "VST", NATIVE, address(token1));
    FixedFeeSwap _hookWithEth = new FixedFeeSwap(_vstWithEth, maturity);
    NonPayableContractMock _nonPayableContract = new NonPayableContractMock();
    _vstWithEth.exposed_mint(address(_nonPayableContract), _depositAmount);
    vm.prank(address(_nonPayableContract));
    _vstWithEth.approve(address(_hookWithEth), _depositAmount);
    vm.prank(address(_nonPayableContract));
    _hookWithEth.deposit(_depositAmount);
    vm.warp(maturity);
    _hookWithEth.settle();
    // ETH fees earned after maturity, which the redeemer's PT is owed.
    vm.deal(address(_vstWithEth), _feeEth);
    _vstWithEth.exposed_updateFees(_feeEth, 0);

    vm.expectRevert(FixedFeeSwap.FixedFeeSwap_TransferFailed.selector);
    vm.prank(address(_nonPayableContract));
    _hookWithEth.redeem(_depositAmount);
  }
}

contract Settle is FixedFeeSwapTest {
  // The vault fee index at maturity that settlement should record when the index rose evenly from
  // zero at `_checkpointTime` to `_feeIndexNow` now, which is at or after maturity.
  function _interpolatedMaturityIndex(uint256 _feeIndexNow, uint256 _checkpointTime)
    internal
    view
    returns (uint256)
  {
    return Math.mulDiv(_feeIndexNow, maturity - _checkpointTime, block.timestamp - _checkpointTime);
  }

  function testFuzz_RevertIf_CalledBeforeMaturity(uint256 _secondsBeforeMaturity) public {
    _secondsBeforeMaturity = bound(_secondsBeforeMaturity, 1, maturity - block.timestamp);
    vm.warp(maturity - _secondsBeforeMaturity);

    vm.expectRevert(FixedFeeSwap.FixedFeeSwap_BeforeMaturity.selector);
    fixedFeeSwap.settle();
  }

  function testFuzz_RecordsTheVaultFeeIndexesWhenCalledAtMaturity(
    uint256 _depositAmount,
    uint256 _feeToken0,
    uint256 _feeToken1
  ) public {
    _depositAmount = _boundToFeeEarningDeposit(_depositAmount);
    _feeToken0 = _boundToFeeAboveRounding(_feeToken0);
    _feeToken1 = _boundToFeeAboveRounding(_feeToken1);
    _mintVstAndDepositForUser(user, _depositAmount);
    _updateYieldTokenFees(_feeToken0, _feeToken1);
    vm.warp(maturity);

    fixedFeeSwap.settle();

    assertTrue(fixedFeeSwap.settled());
    assertEq(fixedFeeSwap.maturityFeeIndex0Scaled(), vaultShareToken.globalFeeIndex0Scaled());
    assertEq(fixedFeeSwap.maturityFeeIndex1Scaled(), vaultShareToken.globalFeeIndex1Scaled());
  }

  function testFuzz_InterpolatesTheMaturityIndexesByTimeWhenCalledAfterMaturity(
    uint256 _depositAmount,
    uint256 _feeToken0,
    uint256 _feeToken1,
    uint256 _secondsAfterMaturity
  ) public {
    _depositAmount = _boundToFeeEarningDeposit(_depositAmount);
    _feeToken0 = _boundToFeeAboveRounding(_feeToken0);
    _feeToken1 = _boundToFeeAboveRounding(_feeToken1);
    _secondsAfterMaturity = bound(_secondsAfterMaturity, 1, 365 days);
    // The deposit checkpoints the vault's indexes, which are still zero, at this time.
    uint256 _checkpointTime = block.timestamp;
    _mintVstAndDepositForUser(user, _depositAmount);
    _updateYieldTokenFees(_feeToken0, _feeToken1);
    vm.warp(maturity + _secondsAfterMaturity);

    fixedFeeSwap.settle();

    assertEq(
      fixedFeeSwap.maturityFeeIndex0Scaled(),
      _interpolatedMaturityIndex(vaultShareToken.globalFeeIndex0Scaled(), _checkpointTime)
    );
    assertEq(
      fixedFeeSwap.maturityFeeIndex1Scaled(),
      _interpolatedMaturityIndex(vaultShareToken.globalFeeIndex1Scaled(), _checkpointTime)
    );
  }

  function testFuzz_EmitsSettled(uint256 _depositAmount, uint256 _feeToken0, uint256 _feeToken1)
    public
  {
    _depositAmount = _boundToFeeEarningDeposit(_depositAmount);
    _feeToken0 = _boundToFeeAboveRounding(_feeToken0);
    _feeToken1 = _boundToFeeAboveRounding(_feeToken1);
    _mintVstAndDepositForUser(user, _depositAmount);
    _updateYieldTokenFees(_feeToken0, _feeToken1);
    vm.warp(maturity);

    vm.expectEmit();
    emit FixedFeeSwap.Settled(
      vaultShareToken.globalFeeIndex0Scaled(), vaultShareToken.globalFeeIndex1Scaled()
    );
    fixedFeeSwap.settle();
  }

  function testFuzz_DoesNothingWhenCalledAgain(
    uint256 _depositAmount,
    uint256 _feeToken0,
    uint256 _secondsAfterMaturity
  ) public {
    _depositAmount = _boundToFeeEarningDeposit(_depositAmount);
    _feeToken0 = _boundToFeeAboveRounding(_feeToken0);
    _secondsAfterMaturity = bound(_secondsAfterMaturity, 0, 365 days);
    _mintVstAndDepositForUser(user, _depositAmount);
    vm.warp(maturity);
    fixedFeeSwap.settle();
    uint256 _maturityIndex0 = fixedFeeSwap.maturityFeeIndex0Scaled();
    _updateYieldTokenFees(_feeToken0, 0);
    vm.warp(maturity + _secondsAfterMaturity);

    fixedFeeSwap.settle();

    assertEq(fixedFeeSwap.maturityFeeIndex0Scaled(), _maturityIndex0);
  }

  function testFuzz_SettlesWhenRedeemIsTheFirstActionAfterMaturity(
    uint256 _depositAmount,
    uint256 _secondsAfterMaturity
  ) public {
    _depositAmount = _boundToRealisticAmount(_depositAmount);
    _secondsAfterMaturity = bound(_secondsAfterMaturity, 0, 365 days);
    _mintVstAndDepositForUser(user, _depositAmount);
    vm.warp(maturity + _secondsAfterMaturity);

    vm.prank(user);
    fixedFeeSwap.redeem(_depositAmount);

    assertTrue(fixedFeeSwap.settled());
  }

  function testFuzz_SettlesWhenClaimYTFeesAfterMaturityIsTheFirstActionAfterMaturity(
    uint256 _depositAmount,
    uint256 _secondsAfterMaturity
  ) public {
    _depositAmount = _boundToRealisticAmount(_depositAmount);
    _secondsAfterMaturity = bound(_secondsAfterMaturity, 0, 365 days);
    _mintVstAndDepositForUser(user, _depositAmount);
    vm.warp(maturity + _secondsAfterMaturity);

    vm.prank(user);
    fixedFeeSwap.claimYTFeesAfterMaturity();

    assertTrue(fixedFeeSwap.settled());
  }

  function testFuzz_SettlesWhenCollectFeesToYTIsTheFirstActionAfterMaturity(
    uint256 _depositAmount,
    uint256 _secondsAfterMaturity
  ) public {
    _depositAmount = _boundToRealisticAmount(_depositAmount);
    _secondsAfterMaturity = bound(_secondsAfterMaturity, 0, 365 days);
    _mintVstAndDepositForUser(user, _depositAmount);
    vm.warp(maturity + _secondsAfterMaturity);

    fixedFeeSwap.collectFeesToYT();

    assertTrue(fixedFeeSwap.settled());
  }

  function testFuzz_CreditsYieldTokenHoldersWithFeesUpToTheMaturityIndex(
    uint256 _depositAmount,
    uint256 _feeToken0,
    uint256 _secondsAfterMaturity
  ) public {
    _depositAmount = _boundToFeeEarningDeposit(_depositAmount);
    _feeToken0 = _boundToFeeAboveRounding(_feeToken0);
    _secondsAfterMaturity = bound(_secondsAfterMaturity, 0, 365 days);
    _mintVstAndDepositForUser(user, _depositAmount);
    _updateYieldTokenFees(_feeToken0, 0);
    vm.warp(maturity + _secondsAfterMaturity);
    fixedFeeSwap.settle();
    uint256 _earnedBeforeMaturity =
      Math.mulDiv(_depositAmount, fixedFeeSwap.maturityFeeIndex0Scaled(), FeeTracking.PRECISION);

    vm.prank(user);
    fixedFeeSwap.claimYTFeesAfterMaturity();

    // YieldToken rounds its own fee index down by up to 1 per 1e18 shares, so the holder can
    // receive up to that much less than the fees credited to YT.
    assertApproxEqAbs(
      token0.balanceOf(user), _earnedBeforeMaturity, _depositAmount / FeeTracking.PRECISION + 1
    );
  }
}

contract FeesAcrossMaturity is FixedFeeSwapTest {
  function testFuzz_LeavesOnlyRoundingDustOnceEveryHolderExits(
    uint256 _depositAmount,
    uint256 _otherDepositAmount,
    uint256 _feeBeforeMaturity,
    uint256 _feeAcrossMaturity,
    uint256 _feeAfterSettlement,
    uint256 _secondsAfterMaturity
  ) public {
    _depositAmount = _boundToFeeEarningDeposit(_depositAmount);
    _otherDepositAmount = _boundToFeeEarningDeposit(_otherDepositAmount);
    _feeBeforeMaturity = _boundToFeeAboveRounding(_feeBeforeMaturity);
    _feeAcrossMaturity = _boundToFeeAboveRounding(_feeAcrossMaturity);
    _feeAfterSettlement = _boundToFeeAboveRounding(_feeAfterSettlement);
    _secondsAfterMaturity = bound(_secondsAfterMaturity, 1, 365 days);
    address _principalBuyer = makeAddr("principalBuyer");
    PrincipalToken _principalToken = fixedFeeSwap.PRINCIPAL_TOKEN();
    _mintVstAndDepositForUser(user, _depositAmount);
    _mintVstAndDepositForUser(userB, _otherDepositAmount);
    // userB keeps the YT and sells the PT, which a transfer stands in for.
    vm.prank(userB);
    _principalToken.transfer(_principalBuyer, _otherDepositAmount);
    _updateYieldTokenFees(_feeBeforeMaturity, 0);
    fixedFeeSwap.collectFeesToYT();
    // Reported after maturity but earned partly before it, so settlement splits it by time.
    _updateYieldTokenFees(_feeAcrossMaturity, 0);
    vm.warp(maturity + _secondsAfterMaturity);

    vm.prank(_principalBuyer);
    fixedFeeSwap.redeem(_otherDepositAmount);
    _updateYieldTokenFees(_feeAfterSettlement, 0);
    vm.prank(user);
    fixedFeeSwap.redeem(_depositAmount);
    vm.prank(user);
    fixedFeeSwap.claimYTFeesAfterMaturity();
    vm.prank(userB);
    fixedFeeSwap.claimYTFeesAfterMaturity();

    // Each fee index, FixedFeeSwap's and YieldToken's, rounds down by up to 1 per 1e18 shares.
    assertLe(
      token0.balanceOf(address(fixedFeeSwap)),
      2 * (_depositAmount + _otherDepositAmount) / FeeTracking.PRECISION + 10
    );
  }
}
