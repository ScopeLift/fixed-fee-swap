// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// External Imports
import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
    vm.assume(_amount > 0);
  }

  function _boundFeeAmount(uint256 _amount) internal view returns (uint256) {
    uint256 _maxFee = type(uint256).max / vaultShareToken.PRECISION();
    return bound(_amount, 0, _maxFee);
  }

  function _boundMintAmount(uint256 _amount) internal pure returns (uint256) {
    return bound(_amount, 1, type(uint256).max / 2);
  }

  function _calculateFeeIndex(uint256 _collectedFeeToken, uint256 _supply)
    internal
    view
    returns (uint256)
  {
    return Math.mulDiv(_collectedFeeToken, vaultShareToken.PRECISION(), _supply);
  }
}

contract Constructor is VaultShareTokenTest {
  function testFuzz_SetsInitialParameters(string memory _name, string memory _symbol) public {
    VaultShareToken _newVaultShareToken = new VaultShareToken(_name, _symbol);

    assertEq(_newVaultShareToken.name(), _name);
    assertEq(_newVaultShareToken.symbol(), _symbol);
  }
}

contract MintShares is VaultShareTokenTest {
  function testFuzz_MintsTokens(address _account, uint256 _amount) public {
    _assumeSafeAddress(_account);
    _assumeSafeAmount(_amount);

    assertEq(vaultShareToken.balanceOf(_account), 0);
    vaultShareToken.exposed_mintShares(_account, _amount);
    assertEq(vaultShareToken.balanceOf(_account), _amount);
  }
}

contract BurnShares is VaultShareTokenTest {
  function testFuzz_BurnsTokens(address _account, uint256 _mintAmount, uint256 _burnAmount) public {
    _assumeSafeAddress(_account);
    _assumeSafeAmount(_mintAmount);

    _burnAmount = bound(_burnAmount, 0, _mintAmount);

    vaultShareToken.exposed_mintShares(_account, _mintAmount);

    assertEq(vaultShareToken.balanceOf(_account), _mintAmount);
    vaultShareToken.exposed_burnShares(_account, _burnAmount);
    assertEq(vaultShareToken.balanceOf(_account), _mintAmount - _burnAmount);
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

    vaultShareToken.exposed_mintShares(_minterAccount, _mintAmount);

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
    _collectedFeeToken0AtT1 = bound(_collectedFeeToken0AtT1, 0, 20e18);
    _collectedFeeToken1AtT1 = bound(_collectedFeeToken1AtT1, 0, 20e18);
    _mintAmountAtT1 = bound(_mintAmountAtT1, 1, 20e18);

    _collectedFeeToken0AtT2 = bound(_collectedFeeToken0AtT2, 0, 20e18);
    _collectedFeeToken1AtT2 = bound(_collectedFeeToken1AtT2, 0, 20e18);
    _mintAmountAtT2 = bound(_mintAmountAtT2, 1, 20e18);

    _assumeSafeAddress(_minterAccountAtT1);
    _assumeSafeAddress(_minterAccountAtT2);

    vaultShareToken.exposed_mintShares(_minterAccountAtT1, _mintAmountAtT1);

    vaultShareToken.exposed_updateFees(_collectedFeeToken0AtT1, _collectedFeeToken1AtT1);

    uint256 _expectedFeeIndex0 = _calculateFeeIndex(_collectedFeeToken0AtT1, _mintAmountAtT1);
    uint256 _expectedFeeIndex1 = _calculateFeeIndex(_collectedFeeToken1AtT1, _mintAmountAtT1);

    assertEq(vaultShareToken.feeIndexToken0(), _expectedFeeIndex0);
    assertEq(vaultShareToken.feeIndexToken1(), _expectedFeeIndex1);

    vaultShareToken.exposed_mintShares(_minterAccountAtT2, _mintAmountAtT2);

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

    vaultShareToken.exposed_mintShares(_minterAccount, _mintAmount);

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

    vaultShareToken.exposed_mintShares(_minterAccount, _mintAmount);

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

    vaultShareToken.exposed_mintShares(_minterAccount, _mintAmount);

    uint256 _expectedFeeIndex0 = _calculateFeeIndex(_collectedFeeToken0, _mintAmount);
    uint256 _expectedFeeIndex1 = _calculateFeeIndex(_collectedFeeToken1, _mintAmount);

    vm.expectEmit();
    emit VaultShareToken.FeeIndexesUpdated(
      _expectedFeeIndex0, _expectedFeeIndex1, _collectedFeeToken0, _collectedFeeToken1
    );
    vaultShareToken.exposed_updateFees(_collectedFeeToken0, _collectedFeeToken1);
  }
}
