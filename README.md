# ERC20 Periodical Staking v0.3.0

## Deployment

- **v0.3.0**: _not yet deployed_
- **v0.2.4**: `0xa816fC819c2BD73c0AEdf60E0b06daF2Bff9691F` (affected by the period-removal lockup, see Known Issues)

## Changes in v0.3.0

v0.3.0 is a new immutable deployment of `src/contracts/erc20-periodical-staking/`. It fixes the v0.2.4 period-removal incident (see Known Issues) and hardens the reward-pool, ownership, token-handling and admin paths that a security review of v0.2.4 flagged.

**Period/phase removal never touches accounting.** `removeStakingPeriod` and `popStakingPhase` only delete the `APY` and `STAKING_TARGET` configuration cells. `STAKED`, `userPhasePeriodDataList[*]`, `userDataList[*]`, `totalDataList[*]` and `rewardPool` are untouched, so deposits on a removed period/phase stay claimable and withdrawable. `_clearPhasePeriodUserData` (an unbounded loop over every staker) is gone; removal gas is O(phases) / O(periods) and independent of staker count. Re-adding a period works and tokens still staked there count toward the new target.

**Saturating indefinite reward math.** `_calculateIndefiniteDepositReward` returns 0 instead of underflowing when already-paid reward exceeds the accrued total.

**Reward pool protection.** `safeStake` performs **no** reward-pool check (same as v0.2.4): a periodical stake is always accepted and adds its `calculateReward(amount, apy, period)` to `totalDataList[REWARD_EXPECTED]`. `collectable = max(0, rewardPool - REWARD_EXPECTED)` is exposed as `getCollectableReward()`, and `collectReward` is bounded by it (`RewardPoolBelowReserved`), so the owner can never take reward already promised to open deposits. Indefinite (period 0) deposits are **not** reserved and are paid only from `collectable`: an indefinite **claim** pays `min(accrued, collectable)` (reverts `NoRewardToClaim` / is skipped in batch only when that is 0; the unpaid remainder keeps accruing and can be claimed after a top-up), and an indefinite **withdraw** (`withdrawDeposit`) returns principal plus the **full** accrued reward or reverts `NotEnoughFundsInRewardPool(accrued, collectable)` when `collectable` cannot cover it (the deposit stays open and keeps accruing; retry after a top-up). Principal is never locked: the explicit opt-in `withdrawDepositPartial(depositNumber, minReward)` closes the deposit with principal plus `min(accrued, collectable)` reward, reverting with the same error only if that reduced reward would be below `minReward` (`minReward = 0` always succeeds; the unpaid remainder stays in the pool). A matured periodical claim reverts `NotEnoughFundsInRewardPool` (skipped silently in batch) if the pool cannot cover its reward; nothing is lost, the user retries after the owner tops up. Ops views: `getRewardRequiredForTargets()` (sum over every configured `(phase, period != 0)` of `calculateReward(target - staked, apy, period)`) and `getRewardPoolShortfall()` (`max(0, required + deficit - collectable)` where `deficit = max(0, REWARD_EXPECTED - rewardPool)`, i.e. it also counts what already-open deposits are missing).

**Strict token accounting.** `_receiveToken` measures the balance delta and reverts `UnexpectedTokenAmount` if it differs from the requested amount. Fee-on-transfer / rebasing tokens are unsupported by design.

**Two-step ownership.** `transferOwnership(addr)` only sets `pendingOwner` (emits `OwnershipTransferStarted`); the pending owner calls `acceptOwnership()` to complete (emits `TransferOwnership`). `transferOwnership(address(0))` cancels. A pending owner has no privileges until accepting.

**Bounded loops for users.** New `claimRange(uint256 fromIndex, uint256 toIndexExclusive)` claims every claimable deposit in a caller-chosen window (`InvalidRange` on an empty window or one past the deposit count; non-claimable deposits inside the window are skipped silently). Because the window is explicit it always makes progress even when open-but-unmatured deposits sit at the head of the list, which a cursor-relative "claim at most N" variant could not guarantee. `claimAll()` is kept and iterates everything from the active cursor. `_updateActiveDepositStartIndex` now advances past a fully-closed tail (cursor == deposit count) instead of parking on the last deposit.

**Defensive guards.** `popStakingPhase` reverts `NoStakingPhasesAddedYet` at zero phases. `getDeposit` / `checkDepositStatus` revert `DepositDoesNotExist`, `getDepositsInRangeBy` reverts `InvalidRange`, instead of panicking. `collectReward` / `provideReward` reject `0` (`ZeroAmountProvided`). `collectReward` records `REWARD_COLLECTED` (user + total) for symmetry with `REWARD_PROVIDED`.

**Rescue path.** `rescueTokens(address token, uint256 amount)` (owner): any token other than `STAKING_TOKEN` in full; for `STAKING_TOKEN` only the excess over `totalDataList[STAKING] + rewardPool` (`RescueAmountExceedsExcess`), so staked principal and the reward pool can never be extracted.

**`ArrayLibrary.sortStorage` is `internal`.** The library is now fully inlined: the staking contract's build artifact has no `linkReferences`, so there is no externally deployed library, no link-time trust, and no runtime `DELEGATECALL`.

**LimitController explicit zero limit.** `setWalletLimit(wallet, phase, period, 0)` now actually means "no staking allowed": a new `hasWalletLimit(wallet, phase, period)` flag (set by `setWalletLimit`/`setWalletLimits`) makes the wallet-specific limit authoritative even when it is 0. `clearWalletLimit(wallet, phase, period)` / `clearWalletLimits(wallets, phase, period)` delete both and restore the phase/period default (emit `WalletLimitCleared`). `getAllowed`, `getRemaining`, `getAllowedBatch` and `getRemainingBatch` all resolve through one internal `_getAllowed` (the previous `this.getAllowed` external self-call is gone). Limits remain **concurrent, not lifetime**: they are compared against the amount currently staked in the cell.

**Version.** README bumped to v0.3.0; deployment address left blank until deployed.

New custom errors: `ZeroAmountProvided`, `UnexpectedTokenAmount`, `RescueAmountExceedsExcess`, `InvalidRange`, `RewardPoolBelowReserved`, `NotPendingOwner`.
New events: `OwnershipTransferStarted`, `RescueTokens`; LimitController: `WalletLimitCleared`.
New functions: `acceptOwnership()`, `pendingOwner()`, `claimRange(uint256,uint256)`, `withdrawDepositPartial(uint256,uint256)`, `getCollectableReward()`, `getRewardRequiredForTargets()`, `getRewardPoolShortfall()`, `rescueTokens(address,uint256)`; LimitController: `hasWalletLimit(address,uint256,uint256)`, `clearWalletLimit(address,uint256,uint256)`, `clearWalletLimits(address[],uint256,uint256)`.

**Operational note.** Stakes are never blocked by the reward pool, so the owner must fund the pool before deposits mature or matured periodical claims will wait (reverting `NotEnoughFundsInRewardPool`) until a top-up. `getRewardPoolShortfall()` tells you how much is missing for every open deposit and every open target.

Unchanged: compiler `0.8.20` with `via_ir` (a compiler bump is a candidate for a later release), no proxy/upgradeability, RequirementChecker v1/v2 untouched.

Tests: `test/erc20-periodical-staking/period-removal/` reproduces the v0.2.4 incident (fails on v0.2.4, passes on v0.3.0, including a gas bound proving removal no longer scales with staker count); `test/erc20-periodical-staking/v030/` covers each change above in its own file (for example `RewardSolvency.t.sol` for the reward pool and `LimitControllerWalletLimit.t.sol` for the explicit zero limit); `test/erc20-periodical-staking/security/` holds adversarial and invariant suites. Test-harness note: with `via_ir`, a raw `block.timestamp` read after `vm.warp`/`skip` inside one test function can be optimized to the pre-warp value (`test/shared/ClockHazard.t.sol` reproduces the loop form on solc 0.8.20); tests read the live time through `test/shared/Clock.sol` (`_now()`) instead.

### Deploying RequirementCheckerV2 on Polygon

Set the following environment variables before running either command:

```bash
export DEPLOYER_PRIVATE_KEY=0x...
export POLYGONSCAN_API_KEY=...
export POLYGON_RPC_URL=https://polygon-rpc.com
export POLYGON_AMOY_RPC_URL=https://rpc-amoy.polygon.technology
export WORTH_TOKEN=0x...                              # ERC20 the checker aggregates
export POOL_STAKING_CONTRACTS='[0x...,0x...]'          # pool-based staking contracts (JSON array; may be `[]`)
export PERIODICAL_STAKING_CONTRACTS='[0x...]'         # periodical staking contracts (JSON array; may be `[]`)
export DEFAULT_REQUIRED_WORTH=1000000000000000000000  # 1000 * 10**18, adjust for your token decimals
```

#### Polygon Amoy (testnet)

```bash
forge create src/contracts/requirement-checker/v2/RequirementCheckerV2.sol:RequirementCheckerV2 \
  --broadcast \
  --rpc-url $POLYGON_AMOY_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --etherscan-api-key $POLYGONSCAN_API_KEY \
  --verify \
  --constructor-args \
    $WORTH_TOKEN \
    "$POOL_STAKING_CONTRACTS" \
    "$PERIODICAL_STAKING_CONTRACTS" \
    $DEFAULT_REQUIRED_WORTH
```

#### Polygon mainnet

```bash
forge create src/contracts/requirement-checker/v2/RequirementCheckerV2.sol:RequirementCheckerV2 \
  --broadcast \
  --rpc-url $POLYGON_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY \
  --etherscan-api-key $POLYGONSCAN_API_KEY \
  --verify \
  --constructor-args \
    $WORTH_TOKEN \
    "$POOL_STAKING_CONTRACTS" \
    "$PERIODICAL_STAKING_CONTRACTS" \
    $DEFAULT_REQUIRED_WORTH
```

If the initial deploy fails to verify (e.g., transient Polygonscan rate limit), re-run verification separately:

```bash
forge verify-contract <DEPLOYED_ADDRESS> \
  src/contracts/requirement-checker/v2/RequirementCheckerV2.sol:RequirementCheckerV2 \
  --chain 137 \                                  # or 80002 for Amoy
  --etherscan-api-key $POLYGONSCAN_API_KEY \
  --constructor-args $(cast abi-encode \
    "constructor(address,address[],address[],uint256)" \
    $WORTH_TOKEN \
    "$POOL_STAKING_CONTRACTS" \
    "$PERIODICAL_STAKING_CONTRACTS" \
    $DEFAULT_REQUIRED_WORTH)
```

After deployment, run the migration from V1 (owner-only):

```bash
# clone staking arrays, periodical staking arrays, ERC1155 config, defaultRequiredWorth, worthToken
cast send <V2_ADDRESS> "cloneConfigFrom(address)" <V1_ADDRESS> \
  --rpc-url $POLYGON_RPC_URL --private-key $DEPLOYER_PRIVATE_KEY

# clone phase/period thresholds — supply the (phase, period) pairs scanned off-chain from V1's event log
cast send <V2_ADDRESS> "clonePhasePeriodRequirements(address,uint256[],uint256[])" \
  <V1_ADDRESS> '[1,2,3]' '[1,1,1]' \
  --rpc-url $POLYGON_RPC_URL --private-key $DEPLOYER_PRIVATE_KEY

# switch the periodical staking consumer to V2
cast send <CONSUMER_ADDRESS> "setRequirementChecker(address)" <V2_ADDRESS> \
  --rpc-url $POLYGON_RPC_URL --private-key $DEPLOYER_PRIVATE_KEY
```

## Dependencies

This project uses the Foundry framework with the OpenZeppelin contracts (v5.0.1) for enhanced security and standardized features. You need to install necessary dependencies.

You can install the OpenZeppelin contracts by running:

```bash
$ forge install --no-commit OpenZeppelin/openzeppelin-contracts@v5.0.1
```

## Known Issues

### removeStakingPeriod / popStakingPhase causes permanent deposit lockup — **fixed in v0.3.0**

> **Status:** affects v0.2.4 (`0xa816fC819c2BD73c0AEdf60E0b06daF2Bff9691F`) only. Fixed in v0.3.0: removal no longer touches accounting data, and `test/erc20-periodical-staking/period-removal/PeriodRemovalRegression.t.sol` reproduces the incident and guards against regression. The description below is kept as history for the v0.2.4 deployment.

After removing period 7 in production, all deposits in that period became permanently locked.

**Root cause:** The `phasePeriodDataList` and `userPhasePeriodDataList` tracking was added as a last-minute request to have the contract provide phase-period-level and user-phase-period-level data. The `userPhasePeriodDataList` in particular is purely informational and it is only written to read via view functions, never used in any conditional or control flow. Because this tracking was a late addition, no tests were added to cover the period/phase removal path with active tracking data, which led to the accounting inconsistency going unnoticed.

**What happens on removal:** `removeStakingPeriod` iterates over all phases and calls `_clearPhasePeriodData` and `_clearPhasePeriodUserData`, zeroing the per-period tracking data (`phasePeriodDataList[STAKED]`, `[APY]`, `[STAKING_TARGET]` and `userPhasePeriodDataList[STAKING]`, `[REWARD_EXPECTED]`, `[WITHDRAWAL]`, `[CLAIM]`) for the removed period. This means the per-period data is zeroed but the deposit data related to the removed phase/period still remains. When a user tries to claim or withdraw a deposit in the removed period, the flow subtracts from the zeroed per-period data, causing an underflow revert.

**Impact scope:**

- **Deposits in the removed period:** Permanently locked. Claim and withdraw revert with underflow. This is critical for any user who had active deposits in that period.
- **Deposits in other periods:** Fully functional. Stake, claim, and withdraw work normally because those per-period values were never touched.
- **`claimAll()`:** Also reverts when it hits a stuck deposit in the removed period, making it unusable for users with any deposit in that period.
- **`rewardPool`:** Unaffected, it only decreases when rewards are actually paid out, so remaining claims have sufficient funds.

**User impact by type:**

| User type                         | Effect                                                                      |
| --------------------------------- | --------------------------------------------------------------------------- |
| Staked only in removed period     | Total loss of that deposit                                                  |
| Staked in removed + other periods | Can claim/withdraw other periods normally; removed period deposit is locked |
| Never staked in removed period    | No impact                                                                   |

**Recovery:** The only way to unstick a deposit is to recreate the period with the exact same configuration, have the user stake the same amount again, and then claim the old deposit. Because the new stake repopulates the per-period tracking data, the old claim's subtractions no longer underflow. The user receives their old principal + reward back, but since they had to lock the same principal again in the new deposit, the net gain is only the old interest minus gas fees.

**Workaround (v0.2.4 deployment only):** Do NOT remove a staking period or pop a staking phase. Instead, set the staking target to 0 for the period you want to disable. On v0.3.0 removal is safe.

## RequirementChecker v2

The incident above exposed a gap in our tooling: once on-chain state had drifted from what a user was actually owed, we had no way to correct the worth the `RequirementChecker` reported. `RequirementCheckerV2` was built in response. It keeps the same aggregation surface (ERC20 balance + pool-based staking + periodical staking + ERC1155 NFT holdings) but adds a per-wallet signed admin offset on every source. An admin can credit or penalize a specific wallet's perceived worth — "treat this wallet as if it has 200 more staked in contract X" or "as if it holds 3 fewer NFTs of id Y" — without moving any real balances. Offsets are signed `int256` values and clamped at 0 per entity so a large negative offset cannot drag another source below zero.

V2 is a drop-in replacement through the shared `IRequirementChecker` interface; periodical staking contract admin switches the requirement checker by calling `setRequirementChecker(v2Address)`. V1 stays deployed and untouched. Two owner-only calls, `cloneConfigFrom` and `clonePhasePeriodRequirements`, migrate the V1 configuration (see the deployment steps above). V2 lives at `src/contracts/requirement-checker/v2/`.
