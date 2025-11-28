// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// External Imports
import {Test} from "forge-std/Test.sol";

// Internal Imports
import {VaultShareToken} from "src/VaultShareToken.sol";
import {VaultShareTokenHarness} from "test/harness/VaultShareTokenHarness.sol";

contract VaultShareTokenTest is Test {
  VaultShareTokenHarness public vaultShareToken;

  function setUp() public virtual {
    vaultShareToken = new VaultShareTokenHarness("Vault Share Token", "VST");
  }

  function _assumeSafeAddress(address _address) internal pure {
    vm.assume(_address != address(0));
  }

  function _assumeSafeAmount(uint256 _amount) internal pure {
    vm.assume(_amount != 0);
  }

  function _boundFeeAmount(uint256 _amount) internal view returns (uint256) {
    // Bound fees so that, even with minimal supply and multiple fee rounds,
    // the cumulative fee index updates cannot overflow uint256.
    //
    // Each update adds ~ collectedFee * PRECISION / totalSupply.
    // We divide by an extra safety factor (4) so several maximal rounds remain safe.
    uint256 _maxFeePerRound = type(uint256).max / vaultShareToken.PRECISION() / 4;
    return bound(_amount, 1, _maxFeePerRound);
  }

  function _boundMintAmount(uint256 _amount) internal pure returns (uint256) {
    return bound(_amount, 1, type(uint128).max);
  }

  function _calculateFeeIndex(uint256 _collectedFeeToken, uint256 _supply)
    internal
    view
    returns (uint256)
  {
    // Manually reproduce the formula `(collected * PRECISION) / supply` rather than calling
    // Math.mulDiv so that the test cross-checks production logic via an equivalent expression.
    if (_supply == 0) return 0;
    unchecked {
      return (_collectedFeeToken * vaultShareToken.PRECISION()) / _supply;
    }
  }

  function _calculateAccruedFees(uint256 _userBalance, uint256 _globalIndex, uint256 _userIndex)
    internal
    view
    returns (uint256)
  {
    // Manually reproduce the formula `(balance * (globalIndex - userIndex)) / PRECISION` rather
    // than calling Math.mulDiv so that the test cross-checks production logic via an equivalent
    // expression.
    if (_globalIndex <= _userIndex) return 0;
    unchecked {
      return (_userBalance * (_globalIndex - _userIndex)) / vaultShareToken.PRECISION();
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

  function testFuzz_UpdatesUserFeesOnMint(
    address _user,
    uint256 _mintAmount1,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1,
    uint256 _mintAmount2
  ) public {
    _assumeSafeAddress(_user);
    _mintAmount1 = _boundMintAmount(_mintAmount1);
    _mintAmount2 = _boundMintAmount(_mintAmount2);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);

    // User mints shares first
    vaultShareToken.exposed_mint(_user, _mintAmount1);

    // Fees are collected (global indices increase while user already has shares)
    vaultShareToken.exposed_updateFees(_collectedFeeToken0, _collectedFeeToken1);

    // Get global indices after fees are collected
    uint256 _globalFeeIndex0 = vaultShareToken.feeIndexToken0();
    uint256 _globalFeeIndex1 = vaultShareToken.feeIndexToken1();

    // User mints more shares - _updateUserFees is called during mint
    vaultShareToken.exposed_mint(_user, _mintAmount2);

    // Get user fees after second mint
    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,
      uint256 _userAccruedToken0,
      uint256 _userAccruedToken1
    ) = vaultShareToken.userFees(_user);

    // User's index should be synced to global index
    assertEq(_userFeeIndex0, _globalFeeIndex0);
    assertEq(_userFeeIndex1, _globalFeeIndex1);

    // User should have accrued fees based on their balance from the first mint
    // (fees were collected while they had _mintAmount1 shares)
    assertEq(_userAccruedToken0, _calculateAccruedFees(_mintAmount1, _globalFeeIndex0, 0));
    assertEq(_userAccruedToken1, _calculateAccruedFees(_mintAmount1, _globalFeeIndex1, 0));
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

  function testFuzz_UpdatesUserFeesOnBurn(
    address _user,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1,
    uint256 _burnAmount
  ) public {
    _assumeSafeAddress(_user);
    _mintAmount = _boundMintAmount(_mintAmount);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);
    _burnAmount = bound(_burnAmount, 1, _mintAmount); // Burn at least 1, but not more than minted

    // User mints shares
    vaultShareToken.exposed_mint(_user, _mintAmount);

    // Fees are collected (global indices increase while user has shares)
    vaultShareToken.exposed_updateFees(_collectedFeeToken0, _collectedFeeToken1);

    // Get global indices after fees are collected
    uint256 _globalFeeIndex0 = vaultShareToken.feeIndexToken0();
    uint256 _globalFeeIndex1 = vaultShareToken.feeIndexToken1();

    // User's balance before burn
    uint256 _balanceBeforeBurn = _mintAmount;

    // User burns shares - _updateUserFees is called during burn
    vaultShareToken.exposed_burn(_user, _burnAmount);

    // Get user fees after burn
    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,
      uint256 _userAccruedToken0,
      uint256 _userAccruedToken1
    ) = vaultShareToken.userFees(_user);

    // User's index should be synced to global index
    assertEq(_userFeeIndex0, _globalFeeIndex0);
    assertEq(_userFeeIndex1, _globalFeeIndex1);

    // User should have accrued fees based on their balance BEFORE the burn
    // (fees were collected while they had _mintAmount shares, and accrual uses pre-burn balance)
    assertEq(_userAccruedToken0, _calculateAccruedFees(_balanceBeforeBurn, _globalFeeIndex0, 0));
    assertEq(_userAccruedToken1, _calculateAccruedFees(_balanceBeforeBurn, _globalFeeIndex1, 0));
  }

  function testFuzz_UpdatesUserFeesOnMultipleBurns(
    address _user,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0Round1,
    uint256 _collectedFeeToken1Round1,
    uint256 _burnAmount1,
    uint256 _collectedFeeToken0Round2,
    uint256 _collectedFeeToken1Round2,
    uint256 _burnAmount2
  ) public {
    _assumeSafeAddress(_user);
    _mintAmount = _boundMintAmount(_mintAmount);
    // Ensure we have enough for two burns
    _mintAmount = bound(_mintAmount, 2, type(uint128).max);
    _collectedFeeToken0Round1 = _boundFeeAmount(_collectedFeeToken0Round1);
    _collectedFeeToken1Round1 = _boundFeeAmount(_collectedFeeToken1Round1);
    _collectedFeeToken0Round2 = _boundFeeAmount(_collectedFeeToken0Round2);
    _collectedFeeToken1Round2 = _boundFeeAmount(_collectedFeeToken1Round2);
    // Ensure we can do two burns: first burn leaves at least 1 for second burn
    _burnAmount1 = bound(_burnAmount1, 1, _mintAmount - 1);
    _burnAmount2 = bound(_burnAmount2, 1, _mintAmount - _burnAmount1); // Burn remaining or less

    // User mints shares
    vaultShareToken.exposed_mint(_user, _mintAmount);

    // Fees collected round 1
    vaultShareToken.exposed_updateFees(_collectedFeeToken0Round1, _collectedFeeToken1Round1);
    uint256 _globalFeeIndex0AfterRound1 = vaultShareToken.feeIndexToken0();
    uint256 _globalFeeIndex1AfterRound1 = vaultShareToken.feeIndexToken1();

    // First burn - should accrue based on initial balance (_mintAmount)
    vaultShareToken.exposed_burn(_user, _burnAmount1);
    uint256 _balanceAfterFirstBurn = _mintAmount - _burnAmount1;

    // Fees collected round 2 (user now has _balanceAfterFirstBurn shares)
    vaultShareToken.exposed_updateFees(_collectedFeeToken0Round2, _collectedFeeToken1Round2);
    uint256 _globalFeeIndex0AfterRound2 = vaultShareToken.feeIndexToken0();
    uint256 _globalFeeIndex1AfterRound2 = vaultShareToken.feeIndexToken1();

    // Second burn - should accrue based on balance before second burn (_balanceAfterFirstBurn)
    vaultShareToken.exposed_burn(_user, _burnAmount2);

    // Get user fees after both burns
    (,, uint256 _userAccruedToken0, uint256 _userAccruedToken1) = vaultShareToken.userFees(_user);

    // User should have accrued fees from both rounds:
    // - Round 1: based on initial balance (_mintAmount)
    // - Round 2: based on balance after first burn (_balanceAfterFirstBurn)
    uint256 _expectedAccrued0 = _calculateAccruedFees(_mintAmount, _globalFeeIndex0AfterRound1, 0)
      + _calculateAccruedFees(
        _balanceAfterFirstBurn, _globalFeeIndex0AfterRound2, _globalFeeIndex0AfterRound1
      );
    uint256 _expectedAccrued1 = _calculateAccruedFees(_mintAmount, _globalFeeIndex1AfterRound1, 0)
      + _calculateAccruedFees(
        _balanceAfterFirstBurn, _globalFeeIndex1AfterRound2, _globalFeeIndex1AfterRound1
      );

    assertEq(_userAccruedToken0, _expectedAccrued0);
    assertEq(_userAccruedToken1, _expectedAccrued1);
  }
}

contract Transfer is VaultShareTokenTest {
  function testFuzz_TransfersTokens(address _from, address _to, uint256 _amount) public {
    _assumeSafeAddress(_from);
    _assumeSafeAddress(_to);
    vm.assume(_from != _to);
    _amount = _boundMintAmount(_amount);

    // Mint tokens to sender
    vaultShareToken.exposed_mint(_from, _amount);

    assertEq(vaultShareToken.balanceOf(_from), _amount);
    assertEq(vaultShareToken.balanceOf(_to), 0);

    // Transfer tokens
    vm.prank(_from);
    bool _success = vaultShareToken.transfer(_to, _amount);
    assertTrue(_success);

    // Verify balances are updated
    assertEq(vaultShareToken.balanceOf(_from), 0);
    assertEq(vaultShareToken.balanceOf(_to), _amount);
  }

  function testFuzz_UpdatesUserFeesOnTransfer(
    address _from,
    address _to,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0Round1,
    uint256 _collectedFeeToken1Round1,
    uint256 _collectedFeeToken0Round2,
    uint256 _collectedFeeToken1Round2
  ) public {
    _assumeSafeAddress(_from);
    _assumeSafeAddress(_to);
    vm.assume(_from != _to);
    _mintAmount = _boundMintAmount(_mintAmount);
    _collectedFeeToken0Round1 = _boundFeeAmount(_collectedFeeToken0Round1);
    _collectedFeeToken1Round1 = _boundFeeAmount(_collectedFeeToken1Round1);
    _collectedFeeToken0Round2 = _boundFeeAmount(_collectedFeeToken0Round2);
    _collectedFeeToken1Round2 = _boundFeeAmount(_collectedFeeToken1Round2);

    // Step 1: User mints shares
    vaultShareToken.exposed_mint(_from, _mintAmount);

    // Step 2: Fees are collected (user accrues fees because they have shares)
    vaultShareToken.exposed_updateFees(_collectedFeeToken0Round1, _collectedFeeToken1Round1);
    uint256 _globalFeeIndex0AfterRound1 = vaultShareToken.feeIndexToken0();
    uint256 _globalFeeIndex1AfterRound1 = vaultShareToken.feeIndexToken1();

    // Step 3: User transfers ALL shares to new user
    // This triggers _updateUserFees for both parties, accruing fees from round 1 for _from
    vm.prank(_from);
    vaultShareToken.transfer(_to, _mintAmount);

    // Verify balances after transfer
    assertEq(vaultShareToken.balanceOf(_from), 0);
    assertEq(vaultShareToken.balanceOf(_to), _mintAmount);

    // Get sender's accrued fees after transfer (they should have accrued fees from round 1)
    (,, uint256 _senderAccruedToken0AfterTransfer, uint256 _senderAccruedToken1AfterTransfer) =
      vaultShareToken.userFees(_from);

    // Verify sender accrued fees from round 1 (earned while they had shares)
    assertEq(
      _senderAccruedToken0AfterTransfer,
      _calculateAccruedFees(_mintAmount, _globalFeeIndex0AfterRound1, 0)
    );
    assertEq(
      _senderAccruedToken1AfterTransfer,
      _calculateAccruedFees(_mintAmount, _globalFeeIndex1AfterRound1, 0)
    );

    // Step 4: New fees come in
    vaultShareToken.exposed_updateFees(_collectedFeeToken0Round2, _collectedFeeToken1Round2);
    uint256 _globalFeeIndex0AfterRound2 = vaultShareToken.feeIndexToken0();
    uint256 _globalFeeIndex1AfterRound2 = vaultShareToken.feeIndexToken1();

    // Update both users' fees to reflect the new fee collection via the public hook
    vaultShareToken.updateUserFees(_from);
    vaultShareToken.updateUserFees(_to);

    // Get sender's fees after round 2 (they have 0 balance)
    (
      uint256 _senderFeeIndex0AfterRound2,
      uint256 _senderFeeIndex1AfterRound2,
      uint256 _senderAccruedToken0AfterRound2,
      uint256 _senderAccruedToken1AfterRound2
    ) = vaultShareToken.userFees(_from);

    // Get recipient's fees after round 2 (they have shares)
    (
      uint256 _recipientFeeIndex0AfterRound2,
      uint256 _recipientFeeIndex1AfterRound2,
      uint256 _recipientAccruedToken0AfterRound2,
      uint256 _recipientAccruedToken1AfterRound2
    ) = vaultShareToken.userFees(_to);

    // Original user (_from): global checkpoint updated, but accrued fees don't increase (0 balance)
    assertEq(_senderFeeIndex0AfterRound2, _globalFeeIndex0AfterRound2);
    assertEq(_senderFeeIndex1AfterRound2, _globalFeeIndex1AfterRound2);
    // Accrued fees should remain the same (no increase because balance is 0)
    assertEq(_senderAccruedToken0AfterRound2, _senderAccruedToken0AfterTransfer);
    assertEq(_senderAccruedToken1AfterRound2, _senderAccruedToken1AfterTransfer);

    // New user (_to): global checkpoint updated AND accrued fees increase (has shares)
    assertEq(_recipientFeeIndex0AfterRound2, _globalFeeIndex0AfterRound2);
    assertEq(_recipientFeeIndex1AfterRound2, _globalFeeIndex1AfterRound2);
    // Recipient should have accrued fees from round 2 (based on their balance)
    assertEq(
      _recipientAccruedToken0AfterRound2,
      _calculateAccruedFees(_mintAmount, _globalFeeIndex0AfterRound2, _globalFeeIndex0AfterRound1)
    );
    assertEq(
      _recipientAccruedToken1AfterRound2,
      _calculateAccruedFees(_mintAmount, _globalFeeIndex1AfterRound2, _globalFeeIndex1AfterRound1)
    );
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
    emit VaultShareToken.FeeIndexesUpdated(
      _expectedFeeIndex0, _expectedFeeIndex1, _collectedFeeToken0, _collectedFeeToken1
    );
    vaultShareToken.exposed_updateFees(_collectedFeeToken0, _collectedFeeToken1);
  }
}

contract UpdateUserFees is VaultShareTokenTest {
  // ========== Branch 1: User has no shares (_userBalance == 0) ==========

  function testFuzz_UserWithNoSharesSyncsToZeroGlobalIndices(address _user) public {
    _assumeSafeAddress(_user);

    // Perform the update for the user without vault shares
    vaultShareToken.updateUserFees(_user);

    // Get the global fee indices (should be 0 initially)
    uint256 _globalFeeIndex0 = vaultShareToken.feeIndexToken0();
    uint256 _globalFeeIndex1 = vaultShareToken.feeIndexToken1();

    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,, //uint256 _userAccruedToken0
      //uint256 _userAccruedToken1
    ) = vaultShareToken.userFees(_user);

    // Check that the user has the same fee indices as the global fee indices
    assertEq(_userFeeIndex0, _globalFeeIndex0);
    assertEq(_userFeeIndex1, _globalFeeIndex1);
  }

  function testFuzz_UserWithNoSharesSyncsToNonZeroGlobalIndices(
    address _userWithVaultShares,
    address _userWithoutVaultShares,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1
  ) public {
    _assumeSafeAddress(_userWithVaultShares);
    _assumeSafeAddress(_userWithoutVaultShares);
    vm.assume(_userWithVaultShares != _userWithoutVaultShares);
    _mintAmount = _boundMintAmount(_mintAmount);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);

    // First, sync the user without shares when global indices are 0
    vaultShareToken.updateUserFees(_userWithoutVaultShares);

    // Mint shares for another user and collect fees to change global indices
    vaultShareToken.exposed_mint(_userWithVaultShares, _mintAmount);
    vaultShareToken.exposed_updateFees(_collectedFeeToken0, _collectedFeeToken1);

    // Get the new global fee indices (should be > 0 now)
    uint256 _globalFeeIndex0 = vaultShareToken.feeIndexToken0();
    uint256 _globalFeeIndex1 = vaultShareToken.feeIndexToken1();

    // Perform the update for the user without vault shares
    vaultShareToken.updateUserFees(_userWithoutVaultShares);

    // Destructure the tuple again after the update
    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,, //uint256 _userAccruedToken0,
      //uint256 _userAccruedToken1
    ) = vaultShareToken.userFees(_userWithoutVaultShares);

    // User without vault shares should have the same fee indices as the global fee indices
    assertEq(_userFeeIndex0, _globalFeeIndex0);
    assertEq(_userFeeIndex1, _globalFeeIndex1);
  }

  function testFuzz_UserWithNoSharesIndicesUnchangedWhenAlreadySynced(address _user) public {
    _assumeSafeAddress(_user);

    // First sync: user indices should sync to global indices (which are 0)
    vaultShareToken.updateUserFees(_user);

    (uint256 _userFeeIndex0AfterFirstSync, uint256 _userFeeIndex1AfterFirstSync,,) =
      vaultShareToken.userFees(_user);

    // Verify indices were synced to 0
    assertEq(_userFeeIndex0AfterFirstSync, 0);
    assertEq(_userFeeIndex1AfterFirstSync, 0);

    // Second sync: indices should remain the same (already synced, no unnecessary update)
    vaultShareToken.updateUserFees(_user);

    (uint256 _userFeeIndex0AfterSecondSync, uint256 _userFeeIndex1AfterSecondSync,,) =
      vaultShareToken.userFees(_user);

    // Indices should remain unchanged (already synced)
    assertEq(_userFeeIndex0AfterSecondSync, _userFeeIndex0AfterFirstSync);
    assertEq(_userFeeIndex1AfterSecondSync, _userFeeIndex1AfterFirstSync);
  }

  function testFuzz_UserWithNoSharesAccruedFeesNeverIncrease(
    address _userWithVaultShares,
    address _userWithoutVaultShares,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1
  ) public {
    _assumeSafeAddress(_userWithVaultShares);
    _assumeSafeAddress(_userWithoutVaultShares);
    vm.assume(_userWithVaultShares != _userWithoutVaultShares);
    _mintAmount = _boundMintAmount(_mintAmount);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);

    // Sync user without shares when global indices are 0
    vaultShareToken.updateUserFees(_userWithoutVaultShares);

    // Mint shares for another user and collect fees to change global indices
    vaultShareToken.exposed_mint(_userWithVaultShares, _mintAmount);
    vaultShareToken.exposed_updateFees(_collectedFeeToken0, _collectedFeeToken1);

    // Update user without shares - even though global index > user index, accrued should remain 0
    // because user has no balance
    vaultShareToken.updateUserFees(_userWithoutVaultShares);

    (,, uint256 _userAccruedToken0, uint256 _userAccruedToken1) =
      vaultShareToken.userFees(_userWithoutVaultShares);

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

    // Mint shares for user and collect fees to change global indices
    vaultShareToken.exposed_mint(_user, _mintAmount);
    vaultShareToken.exposed_updateFees(_collectedFeeToken0, _collectedFeeToken1);

    // Get the new global fee indices
    uint256 _globalFeeIndex0 = vaultShareToken.feeIndexToken0();
    uint256 _globalFeeIndex1 = vaultShareToken.feeIndexToken1();

    // User's index before update is 0 (default for new user)
    uint256 _userFeeIndex0Before = 0;
    uint256 _userFeeIndex1Before = 0;

    // Perform the update for the user
    vaultShareToken.updateUserFees(_user);

    // Destructure the tuple again after the update
    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,
      uint256 _userAccruedToken0,
      uint256 _userAccruedToken1
    ) = vaultShareToken.userFees(_user);

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

    // Mint shares for user and collect fees to change global indices
    vaultShareToken.exposed_mint(_user, _mintAmount);
    vaultShareToken.exposed_updateFees(_collectedFeeToken0, _collectedFeeToken1);

    // Perform the update for the user
    vaultShareToken.updateUserFees(_user);

    // Destructure the tuple again after the update
    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,
      uint256 _userAccruedToken0,
      uint256 _userAccruedToken1
    ) = vaultShareToken.userFees(_user);

    // Again perform the update for the user
    vaultShareToken.updateUserFees(_user);

    // Destructure the tuple again after the update
    (
      uint256 _userFeeIndex0AfterSecondUpdate,
      uint256 _userFeeIndex1AfterSecondUpdate,
      uint256 _userAccruedToken0AfterSecondUpdate,
      uint256 _userAccruedToken1AfterSecondUpdate
    ) = vaultShareToken.userFees(_user);

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

    // Mint shares for user and collect fees to change global indices
    vaultShareToken.exposed_mint(_user, _mintAmount);
    vaultShareToken.exposed_updateFees(_collectedFeeToken0, 0);

    // Get the new global fee indices
    uint256 _globalFeeIndex0 = vaultShareToken.feeIndexToken0();
    uint256 _globalFeeIndex1 = vaultShareToken.feeIndexToken1();

    // User's index before update is 0 (default for new user)
    uint256 _userFeeIndex0Before = 0;

    // Perform the update for the user
    vaultShareToken.updateUserFees(_user);

    // Destructure the tuple again after the update
    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,
      uint256 _userAccruedToken0,
      uint256 _userAccruedToken1
    ) = vaultShareToken.userFees(_user);

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

    // Mint shares for user and collect fees to change global indices
    vaultShareToken.exposed_mint(_user, _mintAmount);
    vaultShareToken.exposed_updateFees(0, _collectedFeeToken1);

    // Get the new global fee indices
    uint256 _globalFeeIndex0 = vaultShareToken.feeIndexToken0();
    uint256 _globalFeeIndex1 = vaultShareToken.feeIndexToken1();

    // User's index before update is 0 (default for new user)
    uint256 _userFeeIndex1Before = 0;

    // Perform the update for the user
    vaultShareToken.updateUserFees(_user);

    // Destructure the tuple again after the update
    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,
      uint256 _userAccruedToken0,
      uint256 _userAccruedToken1
    ) = vaultShareToken.userFees(_user);

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

    // Mint shares for user
    vaultShareToken.exposed_mint(_user, _mintAmount);

    // Collect fees round 1 -> global index increases
    vaultShareToken.exposed_updateFees(_collectedFeeToken0Round1, _collectedFeeToken1Round1);

    // Collect fees round 2 -> global index increases again
    vaultShareToken.exposed_updateFees(_collectedFeeToken0Round2, _collectedFeeToken1Round2);

    // Get the final global fee indices (after both rounds)
    uint256 _finalGlobalFeeIndex0 = vaultShareToken.feeIndexToken0();
    uint256 _finalGlobalFeeIndex1 = vaultShareToken.feeIndexToken1();

    // User's index before update is 0 (default for new user)
    uint256 _userFeeIndex0Before = 0;
    uint256 _userFeeIndex1Before = 0;

    // Perform the update for the user - should accrue for BOTH rounds (delta from 0 to final)
    vaultShareToken.updateUserFees(_user);

    // Destructure the tuple after the update
    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,
      uint256 _userAccruedToken0,
      uint256 _userAccruedToken1
    ) = vaultShareToken.userFees(_user);

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

  function testFuzz_UserWithSharesDoesNotRetroactivelyEarnFeesWhenMintingAfterFeesCollected(
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

    // Another user mints shares and fees are collected
    vaultShareToken.exposed_mint(_existingUser, _existingUserMintAmount);
    vaultShareToken.exposed_updateFees(_collectedFeeToken0, _collectedFeeToken1);

    // Get the global fee indices after fees are collected
    uint256 _globalFeeIndex0 = vaultShareToken.feeIndexToken0();
    uint256 _globalFeeIndex1 = vaultShareToken.feeIndexToken1();

    // New user mints shares AFTER fees were collected
    vaultShareToken.exposed_mint(_newUser, _newUserMintAmount);

    // New user's index should be checkpointed to current global index (no retroactive earnings)
    // This happens automatically via _update in the mint function
    (
      uint256 _newUserFeeIndex0,
      uint256 _newUserFeeIndex1,
      uint256 _newUserAccruedToken0,
      uint256 _newUserAccruedToken1
    ) = vaultShareToken.userFees(_newUser);

    // New user's index should be synced to global index (checkpointed, not 0)
    assertEq(_newUserFeeIndex0, _globalFeeIndex0);
    assertEq(_newUserFeeIndex1, _globalFeeIndex1);

    // New user should have 0 accrued fees (they didn't earn fees collected before they had shares)
    assertEq(_newUserAccruedToken0, 0);
    assertEq(_newUserAccruedToken1, 0);
  }

  function testFuzz_FeeAccrualUsesCurrentBalanceNotHistoricalBalance(
    address _user,
    uint256 _mintAmount1,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1,
    uint256 _mintAmount2,
    uint256 _collectedFeeToken0Round2,
    uint256 _collectedFeeToken1Round2
  ) public {
    _assumeSafeAddress(_user);
    _mintAmount1 = _boundMintAmount(_mintAmount1);
    _mintAmount2 = _boundMintAmount(_mintAmount2);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);
    _collectedFeeToken0Round2 = _boundFeeAmount(_collectedFeeToken0Round2);
    _collectedFeeToken1Round2 = _boundFeeAmount(_collectedFeeToken1Round2);

    // User mints amount1
    vaultShareToken.exposed_mint(_user, _mintAmount1);

    // Fees collected round 1 (user's balance at this point is amount1)
    vaultShareToken.exposed_updateFees(_collectedFeeToken0, _collectedFeeToken1);

    // Get global fee indices after round 1
    uint256 _globalFeeIndex0AfterRound1 = vaultShareToken.feeIndexToken0();
    uint256 _globalFeeIndex1AfterRound1 = vaultShareToken.feeIndexToken1();

    // User mints amount2 (balance is now amount1 + amount2)
    // During mint, _updateUserFees is called BEFORE balance update, so accrual uses amount1
    vaultShareToken.exposed_mint(_user, _mintAmount2);

    // Get user's fee index after the second mint (indices are synced during mint to round 1
    // indices)
    (uint256 _userFeeIndex0AfterMint, uint256 _userFeeIndex1AfterMint,,) =
      vaultShareToken.userFees(_user);

    // Verify indices were synced to round 1 indices
    assertEq(_userFeeIndex0AfterMint, _globalFeeIndex0AfterRound1);
    assertEq(_userFeeIndex1AfterMint, _globalFeeIndex1AfterRound1);

    // Fees collected round 2 (global indices increase again)
    vaultShareToken.exposed_updateFees(_collectedFeeToken0Round2, _collectedFeeToken1Round2);

    // Get the final global fee indices after round 2
    uint256 _finalGlobalFeeIndex0 = vaultShareToken.feeIndexToken0();
    uint256 _finalGlobalFeeIndex1 = vaultShareToken.feeIndexToken1();

    // User's current balance is (amount1 + amount2)
    uint256 _currentBalance = _mintAmount1 + _mintAmount2;

    // Perform the update for the user - should use CURRENT balance (amount1 + amount2)
    vaultShareToken.updateUserFees(_user);

    // Destructure the tuple after the update
    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,
      uint256 _userAccruedToken0,
      uint256 _userAccruedToken1
    ) = vaultShareToken.userFees(_user);

    // Check that the user has the correct fee indices
    assertEq(_userFeeIndex0, _finalGlobalFeeIndex0);
    assertEq(_userFeeIndex1, _finalGlobalFeeIndex1);

    // Total accrued fees = fees from round 1 (accrued during mint using amount1) + fees from round
    // 2 (accrued during explicit update using current balance) Round 1: accrued during second mint
    // using balance amount1 (from index 0 to index after round 1)
    uint256 _feesFromRound1Token0 = _calculateAccruedFees(_mintAmount1, _userFeeIndex0AfterMint, 0);
    uint256 _feesFromRound1Token1 = _calculateAccruedFees(_mintAmount1, _userFeeIndex1AfterMint, 0);

    // Round 2: accrued during explicit updateUserFees using CURRENT balance (amount1 + amount2)
    // This verifies that explicit updateUserFees uses current balance, not historical balance
    uint256 _feesFromRound2Token0 =
      _calculateAccruedFees(_currentBalance, _finalGlobalFeeIndex0, _userFeeIndex0AfterMint);
    uint256 _feesFromRound2Token1 =
      _calculateAccruedFees(_currentBalance, _finalGlobalFeeIndex1, _userFeeIndex1AfterMint);

    // Total accrued should be sum of both rounds
    assertEq(_userAccruedToken0, _feesFromRound1Token0 + _feesFromRound2Token0);
    assertEq(_userAccruedToken1, _feesFromRound1Token1 + _feesFromRound2Token1);
  }

  function testFuzz_UserWithSharesAccruesFeesBeforeBalanceDecreasesOnBurn(
    address _user,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1,
    uint256 _burnAmount
  ) public {
    _assumeSafeAddress(_user);
    _mintAmount = _boundMintAmount(_mintAmount);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);
    _burnAmount = bound(_burnAmount, 1, _mintAmount); // Burn at least 1, but not more than minted

    // User mints shares
    vaultShareToken.exposed_mint(_user, _mintAmount);

    // Fees collected (global indices increase)
    vaultShareToken.exposed_updateFees(_collectedFeeToken0, _collectedFeeToken1);

    // User burns shares - _update is called before balance decreases, so accrual uses pre-burn
    // balance
    vaultShareToken.exposed_burn(_user, _burnAmount);

    // Verify balance decreased
    assertEq(vaultShareToken.balanceOf(_user), _mintAmount - _burnAmount);

    // Get state after burn
    uint256 _globalFeeIndex0 = vaultShareToken.feeIndexToken0();
    uint256 _globalFeeIndex1 = vaultShareToken.feeIndexToken1();
    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,
      uint256 _userAccruedToken0,
      uint256 _userAccruedToken1
    ) = vaultShareToken.userFees(_user);

    // Check that the user has the correct fee indices
    assertEq(_userFeeIndex0, _globalFeeIndex0);
    assertEq(_userFeeIndex1, _globalFeeIndex1);

    // Verify accrual used pre-burn balance (mintAmount), not post-burn balance (mintAmount -
    // burnAmount) User's index before update is 0 (default for new user)
    assertEq(_userAccruedToken0, _calculateAccruedFees(_mintAmount, _globalFeeIndex0, 0));
    assertEq(_userAccruedToken1, _calculateAccruedFees(_mintAmount, _globalFeeIndex1, 0));
  }
}
