// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title NonPayableContractMock
/// @notice A mock contract that rejects ETH transfers for testing purposes.
/// @dev Intentionally has no receive() or fallback() payable functions to test
///      scenarios where native ETH transfers fail.
contract NonPayableContractMock {
  // Intentionally no receive() or fallback() payable functions

  }

