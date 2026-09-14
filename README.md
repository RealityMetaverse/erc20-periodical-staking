# ERC20 Periodical Staking v0.4.0

## Deployment

- **v0.4.0**: _not yet deployed_
- **v0.3.0**: _not yet deployed_
- **v0.2.4**: `0xa816fC819c2BD73c0AEdf60E0b06daF2Bff9691F` (affected by the period-removal lockup, see Known Issues)

## Changes in v0.4.0

v0.4.0 is a new immutable deployment of `src/contracts/erc20-periodical-staking/`, built on v0.3.0. Staking is only possible with a voucher signed by the backend, which decides eligibility (VIP level, whitelisting) before signing. The voucher can add an extra APY and an extra limit, both capped by maximums stored in the contract. The RequirementChecker hook and the whitelist are removed, APYs move to basis points, the LimitController also counts stake held in the v0.2.4 deployment, and admins/owner can freeze and seize deposits. Deposit storage is packed from 8 slots to 2.

**Voucher-only staking.** `safeStake` is removed. The only entry point is `stakeWithVoucher(StakeVoucher voucher, bytes signature, uint256 tokenAmount, uint256 expectedApyBps) returns (uint256 depositNumber)`. The voucher is EIP-712 typed data with domain `{ name: "ERC20PeriodicalStaking", version: "1", chainId, verifyingContract }` and type `StakeVoucher(address wallet,uint256 phase,uint256 period,uint256 extraApyBps,uint256 extraLimit,uint256 validUntil,uint256 nonce)`. Rules:

- the signature must come from `voucherSigner()`; it is checked with OpenZeppelin `SignatureChecker`, so an ERC-1271 contract signer works too;
- `voucher.wallet` must be `msg.sender` (`VoucherWalletMismatch`);
- `block.timestamp <= validUntil` — `validUntil` is inclusive unix seconds (`VoucherExpired`);
- the nonce is single-use per wallet and may be any `uint256`; used nonces are tracked in a per-wallet bitmap (`VoucherNonceUsed`);
- the voucher fixes the phase and period: the phase must be the current phase and the period must exist in it;
- `extraApyBps <= maxExtraApyBps()` and `extraLimit <= maxExtraLimit()` (`VoucherExtraApyTooHigh`, `VoucherExtraLimitTooHigh`);
- the effective APY is `baseApyBps + extraApyBps` and must be **at least** `expectedApyBps` (`ApyBelowExpected`). This floor replaces v0.3.0's exact-equality `PhasePeriodAPYChanged` front-running guard.

Checks run in this order: staking open → signer set → limit controller set → wallet → expiry → nonce → extra caps → signature → minimum deposit → phase → period → expected APY → staking target → wallet limit; then the nonce is marked, the deposit and reserved reward are written, `Stake` is emitted and the tokens are pulled last. The stake path is `nonReentrant`. Helper views for the backend signer: `getVoucherDigest(voucher)`, `isVoucherNonceUsed(wallet, nonce)`, `VOUCHER_TYPEHASH()`, `eip712Domain()`.

**Eligibility moved off-chain.** The RequirementChecker hook (`requirementChecker()`, `setRequirementChecker`, `checkIfUserMeetsRequirements`, `getPhasePeriodRequiredWorth`) and the whitelist (`whitelistEnabled()`, `isWhitelisted(address)`, `setWhitelistEnabled`, `setWhitelistAddress`, `setWhitelistAddresses`) are removed from the staking contract. The backend only issues vouchers to eligible wallets. A stake keeps the extras it was issued with even if the wallet's eligibility changes later. The RequirementChecker v1/v2 contracts themselves are unchanged.

**APY in basis points.** `10_000` = 100%, so fractional rates work (`225` = 2.25%). This covers `pushStakingPhase` / `addStakingPeriod` / `setPhasePeriodData` inputs, `getPhasePeriodData(APY, …)`, the APYs returned by `getProgramData`, the deposit's APY field, the `Stake` event, the second argument of `calculateReward` and indefinite-deposit accrual. A deposit stores its effective APY (base + extra) for its whole life; later base-rate changes do not affect it. A period exists in a phase exactly when its APY cell is non-zero (APY 0 is still rejected on write).

**Extras and their maximums.** New owner settings `setMaxExtraApyBps(uint256)` and `setMaxExtraLimit(uint256)`, with views `maxExtraApyBps()` (`uint32`) and `maxExtraLimit()` (`uint128`).

**Limits through the LimitController, including the v0.2.4 deployment.** A stake reverts `LimitControllerNotSet` when no controller is configured; v0.3.0's `address(0)` fallback (`target - staked`) is gone from the stake path. The staking contract makes one call, `getAllowedAndUsed(wallet, phase, period)`, and allows `tokenAmount <= allowed + voucher.extraLimit - used` (saturating at 0, `StakingLimitExceeded`).

The LimitController gains an optional `legacyStakingContract`, set with `setLegacyStakingContract(address)` (owner; `address(0)` disables it; rejects the staking contract's own address with `SameStakingAndLegacyContract`; emits `LegacyStakingContractSet`). `used` is the wallet's STAKING cell in the staking contract **plus** the same `(phase, period)` cell in the legacy contract. There is no remapping: a phase or period that does not exist in one of the contracts reads 0 there and never reverts, so phases and periods can change freely. `getUsed` is new; `getRemaining` / `getRemainingBatch` now subtract legacy stake; `getAllowed` / `getAllowedBatch` are unchanged and never include voucher extras. The explicit-zero wallet limit (`hasWalletLimit`) behaves as in v0.3.0. Note that if the legacy contract itself reverts on a read, stakes revert until the owner unsets it.

**Freeze, unfreeze and seize.**

- `freezeDeposit(address wallet, uint256 depositNumber)` / `freezeDeposits(address[], uint256[])` and `unfreezeDeposit` / `unfreezeDeposits` — admins (the owner counts as an admin). Only open deposits can be frozen (`DepositNotOpen`), and not twice (`DepositFrozen`). `isDepositFrozen(wallet, depositNumber)` reads the flag.
- A frozen deposit's `claimDeposit`, `withdrawDeposit` and `withdrawDepositPartial` revert `DepositFrozen`; `claimAll` and `claimRange` skip it and pay the rest; `checkClaimableDataFor` excludes it.
- `seizeDeposit(address wallet, uint256 depositNumber)` / `seizeDeposits(address[], uint256[])` — owner only. Requires a treasury (`setTreasury(address)`, `TreasuryNotSet`) and a frozen deposit (`DepositNotFrozen`). Only the principal goes to the treasury; no reward is ever paid out. A periodical deposit's reserved reward is released back to the pool (as with an early withdrawal), and an indefinite deposit's unpaid accrued reward stays in the pool, so the pool keeps serving other stakers. Rewards the wallet already claimed from an indefinite deposit are not taken back. `SeizeDeposit(wallet, depositNumber, treasury, principal)` is emitted.
- A seized deposit gets the new status `SEIZED` (`5`), is closed (cannot be claimed, withdrawn, frozen or seized again), and every counter updates exactly like a withdrawal, so the wallet's limit room frees up. Batch seizes are atomic and send a single transfer.

**Packed storage and leaner bookkeeping.** Deposits are stored in 2 slots instead of 8:

| Slot | Fields                                                                                                            |
| ---- | ----------------------------------------------------------------------------------------------------------------- |
| 0    | `uint128 amount`, `uint40 stakingStartDate`, `uint40 stakingEndDate`, `uint40 withdrawalDate`, `uint8 flags`      |
| 1    | `uint128 rewardGenerated`, `uint32 stakingPhase`, `uint32 stakingPeriod`, `uint32 apyBps`                          |

`getDeposit` and `getDepositsInRangeBy` still return the same 8 fields, but `APY` is now in basis points (a 14% deposit reads `1400`; v0.2.4 deposits stay in whole percent). Values that would not fit are rejected with `SafeCast` instead of being truncated. Only the STAKING per-user phase-period cell is still kept (the LimitController and seize need it): `getUserPhasePeriodData(Batch)` keep their selectors but accept only `DataType.STAKING` (`InvalidDataType` otherwise), and the public `userPhasePeriodDataList` getter is removed. `userDataList`, `totalDataList` and `stakerAddressList` are kept for the backend, frontend and RequirementChecker v2. Action availability is three packed booleans; `changeActionAvailability` accepts only STAKING, WITHDRAWAL and CLAIM. `currentStakingPhase()` and `stakingPhaseCount()` now return `uint32` and `minimumDeposit()` returns `uint128` (same ABI encoding).

**Gas.** Execution gas measured with an identical setup and a real LimitController:

| Action                               | v0.3.0  | v0.4.0  | Change |
| ------------------------------------ | ------- | ------- | ------ |
| Repeat stake into the same cell      | 267,934 | 170,765 | −36%   |
| First stake from a new wallet        | 380,816 | 283,695 | −25%   |
| Claim a matured periodical deposit   | 266,798 | 189,435 | −29%   |
| Withdraw a periodical deposit early  | 192,822 | 142,568 | −26%   |
| `claimAll` over 10 matured deposits  | 767,045 | 330,637 | −57%   |

Setting a legacy staking contract adds about 6.6k gas to each stake; claims and withdrawals are unaffected. Bytecode: `ERC20PeriodicalStaking` 23,438 bytes of runtime code (limit 24,576), `LimitController` 4,307 bytes.

**Read functions.** `getProgramData()` returns `(currentPhase, periods, targets, apysBps, staked)`; `getProgramDataWithUserData(address)` returns `(currentPhase, periods, targets, apysBps, staked, limits, remaining)`; `getPhasePeriodUserData` returns `(limits, remaining)`. Required worth and eligibility are gone. `limits` and `remaining` come from the LimitController, include legacy stake and exclude voucher extras.

**Events.** `Stake` is now `Stake(address indexed by, uint256 indexed stakingPhase, uint256 indexed stakingPeriod, uint256 apyBps, uint256 extraApyBps, uint256 tokenAmount, uint256 depositNumber, uint256 voucherNonce)` — its topic changes, so indexers must update.

New custom errors: `VoucherSignerNotSet`, `LimitControllerNotSet`, `TreasuryNotSet`, `InvalidVoucherSignature`, `VoucherWalletMismatch`, `VoucherExpired`, `VoucherNonceUsed`, `VoucherExtraApyTooHigh`, `VoucherExtraLimitTooHigh`, `ApyBelowExpected`, `DepositFrozen`, `DepositNotFrozen`, `DepositNotOpen`; LimitController: `SameStakingAndLegacyContract`.
Removed errors: `NotWhitelisted`, `RequirementNotMet`, `PhasePeriodAPYChanged`.
New events: `UpdateVoucherSigner`, `UpdateMaxExtraApyBps`, `UpdateMaxExtraLimit`, `UpdateTreasury`, `FreezeDeposit`, `UnfreezeDeposit`, `SeizeDeposit`; LimitController: `LegacyStakingContractSet`.
Removed events: `UpdateWhitelistStatus`, `UpdateWhitelist`, `UpdateRequirementChecker`.
New functions: `stakeWithVoucher`, `getVoucherDigest`, `isVoucherNonceUsed`, `VOUCHER_TYPEHASH`, `eip712Domain`, `setVoucherSigner`, `voucherSigner`, `setMaxExtraApyBps`, `maxExtraApyBps`, `setMaxExtraLimit`, `maxExtraLimit`, `setTreasury`, `treasury`, `freezeDeposit(s)`, `unfreezeDeposit(s)`, `seizeDeposit(s)`, `isDepositFrozen`; LimitController: `getAllowedAndUsed`, `getUsed`, `legacyStakingContract`, `setLegacyStakingContract`.
Removed functions: `safeStake`, `checkIfUserMeetsRequirements`, `checkIfUserExceedsLimit`, `getPhasePeriodRequiredWorth`, `requirementChecker`, `setRequirementChecker`, `whitelistEnabled`, `isWhitelisted`, `setWhitelistEnabled`, `setWhitelistAddress`, `setWhitelistAddresses`, the public `userPhasePeriodDataList` getter.

**Setting up a v0.4.0 deployment.**

1. Deploy `ERC20PeriodicalStaking(tokenAddress)`.
2. Deploy `LimitController(stakingAddress)`, set its default (and any wallet) limits, then `setLegacyStakingContract(0xa816fC819c2BD73c0AEdf60E0b06daF2Bff9691F)` on Polygon so v0.2.4 stake counts toward the same limits.
3. On the staking contract: `setLimitController`, `setVoucherSigner`, `setMaxExtraApyBps`, `setMaxExtraLimit`, `setTreasury`; configure periods and phases as before, **with APYs in basis points**; fund the pool with `provideReward`. Check that `limitController.stakingContract()` returns the new staking address; a controller built for another contract would silently stop enforcing wallet limits.
4. Add the new contract to RequirementCheckerV2 (`0x716ff1f64cC2B7c96ba9DDADfc08bB703F8bcA59` on Polygon) so its stake keeps counting toward wallet worth (backend VIP level 0, daily login and event worth checks). As the checker owner call `setPeriodicalStakingContracts([0x29cE6711fA6A8196D2b9538C5cE6293941e98749, 0xa816fC819c2BD73c0AEdf60E0b06daF2Bff9691F, <v0.4.0 address>])`. The setter replaces the whole list, so the two existing contracts must be passed again. Check that `periodicalStakingContractCount()` returns 3 and `periodicalStakingContracts(2)` is the new address. Do this before step 5.
5. Close v0.2.4 to new stakes with `changeActionAvailability(STAKING, false)`. Claims and withdrawals there stay open.

Unchanged from v0.3.0: reward-pool semantics (no pool check at stake time, reserved periodical rewards, `collectReward` bounds), `provideReward`, `rescueTokens`, two-step ownership, bounded `claimAll` / `claimRange`, flexible (period 0) staking, safe period/phase removal, compiler `0.8.20` with `via_ir`, OpenZeppelin v5.0.1, no proxy/upgradeability.

Tests: `test/v040/` covers vouchers (`Voucher.t.sol`), basis-point APYs and caps (`ApyBps.t.sol`), the LimitController with a legacy contract including the real vendored v0.2.4 contract (`LimitControllerLegacy.t.sol`), freeze and seize (`FreezeSeize.t.sol`) and gas budgets (`GasBudget.t.sol`); the existing suites are migrated to voucher staking and the invariant handler freezes and seizes. `RequirementCheckerV2Integration.t.sol` now uses the vendored v0.2.4 contract as its checker consumer, since v0.4.0 has no hook. Full suite: 688 passed, 0 failed, 1 skipped (the opt-in `LegacyStakingInvariants`).

**Gas snapshots.** `gas-snapshots/` holds one `forge snapshot` per released version from v0.2.3 through v0.4.0 (older versions cannot be rebuilt), each taken from that version's own code and tests; `gas-snapshots/README.md` lists the commits and the exact command.

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

# switch the periodical staking consumer to V2 (v0.2.4 / v0.3.0 only — v0.4.0 has no requirement checker hook)
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

From v0.4.0 the periodical staking contract no longer calls a requirement checker: eligibility is decided by the backend before it signs a stake voucher. RequirementChecker v1/v2 remain deployed and usable by the v0.2.4 / v0.3.0 staking contracts and by off-chain services. The backend's wallet-worth checks read RequirementCheckerV2, which only counts periodical stake in contracts on its `periodicalStakingContracts` list; v0.4.0 stake counts only after the contract is added there (step 4 of the v0.4.0 setup).
