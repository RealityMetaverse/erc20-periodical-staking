// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {V050Base} from "./V050Base.sol";
import {LimitController} from "../../src/contracts/LimitController.sol";
import {Errors} from "../../src/common/Errors.sol";
import {Types} from "../../src/common/Types.sol";

// Vendored pre-fix v0.2.4 sources (never edited): a realistic stand-in for the closed Polygon VIP contract.
import {ERC20PeriodicalStaking as LegacyV024} from
    "../erc20-periodical-staking/security/invariants/legacy/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";

/// @notice LimitController v0.4.0: "used" = stake in the new contract + stake in the legacy contract for the SAME
///         phase and period, unknown phase/period read 0 and never revert, wallet overrides (isSet, explicit 0),
///         the stake-path boundary `used + amount <= allowed + extraLimit`, batch == single reads, and legacy
///         stake shrinking frees room.
contract LimitControllerLegacyTest is V050Base {
    event LegacyStakingContractSet(address indexed legacyStakingContract);
    event StakingContractSet(address indexed stakingContract);

    uint256 internal constant MIN_DEPOSIT = 100;

    // ======================================
    // =              Helpers               =
    // ======================================
    function _sat(uint256 allowed, uint256 used) internal pure returns (uint256) {
        return used >= allowed ? 0 : allowed - used;
    }

    function _pickPeriod(uint256 seed) internal pure returns (uint256) {
        uint256[5] memory periods = [uint256(0), 30, 90, 180, 365];
        return periods[seed % periods.length];
    }

    /// @dev Default the fixture configured: 2 phases x [0, 30, 90]; everything else is unset (0).
    function _expectedDefault(uint256 phase, uint256 period) internal pure returns (uint256) {
        if (phase < 2 && (period == P0 || period == P30 || period == P90)) return DEFAULT_LIMIT;
        return 0;
    }

    function _expectLimitRevert(address wallet, uint256 period, uint256 amount, uint256 extraLimit, uint256 headroom)
        internal
    {
        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(staking, wallet, 0, period, 0, extraLimit);
        uint256 expectedApy = _baseApy(0, period);
        vm.prank(wallet);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.StakingLimitExceeded.selector, wallet, 0, period, amount, headroom)
        );
        staking.stakeWithVoucher(v, sig, amount, expectedApy);
    }

    /// @dev v0.2.4 with one phase and periods [0, 30, 180] (APY in whole percent). Period 90 does not exist there,
    ///      period 180 does not exist in the new contract, phase 1 exists only in the new contract.
    function _deployLegacyV024() internal returns (LegacyV024 l) {
        l = new LegacyV024(address(token));
        uint256[] memory empty = new uint256[](0);
        l.addStakingPeriod(0, empty, empty);
        l.addStakingPeriod(30, empty, empty);
        l.addStakingPeriod(180, empty, empty);
        uint256[] memory apys = new uint256[](3);
        apys[0] = 5;
        apys[1] = 10;
        apys[2] = 20;
        l.pushStakingPhase(apys, _fill(3, TARGET));

        address[2] memory users = [alice, bob];
        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            token.approve(address(l), type(uint256).max);
        }
    }

    function _legacyApy(uint256 period) internal pure returns (uint256) {
        if (period == 0) return 5;
        if (period == 30) return 10;
        return 20;
    }

    function _legacyStake(LegacyV024 l, address wallet, uint256 period, uint256 amount) internal {
        vm.prank(wallet);
        l.safeStake(0, period, amount, _legacyApy(period));
    }

    function _legacyCell(LegacyV024 l, address wallet, uint256 phase, uint256 period) internal view returns (uint256) {
        (bool ok, bytes memory ret) = address(l).staticcall(
            abi.encodeWithSignature("getUserPhasePeriodData(uint8,address,uint256,uint256)", 0, wallet, phase, period)
        );
        require(ok, "legacy read reverted");
        return abi.decode(ret, (uint256));
    }

    // ======================================
    // =        Admin: legacy address       =
    // ======================================
    function test_setLegacy_setClearAndEvents() public {
        assertEq(address(controller.legacyStakingContract()), address(legacy));

        vm.expectEmit(true, true, true, true, address(controller));
        emit LegacyStakingContractSet(address(0));
        controller.setLegacyStakingContract(address(0));
        assertEq(address(controller.legacyStakingContract()), address(0));

        vm.expectEmit(true, true, true, true, address(controller));
        emit LegacyStakingContractSet(address(legacy));
        controller.setLegacyStakingContract(address(legacy));
        assertEq(address(controller.legacyStakingContract()), address(legacy));
    }

    function test_setLegacy_rejectsStakingContractAddress() public {
        vm.expectRevert(
            abi.encodeWithSelector(LimitController.SameStakingAndLegacyContract.selector, address(staking))
        );
        controller.setLegacyStakingContract(address(staking));
    }

    function test_setStakingContract_rejectsLegacyAddress() public {
        vm.expectRevert(abi.encodeWithSelector(LimitController.SameStakingAndLegacyContract.selector, address(legacy)));
        controller.setStakingContract(address(legacy));

        // Once legacy is cleared, the same address is a valid staking contract again.
        controller.setLegacyStakingContract(address(0));
        vm.expectEmit(true, true, true, true, address(controller));
        emit StakingContractSet(address(legacy));
        controller.setStakingContract(address(legacy));
        assertEq(address(controller.stakingContract()), address(legacy));
    }

    function testFuzz_setLegacy_onlyOwner(address caller) public {
        vm.assume(caller != owner);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        controller.setLegacyStakingContract(address(0));
        assertEq(address(controller.legacyStakingContract()), address(legacy));
    }

    // ======================================
    // =        used = new + legacy         =
    // ======================================
    function test_used_sumsNewAndLegacyForSameCell() public {
        stakeFor(alice, P30, 10_000 * ONE);
        legacy.setStaked(alice, 0, P30, 25_000 * ONE);

        assertEq(_cell(alice, 0, P30), 10_000 * ONE);
        assertEq(controller.getUsed(alice, 0, P30), 35_000 * ONE);
        (uint256 allowed, uint256 used) = controller.getAllowedAndUsed(alice, 0, P30);
        assertEq(allowed, DEFAULT_LIMIT);
        assertEq(used, 35_000 * ONE);
        assertEq(controller.getRemaining(alice, 0, P30), DEFAULT_LIMIT - 35_000 * ONE);
    }

    function test_used_noRemapping_otherCellsDoNotBleed() public {
        stakeFor(alice, P30, 10_000 * ONE);
        // Legacy stake in neighbouring cells must not count for (0, 30).
        legacy.setStaked(alice, 1, P30, 40_000 * ONE);
        legacy.setStaked(alice, 0, P90, 50_000 * ONE);
        legacy.setStaked(alice, 0, P0, 60_000 * ONE);
        legacy.setStaked(bob, 0, P30, 70_000 * ONE);

        assertEq(controller.getUsed(alice, 0, P30), 10_000 * ONE);
        assertEq(controller.getUsed(alice, 1, P30), 40_000 * ONE);
        assertEq(controller.getUsed(alice, 0, P90), 50_000 * ONE);
        assertEq(controller.getUsed(alice, 0, P0), 60_000 * ONE);
        assertEq(controller.getUsed(bob, 0, P30), 70_000 * ONE);
    }

    function test_legacyUnset_usedIsNewOnly() public {
        stakeFor(alice, P30, 10_000 * ONE);
        legacy.setStaked(alice, 0, P30, 90_000 * ONE);
        assertEq(controller.getUsed(alice, 0, P30), 100_000 * ONE);
        assertEq(controller.getRemaining(alice, 0, P30), 0);

        controller.setLegacyStakingContract(address(0));
        assertEq(controller.getUsed(alice, 0, P30), 10_000 * ONE);
        (, uint256 used) = controller.getAllowedAndUsed(alice, 0, P30);
        assertEq(used, 10_000 * ONE);
        assertEq(controller.getRemaining(alice, 0, P30), DEFAULT_LIMIT - 10_000 * ONE);

        // And the stake path follows: 90k more now fits, which it did not with legacy counted.
        stakeFor(alice, P30, 90_000 * ONE);
        assertEq(_cell(alice, 0, P30), DEFAULT_LIMIT);
    }

    function test_legacyUnset_stakeRevertsWhileCountedThenSucceeds() public {
        legacy.setStaked(alice, 0, P30, DEFAULT_LIMIT);
        _expectLimitRevert(alice, P30, MIN_DEPOSIT, 0, 0);

        controller.setLegacyStakingContract(address(0));
        stakeFor(alice, P30, DEFAULT_LIMIT);
        assertEq(_cell(alice, 0, P30), DEFAULT_LIMIT);
    }

    // ======================================
    // =   Unknown phase/period never revert =
    // ======================================
    /// @dev Fully random phase/period: in practice "in neither contract". Values set only in the legacy cell.
    function testFuzz_unknownPhasePeriod_neverReverts(uint256 phase, uint256 period, uint256 legacyAmount) public {
        legacyAmount = bound(legacyAmount, 0, type(uint128).max);
        legacy.setStaked(alice, phase, period, legacyAmount);

        uint256 newCell = _cell(alice, phase, period);
        uint256 expectedAllowed = _expectedDefault(phase, period);

        (uint256 allowed, uint256 used) = controller.getAllowedAndUsed(alice, phase, period);
        assertEq(allowed, expectedAllowed, "allowed");
        assertEq(used, newCell + legacyAmount, "used");
        assertEq(controller.getUsed(alice, phase, period), used, "getUsed");
        assertEq(controller.getAllowed(alice, phase, period), allowed, "getAllowed");
        assertEq(controller.getRemaining(alice, phase, period), _sat(allowed, used), "remaining");

        controller.setLegacyStakingContract(address(0));
        (allowed, used) = controller.getAllowedAndUsed(alice, phase, period);
        assertEq(used, newCell, "used without legacy");
        assertEq(controller.getRemaining(alice, phase, period), _sat(allowed, used), "remaining without legacy");
    }

    /// @dev Small domain so every category is hit: phase 0/1 x [0, 30, 90] exist in the new contract (with stake in
    ///      (0, 30) and (0, 90)), phases 2-3 and periods 180/365 exist in neither; legacy may or may not hold stake.
    function testFuzz_mixedPhasePeriod_usedMatchesCells(
        uint256 phaseSeed,
        uint256 periodSeed,
        uint256 legacyAmount,
        address wallet
    ) public {
        stakeFor(alice, P30, 10_000 * ONE);
        stakeFor(alice, P90, 20_000 * ONE);

        uint256 phase = bound(phaseSeed, 0, 3);
        uint256 period = _pickPeriod(periodSeed);
        address who = uint256(uint160(wallet)) % 2 == 0 ? alice : wallet;
        legacyAmount = bound(legacyAmount, 0, 1e30);
        legacy.setStaked(who, phase, period, legacyAmount);

        uint256 newCell = _cell(who, phase, period);
        if (who == alice && phase == 0 && period == P30) assertEq(newCell, 10_000 * ONE);
        if (who == alice && phase == 0 && period == P90) assertEq(newCell, 20_000 * ONE);

        (uint256 allowed, uint256 used) = controller.getAllowedAndUsed(who, phase, period);
        assertEq(allowed, _expectedDefault(phase, period));
        assertEq(used, newCell + legacyAmount);
        assertEq(controller.getRemaining(who, phase, period), _sat(allowed, used));
    }

    function test_cellOnlyInNew_legacyEmpty() public {
        stakeFor(alice, P90, 30_000 * ONE);
        assertEq(legacy.getUserPhasePeriodData(0, alice, 0, P90), 0);
        assertEq(controller.getUsed(alice, 0, P90), 30_000 * ONE);
    }

    function test_cellOnlyInLegacy_newReadsZero() public {
        // Phase 7 / period 365 exists in no new-contract configuration.
        legacy.setStaked(alice, 7, 365, 12_345 * ONE);
        assertEq(_cell(alice, 7, 365), 0);
        (uint256 allowed, uint256 used) = controller.getAllowedAndUsed(alice, 7, 365);
        assertEq(allowed, 0);
        assertEq(used, 12_345 * ONE);
        assertEq(controller.getRemaining(alice, 7, 365), 0);

        // An override on a cell that exists nowhere still resolves normally.
        controller.setWalletLimit(alice, 7, 365, 20_000 * ONE);
        assertEq(controller.getRemaining(alice, 7, 365), 7_655 * ONE);
    }

    function test_brokenLegacy_revertsUntilUnset() public {
        // No code at the address: the read reverts. The controller must NOT swallow that as 0.
        address broken = makeAddr("brokenLegacy");
        controller.setLegacyStakingContract(broken);

        vm.expectRevert();
        controller.getUsed(alice, 0, P30);
        vm.expectRevert();
        controller.getAllowedAndUsed(alice, 0, P30);

        (Types.StakeVoucher memory v, bytes memory sig) = _prepareVoucherStake(staking, alice, 0, P30, 0, 0);
        uint256 expectedApy = _baseApy(0, P30);
        vm.prank(alice);
        vm.expectRevert();
        staking.stakeWithVoucher(v, sig, 1_000 * ONE, expectedApy);

        controller.setLegacyStakingContract(address(0));
        stakeFor(alice, P30, 1_000 * ONE);
        assertEq(controller.getUsed(alice, 0, P30), 1_000 * ONE);
    }

    // ======================================
    // =        Per-wallet overrides        =
    // ======================================
    function test_walletOverride_explicitZeroBlocks_extraLimitIsTheOnlyRoom() public {
        controller.setWalletLimit(alice, 0, P30, 0);
        assertTrue(controller.hasWalletLimit(alice, 0, P30));
        assertEq(controller.getAllowed(alice, 0, P30), 0, "explicit 0 must not fall back to the default");
        assertEq(controller.getRemaining(alice, 0, P30), 0);
        assertEq(controller.getAllowed(bob, 0, P30), DEFAULT_LIMIT, "other wallets keep the default");

        _expectLimitRevert(alice, P30, MIN_DEPOSIT, 0, 0);

        // Voucher extra limit is the only headroom: exactly that much fits, one more wei does not.
        uint256 extra = 1_000 * ONE;
        _expectLimitRevert(alice, P30, extra + 1, extra, extra);
        stakeWith(alice, P30, extra, 0, extra);
        assertEq(_cell(alice, 0, P30), extra);
        _expectLimitRevert(alice, P30, MIN_DEPOSIT, extra, 0);

        controller.clearWalletLimit(alice, 0, P30);
        assertFalse(controller.hasWalletLimit(alice, 0, P30));
        assertEq(controller.getAllowed(alice, 0, P30), DEFAULT_LIMIT);
        assertEq(controller.getRemaining(alice, 0, P30), DEFAULT_LIMIT - extra);
    }

    function testFuzz_walletOverride_isAuthoritative(uint256 limit, uint256 defaultLimit, uint256 legacyAmount)
        public
    {
        limit = bound(limit, 0, 1e30);
        defaultLimit = bound(defaultLimit, 0, 1e30);
        legacyAmount = bound(legacyAmount, 0, 1e30);
        controller.setDefaultLimit(0, P90, defaultLimit);
        legacy.setStaked(alice, 0, P90, legacyAmount);

        assertEq(controller.getAllowed(alice, 0, P90), defaultLimit);
        controller.setWalletLimit(alice, 0, P90, limit);
        (uint256 allowed, uint256 used) = controller.getAllowedAndUsed(alice, 0, P90);
        assertEq(allowed, limit);
        assertEq(used, legacyAmount);
        assertEq(controller.getRemaining(alice, 0, P90), _sat(limit, legacyAmount));
        // bob: default, same legacy cell for bob is empty
        assertEq(controller.getRemaining(bob, 0, P90), defaultLimit);

        controller.clearWalletLimit(alice, 0, P90);
        assertEq(controller.getAllowed(alice, 0, P90), defaultLimit);
        assertEq(controller.getRemaining(alice, 0, P90), _sat(defaultLimit, legacyAmount));
    }

    // ======================================================================
    // =   headroom = (allowed - used) + unspent bonus                      =
    // ======================================================================
    // BEHAVIOUR CHANGE, 2026-09-18, v0.4.0 bonus-budget rework. These two tests used to assert the pre-fix rule
    // `headroom = (allowed + extra) - used`, where stake already sitting above the controller limit ate into the
    // voucher's extra. That was found to mean a wallet whose LEGACY position overshot its new limit arrived with
    // part of its VIP perk silently already spent -- on day one, for exactly the users most likely to be VIPs.
    // The fix makes the bonus INDEPENDENT headroom stacked on top of the base allowance, so an overshoot shrinks
    // `baseRoom` and nothing else. Do not restore the old assertions.
    function testFuzz_stakeBoundary_exact(
        uint256 newStaked,
        uint256 legacyAmount,
        uint256 extraLimit,
        bool useOverride,
        uint256 overrideLimit
    ) public {
        newStaked = bound(newStaked, 0, 60_000 * ONE);
        legacyAmount = bound(legacyAmount, 0, 150_000 * ONE);
        extraLimit = bound(extraLimit, 0, MAX_EXTRA_LIMIT_TOTAL);
        overrideLimit = bound(overrideLimit, 0, 150_000 * ONE);

        // Stake in the new contract first, before legacy stake and overrides can block it.
        if (newStaked >= MIN_DEPOSIT) stakeFor(alice, P30, newStaked);
        else newStaked = 0;

        legacy.setStaked(alice, 0, P30, legacyAmount);
        uint256 allowed = DEFAULT_LIMIT;
        if (useOverride) {
            controller.setWalletLimit(alice, 0, P30, overrideLimit);
            allowed = overrideLimit;
        }

        uint256 used = newStaked + legacyAmount;
        (uint256 cAllowed, uint256 cUsed) = controller.getAllowedAndUsed(alice, 0, P30);
        assertEq(cAllowed, allowed);
        assertEq(cUsed, used);

        // The bonus is not reduced by an overshoot: unused base room, PLUS the whole voucher budget. The first
        // stake above consumed no bonus (it fits inside DEFAULT_LIMIT before the legacy stake and override land),
        // so the meter is still empty here.
        uint256 baseRoom = _sat(allowed, used);
        uint256 headroom = baseRoom + extraLimit;

        // One over the headroom (at least the minimum deposit, which is checked earlier) reverts.
        uint256 over = headroom + 1 < MIN_DEPOSIT ? MIN_DEPOSIT : headroom + 1;
        _expectLimitRevert(alice, P30, over, extraLimit, headroom);

        if (headroom < MIN_DEPOSIT) return;

        // Exactly the headroom succeeds, and the part above baseRoom is what the meter records.
        stakeWith(alice, P30, headroom, 0, extraLimit);
        assertEq(_cell(alice, 0, P30), newStaked + headroom);
        (, cUsed) = controller.getAllowedAndUsed(alice, 0, P30);
        assertEq(cUsed, used + headroom, "every token landed in the cell");
        (uint256 spentTotal,) = staking.getBonusUsage(alice, 0, P30);
        assertEq(spentTotal, extraLimit, "the whole budget was spent, and only the budget");

        // Nothing more fits: base room is gone and the budget is exhausted, so a fresh voucher with the same
        // numbers finds zero. Under the old rule this held for the wrong reason.
        _expectLimitRevert(alice, P30, MIN_DEPOSIT, extraLimit, 0);
    }

    /// @notice Legacy stake above the limit zeroes the BASE room and leaves the voucher bonus fully intact.
    /// @dev This is the case the rework exists for. A wallet migrated with a legacy position larger than its new
    ///      limit (limits were lowered after the migration) still gets its whole VIP bonus; previously the
    ///      overshoot was treated as bonus already consumed, so the perk was gone before the wallet ever used it.
    ///      The saturation this test originally guarded is still asserted: `getRemaining` is 0, not an underflow,
    ///      and a voucher carrying no bonus still gets nothing.
    function test_stakeBoundary_legacyAboveAllowed_zeroesBaseRoomButNotTheBonus() public {
        legacy.setStaked(alice, 0, P30, DEFAULT_LIMIT + MAX_EXTRA_LIMIT_TOTAL + 1);
        assertEq(controller.getRemaining(alice, 0, P30), 0, "base room saturates at 0, no underflow");

        // No bonus on the voucher: still nothing.
        _expectLimitRevert(alice, P30, MIN_DEPOSIT, 0, 0);

        // With a bonus: exactly the bonus, undiminished by the overshoot.
        _expectLimitRevert(alice, P30, MAX_EXTRA_LIMIT_TOTAL + 1, MAX_EXTRA_LIMIT_TOTAL, MAX_EXTRA_LIMIT_TOTAL);
        stakeWith(alice, P30, MAX_EXTRA_LIMIT_TOTAL, 0, MAX_EXTRA_LIMIT_TOTAL);
        (uint256 spentTotal,) = staking.getBonusUsage(alice, 0, P30);
        assertEq(spentTotal, MAX_EXTRA_LIMIT_TOTAL, "the overshoot did not pre-spend the budget");
    }

    // ======================================
    // =       Legacy stake shrinking        =
    // ======================================
    function testFuzz_legacyDecrease_freesRoom(uint256 before, uint256 afterAmount) public {
        before = bound(before, DEFAULT_LIMIT, 10 * DEFAULT_LIMIT);
        afterAmount = bound(afterAmount, 0, DEFAULT_LIMIT - MIN_DEPOSIT);

        legacy.setStaked(alice, 0, P30, before);
        _expectLimitRevert(alice, P30, MIN_DEPOSIT, 0, 0);

        // Legacy withdrawal (the mock cell shrinks).
        legacy.setStaked(alice, 0, P30, afterAmount);
        uint256 freed = DEFAULT_LIMIT - afterAmount;
        assertEq(controller.getRemaining(alice, 0, P30), freed);

        _expectLimitRevert(alice, P30, freed + 1, 0, freed);
        stakeFor(alice, P30, freed);
        assertEq(_cell(alice, 0, P30), freed);
        assertEq(controller.getRemaining(alice, 0, P30), 0);
    }

    // ======================================
    // =        Batch == single reads       =
    // ======================================
    function testFuzz_batchEqualsSingle(uint256 seed, bool withLegacy) public {
        stakeFor(alice, P30, 5_000 * ONE);
        stakeFor(bob, P90, 7_000 * ONE);
        if (!withLegacy) controller.setLegacyStakingContract(address(0));

        uint256 n = 6;
        address[] memory wallets = new address[](n);
        uint256[] memory phases = new uint256[](n);
        uint256[] memory periods = new uint256[](n);
        address[3] memory pool = [alice, bob, carol];

        for (uint256 i = 0; i < n; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            wallets[i] = pool[r % 3];
            phases[i] = (r >> 8) % 4;
            periods[i] = _pickPeriod(r >> 16);
            legacy.setStaked(wallets[i], phases[i], periods[i], (r >> 24) % (150_000 * ONE));
            if ((r >> 200) % 3 == 0) {
                controller.setWalletLimit(wallets[i], phases[i], periods[i], (r >> 100) % (120_000 * ONE));
            }
        }

        uint256[] memory remaining = controller.getRemainingBatch(wallets, phases, periods);
        uint256[] memory allowedB = controller.getAllowedBatch(wallets, phases, periods);
        assertEq(remaining.length, n);
        assertEq(allowedB.length, n);
        for (uint256 i = 0; i < n; i++) {
            (uint256 allowed, uint256 used) = controller.getAllowedAndUsed(wallets[i], phases[i], periods[i]);
            assertEq(allowedB[i], allowed, "allowed batch");
            assertEq(allowedB[i], controller.getAllowed(wallets[i], phases[i], periods[i]), "getAllowed");
            assertEq(remaining[i], controller.getRemaining(wallets[i], phases[i], periods[i]), "remaining batch");
            assertEq(remaining[i], _sat(allowed, used), "remaining formula");
            uint256 expectedUsed = _cell(wallets[i], phases[i], periods[i])
                + (withLegacy ? legacy.getUserPhasePeriodData(0, wallets[i], phases[i], periods[i]) : 0);
            assertEq(used, expectedUsed, "used");
        }
    }

    function testFuzz_batchRandomPhasePeriod_neverReverts(uint256 phase, uint256 period, uint256 legacyAmount)
        public
    {
        legacyAmount = bound(legacyAmount, 0, 1e30);
        legacy.setStaked(alice, phase, period, legacyAmount);

        address[] memory wallets = new address[](2);
        uint256[] memory phases = new uint256[](2);
        uint256[] memory periods = new uint256[](2);
        wallets[0] = alice;
        wallets[1] = bob;
        phases[0] = phase;
        phases[1] = phase;
        periods[0] = period;
        periods[1] = period;

        uint256[] memory remaining = controller.getRemainingBatch(wallets, phases, periods);
        uint256 allowed = _expectedDefault(phase, period);
        assertEq(remaining[0], _sat(allowed, legacyAmount + _cell(alice, phase, period)));
        assertEq(remaining[1], _sat(allowed, _cell(bob, phase, period)));
    }

    function test_batch_lengthMismatch() public {
        address[] memory wallets = new address[](2);
        uint256[] memory two = new uint256[](2);
        uint256[] memory one = new uint256[](1);

        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        controller.getRemainingBatch(wallets, one, two);
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        controller.getRemainingBatch(wallets, two, one);
        vm.expectRevert(abi.encodeWithSelector(Errors.LengthMismatch.selector, 2, 1));
        controller.getAllowedBatch(wallets, one, two);
    }

    // ======================================
    // =   Realistic legacy: vendored v0.2.4 =
    // ======================================
    function test_v024Legacy_sameCellCounted_unknownCellsReadZero() public {
        LegacyV024 old = _deployLegacyV024();
        _legacyStake(old, alice, 30, 40_000 * ONE);
        _legacyStake(old, alice, 0, 15_000 * ONE);
        _legacyStake(old, alice, 180, 25_000 * ONE);
        controller.setLegacyStakingContract(address(old));

        stakeFor(alice, P30, 10_000 * ONE);
        stakeFor(alice, P90, 5_000 * ONE);

        // Same phase + period in both: summed.
        assertEq(controller.getUsed(alice, 0, 30), 50_000 * ONE);
        // Period 0 (flexible) in both, stake only in legacy.
        assertEq(controller.getUsed(alice, 0, 0), 15_000 * ONE);
        // Period 90: only exists in the new contract.
        assertEq(controller.getUsed(alice, 0, 90), 5_000 * ONE);
        // Period 180: only exists in legacy (the new contract reads 0, no revert).
        assertEq(controller.getUsed(alice, 0, 180), 25_000 * ONE);
        // Phase 1: exists only in the new contract; legacy has a single phase. No remapping to phase 0.
        assertEq(controller.getUsed(alice, 1, 30), 0);
        // Phase beyond both counts and a period in neither.
        assertEq(controller.getUsed(alice, 5, 30), 0);
        assertEq(controller.getUsed(alice, 0, 365), 0);
        (uint256 allowed, uint256 used) = controller.getAllowedAndUsed(alice, 9, 365);
        assertEq(allowed, 0);
        assertEq(used, 0);

        // The stake path sees the real legacy stake: 50k used of 100k.
        _expectLimitRevert(alice, P30, 50_000 * ONE + 1, 0, 50_000 * ONE);
        stakeFor(alice, P30, 50_000 * ONE);
        assertEq(controller.getRemaining(alice, 0, 30), 0);
    }

    function test_v024Legacy_removedPeriodReadsZero() public {
        LegacyV024 old = _deployLegacyV024();
        _legacyStake(old, alice, 180, 25_000 * ONE);
        controller.setLegacyStakingContract(address(old));
        assertEq(controller.getUsed(alice, 0, 180), 25_000 * ONE);

        old.removeStakingPeriod(180);
        assertEq(_legacyCell(old, alice, 0, 180), 0);
        assertEq(controller.getUsed(alice, 0, 180), 0);
        assertEq(controller.getRemaining(alice, 0, 180), 0); // no default configured for 180
        controller.setDefaultLimit(0, 180, 1_000 * ONE);
        assertEq(controller.getRemaining(alice, 0, 180), 1_000 * ONE);
    }

    function test_v024Legacy_withdrawFreesRoom() public {
        LegacyV024 old = _deployLegacyV024();
        _legacyStake(old, alice, 30, DEFAULT_LIMIT);
        controller.setLegacyStakingContract(address(old));

        _expectLimitRevert(alice, P30, MIN_DEPOSIT, 0, 0);

        vm.prank(alice);
        old.withdrawDeposit(0);
        assertEq(_legacyCell(old, alice, 0, 30), 0);
        assertEq(controller.getRemaining(alice, 0, 30), DEFAULT_LIMIT);

        stakeFor(alice, P30, DEFAULT_LIMIT);
        assertEq(controller.getUsed(alice, 0, 30), DEFAULT_LIMIT);
    }

    function testFuzz_v024Legacy_anyPhasePeriod_neverReverts(uint256 phase, uint256 period, uint256 seed) public {
        LegacyV024 old = _deployLegacyV024();
        _legacyStake(old, alice, 30, 40_000 * ONE);
        controller.setLegacyStakingContract(address(old));
        stakeFor(alice, P90, 5_000 * ONE);

        // Half the runs use the small domain so real cells are hit, the rest are fully random.
        if (seed % 2 == 0) {
            phase = bound(phase, 0, 3);
            period = _pickPeriod(period);
        }

        uint256 expectedUsed = _cell(alice, phase, period) + _legacyCell(old, alice, phase, period);
        (uint256 allowed, uint256 used) = controller.getAllowedAndUsed(alice, phase, period);
        assertEq(allowed, _expectedDefault(phase, period));
        assertEq(used, expectedUsed);
        assertEq(controller.getRemaining(alice, phase, period), _sat(allowed, used));

        address[] memory wallets = new address[](1);
        uint256[] memory phases = new uint256[](1);
        uint256[] memory periods = new uint256[](1);
        wallets[0] = alice;
        phases[0] = phase;
        periods[0] = period;
        assertEq(controller.getRemainingBatch(wallets, phases, periods)[0], _sat(allowed, used));
    }
}
