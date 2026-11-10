// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// External imports
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

// Internal imports
import {PrincipalToken} from "src/PrincipalToken.sol";
import {YieldToken} from "src/YieldToken.sol";
import {VaultShareToken} from "src/VaultShareToken.sol";
import {FeeTracking} from "src/lib/FeeTracking.sol";

/// @notice Splits VaultShareTokens into PrincipalTokens and YieldTokens until a maturity date.
/// @dev
///  - The VST this contract holds keeps earning vault fees. Fees earned before `MATURITY` go to YT
///    holders, and fees earned after it go to PT holders.
///  - VST sent here directly, rather than split through `deposit`, backs no PT or YT. Neither it
/// nor the fees it earns is paid to anyone, and both stay in the contract.
///  - The vault's fee index only moves when the vault records new fees, so the contract settles
///    the switch once, at the first action at or after `MATURITY` (or a call to `settle`). It
///    records the vault fee index at `MATURITY`, interpolating by time when the first reading
///    after maturity covers time on both sides of it.
///  - YT holders earn vault fees up to that index and can claim them after maturity whatever anyone
///    else has done. PT holders earn every fee after it, paid per PT when they redeem, and need no
///    YT to redeem after maturity.
///  - The split by time assumes fees accrued evenly between the last checkpoint and settlement.
///    Anyone can shrink that window by calling `collectFeesToYT` shortly before maturity and
///    `settle` shortly after it.
contract FixedFeeSwap {
  using SafeERC20 for IERC20;

  /// @notice The last vault fee indexes credited to YT holders, and when they were read.
  /// @dev `timestamp` is `MATURITY` once the contract has settled.
  struct VstFeeCheckpoint {
    uint256 feeIndex0LastScaled;
    uint256 feeIndex1LastScaled;
    uint256 timestamp;
  }

  /*//////////////////////////////////////////////////////////////
                        ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when split is attempted after maturity is reached.
  error FixedFeeSwap_SplitAfterMaturity();

  /// @notice Thrown when deposit is attempted with an invalid amount.
  error FixedFeeSwap_InvalidAmount();

  /// @notice Thrown when the maturity is in the past.
  error FixedFeeSwap_InvalidMaturity();

  /// @notice Thrown when the vault share token is zero.
  error FixedFeeSwap_InvalidVaultShareToken();

  /// @notice Thrown when action is attempted with an insufficient balance.
  error FixedFeeSwap_InsufficientBalance();

  /// @notice Thrown when an action is attempted before maturity is reached.
  error FixedFeeSwap_BeforeMaturity();

  /// @notice Thrown when a transfer fails.
  error FixedFeeSwap_TransferFailed();

  /// @notice Thrown when the caller is not authorized.
  error FixedFeeSwap_NotAuthorized();

  /// @notice Thrown when reading a maturity index before the contract has settled.
  error FixedFeeSwap_NotSettled();

  /*//////////////////////////////////////////////////////////////
                        EVENTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Emitted when the hook is initialized.
  /// @param vaultShareToken The address of the vault share token.
  /// @param principalToken The address of the principal token.
  /// @param yieldToken The address of the yield token.
  /// @param maturity The maturity of the hook.
  event Initialized(
    address vaultShareToken, address principalToken, address yieldToken, uint256 maturity
  );

  /// @notice Emitted when a user deposits their vault share token into principal and yield tokens.
  /// @param user The address of the user who deposited.
  /// @param amount The amount of vault share token deposited.
  event Deposit(address indexed user, uint256 amount);

  /// @notice Emitted when a user redeems their principal and yield tokens back into the vault share
  /// token.
  /// @param user The address of the user who redeemed.
  /// @param vstAmount The amount of vault share token redeemed.
  /// @param maturityReached Whether the maturity has been reached.
  event Redeem(address indexed user, uint256 vstAmount, bool maturityReached);

  /// @notice Emitted when a PT holder is paid the fees earned after maturity on redeem.
  /// @param user The address of the user who claimed fees.
  /// @param token0 The address of the token0 to claim fees for.
  /// @param token1 The address of the token1 to claim fees for.
  /// @param token0Amount Amount of token0 fees claimed.
  /// @param token1Amount Amount of token1 fees claimed.
  event FeesClaimed(
    address indexed user,
    address indexed token0,
    address indexed token1,
    uint256 token0Amount,
    uint256 token1Amount
  );

  /// @notice Emitted once, when the contract settles the switch from YT fees to PT fees.
  /// @param maturityFeeIndex0Scaled The vault's token0 fee index at maturity.
  /// @param maturityFeeIndex1Scaled The vault's token1 fee index at maturity.
  event Settled(uint256 maturityFeeIndex0Scaled, uint256 maturityFeeIndex1Scaled);

  /*//////////////////////////////////////////////////////////////
                        STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice Native ETH address following Uniswap v4 `Currency` convention.
  /// @dev See: https://github.com/Uniswap/v4-core/blob/main/src/types/Currency.sol#L37-L38
  address private constant NATIVE = address(0);

  /// @notice The vault share token.
  VaultShareToken public immutable VAULT_SHARE_TOKEN;

  /// @notice The principal token.
  PrincipalToken public immutable PRINCIPAL_TOKEN;

  /// @notice The yield token.
  YieldToken public immutable YIELD_TOKEN;

  /// @notice The maturity after which yield token will be 0. (principal token will be equal to
  /// vault share token)
  uint256 public immutable MATURITY;

  /// @notice The token the vault pays token0 fees in, cached from the vault share token.
  address public immutable FEE_TOKEN0;

  /// @notice The token the vault pays token1 fees in, cached from the vault share token.
  address public immutable FEE_TOKEN1;

  /// @notice The last vault fee indexes credited to YT holders, and when they were read.
  VstFeeCheckpoint public vstFeeCheckpoint;

  /// @notice Token0 fees credited to YT holders and not yet paid to them.
  /// @dev Held back from PT redeemers, so PT can't be paid fees that YT holders earned.
  uint256 public yieldTokenFeesOwed0;

  /// @notice Token1 fees credited to YT holders and not yet paid to them.
  /// @dev Held back from PT redeemers, so PT can't be paid fees that YT holders earned.
  uint256 public yieldTokenFeesOwed1;

  /*//////////////////////////////////////////////////////////////
                        CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /// @notice Initializes the hook and deploys the principal and yield tokens.
  /// @param _vaultShareToken The vault share token.
  /// @param _maturity The maturity of the hook.
  constructor(VaultShareToken _vaultShareToken, uint256 _maturity) {
    if (address(_vaultShareToken) == address(0)) revert FixedFeeSwap_InvalidVaultShareToken();
    if (_maturity <= block.timestamp) revert FixedFeeSwap_InvalidMaturity();

    VAULT_SHARE_TOKEN = _vaultShareToken;

    string memory _underlyingName = VAULT_SHARE_TOKEN.name();
    string memory _underlyingSymbol = VAULT_SHARE_TOKEN.symbol();
    string memory _maturityStr = Strings.toString(_maturity);

    PRINCIPAL_TOKEN = new PrincipalToken(
      string.concat("Principal ", _underlyingName),
      string.concat("PT-", _underlyingSymbol, "-", _maturityStr),
      address(this)
    );
    FEE_TOKEN0 = _vaultShareToken.FEE_TOKEN0();
    FEE_TOKEN1 = _vaultShareToken.FEE_TOKEN1();
    YIELD_TOKEN = new YieldToken(
      string.concat("Yield ", _underlyingName),
      string.concat("YT-", _underlyingSymbol, "-", _maturityStr),
      address(this),
      FEE_TOKEN0,
      FEE_TOKEN1
    );

    MATURITY = _maturity;

    // Starts the checkpoint at the vault's current indexes, brought up to date first, so fees the
    // vault earned before this contract existed are never credited to YT, and settlement has a
    // start time to interpolate from.
    _vaultShareToken.syncFees();
    vstFeeCheckpoint = VstFeeCheckpoint(
      _vaultShareToken.globalFeeIndex0Scaled(),
      _vaultShareToken.globalFeeIndex1Scaled(),
      block.timestamp
    );

    emit Initialized(
      address(_vaultShareToken), address(PRINCIPAL_TOKEN), address(YIELD_TOKEN), _maturity
    );
  }

  /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Deposits the vault share token into principal and yield tokens.
  /// @param _amount The amount of vault share token to deposit.
  /// @dev The caller must have approved the hook to spend the vault share token.
  /// @dev When we split VST, we split it into equal amounts of YT + PT (1:1 ratio).
  function deposit(uint256 _amount) external {
    if (block.timestamp >= MATURITY) revert FixedFeeSwap_SplitAfterMaturity();

    // Credit YT holders with all yield earned so far, before the new YT shares in it.
    _syncFees();

    if (_amount == 0) revert FixedFeeSwap_InvalidAmount();

    if (VAULT_SHARE_TOKEN.balanceOf(msg.sender) < _amount) {
      revert FixedFeeSwap_InsufficientBalance();
    }

    // Transfer VaultShareToken from caller to the hook
    VAULT_SHARE_TOKEN.transferFrom(msg.sender, address(this), _amount);

    // When we split VST, we split it into equal amounts of YT + PT (1:1 ratio)
    // Mint PrincipalToken to the caller
    PRINCIPAL_TOKEN.mint(msg.sender, _amount);

    // Mint YieldToken to the caller
    YIELD_TOKEN.mint(msg.sender, _amount);

    emit Deposit(msg.sender, _amount);
  }

  /// @notice Redeems the principal and yield tokens back into the vault share token.
  /// @param _amount The amount of principal and yield tokens to redeem.
  /// @return _vstAmount The amount of vault share token redeemed.
  /// @dev
  ///  - Before maturity, the caller must have at least `_amount` PT and YT. Both are burned, and
  ///    the caller is paid the fees their YT earned.
  ///  - At or after maturity, the caller needs only `_amount` PT. It is burned, and the caller is
  ///    paid the fees the vault earned on `_amount` VST since maturity. Any YT the caller holds is
  ///    left alone and can still be claimed through `claimYTFeesAfterMaturity`.
  function redeem(uint256 _amount) external returns (uint256 _vstAmount) {
    if (_amount == 0) revert FixedFeeSwap_InvalidAmount();

    // Caller should always have enough PT tokens
    if (PRINCIPAL_TOKEN.balanceOf(msg.sender) < _amount) {
      revert FixedFeeSwap_InsufficientBalance();
    }

    bool _maturityReached = block.timestamp >= MATURITY;

    if (_maturityReached) {
      // Settles first if nobody has yet, so the fees paid here start at the maturity index.
      (uint256 _feeIndex0Now, uint256 _feeIndex1Now) = _syncFees();
      // Burns the PT before paying, so the payout can't be re-entered with the same PT.
      PRINCIPAL_TOKEN.burn(msg.sender, _amount);
      _payFeesEarnedAfterMaturity(msg.sender, _amount, _feeIndex0Now, _feeIndex1Now);
    } else {
      // Burning YT claims its fees, which syncs fees through `collectFeesToYT`.
      _claimAndBurnYieldTokens(msg.sender, _amount);
      PRINCIPAL_TOKEN.burn(msg.sender, _amount);
    }

    // Transfer VaultShareToken from the hook to the caller
    _vstAmount = _amount;
    if (VAULT_SHARE_TOKEN.balanceOf(address(this)) < _vstAmount) {
      revert FixedFeeSwap_InsufficientBalance();
    }

    VAULT_SHARE_TOKEN.transfer(msg.sender, _vstAmount);

    emit Redeem(msg.sender, _vstAmount, _maturityReached);
  }

  /// @notice Records the vault fee indexes at maturity, which switches vault fees from YT holders
  /// to PT holders.
  /// @dev
  ///  - Callable by anyone at or after maturity. Every redeem, YT claim and `collectFeesToYT`
  ///    after maturity also settles first, so calling this is optional; it lets anyone fix the
  ///    switch close to maturity.
  ///  - Does nothing once the contract has settled.
  function settle() external {
    if (block.timestamp < MATURITY) revert FixedFeeSwap_BeforeMaturity();
    if (settled()) return;
    _syncFees();
  }

  /// @notice The vault's token0 fee index at maturity. YT earns up to it and PT earns after it.
  /// @return The index. Settlement leaves it in the checkpoint, which never moves again.
  /// @dev Reverts until `settled()`, so a caller can't mistake an unrecorded index for zero.
  function maturityFeeIndex0Scaled() external view returns (uint256) {
    if (!settled()) revert FixedFeeSwap_NotSettled();
    return vstFeeCheckpoint.feeIndex0LastScaled;
  }

  /// @notice The vault's token1 fee index at maturity. YT earns up to it and PT earns after it.
  /// @return The index. Settlement leaves it in the checkpoint, which never moves again.
  /// @dev Reverts until `settled()`, so a caller can't mistake an unrecorded index for zero.
  function maturityFeeIndex1Scaled() external view returns (uint256) {
    if (!settled()) revert FixedFeeSwap_NotSettled();
    return vstFeeCheckpoint.feeIndex1LastScaled;
  }

  /// @notice Whether the contract has recorded the vault fee indexes at maturity.
  /// @return True once settled. Settlement is the only thing that sets the checkpoint time to
  /// `MATURITY`; every checkpoint before it is taken before maturity.
  function settled() public view returns (bool) {
    return vstFeeCheckpoint.timestamp == MATURITY;
  }

  /// @notice Brings fee accounting up to date with the vault, without claiming any fees.
  /// @dev
  ///  - Callable by anyone. YieldToken calls it before every transfer, so the sender keeps the
  ///    fees they earned.
  ///  - Before maturity, credits YT holders with the vault fees earned since the last sync. At or
  ///    after maturity, settles if nobody has yet.
  function syncFees() external {
    _syncFees();
  }

  /// @notice Pays a YT holder the fees their YT has earned, without burning it.
  /// @param _user The holder to pay. The fees always go to `_user`, so anyone can call this.
  /// @return _claimedToken0 Amount of fee token0 paid.
  /// @return _claimedToken1 Amount of fee token1 paid.
  /// @dev The only way to collect fees credited to an account that no longer holds YT, such as one
  /// that transferred all of it.
  function claimYTFees(address _user)
    external
    returns (uint256 _claimedToken0, uint256 _claimedToken1)
  {
    (_claimedToken0, _claimedToken1) = YIELD_TOKEN.claim(_user);
  }

  /// @notice Brings fee accounting up to date and claims this hook's vault fees into it.
  /// @dev
  ///  - Before maturity, credits YT holders with the vault fees earned since the last sync.
  ///  - At or after maturity, settles if nobody has yet, then credits YT nothing more.
  ///  - Claims this hook's fees from the vault, so YT holders can be paid through
  ///    `transferFeesToUser`.
  ///  - Callable by anyone. Calling it shortly before maturity narrows the window settlement has to
  ///    split by time.
  function collectFeesToYT() external {
    _syncFees();

    // Claim fees from the vault into this contract; YT will call transferFeesToUser to pay users
    VAULT_SHARE_TOKEN.claim(address(this));
  }

  /// @notice Transfers fee tokens directly to a user. Called by YieldToken during fee claims.
  /// @param _user The address to transfer the fees to.
  /// @param _amount0 The amount of fee token0 to transfer.
  /// @param _amount1 The amount of fee token1 to transfer.
  /// @dev
  ///  - Can only be called by the YieldToken contract.
  ///  - Pays at most this hook's balance of each token. YT is credited only with fees the hook's
  ///    VST earned, so any shortfall is rounding dust from the vault's accounting. Capping it keeps
  ///    a YT claim from reverting over dust.
  function transferFeesToUser(address _user, uint256 _amount0, uint256 _amount1) external {
    if (msg.sender != address(YIELD_TOKEN)) revert FixedFeeSwap_NotAuthorized();

    _amount0 = Math.min(_amount0, _getTokenBalance(FEE_TOKEN0));
    _amount1 = Math.min(_amount1, _getTokenBalance(FEE_TOKEN1));
    yieldTokenFeesOwed0 = Math.saturatingSub(yieldTokenFeesOwed0, _amount0);
    yieldTokenFeesOwed1 = Math.saturatingSub(yieldTokenFeesOwed1, _amount1);

    if (_amount0 > 0) _transferFeeToken(FEE_TOKEN0, _user, _amount0);
    if (_amount1 > 0) _transferFeeToken(FEE_TOKEN1, _user, _amount1);
  }

  /// @notice Claims fees and burns leftover yield tokens after maturity.
  /// @dev
  ///  - Can only be called after maturity.
  ///  - Claims every fee the caller's YT earned up to maturity, whatever anyone else has done.
  ///  - Burns the YT tokens after claiming fees.
  ///  - Note: This function internally calls `burn()` on the YT token, which claims fees before
  /// burning. Fees are claimed through the YT token's burn mechanism.
  function claimYTFeesAfterMaturity() external {
    if (block.timestamp < MATURITY) revert FixedFeeSwap_BeforeMaturity();

    uint256 _amount = YIELD_TOKEN.balanceOf(msg.sender);

    if (_amount == 0) revert FixedFeeSwap_InvalidAmount();

    _claimAndBurnYieldTokens(msg.sender, _amount);
  }

  /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Claims fees and burns YT tokens
  /// @param _user The address to claim fees from and burn YT tokens for.
  /// @param _amount The amount of YT tokens to claim fees from and burn.
  /// @dev Burns the YT tokens, which first claims their fees through `collectFeesToYT` and
  /// `transferFeesToUser`.
  function _claimAndBurnYieldTokens(address _user, uint256 _amount) internal {
    // Caller should have enough YT tokens
    if (YIELD_TOKEN.balanceOf(_user) < _amount) revert FixedFeeSwap_InsufficientBalance();

    // Burn YT tokens (which internally claims fees before burning)
    YIELD_TOKEN.burn(_user, _amount);
  }

  /// @notice Pays a PT redeemer the fees the vault earned after maturity on the VST they redeem.
  /// @param _user The address to pay.
  /// @param _amount The amount of PT being redeemed.
  /// @param _feeIndex0Now The vault's current token0 fee index.
  /// @param _feeIndex1Now The vault's current token1 fee index.
  /// @dev
  ///  - Each VST earns the increase in the vault's fee index, so `_amount` PT is owed
  ///    `_amount * (index now - index at maturity) / PRECISION` of each fee token.
  ///  - Claims this hook's vault fees first, so the payout includes the newest ones.
  ///  - Pays at most the balance not owed to YT holders, so rounding dust can't take their fees.
  ///  - Must run after settlement.
  function _payFeesEarnedAfterMaturity(
    address _user,
    uint256 _amount,
    uint256 _feeIndex0Now,
    uint256 _feeIndex1Now
  ) internal {
    VAULT_SHARE_TOKEN.claim(address(this));

    uint256 _feeToken0Amount = Math.min(
      _feesEarnedAfterMaturity(_amount, _feeIndex0Now, vstFeeCheckpoint.feeIndex0LastScaled),
      _balanceNotOwedToYieldToken(FEE_TOKEN0, yieldTokenFeesOwed0)
    );
    uint256 _feeToken1Amount = Math.min(
      _feesEarnedAfterMaturity(_amount, _feeIndex1Now, vstFeeCheckpoint.feeIndex1LastScaled),
      _balanceNotOwedToYieldToken(FEE_TOKEN1, yieldTokenFeesOwed1)
    );

    if (_feeToken0Amount > 0) _transferFeeToken(FEE_TOKEN0, _user, _feeToken0Amount);
    if (_feeToken1Amount > 0) _transferFeeToken(FEE_TOKEN1, _user, _feeToken1Amount);

    emit FeesClaimed(_user, FEE_TOKEN0, FEE_TOKEN1, _feeToken0Amount, _feeToken1Amount);
  }

  /// @notice The fees `_amount` VST earned between the maturity index and the current index.
  /// @param _amount The amount of VST.
  /// @param _feeIndexNowScaled The vault's current fee index.
  /// @param _maturityFeeIndexScaled The vault's fee index at maturity.
  /// @return The fees earned, rounded down.
  function _feesEarnedAfterMaturity(
    uint256 _amount,
    uint256 _feeIndexNowScaled,
    uint256 _maturityFeeIndexScaled
  ) internal pure returns (uint256) {
    return Math.mulDiv(_amount, _feeIndexNowScaled - _maturityFeeIndexScaled, FeeTracking.PRECISION);
  }

  /// @notice This hook's balance of a fee token, minus what it owes YT holders in that token.
  /// @param _token The fee token.
  /// @param _owedToYieldToken The amount of `_token` owed to YT holders.
  /// @return The balance available to PT redeemers, or zero if YT holders are owed all of it.
  function _balanceNotOwedToYieldToken(address _token, uint256 _owedToYieldToken)
    internal
    view
    returns (uint256)
  {
    return Math.saturatingSub(_getTokenBalance(_token), _owedToYieldToken);
  }

  /// @notice Gets the balance of a token in the contract.
  /// @param _token The address of the token to get the balance of.
  /// @return The balance of the token in the contract.
  function _getTokenBalance(address _token) internal view returns (uint256) {
    if (_token == NATIVE) return address(this).balance;
    else return IERC20(_token).balanceOf(address(this));
  }

  /// @notice Transfers an amount of fee tokens to a user.
  /// @param _token The address of the token to transfer.
  /// @param _to The address to transfer the tokens to.
  /// @param _amount The amount of tokens to transfer.
  /// @dev Following Uniswap v4's `Currency` convention: NATIVE represents native ETH.
  ///      See: https://github.com/Uniswap/v4-core/blob/main/src/types/Currency.sol#L37-L38
  function _transferFeeToken(address _token, address _to, uint256 _amount) internal {
    if (_token == NATIVE) {
      (bool _success,) = payable(_to).call{value: _amount}("");
      if (!_success) revert FixedFeeSwap_TransferFailed();
    } else {
      IERC20(_token).safeTransfer(_to, _amount);
    }
  }

  /// @notice Brings fee accounting up to date with the vault.
  /// @dev
  ///  - First has the vault record the fees it has earned, so its fee indexes are current.
  ///  - Before maturity, credits YT holders with the fees earned since the last checkpoint.
  ///  - At or after maturity, settles if the contract hasn't yet. After that, YT is never credited
  ///    again; PT redeemers are paid from the index directly.
  /// @return _feeIndex0Now The vault's current token0 fee index.
  /// @return _feeIndex1Now The vault's current token1 fee index.
  function _syncFees() internal returns (uint256 _feeIndex0Now, uint256 _feeIndex1Now) {
    VAULT_SHARE_TOKEN.syncFees();
    _feeIndex0Now = VAULT_SHARE_TOKEN.globalFeeIndex0Scaled();
    _feeIndex1Now = VAULT_SHARE_TOKEN.globalFeeIndex1Scaled();

    if (block.timestamp < MATURITY) {
      _creditYieldTokenUpTo(_feeIndex0Now, _feeIndex1Now, block.timestamp);
    } else if (!settled()) {
      _settle(_feeIndex0Now, _feeIndex1Now);
    }
  }

  /// @notice Records the vault fee indexes at maturity and credits YT holders up to them.
  /// @param _feeIndex0Now The vault's current token0 fee index.
  /// @param _feeIndex1Now The vault's current token1 fee index.
  /// @dev The fees since the last checkpoint arrive as one lump that may cover time on both sides
  /// of maturity, so the maturity index is interpolated by time between the checkpoint and now.
  function _settle(uint256 _feeIndex0Now, uint256 _feeIndex1Now) internal {
    VstFeeCheckpoint memory _checkpoint = vstFeeCheckpoint;
    uint256 _maturityIndex0 =
      _interpolateToMaturity(_checkpoint.feeIndex0LastScaled, _feeIndex0Now, _checkpoint.timestamp);
    uint256 _maturityIndex1 =
      _interpolateToMaturity(_checkpoint.feeIndex1LastScaled, _feeIndex1Now, _checkpoint.timestamp);

    emit Settled(_maturityIndex0, _maturityIndex1);

    // Leaves the maturity indexes in the checkpoint and moves its time to `MATURITY`, which marks
    // the contract settled.
    _creditYieldTokenUpTo(_maturityIndex0, _maturityIndex1, MATURITY);
  }

  /// @notice Estimates a fee index at maturity from a reading before it and one at or after it.
  /// @param _feeIndexLast The index at the last checkpoint, taken before maturity.
  /// @param _feeIndexNow The index now, at or after maturity.
  /// @param _checkpointTimestamp When the last checkpoint was taken.
  /// @return The index at maturity, assuming fees accrued evenly between the two readings, rounded
  /// down.
  function _interpolateToMaturity(
    uint256 _feeIndexLast,
    uint256 _feeIndexNow,
    uint256 _checkpointTimestamp
  ) internal view returns (uint256) {
    return _feeIndexLast
      + Math.mulDiv(
      _feeIndexNow - _feeIndexLast,
      MATURITY - _checkpointTimestamp,
      block.timestamp - _checkpointTimestamp
    );
  }

  /// @notice Credits YT holders with the fees this hook's VST earned between the checkpoint and
  /// the given indexes, and moves the checkpoint to them.
  /// @param _feeIndex0 The token0 index to credit up to.
  /// @param _feeIndex1 The token1 index to credit up to.
  /// @param _timestamp The time the indexes are for, stored with the checkpoint.
  function _creditYieldTokenUpTo(uint256 _feeIndex0, uint256 _feeIndex1, uint256 _timestamp)
    internal
  {
    VstFeeCheckpoint memory _checkpoint = vstFeeCheckpoint;
    vstFeeCheckpoint = VstFeeCheckpoint(_feeIndex0, _feeIndex1, _timestamp);
    uint256 _deltaIndex0 = _feeIndex0 - _checkpoint.feeIndex0LastScaled;
    uint256 _deltaIndex1 = _feeIndex1 - _checkpoint.feeIndex1LastScaled;
    if (_deltaIndex0 == 0 && _deltaIndex1 == 0) return;

    // Each YT stands for one VST split here, which has earned `_deltaIndex / PRECISION` of each fee
    // token since the checkpoint. YT supply, unlike this hook's VST balance, leaves out VST sent
    // here directly, which YT has no claim on. Every YT has a VST behind it, so the hook always
    // earns at least what YT is credited. With no YT outstanding the fees have no owner.
    uint256 _yieldTokenSupply = YIELD_TOKEN.totalSupply();
    if (_yieldTokenSupply == 0) return;
    uint256 _newFees0 = Math.mulDiv(_yieldTokenSupply, _deltaIndex0, FeeTracking.PRECISION);
    uint256 _newFees1 = Math.mulDiv(_yieldTokenSupply, _deltaIndex1, FeeTracking.PRECISION);
    if (_newFees0 == 0 && _newFees1 == 0) return;

    uint256 _yieldTokenIndex0Before = YIELD_TOKEN.globalFeeIndex0Scaled();
    uint256 _yieldTokenIndex1Before = YIELD_TOKEN.globalFeeIndex1Scaled();
    YIELD_TOKEN.updateFees(_newFees0, _newFees1);
    // Holds back only what YieldToken's index now pays out, read from the index itself, so its
    // rounding dust isn't reserved forever and its rounding rules live only in YieldToken.
    yieldTokenFeesOwed0 += Math.mulDiv(
      YIELD_TOKEN.globalFeeIndex0Scaled() - _yieldTokenIndex0Before,
      _yieldTokenSupply,
      FeeTracking.PRECISION
    );
    yieldTokenFeesOwed1 += Math.mulDiv(
      YIELD_TOKEN.globalFeeIndex1Scaled() - _yieldTokenIndex1Before,
      _yieldTokenSupply,
      FeeTracking.PRECISION
    );
  }

  /// @notice Accepts native ETH sent by the VaultShareToken when claiming fees.
  receive() external payable {}
}
