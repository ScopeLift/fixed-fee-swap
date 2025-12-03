// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// External Imports
import {Test} from "forge-std/Test.sol";

// Internal Imports
import {VaultShareToken} from "src/VaultShareToken.sol";
import {VaultShareTokenHarness} from "test/harness/VaultShareTokenHarness.sol";
import {ERC20Mock} from "test/mock/ERC20Mock.sol";

contract VaultShareTokenTest is Test {
  VaultShareTokenHarness public vaultShareToken;
  ERC20Mock public token0;
  ERC20Mock public token1;

  function setUp() public virtual {
    vaultShareToken = new VaultShareTokenHarness("Vault Share Token", "VST");
    token0 = new ERC20Mock("Token 0", "T0");
    token1 = new ERC20Mock("Token 1", "T1");
  }

  function _assumeSafeAddress(address _address) internal pure {
    vm.assume(_address != address(0));
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
    // This covers standard Ethereum precompiles (0x01-0x09) and additional ones in test
    // environments
    vm.assume(_address > address(0x0F));
    // Exclude contract addresses (for native ETH transfers)
    vm.assume(_address.code.length == 0);
  }

  function _assumeSafeAmount(uint256 _amount) internal pure {
    vm.assume(_amount != 0);
  }

  function _boundFeeAmount(uint256 _amount) internal pure returns (uint256) {
    // Bound fees so that, even with minimal supply and multiple fee rounds,
    // the cumulative fee index updates cannot overflow uint256.
    //
    // Each update adds ~ collectedFee * PRECISION / totalSupply.
    // To prevent overflow in `collectedFee * PRECISION`, we need:
    //   collectedFee * PRECISION <= type(uint256).max
    //   collectedFee <= type(uint256).max / PRECISION
    //
    // Using uint192.max provides a simpler, safe bound,
    uint256 _maxFeePerRound = type(uint192).max;
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
    if (_globalIndex == _userIndex) return 0;
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
    uint256 _globalFeeIndex0 = vaultShareToken.globalFeeIndex0Scaled();
    uint256 _globalFeeIndex1 = vaultShareToken.globalFeeIndex1Scaled();

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
    uint256 _globalFeeIndex0 = vaultShareToken.globalFeeIndex0Scaled();
    uint256 _globalFeeIndex1 = vaultShareToken.globalFeeIndex1Scaled();

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

  struct MultipleBurnsParams {
    address user;
    uint256 mintAmount;
    uint256 collectedFeeToken0Round1;
    uint256 collectedFeeToken1Round1;
    uint256 burnAmount1;
    uint256 collectedFeeToken0Round2;
    uint256 collectedFeeToken1Round2;
    uint256 burnAmount2;
  }

  function testFuzz_UpdatesUserFeesOnMultipleBurns(MultipleBurnsParams memory _params) public {
    _assumeSafeAddress(_params.user);
    _params.mintAmount = _boundMintAmount(_params.mintAmount);
    // Ensure we have enough for two burns
    _params.mintAmount = bound(_params.mintAmount, 2, type(uint128).max);
    _params.collectedFeeToken0Round1 = _boundFeeAmount(_params.collectedFeeToken0Round1);
    _params.collectedFeeToken1Round1 = _boundFeeAmount(_params.collectedFeeToken1Round1);
    _params.collectedFeeToken0Round2 = _boundFeeAmount(_params.collectedFeeToken0Round2);
    _params.collectedFeeToken1Round2 = _boundFeeAmount(_params.collectedFeeToken1Round2);
    // Ensure we can do two burns: first burn leaves at least 1 for second burn
    _params.burnAmount1 = bound(_params.burnAmount1, 1, _params.mintAmount - 1);
    _params.burnAmount2 = bound(_params.burnAmount2, 1, _params.mintAmount - _params.burnAmount1); // Burn
    // remaining or less

    // User mints shares
    vaultShareToken.exposed_mint(_params.user, _params.mintAmount);

    // Fees collected round 1
    vaultShareToken.exposed_updateFees(
      _params.collectedFeeToken0Round1, _params.collectedFeeToken1Round1
    );
    uint256 _globalFeeIndex0AfterRound1 = vaultShareToken.globalFeeIndex0Scaled();
    uint256 _globalFeeIndex1AfterRound1 = vaultShareToken.globalFeeIndex1Scaled();

    // First burn - should accrue based on initial balance (_mintAmount)
    vaultShareToken.exposed_burn(_params.user, _params.burnAmount1);

    // Fees collected round 2 (user now has _mintAmount - _burnAmount1 shares)
    vaultShareToken.exposed_updateFees(
      _params.collectedFeeToken0Round2, _params.collectedFeeToken1Round2
    );
    uint256 _globalFeeIndex0AfterRound2 = vaultShareToken.globalFeeIndex0Scaled();
    uint256 _globalFeeIndex1AfterRound2 = vaultShareToken.globalFeeIndex1Scaled();

    // Second burn - should accrue based on balance before second burnn
    vaultShareToken.exposed_burn(_params.user, _params.burnAmount2);

    // Get user fees after both burns
    (,, uint256 _userAccruedToken0, uint256 _userAccruedToken1) =
      vaultShareToken.userFees(_params.user);

    // User should have accrued fees from both rounds:
    // - Round 1: based on initial balance (_mintAmount)
    // - Round 2: based on balance after first burn (_balanceAfterFirstBurn)
    uint256 _balanceAfterFirstBurn = _params.mintAmount - _params.burnAmount1;
    uint256 _expected0 = _calculateAccruedFees(_params.mintAmount, _globalFeeIndex0AfterRound1, 0)
      + _calculateAccruedFees(
        _balanceAfterFirstBurn, _globalFeeIndex0AfterRound2, _globalFeeIndex0AfterRound1
      );
    uint256 _expected1 = _calculateAccruedFees(_params.mintAmount, _globalFeeIndex1AfterRound1, 0)
      + _calculateAccruedFees(
        _balanceAfterFirstBurn, _globalFeeIndex1AfterRound2, _globalFeeIndex1AfterRound1
      );

    assertEq(_userAccruedToken0, _expected0);
    assertEq(_userAccruedToken1, _expected1);
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

  struct TransferParams {
    address from;
    address to;
    uint256 mintAmount;
    uint256 collectedFeeToken0Round1;
    uint256 collectedFeeToken1Round1;
    uint256 collectedFeeToken0Round2;
    uint256 collectedFeeToken1Round2;
  }

  function testFuzz_UpdatesUserFeesOnTransfer(TransferParams memory _params) public {
    _assumeSafeAddress(_params.from);
    _assumeSafeAddress(_params.to);
    vm.assume(_params.from != _params.to);
    _params.mintAmount = _boundMintAmount(_params.mintAmount);
    _params.collectedFeeToken0Round1 = _boundFeeAmount(_params.collectedFeeToken0Round1);
    _params.collectedFeeToken1Round1 = _boundFeeAmount(_params.collectedFeeToken1Round1);
    _params.collectedFeeToken0Round2 = _boundFeeAmount(_params.collectedFeeToken0Round2);
    _params.collectedFeeToken1Round2 = _boundFeeAmount(_params.collectedFeeToken1Round2);

    // Step 1: User mints shares
    vaultShareToken.exposed_mint(_params.from, _params.mintAmount);

    // Step 2: Fees are collected (user accrues fees because they have shares)
    vaultShareToken.exposed_updateFees(
      _params.collectedFeeToken0Round1, _params.collectedFeeToken1Round1
    );
    uint256 _globalFeeIndex0AfterRound1 = vaultShareToken.globalFeeIndex0Scaled();
    uint256 _globalFeeIndex1AfterRound1 = vaultShareToken.globalFeeIndex1Scaled();

    // Step 3: User transfers ALL shares to new user
    // This triggers _updateUserFees for both parties, accruing fees from round 1 for _from
    vm.prank(_params.from);
    bool _success = vaultShareToken.transfer(_params.to, _params.mintAmount);
    assertTrue(_success);

    // Verify balances after transfer
    assertEq(vaultShareToken.balanceOf(_params.from), 0);
    assertEq(vaultShareToken.balanceOf(_params.to), _params.mintAmount);

    // Verify sender accrued fees from round 1 (earned while they had shares)
    (,, uint256 _senderAccruedToken0AfterTransfer, uint256 _senderAccruedToken1AfterTransfer) =
      vaultShareToken.userFees(_params.from);
    {
      uint256 _expectedSenderAccrued0 =
        _calculateAccruedFees(_params.mintAmount, _globalFeeIndex0AfterRound1, 0);
      uint256 _expectedSenderAccrued1 =
        _calculateAccruedFees(_params.mintAmount, _globalFeeIndex1AfterRound1, 0);
      assertEq(_senderAccruedToken0AfterTransfer, _expectedSenderAccrued0);
      assertEq(_senderAccruedToken1AfterTransfer, _expectedSenderAccrued1);
    }

    // Step 4: New fees come in
    vaultShareToken.exposed_updateFees(
      _params.collectedFeeToken0Round2, _params.collectedFeeToken1Round2
    );
    uint256 _globalFeeIndex0AfterRound2 = vaultShareToken.globalFeeIndex0Scaled();
    uint256 _globalFeeIndex1AfterRound2 = vaultShareToken.globalFeeIndex1Scaled();

    // Update both users' fees to reflect the new fee collection via the public hook
    vaultShareToken.exposed_updateUserFees(_params.from);
    vaultShareToken.exposed_updateUserFees(_params.to);

    // Get sender's fees after round 2 (they have 0 balance)
    {
      (
        uint256 _senderFeeIndex0AfterRound2,
        uint256 _senderFeeIndex1AfterRound2,
        uint256 _senderAccruedToken0AfterRound2,
        uint256 _senderAccruedToken1AfterRound2
      ) = vaultShareToken.userFees(_params.from);

      // Original user (_from): global checkpoint updated, but accrued fees don't increase (0
      // balance)
      assertEq(_senderFeeIndex0AfterRound2, _globalFeeIndex0AfterRound2);
      assertEq(_senderFeeIndex1AfterRound2, _globalFeeIndex1AfterRound2);
      // Accrued fees should remain the same (no increase because balance is 0)
      assertEq(_senderAccruedToken0AfterRound2, _senderAccruedToken0AfterTransfer);
      assertEq(_senderAccruedToken1AfterRound2, _senderAccruedToken1AfterTransfer);
    }

    // Get recipient's fees after round 2 (they have shares)
    {
      (
        uint256 _recipientFeeIndex0AfterRound2,
        uint256 _recipientFeeIndex1AfterRound2,
        uint256 _recipientAccruedToken0AfterRound2,
        uint256 _recipientAccruedToken1AfterRound2
      ) = vaultShareToken.userFees(_params.to);

      // New user (_to): global checkpoint updated AND accrued fees increase (has shares)
      assertEq(_recipientFeeIndex0AfterRound2, _globalFeeIndex0AfterRound2);
      assertEq(_recipientFeeIndex1AfterRound2, _globalFeeIndex1AfterRound2);

      // Recipient should have accrued fees from round 2 (based on their balance)
      uint256 _expectedRecipientAccrued0 = _calculateAccruedFees(
        _params.mintAmount, _globalFeeIndex0AfterRound2, _globalFeeIndex0AfterRound1
      );
      uint256 _expectedRecipientAccrued1 = _calculateAccruedFees(
        _params.mintAmount, _globalFeeIndex1AfterRound2, _globalFeeIndex1AfterRound1
      );
      assertEq(_recipientAccruedToken0AfterRound2, _expectedRecipientAccrued0);
      assertEq(_recipientAccruedToken1AfterRound2, _expectedRecipientAccrued1);
    }
  }
}

contract UpdateFees is VaultShareTokenTest {
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

    vaultShareToken.exposed_mint(_minterAccount, _mintAmount);

    assertEq(vaultShareToken.globalFeeIndex0Scaled(), 0);
    assertEq(vaultShareToken.globalFeeIndex1Scaled(), 0);

    vaultShareToken.exposed_updateFees(_collectedFeeToken0, _collectedFeeToken1);

    assertEq(
      vaultShareToken.globalFeeIndex0Scaled(), _calculateFeeIndex(_collectedFeeToken0, _mintAmount)
    );
    assertEq(
      vaultShareToken.globalFeeIndex1Scaled(), _calculateFeeIndex(_collectedFeeToken1, _mintAmount)
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

    vaultShareToken.exposed_mint(_minterAccountAtT1, _mintAmountAtT1);

    vaultShareToken.exposed_updateFees(_collectedFeeToken0AtT1, _collectedFeeToken1AtT1);

    uint256 _expectedFeeIndex0 = _calculateFeeIndex(_collectedFeeToken0AtT1, _mintAmountAtT1);
    uint256 _expectedFeeIndex1 = _calculateFeeIndex(_collectedFeeToken1AtT1, _mintAmountAtT1);

    assertEq(vaultShareToken.globalFeeIndex0Scaled(), _expectedFeeIndex0);
    assertEq(vaultShareToken.globalFeeIndex1Scaled(), _expectedFeeIndex1);

    vaultShareToken.exposed_mint(_minterAccountAtT2, _mintAmountAtT2);

    vaultShareToken.exposed_updateFees(_collectedFeeToken0AtT2, _collectedFeeToken1AtT2);

    uint256 _totalSupplyAfterT2 = _mintAmountAtT1 + _mintAmountAtT2;
    _expectedFeeIndex0 += _calculateFeeIndex(_collectedFeeToken0AtT2, _totalSupplyAfterT2);
    _expectedFeeIndex1 += _calculateFeeIndex(_collectedFeeToken1AtT2, _totalSupplyAfterT2);

    assertEq(vaultShareToken.globalFeeIndex0Scaled(), _expectedFeeIndex0);
    assertEq(vaultShareToken.globalFeeIndex1Scaled(), _expectedFeeIndex1);
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

    assertEq(vaultShareToken.globalFeeIndex0Scaled(), 0);
    assertEq(vaultShareToken.globalFeeIndex1Scaled(), 0);

    vaultShareToken.exposed_updateFees(0, _collectedFeeToken1);

    assertEq(vaultShareToken.globalFeeIndex0Scaled(), 0);
    assertEq(
      vaultShareToken.globalFeeIndex1Scaled(), _calculateFeeIndex(_collectedFeeToken1, _mintAmount)
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

    vaultShareToken.exposed_mint(_minterAccount, _mintAmount);

    assertEq(vaultShareToken.globalFeeIndex0Scaled(), 0);
    assertEq(vaultShareToken.globalFeeIndex1Scaled(), 0);

    vaultShareToken.exposed_updateFees(_collectedFeeToken0, 0);

    assertEq(
      vaultShareToken.globalFeeIndex0Scaled(), _calculateFeeIndex(_collectedFeeToken0, _mintAmount)
    );
    assertEq(vaultShareToken.globalFeeIndex1Scaled(), 0);
  }

  function testFuzz_FeeIndexesAreNotUpdatedWhenNoSharesMinted(
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1
  ) public {
    assertEq(vaultShareToken.totalSupply(), 0);
    assertEq(vaultShareToken.globalFeeIndex0Scaled(), 0);
    assertEq(vaultShareToken.globalFeeIndex1Scaled(), 0);

    vaultShareToken.exposed_updateFees(_collectedFeeToken0, _collectedFeeToken1);

    assertEq(vaultShareToken.globalFeeIndex0Scaled(), 0);
    assertEq(vaultShareToken.globalFeeIndex1Scaled(), 0);
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
    vaultShareToken.exposed_updateUserFees(_user);

    // Get the global fee indices (should be 0 initially)
    uint256 _globalFeeIndex0 = vaultShareToken.globalFeeIndex0Scaled();
    uint256 _globalFeeIndex1 = vaultShareToken.globalFeeIndex1Scaled();

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
    vaultShareToken.exposed_updateUserFees(_userWithoutVaultShares);

    // Mint shares for another user and collect fees to change global indices
    vaultShareToken.exposed_mint(_userWithVaultShares, _mintAmount);
    vaultShareToken.exposed_updateFees(_collectedFeeToken0, _collectedFeeToken1);

    // Get the new global fee indices (should be > 0 now)
    uint256 _globalFeeIndex0 = vaultShareToken.globalFeeIndex0Scaled();
    uint256 _globalFeeIndex1 = vaultShareToken.globalFeeIndex1Scaled();

    // Perform the update for the user without vault shares
    vaultShareToken.exposed_updateUserFees(_userWithoutVaultShares);

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
    vaultShareToken.exposed_updateUserFees(_user);

    (uint256 _userFeeIndex0AfterFirstSync, uint256 _userFeeIndex1AfterFirstSync,,) =
      vaultShareToken.userFees(_user);

    // Verify indices were synced to 0
    assertEq(_userFeeIndex0AfterFirstSync, 0);
    assertEq(_userFeeIndex1AfterFirstSync, 0);

    // Second sync: indices should remain the same (already synced, no unnecessary update)
    vaultShareToken.exposed_updateUserFees(_user);

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
    vaultShareToken.exposed_updateUserFees(_userWithoutVaultShares);

    // Mint shares for another user and collect fees to change global indices
    vaultShareToken.exposed_mint(_userWithVaultShares, _mintAmount);
    vaultShareToken.exposed_updateFees(_collectedFeeToken0, _collectedFeeToken1);

    // Update user without shares - even though global index > user index, accrued should remain 0
    // because user has no balance
    vaultShareToken.exposed_updateUserFees(_userWithoutVaultShares);

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
    uint256 _globalFeeIndex0 = vaultShareToken.globalFeeIndex0Scaled();
    uint256 _globalFeeIndex1 = vaultShareToken.globalFeeIndex1Scaled();

    // User's index before update is 0 (default for new user)
    uint256 _userFeeIndex0Before = 0;
    uint256 _userFeeIndex1Before = 0;

    // Perform the update for the user
    vaultShareToken.exposed_updateUserFees(_user);

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
    vaultShareToken.exposed_updateUserFees(_user);

    // Destructure the tuple again after the update
    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,
      uint256 _userAccruedToken0,
      uint256 _userAccruedToken1
    ) = vaultShareToken.userFees(_user);

    // Again perform the update for the user
    vaultShareToken.exposed_updateUserFees(_user);

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
    uint256 _globalFeeIndex0 = vaultShareToken.globalFeeIndex0Scaled();
    uint256 _globalFeeIndex1 = vaultShareToken.globalFeeIndex1Scaled();

    // User's index before update is 0 (default for new user)
    uint256 _userFeeIndex0Before = 0;

    // Perform the update for the user
    vaultShareToken.exposed_updateUserFees(_user);

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
    uint256 _globalFeeIndex0 = vaultShareToken.globalFeeIndex0Scaled();
    uint256 _globalFeeIndex1 = vaultShareToken.globalFeeIndex1Scaled();

    // User's index before update is 0 (default for new user)
    uint256 _userFeeIndex1Before = 0;

    // Perform the update for the user
    vaultShareToken.exposed_updateUserFees(_user);

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
    uint256 _finalGlobalFeeIndex0 = vaultShareToken.globalFeeIndex0Scaled();
    uint256 _finalGlobalFeeIndex1 = vaultShareToken.globalFeeIndex1Scaled();

    // User's index before update is 0 (default for new user)
    uint256 _userFeeIndex0Before = 0;
    uint256 _userFeeIndex1Before = 0;

    // Perform the update for the user - should accrue for BOTH rounds (delta from 0 to final)
    vaultShareToken.exposed_updateUserFees(_user);

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
    uint256 _globalFeeIndex0 = vaultShareToken.globalFeeIndex0Scaled();
    uint256 _globalFeeIndex1 = vaultShareToken.globalFeeIndex1Scaled();

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

  struct FeeAccrualParams {
    address user;
    uint256 mintAmount1;
    uint256 collectedFeeToken0;
    uint256 collectedFeeToken1;
    uint256 mintAmount2;
    uint256 collectedFeeToken0Round2;
    uint256 collectedFeeToken1Round2;
  }

  function testFuzz_FeeAccrualUsesCurrentBalanceNotHistoricalBalance(FeeAccrualParams memory _params)
    public
  {
    _assumeSafeAddress(_params.user);
    _params.mintAmount1 = _boundMintAmount(_params.mintAmount1);
    _params.mintAmount2 = _boundMintAmount(_params.mintAmount2);
    _params.collectedFeeToken0 = _boundFeeAmount(_params.collectedFeeToken0);
    _params.collectedFeeToken1 = _boundFeeAmount(_params.collectedFeeToken1);
    _params.collectedFeeToken0Round2 = _boundFeeAmount(_params.collectedFeeToken0Round2);
    _params.collectedFeeToken1Round2 = _boundFeeAmount(_params.collectedFeeToken1Round2);

    // User mints amount1
    vaultShareToken.exposed_mint(_params.user, _params.mintAmount1);

    // Fees collected round 1 (user's balance at this point is amount1)
    vaultShareToken.exposed_updateFees(_params.collectedFeeToken0, _params.collectedFeeToken1);

    // Get global fee indices after round 1
    uint256 _globalFeeIndex0AfterRound1 = vaultShareToken.globalFeeIndex0Scaled();
    uint256 _globalFeeIndex1AfterRound1 = vaultShareToken.globalFeeIndex1Scaled();

    // User mints amount2 (balance is now amount1 + amount2)
    // During mint, _updateUserFees is called BEFORE balance update, so accrual uses amount1
    vaultShareToken.exposed_mint(_params.user, _params.mintAmount2);

    // Get user's fee index after the second mint (indices are synced during mint to round 1
    // indices)
    (uint256 _userFeeIndex0AfterMint, uint256 _userFeeIndex1AfterMint,,) =
      vaultShareToken.userFees(_params.user);

    // Verify indices were synced to round 1 indices
    assertEq(_userFeeIndex0AfterMint, _globalFeeIndex0AfterRound1);
    assertEq(_userFeeIndex1AfterMint, _globalFeeIndex1AfterRound1);

    // Fees collected round 2 (global indices increase again)
    vaultShareToken.exposed_updateFees(
      _params.collectedFeeToken0Round2, _params.collectedFeeToken1Round2
    );

    // Get the final global fee indices after round 2
    uint256 _finalGlobalFeeIndex0 = vaultShareToken.globalFeeIndex0Scaled();
    uint256 _finalGlobalFeeIndex1 = vaultShareToken.globalFeeIndex1Scaled();

    // Perform the update for the user - should use CURRENT balance (amount1 + amount2)
    vaultShareToken.exposed_updateUserFees(_params.user);

    // Get user fees after update
    (
      uint256 _userFeeIndex0,
      uint256 _userFeeIndex1,
      uint256 _userAccruedToken0,
      uint256 _userAccruedToken1
    ) = vaultShareToken.userFees(_params.user);

    // Check that the user has the correct fee indices
    assertEq(_userFeeIndex0, _finalGlobalFeeIndex0);
    assertEq(_userFeeIndex1, _finalGlobalFeeIndex1);

    // User's current balance is (amount1 + amount2)
    uint256 _currentBalance = _params.mintAmount1 + _params.mintAmount2;

    // Total accrued fees = fees from round 1 (accrued during mint using amount1) + fees from round
    // 2 (accrued during explicit update using current balance)
    // Round 1: accrued during second mint using balance amount1 (from index 0 to index after round
    // 1)
    uint256 _feesFromRound1Token0 =
      _calculateAccruedFees(_params.mintAmount1, _userFeeIndex0AfterMint, 0);
    uint256 _feesFromRound1Token1 =
      _calculateAccruedFees(_params.mintAmount1, _userFeeIndex1AfterMint, 0);

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
    uint256 _globalFeeIndex0 = vaultShareToken.globalFeeIndex0Scaled();
    uint256 _globalFeeIndex1 = vaultShareToken.globalFeeIndex1Scaled();
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

/// @notice Contract that rejects ETH transfers (no payable fallback or receive function).
contract NonPayableContract {
  // Intentionally no receive() or fallback() payable functions

  }

contract Claim is VaultShareTokenTest {
  function testFuzz_transfersTokens(
    address _user,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1
  ) public {
    _assumeSafeEOA(_user);
    _mintAmount = _boundMintAmount(_mintAmount);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);

    // Store initial balances to verify the delta after claiming
    uint256 _initialUserEthBalance = _user.balance;
    uint256 _initialUserToken1Balance = token1.balanceOf(_user);

    // Mint and send fees for token0 and token1 into the vault
    vm.deal(address(vaultShareToken), _collectedFeeToken0); // Native token
    token1.mint(address(vaultShareToken), _collectedFeeToken1); // ERC20 token

    // User mints shares
    vaultShareToken.exposed_mint(_user, _mintAmount);

    // Fees collected (global indices increase)
    vaultShareToken.exposed_updateFees(_collectedFeeToken0, _collectedFeeToken1);

    // Sync user fees to latest global indices
    vaultShareToken.exposed_updateUserFees(_user);

    // Assert balance of tokens in vault
    assertEq(address(vaultShareToken).balance, _collectedFeeToken0);
    assertEq(token1.balanceOf(address(vaultShareToken)), _collectedFeeToken1);

    // Get accrued amounts before claiming
    (,, uint256 _accruedToken0BeforeClaiming, uint256 _accruedToken1BeforeClaiming) =
      vaultShareToken.userFees(_user);

    // User claims fees
    (uint256 _claimedToken0, uint256 _claimedToken1) =
      vaultShareToken.claim(_user, address(0), address(token1));

    // Verify claimed amounts match accrued amounts
    assertEq(_claimedToken0, _accruedToken0BeforeClaiming);
    assertEq(_claimedToken1, _accruedToken1BeforeClaiming);

    // Verify tokens were transferred to user (check delta from initial balance)
    assertEq(_user.balance, _initialUserEthBalance + _claimedToken0);
    assertEq(token1.balanceOf(_user), _initialUserToken1Balance + _claimedToken1);

    // Verify vault balance equals the dust (collected - claimed) due to Floor rounding
    // This dust is intentional and safe - it remains in the vault
    assertEq(address(vaultShareToken).balance, _collectedFeeToken0 - _claimedToken0);
    assertEq(token1.balanceOf(address(vaultShareToken)), _collectedFeeToken1 - _claimedToken1);
  }

  function testFuzz_emitsFeesClaimedEvent(
    address _user,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1
  ) public {
    _assumeSafeAddress(_user);
    _mintAmount = _boundMintAmount(_mintAmount);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);

    // Mint and send fees for token0 and token1 into the vault
    token0.mint(address(vaultShareToken), _collectedFeeToken0);
    token1.mint(address(vaultShareToken), _collectedFeeToken1);

    // User mints shares
    vaultShareToken.exposed_mint(_user, _mintAmount);

    // Fees collected (global indices increase)
    vaultShareToken.exposed_updateFees(_collectedFeeToken0, _collectedFeeToken1);

    // Sync user fees to latest global indices
    vaultShareToken.exposed_updateUserFees(_user);

    // Get accrued amounts before claiming
    (,, uint256 _accruedToken0BeforeClaiming, uint256 _accruedToken1BeforeClaiming) =
      vaultShareToken.userFees(_user);

    // User claims fees
    vm.expectEmit();
    emit VaultShareToken.FeesClaimed(
      _user,
      address(token0),
      address(token1),
      _accruedToken0BeforeClaiming,
      _accruedToken1BeforeClaiming
    );
    vaultShareToken.claim(_user, address(token0), address(token1));
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

    // Mint and send fees for token0 and token1 into the vault
    token0.mint(address(vaultShareToken), _collectedFeeToken0);
    token1.mint(address(vaultShareToken), _collectedFeeToken1);

    // User mints shares
    vaultShareToken.exposed_mint(_user, _mintAmount);

    // Fees collected (global indices increase)
    vaultShareToken.exposed_updateFees(_collectedFeeToken0, _collectedFeeToken1);

    // Get user fees before claiming
    (uint256 _userFeeIndex0BeforeClaiming, uint256 _userFeeIndex1BeforeClaiming,,) =
      vaultShareToken.userFees(_user);

    // Verify that userFees are not synced to latest global indices
    assertEq(_userFeeIndex0BeforeClaiming, 0);
    assertEq(_userFeeIndex1BeforeClaiming, 0);

    // User claims fees
    vaultShareToken.claim(_user, address(token0), address(token1));

    // Verify user fees are synced to latest global indices
    (uint256 _userFeeIndex0AfterClaiming, uint256 _userFeeIndex1AfterClaiming,,) =
      vaultShareToken.userFees(_user);
    assertEq(_userFeeIndex0AfterClaiming, vaultShareToken.globalFeeIndex0Scaled());
    assertEq(_userFeeIndex1AfterClaiming, vaultShareToken.globalFeeIndex1Scaled());
  }

  function testFuzz_ResetsAccruedFeesAfterClaiming(
    address _user,
    uint256 _mintAmount,
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1
  ) public {
    _assumeSafeAddress(_user);
    _mintAmount = _boundMintAmount(_mintAmount);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundFeeAmount(_collectedFeeToken1);

    // Mint and send fees for token0 and token1 into the vault
    token0.mint(address(vaultShareToken), _collectedFeeToken0);
    token1.mint(address(vaultShareToken), _collectedFeeToken1);

    // User mints shares
    vaultShareToken.exposed_mint(_user, _mintAmount);

    // Fees collected (global indices increase)
    vaultShareToken.exposed_updateFees(_collectedFeeToken0, _collectedFeeToken1);

    // Sync user fees to latest global indices
    vaultShareToken.exposed_updateUserFees(_user);

    // User claims fees
    vaultShareToken.claim(_user, address(token0), address(token1));

    // Verify accrued fees are reset to 0
    (,, uint256 _accruedToken0After, uint256 _accruedToken1After) = vaultShareToken.userFees(_user);
    assertEq(_accruedToken0After, 0);
    assertEq(_accruedToken1After, 0);
  }

  function test_RevertIf_NativeEthTransferFails(uint256 _mintAmount, uint256 _collectedFeeToken0)
    public
  {
    _mintAmount = _boundMintAmount(_mintAmount);
    _collectedFeeToken0 = _boundFeeAmount(_collectedFeeToken0);
    // Ensure we have some accrued fees to claim
    vm.assume(_collectedFeeToken0 > 0 && _mintAmount > 0);

    // Deploy a contract that rejects ETH transfers
    NonPayableContract _nonPayableContract = new NonPayableContract();

    // Mint and send native ETH fees to the vault
    vm.deal(address(vaultShareToken), _collectedFeeToken0);

    // User (non-payable contract) mints shares
    vaultShareToken.exposed_mint(address(_nonPayableContract), _mintAmount);

    // Fees collected (global indices increase)
    vaultShareToken.exposed_updateFees(_collectedFeeToken0, 0);

    // Sync user fees to latest global indices
    vaultShareToken.exposed_updateUserFees(address(_nonPayableContract));

    // Get accrued amount before claiming
    (,, uint256 _accruedToken0BeforeClaiming,) =
      vaultShareToken.userFees(address(_nonPayableContract));
    // Ensure there are accrued fees to claim
    vm.assume(_accruedToken0BeforeClaiming > 0);

    // Attempt to claim should revert with VaultShareToken_TransferFailed
    vm.expectRevert(VaultShareToken.VaultShareToken_TransferFailed.selector);
    vaultShareToken.claim(address(_nonPayableContract), address(0), address(token1));
  }
}
