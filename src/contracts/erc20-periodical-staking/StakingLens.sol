// SPDX-License-Identifier: BUSL-1.1
// Copyright 2024 Reality Metaverse
pragma solidity 0.8.20;

import "./ERC20PeriodicalStaking.sol";
import "../../common/Types.sol";
import "../../common/Errors.sol";
import "../../interfaces/ILimitController.sol";

/// @title StakingLens
/// @notice Read-only companion of one ERC20PeriodicalStaking deployment. It holds the convenience views that
///         bundle several reads into one call, so the staking contract itself stays under the 24,576-byte
///         EIP-170 runtime limit (v0.5.0 with these views inside was 25,533 bytes and could not be deployed).
/// @dev The lens has no storage besides the immutable target, no owner and no privileges: it only calls public
///      getters of `STAKING`, so it can be deployed by anyone, at any time, and replaced freely. Every function
///      keeps the name, arguments and return shape it had on the staking contract up to v0.4.0, so a caller
///      only swaps the address (and ABI) for these calls. All reads of one call happen in one `eth_call`, i.e.
///      against one block, exactly as before.
contract StakingLens is Errors {
    ERC20PeriodicalStaking public immutable STAKING;

    constructor(ERC20PeriodicalStaking staking) {
        if (address(staking) == address(0)) revert ZeroAddressProvided();
        STAKING = staking;
    }

    // ======================================
    // =            Program Data            =
    // ======================================
    /// @notice getProgramData plus the user's controller limits and remaining amounts (legacy stake included,
    ///         voucher extras not included).
    function getProgramDataWithUserData(address userAddress)
        external
        view
        returns (
            uint256 currentPhase,
            uint256[] memory periods,
            uint256[][] memory targets,
            uint256[][] memory apysBps,
            uint256[][] memory staked,
            uint256[][] memory limits,
            uint256[][] memory remaining
        )
    {
        (currentPhase, periods, targets, apysBps, staked) = STAKING.getProgramData();
        (limits, remaining) = _phasePeriodUserData(userAddress, targets.length, periods);
    }

    /// @notice The user's controller limit and remaining amount per [phase][periodIndex].
    /// @dev Both come from the LimitController and include legacy-contract stake; voucher extras are not included.
    ///      Zero-filled when userAddress or limitController is address(0). Reverts if the controller reverts or
    ///      returns arrays of the wrong length.
    function getPhasePeriodUserData(address userAddress)
        external
        view
        returns (uint256[][] memory phasePeriodLimits, uint256[][] memory phasePeriodRemainingAmountForUser)
    {
        return _phasePeriodUserData(userAddress, STAKING.stakingPhaseCount(), STAKING.getStakingPeriods());
    }

    function getPhasePeriodDataAll(Types.PhasePeriodDataType dataType) external view returns (uint256[][] memory) {
        uint256 phaseCount = STAKING.stakingPhaseCount();
        uint256[] memory periods = STAKING.getStakingPeriods();

        uint256[][] memory phasePeriodData = new uint256[][](phaseCount);
        for (uint256 phase = 0; phase < phaseCount; ++phase) {
            phasePeriodData[phase] = new uint256[](periods.length);
            for (uint256 periodIndex = 0; periodIndex < periods.length; ++periodIndex) {
                phasePeriodData[phase][periodIndex] = STAKING.getPhasePeriodData(dataType, phase, periods[periodIndex]);
            }
        }
        return phasePeriodData;
    }

    /// @notice Reward the pool must still be able to pay for every configured periodical cell to fill.
    /// @dev Sum over every (phase < stakingPhaseCount, period in stakingPeriodList, period != 0) of
    ///      `calculateReward(target - staked, baseApyBps, period)` (0 when the cell is already at or above
    ///      target). Voucher extra APY is not included. Stakes are never blocked by pool state; this is an ops
    ///      view so the pool can be funded before deposits mature (a matured periodical claim reverts
    ///      `NotEnoughFundsInRewardPool` while the pool is short).
    ///      SATURATING, never reverting: an "unlimited" target (type(uint256).max) is what an operator types,
    ///      and this view always answers instead of taking itself down. It does NOT follow that such a cell
    ///      reads as type(uint256).max. calculateReward only overflows when apyBps * days > 3_650_000, so at
    ///      production APYs an unlimited target yields a finite but absurd number (~6.7e75 for 500 bps over
    ///      30 days) and the sum saturates only if the running total overflows. type(uint256).max is
    ///      returned only when some cell's own reward computation overflows -- i.e. an unlimited or huge
    ///      target combined with a high APY and a long period. Either way, read "wildly above any fundable
    ///      amount" as "this cell cannot be funded"; do not test for equality with type(uint256).max.
    function getRewardRequiredForTargets() public view returns (uint256 required) {
        (, uint256[] memory periods, uint256[][] memory targets, uint256[][] memory apysBps, uint256[][] memory staked) =
            STAKING.getProgramData();

        for (uint256 phase = 0; phase < targets.length; ++phase) {
            for (uint256 periodIndex = 0; periodIndex < periods.length; ++periodIndex) {
                uint256 period = periods[periodIndex];
                if (period == 0) continue;
                uint256 target = targets[phase][periodIndex];
                uint256 filled = staked[phase][periodIndex];
                if (target > filled) {
                    // calculateReward reverts when the result does not fit a uint256 (mulDiv overflow).
                    try STAKING.calculateReward(target - filled, apysBps[phase][periodIndex], period) returns (
                        uint256 cellReward
                    ) {
                        required = _saturatingAdd(required, cellReward);
                    } catch {
                        return type(uint256).max;
                    }
                }
            }
        }
    }

    /// @notice Extra reward-pool funding needed so that every already-open periodical deposit AND every
    ///         open target, once filled, can be paid at maturity.
    /// @dev `deficit = max(0, totalDataList[REWARD_EXPECTED] - rewardPool)` is what already-open deposits are
    ///      missing today; `required` is what the remaining target capacity would add.
    ///      Saturating like getRewardRequiredForTargets: type(uint256).max targets read as a huge shortfall
    ///      rather than a revert.
    /// @return shortfall `max(0, getRewardRequiredForTargets() + deficit - getCollectableReward())`
    function getRewardPoolShortfall() external view returns (uint256 shortfall) {
        uint256 required = getRewardRequiredForTargets();
        uint256 reserved = STAKING.getTotalData(Types.DataType.REWARD_EXPECTED);
        uint256 pool = STAKING.rewardPool();
        uint256 deficit = reserved > pool ? reserved - pool : 0;
        uint256 collectable = pool > reserved ? pool - reserved : 0;
        uint256 needed = _saturatingAdd(required, deficit);
        return needed > collectable ? needed - collectable : 0;
    }

    // ======================================
    // =             User Data             =
    // ======================================
    /// @notice Get deposits [fromIndex, toIndex) of a user.
    /// @dev Reverts InvalidRange when fromIndex > toIndex or toIndex exceeds the deposit count.
    function getDepositsInRangeBy(address userAddress, uint256 fromIndex, uint256 toIndex)
        external
        view
        returns (ProgramManager.TokenDeposit[] memory)
    {
        if (fromIndex > toIndex || toIndex > STAKING.checkDepositCountOfAddress(userAddress)) {
            revert InvalidRange(fromIndex, toIndex);
        }
        ProgramManager.TokenDeposit[] memory userDepositsInRange = new ProgramManager.TokenDeposit[](toIndex - fromIndex);
        for (uint256 i = fromIndex; i < toIndex; ++i) {
            userDepositsInRange[i - fromIndex] = STAKING.getDeposit(userAddress, i);
        }
        return userDepositsInRange;
    }

    /// @notice getBonusUsage for several periods of one phase, so a whole period table costs one RPC call.
    /// @param periods Periods to report within `phase`; unknown periods read 0
    /// @return usedTotal Bonus held open across every cell, not only the ones requested or this phase's
    /// @return usedPerCell Bonus held open in cell (`phase`, periods[i]), in the order given
    function getBonusUsageBatch(address wallet, uint256 phase, uint256[] calldata periods)
        external
        view
        returns (uint256 usedTotal, uint256[] memory usedPerCell)
    {
        uint256 len = periods.length;
        usedPerCell = new uint256[](len);
        // `usedTotal` does not depend on the cell, so with no periods asked for it is read from any cell.
        if (len == 0) (usedTotal,) = STAKING.getBonusUsage(wallet, phase, 0);
        for (uint256 i = 0; i < len; ++i) {
            (usedTotal, usedPerCell[i]) = STAKING.getBonusUsage(wallet, phase, periods[i]);
        }
    }

    // ======================================
    // =              Internal              =
    // ======================================
    function _saturatingAdd(uint256 a, uint256 b) private pure returns (uint256) {
        unchecked {
            uint256 c = a + b;
            return c < a ? type(uint256).max : c;
        }
    }

    function _phasePeriodUserData(address userAddress, uint256 phaseCount, uint256[] memory periods)
        private
        view
        returns (uint256[][] memory limits, uint256[][] memory remaining)
    {
        uint256 periodCount = periods.length;
        address controller = STAKING.limitController();

        limits = new uint256[][](phaseCount);
        remaining = new uint256[][](phaseCount);
        for (uint256 phase = 0; phase < phaseCount; ++phase) {
            limits[phase] = new uint256[](periodCount);
            remaining[phase] = new uint256[](periodCount);
        }
        if (userAddress == address(0) || controller == address(0)) return (limits, remaining);

        uint256 total = phaseCount * periodCount;
        address[] memory wallets = new address[](total);
        uint256[] memory phases = new uint256[](total);
        uint256[] memory periodsFlat = new uint256[](total);
        uint256 idx;
        for (uint256 phase = 0; phase < phaseCount; ++phase) {
            for (uint256 periodIndex = 0; periodIndex < periodCount; ++periodIndex) {
                wallets[idx] = userAddress;
                phases[idx] = phase;
                periodsFlat[idx] = periods[periodIndex];
                ++idx;
            }
        }

        uint256[] memory batchLimits = ILimitController(controller).getAllowedBatch(wallets, phases, periodsFlat);
        uint256[] memory batchRemaining = ILimitController(controller).getRemainingBatch(wallets, phases, periodsFlat);
        if (batchLimits.length != total) revert LengthMismatch(total, batchLimits.length);
        if (batchRemaining.length != total) revert LengthMismatch(total, batchRemaining.length);

        idx = 0;
        for (uint256 phase = 0; phase < phaseCount; ++phase) {
            for (uint256 periodIndex = 0; periodIndex < periodCount; ++periodIndex) {
                limits[phase][periodIndex] = batchLimits[idx];
                remaining[phase][periodIndex] = batchRemaining[idx];
                ++idx;
            }
        }
    }
}
