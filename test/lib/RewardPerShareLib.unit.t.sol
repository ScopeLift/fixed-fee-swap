// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// External Imports
import {Test} from "forge-std/Test.sol";

// Internal Imports
import {RewardPerShareLib} from "src/lib/RewardPerShareLib.sol";

/// @notice Test harness to expose library functions for testing
contract RewardPerShareLibHarness {
  RewardPerShareLib.GlobalFeeIndexes public globalFeeIndexes;
  mapping(address => RewardPerShareLib.UserFees) public userFees;

  function updateFees(
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1,
    uint256 _totalSupply
  ) external {
    RewardPerShareLib._updateFees(
      globalFeeIndexes, _collectedFeeToken0, _collectedFeeToken1, _totalSupply
    );
  }

  function updateUserFees(address _user, uint256 _userBalance) external {
    RewardPerShareLib._updateUserFees(userFees[_user], globalFeeIndexes, _userBalance);
  }

  function getGlobalFeeIndex0Scaled() external view returns (uint256) {
    return globalFeeIndexes.globalFeeIndex0Scaled;
  }

  function getGlobalFeeIndex1Scaled() external view returns (uint256) {
    return globalFeeIndexes.globalFeeIndex1Scaled;
  }

  function getUserFees(address _user)
    external
    view
    returns (
      uint256 userFeeIndexToken0Scaled,
      uint256 userFeeIndexToken1Scaled,
      uint256 userAccruedToken0,
      uint256 userAccruedToken1
    )
  {
    RewardPerShareLib.UserFees memory _fees = userFees[_user];
    return (
      _fees.userFeeIndexToken0Scaled,
      _fees.userFeeIndexToken1Scaled,
      _fees.userAccruedToken0,
      _fees.userAccruedToken1
    );
  }
}

contract RewardPerShareLibTest is Test {
  RewardPerShareLibHarness public lib;

  function setUp() public virtual {
    lib = new RewardPerShareLibHarness();
  }

  function _assumeSafeAddress(address _address) internal pure {
    vm.assume(_address != address(0));
  }

  function _assumeSafeAmount(uint256 _amount) internal pure {
    vm.assume(_amount != 0);
  }

  function _boundFeeAmount(uint256 _amount) internal pure returns (uint256) {
    // Bound fees so that, even with minimal supply and multiple fee rounds,
    // the cumulative fee index updates cannot overflow uint256.
    //
    // Each update adds ~ collectedFee * PRECISION / totalSupply.
    // We divide by an extra safety factor (4) so several maximal rounds remain safe.
    uint256 _maxFeePerRound = type(uint256).max / RewardPerShareLib.PRECISION / 4;
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
      return (_collectedFeeToken * RewardPerShareLib.PRECISION) / _supply;
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
    if (_globalIndex <= _userIndex) return 0;
    unchecked {
      return (_userBalance * (_globalIndex - _userIndex)) / RewardPerShareLib.PRECISION;
    }
  }
}

contract UpdateFees is RewardPerShareLibTest {
  function testFuzz_FeeIndexesAreUpdated(
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1,
    uint256 _totalSupply
  ) public {
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);
    _totalSupply = _boundMintAmount(_totalSupply);

    assertEq(lib.getGlobalFeeIndex0Scaled(), 0);
    assertEq(lib.getGlobalFeeIndex1Scaled(), 0);

    lib.updateFees(_collectedFeeToken0, _collectedFeeToken1, _totalSupply);

    assertEq(lib.getGlobalFeeIndex0Scaled(), _calculateFeeIndex(_collectedFeeToken0, _totalSupply));
    assertEq(lib.getGlobalFeeIndex1Scaled(), _calculateFeeIndex(_collectedFeeToken1, _totalSupply));
  }

  function testFuzz_FeeIndexesAreCumulative(
    uint256 _collectedFeeToken0Round1,
    uint256 _collectedFeeToken1Round1,
    uint256 _collectedFeeToken0Round2,
    uint256 _collectedFeeToken1Round2,
    uint256 _totalSupply
  ) public {
    _collectedFeeToken0Round1 = _boundFeeAmount(_collectedFeeToken0Round1);
    _collectedFeeToken1Round1 = _boundFeeAmount(_collectedFeeToken1Round1);
    _collectedFeeToken0Round2 = _boundFeeAmount(_collectedFeeToken0Round2);
    _collectedFeeToken1Round2 = _boundFeeAmount(_collectedFeeToken1Round2);
    _totalSupply = _boundMintAmount(_totalSupply);

    lib.updateFees(_collectedFeeToken0Round1, _collectedFeeToken1Round1, _totalSupply);

    uint256 _expectedIndex0 = _calculateFeeIndex(_collectedFeeToken0Round1, _totalSupply);
    uint256 _expectedIndex1 = _calculateFeeIndex(_collectedFeeToken1Round1, _totalSupply);

    assertEq(lib.getGlobalFeeIndex0Scaled(), _expectedIndex0);
    assertEq(lib.getGlobalFeeIndex1Scaled(), _expectedIndex1);

    lib.updateFees(_collectedFeeToken0Round2, _collectedFeeToken1Round2, _totalSupply);

    _expectedIndex0 += _calculateFeeIndex(_collectedFeeToken0Round2, _totalSupply);
    _expectedIndex1 += _calculateFeeIndex(_collectedFeeToken1Round2, _totalSupply);

    assertEq(lib.getGlobalFeeIndex0Scaled(), _expectedIndex0);
    assertEq(lib.getGlobalFeeIndex1Scaled(), _expectedIndex1);
  }

  function testFuzz_FeeIndex0NotUpdatedWhenZero(uint256 _collectedFeeToken1, uint256 _totalSupply)
    public
  {
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);
    _totalSupply = _boundMintAmount(_totalSupply);

    lib.updateFees(0, _collectedFeeToken1, _totalSupply);

    assertEq(lib.getGlobalFeeIndex0Scaled(), 0);
    assertEq(lib.getGlobalFeeIndex1Scaled(), _calculateFeeIndex(_collectedFeeToken1, _totalSupply));
  }

  function testFuzz_FeeIndex1NotUpdatedWhenZero(uint256 _collectedFeeToken0, uint256 _totalSupply)
    public
  {
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _totalSupply = _boundMintAmount(_totalSupply);

    lib.updateFees(_collectedFeeToken0, 0, _totalSupply);

    assertEq(lib.getGlobalFeeIndex0Scaled(), _calculateFeeIndex(_collectedFeeToken0, _totalSupply));
    assertEq(lib.getGlobalFeeIndex1Scaled(), 0);
  }

  function testFuzz_FeeIndexesNotUpdatedWhenSupplyIsZero(
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1
  ) public {
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);

    lib.updateFees(_collectedFeeToken0, _collectedFeeToken1, 0);

    assertEq(lib.getGlobalFeeIndex0Scaled(), 0);
    assertEq(lib.getGlobalFeeIndex1Scaled(), 0);
  }

  function testFuzz_EmitsFeeIndexesUpdatedEvent(
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1,
    uint256 _totalSupply
  ) public {
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);
    _totalSupply = _boundMintAmount(_totalSupply);

    uint256 _expectedFeeIndex0 = _calculateFeeIndex(_collectedFeeToken0, _totalSupply);
    uint256 _expectedFeeIndex1 = _calculateFeeIndex(_collectedFeeToken1, _totalSupply);

    vm.expectEmit();
    emit RewardPerShareLib.FeeIndexesUpdated(
      _expectedFeeIndex0, _expectedFeeIndex1, _collectedFeeToken0, _collectedFeeToken1
    );
    lib.updateFees(_collectedFeeToken0, _collectedFeeToken1, _totalSupply);
  }
}

contract UpdateUserFees is RewardPerShareLibTest {
  function testFuzz_UserWithNoSharesSyncsToGlobalIndices(address _user) public {
    _assumeSafeAddress(_user);

    // Set global indices to non-zero
    lib.updateFees(1000, 2000, 100);

    assertEq(lib.getGlobalFeeIndex0Scaled(), _calculateFeeIndex(1000, 100));
    assertEq(lib.getGlobalFeeIndex1Scaled(), _calculateFeeIndex(2000, 100));

    lib.updateUserFees(_user, 0);

    (uint256 _userIndex0, uint256 _userIndex1, uint256 _accrued0, uint256 _accrued1) =
      lib.getUserFees(_user);

    assertEq(_userIndex0, lib.getGlobalFeeIndex0Scaled());
    assertEq(_userIndex1, lib.getGlobalFeeIndex1Scaled());
    assertEq(_accrued0, 0);
    assertEq(_accrued1, 0);
  }

  function testFuzz_UserWithNoSharesIndicesUnchangedWhenAlreadySynced(address _user) public {
    _assumeSafeAddress(_user);

    // Set global indices
    lib.updateFees(1000, 2000, 100);

    // First update syncs user
    lib.updateUserFees(_user, 0);
    (uint256 _userIndex0Before,,,) = lib.getUserFees(_user);

    // Second update should not change indices (already synced)
    lib.updateUserFees(_user, 0);
    (uint256 _userIndex0After,,,) = lib.getUserFees(_user);

    assertEq(_userIndex0Before, _userIndex0After);
    assertEq(_userIndex0After, lib.getGlobalFeeIndex0Scaled());
  }

  function testFuzz_UserWithNoSharesAccruedFeesNeverIncrease(address _user) public {
    _assumeSafeAddress(_user);

    // Set global indices
    lib.updateFees(1000, 2000, 100);

    lib.updateUserFees(_user, 0);

    (,, uint256 _accrued0Before, uint256 _accrued1Before) = lib.getUserFees(_user);
    assertEq(_accrued0Before, 0);
    assertEq(_accrued1Before, 0);

    // Update fees again
    lib.updateFees(500, 600, 100);
    lib.updateUserFees(_user, 0);

    (,, uint256 _accrued0After, uint256 _accrued1After) = lib.getUserFees(_user);
    assertEq(_accrued0After, 0);
    assertEq(_accrued1After, 0);
  }

  function testFuzz_UserWithSharesAccruesFees(
    address _user,
    uint256 _userBalance,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1,
    uint256 _totalSupply
  ) public {
    _assumeSafeAddress(_user);
    _userBalance = _boundMintAmount(_userBalance);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);
    _totalSupply = _boundMintAmount(_totalSupply);

    // Ensure user balance doesn't exceed total supply
    _userBalance = bound(_userBalance, 1, _totalSupply);

    // Set global indices
    lib.updateFees(_collectedFeeToken0, _collectedFeeToken1, _totalSupply);

    uint256 _globalIndex0 = lib.getGlobalFeeIndex0Scaled();
    uint256 _globalIndex1 = lib.getGlobalFeeIndex1Scaled();

    lib.updateUserFees(_user, _userBalance);

    (uint256 _userIndex0, uint256 _userIndex1, uint256 _accrued0, uint256 _accrued1) =
      lib.getUserFees(_user);

    assertEq(_userIndex0, _globalIndex0);
    assertEq(_userIndex1, _globalIndex1);
    assertEq(_accrued0, _calculateAccruedFees(_userBalance, _globalIndex0, 0));
    assertEq(_accrued1, _calculateAccruedFees(_userBalance, _globalIndex1, 0));
  }

  struct AccruesFeesOverMultipleRoundsParams {
    address user;
    uint256 userBalance;
    uint256 collectedFeeToken0Round1;
    uint256 collectedFeeToken1Round1;
    uint256 collectedFeeToken0Round2;
    uint256 collectedFeeToken1Round2;
  }

  function testFuzz_UserWithSharesAccruesFeesOverMultipleRounds(AccruesFeesOverMultipleRoundsParams memory _params)
    public
  {
    _assumeSafeAddress(_params.user);
    _params.userBalance = _boundMintAmount(_params.userBalance);
    _params.collectedFeeToken0Round1 = _boundFeeAmount(_params.collectedFeeToken0Round1);
    _params.collectedFeeToken1Round1 = _boundFeeAmount(_params.collectedFeeToken1Round1);
    _params.collectedFeeToken0Round2 = _boundFeeAmount(_params.collectedFeeToken0Round2);
    _params.collectedFeeToken1Round2 = _boundFeeAmount(_params.collectedFeeToken1Round2);

    uint256 _totalSupply = bound(_params.userBalance, 1, type(uint128).max);
    _params.userBalance = bound(_params.userBalance, 1, _totalSupply);

    // Round 1
    lib.updateFees(_params.collectedFeeToken0Round1, _params.collectedFeeToken1Round1, _totalSupply);

    // Round 2
    lib.updateFees(_params.collectedFeeToken0Round2, _params.collectedFeeToken1Round2, _totalSupply);

    // Get the final global fee indices (after both rounds)
    uint256 _finalGlobalFeeIndex0 = lib.getGlobalFeeIndex0Scaled();
    uint256 _finalGlobalFeeIndex1 = lib.getGlobalFeeIndex1Scaled();

    // User's index before update is 0 (default for new user)
    uint256 _userFeeIndex0Before = 0;
    uint256 _userFeeIndex1Before = 0;

    // Perform the update for the user - should accrue for BOTH rounds (delta from 0 to final)
    lib.updateUserFees(_params.user, _params.userBalance);

    // Get user fees after update
    (uint256 _userIndex0, uint256 _userIndex1, uint256 _accrued0, uint256 _accrued1) =
      lib.getUserFees(_params.user);

    // User should be synced to final global indices
    assertEq(_userIndex0, _finalGlobalFeeIndex0);
    assertEq(_userIndex1, _finalGlobalFeeIndex1);
    // User should accrue for both rounds (delta from initial 0 to final global index)
    assertEq(
      _accrued0,
      _calculateAccruedFees(_params.userBalance, _finalGlobalFeeIndex0, _userFeeIndex0Before)
    );
    assertEq(
      _accrued1,
      _calculateAccruedFees(_params.userBalance, _finalGlobalFeeIndex1, _userFeeIndex1Before)
    );
  }

  function testFuzz_UserWithSharesIndicesUnchangedWhenAlreadySynced(
    address _user,
    uint256 _userBalance,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1,
    uint256 _totalSupply
  ) public {
    _assumeSafeAddress(_user);
    _userBalance = _boundMintAmount(_userBalance);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);
    _totalSupply = _boundMintAmount(_totalSupply);

    _userBalance = bound(_userBalance, 1, _totalSupply);

    lib.updateFees(_collectedFeeToken0, _collectedFeeToken1, _totalSupply);
    lib.updateUserFees(_user, _userBalance);

    (uint256 _userIndex0Before, uint256 _userIndex1Before,,) = lib.getUserFees(_user);

    // Update again without new fees - indices should be unchanged
    lib.updateUserFees(_user, _userBalance);

    (uint256 _userIndex0After, uint256 _userIndex1After,,) = lib.getUserFees(_user);

    assertEq(_userIndex0Before, _userIndex0After);
    assertEq(_userIndex1Before, _userIndex1After);
  }

  function testFuzz_UserWithSharesAccruesOnlyToken0WhenToken1Unchanged(
    address _user,
    uint256 _userBalance,
    uint256 _collectedFeeToken0
  ) public {
    _assumeSafeAddress(_user);
    _userBalance = _boundMintAmount(_userBalance);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);

    uint256 _totalSupply = bound(_userBalance, 1, type(uint128).max);

    // Collect fees for token0 only
    lib.updateFees(_collectedFeeToken0, 0, _totalSupply);

    // Get the new global fee indices
    uint256 _globalFeeIndex0 = lib.getGlobalFeeIndex0Scaled();
    uint256 _globalFeeIndex1 = lib.getGlobalFeeIndex1Scaled();

    // User's index before update is 0 (default for new user)
    uint256 _userFeeIndex0Before = 0;

    // Perform the update for the user
    lib.updateUserFees(_user, _userBalance);

    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,
      uint256 _userAccruedToken0,
      uint256 _userAccruedToken1
    ) = lib.getUserFees(_user);

    // Check that the user has the correct fee indices and accrued fees
    assertEq(_userFeeIndex0, _globalFeeIndex0);
    assertEq(_userFeeIndex1, _globalFeeIndex1);
    assertEq(
      _userAccruedToken0,
      _calculateAccruedFees(_userBalance, _globalFeeIndex0, _userFeeIndex0Before)
    );
    assertEq(_userAccruedToken1, 0);
  }

  function testFuzz_UserWithSharesAccruesOnlyToken1WhenToken0Unchanged(
    address _user,
    uint256 _userBalance,
    uint256 _collectedFeeToken1
  ) public {
    _assumeSafeAddress(_user);
    _userBalance = _boundMintAmount(_userBalance);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);

    uint256 _totalSupply = bound(_userBalance, 1, type(uint128).max);

    // Collect fees for token1 only
    lib.updateFees(0, _collectedFeeToken1, _totalSupply);

    // Get the new global fee indices
    uint256 _globalFeeIndex0 = lib.getGlobalFeeIndex0Scaled();
    uint256 _globalFeeIndex1 = lib.getGlobalFeeIndex1Scaled();

    // User's index before update is 0 (default for new user)
    uint256 _userFeeIndex1Before = 0;

    // Perform the update for the user
    lib.updateUserFees(_user, _userBalance);

    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,
      uint256 _userAccruedToken0,
      uint256 _userAccruedToken1
    ) = lib.getUserFees(_user);

    // Check that the user has the correct fee indices and accrued fees
    assertEq(_userFeeIndex0, _globalFeeIndex0);
    assertEq(_userFeeIndex1, _globalFeeIndex1);
    assertEq(_userAccruedToken0, 0);
    assertEq(
      _userAccruedToken1,
      _calculateAccruedFees(_userBalance, _globalFeeIndex1, _userFeeIndex1Before)
    );
  }

  struct NoAccrualWhenSyncedParams {
    address user;
    uint256 userBalance1;
    uint256 userBalance2;
    uint256 collectedFeeToken0;
    uint256 collectedFeeToken1;
  }

  function testFuzz_UserWithSharesNoAccrualWhenIndicesAlreadySynced(NoAccrualWhenSyncedParams memory _params)
    public
  {
    _assumeSafeAddress(_params.user);
    _params.userBalance1 = _boundMintAmount(_params.userBalance1);
    _params.userBalance2 = _boundMintAmount(_params.userBalance2);
    _params.collectedFeeToken0 = _boundFeeAmount(_params.collectedFeeToken0);
    _params.collectedFeeToken1 = _boundFeeAmount(_params.collectedFeeToken1);

    uint256 _totalSupply = _params.userBalance1 + _params.userBalance2;
    _totalSupply = bound(_totalSupply, 2, type(uint128).max);
    _params.userBalance1 = bound(_params.userBalance1, 1, _totalSupply - 1);
    _params.userBalance2 = _totalSupply - _params.userBalance1;

    // Set global indices
    lib.updateFees(_params.collectedFeeToken0, _params.collectedFeeToken1, _totalSupply);
    uint256 _globalIndex0 = lib.getGlobalFeeIndex0Scaled();
    uint256 _globalIndex1 = lib.getGlobalFeeIndex1Scaled();

    // First update with balance1 - syncs indices
    lib.updateUserFees(_params.user, _params.userBalance1);
    (,, uint256 _accrued0AfterBalance1, uint256 _accrued1AfterBalance1) =
      lib.getUserFees(_params.user);

    // Second update with increased balance (balance1 + balance2) but indices already synced
    uint256 _currentBalance = _params.userBalance1 + _params.userBalance2;
    lib.updateUserFees(_params.user, _currentBalance);

    // Get user fees after second update
    (
      uint256 _userIndex0,
      uint256 _userIndex1,
      uint256 _accrued0AfterBalance2,
      uint256 _accrued1AfterBalance2
    ) = lib.getUserFees(_params.user);

    // User should be synced
    assertEq(_userIndex0, _globalIndex0);
    assertEq(_userIndex1, _globalIndex1);

    // Since indices are already synced after first update, second update should accrue nothing
    // even though balance increased - this verifies accrual only happens when indices change
    uint256 _additionalAccrued0 = _accrued0AfterBalance2 - _accrued0AfterBalance1;
    uint256 _additionalAccrued1 = _accrued1AfterBalance2 - _accrued1AfterBalance1;
    assertEq(_additionalAccrued0, 0);
    assertEq(_additionalAccrued1, 0);
  }
}
