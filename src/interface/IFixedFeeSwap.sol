// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IFixedFeeSwap
/// @author [ScopeLift](https://scopelift.co)
/// @notice Minimal interface for FixedFeeSwap so the YieldToken can pull fees on claim.
interface IFixedFeeSwap {
  function collectFeesToYT() external;
}
