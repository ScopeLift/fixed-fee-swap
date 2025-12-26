// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {Test, Vm} from "forge-std/Test.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Internal imports
import {FixedFeeSwapHook as FixedFeeSwapHookBase} from "src/FixedFeeSwapHook.sol";
import {VaultShareToken} from "src/VaultShareToken.sol";
import {PrincipalToken} from "src/PrincipalToken.sol";
import {YieldToken} from "src/YieldToken.sol";
import {ERC20Mock} from "test/mock/ERC20Mock.sol";
import {FixedFeeSwapHookHarness} from "test/harness/FixedFeeSwapHookHarness.sol";
import {NonPayableContractMock} from "test/mock/NonPayableContractMock.sol";

contract FixedFeeSwapHookTest is Test {
  FixedFeeSwapHookHarness internal fixedFeeSwapHook;
  VaultShareToken internal vaultShareToken;
  ERC20Mock internal token0;
  ERC20Mock internal token1;
  IPoolManager internal poolManager;

  address internal user;

  uint256 internal maturity;

  function setUp() public virtual {
    // Underlying fee tokens for the VaultShareToken
    token0 = new ERC20Mock("Token 0", "T0");
    token1 = new ERC20Mock("Token 1", "T1");

    // Underlying VaultShareToken whose shares are being split
    vaultShareToken =
      new VaultShareToken("Vault Share Token", "VST", address(token0), address(token1));

    // PoolManager is only stored in the hook; we never call into it in these tests
    poolManager = IPoolManager(makeAddr("poolManager"));

    // Choose a maturity strictly in the future
    maturity = block.timestamp + 30 days;

    fixedFeeSwapHook = new FixedFeeSwapHookHarness(poolManager, vaultShareToken, maturity);

    user = makeAddr("user");
  }

  function _assumeSafeAddress(address _addr) internal pure {
    vm.assume(_addr != address(0));
  }

  /// @notice Assumes the address is a safe EOA (Externally Owned Account).
  /// @param _address The address to check.
  /// @dev Excludes contract addresses, precompile addresses, and known problematic addresses (like
  /// console), which is necessary for native ETH transfers.
  function _assumeSafeEOA(address _address) internal view {
    vm.assume(_address != address(0));
    // Exclude the console address (used by forge-std for logging, cannot receive ETH)
    vm.assume(_address != address(0x000000000000000000636F6e736F6c652e6c6f67));
    // Exclude precompile addresses (0x01-0x0F) which cannot receive ETH
    vm.assume(_address > address(0x0F));
    // Exclude contract addresses (for native ETH transfers)
    vm.assume(_address.code.length == 0);
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
    vaultShareToken.approve(address(fixedFeeSwapHook), _depositAmount);
    vm.prank(_user);
    fixedFeeSwapHook.deposit(_depositAmount);
  }

  /// @notice Helper function to set up fees on YT before maturity.
  /// @param _feeToken0 Amount of token0 fees to add.
  /// @param _feeToken1 Amount of token1 fees to add.
  function _setupFeesBeforeMaturity(uint256 _feeToken0, uint256 _feeToken1) internal {
    // Update fees on YT before maturity (routes to YT via _updateFees)
    fixedFeeSwapHook.exposed_updateFees(_feeToken0, _feeToken1);

    // Fund the YieldToken contract with fee tokens so it can pay out claims
    // Use a large amount to ensure we have enough for any user's claim
    YieldToken _yt = fixedFeeSwapHook.YIELD_TOKEN();
    deal(address(token0), address(_yt), type(uint128).max);
    deal(address(token1), address(_yt), type(uint128).max);
  }

  /// @notice Helper function to approve PT and YT tokens for redeem.
  /// @param _user The address to approve for.
  /// @param _amount The amount to approve.
  function _approvePTAndYTForRedeem(address _user, uint256 _amount) internal {
    vm.prank(_user);
    fixedFeeSwapHook.PRINCIPAL_TOKEN().approve(address(fixedFeeSwapHook), _amount);
    vm.prank(_user);
    fixedFeeSwapHook.YIELD_TOKEN().approve(address(fixedFeeSwapHook), _amount);
  }

  /// @notice Helper function to set up post-maturity fees.
  /// @param _feeToken0 Amount of token0 fees to add.
  /// @param _feeToken1 Amount of token1 fees to add.
  /// @dev Must be called after maturity. Funds the hook contract with fee tokens.
  function _setupFeesAfterMaturity(uint256 _feeToken0, uint256 _feeToken1) internal {
    // Update fees on hook after maturity (must be called by the hook)
    fixedFeeSwapHook.exposed_updateFees(_feeToken0, _feeToken1);

    // Fund the hook contract with fee tokens so it can pay out claims
    // Use a large amount to ensure we have enough for any user's claim
    deal(address(token0), address(fixedFeeSwapHook), type(uint128).max);
    deal(address(token1), address(fixedFeeSwapHook), type(uint128).max);
  }

  /// @notice Helper function to calculate expected post-maturity fees.
  /// @param _hook The hook contract.
  /// @param _redeemAmount The amount being redeemed.
  /// @return _fee0 Expected fee0 amount.
  /// @return _fee1 Expected fee1 amount.
  function _calculatePostMaturityFees(FixedFeeSwapHookHarness _hook, uint256 _redeemAmount)
    internal
    view
    returns (uint256 _fee0, uint256 _fee1)
  {
    _fee0 = Math.mulDiv(
      _hook.postMaturityFeeIndex0Scaled(), _redeemAmount, 1e18, Math.Rounding.Floor
    );
    _fee1 =
      Math.mulDiv(_hook.postMaturityFeeIndex1Scaled(), _redeemAmount, 1e18, Math.Rounding.Floor);
  }
}

contract Constructor is FixedFeeSwapHookTest {
  function testFuzz_SetsInitialParameters(
    address _poolManager,
    address _vaultShareToken0,
    address _vaultShareToken1,
    uint256 _maturity
  ) public {
    _assumeSafeAddress(_vaultShareToken0);
    _assumeSafeAddress(_vaultShareToken1);
    _assumeSafeAddress(_poolManager);
    _assumeSafeMaturity(_maturity);

    VaultShareToken _vaultShareToken =
      new VaultShareToken("Vault Share Token", "VST", _vaultShareToken0, _vaultShareToken1);

    FixedFeeSwapHookHarness _hook = new FixedFeeSwapHookHarness(
      IPoolManager(_poolManager), VaultShareToken(_vaultShareToken), _maturity
    );

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

    assertEq(_pt.FIXED_FEE_SWAP_HOOK(), address(_hook));
    assertEq(_yt.FIXED_FEE_SWAP_HOOK(), address(_hook));
  }

  function testFuzz_EmitsInitializedEvent(address _poolManager, uint256 _maturity) public {
    _assumeSafeAddress(_poolManager);
    _assumeSafeMaturity(_maturity);

    // Record logs to capture the event
    vm.recordLogs();

    // Deploy the hook (this will emit the Initialized event)
    FixedFeeSwapHookHarness _hook =
      new FixedFeeSwapHookHarness(IPoolManager(_poolManager), vaultShareToken, _maturity);

    // Get the actual PT and YT addresses from the deployed hook
    address _ptAddress = address(_hook.PRINCIPAL_TOKEN());
    address _ytAddress = address(_hook.YIELD_TOKEN());

    // Verify the event was emitted with correct values
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    assertEq(_logs.length, 1);

    // Decode and verify the event
    // Only poolManager is indexed, so topics[0] = signature, topics[1] = poolManager
    bytes32 _eventSignature = keccak256("Initialized(address,address,address,address,uint256)");
    assertEq(_logs[0].topics[0], _eventSignature);
    assertEq(address(uint160(uint256(_logs[0].topics[1]))), _poolManager);

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

  function test_RevertIf_ManagerIsZero(address _vaultShareToken, uint256 _maturity) public {
    _assumeSafeAddress(_vaultShareToken);
    _assumeSafeMaturity(_maturity);

    vm.expectRevert(FixedFeeSwapHookBase.FixedFeeSwapHook_InvalidManager.selector);
    new FixedFeeSwapHookHarness(
      IPoolManager(address(0)), VaultShareToken(_vaultShareToken), _maturity
    );
  }

  function testFuzz_RevertIf_VaultShareTokenIsZero(address _poolManager) public {
    _assumeSafeAddress(_poolManager);

    vm.expectRevert(FixedFeeSwapHookBase.FixedFeeSwapHook_InvalidVaultShareToken.selector);
    new FixedFeeSwapHookHarness(IPoolManager(_poolManager), VaultShareToken(address(0)), maturity);
  }

  function testFuzz_RevertIf_MaturityInPast(uint256 _maturity) public {
    _maturity = bound(_maturity, 0, block.timestamp);

    vm.expectRevert(FixedFeeSwapHookBase.FixedFeeSwapHook_InvalidMaturity.selector);
    new FixedFeeSwapHookHarness(poolManager, vaultShareToken, _maturity);
  }
}

contract GetHookPermissions is FixedFeeSwapHookTest {
  function test_ReturnsCorrectPermissions() public view {
    Hooks.Permissions memory _permissions = fixedFeeSwapHook.getHookPermissions();
    assertFalse(_permissions.beforeInitialize);
    assertFalse(_permissions.afterInitialize);
    assertFalse(_permissions.beforeAddLiquidity);
    assertFalse(_permissions.afterAddLiquidity);
    assertFalse(_permissions.beforeRemoveLiquidity);
    assertFalse(_permissions.afterRemoveLiquidity);
    assertFalse(_permissions.beforeSwap);
    assertFalse(_permissions.beforeDonate);
    assertFalse(_permissions.beforeSwapReturnDelta);
    assertFalse(_permissions.afterSwapReturnDelta);

    assertTrue(_permissions.afterSwap);
    assertTrue(_permissions.afterDonate);
  }
}

contract Deposit is FixedFeeSwapHookTest {
  function testFuzz_SplitsVaultShareTokenToPTAndYT(uint256 _amount) public {
    _amount = _boundToRealisticAmount(_amount);
    deal(address(vaultShareToken), user, _amount);

    uint256 _initialUserVstBalance = vaultShareToken.balanceOf(user);
    uint256 _initialHookVstBalance = vaultShareToken.balanceOf(address(fixedFeeSwapHook));
    uint256 _initialPtSupply = fixedFeeSwapHook.PRINCIPAL_TOKEN().totalSupply();
    uint256 _initialYtSupply = fixedFeeSwapHook.YIELD_TOKEN().totalSupply();
    uint256 _initialPtUserBalance = fixedFeeSwapHook.PRINCIPAL_TOKEN().balanceOf(user);
    uint256 _initialYtUserBalance = fixedFeeSwapHook.YIELD_TOKEN().balanceOf(user);

    vm.prank(user);
    vaultShareToken.approve(address(fixedFeeSwapHook), _amount);

    vm.prank(user);
    (uint256 _ptAmount, uint256 _ytAmount) = fixedFeeSwapHook.deposit(_amount);

    assertEq(vaultShareToken.balanceOf(user), _initialUserVstBalance - _amount);
    assertEq(vaultShareToken.balanceOf(address(fixedFeeSwapHook)), _initialHookVstBalance + _amount);
    assertEq(fixedFeeSwapHook.PRINCIPAL_TOKEN().totalSupply(), _initialPtSupply + _amount);
    assertEq(fixedFeeSwapHook.YIELD_TOKEN().totalSupply(), _initialYtSupply + _amount);
    assertEq(fixedFeeSwapHook.PRINCIPAL_TOKEN().balanceOf(user), _initialPtUserBalance + _amount);
    assertEq(fixedFeeSwapHook.YIELD_TOKEN().balanceOf(user), _initialYtUserBalance + _amount);

    assertEq(_ptAmount, _amount);
    assertEq(_ytAmount, _amount);
  }

  function testFuzz_EmitsDepositEvent(uint256 _amount) public {
    _amount = _boundToRealisticAmount(_amount);
    deal(address(vaultShareToken), user, _amount);
    vm.prank(user);
    vaultShareToken.approve(address(fixedFeeSwapHook), _amount);

    uint256 _ptAmount = _amount;
    uint256 _ytAmount = _amount;

    vm.expectEmit();
    emit FixedFeeSwapHookBase.Deposit(user, _amount, _ptAmount, _ytAmount);
    vm.prank(user);
    fixedFeeSwapHook.deposit(_amount);
  }

  function testFuzz_RevertIf_DepositAfterMaturity(uint256 _amount) public {
    vm.warp(maturity + 1);
    vm.expectRevert(FixedFeeSwapHookBase.FixedFeeSwapHook_SplitAfterMaturity.selector);
    fixedFeeSwapHook.deposit(_amount);
  }

  function test_RevertIf_AmountIsZero() public {
    vm.expectRevert(FixedFeeSwapHookBase.FixedFeeSwapHook_InvalidAmount.selector);
    fixedFeeSwapHook.deposit(0);
  }

  function testFuzz_RevertIf_InsufficientAllowance(uint256 _amount, uint256 _approvalAmount)
    public
  {
    _amount = _boundToRealisticAmount(_amount);
    _approvalAmount = bound(_approvalAmount, 0, _amount - 1); // Approval must be less than amount

    deal(address(vaultShareToken), user, _amount);

    // Approve less than the deposit amount
    vm.prank(user);
    vaultShareToken.approve(address(fixedFeeSwapHook), _approvalAmount);

    // Attempt to deposit more than approved
    vm.prank(user);
    vm.expectRevert(
      abi.encodeWithSelector(
        IERC20Errors.ERC20InsufficientAllowance.selector,
        address(fixedFeeSwapHook),
        _approvalAmount,
        _amount
      )
    );
    fixedFeeSwapHook.deposit(_amount);
  }

  function testFuzz_RevertIf_InsufficientBalance(uint256 _amount, uint256 _userBalance) public {
    _amount = _boundToRealisticAmount(_amount);
    _userBalance = bound(_userBalance, 0, _amount - 1); // Balance must be less than amount

    // Give user less than the deposit amount
    deal(address(vaultShareToken), user, _userBalance);

    // Approve the full amount (even though user doesn't have it)
    vm.prank(user);
    vaultShareToken.approve(address(fixedFeeSwapHook), _amount);

    // Attempt to deposit more than user has
    vm.prank(user);
    vm.expectRevert(FixedFeeSwapHookBase.FixedFeeSwapHook_InsufficientBalance.selector);
    fixedFeeSwapHook.deposit(_amount);
  }
}

contract ClaimYTFeesAfterMaturity is FixedFeeSwapHookTest {
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
    _setupFeesBeforeMaturity(_feeToken0, _feeToken1);

    // Sync user fees by doing a 0-value transfer (this updates their accrued fees)
    vm.prank(user);
    fixedFeeSwapHook.YIELD_TOKEN().transfer(user, 0);

    // Get user's accrued fees before claiming
    (,, uint256 _accruedToken0, uint256 _accruedToken1) =
      fixedFeeSwapHook.YIELD_TOKEN().userFees(user);

    // Move past maturity
    vm.warp(maturity + 1);

    uint256 _ytBalance = fixedFeeSwapHook.YIELD_TOKEN().balanceOf(user);
    uint256 _initialYtSupply = fixedFeeSwapHook.YIELD_TOKEN().totalSupply();
    uint256 _initialUserToken0Balance = token0.balanceOf(user);
    uint256 _initialUserToken1Balance = token1.balanceOf(user);

    // Claim and burn
    vm.prank(user);
    (uint256 _claimedToken0, uint256 _claimedToken1) = fixedFeeSwapHook.claimYTFeesAfterMaturity();

    // Check tokens are burnt
    assertEq(fixedFeeSwapHook.YIELD_TOKEN().balanceOf(user), 0);
    assertEq(fixedFeeSwapHook.YIELD_TOKEN().totalSupply(), _initialYtSupply - _ytBalance);

    // Check fees are claimed (should match accrued fees)
    assertEq(_claimedToken0, _accruedToken0);
    assertEq(_claimedToken1, _accruedToken1);
    assertEq(token0.balanceOf(user), _initialUserToken0Balance + _accruedToken0);
    assertEq(token1.balanceOf(user), _initialUserToken1Balance + _accruedToken1);
  }

  function testFuzz_RevertIf_BalanceIsZero(address _newUser) public {
    _assumeSafeAddress(_newUser);
    // Ensure the user doesn't have any YT tokens
    vm.assume(fixedFeeSwapHook.YIELD_TOKEN().balanceOf(_newUser) == 0);

    // Move past maturity
    vm.warp(maturity + 1);

    // User has no YT tokens (they were already burned or never had any)
    vm.prank(_newUser);
    vm.expectRevert(FixedFeeSwapHookBase.FixedFeeSwapHook_InsufficientBalance.selector);
    fixedFeeSwapHook.claimYTFeesAfterMaturity();
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
    vm.expectRevert(FixedFeeSwapHookBase.FixedFeeSwapHook_BeforeMaturity.selector);
    fixedFeeSwapHook.claimYTFeesAfterMaturity();
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
    _setupFeesBeforeMaturity(_feeToken0, _feeToken1);

    // Sync user fees
    vm.prank(user);
    fixedFeeSwapHook.YIELD_TOKEN().transfer(user, 0);

    // Get user's accrued fees before claiming
    (,, uint256 _accruedToken0, uint256 _accruedToken1) =
      fixedFeeSwapHook.YIELD_TOKEN().userFees(user);

    // Try to claim exactly at maturity (should succeed since we check <, not <=)
    vm.warp(maturity);

    uint256 _ytBalance = fixedFeeSwapHook.YIELD_TOKEN().balanceOf(user);
    uint256 _initialYtSupply = fixedFeeSwapHook.YIELD_TOKEN().totalSupply();

    // Should succeed at exactly maturity
    vm.prank(user);
    (uint256 _claimedToken0, uint256 _claimedToken1) = fixedFeeSwapHook.claimYTFeesAfterMaturity();

    // Check tokens are burnt
    assertEq(fixedFeeSwapHook.YIELD_TOKEN().balanceOf(user), 0);
    assertEq(fixedFeeSwapHook.YIELD_TOKEN().totalSupply(), _initialYtSupply - _ytBalance);

    // Fees should be claimed (may be 0 due to rounding with very small fees)
    assertEq(_claimedToken0, _accruedToken0);
    assertEq(_claimedToken1, _accruedToken1);
  }
}

contract Redeem is FixedFeeSwapHookTest {
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
    uint256 _userBalance = fixedFeeSwapHook.PRINCIPAL_TOKEN().balanceOf(user);
    _redeemAmount = bound(_redeemAmount, 1, _userBalance);

    // Set up fees before maturity
    _setupFeesBeforeMaturity(_feeToken0, _feeToken1);

    // Sync user fees by doing a 0-value transfer (this updates their accrued fees)
    vm.prank(user);
    fixedFeeSwapHook.YIELD_TOKEN().transfer(user, 0);

    // Get user's accrued fees before redeeming
    (,, uint256 _accruedToken0, uint256 _accruedToken1) =
      fixedFeeSwapHook.YIELD_TOKEN().userFees(user);

    // Get initial balances
    uint256 _initialUserVstBalance = vaultShareToken.balanceOf(user);
    uint256 _initialHookVstBalance = vaultShareToken.balanceOf(address(fixedFeeSwapHook));
    uint256 _initialPtSupply = fixedFeeSwapHook.PRINCIPAL_TOKEN().totalSupply();
    uint256 _initialYtSupply = fixedFeeSwapHook.YIELD_TOKEN().totalSupply();
    uint256 _initialUserToken0Balance = token0.balanceOf(user);
    uint256 _initialUserToken1Balance = token1.balanceOf(user);

    // Approve PT and YT tokens
    _approvePTAndYTForRedeem(user, _redeemAmount);

    // Redeem
    vm.prank(user);
    uint256 _vstAmount = fixedFeeSwapHook.redeem(_redeemAmount);

    // Check VST is transferred
    assertEq(_vstAmount, _redeemAmount);
    assertEq(vaultShareToken.balanceOf(user), _initialUserVstBalance + _redeemAmount);
    assertEq(
      vaultShareToken.balanceOf(address(fixedFeeSwapHook)), _initialHookVstBalance - _redeemAmount
    );

    // Check PT is burned
    assertEq(fixedFeeSwapHook.PRINCIPAL_TOKEN().balanceOf(user), _userBalance - _redeemAmount);
    assertEq(fixedFeeSwapHook.PRINCIPAL_TOKEN().totalSupply(), _initialPtSupply - _redeemAmount);

    // Check YT is burned
    assertEq(fixedFeeSwapHook.YIELD_TOKEN().balanceOf(user), _userBalance - _redeemAmount);
    assertEq(fixedFeeSwapHook.YIELD_TOKEN().totalSupply(), _initialYtSupply - _redeemAmount);

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

    // Assume user is a safe EOA (needed for native ETH transfers)
    _assumeSafeEOA(user);

    // Create a VaultShareToken with native ETH (address(0)) as token0 and ERC20 as token1
    VaultShareToken _vstWithEth =
      new VaultShareToken("Vault Share Token", "VST", address(0), address(token1));

    // Create a new hook with the ETH-enabled VST
    FixedFeeSwapHookHarness _hookWithEth =
      new FixedFeeSwapHookHarness(poolManager, _vstWithEth, maturity);

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

    // Set up post-maturity fees (ETH and ERC20)
    _hookWithEth.exposed_updateFees(_feeToken0, _feeToken1);

    // Fund the hook contract with ETH and ERC20 tokens
    vm.deal(address(_hookWithEth), type(uint128).max);
    deal(address(token1), address(_hookWithEth), type(uint128).max);

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
    uint256 _expectedFeeEth = Math.mulDiv(
      _hookWithEth.postMaturityFeeIndex0Scaled(), _redeemAmount, 1e18, Math.Rounding.Floor
    );
    assertEq(user.balance, _initialUserEthBalance + _expectedFeeEth);

    uint256 _expectedFee1 = Math.mulDiv(
      _hookWithEth.postMaturityFeeIndex1Scaled(), _redeemAmount, 1e18, Math.Rounding.Floor
    );
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

    // Assume user is a safe EOA (needed for native ETH transfers)
    _assumeSafeEOA(user);

    // Create a VaultShareToken with native ETH (address(0)) as token0 and ERC20 as token1
    VaultShareToken _vstWithEth =
      new VaultShareToken("Vault Share Token", "VST", address(0), address(token1));

    // Create a new hook with the ETH-enabled VST
    FixedFeeSwapHookHarness _hookWithEth =
      new FixedFeeSwapHookHarness(poolManager, _vstWithEth, maturity);

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

    // Set up post-maturity fees (ETH and ERC20)
    _hookWithEth.exposed_updateFees(_feeToken0, _feeToken1);

    // Fund the hook contract with ETH and ERC20 tokens
    vm.deal(address(_hookWithEth), type(uint128).max);
    deal(address(token1), address(_hookWithEth), type(uint128).max);

    // Calculate expected fees (using same rounding as contract)
    uint256 _expectedFeeEth = Math.mulDiv(
      _hookWithEth.postMaturityFeeIndex0Scaled(), _redeemAmount, 1e18, Math.Rounding.Floor
    );
    uint256 _expectedFee1 = Math.mulDiv(
      _hookWithEth.postMaturityFeeIndex1Scaled(), _redeemAmount, 1e18, Math.Rounding.Floor
    );

    // Approve PT tokens
    vm.prank(user);
    _hookWithEth.PRINCIPAL_TOKEN().approve(address(_hookWithEth), _redeemAmount);

    // Expect FeesClaimed event (with native ETH address(0) and ERC20 token1)
    vm.expectEmit();
    emit FixedFeeSwapHookBase.FeesClaimed(
      user, address(0), address(token1), _expectedFeeEth, _expectedFee1
    );

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
    uint256 _userBalance = fixedFeeSwapHook.PRINCIPAL_TOKEN().balanceOf(user);
    _redeemAmount = bound(_redeemAmount, 1, _userBalance);

    // Approve PT and YT tokens
    _approvePTAndYTForRedeem(user, _redeemAmount);

    bool _maturityReached = block.timestamp >= fixedFeeSwapHook.MATURITY();

    vm.expectEmit();
    emit FixedFeeSwapHookBase.Redeem(user, _redeemAmount, _maturityReached);
    vm.prank(user);
    fixedFeeSwapHook.redeem(_redeemAmount);
  }

  function test_RevertIf_AmountIsZero() public {
    vm.expectRevert(FixedFeeSwapHookBase.FixedFeeSwapHook_InvalidAmount.selector);
    fixedFeeSwapHook.redeem(0);
  }

  function testFuzz_RevertIf_InsufficientPTBalance(uint256 _depositAmount, uint256 _redeemAmount)
    public
  {
    _depositAmount = _boundToRealisticAmount(_depositAmount);
    _redeemAmount = _boundToRealisticAmount(_redeemAmount);

    // Set up: user deposits VST to get PT and YT before maturity
    _depositVstForUser(user, _depositAmount);
    uint256 _actualPtBalance = fixedFeeSwapHook.PRINCIPAL_TOKEN().balanceOf(user);

    vm.assume(_redeemAmount > _actualPtBalance);

    vm.expectRevert(FixedFeeSwapHookBase.FixedFeeSwapHook_InsufficientBalance.selector);
    vm.prank(user);
    fixedFeeSwapHook.redeem(_redeemAmount);
  }

  function testFuzz_RevertIf_InsufficientYieldTokenBalance(uint256 _depositAmount) public {
    _depositAmount = _boundToRealisticAmount(_depositAmount);

    // User deposits to get PT and YT (equal amounts)
    _depositVstForUser(user, _depositAmount);

    uint256 _ytBalance = fixedFeeSwapHook.YIELD_TOKEN().balanceOf(user);

    // Set PT balance to be YT + 1 to create the scenario where user has enough PT
    // but not enough YT
    uint256 _redeemAmount = _ytBalance + 1;
    deal(address(fixedFeeSwapHook.PRINCIPAL_TOKEN()), user, _redeemAmount);

    // Approve PT tokens (only PT needed since YT check happens first)
    vm.prank(user);
    fixedFeeSwapHook.PRINCIPAL_TOKEN().approve(address(fixedFeeSwapHook), _redeemAmount);

    vm.expectRevert(FixedFeeSwapHookBase.FixedFeeSwapHook_InsufficientBalance.selector);
    vm.prank(user);
    fixedFeeSwapHook.redeem(_redeemAmount);
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
    uint256 _userBalance = fixedFeeSwapHook.PRINCIPAL_TOKEN().balanceOf(user);
    _redeemAmount = bound(_redeemAmount, 1, _userBalance);

    // Manually reduce hook's VST balance to create insufficient balance scenario
    // Set hook's balance to be less than the redeem amount
    uint256 _insufficientBalance = _redeemAmount > 0 ? _redeemAmount - 1 : 0;
    deal(address(vaultShareToken), address(fixedFeeSwapHook), _insufficientBalance);

    // Approve PT tokens
    vm.prank(user);
    fixedFeeSwapHook.PRINCIPAL_TOKEN().approve(address(fixedFeeSwapHook), _redeemAmount);

    // Approve YT tokens if before maturity
    if (block.timestamp < fixedFeeSwapHook.MATURITY()) {
      vm.prank(user);
      fixedFeeSwapHook.YIELD_TOKEN().approve(address(fixedFeeSwapHook), _redeemAmount);
    }

    // Should revert because hook doesn't have enough VST
    vm.expectRevert(FixedFeeSwapHookBase.FixedFeeSwapHook_InsufficientBalance.selector);
    vm.prank(user);
    fixedFeeSwapHook.redeem(_redeemAmount);
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

    // Create a VaultShareToken with native ETH (address(0)) as token0
    VaultShareToken _vstWithEth =
      new VaultShareToken("Vault Share Token", "VST", address(0), address(token1));

    // Create a new hook with the ETH-enabled VST
    FixedFeeSwapHookHarness _hookWithEth =
      new FixedFeeSwapHookHarness(poolManager, _vstWithEth, maturity);

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

    // Set up post-maturity fees (use large fee to ensure non-zero claimable amount)
    _hookWithEth.exposed_updateFees(_feeEth, 0);

    // Fund the hook contract with ETH
    vm.deal(address(_hookWithEth), type(uint128).max);

    // Calculate expected ETH fee to ensure it's non-zero
    uint256 _expectedFeeEth = Math.mulDiv(
      _hookWithEth.postMaturityFeeIndex0Scaled(), _redeemAmount, 1e18, Math.Rounding.Floor
    );

    // Only test if we have non-zero fees to claim
    vm.assume(_expectedFeeEth > 0);

    // Approve PT tokens
    vm.prank(address(_nonPayableContract));
    _hookWithEth.PRINCIPAL_TOKEN().approve(address(_hookWithEth), _redeemAmount);

    // Should revert because non-payable contract cannot receive ETH
    vm.expectRevert(FixedFeeSwapHookBase.FixedFeeSwapHook_TransferFailed.selector);
    vm.prank(address(_nonPayableContract));
    _hookWithEth.redeem(_redeemAmount);
  }
}
