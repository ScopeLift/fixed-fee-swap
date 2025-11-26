// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {Deploy} from "script/Deploy.s.sol";
import {Counter} from "src/Counter.sol";

contract CounterTest is Test, Deploy {
  function setUp() public {
    Deploy.run();
  }
}

contract Increment is CounterTest {
  function test_NumberIsIncremented() public {
    counter.increment();
    assertEq(counter.number(), 1);
  }
}

contract SetNumber is CounterTest {
  function testFuzz_NumberIsSet(uint256 _x) public {
    counter.setNumber(_x);
    assertEq(counter.number(), _x);
  }
}
