## Claim / fee attribution scenarios (FixedFeeSwapHook + PT/YT hybrid)

This document enumerates the claim scenarios + transfer combinations and checks whether the current implementation attributes fees correctly.

### Glossary
- **VST**: VaultShareToken (underlying deposit token)
- **PT**: PrincipalToken
- **YT**: YieldToken
- **Pre-maturity**: `block.timestamp < MATURITY`
- **Post-maturity**: `block.timestamp >= MATURITY`
- **Fee routing**: fees are routed by the hook via `FixedFeeSwapHook.updateFees(token0, token1)`.

### Invariants / intended economic rules
- **R1 (pre-maturity yield)**: While pre-maturity, fees accrue to **YT holders**.
- **R2 (post-maturity yield)**: While post-maturity, fees accrue to **PT holders**.
- **R3 (claim gating)**:
  - YT fees are claimable only when the hook triggers `YIELD_TOKEN.claim(user)` (currently done inside `redeem`).
  - PT fees are claimable only when the hook triggers `PRINCIPAL_TOKEN.claim(user)` (currently done inside `redeem` post-maturity).
- **R4 (transfer correctness)**: Fee ownership follows token ownership:
  - If you transfer YT, you transfer the right to future (and unclaimed) YT fees.
  - If you transfer PT, you transfer the right to future (and unclaimed) PT fees.

### Implementation summary
- **Before maturity**
  - `deposit(amount)` mints `amount` PT + `amount` YT.
  - `updateFees(collected0, collected1)` routes to `YIELD_TOKEN.updateFees(...)`.
  - `redeem(amount)`:
    - requires `PT>=amount` and `YT>=amount`
    - calls `YIELD_TOKEN.claim(user)` then burns `amount` YT
    - burns `amount` PT and returns `amount` VST

- **At/after maturity**
  - `updateFees(collected0, collected1)` routes to PT:
    - hook calls `_checkpointMaturity()` once
    - then calls `PRINCIPAL_TOKEN.updateFees(...)`
  - `_checkpointMaturity()`
    - reads YT final global indexes (`YT.globalFeeIndex*Scaled()`)
    - sets PT baseline via `PRINCIPAL_TOKEN.initializeFeeIndexes(...)` (one-time)
  - `redeem(amount)` (post-maturity):
    - requires `PT>=amount`
    - if user has any YT, hook calls `YIELD_TOKEN.claim(user)` then burns ALL user YT balance
    - hook calls `_checkpointMaturity()`
    - hook calls `PRINCIPAL_TOKEN.claim(user)`
    - burns `amount` PT and returns `amount` VST

- **PT fee tracking (hybrid design)**
  - PT now tracks fees internally, like YT.
  - PT updates user fee accounting on mint/burn/transfer (`_update(...)` override).
  - PT includes a baseline + lazy user-checkpoint initialization so users do NOT "earn the baseline".

---

## Scenario matrix

### A. Simple redeem scenarios (no transfers)

#### A1. Pre-maturity: mint → redeem
- **Setup**: user deposits, fees accrue pre-maturity, user redeems pre-maturity.
- **Expected**: user receives all YT fees earned while holding YT; PT has no fees.
- **Actual**:
  - redeem calls `YT.claim(user)` (syncs and transfers accrued)
  - then burns YT and PT
- **Status**: ✅ correct.

#### A2. Post-maturity: mint → do nothing → redeem
- **Setup**: user deposits, fees accrue pre-maturity (to YT), maturity passes, fees accrue post-maturity (to PT), user redeems.
- **Expected**:
  - user receives all pre-maturity fees via YT claim
  - user receives all post-maturity fees via PT claim
- **Actual**:
  - redeem sees user still has YT → calls `YT.claim(user)` then burns ALL YT
  - hook checkpoints PT baseline once
  - hook calls `PT.claim(user)`
- **Status**: ✅ correct.

#### A3. Post-maturity: multiple redeems
- **Setup**: user redeems partially multiple times after maturity.
- **Expected**:
  - first redeem claims all remaining YT fees and burns all YT
  - each redeem claims any PT fees accrued since last claim
- **Actual**:
  - first post-maturity redeem burns all YT and claims YT fees
  - PT claim is called each redeem
- **Status**: ✅ correct.

---

### B. YT transfer scenarios

#### B1. Pre-maturity: transfer YT away, then redeem pre-maturity
- **Setup**: user has PT+YT, transfers some/all YT away, then tries to redeem pre-maturity.
- **Expected**: should revert if user lacks enough YT for redeem.
- **Actual**: redeem pre-maturity checks `YT.balance >= amount`.
- **Status**: ✅ correct.

#### B2. Pre-maturity: transfer YT away, then redeem post-maturity
- **Setup**: user transfers all YT away pre-maturity, keeps PT, waits to maturity, then redeems.
- **Expected**:
  - user should NOT receive pre-maturity fees (they transferred YT)
  - user CAN receive post-maturity fees on PT
- **Actual**:
  - post-maturity redeem sees YT balance = 0 → no YT claim
  - PT claim works
- **Status**: ✅ correct.

#### B3. Post-maturity: transfer YT
- **Setup**: user still has YT at maturity, transfers it post-maturity.
- **Expected**:
  - YT fees are still associated to YT; transferee can claim them later when hook claims on redeem.
- **Actual**:
  - YT accounting is in YT; transfers update fee checkpoints.
- **Status**: ✅ correct (note: YT is "worthless" economically post-maturity, but still represents claim rights to pre-maturity fees).

---

### C. PT transfer scenarios (pre-maturity)

#### C1. Pre-maturity: transfer PT, then redeem pre-maturity
- **Setup**: user transfers PT away before maturity and then tries to redeem pre-maturity.
- **Expected**: redeem pre-maturity requires both PT and YT; it should revert if PT < amount.
- **Actual**: redeem checks PT balance first.
- **Status**: ✅ correct.

#### C2. Pre-maturity: transfer PT to someone else, both hold YT unchanged, redeem post-maturity
- **Setup**:
  - Alice mints 100 PT + 100 YT
  - Alice transfers 50 PT to Bob pre-maturity
  - maturity passes, post-maturity fees accrue to PT
  - both redeem post-maturity
- **Expected**:
  - Alice: claims YT fees on her YT, and PT fees on her remaining PT
  - Bob: claims PT fees on the PT he holds (only for the time he held it post-maturity)
- **Actual**:
  - PT fee tracking is inside PT and **updates on transfers**.
  - Baseline is initialized at maturity, and users' checkpoints are lazily initialized to baseline.
- **Status**: ✅ correct.

---

### D. PT transfer scenarios (post-maturity) — important

#### D1. Post-maturity: transfer PT after fees start accruing
- **Setup**:
  - PT baseline set at maturity
  - fees accrue to PT (index increases)
  - Alice transfers PT to Bob after some accrual
- **Expected**:
  - Alice earns fees for the period she held PT
  - Bob earns fees only from the time he holds PT onward
- **Actual (with hybrid PT tracking)**:
  - PT overrides ERC20 `_update` to call `_updateUserFees(from)` and `_updateUserFees(to)` before balances move
  - so both Alice and Bob are checkpointed correctly at transfer time
- **Status**: ✅ correct.

#### D2. Post-maturity: Bob receives PT and never interacts until redeem
- **Setup**: Bob receives PT post-maturity, holds it, then later redeems.
- **Expected**: Bob earns PT fees from when he received PT onward.
- **Actual**:
  - the transfer itself already syncs fee checkpoints (inside PT)
  - redeem triggers hook to call `PT.claim(Bob)`
- **Status**: ✅ correct.

---

### E. Fee routing / checkpoint scenarios

#### E1. Fees are updated before maturity
- **Setup**: `hook.updateFees(...)` called pre-maturity.
- **Expected**: YT global indexes update.
- **Actual**: routes to `YIELD_TOKEN.updateFees`.
- **Status**: ✅ correct.

#### E2. First fee update after maturity (lazy checkpoint)
- **Setup**: `hook.updateFees(...)` called post-maturity for the first time.
- **Expected**:
  - baseline is set once
  - new fees accrue to PT
- **Actual**:
  - hook calls `_checkpointMaturity()` once
  - then calls `PT.updateFees(...)`
- **Status**: ✅ correct.

#### E3. No post-maturity fees ever updated, but user redeems post-maturity
- **Setup**: no `updateFees` calls post-maturity; user redeems.
- **Expected**:
  - baseline can still be initialized
  - PT claim returns 0
- **Actual**:
  - redeem calls `_checkpointMaturity()` then `PT.claim(user)`
- **Status**: ✅ correct.

---

## Known assumptions / constraints

1. **Users cannot directly call `YT.claim` or `PT.claim`** (hook-only). Claiming happens via `redeem`.
2. **Fee funds availability**: fee accounting is correct, but the system that calls `hook.updateFees(...)` must also ensure the hook/PT/YT actually holds or can pay out the fee tokens as implemented.
3. **Burning all YT post-maturity on first redeem**: this is intentional to force pre-maturity fee claim + clean up YT.

---

## Conclusion

With the hybrid approach:
- **Fee attribution is sound** for PT transfers both pre- and post-maturity because PT now updates fee checkpoints on transfers.
- The previous "hook-tracked PT fees" approach was fundamentally broken for PT transfers (since transfers bypass the hook).
- The remaining behavior choices (e.g., burning all YT on first post-maturity redeem) are design decisions but do not break fee correctness.

---

## Historical context: Hook-only approach (deprecated)

### Why the hook-only approach was replaced

The current implementation uses a **hybrid design** where PT tracks fees internally (like YT). This replaced an earlier **hook-only design** where:
- YT handled its own fee accounting (as it does today)
- PT was a plain ERC20 (no `FeeTracking`, no fee-sync on transfer)
- The hook maintained PT fee accounting state (`ptGlobalFees`, `ptUserFees`) and paid fees out on redeem

### Why hook-only was broken

The hook-only approach had a fundamental flaw: **PT transfers bypass the hook**, so the hook cannot update fee checkpoints at transfer time. This breaks fee attribution in several scenarios:

#### Broken scenario: Post-maturity PT transfer
- **Setup**: Alice holds PT when fees accrue (index 100 → 110), then transfers PT to Bob. Later index moves 110 → 120 and Bob redeems.
- **Expected**: Alice gets fees for 100 → 110, Bob gets fees for 110 → 120.
- **Hook-only outcome**: ❌ **Broken**
  - Bob's checkpoint is not updated to 110 at receipt (transfer doesn't call hook)
  - If Bob's checkpoint is still 100, Bob accrues 100 → 120 (includes 100 → 110 he did not hold)
  - Alice may lose attribution for 100 → 110

#### Broken scenario: Pre-maturity PT transfer
- **Setup**: Alice transfers PT to Bob pre-maturity, maturity passes, both redeem post-maturity.
- **Expected**: Each earns PT fees only on the PT they hold post-maturity.
- **Hook-only outcome**: ❌ **Broken**
  - Hook doesn't see the PT transfer, so it can't set Bob's `ptUserFeeIndex*` at receipt time
  - Bob may "earn the baseline" and/or accrue for time before he actually held PT

### What worked vs what didn't

#### ✅ Sound (hook-only)
- Scenarios where only YT is used/transferred for fee rights
- Scenarios where PT is never transferred (single holder path)
- Hook correctly initializes PT user checkpoints at maturity baseline

#### ❌ Fundamentally broken (hook-only)
- Any scenario involving **PT transfers** (pre- or post-maturity) where the recipient's PT fee checkpoint must be updated at transfer time

**Core reason**: PT transfers happen inside the PT ERC20 and do not call into the hook, so hook-only accounting cannot correctly assign fee ownership across transfers.

### The solution: Hybrid approach

The hybrid approach fixes this by:
- PT now tracks fees internally, like YT
- PT overrides ERC20 `_update` to call `_updateUserFees(from)` and `_updateUserFees(to)` before balances move
- Both sender and recipient are checkpointed correctly at transfer time
- Fee attribution is sound for PT transfers both pre- and post-maturity
