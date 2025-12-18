// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {Test, Vm} from "forge-std/Test.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

// Internal imports
import {FixedFeeSwapHook as FixedFeeSwapHookBase} from "src/FixedFeeSwapHook.sol";
import {VaultShareToken} from "src/VaultShareToken.sol";
import {PrincipalToken} from "src/PrincipalToken.sol";
import {YieldToken} from "src/YieldToken.sol";
import {ERC20Mock} from "test/mock/ERC20Mock.sol";
import {FixedFeeSwapHookHarness} from "test/harness/FixedFeeSwapHookHarness.sol";

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

  function _boundToRealisticAmount(uint256 _amount) internal pure returns (uint256) {
    return bound(_amount, 1, type(uint128).max);
  }

  function _assumeSafeMaturity(uint256 _maturity) internal view {
    vm.assume(_maturity > block.timestamp);
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
    Vm.Log[] memory logs = vm.getRecordedLogs();
    assertEq(logs.length, 1);

    // Decode and verify the event
    // Only poolManager is indexed, so topics[0] = signature, topics[1] = poolManager
    bytes32 _eventSignature = keccak256("Initialized(address,address,address,address,uint256)");
    assertEq(logs[0].topics[0], _eventSignature);
    assertEq(address(uint160(uint256(logs[0].topics[1]))), _poolManager);

    // Decode the event data using abi.decode
    (
      address _vstAddress,
      address _ptAddressFromEvent,
      address _ytAddressFromEvent,
      uint256 _maturityFromEvent
    ) = abi.decode(logs[0].data, (address, address, address, uint256));

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
    assertFalse(_permissions.afterSwap);
    assertFalse(_permissions.beforeDonate);
    assertFalse(_permissions.afterDonate);
    assertFalse(_permissions.beforeSwapReturnDelta);
    assertFalse(_permissions.afterSwapReturnDelta);
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
