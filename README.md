# ERC20 Periodical Staking v0.2.4

## Deployment

- **v0.2.4**: `0xa816fC819c2BD73c0AEdf60E0b06daF2Bff9691F`

## Dependencies

This project uses the Foundry framework with the OpenZeppelin contracts (v5.0.1) for enhanced security and standardized features. You need to install necessary dependencies.

You can install the OpenZeppelin contracts by running:

```bash
$ forge install --no-commit OpenZeppelin/openzeppelin-contracts@v5.0.1
```

## Known Issues

### removeStakingPeriod / popStakingPhase causes permanent deposit lockup

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

**Workaround:** Do NOT remove a staking period or pop a staking phase. Instead, set the staking target to 0 for the period you want to disable.
