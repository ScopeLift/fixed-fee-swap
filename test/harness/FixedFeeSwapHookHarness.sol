// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// External imports
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

// Internal imports
import {FixedFeeSwapHook} from "src/FixedFeeSwapHook.sol";
import {VaultShareToken} from "src/VaultShareToken.sol";
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

/// @notice Test harness for FixedFeeSwapHook.
contract FixedFeeSwapHookHarness is FixedFeeSwapHook {
  constructor(IPoolManager _manager, VaultShareToken _vaultShareToken, uint256 _maturity)
    FixedFeeSwapHook(_manager, _vaultShareToken, _maturity)
  {}

  function validateHookAddress(BaseHook) internal pure override {}

  /// @notice Exposed function to update fees for testing.
  /// @param fee0 The amount of token0 fees collected.
  /// @param fee1 The amount of token1 fees collected.
  function exposed_updateFees(uint256 fee0, uint256 fee1) external {
    _updateFees(fee0, fee1);
  }
}

