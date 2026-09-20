# ERC20 Periodical Staking v0.5.0

## Deployment

- **v0.5.0**: _not yet deployed_ (current source; `VERSION()` returns `0.5.0`)
- **v0.4.0**: _not yet deployed on mainnet_ (an earlier build is on Amoy; its voucher has 7 fields and is NOT compatible)
- **v0.3.0**: _not yet deployed_
- **v0.2.4**: `0xa816fC819c2BD73c0AEdf60E0b06daF2Bff9691F` (affected by the period-removal lockup, see Known Issues)

## Changes in v0.5.0

v0.5.0 changes what the voucher's extra limit MEANS, adds an on-chain wallet block, bounds voucher lifetime, and publishes a version string. The voucher struct changes shape, so **every v0.4.0 voucher and signer is incompatible** - see the typehash below.

Three things a reader needs and cannot infer from the code:

- **The bonus is a metered BUDGET, not a per-stake grant.** In v0.4.0 the voucher's `extraLimit` was added to the wallet's limit on every stake, so the same bonus was handed out again in every period and again on every voucher. In v0.5.0 the contract meters what the wallet has actually spent above its controller limit and subtracts it, so re-presenting a voucher (or issuing a fresh one with the same numbers) grants nothing extra.
- **The total budget is GLOBAL - one per wallet, across every phase.** Advancing the phase does not refill it. It is concurrent, not lifetime: closing a deposit returns its bonus, so a wallet can spend its 50,000 many times over the programme's life but never hold more than 50,000 of bonus open at once.
- **A "cell" is a `(phase, period)` PAIR.** The same period in a different phase is a different cell with its own per-cell cap, exactly as the LimitController keys `allowed` and `used`. The per-cell cap stops a wallet concentrating its bonus into one period *within* a phase; spreading it across phases is deliberate, because a phase runs about a year, and the global total is the ceiling that spans them.

**The voucher gains a field and one is renamed.** `extraLimit` is gone. The EIP-712 type is now:

```
StakeVoucher(address wallet,uint256 phase,uint256 period,uint256 extraApyBps,uint256 extraLimitTotal,uint256 extraLimitPerCell,uint256 validUntil,uint256 nonce)
```

`keccak256` of that string is `0xa7048f901162583d7c998e76f924674fc01196a5a7a84f036f7db892508bd49b`, which is the value compiled into `VOUCHER_TYPEHASH()`. The domain is unchanged: `{ name: "ERC20PeriodicalStaking", version: "1", chainId, verifyingContract }` - the domain `version` is **not** a contract version and stays `"1"`. Field order is the encoding order; a tuple built in the old order produces a valid signature over the wrong digest and every stake reverts `InvalidVoucherSignature`. Check `VERSION()` before blaming the key.

- `extraLimitTotal` is the wallet's whole bonus budget, capped by `maxExtraLimitTotal()` (`VoucherExtraLimitTotalTooHigh`).
- `extraLimitPerCell` is how much of it may sit in any one cell, capped by the new `maxExtraLimitPerCell()` (`VoucherExtraLimitPerCellTooHigh`).

**The limit rule.** The contract reads `getAllowedAndUsed(wallet, phase, period)`, subtracts the bonus already metered in that cell from `used` to get the base-funded part, and allows `tokenAmount <= baseRoom + min(extraLimitTotal - usedTotal, extraLimitPerCell - usedInCell)` (saturating, `StakingLimitExceeded`). Whatever goes above `baseRoom` is charged to the meter and released when the deposit closes.

**Bonus is released on exactly three paths**, each using the deposit's own phase and period: `withdrawDeposit` / `withdrawDepositPartial`, the `READY_TO_CLAIM` branch of `claimDeposit` (and its batch forms), and `seizeDeposit`. An indefinite-deposit reward claim does **not** release, because it pays reward only and leaves the position open.

**Wallet block.** `setWalletBlocked(address, bool)` and `setWalletsBlocked(address[], bool)` (admins and owner) bar a wallet from opening NEW stakes; `walletBlocked(address)` reads the flag and `stakeWithVoucher` reverts `WalletBlocked`. It is checked first, before the nonce is consumed. **It gates staking only** - withdraw, claim, `claimAll`, `claimRange` and existing deposits are untouched, and a block never traps funds. It exists because it is the only lever that still works if the voucher signing key leaks: the attacker signs their own vouchers, so the backend's issuance blocklist never sees them.

Note this is separate from a LimitController wallet limit of `0`, which removes the wallet's BASE allowance only - a voucher bonus still stakes on top of it.

**Voucher validity ceiling.** `maxVoucherValidity()` (`uint32` seconds) bounds how far ahead `validUntil` may sit, measured from now, so a leaked signer key cannot mint vouchers good for years (`VoucherValidityTooLong`). `setMaxVoucherValidity(uint256)` rejects `0` (`ZeroAmountProvided`) - the protection has no off switch, lower it instead. The constructor defaults it to `1800`, the maximum the backend's own `validity_seconds` can be set to, so a contract deployed outside the script is still usable. The backend reads this ceiling and refuses to sign with a 503 rather than issuing a voucher that would revert.

**Version string.** `VERSION()` returns `"0.5.0"`. Read it at startup and refuse to run when it disagrees with the ABI you built against.

**New views.** `getBonusUsage(address wallet, uint256 phase, uint256 period)` returns `(uint256 usedTotal, uint256 usedInCell)`; `getBonusUsageBatch(address wallet, uint256 phase, uint256[] periods)` (on the **StakingLens**, see below) returns `(uint256 usedTotal, uint256[] usedPerCell)` so a whole period table costs one call. Both report USAGE, not remaining - the budget lives on the voucher. The two returns have different scopes: `usedTotal` is global and does not reset on a phase change, `usedInCell` is per cell and does.

**Contract size and the StakingLens.** With the v0.5.0 additions the staking contract's runtime code reached 25,533 bytes, 957 over the 24,576-byte EIP-170 limit, so it could not be deployed (`forge test` does not enforce that limit; `forge build --sizes` does). No optimizer setting closes the gap. Seven read-only views that only bundle other reads moved to a separate contract, `src/contracts/erc20-periodical-staking/StakingLens.sol`: `getProgramDataWithUserData`, `getPhasePeriodUserData`, `getDepositsInRangeBy`, `getPhasePeriodDataAll`, `getRewardRequiredForTargets`, `getRewardPoolShortfall`, `getBonusUsageBatch`. Names, arguments and return shapes are unchanged - a caller swaps only the address and ABI for these calls. The staking contract is now 23,075 bytes (1,501 spare) and the lens 5,654. No state-changing code moved. `getUserPhasePeriodDataBatch` stays on the staking contract because the LimitController calls it on-chain; `checkTotalClaimableData` stays because it walks the internal staker list.

The lens is bound to one staking contract (`STAKING()`), has no owner, storage or privileges, and only calls public getters, so anyone can deploy or replace it. The `deploy-v050` rpc alias reads `RPC_URL` from `deploy/v050/<network>.env`, not from your shell, so load that file in a subshell: `( set -a; . deploy/v050/<network>.env; set +a; STAKING=<staking address> forge script script/DeployLens.s.sol --rpc-url deploy-v050 --account <KEYSTORE_ACCOUNT> --sender <DEPLOYER_ADDRESS> --broadcast --slow )` (add `--verify` when `ETHERSCAN_API_KEY` is set in that file). Deploy it right after the staking contract and give its address to the frontend; it is manual step 4 below and in the script's own output.

Two wrappers do this with the same env file as `deploy-v050.sh` (the RPC URL never enters your shell): `./script/deploy-lens-v050.sh <polygon|amoy> <staking address> [--broadcast]` simulates by default, retries a simulation when a public RPC drops a request, and never retries a broadcast. `./script/verify-lens-v050.sh <polygon|amoy>` verifies the deployed lens on the explorer and sends no transaction. It exists because with `via_ir` solc 0.8.20 generates slightly different code for the same source depending on which files are compiled in the same batch: `forge script` compiles the lens together with `DeployLens.s.sol`, while `--verify` / `forge verify-contract` send only the lens's own imports, so the explorer's rebuild fails with "bytecode does NOT match". The script rebuilds the exact batch of the deploy, checks locally that it reproduces the bytes that were sent on chain, and only then submits that input.

New functions: `setMaxExtraLimitPerCell`, `maxExtraLimitPerCell`, `setMaxVoucherValidity`, `maxVoucherValidity`, `setWalletBlocked`, `setWalletsBlocked`, `walletBlocked`, `getBonusUsage`, `VERSION`; on the lens: `getBonusUsageBatch`.
New events: `UpdateMaxExtraLimitPerCell`, `UpdateMaxVoucherValidity`, `UpdateWalletBlocked`, `BonusConsumed(wallet, phase, period, depositNumber, amount)`, `BonusReleased(wallet, phase, period, depositNumber, amount)`.
New errors: `VoucherExtraLimitPerCellTooHigh`, `VoucherValidityTooLong`, `WalletBlocked`.
Unchanged: the `Stake` event signature, so indexers do not need to change for it.

**Renamed, so the ceilings read like the voucher fields they cap** (`extraLimitTotal` / `extraLimitPerCell`): `maxExtraLimit()` -> `maxExtraLimitTotal()`, `setMaxExtraLimit` -> `setMaxExtraLimitTotal`, event `UpdateMaxExtraLimit` -> `UpdateMaxExtraLimitTotal`, error `VoucherExtraLimitTooHigh(extraLimit, maxExtraLimit)` -> `VoucherExtraLimitTotalTooHigh(extraLimitTotal, maxExtraLimitTotal)`, env var `MAX_EXTRA_LIMIT` -> `MAX_EXTRA_LIMIT_TOTAL`. The deploy tooling is now `script/DeployV050.s.sol`, `script/deploy-v050.sh`, `script/verify-v050.sh` and `deploy/v050/`. The v0.4.0 section below keeps the old names on purpose: that is what a v0.4.0 contract exposes.

Deployment adds two required env vars, `MAX_EXTRA_LIMIT_PER_CELL` and `MAX_VOUCHER_VALIDITY`; both are read back and asserted after deploy, and `deploy-v050.sh` refuses a per-cell ceiling of 0 alongside a non-zero total, which would silently disable the bonus.

## Changes in v0.4.0

v0.4.0 is a new immutable deployment of `src/contracts/erc20-periodical-staking/`, built on v0.3.0. Staking is only possible with a voucher signed by the backend, which decides eligibility (VIP level, whitelisting) before signing. The voucher can add an extra APY and an extra limit, both capped by maximums stored in the contract. The RequirementChecker hook and the whitelist are removed, APYs move to basis points, the LimitController also counts stake held in the v0.2.4 deployment, and admins/owner can freeze and seize deposits. Deposit storage is packed from 8 slots to 2.

**Voucher-only staking.** `safeStake` is removed. The only entry point is `stakeWithVoucher(StakeVoucher voucher, bytes signature, uint256 tokenAmount, uint256 expectedApyBps) returns (uint256 depositNumber)`. The voucher is EIP-712 typed data with domain `{ name: "ERC20PeriodicalStaking", version: "1", chainId, verifyingContract }` and type `StakeVoucher(address wallet,uint256 phase,uint256 period,uint256 extraApyBps,uint256 extraLimit,uint256 validUntil,uint256 nonce)` - **superseded in v0.5.0, which renamed `extraLimit` and added `extraLimitPerCell`; use the 8-field type above**. Rules:

- the signature must come from `voucherSigner()`; it is checked with OpenZeppelin `SignatureChecker`, so an ERC-1271 contract signer works too;
- `voucher.wallet` must be `msg.sender` (`VoucherWalletMismatch`);
- `block.timestamp <= validUntil` — `validUntil` is inclusive unix seconds (`VoucherExpired`);
- the nonce is single-use per wallet and may be any `uint256`; used nonces are tracked in a per-wallet bitmap (`VoucherNonceUsed`);
- the voucher fixes the phase and period: the phase must be the current phase and the period must exist in it;
- `extraApyBps <= maxExtraApyBps()` and `extraLimit <= maxExtraLimit()` (`VoucherExtraApyTooHigh`, `VoucherExtraLimitTooHigh`) - in v0.5.0 this is `extraLimitTotal`, plus a per-cell cap;
- the effective APY is `baseApyBps + extraApyBps` and must be **at least** `expectedApyBps` (`ApyBelowExpected`). This floor replaces v0.3.0's exact-equality `PhasePeriodAPYChanged` front-running guard.

Checks run in this order: staking open → signer set → limit controller set → wallet → expiry → nonce → extra caps → signature → minimum deposit → phase → period → expected APY → staking target → wallet limit; then the nonce is marked, the deposit and reserved reward are written, `Stake` is emitted and the tokens are pulled last. The stake path is `nonReentrant`. Helper views for the backend signer: `getVoucherDigest(voucher)`, `isVoucherNonceUsed(wallet, nonce)`, `VOUCHER_TYPEHASH()`, `eip712Domain()`.

**Eligibility moved off-chain.** The RequirementChecker hook (`requirementChecker()`, `setRequirementChecker`, `checkIfUserMeetsRequirements`, `getPhasePeriodRequiredWorth`) and the whitelist (`whitelistEnabled()`, `isWhitelisted(address)`, `setWhitelistEnabled`, `setWhitelistAddress`, `setWhitelistAddresses`) are removed from the staking contract. The backend only issues vouchers to eligible wallets. A stake keeps the extras it was issued with even if the wallet's eligibility changes later. The RequirementChecker v1/v2 contracts themselves are unchanged.

**APY in basis points.** `10_000` = 100%, so fractional rates work (`225` = 2.25%). This covers `pushStakingPhase` / `addStakingPeriod` / `setPhasePeriodData` inputs, `getPhasePeriodData(APY, …)`, the APYs returned by `getProgramData`, the deposit's APY field, the `Stake` event, the second argument of `calculateReward` and indefinite-deposit accrual. A deposit stores its effective APY (base + extra) for its whole life; later base-rate changes do not affect it. A period exists in a phase exactly when its APY cell is non-zero (APY 0 is still rejected on write).

**Extras and their maximums.** New owner settings `setMaxExtraApyBps(uint256)` and `setMaxExtraLimit(uint256)`, with views `maxExtraApyBps()` (`uint32`) and `maxExtraLimit()` (`uint128`). v0.5.0 adds `setMaxExtraLimitPerCell` / `maxExtraLimitPerCell` and `setMaxVoucherValidity` / `maxVoucherValidity`. Lowering any of these caps NEW vouchers only; bonus already held open is never clawed back.

**Limits through the LimitController, including the v0.2.4 deployment.** A stake reverts `LimitControllerNotSet` when no controller is configured; v0.3.0's `address(0)` fallback (`target - staked`) is gone from the stake path. The staking contract makes one call, `getAllowedAndUsed(wallet, phase, period)`, and allows `tokenAmount <= allowed + voucher.extraLimit - used` (saturating at 0, `StakingLimitExceeded`). **v0.5.0 replaces this rule** - the extra is a metered budget, not an addition to the limit; see Changes in v0.5.0.

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

#### Deploying v0.5.0 with DeployV050.s.sol

`script/DeployV050.s.sol` does steps 1–3 as a like-for-like copy of **the same network's** v0.2.4 contract: it reads the program from chain, deploys `ERC20PeriodicalStaking(sourceToken)` and `LimitController(staking)`, applies the copy, then re-reads every value from the new contracts and `require`s it equals the source.

Source resolution (per `block.chainid`, nothing is taken from another network):

| Chain | Source staking (v0.2.4, `PERIODIC_STAKING_2`) | RequirementCheckerV2 (manual step only) |
| ----- | --------------------------------------------- | --------------------------------------- |
| 137 Polygon | `0xa816fC819c2BD73c0AEdf60E0b06daF2Bff9691F` | `0x716ff1f64cC2B7c96ba9DDADfc08bB703F8bcA59` |
| 80002 Amoy | `0x0d8ab209583050A9959322229A7c314c66e40E6f` | `0x3D55e53835e90149BCe416881b4b677EB107d4e3` |

The checker column is the worth-aggregating RequirementCheckerV2 the backend reads (`REQUIREMENT_CHECKER_V2` in the backend network JSON), not the source's own `requirementChecker()` hook (on Amoy that is `0xE751c4D2dDa2bfc8fB501BAf1369548701e0F76B`, logged for information only; v0.4.0 has no hook). When the source is not on that checker's current list, the script prints a note with the manual step. Another v0.2.4-shaped Amoy contract, `0x433F493D87e55781D0bEbD85481e4d691819f69a`, can be copied instead with `SOURCE_STAKING=0x433F493D87e55781D0bEbD85481e4d691819f69a`.

`SOURCE_STAKING` overrides the table; on any other chain it is required (the script reverts without it). The source must be v0.2.4-shaped (no `pendingOwner`, has `whitelistEnabled` and `getUserPhasePeriodDataBatch`), otherwise the script reverts, because the percent→bps conversion only holds for v0.2.4. The token comes from the source's `STAKING_TOKEN()`, the source LimitController from its `limitController()` getter, and the same source address becomes the new controller's `legacyStakingContract`. `REQUIREMENT_CHECKER_V2` overrides the checker table; its current periodical list is read live to print the replacement list.

What it copies from the source: the staking token; every period (added before any phase); every phase with APY per phase×period converted from whole percent to bps (`× 100`, checked so `apyBps + MAX_EXTRA_APY_BPS` fits the deposit's `uint32`) and the staking target per phase×period; the current phase; the minimum deposit; and, from the LimitController v0.2.4 points to (`limitController()`), the default limit for every configured phase×period. The new controller gets `setLegacyStakingContract(source)` so stake in the source counts toward the same limits. If the source's controller was built for a different staking contract (its `stakingContract()` is not the source, as on Amoy), the defaults are still copied and a warning is logged.

What it does not copy, and logs: contract admins (a mapping, not enumerable: pass `ADMINS`); per-wallet limits (a mapping on the old controller, not enumerable: pass `WALLET_LIMITS_FILE`); controller defaults for cells outside the current config (for example the removed period 7); `requirementChecker` and the whitelist (removed in v0.4.0); the reward pool and all deposits/accounting.

Action availability: staking on the new contract is closed right after deployment unless `OPEN_STAKING=true`; withdrawal and claim stay open.

Settings live in one env file per network, never in the shell:

```bash
cp deploy/v050/amoy.env.example deploy/v050/amoy.env   # or polygon.env.example -> polygon.env
# fill in RPC_URL, VOUCHER_SIGNER, TREASURY, MAX_EXTRA_APY_BPS, MAX_EXTRA_LIMIT_TOTAL, DEPLOYER_ADDRESS, DEPLOYER_ACCOUNT
./script/deploy-v050.sh amoy               # simulate (default, no transactions)
./script/deploy-v050.sh amoy --broadcast   # send
```

`deploy/v050/example.env` documents every variable, grouped into required and optional. The per-network `.env.example` files already hold that network's `SOURCE_STAKING` and `REQUIREMENT_CHECKER_V2`. Filled-in `deploy/v050/*.env` files are git-ignored.

Required: `VOUCHER_SIGNER` (backend voucher signer), `TREASURY` (receiver of seized principal), `MAX_EXTRA_APY_BPS` (e.g. 500 = 5.00%), `MAX_EXTRA_LIMIT_TOTAL` (token wei). Optional: `NEW_OWNER` (staking: two-step transfer, NEW_OWNER must `acceptOwnership`; LimitController: OpenZeppelin `Ownable`, transferred immediately), `ADMINS` (comma-separated), `OPEN_STAKING` (default false), `REWARD_TOP_UP` (default 0 = no funding; >0 = approve + `provideReward` from the deployer), `WALLET_LIMITS_FILE`, `SOURCE_STAKING` and `REQUIREMENT_CHECKER_V2` (default: the per-chain table above).

`script/deploy-v050.sh <polygon|amoy> [--broadcast]`:

- refuses to run when a repo-root `.env` defines any variable this deployment reads (`SOURCE_STAKING`, `REQUIREMENT_CHECKER_V2`, `VOUCHER_SIGNER`, `TREASURY`, `MAX_EXTRA_APY_BPS`, `MAX_EXTRA_LIMIT_TOTAL`, `NEW_OWNER`, `ADMINS`, `OPEN_STAKING`, `REWARD_TOP_UP`, `WALLET_LIMITS_FILE`, `PRIVATE_KEY`, `RPC_URL`, `ETHERSCAN_API_KEY`, or any `ETH_*` / `FOUNDRY_*`), `export NAME=` lines included, and names them. forge auto-loads that file, so it could otherwise fill values the network env file leaves empty. A root `.env` that defines none of them only gets a warning;
- loads only `deploy/v050/<network>.env` (`set -a; source; set +a`) and fails with the `cp` command if it is missing;
- rejects placeholders and malformed addresses, numbers, `ADMINS` entries and keys; `WALLET_LIMITS_FILE` must be an existing file under `deploy/v050/`;
- checks `cast chain-id` of `RPC_URL` against the network (polygon 137, amoy 80002);
- exports every variable the script reads, including empty ones. The script treats an empty value as unset and uses the default, so an empty `NEW_OWNER=` really means "keep the deployer";
- prints the settings as the script resolves them (the RPC as host only), then runs `forge script script/DeployV050.s.sol --rpc-url deploy-v050`. The script prints its own resolved settings under `=== DeployV050: source (v0.2.4) ===`: compare them with the banner and stop if anything differs.

Secrets stay out of forge's command line (visible in `ps`): the RPC URL goes through the `deploy-v050` alias in `foundry.toml` (`[rpc_endpoints] deploy-v050 = "${RPC_URL}"`) and reaches `cast chain-id` as `ETH_RPC_URL`; the verification key is exported as `ETHERSCAN_API_KEY` for forge to read; a `PRIVATE_KEY` is exported to the script, which calls `vm.startBroadcast(PRIVATE_KEY)` (and checks it matches `DEPLOYER_ADDRESS` when that is set).

Without `--broadcast` the run is a simulation. With `--broadcast` it signs with the Foundry keystore account (`--account "$DEPLOYER_ACCOUNT" --sender "$DEPLOYER_ADDRESS"`, created with `cast wallet import <name> --interactive`), and adds `--verify` when `ETHERSCAN_API_KEY` (or `POLYGONSCAN_API_KEY`) is set. A `PRIVATE_KEY` in the env file is accepted as a fallback but never printed or passed as a flag; with both set the keystore wins. Extra forge flags go in `FORGE_ARGS` (quoted); a flag named there is not added again by the wrapper, so `FORGE_ARGS` also overrides the robustness defaults below.

#### Why the first Amoy broadcast ran out of gas

The first real Amoy broadcast (chain 80002) deployed both contracts but **4 of its 20 transactions failed with out-of-gas**: both `pushStakingPhase` calls and the `addStakingPeriod` calls for periods 5 and 6. The deployment was discarded. One failure is documented in full: `0xb077fe2e4c31369f6a7953108286737ebede5aea29dfe80bfc49fd76fd22610f` (`pushStakingPhase`) was broadcast with a **39,273** gas limit and consumed all of it, while replaying it with `cast run` against full block state needs **418,529**.

The two calls whose cost is not constant are exactly the two that failed:

- `addStakingPeriod` pushes onto `stakingPeriodList` and then calls `sortStorage()` on it, so each additional period costs more than the last;
- `pushStakingPhase` writes two storage slots (APY and staking target) **per period**, so its cost is zero-ish with no periods configured and ~418k with eight.

A gas limit of 39,273 is what `pushStakingPhase` costs when `stakingPeriodList` is **empty**. That number can only be produced by estimating the call against a state in which the `addStakingPeriod` transactions had not landed yet — the run broadcast its transactions without waiting for receipts, so the later estimates were made against stale state, and forge's default 130% multiplier is nowhere near enough to absorb a 10× error.

The wrapper now always passes, and prints in its banner:

| Flag | Why |
| ---- | --- |
| `--slow` | Send one transaction, wait for its receipt, only then estimate and send the next. This is the actual fix: every estimate is made against the state the previous transactions left behind. |
| `--isolate` | Simulate every top-level call in its own EVM context, so warm storage slots and accounts cannot carry across calls that become separate transactions on chain. Measured on forks of both networks this changed nothing (`pushStakingPhase` estimated at 444,698 gas with and without it), so it is defence in depth, not the fix — it removes one way the simulation could differ from the chain, at no cost. |
| `--gas-estimate-multiplier` | Headroom on top of the estimate. Default raised from forge's 130 to **200** (`GAS_ESTIMATE_MULTIPLIER`). |
| `--rpc-timeout` | Seconds per RPC request, default 120 (`RPC_TIMEOUT`); forge's own default of 45 is optimistic for flaky public endpoints. |
| `--timeout` | Seconds to wait for a sent transaction's receipt, default 600 (`TX_TIMEOUT`), `--broadcast` only. |
| `--retries` / `--delay` | Default 10 attempts, 15s apart (`VERIFY_RETRIES` / `VERIFY_DELAY`), only when a verification key is set. **In forge 1.7.1 these are contract-verification retries; they do not retry RPC calls** — there is no RPC-level retry flag for `forge script`, which is why the timeouts above carry that job. |

**Why 200%.** Measured on an Amoy fork, the per-period cost of `addStakingPeriod` grows from 53,690 (first period) to 74,643 (eighth), a factor of 1.39 across one run, and `pushStakingPhase` is the call whose cost scales with everything added before it. 200% absorbs a 2× underestimate; anything larger mainly inflates the "amount required" preflight. Unspent gas is refunded, so headroom costs nothing when it is not used — only the gas actually burnt is paid for.

**What was and was not reproduced.** The fix is verified end to end: against anvil forks of Amoy and Polygon the wrapper completes with every transaction succeeding and the self-check passing. The original underestimation itself could **not** be reproduced locally. On a fork, forge derives each limit from the script simulation and those numbers are accurate — `pushStakingPhase` estimated 444,698 against 418,541 actually used — and the run succeeds even with the old flags, with instant mining and with a 2s block time alike. So the stale-state explanation above is the reading most consistent with the evidence (a 39,273 limit is the cost of `pushStakingPhase` over an empty period list, which no simulation of this script produces), but it is a hypothesis about that specific live run, not something reproduced here. `--slow` makes the ordering assumption unnecessary either way, and the 200% headroom covers an underestimate of the size actually observed on chain.

**Transaction count was left alone.** The contract offers no batch setter: `addStakingPeriod(period, apyPerPhase[], targetPerPhase[])` and `pushStakingPhase(apyPerPeriod[], targetPerPeriod[])` each configure one period or one phase, so 8 periods + 2 phases is 10 transactions either way. Pushing phase 0 early and passing per-phase arrays to each `addStakingPeriod` does not reduce the count, makes every period add write two extra cells, and gives up the "all periods exist before any phase is pushed" property the self-check relies on. The ordering is unchanged and the fix is in the gas accounting.

#### Resuming a broadcast that died partway

The deployment is **idempotent**. Every step in `_deployAndConfigure` is guarded by a read of the target contract, so re-running it against a half-configured deployment sends only the transactions that are still missing and ends in the same full self-check. Set the two addresses in `deploy/v050/<network>.env` and run the same command again:

```bash
RESUME_STAKING=0x…      # the ERC20PeriodicalStaking the failed run deployed
RESUME_CONTROLLER=0x…   # the LimitController, if it got that far (omit if it did not)
./script/deploy-v050.sh amoy --broadcast
```

Both addresses are printed by the failed run and are in `broadcast/DeployV050.s.sol/<chainid>/run-latest.json` as the `contractAddress` of the two `CREATE` entries. `RESUME_CONTROLLER` without `RESUME_STAKING` is rejected. Before doing anything the script checks that `RESUME_STAKING` has code, uses the same staking token as the source and is still owned by the deployer, that it does not have more phases than the source, and that `RESUME_CONTROLLER` was built for that staking contract and is still owned by the deployer.

What a resume skips: any setting that already holds the right value, any period that already exists, any phase already pushed, any controller default or wallet limit already correct, any admin already added, and `REWARD_TOP_UP` when the pool is already non-empty (so a resume can never fund twice). Missing periods are added first — with one array entry per phase that already exists, which is what `addStakingPeriod` requires once phases are present — and the remaining phases are pushed afterwards, so the two orders converge on the same configuration. Ownership transfer stays last and is skipped when it already happened.

Limits worth knowing: a resume must run **before** `NEW_OWNER` calls `acceptOwnership()` (and before the LimitController is handed over), because it still needs owner rights on both contracts; if a phase was pushed while periods were missing, the phase's cells for those periods are wrong, the self-check fails loudly and the right answer is a fresh deployment, not a resume.

**Why not `forge script --resume`.** `--resume` does not re-simulate and requires the deployer's nonce to be exactly what it was, and it only resubmits transactions it considers unsent. The failure this is meant to recover from is an out-of-gas transaction, which *is* mined: it consumes its nonce and moves the account on. `--resume` cannot put that back, so it does not cover this case. The idempotent path does, and it ends in the same verified state rather than trusting a replayed transaction list.

#### Verifying an existing deployment

`script/deploy-v050.sh` verifies automatically: it adds `--verify` to the broadcast whenever `ETHERSCAN_API_KEY` (or `POLYGONSCAN_API_KEY`) is set in the env file. **If that line is commented out, the deployment lands unverified** — which is what happened to the first Amoy v0.4.0 deployment. Set the key before broadcasting and there is no second step.

For a deployment that is already on chain, `script/verify-v050.sh <polygon|amoy>` verifies the pair after the fact. It sends no transactions and uses the same env-file flow as the deploy wrapper: only `deploy/v050/<network>.env` is read, a root `.env` that could override it is refused, placeholders are rejected, and `cast chain-id` must match the network.

```bash
# deploy/v050/amoy.env: uncomment ETHERSCAN_API_KEY= and put the key after the '='
./script/verify-v050.sh amoy
```

Addresses are resolved in this order, and the one used is printed as `addresses from`:

1. `VERIFY_STAKING` / `VERIFY_CONTROLLER` from the env file, when set;
2. otherwise the two `CREATE` entries in `broadcast/DeployV050.s.sol/<chainid>/run-latest.json` (the earlier v0.4.0 Amoy pair, `0x792eb1B14F9f4ea94D5893064E256012839eCBA9` and `0x1883729ca8ea466806dd1d9059612f89955ddF89`, sits under `broadcast/DeployV040.s.sol/` and is not what this reads);
3. otherwise it stops and tells you which two variables to set.

A run in which only the staking contract is known is accepted; the summary then says the LimitController was not verified and names the variable to set.

**Constructor arguments are read from the chain, never guessed.** `ERC20PeriodicalStaking(address tokenAddress)` gets its argument from the deployed contract's own `STAKING_TOKEN()`, and `LimitController(address _stakingContract)` from its own `stakingContract()`; both are then ABI-encoded with `cast abi-encode`. Before verifying, the controller's `stakingContract()` must equal the staking address being verified — if it does not, the script stops rather than submit an argument that cannot match the creation code. Both addresses are also checked to actually hold code.

Verification runs `forge verify-contract --chain <id> --verifier etherscan --watch` (the default verifier is Sourcify, so Etherscan is selected explicitly), with `--retries` / `--delay` from `VERIFY_RETRIES` / `VERIFY_DELAY` — the same variables and defaults (10 attempts, 15s) the deploy wrapper uses. A contract the explorer already reports as verified is reported as `already verified (skipped)` and does not fail the run. The key travels as `ETHERSCAN_API_KEY` in the environment and the RPC URL as `ETH_RPC_URL`, so neither appears in `ps`. A submission that was accepted but is still pending can be polled with `./script/verify-v050.sh <network> --guid <GUID>`, which wraps `forge verify-check`.

`foundry.toml` lets Solidity read only `deploy/v050/` and `test/v050/fixtures/`, so keep the wallet-limits CSV in `deploy/v050/`.

`WALLET_LIMITS_FILE` is CSV, one `wallet,phase,period,limit` per line (limit in token wei; blank lines, `#` comments and a `wallet,...` header are ignored). Build it from the old controller's `WalletLimitSet(address indexed wallet, uint256 phase, uint256 period, uint256 limit)` events, keeping the latest value per wallet/phase/period (a free RPC tier may cap log ranges; use an explorer export or a paid RPC). The script checks every row against `walletPhasePeriodLimit` on the old controller and reverts on a mismatch. Rows with limit `0` are dropped: on the v0.2.4-era controller 0 means "use the default", while on the new controller `setWalletLimit(…, 0)` removes the wallet's BASE allowance (`hasWalletLimit`). That is not a block - a voucher bonus still stakes on top of it, and blocking outright is `setWalletBlocked` on the staking contract.

The equivalent raw forge calls, if the wrapper cannot be used. Export the variables by hand first (`RPC_URL`, the settings, `ETHERSCAN_API_KEY` for `--verify`), and make sure no root `.env` defines any of them:

```bash
forge script script/DeployV050.s.sol --rpc-url deploy-v050 --sender <DEPLOYER_ADDRESS>                 # simulate
forge script script/DeployV050.s.sol --rpc-url deploy-v050 --account <KEYSTORE_ACCOUNT> --sender <DEPLOYER_ADDRESS> \
  --broadcast --verify                                                                                  # send
```

What it logs: the source config and old controller (owner, target), the inputs, the list of what was not copied, a self-check table (`phase P period Nd: APY x% -> y bps | target a -> b`, default limit old -> new, minimum deposit, current phase, availability, admins, wallet-limit count), the deployed addresses and the remaining manual steps:

1. That network's RequirementCheckerV2 owner: `setPeriodicalStakingContracts(<current list read live> + <new staking address>)`, then check the new count (on Polygon: `[0x29cE6711fA6A8196D2b9538C5cE6293941e98749, 0xa816fC819c2BD73c0AEdf60E0b06daF2Bff9691F, <v0.4.0 address>]`, count 3). A note is printed when the source itself is not on the list.
2. Fund the reward pool with `provideReward` (unless `REWARD_TOP_UP` did).
3. In the backend `pawnshop/networks/<chainid>.json` set `CONTRACTS.PERIODIC_STAKING_V050.ADDRESS = <staking>` and `DEPLOYMENT_BLOCK = <block>`. The script prints the block number from just before its first transaction, a safe lower bound. The exact block is the `blockNumber` of the receipt whose `contractAddress` is the staking contract in `broadcast/DeployV050.s.sol/<chainid>/run-latest.json`.
   **Only a backend build that reads `PERIODIC_STAKING_V050` picks this up.** Older builds read `PERIODIC_STAKING_V040`, silently ignore a `V050` block and keep signing vouchers for the old contract, so every stake on the new one reverts `InvalidVoucherSignature`.
4. Deploy the `StakingLens` for the new staking contract (`./script/deploy-lens-v050.sh <network> <staking address> --broadcast`, then `./script/verify-lens-v050.sh <network>` if the explorer reports a bytecode mismatch; details in "Contract size and the StakingLens" above) and give its address to the frontend. The frontend reads `getProgramDataWithUserData`, `getDepositsInRangeBy` and `getBonusUsageBatch` from the lens; without it the staking page shows no data.
5. Source owner: `changeActionAvailability(STAKING, false)` on the source.
6. `NEW_OWNER`: `acceptOwnership()` on the staking contract.
7. When ready: `changeActionAvailability(STAKING, true)` on the new contract.

`test/v050/DeployV050Fork.t.sol` runs the same deployment against a fork of whichever network the RPC points at (opt-in: `FORK_RPC_URL`, falling back to `POLYGON_RPC_URL`; optionally `FORK_BLOCK` and `SOURCE_STAKING`; skipped otherwise). It checks the copy against that network's live source, that source stake shows up in `LimitController.getUsed` (a real staker on Polygon; on networks without a known staker it creates legacy stake on the fork), and a voucher stake end to end. `test/v050/DeployV050ForkWalletLimits.t.sol` (same opt-in) has the old controller's owner set wallet limits on the fork, loads them from `test/v050/fixtures/wallet-limits-crlf.csv` (CRLF line endings, a header, a `#` comment, a blank line and a limit-0 row; `.gitattributes` keeps the CRLF), deploys, and checks the new controller's `getAllowed` equals the old one's for every row, that the limit-0 wallet has no `hasWalletLimit`, and that `wallet-limits-mismatch.csv` reverts with the mismatch message.

Unchanged from v0.3.0: reward-pool semantics (no pool check at stake time, reserved periodical rewards, `collectReward` bounds), `provideReward`, `rescueTokens`, two-step ownership, bounded `claimAll` / `claimRange`, flexible (period 0) staking, safe period/phase removal, compiler `0.8.20` with `via_ir`, OpenZeppelin v5.0.1, no proxy/upgradeability.

Tests: `test/v050/` covers vouchers (`Voucher.t.sol`), basis-point APYs and caps (`ApyBps.t.sol`), the LimitController with a legacy contract including the real vendored v0.2.4 contract (`LimitControllerLegacy.t.sol`), freeze and seize (`FreezeSeize.t.sol`) and gas budgets (`GasBudget.t.sol`); the existing suites are migrated to voucher staking and the invariant handler freezes and seizes. `RequirementCheckerV2Integration.t.sol` now uses the vendored v0.2.4 contract as its checker consumer, since v0.4.0 has no hook. Full suite: 688 passed, 0 failed, 1 skipped (the opt-in `LegacyStakingInvariants`).

**Gas snapshots.** `gas-snapshots/` holds one `forge snapshot` per released version from v0.2.3 through v0.5.0 (older versions cannot be rebuilt), each taken from that version's own code and tests; `gas-snapshots/README.md` lists the commits and the exact command.

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

## Running the tests

The contract itself builds in under a minute. The test suite is the slow part: compiling all 85 test files takes
about 29 minutes (one `solc` process, `via_ir`) and the 32 invariant campaigns run for about 13 more. So there are
two ways to run it:

```bash
# Day to day: one test file. Compiles only that file and its imports (1-2.5 min the first time, seconds after).
$ forge test --match-path test/v050/Voucher.t.sol

# Everything except the invariant campaigns (the first build is still long; later runs are incremental).
$ forge test

# The full run: every test file and all invariant campaigns at full depth. About 45 minutes from a clean tree.
$ FOUNDRY_PROFILE=full forge test
```

A green `forge test` on the default profile does **not** include the invariant campaigns. The full run happens in CI
(`.github/workflows/full-check.yml`) on every pull request to `main`. Compiler settings are the same in both
profiles, so the deployed bytecode does not depend on which one you use.

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
