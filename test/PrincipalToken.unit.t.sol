// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// External Imports
import {Test} from "forge-std/Test.sol";

// Internal Imports
import {PrincipalToken} from "src/PrincipalToken.sol";

contract PrincipalTokenTest is Test {
  PrincipalToken internal principalToken;
  address internal hook;

  function setUp() public virtual {
    hook = makeAddr("hook");
    principalToken = new PrincipalToken("Principal Token", "PT", hook);
  }

  function _assumeSafeAddress(address _addr) internal pure {
    vm.assume(_addr != address(0));
  }

  function _boundToRealisticAmount(uint256 _amount) internal pure returns (uint256) {
    return bound(_amount, 1, type(uint128).max);
  }
}

contract Constructor is PrincipalTokenTest {
  function test_SetsInitialParameters() public view {
    assertEq(principalToken.name(), "Principal Token");
    assertEq(principalToken.symbol(), "PT");
    assertEq(principalToken.decimals(), 18);

    // fixedFeeSwapHook is set to deployer
    assertEq(principalToken.FIXED_FEE_SWAP_HOOK(), hook);
  }
}

contract Mint is PrincipalTokenTest {
  function testFuzz_MintSucceedsWhenCalledByHook(address _to, uint256 _amount) public {
    _assumeSafeAddress(_to);
    _amount = _boundToRealisticAmount(_amount);

    vm.prank(hook);
    principalToken.mint(_to, _amount);

    assertEq(principalToken.totalSupply(), _amount);
    assertEq(principalToken.balanceOf(_to), _amount);
  }

  function testFuzz_RevertIf_MintCalledByNonHook(address _to, uint256 _amount, address _nonHook)
    public
  {
    vm.assume(_nonHook != hook);

    vm.prank(_nonHook);
    vm.expectRevert(PrincipalToken.PrincipalToken_NotAuthorized.selector);
    principalToken.mint(_to, _amount);
  }
}

contract Burn is PrincipalTokenTest {
  function testFuzz_BurnSucceedsWhenCalledByHook(address _user, uint256 _amount) public {
    _assumeSafeAddress(_user);
    _amount = _boundToRealisticAmount(_amount);

    // Mint some tokens to the user
    vm.prank(hook);
    principalToken.mint(_user, _amount);
    assertEq(principalToken.balanceOf(_user), _amount);

    // Burn some tokens from the user
    vm.prank(hook);
    principalToken.burn(_user, _amount);

    assertEq(principalToken.balanceOf(_user), 0);
    assertEq(principalToken.totalSupply(), 0);
  }

  function testFuzz_RevertIf_BurnCalledByNonHook(address _user, uint256 _amount, address _nonHook)
    public
  {
    _assumeSafeAddress(_user);
    _amount = _boundToRealisticAmount(_amount);
    vm.assume(_nonHook != hook);

    // Mint some tokens to the user
    vm.prank(hook);
    principalToken.mint(_user, _amount);

    vm.expectRevert(PrincipalToken.PrincipalToken_NotAuthorized.selector);
    vm.prank(_nonHook);
    principalToken.burn(_user, _amount);
  }
}
