// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// External Imports
import {Test} from "forge-std/Test.sol";

// Internal Imports
import {VaultShareToken} from "src/VaultShareToken.sol";
import {VaultShareTokenHarness} from "test/harness/VaultShareTokenHarness.sol";
import {RewardPerShareLib} from "src/lib/RewardPerShareLib.sol";

contract VaultShareTokenTest is Test {
  VaultShareTokenHarness public vaultShareToken;

  function setUp() public virtual {
    vaultShareToken = new VaultShareTokenHarness("Vault Share Token", "VST");
  }

  function _assumeSafeAddress(address _address) internal pure {
    vm.assume(_address != address(0));
  }

  function _assumeSafeAmount(uint256 _amount) internal pure {
    vm.assume(_amount > 0);
  }

  function _boundFeeAmount(uint256 _amount) internal pure returns (uint256) {
    uint256 _maxFee = type(uint256).max / RewardPerShareLib.PRECISION;
    return bound(_amount, 0, _maxFee);
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

  function _calculateUserAccrued(uint256 _userBalance, uint256 _globalIndex, uint256 _userIndex)
    internal
    view
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

contract Constructor is VaultShareTokenTest {
  function testFuzz_SetsInitialParameters(string memory _name, string memory _symbol) public {
    VaultShareToken _newVaultShareToken = new VaultShareToken(_name, _symbol);

    assertEq(_newVaultShareToken.name(), _name);
    assertEq(_newVaultShareToken.symbol(), _symbol);
  }
}

contract Mint is VaultShareTokenTest {
  function testFuzz_MintsTokens(address _account, uint256 _amount) public {
    _assumeSafeAddress(_account);
    _assumeSafeAmount(_amount);

    assertEq(vaultShareToken.balanceOf(_account), 0);
    vaultShareToken.exposed_mint(_account, _amount);
    assertEq(vaultShareToken.balanceOf(_account), _amount);
  }

  function testFuzz_UpdatesUserFeesOnMint(address _account, uint256 _amount) public {
    // TODO: Implement
    // Test that _updateUserFees is called for the recipient when minting
    // - If global index > 0, user should checkpoint to global (no retroactive earnings)
    // - If global index == 0, user index should remain 0
  }
}

contract Burn is VaultShareTokenTest {
  function testFuzz_BurnsTokens(address _account, uint256 _mintAmount, uint256 _burnAmount) public {
    _assumeSafeAddress(_account);
    _assumeSafeAmount(_mintAmount);

    _burnAmount = bound(_burnAmount, 0, _mintAmount);

    vaultShareToken.exposed_mint(_account, _mintAmount);

    assertEq(vaultShareToken.balanceOf(_account), _mintAmount);
    vaultShareToken.exposed_burn(_account, _burnAmount);
    assertEq(vaultShareToken.balanceOf(_account), _mintAmount - _burnAmount);
  }

  function testFuzz_UpdatesUserFeesOnBurn(address _account, uint256 _amount) public {
    // TODO: Implement
    // Test that _updateUserFees is called for the sender when burning
    // - Should accrue fees before balance decreases
    // - If balance goes to 0, should checkpoint to global index
  }
}

contract Transfer is VaultShareTokenTest {
  function testFuzz_TransfersTokens(address _from, address _to, uint256 _amount) public {
    // TODO: Implement
  }

  function testFuzz_UpdatesUserFeesOnTransfer(address _from, address _to, uint256 _amount) public {
    // TODO: Implement
    // Test that _updateUserFees is called for both sender and recipient
    // - Sender should accrue fees before balance decreases
    // - Recipient should checkpoint to global index (no retroactive earnings)
  }
}

contract TransferFrom is VaultShareTokenTest {
  function testFuzz_TransfersTokens(address _from, address _to, uint256 _amount) public {
    // TODO: Implement
  }

  function testFuzz_UpdatesUserFeesOnTransferFrom(address _from, address _to, uint256 _amount)
    public {
    // TODO: Implement
    // Same as Transfer - both parties should have fees updated
  }
}

contract UpdateFees is VaultShareTokenTest {
  function testFuzz_FeeIndexTokensAreUpdated(
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1,
    uint256 _mintAmount,
    address _minterAccount
  ) public {
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);
    _mintAmount = _boundMintAmount(_mintAmount);

    _assumeSafeAddress(_minterAccount);

    vaultShareToken.exposed_mint(_minterAccount, _mintAmount);

    assertEq(vaultShareToken.feeIndexToken0(), 0);
    assertEq(vaultShareToken.feeIndexToken1(), 0);

    vaultShareToken.exposed_updateFees(_collectedFeeToken0, _collectedFeeToken1);

    assertEq(vaultShareToken.feeIndexToken0(), _calculateFeeIndex(_collectedFeeToken0, _mintAmount));
    assertEq(vaultShareToken.feeIndexToken1(), _calculateFeeIndex(_collectedFeeToken1, _mintAmount));
  }

  function testFuzz_FeeIndexTokensAreUpdatedOnMultipleCalls(
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

    vaultShareToken.exposed_mint(_minterAccountAtT1, _mintAmountAtT1);

    vaultShareToken.exposed_updateFees(_collectedFeeToken0AtT1, _collectedFeeToken1AtT1);

    uint256 _expectedFeeIndex0 = _calculateFeeIndex(_collectedFeeToken0AtT1, _mintAmountAtT1);
    uint256 _expectedFeeIndex1 = _calculateFeeIndex(_collectedFeeToken1AtT1, _mintAmountAtT1);

    assertEq(vaultShareToken.feeIndexToken0(), _expectedFeeIndex0);
    assertEq(vaultShareToken.feeIndexToken1(), _expectedFeeIndex1);

    vaultShareToken.exposed_mint(_minterAccountAtT2, _mintAmountAtT2);

    vaultShareToken.exposed_updateFees(_collectedFeeToken0AtT2, _collectedFeeToken1AtT2);

    uint256 _totalSupplyAfterT2 = _mintAmountAtT1 + _mintAmountAtT2;
    _expectedFeeIndex0 += _calculateFeeIndex(_collectedFeeToken0AtT2, _totalSupplyAfterT2);
    _expectedFeeIndex1 += _calculateFeeIndex(_collectedFeeToken1AtT2, _totalSupplyAfterT2);

    assertEq(vaultShareToken.feeIndexToken0(), _expectedFeeIndex0);
    assertEq(vaultShareToken.feeIndexToken1(), _expectedFeeIndex1);
  }

  function testFuzz_FeeIndex0IsNotUpdatedWhenTokenFee0IsZero(
    uint256 _collectedFeeToken1,
    uint256 _mintAmount,
    address _minterAccount
  ) public {
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);
    _mintAmount = _boundMintAmount(_mintAmount);

    _assumeSafeAddress(_minterAccount);

    vaultShareToken.exposed_mint(_minterAccount, _mintAmount);

    assertEq(vaultShareToken.feeIndexToken0(), 0);
    assertEq(vaultShareToken.feeIndexToken1(), 0);

    vaultShareToken.exposed_updateFees(0, _collectedFeeToken1);

    assertEq(vaultShareToken.feeIndexToken0(), 0);
    assertEq(vaultShareToken.feeIndexToken1(), _calculateFeeIndex(_collectedFeeToken1, _mintAmount));
  }

  function testFuzz_FeeIndex1IsNotUpdatedWhenTokenFee1IsZero(
    uint256 _collectedFeeToken0,
    uint256 _mintAmount,
    address _minterAccount
  ) public {
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _mintAmount = _boundMintAmount(_mintAmount);

    _assumeSafeAddress(_minterAccount);

    vaultShareToken.exposed_mint(_minterAccount, _mintAmount);

    assertEq(vaultShareToken.feeIndexToken0(), 0);
    assertEq(vaultShareToken.feeIndexToken1(), 0);

    vaultShareToken.exposed_updateFees(_collectedFeeToken0, 0);

    assertEq(vaultShareToken.feeIndexToken0(), _calculateFeeIndex(_collectedFeeToken0, _mintAmount));
    assertEq(vaultShareToken.feeIndexToken1(), 0);
  }

  function testFuzz_FeeIndexesAreNotUpdatedWhenNoSharesMinted(
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1
  ) public {
    assertEq(vaultShareToken.totalSupply(), 0);
    assertEq(vaultShareToken.feeIndexToken0(), 0);
    assertEq(vaultShareToken.feeIndexToken1(), 0);

    vaultShareToken.exposed_updateFees(_collectedFeeToken0, _collectedFeeToken1);

    assertEq(vaultShareToken.feeIndexToken0(), 0);
    assertEq(vaultShareToken.feeIndexToken1(), 0);
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

    vaultShareToken.exposed_mint(_minterAccount, _mintAmount);

    uint256 _expectedFeeIndex0 = _calculateFeeIndex(_collectedFeeToken0, _mintAmount);
    uint256 _expectedFeeIndex1 = _calculateFeeIndex(_collectedFeeToken1, _mintAmount);

    vm.expectEmit();
    emit RewardPerShareLib.FeeIndexesUpdated(
      _expectedFeeIndex0, _expectedFeeIndex1, _collectedFeeToken0, _collectedFeeToken1
    );
    vaultShareToken.exposed_updateFees(_collectedFeeToken0, _collectedFeeToken1);
  }
}

contract UpdateUserFees is VaultShareTokenTest {
  // ========== Branch 1: User has no shares (_userBalance == 0) ==========

  function testFuzz_UserFeeIndexesAreUpdatedWhenNoSharesAreMinted(address _user) public {
    // TODO: Implement
    // Branch 1a & 1c: When user has 0 balance and global index > user index
    // - Should update userFeeIndexToken0 to globalFeeIndex0 if different
    // - Should update userFeeIndexToken1 to globalFeeIndex1 if different
    // - Should NOT accrue any fees (accruedToken0/1 should remain 0)
  }

  function testFuzz_UserFeeIndexesAreNotUpdatedWhenAlreadySyncedAndNoShares(address _user) public {
    // TODO: Implement
    // Branch 1b & 1d: When user has 0 balance and global index == user index
    // - Should NOT update userFeeIndexToken0/1 (already synced)
    // - Should NOT accrue any fees
  }

  function testFuzz_UserAccruedFeesAreNotUpdatedWhenUserHasNoShares(address _user) public {
    // TODO: Implement
    // Branch 1: When user has 0 balance, accrued fees should never increase
    // - Even if global index > user index, accrued should remain 0
  }

  // ========== Branch 2: User has shares (_userBalance > 0) ==========

  function testFuzz_UserFeeIndexAndAccruedFeesAreUpdatedWhenUserHasShares(
    address _user,
    uint256 _mintAmount
  ) public {
    // TODO: Implement
    // Branch 2a & 2c: When user has shares and global index > user index
    // - Should accrue fees: accruedToken0 += balance * (globalIndex0 - userIndex0) / PRECISION
    // - Should accrue fees: accruedToken1 += balance * (globalIndex1 - userIndex1) / PRECISION
    // - Should update checkpoints to global indices
  }

  function testFuzz_UserFeeIndexIsNotUpdatedWhenUserHasAlreadySyncedToGlobalIndex(
    address _user,
    uint256 _mintAmount
  ) public {
    // TODO: Implement
    // Branch 2b & 2d: When user has shares and global index <= user index
    // - Should NOT accrue fees (no delta)
    // - Should still update checkpoint if different (branch 2e/2g)
  }

  function testFuzz_UserAccruesOnlyToken0FeesWhenToken1IndexUnchanged(
    address _user,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0
  ) public {
    // TODO: Implement
    // Branch 2a (true) & 2c (false): globalIndex0 > userIndex0, but globalIndex1 == userIndex1
    // - Should accrue token0 fees
    // - Should NOT accrue token1 fees
    // - Should update both checkpoints
  }

  function testFuzz_UserAccruesOnlyToken1FeesWhenToken0IndexUnchanged(
    address _user,
    uint256 _mintAmount,
    uint256 _collectedFeeToken1
  ) public {
    // TODO: Implement
    // Branch 2c (true) & 2a (false): globalIndex1 > userIndex1, but globalIndex0 == userIndex0
    // - Should accrue token1 fees
    // - Should NOT accrue token0 fees
    // - Should update both checkpoints
  }

  function testFuzz_UserCheckpointUpdatedEvenWhenNoAccrual(address _user, uint256 _mintAmount)
    public {
    // TODO: Implement
    // Branch 2e & 2g: When user has shares, global index == user index (no accrual)
    // - Should NOT accrue fees
    // - Should still update checkpoint if indices differ (edge case - shouldn't happen but good to
    // test)
  }

  function testFuzz_UserAccruesFeesOverMultipleFeeUpdates(
    address _user,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0Round1,
    uint256 _collectedFeeToken1Round1,
    uint256 _collectedFeeToken0Round2,
    uint256 _collectedFeeToken1Round2
  ) public {
    // TODO: Implement
    // Test that user accrues correctly when fees are collected multiple times
    // - User mints shares
    // - Fees collected round 1 -> global index increases
    // - Fees collected round 2 -> global index increases again
    // - User interacts -> should accrue for BOTH rounds (delta from initial to final)
  }

  function testFuzz_UserWithSharesDoesNotRetroactivelyEarnFeesWhenMintingAfterFeesCollected(
    address _user,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1,
    uint256 _mintAmount
  ) public {
    // TODO: Implement
    // Critical: User should NOT earn fees that were collected before they had shares
    // - Another user mints and fees are collected
    // - New user mints shares
    // - New user's index should checkpoint to current global index (no retroactive earnings)
  }

  function testFuzz_UserAccruesFeesBasedOnCurrentBalanceNotHistorical(
    address _user,
    uint256 _mintAmount1,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1,
    uint256 _mintAmount2
  ) public {
    // TODO: Implement
    // Test that accrual uses current balance, not historical
    // - User mints amount1, fees collected, user mints amount2
    // - When fees accrue, should use (amount1 + amount2) as balance
  }

  function testFuzz_UserBurningSharesAccruesFeesBeforeBalanceDecreases(
    address _user,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1,
    uint256 _burnAmount
  ) public {
    // TODO: Implement
    // Test that when burning, fees are accrued using the balance BEFORE burn
    // - User mints, fees collected, user burns
    // - Accrual should use pre-burn balance
  }
}
