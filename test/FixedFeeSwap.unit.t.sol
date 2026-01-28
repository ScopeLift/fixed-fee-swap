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

  /// @notice Helper function to set up fees on YT.
  /// @param _feeToken0 Amount of token0 fees to add.
  /// @param _feeToken1 Amount of token1 fees to add.
  function _updateYieldTokenFees(uint256 _feeToken0, uint256 _feeToken1) internal {
    // Update fees on YT
    YieldToken _yt = fixedFeeSwap.YIELD_TOKEN();
    vm.prank(address(fixedFeeSwap));
    _yt.updateFees(_feeToken0, _feeToken1);

    // Fund the YieldToken contract with fee tokens so it can pay out claims
    // Deal the actual fee amounts being added (or add to existing balance if fees were updated
    // multiple times)
    uint256 _currentBalance0 = token0.balanceOf(address(_yt));
    uint256 _currentBalance1 = token1.balanceOf(address(_yt));
    deal(address(token0), address(_yt), _currentBalance0 + _feeToken0);
    deal(address(token1), address(_yt), _currentBalance1 + _feeToken1);
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

    // Second deposit triggers `_syncYTFees` before doing the split.
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

contract SyncYTFees is FixedFeeSwapTest {
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

    // Deposit triggers _syncYTFees, but hook has 0 VST, so early return.
    _vstHarness.exposed_mint(user, _depositAmount);
    vm.prank(user);
    vaultShareToken.approve(address(fixedFeeSwap), _depositAmount);
    vm.prank(user);
    fixedFeeSwap.deposit(_depositAmount);

    // YT index should still be 0 because _vstBalance was 0 during _syncYTFees.
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

    // Simulate additional vault fees.
    _vstHarness.exposed_updateFees(_collectedFeeToken0, 0);

    // Fund YT with fee tokens so it can pay out claims when YT is burned.
    deal(address(token0), address(_yt), type(uint128).max);

    // Move past maturity so `claimYTFeesAfterMaturity` is enabled.
    vm.warp(maturity + 1);

    // This call runs `_syncYTFees` then burns YT, which claims fees.
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

  function testFuzz_RedeemAfterMaturity(
    uint256 _depositAmount,
    uint256 _redeemAmount,
    uint256 _feeToken0,
    uint256 _feeToken1
  ) public {
    _depositAmount = _boundToRealisticAmount(_depositAmount);
    _feeToken0 = _boundToRealisticAmount(_feeToken0);
    _feeToken1 = _boundToRealisticAmount(_feeToken1);

    // Assume user is a safe address (allows both EOAs and contracts that can receive ETH)
    _assumeSafeAddressForEth(user);

    // Create a VaultShareToken with native ETH (NATIVE) as token0 and ERC20 as token1
    VaultShareToken _vstWithEth =
      new VaultShareToken("Vault Share Token", "VST", NATIVE, address(token1));

    // Create a new hook with the ETH-enabled VST
    FixedFeeSwap _hookWithEth = new FixedFeeSwap(_vstWithEth, maturity);

    // Set up: user deposits VST to get PT and YT before maturity
    deal(address(_vstWithEth), user, _depositAmount);
    vm.prank(user);
    _vstWithEth.approve(address(_hookWithEth), _depositAmount);
    vm.prank(user);
    _hookWithEth.deposit(_depositAmount);

    // Ensure redeem amount doesn't exceed user's balance
    uint256 _userBalance = _hookWithEth.PRINCIPAL_TOKEN().balanceOf(user);
    _redeemAmount = bound(_redeemAmount, 1, _userBalance);

    // Move past maturity
    vm.warp(maturity + 1);

    // Fund the hook contract with ETH and ERC20 tokens for post-maturity fees
    vm.deal(address(_hookWithEth), _feeToken0);
    deal(address(token1), address(_hookWithEth), _feeToken1);

    // Get initial balances
    uint256 _initialUserVstBalance = _vstWithEth.balanceOf(user);
    uint256 _initialUserEthBalance = user.balance;
    uint256 _initialUserToken1Balance = token1.balanceOf(user);
    uint256 _initialPtSupply = _hookWithEth.PRINCIPAL_TOKEN().totalSupply();
    uint256 _initialYtSupply = _hookWithEth.YIELD_TOKEN().totalSupply();

    // Approve PT tokens (only PT needed after maturity)
    vm.prank(user);
    _hookWithEth.PRINCIPAL_TOKEN().approve(address(_hookWithEth), _redeemAmount);

    // Redeem
    vm.prank(user);
    assertEq(_hookWithEth.redeem(_redeemAmount), _redeemAmount);

    // Check VST is transferred
    assertEq(_vstWithEth.balanceOf(user), _initialUserVstBalance + _redeemAmount);

    // Check PT is burned
    assertEq(_hookWithEth.PRINCIPAL_TOKEN().balanceOf(user), _userBalance - _redeemAmount);
    assertEq(_hookWithEth.PRINCIPAL_TOKEN().totalSupply(), _initialPtSupply - _redeemAmount);

    // Check YT is NOT burned (after maturity, YT is not required)
    assertEq(_hookWithEth.YIELD_TOKEN().totalSupply(), _initialYtSupply);

    // Check post-maturity fees are claimed (native ETH and ERC20)
    // Calculate expected fees based on contract balances and PT supply
    uint256 _totalSupply = _initialPtSupply;
    uint256 _expectedFeeEth =
      Math.mulDiv(_feeToken0, _redeemAmount, _totalSupply, Math.Rounding.Floor);
    uint256 _expectedFee1 =
      Math.mulDiv(_feeToken1, _redeemAmount, _totalSupply, Math.Rounding.Floor);

    assertEq(user.balance, _initialUserEthBalance + _expectedFeeEth);
    assertEq(token1.balanceOf(user), _initialUserToken1Balance + _expectedFee1);
  }

  function testFuzz_EmitFeesClaimedOnRedeemAfterMaturity(
    uint256 _depositAmount,
    uint256 _redeemAmount,
    uint256 _feeToken0,
    uint256 _feeToken1
  ) public {
    _depositAmount = _boundToRealisticAmount(_depositAmount);
    _feeToken0 = _boundToRealisticAmount(_feeToken0);
    _feeToken1 = _boundToRealisticAmount(_feeToken1);

    // Assume user is a safe address (allows both EOAs and contracts that can receive ETH)
    _assumeSafeAddressForEth(user);

    // Create a VaultShareToken with native ETH (NATIVE) as token0 and ERC20 as token1
    VaultShareToken _vstWithEth =
      new VaultShareToken("Vault Share Token", "VST", NATIVE, address(token1));

    // Create a new hook with the ETH-enabled VST
    FixedFeeSwap _hookWithEth = new FixedFeeSwap(_vstWithEth, maturity);

    // Set up: user deposits VST to get PT and YT before maturity
    deal(address(_vstWithEth), user, _depositAmount);
    vm.prank(user);
    _vstWithEth.approve(address(_hookWithEth), _depositAmount);
    vm.prank(user);
    _hookWithEth.deposit(_depositAmount);

    // Ensure redeem amount doesn't exceed user's balance
    uint256 _userBalance = _hookWithEth.PRINCIPAL_TOKEN().balanceOf(user);
    _redeemAmount = bound(_redeemAmount, 1, _userBalance);

    // Move past maturity
    vm.warp(maturity + 1);

    // Fund the hook contract with ETH and ERC20 tokens for post-maturity fees
    // Post-maturity fees are now calculated based on contract balances
    vm.deal(address(_hookWithEth), _feeToken0);
    deal(address(token1), address(_hookWithEth), _feeToken1);

    // Calculate expected fees based on contract balances and PT supply
    uint256 _totalSupply = _hookWithEth.PRINCIPAL_TOKEN().totalSupply();
    uint256 _expectedFee0 =
      Math.mulDiv(_feeToken0, _redeemAmount, _totalSupply, Math.Rounding.Floor);
    uint256 _expectedFee1 =
      Math.mulDiv(_feeToken1, _redeemAmount, _totalSupply, Math.Rounding.Floor);

    // Approve PT tokens
    vm.prank(user);
    _hookWithEth.PRINCIPAL_TOKEN().approve(address(_hookWithEth), _redeemAmount);

    // Expect FeesClaimed event (with native ETH (NATIVE) and ERC20 token1)
    vm.expectEmit();
    emit FixedFeeSwap.FeesClaimed(user, NATIVE, address(token1), _expectedFee0, _expectedFee1);

    // Redeem
    vm.prank(user);
    _hookWithEth.redeem(_redeemAmount);
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

    // Simulate new vault fees accruing to VST.
    _vstHarness.exposed_updateFees(_collectedFeeToken0, 0);

    // Fund YT with fee tokens so it can pay out claims when YT is burned.
    deal(address(token0), address(_yt), type(uint128).max);

    // Approve PT and YT for redeem before maturity.
    _approvePTAndYTForRedeem(user, _depositAmount);

    // Redeem before maturity:
    //  - `_syncYTFees` runs, pushing vault fees into YT accounting.
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
  function testFuzz_RevertIf_NativeEthTransferFails(
    uint256 _depositAmount,
    uint256 _redeemAmount,
    uint256 _feeEth
  ) public {
    _depositAmount = _boundToRealisticAmount(_depositAmount);
    _feeEth = _boundToRealisticAmount(_feeEth);
    _redeemAmount = _boundToRealisticAmount(_redeemAmount);

    // Ensure we have fees to claim - need significant fees to avoid rounding to zero
    vm.assume(_feeEth >= _depositAmount && _depositAmount > 0);

    // Create a VaultShareToken with native ETH (NATIVE) as token0
    VaultShareToken _vstWithEth =
      new VaultShareToken("Vault Share Token", "VST", NATIVE, address(token1));

    // Create a new hook with the ETH-enabled VST
    FixedFeeSwap _hookWithEth = new FixedFeeSwap(_vstWithEth, maturity);

    // Deploy a contract that rejects ETH transfers
    NonPayableContractMock _nonPayableContract = new NonPayableContractMock();

    // Set up: non-payable contract deposits VST to get PT and YT before maturity
    deal(address(_vstWithEth), address(_nonPayableContract), _depositAmount);
    vm.prank(address(_nonPayableContract));
    _vstWithEth.approve(address(_hookWithEth), _depositAmount);
    vm.prank(address(_nonPayableContract));
    _hookWithEth.deposit(_depositAmount);

    // Ensure redeem amount doesn't exceed balance
    uint256 _userBalance = _hookWithEth.PRINCIPAL_TOKEN().balanceOf(address(_nonPayableContract));
    _redeemAmount = bound(_redeemAmount, 1, _userBalance);

    // Move past maturity
    vm.warp(maturity + 1);

    // Fund the hook contract with ETH for post-maturity fees
    vm.deal(address(_hookWithEth), _feeEth);

    // Calculate expected ETH fee based on contract balance and PT supply
    uint256 _totalSupply = _hookWithEth.PRINCIPAL_TOKEN().totalSupply();
    uint256 _expectedFeeEth = Math.mulDiv(_feeEth, _redeemAmount, _totalSupply, Math.Rounding.Floor);

    // Only test if we have non-zero fees to claim
    vm.assume(_expectedFeeEth > 0);

    // Approve PT tokens
    vm.prank(address(_nonPayableContract));
    _hookWithEth.PRINCIPAL_TOKEN().approve(address(_hookWithEth), _redeemAmount);

    // Should revert because non-payable contract cannot receive ETH
    vm.expectRevert(FixedFeeSwap.FixedFeeSwap_TransferFailed.selector);
    vm.prank(address(_nonPayableContract));
    _hookWithEth.redeem(_redeemAmount);
  }
}
