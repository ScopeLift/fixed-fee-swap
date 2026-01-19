// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Internal imports
import {FixedFeeSwapHook} from "src/FixedFeeSwapHook.sol";
import {VaultShareToken} from "src/VaultShareToken.sol";

/// @notice Test harness for FixedFeeSwapHook.
contract FixedFeeSwapHookHarness is FixedFeeSwapHook {
  constructor(VaultShareToken _vaultShareToken, uint256 _maturity)
    FixedFeeSwapHook(_vaultShareToken, _maturity)
  {}
}
