# ERC20 Periodical Staking v0.2.4

## Deployment

- **v0.2.4**: `0xa816fC819c2BD73c0AEdf60E0b06daF2Bff9691F`

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

**Recovery:** The only way to unstick a deposit is to recreate the period with the exact same configuration, have the user stake the same amount again, and then claim the old deposit. Because the new stake repopulates the per-period tracking data, the old claim's subtractions no longer underflow. The user receives their old principal + reward back, but since they had to lock the same principal again in the new deposit, the net gain is only the old interest minus gas fees.

**Workaround:** Do NOT remove a staking period or pop a staking phase. Instead, set the staking target to 0 for the period you want to disable.

## RequirementChecker v2

The incident above exposed a gap in our tooling: once on-chain state had drifted from what a user was actually owned, we had no way to correct the worth the `RequirementChecker` reported. `RequirementCheckerV2` was built in response. It keeps the same aggregation surface (ERC20 balance + pool-based staking + periodical staking + ERC1155 NFT holdings) but adds a per-wallet signed admin offset on every source. An admin can credit or penalize a specific wallet's perceived worth — "treat this wallet as if it has 200 more staked in contract X" or "as if it holds 3 fewer NFTs of id Y" — without moving any real balances. Offsets are signed `int256` values and clamped at 0 per entity so a large negative offset cannot drag another source below zero.

V2 is a drop-in replacement through the shared `IRequirementChecker` interface; periodical staking contract admin switches the requirement checker by calling `setRequirementChecker(v2Address)`. V1 stays deployed and untouched. One-shot `cloneConfigFrom` and `clonePhasePeriodRequirements` migrate the V1 configuration in a single transaction. V2 lives at `src/contracts/requirement-checker/v2/`.
