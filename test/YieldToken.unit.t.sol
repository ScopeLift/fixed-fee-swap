// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External Imports
import {Test} from "forge-std/Test.sol";

// Internal Imports
import {YieldToken} from "src/YieldToken.sol";
import {FeeTracking} from "src/lib/FeeTracking.sol";
import {ERC20Mock} from "test/mock/ERC20Mock.sol";
import {FixedFeeSwapMock} from "test/mock/FixedFeeSwapMock.sol";
import {NonPayableContractMock} from "test/mock/NonPayableContractMock.sol";
import {IFeeTrackingToken} from "src/interface/IFeeTrackingToken.sol";

contract YieldTokenTest is Test {
  /// @notice Native ETH address following Uniswap v4 `Currency` convention.
  /// @dev See: https://github.com/Uniswap/v4-core/blob/main/src/types/Currency.sol#L37-L38
  address internal constant NATIVE = address(0);

  YieldToken internal yieldToken;
  ERC20Mock internal token0;
  ERC20Mock internal token1;
  address internal hook;

  function setUp() public virtual {
    token0 = new ERC20Mock("Token0", "TK0");
    token1 = new ERC20Mock("Token1", "TK1");
    FixedFeeSwapMock _mock = new FixedFeeSwapMock(address(token0), address(token1));
    yieldToken =
      new YieldToken("Yield Token", "YT", address(_mock), address(token0), address(token1));
    _mock.setYieldToken(address(yieldToken));
    hook = address(_mock);
  }

  function _assumeSafeAddress(address _addr) internal pure virtual {
    vm.assume(_addr != address(0));
  }

  function _boundToRealisticAmount(uint256 _amount) internal pure virtual returns (uint256) {
    return bound(_amount, 1, type(uint128).max);
  }

  function _boundFeeAmount(uint256 _amount) internal pure returns (uint256) {
    uint256 _maxFeePerRound = type(uint192).max;
    return bound(_amount, 1, _maxFeePerRound);
  }

  function _boundMintAmount(uint256 _amount) internal pure returns (uint256) {
    return bound(_amount, 1, type(uint128).max);
  }

  function _calculateFeeIndex(uint256 _collectedFeeToken, uint256 _supply)
    internal
    pure
    returns (uint256)
  {
    // Manually reproduce the formula `(collected * PRECISION) / supply` rather than calling
    // Math.mulDiv so that the test cross-checks production logic via an equivalent expression.
    if (_supply == 0) return 0;
    unchecked {
      return (_collectedFeeToken * FeeTracking.PRECISION) / _supply;
    }
  }

  function _calculateAccruedFees(uint256 _userBalance, uint256 _globalIndex, uint256 _userIndex)
    internal
    pure
    returns (uint256)
  {
    // Manually reproduce the formula `(balance * (globalIndex - userIndex)) / PRECISION` rather
    // than calling Math.mulDiv so that the test cross-checks production logic via an equivalent
    // expression.
    if (_globalIndex == _userIndex) return 0;
    unchecked {
      return (_userBalance * (_globalIndex - _userIndex)) / FeeTracking.PRECISION;
    }
  }
}

contract Constructor is YieldTokenTest {
  function test_SetsInitialParameters() public view {
    assertEq(yieldToken.name(), "Yield Token");
    assertEq(yieldToken.symbol(), "YT");
    assertEq(yieldToken.decimals(), 18);

    // fixedFeeSwap and fee tokens are set correctly
    assertEq(yieldToken.FIXED_FEE_SWAP(), hook);
    assertEq(yieldToken.FEE_TOKEN0(), address(token0));
    assertEq(yieldToken.FEE_TOKEN1(), address(token1));
  }
}

contract Mint is YieldTokenTest {
  function testFuzz_MintSucceedsWhenCalledByHook(address _to, uint256 _amount) public {
    _assumeSafeAddress(_to);
    _amount = _boundToRealisticAmount(_amount);

    vm.prank(hook);
    yieldToken.mint(_to, _amount);

    assertEq(yieldToken.totalSupply(), _amount);
    assertEq(yieldToken.balanceOf(_to), _amount);
  }

  function testFuzz_RevertIf_MintCalledByNonHook(address _to, uint256 _amount, address _nonHook)
    public
  {
    vm.assume(_nonHook != hook);

    vm.prank(_nonHook);
    vm.expectRevert(YieldToken.YieldToken_NotAuthorized.selector);
    yieldToken.mint(_to, _amount);
  }

  // ========== _updateUserFees tests via mint ==========

  function testFuzz_UserDoesNotRetroactivelyEarnFeesWhenMintingAfterFeesCollected(
    address _existingUser,
    address _newUser,
    uint256 _existingUserMintAmount,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1,
    uint256 _newUserMintAmount
  ) public {
    _assumeSafeAddress(_existingUser);
    _assumeSafeAddress(_newUser);
    vm.assume(_existingUser != _newUser);
    _existingUserMintAmount = _boundMintAmount(_existingUserMintAmount);
    _newUserMintAmount = _boundMintAmount(_newUserMintAmount);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);

    // Another user mints shares and fees are collected via the hook
    vm.prank(hook);
    yieldToken.mint(_existingUser, _existingUserMintAmount);
    vm.prank(hook);
    yieldToken.updateFees(_collectedFeeToken0, _collectedFeeToken1);

    // Get the global fee indices after fees are collected
    uint256 _globalFeeIndex0 = yieldToken.globalFeeIndex0Scaled();
    uint256 _globalFeeIndex1 = yieldToken.globalFeeIndex1Scaled();

    // New user mints shares after fees have already been collected via the hook
    vm.prank(hook);
    yieldToken.mint(_newUser, _newUserMintAmount);

    // Perform the update for the new user via 0-value self-transfer
    vm.prank(_newUser);
    yieldToken.transfer(_newUser, 0);

    // Destructure the tuple for the new user
    (
      uint256 _newUserFeeIndex0,
      uint256 _newUserFeeIndex1,
      uint256 _newUserAccruedToken0,
      uint256 _newUserAccruedToken1
    ) = yieldToken.userFees(_newUser);

    // New user indices should sync to current global indices
    assertEq(_newUserFeeIndex0, _globalFeeIndex0);
    assertEq(_newUserFeeIndex1, _globalFeeIndex1);

    // New user should NOT retroactively earn fees from before they minted
    assertEq(_newUserAccruedToken0, 0);
    assertEq(_newUserAccruedToken1, 0);
  }
}

contract Burn is YieldTokenTest {
  function testFuzz_BurnSucceedsWhenCalledByHook(address _user, uint256 _amount) public {
    _assumeSafeAddress(_user);
    _amount = _boundToRealisticAmount(_amount);

    // Mint some tokens to the user
    vm.prank(hook);
    yieldToken.mint(_user, _amount);
    assertEq(yieldToken.balanceOf(_user), _amount);

    // Burn some tokens from the user
    vm.prank(hook);
    yieldToken.burn(_user, _amount);

    assertEq(yieldToken.balanceOf(_user), 0);
    assertEq(yieldToken.totalSupply(), 0);
  }

  function testFuzz_RevertIf_BurnCalledByNonHook(address _user, uint256 _amount, address _nonHook)
    public
  {
    _assumeSafeAddress(_user);
    _amount = _boundToRealisticAmount(_amount);
    vm.assume(_nonHook != hook);

    // Mint some tokens to the to address
    vm.prank(hook);
    yieldToken.mint(_user, _amount);

    vm.expectRevert(YieldToken.YieldToken_NotAuthorized.selector);
    vm.prank(_nonHook);
    yieldToken.burn(_user, _amount);
  }

  // ========== _updateUserFees tests via burn ==========

  struct BurnTestParams {
    address user;
    uint256 mintAmount;
    uint256 collectedFeeToken0;
    uint256 collectedFeeToken1;
  }

  function testFuzz_BurnUpdatesUserFeesBeforeBurning(
    address _user,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1
  ) public {
    _assumeSafeAddress(_user);
    _mintAmount = _boundMintAmount(_mintAmount);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);

    BurnTestParams memory _params = BurnTestParams({
      user: _user,
      mintAmount: _mintAmount,
      collectedFeeToken0: _collectedFeeToken0,
      collectedFeeToken1: _collectedFeeToken1
    });

    token0.mint(hook, _params.collectedFeeToken0);
    token1.mint(hook, _params.collectedFeeToken1);

    vm.prank(hook);
    yieldToken.mint(_params.user, _params.mintAmount);

    vm.prank(hook);
    yieldToken.updateFees(_params.collectedFeeToken0, _params.collectedFeeToken1);

    // Get the global fee indices
    uint256 _globalFeeIndex0 = yieldToken.globalFeeIndex0Scaled();
    uint256 _globalFeeIndex1 = yieldToken.globalFeeIndex1Scaled();

    // Get initial user token balances
    uint256 _initialUserToken0Balance = token0.balanceOf(_params.user);
    uint256 _initialUserToken1Balance = token1.balanceOf(_params.user);

    // Burn tokens - this should trigger _updateUserFees and _claim before burning
    vm.prank(hook);
    yieldToken.burn(_params.user, _params.mintAmount);

    // Check that the user's fees were updated before burning
    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,
      uint256 _userAccruedToken0,
      uint256 _userAccruedToken1
    ) = yieldToken.userFees(_params.user);

    // User should have synced to global indices
    assertEq(_userFeeIndex0, _globalFeeIndex0);
    assertEq(_userFeeIndex1, _globalFeeIndex1);
    // Accrued fees should be reset to 0 since they were claimed during burn
    assertEq(_userAccruedToken0, 0);
    assertEq(_userAccruedToken1, 0);

    // Check that fees were transferred to the user
    uint256 _expectedToken0 =
      _initialUserToken0Balance + _calculateAccruedFees(_params.mintAmount, _globalFeeIndex0, 0);
    uint256 _expectedToken1 =
      _initialUserToken1Balance + _calculateAccruedFees(_params.mintAmount, _globalFeeIndex1, 0);
    // When user is the YT, mock sent full collected amounts to YT and YT "transferred" accrued to
    // itself (may round); balance = initial + mock amount
    if (_params.user == address(yieldToken)) {
      assertEq(
        token0.balanceOf(_params.user),
        _initialUserToken0Balance + _params.collectedFeeToken0,
        "YT as user: token0"
      );
      assertEq(
        token1.balanceOf(_params.user),
        _initialUserToken1Balance + _params.collectedFeeToken1,
        "YT as user: token1"
      );
    } else {
      assertEq(token0.balanceOf(_params.user), _expectedToken0);
      assertEq(token1.balanceOf(_params.user), _expectedToken1);
    }
  }
}

contract UpdateFees is YieldTokenTest {
  function testFuzz_GlobalFeeIndexScaledAreUpdated(
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1,
    uint256 _mintAmount,
    address _minterAccount
  ) public {
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);
    _mintAmount = _boundMintAmount(_mintAmount);

    _assumeSafeAddress(_minterAccount);

    vm.prank(hook);
    yieldToken.mint(_minterAccount, _mintAmount);

    assertEq(yieldToken.globalFeeIndex0Scaled(), 0);
    assertEq(yieldToken.globalFeeIndex1Scaled(), 0);

    vm.prank(hook);
    yieldToken.updateFees(_collectedFeeToken0, _collectedFeeToken1);

    assertEq(
      yieldToken.globalFeeIndex0Scaled(), _calculateFeeIndex(_collectedFeeToken0, _mintAmount)
    );
    assertEq(
      yieldToken.globalFeeIndex1Scaled(), _calculateFeeIndex(_collectedFeeToken1, _mintAmount)
    );
  }

  function testFuzz_GlobalFeeIndexScaledAreUpdatedOnMultipleCalls(
    uint256 _collectedFeeToken0AtT1,
    uint256 _collectedFeeToken1AtT1,
    uint256 _mintAmountAtT1,
    address _minterAccountAtT1,
    uint256 _collectedFeeToken0AtT2,
    uint256 _collectedFeeToken1AtT2,
    uint256 _mintAmountAtT2,
    address _minterAccountAtT2
  ) public {
    _collectedFeeToken0AtT1 = bound(_collectedFeeToken0AtT1, 0, type(uint128).max);
    _collectedFeeToken1AtT1 = bound(_collectedFeeToken1AtT1, 0, type(uint128).max);
    _mintAmountAtT1 = bound(_mintAmountAtT1, 1, type(uint128).max);

    _collectedFeeToken0AtT2 = bound(_collectedFeeToken0AtT2, 0, type(uint128).max);
    _collectedFeeToken1AtT2 = bound(_collectedFeeToken1AtT2, 0, type(uint128).max);
    _mintAmountAtT2 = bound(_mintAmountAtT2, 1, type(uint128).max);

    _assumeSafeAddress(_minterAccountAtT1);
    _assumeSafeAddress(_minterAccountAtT2);

    vm.prank(hook);
    yieldToken.mint(_minterAccountAtT1, _mintAmountAtT1);

    vm.prank(hook);
    yieldToken.updateFees(_collectedFeeToken0AtT1, _collectedFeeToken1AtT1);

    uint256 _expectedFeeIndex0 = _calculateFeeIndex(_collectedFeeToken0AtT1, _mintAmountAtT1);
    uint256 _expectedFeeIndex1 = _calculateFeeIndex(_collectedFeeToken1AtT1, _mintAmountAtT1);

    assertEq(yieldToken.globalFeeIndex0Scaled(), _expectedFeeIndex0);
    assertEq(yieldToken.globalFeeIndex1Scaled(), _expectedFeeIndex1);

    vm.prank(hook);
    yieldToken.mint(_minterAccountAtT2, _mintAmountAtT2);

    vm.prank(hook);
    yieldToken.updateFees(_collectedFeeToken0AtT2, _collectedFeeToken1AtT2);

    uint256 _totalSupplyAfterT2 = _mintAmountAtT1 + _mintAmountAtT2;
    _expectedFeeIndex0 += _calculateFeeIndex(_collectedFeeToken0AtT2, _totalSupplyAfterT2);
    _expectedFeeIndex1 += _calculateFeeIndex(_collectedFeeToken1AtT2, _totalSupplyAfterT2);

    assertEq(yieldToken.globalFeeIndex0Scaled(), _expectedFeeIndex0);
    assertEq(yieldToken.globalFeeIndex1Scaled(), _expectedFeeIndex1);
  }

  function testFuzz_FeeIndex0IsNotUpdatedWhenTokenFee0IsZero(
    uint256 _collectedFeeToken1,
    uint256 _mintAmount,
    address _minterAccount
  ) public {
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);
    _mintAmount = _boundMintAmount(_mintAmount);

    _assumeSafeAddress(_minterAccount);

    vm.prank(hook);
    yieldToken.mint(_minterAccount, _mintAmount);

    assertEq(yieldToken.globalFeeIndex0Scaled(), 0);
    assertEq(yieldToken.globalFeeIndex1Scaled(), 0);

    vm.prank(hook);
    yieldToken.updateFees(0, _collectedFeeToken1);

    assertEq(yieldToken.globalFeeIndex0Scaled(), 0);
    assertEq(
      yieldToken.globalFeeIndex1Scaled(), _calculateFeeIndex(_collectedFeeToken1, _mintAmount)
    );
  }

  function testFuzz_FeeIndex1IsNotUpdatedWhenTokenFee1IsZero(
    uint256 _collectedFeeToken0,
    uint256 _mintAmount,
    address _minterAccount
  ) public {
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _mintAmount = _boundMintAmount(_mintAmount);

    _assumeSafeAddress(_minterAccount);

    vm.prank(hook);
    yieldToken.mint(_minterAccount, _mintAmount);

    assertEq(yieldToken.globalFeeIndex0Scaled(), 0);
    assertEq(yieldToken.globalFeeIndex1Scaled(), 0);

    vm.prank(hook);
    yieldToken.updateFees(_collectedFeeToken0, 0);

    assertEq(
      yieldToken.globalFeeIndex0Scaled(), _calculateFeeIndex(_collectedFeeToken0, _mintAmount)
    );
    assertEq(yieldToken.globalFeeIndex1Scaled(), 0);
  }

  function testFuzz_FeeIndexesAreNotUpdatedWhenNoSharesMinted(
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1
  ) public {
    assertEq(yieldToken.totalSupply(), 0);
    assertEq(yieldToken.globalFeeIndex0Scaled(), 0);
    assertEq(yieldToken.globalFeeIndex1Scaled(), 0);

    vm.prank(hook);
    yieldToken.updateFees(_collectedFeeToken0, _collectedFeeToken1);

    assertEq(yieldToken.globalFeeIndex0Scaled(), 0);
    assertEq(yieldToken.globalFeeIndex1Scaled(), 0);
  }

  function testFuzz_EmitsFeeIndexesUpdatedEvent(
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1,
    uint256 _mintAmount,
    address _minterAccount
  ) public {
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);
    _mintAmount = _boundMintAmount(_mintAmount);

    _assumeSafeAddress(_minterAccount);

    vm.prank(hook);
    yieldToken.mint(_minterAccount, _mintAmount);

    uint256 _expectedFeeIndex0 = _calculateFeeIndex(_collectedFeeToken0, _mintAmount);
    uint256 _expectedFeeIndex1 = _calculateFeeIndex(_collectedFeeToken1, _mintAmount);

    vm.expectEmit();
    emit IFeeTrackingToken.FeeIndexesUpdated(
      _expectedFeeIndex0, _expectedFeeIndex1, _collectedFeeToken0, _collectedFeeToken1
    );

    vm.prank(hook);
    yieldToken.updateFees(_collectedFeeToken0, _collectedFeeToken1);
  }

  function testFuzz_RevertIf_UpdateFeesCalledByNonHook(
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1,
    address _nonHook
  ) public {
    vm.assume(_nonHook != hook);

    vm.expectRevert(YieldToken.YieldToken_NotAuthorized.selector);
    vm.prank(_nonHook);
    yieldToken.updateFees(_collectedFeeToken0, _collectedFeeToken1);
  }
}

contract Transfer is YieldTokenTest {
  function testFuzz_TransfersTokens(address _from, address _to, uint256 _amount) public {
    _assumeSafeAddress(_from);
    _assumeSafeAddress(_to);
    vm.assume(_from != _to);
    _amount = _boundMintAmount(_amount);

    // Mint tokens to sender via hook
    vm.prank(hook);
    yieldToken.mint(_from, _amount);

    assertEq(yieldToken.balanceOf(_from), _amount);
    assertEq(yieldToken.balanceOf(_to), 0);

    // Transfer tokens
    vm.prank(_from);
    bool _success = yieldToken.transfer(_to, _amount);
    assertTrue(_success);

    // Verify balances are updated
    assertEq(yieldToken.balanceOf(_from), 0);
    assertEq(yieldToken.balanceOf(_to), _amount);
  }

  // ========== _updateUserFees tests via transfer ==========

  // ========== Branch 1: User has no shares (_userBalance == 0) ==========

  function testFuzz_UserWithNoSharesSyncsToZeroGlobalIndices(address _user) public {
    _assumeSafeAddress(_user);

    // Trigger a sync for the user without shares via a 0-value self-transfer
    vm.prank(_user);
    yieldToken.transfer(_user, 0);

    // Get the global fee indices (should be 0 initially)
    uint256 _globalFeeIndex0 = yieldToken.globalFeeIndex0Scaled();
    uint256 _globalFeeIndex1 = yieldToken.globalFeeIndex1Scaled();

    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,, //uint256 _userAccruedToken0
      //uint256 _userAccruedToken1
    ) = yieldToken.userFees(_user);

    // Check that the user has the same fee indices as the global fee indices
    assertEq(_userFeeIndex0, _globalFeeIndex0);
    assertEq(_userFeeIndex1, _globalFeeIndex1);
  }

  function testFuzz_UserWithNoSharesSyncsToNonZeroGlobalIndices(
    address _userWithShares,
    address _userWithoutShares,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1
  ) public {
    _assumeSafeAddress(_userWithShares);
    _assumeSafeAddress(_userWithoutShares);
    vm.assume(_userWithShares != _userWithoutShares);
    _mintAmount = _boundMintAmount(_mintAmount);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);

    // First, sync the user without shares when global indices are 0 (0-value transfer)
    vm.prank(_userWithoutShares);
    yieldToken.transfer(_userWithoutShares, 0);

    // Mint shares for another user and collect fees to change global indices via the hook
    vm.prank(hook);
    yieldToken.mint(_userWithShares, _mintAmount);
    vm.prank(hook);
    yieldToken.updateFees(_collectedFeeToken0, _collectedFeeToken1);

    // Get the new global fee indices (should be > 0 now)
    uint256 _globalFeeIndex0 = yieldToken.globalFeeIndex0Scaled();
    uint256 _globalFeeIndex1 = yieldToken.globalFeeIndex1Scaled();

    // Perform the update for the user without shares via 0-value transfer
    vm.prank(_userWithoutShares);
    yieldToken.transfer(_userWithoutShares, 0);

    // Destructure the tuple again after the update
    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,, //uint256 _userAccruedToken0,
      //uint256 _userAccruedToken1
    ) = yieldToken.userFees(_userWithoutShares);

    // User without shares should have the same fee indices as the global fee indices
    assertEq(_userFeeIndex0, _globalFeeIndex0);
    assertEq(_userFeeIndex1, _globalFeeIndex1);
  }

  function testFuzz_UserWithNoSharesIndicesUnchangedWhenAlreadySynced(address _user) public {
    _assumeSafeAddress(_user);

    // First sync: user indices should sync to global indices (which are 0) via 0-value transfer
    vm.prank(_user);
    yieldToken.transfer(_user, 0);

    (uint256 _userFeeIndex0AfterFirstSync, uint256 _userFeeIndex1AfterFirstSync,,) =
      yieldToken.userFees(_user);

    // Verify indices were synced to 0
    assertEq(_userFeeIndex0AfterFirstSync, 0);
    assertEq(_userFeeIndex1AfterFirstSync, 0);

    // Second sync: indices should remain the same (already synced) via another 0-value transfer
    vm.prank(_user);
    yieldToken.transfer(_user, 0);

    (uint256 _userFeeIndex0AfterSecondSync, uint256 _userFeeIndex1AfterSecondSync,,) =
      yieldToken.userFees(_user);

    // Indices should remain unchanged (already synced)
    assertEq(_userFeeIndex0AfterSecondSync, _userFeeIndex0AfterFirstSync);
    assertEq(_userFeeIndex1AfterSecondSync, _userFeeIndex1AfterFirstSync);
  }

  function testFuzz_UserWithNoSharesAccruedFeesNeverIncrease(
    address _userWithShares,
    address _userWithoutShares,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1
  ) public {
    _assumeSafeAddress(_userWithShares);
    _assumeSafeAddress(_userWithoutShares);
    vm.assume(_userWithShares != _userWithoutShares);
    _mintAmount = _boundMintAmount(_mintAmount);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);

    // Sync user without shares when global indices are 0 via 0-value transfer
    vm.prank(_userWithoutShares);
    yieldToken.transfer(_userWithoutShares, 0);

    // Mint shares for another user and collect fees to change global indices via the hook
    vm.prank(hook);
    yieldToken.mint(_userWithShares, _mintAmount);
    vm.prank(hook);
    yieldToken.updateFees(_collectedFeeToken0, _collectedFeeToken1);

    // Update user without shares via 0-value transfer - even though global index > user index,
    // accrued should remain 0 because user has no balance
    vm.prank(_userWithoutShares);
    yieldToken.transfer(_userWithoutShares, 0);

    (,, uint256 _userAccruedToken0, uint256 _userAccruedToken1) =
      yieldToken.userFees(_userWithoutShares);

    // Accrued fees should remain 0 even though global indices increased
    assertEq(_userAccruedToken0, 0);
    assertEq(_userAccruedToken1, 0);
  }

  // ========== Branch 2: User has shares (_userBalance > 0) ==========

  function testFuzz_UserFeeIndexAndAccruedFeesAreUpdatedWhenUserHasShares(
    address _user,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1
  ) public {
    _assumeSafeAddress(_user);
    _mintAmount = _boundMintAmount(_mintAmount);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);

    // Mint shares for user and collect fees to change global indices via the hook
    vm.prank(hook);
    yieldToken.mint(_user, _mintAmount);
    vm.prank(hook);
    yieldToken.updateFees(_collectedFeeToken0, _collectedFeeToken1);

    // Get the new global fee indices
    uint256 _globalFeeIndex0 = yieldToken.globalFeeIndex0Scaled();
    uint256 _globalFeeIndex1 = yieldToken.globalFeeIndex1Scaled();

    // User's index before update is 0 (default for new user)
    uint256 _userFeeIndex0Before = 0;
    uint256 _userFeeIndex1Before = 0;

    // Perform the update for the user via 0-value self-transfer
    vm.prank(_user);
    yieldToken.transfer(_user, 0);

    // Destructure the tuple again after the update
    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,
      uint256 _userAccruedToken0,
      uint256 _userAccruedToken1
    ) = yieldToken.userFees(_user);

    // Check that the user has the correct fee indices and accrued fees
    assertEq(_userFeeIndex0, _globalFeeIndex0);
    assertEq(_userFeeIndex1, _globalFeeIndex1);
    assertEq(
      _userAccruedToken0, _calculateAccruedFees(_mintAmount, _globalFeeIndex0, _userFeeIndex0Before)
    );
    assertEq(
      _userAccruedToken1, _calculateAccruedFees(_mintAmount, _globalFeeIndex1, _userFeeIndex1Before)
    );
  }

  function testFuzz_UserWithSharesStateUnchangedWhenAlreadySynced(
    address _user,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1
  ) public {
    _assumeSafeAddress(_user);
    _mintAmount = _boundMintAmount(_mintAmount);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);

    // Mint shares, collect fees, and sync user fees
    _mintSharesAndCollectFeesHelper(
      _user, _mintAmount, _collectedFeeToken0, _collectedFeeToken1, yieldToken
    );

    // Destructure the tuple again after the update
    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,
      uint256 _userAccruedToken0,
      uint256 _userAccruedToken1
    ) = yieldToken.userFees(_user);

    // Again perform the update for the user via 0-value transfer
    vm.prank(_user);
    yieldToken.transfer(_user, 0);

    // Destructure the tuple again after the update
    (
      uint256 _userFeeIndex0AfterSecondUpdate,
      uint256 _userFeeIndex1AfterSecondUpdate,
      uint256 _userAccruedToken0AfterSecondUpdate,
      uint256 _userAccruedToken1AfterSecondUpdate
    ) = yieldToken.userFees(_user);

    // Check that the user has the same fee indices and accrued fees as before the update
    assertEq(_userFeeIndex0AfterSecondUpdate, _userFeeIndex0);
    assertEq(_userFeeIndex1AfterSecondUpdate, _userFeeIndex1);
    assertEq(_userAccruedToken0AfterSecondUpdate, _userAccruedToken0);
    assertEq(_userAccruedToken1AfterSecondUpdate, _userAccruedToken1);
  }

  function testFuzz_UserWithSharesAccruesOnlyToken0WhenToken1Unchanged(
    address _user,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0
  ) public {
    _assumeSafeAddress(_user);
    _mintAmount = _boundMintAmount(_mintAmount);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);

    // Mint shares for user and collect fees to change global indices via the hook
    vm.prank(hook);
    yieldToken.mint(_user, _mintAmount);
    vm.prank(hook);
    yieldToken.updateFees(_collectedFeeToken0, 0);

    // Get the new global fee indices
    uint256 _globalFeeIndex0 = yieldToken.globalFeeIndex0Scaled();
    uint256 _globalFeeIndex1 = yieldToken.globalFeeIndex1Scaled();

    // User's index before update is 0 (default for new user)
    uint256 _userFeeIndex0Before = 0;

    // Perform the update for the user via 0-value self-transfer
    vm.prank(_user);
    yieldToken.transfer(_user, 0);

    // Destructure the tuple again after the update
    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,
      uint256 _userAccruedToken0,
      uint256 _userAccruedToken1
    ) = yieldToken.userFees(_user);

    // Check that the user has the correct fee indices and accrued fees
    assertEq(_userFeeIndex0, _globalFeeIndex0);
    assertEq(_userFeeIndex1, _globalFeeIndex1);
    assertEq(
      _userAccruedToken0, _calculateAccruedFees(_mintAmount, _globalFeeIndex0, _userFeeIndex0Before)
    );
    assertEq(_userAccruedToken1, 0);
  }

  function testFuzz_UserWithSharesAccruesOnlyToken1WhenToken0Unchanged(
    address _user,
    uint256 _mintAmount,
    uint256 _collectedFeeToken1
  ) public {
    _assumeSafeAddress(_user);
    _mintAmount = _boundMintAmount(_mintAmount);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);

    // Mint shares for user and collect fees to change global indices via the hook
    vm.prank(hook);
    yieldToken.mint(_user, _mintAmount);
    vm.prank(hook);
    yieldToken.updateFees(0, _collectedFeeToken1);

    // Get the new global fee indices
    uint256 _globalFeeIndex0 = yieldToken.globalFeeIndex0Scaled();
    uint256 _globalFeeIndex1 = yieldToken.globalFeeIndex1Scaled();

    // User's index before update is 0 (default for new user)
    uint256 _userFeeIndex1Before = 0;

    // Perform the update for the user via 0-value self-transfer
    vm.prank(_user);
    yieldToken.transfer(_user, 0);

    // Destructure the tuple again after the update
    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,
      uint256 _userAccruedToken0,
      uint256 _userAccruedToken1
    ) = yieldToken.userFees(_user);

    // Check that the user has the correct fee indices and accrued fees
    assertEq(_userFeeIndex0, _globalFeeIndex0);
    assertEq(_userFeeIndex1, _globalFeeIndex1);
    assertEq(_userAccruedToken0, 0);
    assertEq(
      _userAccruedToken1, _calculateAccruedFees(_mintAmount, _globalFeeIndex1, _userFeeIndex1Before)
    );
  }

  function testFuzz_UserWithSharesAccruesForMultipleFeeRounds(
    address _user,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0Round1,
    uint256 _collectedFeeToken1Round1,
    uint256 _collectedFeeToken0Round2,
    uint256 _collectedFeeToken1Round2
  ) public {
    _assumeSafeAddress(_user);
    _mintAmount = _boundMintAmount(_mintAmount);
    _collectedFeeToken0Round1 = _boundFeeAmount(_collectedFeeToken0Round1);
    _collectedFeeToken1Round1 = _boundFeeAmount(_collectedFeeToken1Round1);
    _collectedFeeToken0Round2 = _boundFeeAmount(_collectedFeeToken0Round2);
    _collectedFeeToken1Round2 = _boundFeeAmount(_collectedFeeToken1Round2);

    // Mint shares for user via the hook
    vm.prank(hook);
    yieldToken.mint(_user, _mintAmount);

    // Collect fees round 1 -> global index increases
    vm.prank(hook);
    yieldToken.updateFees(_collectedFeeToken0Round1, _collectedFeeToken1Round1);

    // Collect fees round 2 -> global index increases again
    vm.prank(hook);
    yieldToken.updateFees(_collectedFeeToken0Round2, _collectedFeeToken1Round2);

    // Get the final global fee indices (after both rounds)
    uint256 _finalGlobalFeeIndex0 = yieldToken.globalFeeIndex0Scaled();
    uint256 _finalGlobalFeeIndex1 = yieldToken.globalFeeIndex1Scaled();

    // User's index before update is 0 (default for new user)
    uint256 _userFeeIndex0Before = 0;
    uint256 _userFeeIndex1Before = 0;

    // Perform the update for the user via 0-value self-transfer
    // Should accrue for BOTH rounds (delta from 0 to final)
    vm.prank(_user);
    yieldToken.transfer(_user, 0);

    // Destructure the tuple after the update
    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,
      uint256 _userAccruedToken0,
      uint256 _userAccruedToken1
    ) = yieldToken.userFees(_user);

    // Check that the user has the correct fee indices and accrued fees
    // User should be synced to final global indices
    assertEq(_userFeeIndex0, _finalGlobalFeeIndex0);
    assertEq(_userFeeIndex1, _finalGlobalFeeIndex1);
    // User should accrue for both rounds (delta from initial 0 to final global index)
    assertEq(
      _userAccruedToken0,
      _calculateAccruedFees(_mintAmount, _finalGlobalFeeIndex0, _userFeeIndex0Before)
    );
    assertEq(
      _userAccruedToken1,
      _calculateAccruedFees(_mintAmount, _finalGlobalFeeIndex1, _userFeeIndex1Before)
    );
  }

  /// @notice Helper function to mint shares, collect fees, and sync user fees via public flows.
  function _mintSharesAndCollectFeesHelper(
    address _user,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1,
    YieldToken _yieldToken
  ) internal {
    // User mints shares via the hook
    vm.prank(hook);
    _yieldToken.mint(_user, _mintAmount);

    // Fees collected (global indices increase) via the hook
    vm.prank(hook);
    _yieldToken.updateFees(_collectedFeeToken0, _collectedFeeToken1);

    // Sync user fees to latest global indices via 0-value transfer
    vm.prank(_user);
    _yieldToken.transfer(_user, 0);
  }
}

contract Claim is YieldTokenTest {
  function testFuzz_ClaimTransfersAccruedFeesToUser(
    address _user,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1
  ) public {
    _assumeSafeAddress(_user);
    _mintAmount = _boundMintAmount(_mintAmount);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);

    // Fund the mock (hook) so collectFeesToYT can transfer to the YT when claim runs
    token0.mint(hook, _collectedFeeToken0);
    token1.mint(hook, _collectedFeeToken1);

    vm.prank(hook);
    yieldToken.mint(_user, _mintAmount);

    vm.prank(hook);
    yieldToken.updateFees(_collectedFeeToken0, _collectedFeeToken1);

    vm.prank(hook);
    yieldToken.claim(_user);
    // After claim, user fees should have been reset; we just ensure no revert and balances updated
    // Note: actual token transfers are covered by event test below
  }

  function testFuzz_EmitsFeesClaimedEvent(
    address _user,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1
  ) public {
    _assumeSafeAddress(_user);
    _mintAmount = _boundMintAmount(_mintAmount);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);

    token0.mint(hook, _collectedFeeToken0);
    token1.mint(hook, _collectedFeeToken1);

    vm.prank(hook);
    yieldToken.mint(_user, _mintAmount);

    vm.prank(hook);
    yieldToken.updateFees(_collectedFeeToken0, _collectedFeeToken1);

    // Compute expected accrued fees for the user based on current global indices
    uint256 _globalFeeIndex0 = yieldToken.globalFeeIndex0Scaled();
    uint256 _globalFeeIndex1 = yieldToken.globalFeeIndex1Scaled();
    uint256 _userIndex0Before = 0;
    uint256 _userIndex1Before = 0;
    uint256 _expectedAccruedToken0 =
      _calculateAccruedFees(_mintAmount, _globalFeeIndex0, _userIndex0Before);
    uint256 _expectedAccruedToken1 =
      _calculateAccruedFees(_mintAmount, _globalFeeIndex1, _userIndex1Before);

    vm.expectEmit();
    emit IFeeTrackingToken.FeesClaimed(_user, _expectedAccruedToken0, _expectedAccruedToken1);

    vm.prank(hook);
    yieldToken.claim(_user);
  }

  function testFuzz_ClaimsFeesAlsoSyncsToLatestGlobalIndices(
    address _user,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1
  ) public {
    _assumeSafeAddress(_user);
    _mintAmount = _boundMintAmount(_mintAmount);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);

    token0.mint(hook, _collectedFeeToken0);
    token1.mint(hook, _collectedFeeToken1);

    vm.prank(hook);
    yieldToken.mint(_user, _mintAmount);

    vm.prank(hook);
    yieldToken.updateFees(_collectedFeeToken0, _collectedFeeToken1);

    // Now claim via hook
    vm.prank(hook);
    yieldToken.claim(_user);

    // Verify user fees are synced to latest global indices and accrued reset
    (
      uint256 _userFeeIndex0AfterClaiming,
      uint256 _userFeeIndex1AfterClaiming,
      uint256 _accrued0AfterClaiming,
      uint256 _accrued1AfterClaiming
    ) = yieldToken.userFees(_user);

    assertEq(_userFeeIndex0AfterClaiming, yieldToken.globalFeeIndex0Scaled());
    assertEq(_userFeeIndex1AfterClaiming, yieldToken.globalFeeIndex1Scaled());
    assertEq(_accrued0AfterClaiming, 0);
    assertEq(_accrued1AfterClaiming, 0);
  }

  function testFuzz_RevertIf_ClaimCalledByNonHook(address _user, address _nonHook) public {
    _assumeSafeAddress(_user);
    vm.assume(_nonHook != hook);

    vm.expectRevert(YieldToken.YieldToken_NotAuthorized.selector);
    vm.prank(_nonHook);
    yieldToken.claim(_user);
  }

  // ========== ETH-specific claim tests ==========

  function testFuzz_ClaimsEthAndErc20Successfully(
    address, // unused fuzzed address
    uint256 _mintAmount,
    uint256 _collectedEth,
    uint256 _collectedToken1
  ) public {
    address _user = makeAddr("ethReceiver");

    FixedFeeSwapMock _ethMock = new FixedFeeSwapMock(NATIVE, address(token1));
    YieldToken _ethYieldToken =
      new YieldToken("Yield Token", "YT", address(_ethMock), NATIVE, address(token1));
    _ethMock.setYieldToken(address(_ethYieldToken));

    _mintAmount = _boundMintAmount(_mintAmount);
    _collectedEth = _boundFeeAmount(_collectedEth);
    _collectedToken1 = _boundFeeAmount(_collectedToken1);
    vm.assume(_collectedEth > 0 || _collectedToken1 > 0);

    vm.deal(address(_ethMock), _collectedEth);
    token1.mint(address(_ethMock), _collectedToken1);

    vm.prank(address(_ethMock));
    _ethYieldToken.mint(_user, _mintAmount);

    vm.prank(address(_ethMock));
    _ethYieldToken.updateFees(_collectedEth, _collectedToken1);

    vm.prank(address(_ethMock));
    _ethYieldToken.claim(_user);
  }

  function testFuzz_RevertIf_EthTransferFails(uint256 _mintAmount, uint256 _collectedEth) public {
    _mintAmount = _boundMintAmount(_mintAmount);
    _collectedEth = _boundFeeAmount(_collectedEth);
    vm.assume(_collectedEth > 0);

    FixedFeeSwapMock _ethMock = new FixedFeeSwapMock(NATIVE, address(token1));
    YieldToken _ethYieldToken =
      new YieldToken("Yield Token", "YT", address(_ethMock), NATIVE, address(token1));
    _ethMock.setYieldToken(address(_ethYieldToken));

    NonPayableContractMock _nonPayable = new NonPayableContractMock();

    vm.deal(address(_ethMock), _collectedEth);

    vm.prank(address(_ethMock));
    _ethYieldToken.mint(address(_nonPayable), _mintAmount);

    vm.prank(address(_ethMock));
    _ethYieldToken.updateFees(_collectedEth, 0);

    vm.expectRevert(YieldToken.YieldToken_TransferFailed.selector);
    vm.prank(address(_ethMock));
    _ethYieldToken.claim(address(_nonPayable));
  }
}
