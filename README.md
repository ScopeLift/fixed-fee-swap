⚠️ **Disclaimer:** This repository has not been audited. It is a proof of concept and is not ready for production use.

# Fixed Fee Swap: Principal and Yield Token Separation

- [Fixed Fee Swap: Principal and Yield Token Separation](#fixed-fee-swap-principal-and-yield-token-separation)
  - [About](#about)
  - [Architecture](#architecture)
    - [Summary](#summary)
    - [Component Summary](#component-summary)
      - [LPVault](#lpvault)
      - [VaultShareToken](#vaultsharetoken)
      - [FixedFeeSwap](#fixedfeeswap)
      - [PrincipalToken](#principaltoken)
      - [YieldToken](#yieldtoken)
      - [FeeTracking Library](#feetracking-library)
      - [Zapper](#zapper)
      - [FixedFeeSwapMarket](#fixedfeeswapmarket)
    - [Diagram](#diagram)
  - [Development](#development)
    - [Getting Started](#getting-started)
    - [Build](#build)
    - [Test](#test)
  - [License](#license)

## About

Fixed Fee Swap is a protocol for separating LP positions into their principal and yield components. It allows liquidity providers to tokenize their Uniswap v4 LP positions and split them into Principal Tokens (PT) and Yield Tokens (YT), enabling more flexible yield strategies.

Key features:

- **Principal/Yield Separation**: Split vault shares into PT (representing principal) and YT (representing future yield/fees)
- **Time-based Maturity**: Each split has a defined maturity date after which PT holders can redeem 1:1 for the underlying vault shares
- **Pro-rata Fee Distribution**: Fees earned by the LP position are distributed to YT holders proportionally using an efficient cumulative fee-per-share index model
- **Flash Loan Support**: PT tokens support ERC-3156 flash loans, enabling advanced DeFi strategies

## Architecture

### Summary

The system consists of smart contracts that manage Uniswap v4 LP positions and enable principal/yield separation:

1. **LPVault**: Wraps Uniswap v4 LP positions and issues VaultShareTokens (VST) representing proportional ownership
2. **FixedFeeSwap**: Enables splitting VST into Principal Tokens and Yield Tokens before a maturity date
3. **Token System**: PT and YT tokens with built-in fee tracking and distribution mechanisms
4. **Zapper**: Helper contract for easily buying/selling YT tokens using flash loans
5. **FixedFeeSwapMarket**: A trading market for swapping between Principal Tokens and cash, with yield-based pricing

### Component Summary

#### LPVault

A contract that wraps a set of static LP positions in a single Uniswap v4 pool. Positions and their weight distributions are fixed at contract creation.

- Manages liquidity across multiple tick ranges with configurable weights (summing to 100%)
- Issues VaultShareTokens proportional to deposited liquidity
- Collects swap fees from the pool and distributes them to share holders
- Inherits from VaultShareToken for integrated fee tracking

#### VaultShareToken

An ERC20 token representing proportional ownership of an LP vault with built-in fee accounting.

- Implements fee distribution via cumulative "fee-per-share" indexes
- Users accrue fees lazily: `accrued += balance * (globalIndex - userIndex) / PRECISION`
- Ensures O(1) fee accounting per operation with no iteration over holders
- Supports native ETH as a fee token (using `address(0)` following Uniswap v4 convention)

#### FixedFeeSwap

The core contract that enables splitting VaultShareTokens into Principal and Yield tokens.

- **Deposit**: Before maturity, users can deposit VST and receive 1:1 PT and YT
- **Redeem (before maturity)**: Users must burn equal amounts of PT and YT to receive VST back
- **Settlement at maturity**: The first action at or after maturity, or a call to the permissionless `settle()`, records the vault fee index at maturity. When the first reading after maturity covers time on both sides of it, the fees in that reading are split by time.
  - Fees earned up to that index belong to YT holders, who can claim them after maturity whatever anyone else has done
  - Fees earned after it belong to PT holders
- **Redeem (at/after maturity)**: Users burn only PT to receive VST back, plus the fees the vault earned on that VST since maturity. No YT is needed.
- Deploys new PT and YT contracts for each maturity period

#### PrincipalToken

An ERC20 token representing the principal value of deposited vault shares.

- Redeemable 1:1 for VaultShareTokens after maturity
- Supports ERC-3156 flash loans for capital-efficient strategies
- Can only be minted/burned by the FixedFeeSwap contract

#### YieldToken

An ERC20 token representing the right to fees earned by the underlying LP position.

- Tracks and distributes fees using the same cumulative index model as VaultShareToken
- Fees are automatically claimed when tokens are burned
- Transfers first sync the vault fees earned so far, so the sender keeps them and the recipient earns only from the transfer on
- Earned fees can be claimed at any time, without burning YT, through FixedFeeSwap's `claimYTFees(address)`. The holder can call it, or any account with a YT allowance from the holder, and it always pays the holder
- Earns fees up to maturity and nothing after it
- After maturity, holders can claim the fees their YT earned and burn it via `claimYTFeesAfterMaturity()`, whatever other holders have done
- Can only be minted/burned by the FixedFeeSwap contract

#### FeeTracking Library

A shared library implementing the cumulative "fee-per-share" index model for pro-rata fee distribution.

- Global fee indexes track total fees earned per share over time
- Each user stores a checkpoint of the last index they synced to
- User earnings are accrued lazily on interaction (mint, burn, transfer, claim)
- Guarantees O(1) fee accounting and prevents over-distribution

#### Zapper

A helper contract for buying and selling YT tokens using flash loans.

- **Sell YT**: `sellYieldToken(ytAmount, vstForBuyback, minVstOut, deadline)`. Flash loan PT,
  combine with YT to redeem VST, and swap `vstForBuyback` of it back to PT to repay the loan. The
  seller gets the VST left and any PT beyond the loan.
- **Buy YT**: `buyYieldToken(vstAmount, ptLoan, minYtOut, deadline)`. Flash loan `ptLoan` PT, swap
  it for VST, deposit to get PT+YT, repay the loan with PT, and keep the YT. The buyer gets the YT
  and any PT left after repaying, including PT the market didn't take.

The market only swaps an exact input and has no quote function, so the caller sizes each swap.
Simulate the swap off-chain against the current market state. The market pulls the input from its
caller, so `eth_call` the swap from the Zapper's address with state overrides that give it the input
and allowance, or search with `eth_call` over the zap itself:

- For a sale, `vstForBuyback` is the least VST whose `swap(vstForBuyback, false, 0)` returns at
  least `ytAmount` PT. It must be at most `ytAmount`, the VST that redeeming gives; a sale whose
  buyback needs more can't be done. The market fills only whole ticks, so this can happen for some
  small sales. The PT price rises toward par every second, so a buyback sized exactly can fall a
  tick short if the sale lands in a later block. Add a small margin, such as 0.01%. The market can
  keep it, so it is the seller's slippage tolerance.
- For a purchase, `ptLoan` is a PT amount whose `swap(ptLoan, true, 0)` returns VST out and takes
  PT in such that `vstAmount + vstOut >= ptIn`; PT the market leaves untaken counts toward
  repayment. The buyer gets `vstAmount + vstOut` in YT, so the loan with the most VST out buys the
  most, and any PT left after repaying is refunded. `minYtOut` doesn't bound that refund.

A zap reverts if the market moves before it runs so that the sized swap can no longer repay the
loan, if its output is below `minVstOut` or `minYtOut`, if it runs after `deadline`, or if it runs at
or after maturity.

#### FixedFeeSwapMarket

A trading market that enables users to swap between Principal Tokens and cash tokens. It operates as a Uniswap v4 hook with custom pricing logic tailored for fixed-income assets.

**What it does:**

- Provides a marketplace where users can trade Principal Tokens for cash (and vice versa)
- Uses a yield-based pricing model where prices naturally converge toward 1:1 as maturity approaches
- Allows liquidity providers to earn trading fees by providing liquidity across yield ranges

**How pricing works:**

The market uses "ticks" that represent yield rates (similar to interest rates). Each tick equals 1 basis point (0.01%) of yield. As time passes and the maturity date gets closer, the price of Principal Tokens gradually increases toward their face value.

**For traders:**

- **Sell PT for cash**: Trade your Principal Tokens now for immediate cash at a discount
- **Buy PT with cash**: Purchase discounted Principal Tokens that can be redeemed at full value after maturity

**For liquidity providers:**

- Provide liquidity across specific yield ranges (similar to concentrated liquidity in Uniswap v3)
- Earn a share of trading fees proportional to your liquidity
- Choose your yield range based on where you expect trading activity

**Key features:**

- **Time-based maturity**: The market has a defined start time and maturity date
- **Configurable fee rate**: Trading fees are collected on each swap
- **Concentrated liquidity**: LPs can focus their capital in specific yield ranges for higher capital efficiency
- **Vault yield on cash**: The cash token is a VaultShareToken, which earns vault fees for the market. Anyone can call `forwardVaultYield()` to send those fees to the recipient set at deployment (`VAULT_YIELD_RECIPIENT`). LPs don't receive them, so this is a cost of providing liquidity to price into the fee rate.

### Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Uniswap v4 Pool                                │
│                         (token0 / token1 liquidity)                         │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ LP positions
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                                  LPVault                                    │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         VaultShareToken                              │   │
│  │  • Deposit token0 + token1 → receive VST shares                     │   │
│  │  • Withdraw VST shares → receive token0 + token1                    │   │
│  │  • Collect fees from LP positions                                   │   │
│  │  • Fee tracking via cumulative index                                │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ VST
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              FixedFeeSwap                                   │
│                                                                             │
│  deposit(VST) ──────────────────────────────────────────────► PT + YT      │
│                                                                             │
│  redeem(PT + YT) ◄────────────────── (before maturity) ────── VST          │
│  redeem(PT only) ◄────────────────── (after maturity) ─────── VST + fees   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                           │                    │
              ┌────────────┘                    └────────────┐
              │                                              │
              ▼                                              ▼
┌─────────────────────────────┐            ┌─────────────────────────────────┐
│       PrincipalToken        │            │          YieldToken             │
│                             │            │                                 │
│  • Represents principal     │            │  • Represents yield rights      │
│  • 1:1 redeemable after     │            │  • Receives LP fees before      │
│    maturity                 │            │    maturity                     │
│  • ERC-3156 flash loans     │            │  • Fee tracking via cumulative  │
│                             │            │    index                        │
└─────────────────────────────┘            └─────────────────────────────────┘
              │                                              │
              ├────────────────────┬─────────────────────────┘
              │                    │
              ▼                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            FixedFeeSwapMarket                               │
│                           (Uniswap v4 Hook)                                 │
│                                                                             │
│  • Trade PT ←→ Cash with yield-based pricing                               │
│  • Price converges to 1:1 as maturity approaches                           │
│  • LPs provide liquidity across yield ranges and earn fees                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                                 Zapper                                      │
│                                                                             │
│  sellYieldToken(YT, …) ───► Flash loan PT ───► Redeem ───► Swap ────► VST  │
│  buyYieldToken(VST, …) ───► Flash loan PT ───► Swap ───► Deposit ────► YT  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Development

### Getting Started

This repo is built using [Foundry](https://github.com/foundry-rs/foundry).

1. [Install Foundry](https://book.getfoundry.sh/getting-started/installation)

2. Clone the repository

```bash
git clone https://github.com/ScopeLift/fixed-fee-swap.git
cd fixed-fee-swap
```

3. Install dependencies

```bash
forge install
```

4. (Optional) Install [scopelint](https://github.com/ScopeLift/scopelint) for formatting and linting

```bash
cargo install scopelint
```

### Build

Build contracts:

```bash
forge build
```

Format code (if scopelint is installed):

```bash
scopelint fmt
```

### Test

Run tests:

```bash
forge test
```

Run tests with verbose output:

```bash
forge test -vvv
```

Run tests with gas reporting:

```bash
forge test --gas-report
```

Run coverage:

```bash
forge coverage
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
