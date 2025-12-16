// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// External Imports
import {Test} from "forge-std/Test.sol";

// Internal Imports
import {YieldToken} from "src/YieldToken.sol";

contract YieldTokenTest is Test {
  YieldToken internal yieldToken;
  address internal hook;
  address internal feeToken0;
  address internal feeToken1;

  function setUp() public virtual {
    hook = makeAddr("hook");
    feeToken0 = makeAddr("feeToken0");
    feeToken1 = makeAddr("feeToken1");
    yieldToken = new YieldToken("Yield Token", "YT", hook, feeToken0, feeToken1);
  }

  function _assumeSafeAddress(address _addr) internal pure {
    vm.assume(_addr != address(0));
  }

  function _boundToRealisticAmount(uint256 _amount) internal pure returns (uint256) {
    return bound(_amount, 1, type(uint128).max);
  }
}

contract Constructor is YieldTokenTest {
  function test_SetsInitialParameters() public view {
    assertEq(yieldToken.name(), "Yield Token");
    assertEq(yieldToken.symbol(), "YT");
    assertEq(yieldToken.decimals(), 18);

    // fixedFeeSwapHook is set to deployer
    assertEq(yieldToken.FIXED_FEE_SWAP_HOOK(), hook);
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
}
