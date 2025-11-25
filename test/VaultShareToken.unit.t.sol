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

  // Assume safe values
  function _assumeSafeAddress(address _address) internal pure {
    vm.assume(_address != address(0));
  }

  function _assumeSafeAmount(uint256 _amount) internal pure {
    vm.assume(_amount > 0);
  }

  // Bound realistic values
  function _boundToRealisticAmount(uint256 _amount) internal returns (uint256) {
    return bound(_amount, 1, type(uint256).max / vaultShareToken.PRECISION());
  }

  // Utility functions
  function _calculateFeeIndex(uint256 _collectedFeeToken, uint256 _mintAmount) internal returns (uint256) {
    return Math.mulDiv(_collectedFeeToken, vaultShareToken.PRECISION(), _mintAmount);
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
    address _account
  ) public {
    _collectedFeeToken0 = _boundToRealisticAmount(_collectedFeeToken0);
    _collectedFeeToken1 = _boundToRealisticAmount(_collectedFeeToken1);
    _mintAmount = _boundToRealisticAmount(_mintAmount);
    _assumeSafeAddress(_account);

    vaultShareToken.mintShares(_account, _mintAmount);

    assertEq(vaultShareToken.feeIndexToken0(), 0);
    assertEq(vaultShareToken.feeIndexToken1(), 0);

    vaultShareToken.updateFees(_collectedFeeToken0, _collectedFeeToken1);

    assertEq(vaultShareToken.feeIndexToken0(), _calculateFeeIndex(_collectedFeeToken0, _mintAmount));
    assertEq(vaultShareToken.feeIndexToken1(), _calculateFeeIndex(_collectedFeeToken1, _mintAmount));
  }

  function testFuzz_FeeIndexTokensAreUpdatedOnMultipleCalls(
    uint256 _collectedFeeToken0AtT1,
    uint256 _collectedFeeToken1AtT1,
    uint256 _mintAmountAtT1,
    uint256 _collectedFeeToken0AtT2,
    uint256 _collectedFeeToken1AtT2,
    uint256 _mintAmountAtT2
  ) public {
    _assumeSafeAmount(_collectedFeeToken0AtT1);
    _assumeSafeAmount(_collectedFeeToken1AtT1);
    _assumeSafeAmount(_mintAmountAtT1);
    _assumeSafeAmount(_collectedFeeToken0AtT2);
    _assumeSafeAmount(_collectedFeeToken1AtT2);
    _assumeSafeAmount(_mintAmountAtT2);

    // TODO
  }

  function testFuzz_FeeIndexIsNotUpdatedWhenTokenFee0IsZero(
    uint256 _collectedFeeToken0,
    uint256 _mintAmount
  ) public {
    _assumeSafeAmount(_collectedFeeToken0);
    // TODO
  }

  function testFuzz_FeeIndexIsNotUpdatedWhenTokenFee1IsZero(
    uint256 _collectedFeeToken1,
    uint256 _mintAmount
  ) public {
    _assumeSafeAmount(_collectedFeeToken1);
    // TODO
  }

  function testFuzz_FeeIndexIsNotUpdatedWhenMintAmountIsZero(
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1
  ) public {
    assertEq(vaultShareToken.totalSupply(), 0);
    assertEq(vaultShareToken.feeIndexToken0(), 0);
    assertEq(vaultShareToken.feeIndexToken1(), 0);

    vaultShareToken.updateFees(_collectedFeeToken0, _collectedFeeToken1);

    assertEq(vaultShareToken.feeIndexToken0(), 0);
    assertEq(vaultShareToken.feeIndexToken1(), 0);
  }

  function testFuzz_EmitsFeeIndexesUpdatedEvent(
    uint256 _collectedFeeToken0,
    uint256 _collectedFeeToken1,
    uint256 _mintAmount
  ) public {
    _assumeSafeAmount(_collectedFeeToken0);
    _assumeSafeAmount(_collectedFeeToken1);
    // TODO
  }
}
