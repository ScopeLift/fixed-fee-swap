// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Internal Imports
import {PrincipalToken} from "src/PrincipalToken.sol";
import {YieldToken} from "src/YieldToken.sol";
import {VaultShareToken} from "src/VaultShareToken.sol";
import {FixedFeeSwap} from "src/FixedFeeSwap.sol";
import {FixedFeeSwapMarket} from "src/FixedFeeSwapMarket.sol";

// External Imports
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Sells or buys YT in one call, using a PT flash loan and FixedFeeSwapMarket.
/// @dev The market only swaps an exact input and offers no quote, so the caller sizes each zap's
/// swap. To size one, simulate it off-chain against the current market state and pass the result
/// along with a minimum output and a deadline. The market pulls the swap's input from its caller,
/// so simulate the swap with `eth_call` from this contract's address with state overrides that
/// give it the input and the allowance, or search with `eth_call` over the zap itself. The zap
/// reverts if the market has moved so that the sized swap can no longer repay the flash loan, or if
/// the output falls below the minimum.
contract Zapper is IERC3156FlashBorrower {
  using SafeERC20 for IERC20;

  /*//////////////////////////////////////////////////////////////
                        ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when address is invalid.
  error Zapper_InvalidAddress();

  /// @notice Thrown when amount is invalid.
  error Zapper_InvalidAmount();

  /// @notice Thrown when flash loan callback is called with invalid initiator.
  error Zapper_InvalidInitiator();

  /// @notice Thrown when flash loan callback is called with invalid token.
  error Zapper_InvalidFlashLoanToken();

  /// @notice Thrown when flash loan callback is called with invalid caller.
  error Zapper_NotAuthorized();

  /// @notice Thrown when YT is sold or bought at or after maturity, when the market no longer
  /// trades.
  error Zapper_AfterMaturity();

  /// @notice Thrown when forwarding native ETH fees to the seller fails.
  error Zapper_TransferFailed();

  /// @notice Thrown when a zap runs after its deadline.
  error Zapper_DeadlineExpired();

  /// @notice Thrown when a zap ends its flash loan holding less PT than it must repay.
  /// @param principalAvailable The PT the zap has for repayment: the PT a sale's buyback returned,
  /// or the PT a purchase holds after its split.
  /// @param principalOwed The PT owed to the flash loan.
  error Zapper_InsufficientPrincipalToRepay(uint256 principalAvailable, uint256 principalOwed);

  /// @notice Thrown when a zap's output is below the caller's minimum.
  /// @param amountOut The VST a sell or the YT a buy would pay out.
  /// @param minAmountOut The caller's minimum.
  error Zapper_InsufficientOutput(uint256 amountOut, uint256 minAmountOut);

  /*//////////////////////////////////////////////////////////////
                        EVENTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Emitted when yield token is sold.
  /// @param user The address that sold the yield token.
  /// @param ytAmount The amount of yield token sold.
  /// @param vaultSharesReceived The amount of vault shares received.
  event YieldTokenSold(address indexed user, uint256 ytAmount, uint256 vaultSharesReceived);

  /// @notice Emitted when yield token is bought.
  /// @param user The address that bought the yield token.
  /// @param ytBought The amount of yield token bought.
  /// @param vstSupplied The amount of VST supplied.
  event YieldTokenBought(address indexed user, uint256 ytBought, uint256 vstSupplied);

  /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice Magic return value for flash loan callback.
  bytes32 private constant FLASH_LOAN_RETURN_VALUE = keccak256("ERC3156FlashBorrower.onFlashLoan");

  /// @notice The yield token address.
  YieldToken public immutable YIELD_TOKEN;

  /// @notice The principal token address.
  PrincipalToken public immutable PRINCIPAL_TOKEN;

  /// @notice The vault share token address.
  VaultShareToken public immutable VAULT_SHARE_TOKEN;

  /// @notice The fixed fee swap hook address.
  FixedFeeSwap public immutable FIXED_FEE_SWAP;

  /// @notice The fixed fee swap market address.
  FixedFeeSwapMarket public immutable FIXED_FEE_SWAP_MARKET;

  /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /// @notice Initializes the zapper.
  /// @param _fixedFeeSwap The fixed fee swap address.
  /// @param _fixedFeeSwapMarket The fixed fee swap market address.
  constructor(FixedFeeSwap _fixedFeeSwap, FixedFeeSwapMarket _fixedFeeSwapMarket) {
    if (address(_fixedFeeSwap) == address(0) || address(_fixedFeeSwapMarket) == address(0)) {
      revert Zapper_InvalidAddress();
    }

    FIXED_FEE_SWAP = _fixedFeeSwap;
    FIXED_FEE_SWAP_MARKET = _fixedFeeSwapMarket;
    YIELD_TOKEN = _fixedFeeSwap.YIELD_TOKEN();
    PRINCIPAL_TOKEN = _fixedFeeSwap.PRINCIPAL_TOKEN();
    VAULT_SHARE_TOKEN = _fixedFeeSwap.VAULT_SHARE_TOKEN();
  }

  /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Sells YT tokens for VST.
  /// @param _ytAmount The amount of YT tokens to sell.
  /// @param _vstForBuyback The VST to swap for PT to repay the flash loan of `_ytAmount` PT. Size
  /// it by simulating `FIXED_FEE_SWAP_MARKET.swap(_vstForBuyback, false, 0)`: the smallest amount
  /// whose PT out is at least `_ytAmount` gets the seller the most VST. At most `_ytAmount`, the
  /// VST that redeeming the PT and YT gives. If even `_ytAmount` VST can't buy back `_ytAmount` PT,
  /// as when the market fills only whole ticks and a small sale's buyback needs one more, the sale
  /// can't be done. The PT price rises toward par every second, so a buyback sized exactly in one
  /// block can fall a tick short in a later one. Add a small margin, which the market can keep, as
  /// the seller's slippage tolerance.
  /// @param _minVstOut The least VST the seller accepts. The VST left is `_ytAmount` less the VST
  /// the swap takes, so this bounds the swap's input. It doesn't bound the PT the swap returns
  /// beyond the loan, which a price move can shrink, so size `_vstForBuyback` tightly.
  /// @param _deadline The last timestamp at which the sale can run.
  /// @dev
  ///  - Flash-borrows `_ytAmount` PT, redeems it with the seller's YT for `_ytAmount` VST, and
  ///    swaps `_vstForBuyback` of that VST for PT to repay the loan.
  ///  - Pays the seller the VST left over and any PT the swap returned beyond the loan.
  ///  - Reverts if the swap returns less PT than the loan, if the VST left is below `_minVstOut`,
  ///    after `_deadline`, or at or after maturity.
  ///  - Also pays the seller every fee their YT has earned, including on YT they keep, when that
  ///    payout succeeds. If it can't, for example because the seller can't receive native ETH,
  ///    the sale still goes ahead and the fees stay credited to the seller.
  ///  - Forwards to the seller any fee tokens this contract holds afterwards, such as fees earned
  ///    by YT someone sent here directly, which the redeem pays to this contract.
  function sellYieldToken(
    uint256 _ytAmount,
    uint256 _vstForBuyback,
    uint256 _minVstOut,
    uint256 _deadline
  ) external {
    // A deadline needs only second precision, which validators can't skew by much.
    // forge-lint: disable-next-line(block-timestamp)
    if (block.timestamp > _deadline) revert Zapper_DeadlineExpired();
    if (_ytAmount == 0 || _vstForBuyback == 0 || _vstForBuyback > _ytAmount) {
      revert Zapper_InvalidAmount();
    }
    if (block.timestamp >= FIXED_FEE_SWAP.MATURITY()) revert Zapper_AfterMaturity();

    // 1. Pay the seller the fees their YT has earned, as a convenience: the YT transfer below
    //    credits them to the seller anyway. A failed payout leaves them credited, and a missing
    //    approval reverts in the transfer below with the token's own error.
    try FIXED_FEE_SWAP.claimYTFees(msg.sender) {} catch {}
    YIELD_TOKEN.transferFrom(msg.sender, address(this), _ytAmount);

    // 2. Request flash loan of PT equal to YT amount
    PRINCIPAL_TOKEN.flashLoan(
      IERC3156FlashBorrower(address(this)),
      address(PRINCIPAL_TOKEN),
      _ytAmount,
      abi.encode(false, _vstForBuyback)
    );

    // 3. After repaying flash loan (via `onFlashLoan`), transfer remaining tokens to user
    uint256 _vstReceived = VAULT_SHARE_TOKEN.balanceOf(address(this));
    if (_vstReceived < _minVstOut) revert Zapper_InsufficientOutput(_vstReceived, _minVstOut);
    VAULT_SHARE_TOKEN.transfer(msg.sender, _vstReceived);

    // Transfer any PT the buyback returned beyond the loan to the user
    uint256 _ptRemaining = PRINCIPAL_TOKEN.balanceOf(address(this));
    if (_ptRemaining > 0) IERC20(address(PRINCIPAL_TOKEN)).transfer(msg.sender, _ptRemaining);

    _forwardFeeTokens(msg.sender);

    emit YieldTokenSold(msg.sender, _ytAmount, _vstReceived);
  }

  /// @notice Accepts native ETH fees that FixedFeeSwap pays this contract when its YT is burned.
  /// @dev Without it, one wei of ETH fees owed to this contract would make every sale revert.
  receive() external payable {}

  /// @notice Buys YT by supplying VST.
  /// @param _vstAmount The amount of VST to supply.
  /// @param _ptLoan The PT to flash-borrow and sell for VST. Size it by simulating
  /// `FIXED_FEE_SWAP_MARKET.swap(_ptLoan, true, 0)`: the VST out plus `_vstAmount`, plus any PT the
  /// market doesn't take, must be at least `_ptLoan`. The buyer gets `_vstAmount` plus that VST out
  /// in YT.
  /// @param _minYtOut The least YT the buyer accepts. It doesn't bound the PT refunded after
  /// repaying, which a price move can shrink when the market takes more of the loan than simulated.
  /// @param _deadline The last timestamp at which the purchase can run.
  /// @dev
  ///  - Flash-borrows `_ptLoan` PT, sells it for VST, and splits that VST and the buyer's into PT
  ///    and YT, repaying the loan from the PT. The market can take less than all the PT.
  ///  - Pays the buyer the YT and any PT left after repaying the loan. The split uses all the VST,
  ///    so none is left over.
  ///  - Reverts if the split leaves less PT than the loan, if the YT is below `_minYtOut`, after
  ///    `_deadline`, or at or after maturity.
  function buyYieldToken(uint256 _vstAmount, uint256 _ptLoan, uint256 _minYtOut, uint256 _deadline)
    external
  {
    // A deadline needs only second precision, which validators can't skew by much.
    // forge-lint: disable-next-line(block-timestamp)
    if (block.timestamp > _deadline) revert Zapper_DeadlineExpired();
    if (_vstAmount == 0 || _ptLoan == 0) revert Zapper_InvalidAmount();
    if (block.timestamp >= FIXED_FEE_SWAP.MATURITY()) revert Zapper_AfterMaturity();

    // 1. User sends VST to zapper
    VAULT_SHARE_TOKEN.transferFrom(msg.sender, address(this), _vstAmount);

    // 2. Flash loan PT
    PRINCIPAL_TOKEN.flashLoan(
      IERC3156FlashBorrower(address(this)),
      address(PRINCIPAL_TOKEN),
      _ptLoan,
      abi.encode(true, 0) // A buy needs no buyback amount
    );

    // 3. After flash loan callback, send all YT to user
    uint256 _ytBought = YIELD_TOKEN.balanceOf(address(this));
    if (_ytBought < _minYtOut) revert Zapper_InsufficientOutput(_ytBought, _minYtOut);
    YIELD_TOKEN.transfer(msg.sender, _ytBought);

    // Transfer any PT left after repaying the loan to the user
    uint256 _ptRemaining = PRINCIPAL_TOKEN.balanceOf(address(this));
    if (_ptRemaining > 0) IERC20(address(PRINCIPAL_TOKEN)).transfer(msg.sender, _ptRemaining);

    emit YieldTokenBought(msg.sender, _ytBought, _vstAmount);
  }

  /// @notice Flash loan callback implementation.
  /// @param _initiator The address that initiated the flash loan.
  /// @param _token The token being flash loaned.
  /// @param _amount The amount of tokens flash loaned.
  /// @param _data `abi.encode(bool isBuy, uint256 vstForBuyback)`; a buy ignores
  /// `vstForBuyback`.
  /// @return FLASH_LOAN_RETURN_VALUE The magic return value.
  function onFlashLoan(
    address _initiator,
    address _token,
    uint256 _amount,
    uint256, // _fee
    bytes calldata _data
  ) external returns (bytes32) {
    // Verify this contract initiated the flash loan
    if (_initiator != address(this)) revert Zapper_InvalidInitiator();

    // Verify the token is PT
    if (_token != address(PRINCIPAL_TOKEN)) revert Zapper_InvalidFlashLoanToken();

    // Verify the caller is the PT token contract
    if (msg.sender != address(PRINCIPAL_TOKEN)) revert Zapper_NotAuthorized();

    (bool _isBuy, uint256 _vstForBuyback) = abi.decode(_data, (bool, uint256));

    if (_isBuy) _handleBuyFlashLoan(_amount);
    else _handleSellFlashLoan(_amount, _vstForBuyback);

    return FLASH_LOAN_RETURN_VALUE;
  }

  /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Handles flash loan callback for selling YT.
  /// @param _amount The amount of PT flash loaned.
  /// @param _vstForBuyback The VST to swap for PT to repay the loan.
  function _handleSellFlashLoan(uint256 _amount, uint256 _vstForBuyback) internal {
    // Approve hook to spend PT and YT
    IERC20(address(PRINCIPAL_TOKEN)).approve(address(FIXED_FEE_SWAP), _amount);
    IERC20(address(YIELD_TOKEN)).approve(address(FIXED_FEE_SWAP), _amount);

    // Burn PT and YT to mint VST
    FIXED_FEE_SWAP.redeem(_amount);

    // Buy back the loaned PT with the VST the caller sized off-chain
    uint256 _swappedPT = _swapVSTForPT(_vstForBuyback);
    if (_swappedPT < _amount) revert Zapper_InsufficientPrincipalToRepay(_swappedPT, _amount);

    // Approve PT contract to spend PT to repay flash loan; any PT beyond it goes to the seller
    IERC20(address(PRINCIPAL_TOKEN)).approve(address(PRINCIPAL_TOKEN), _amount);
  }

  /// @notice Handles flash loan callback for buying YT.
  /// @dev Sells the loan for VST and splits all the VST; any PT the market doesn't take stays and
  /// counts toward repayment.
  /// @param _amount The amount of PT to repay (flash loan amount).
  function _handleBuyFlashLoan(uint256 _amount) internal {
    // Swap PT for VST (cash) using the market
    // principalForCash = true means: PT in → cash out
    IERC20(address(PRINCIPAL_TOKEN)).approve(address(FIXED_FEE_SWAP_MARKET), _amount);
    FIXED_FEE_SWAP_MARKET.swap(
      _amount, // amountIn (PT)
      true, // principalForCash = true (we're swapping principal FOR cash)
      0 // no price limit
    );

    // Combine swapped VST with user's existing VST
    uint256 _totalVst = VAULT_SHARE_TOKEN.balanceOf(address(this));

    // Split all VST into PT + YT
    IERC20(address(VAULT_SHARE_TOKEN)).approve(address(FIXED_FEE_SWAP), _totalVst);
    FIXED_FEE_SWAP.deposit(_totalVst);

    uint256 _ptBalance = PRINCIPAL_TOKEN.balanceOf(address(this));
    if (_ptBalance < _amount) revert Zapper_InsufficientPrincipalToRepay(_ptBalance, _amount);

    // Approve PT contract to spend PT to repay flash loan
    IERC20(address(PRINCIPAL_TOKEN)).approve(address(PRINCIPAL_TOKEN), _amount);

    // YT, and any PT beyond the loan, stay in contract and will be sent to user after callback
  }

  /// @notice Swaps VST (cash) for PT using the FixedFeeSwapMarket
  /// @param _vstForBuyback The caller-sized amount of VST to swap
  /// @return _swappedPT The amount of PT obtained from swapping VST
  function _swapVSTForPT(uint256 _vstForBuyback) internal returns (uint256 _swappedPT) {
    // Approve market to spend VST (cash token)
    IERC20(address(VAULT_SHARE_TOKEN)).approve(address(FIXED_FEE_SWAP_MARKET), _vstForBuyback);

    // Swap VST (cash) for PT (principal)
    // principalForCash = false means: cash in → PT out
    (, _swappedPT) = FIXED_FEE_SWAP_MARKET.swap(
      _vstForBuyback, // amountIn (VST)
      false, // principalForCash = false (we're swapping cash FOR principal)
      0 // no price limit
    );
  }

  /// @notice Sends this contract's whole balance of each fee token to `_to`.
  /// @param _to The recipient.
  /// @dev The Zapper never keeps fee tokens. It only receives them when burning YT whose fees were
  /// credited to it, such as YT sent here directly.
  function _forwardFeeTokens(address _to) internal {
    _forwardFeeToken(VAULT_SHARE_TOKEN.FEE_TOKEN0(), _to);
    _forwardFeeToken(VAULT_SHARE_TOKEN.FEE_TOKEN1(), _to);
  }

  /// @notice Sends this contract's whole balance of one fee token to `_to`.
  /// @param _token The fee token, or address(0) for native ETH.
  /// @param _to The recipient.
  function _forwardFeeToken(address _token, address _to) internal {
    if (_token == address(0)) {
      uint256 _balance = address(this).balance;
      if (_balance == 0) return;
      (bool _success,) = payable(_to).call{value: _balance}("");
      if (!_success) revert Zapper_TransferFailed();
    } else {
      uint256 _balance = IERC20(_token).balanceOf(address(this));
      if (_balance > 0) IERC20(_token).safeTransfer(_to, _balance);
    }
  }
}
