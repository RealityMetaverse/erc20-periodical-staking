// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {TestToken} from "../../../shared/TestToken.sol";
import {VoucherHelper} from "../../../shared/VoucherHelper.sol";
import {ERC20PeriodicalStaking} from
    "../../../../src/contracts/erc20-periodical-staking/ERC20PeriodicalStaking.sol";
import {ProgramManager} from "../../../../src/contracts/erc20-periodical-staking/ProgramManager.sol";
import {Types} from "../../../../src/common/Types.sol";
import {Errors} from "../../../../src/common/Errors.sol";

/// @title SolvencyPoC
/// @notice Deterministic reproducer for a v0.2.4 reward-pool weakness first exposed by the invariant suite:
///         INDEFINITE deposits used to pay their accrued reward out of the same pool as periodical deposits,
///         checking only `reward <= rewardPool`, so an indefinite staker could consume tokens already promised
///         to a periodical deposit and lock its principal until a top-up.
///
///         Fixed in v0.3.0: an indefinite claim pays `min(accrued, collectable)`, an indefinite withdraw
///         either pays the full accrued reward from `collectable` or reverts (the opt-in
///         `withdrawDepositPartial` closes it with `min(accrued, collectable)`), and `collectReward` is
///         bounded by `collectable`, so once the pool covers REWARD_EXPECTED nothing but a periodical claim
///         can lower it below that line. (There is no stake-time pool check, so a
///         pool can be short from the start; that case is covered below.)
///
///         v0.4.0 adds seize: it sends only the principal to the treasury and never pays out of the pool (a
///         periodical seize releases its reservation, an indefinite seize leaves its accrual in the pool), so it
///         cannot breach the reserve and never reverts because the pool is short.
contract SolvencyPoC is VoucherHelper {
    function _selectorOf(bytes memory reason) internal pure returns (bytes4 sel) {
        if (reason.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(reason, 32))
        }
    }

    TestToken internal token;
    ERC20PeriodicalStaking internal staking;
    address internal owner = makeAddr("owner");
    address internal periodicalStaker = makeAddr("periodicalStaker");
    address internal indefiniteStaker = makeAddr("indefiniteStaker");

    uint256 internal constant APY = 2000; // bps (20%)
    uint256 internal constant PERIOD = 30;

    function setUp() external {
        token = new TestToken(18);
        vm.prank(owner);
        staking = new ERC20PeriodicalStaking(address(token));

        uint256[] memory empty = new uint256[](0);
        vm.startPrank(owner);
        staking.addStakingPeriod(0, empty, empty);
        staking.addStakingPeriod(PERIOD, empty, empty);
        uint256[] memory apy = new uint256[](2);
        uint256[] memory target = new uint256[](2);
        apy[0] = APY;
        apy[1] = APY;
        target[0] = type(uint128).max;
        target[1] = type(uint128).max;
        staking.pushStakingPhase(apy, target);
        _enableVoucherStaking(staking);
        vm.stopPrank();

        token.transfer(periodicalStaker, 100_000e18);
        token.transfer(indefiniteStaker, 100_000e18);
        token.transfer(owner, 1_000_000e18);
        vm.prank(periodicalStaker);
        token.approve(address(staking), type(uint256).max);
        vm.prank(indefiniteStaker);
        token.approve(address(staking), type(uint256).max);
        vm.prank(owner);
        token.approve(address(staking), type(uint256).max);
    }

    /// @dev Fund exactly what one periodical deposit needs, open it, then open an indefinite deposit.
    ///      Amounts: 10_000 tokens each at 20% APY. Reserve for 30 days = 164.38 tokens; 10 days of indefinite
    ///      accrual = 54.79 tokens, i.e. non-zero and below the pool, so the payout succeeds and eats the reserve.
    function _openBothDeposits(uint256 periodicalAmount, uint256 indefiniteAmount) internal returns (uint256 reserved) {
        reserved = staking.calculateReward(periodicalAmount, APY, PERIOD);
        vm.prank(owner);
        staking.provideReward(reserved);

        _stakeV(staking, periodicalStaker, 0, PERIOD, periodicalAmount);
        assertEq(staking.totalDataList(Types.DataType.REWARD_EXPECTED), reserved);
        assertEq(staking.rewardPool(), reserved, "pool == reserve after stake");
        assertEq(staking.getCollectableReward(), 0, "nothing collectable");

        _stakeV(staking, indefiniteStaker, 0, 0, indefiniteAmount);
    }

    function _freezeAndSeize(address wallet, uint256 depositNumber) internal {
        vm.startPrank(owner);
        staking.freezeDeposit(wallet, depositNumber);
        staking.seizeDeposit(wallet, depositNumber);
        vm.stopPrank();
    }

    /// @notice An indefinite claim must not reduce rewardPool below totalDataList[REWARD_EXPECTED].
    function test_indefiniteClaim_cannotBreachReserve() external {
        uint256 reserved = _openBothDeposits(10_000e18, 10_000e18);

        vm.warp(block.timestamp + 10 days);
        vm.prank(indefiniteStaker);
        try staking.claimDeposit(0) {} catch {}

        assertGe(
            staking.rewardPool(),
            reserved,
            "indefinite claimDeposit drained the pool below the reward reserved for a periodical deposit"
        );
    }

    /// @notice An indefinite withdraw (full or partial) must not reduce rewardPool below
    ///         totalDataList[REWARD_EXPECTED].
    function test_indefiniteWithdraw_cannotBreachReserve() external {
        uint256 reserved = _openBothDeposits(10_000e18, 10_000e18);

        vm.warp(block.timestamp + 10 days);
        vm.prank(indefiniteStaker);
        try staking.withdrawDeposit(0) {} catch {}
        vm.prank(indefiniteStaker);
        try staking.withdrawDepositPartial(0, 0) {} catch {}

        assertGe(
            staking.rewardPool(),
            reserved,
            "indefinite withdrawDeposit drained the pool below the reward reserved for a periodical deposit"
        );
    }

    /// @notice End-to-end impact: the periodical staker must be able to claim principal + reward at maturity
    ///         without anyone topping up the pool, regardless of what indefinite stakers did meanwhile.
    function test_periodicalPrincipalNeverLockedByIndefinitePayouts() external {
        uint256 principal = 10_000e18;
        uint256 reserved = _openBothDeposits(principal, 10_000e18);

        // Indefinite staker takes whatever the contract lets them take.
        vm.warp(block.timestamp + 10 days);
        vm.prank(indefiniteStaker);
        try staking.claimDeposit(0) {} catch {}

        // Periodical deposit matures. The pool covered REWARD_EXPECTED, so this can never fail.
        vm.warp(staking.getDeposit(periodicalStaker, 0).stakingEndDate);
        uint256 balBefore = token.balanceOf(periodicalStaker);
        vm.prank(periodicalStaker);
        staking.claimDeposit(0);
        assertEq(token.balanceOf(periodicalStaker) - balBefore, principal + reserved);
    }

    /// @notice With an EMPTY pool both stakes are accepted. The indefinite staker's full withdraw reverts
    ///         (nothing to pay the accrued reward with) but the opt-in partial withdraw returns principal with
    ///         no reward, the owner can collect nothing, and the periodical claim reverts with the typed
    ///         NotEnoughFundsInRewardPool (never a panic) until the owner tops up; then it pays in full.
    function test_poolShortFromTheStart_periodicalClaimWaitsForTopUp() external {
        uint256 principal = 10_000e18;
        uint256 reserved = staking.calculateReward(principal, APY, PERIOD);

        _stakeV(staking, periodicalStaker, 0, PERIOD, principal);
        _stakeV(staking, indefiniteStaker, 0, 0, principal);
        assertEq(staking.rewardPool(), 0);
        assertEq(staking.totalDataList(Types.DataType.REWARD_EXPECTED), reserved);
        assertEq(staking.getCollectableReward(), 0);
        assertGe(staking.getRewardPoolShortfall(), reserved, "shortfall includes the existing deficit");

        vm.prank(owner);
        (bool collected,) = address(staking).call(abi.encodeCall(staking.collectReward, (1)));
        assertFalse(collected, "owner cannot collect while the pool is short");

        vm.warp(block.timestamp + 10 days);
        uint256 accrued = staking.getDeposit(indefiniteStaker, 0).rewardGenerated;
        vm.prank(indefiniteStaker);
        vm.expectRevert(abi.encodeWithSelector(Errors.NotEnoughFundsInRewardPool.selector, accrued, 0));
        staking.withdrawDeposit(0);
        uint256 balBefore = token.balanceOf(indefiniteStaker);
        vm.prank(indefiniteStaker);
        staking.withdrawDepositPartial(0, 0);
        assertEq(token.balanceOf(indefiniteStaker) - balBefore, principal, "principal back, 0 reward");

        vm.warp(staking.getDeposit(periodicalStaker, 0).stakingEndDate);
        vm.prank(periodicalStaker);
        (bool ok, bytes memory reason) = address(staking).call(abi.encodeCall(staking.claimDeposit, (0)));
        assertFalse(ok);
        assertEq(_selectorOf(reason), Errors.NotEnoughFundsInRewardPool.selector, "typed revert, no panic");

        vm.prank(owner);
        staking.provideReward(reserved);
        balBefore = token.balanceOf(periodicalStaker);
        vm.prank(periodicalStaker);
        staking.claimDeposit(0);
        assertEq(token.balanceOf(periodicalStaker) - balBefore, principal + reserved, "no loss after top-up");
        assertEq(staking.rewardPool(), 0);
    }

    // ======================================
    // =          Seize (v0.4.0)            =
    // ======================================

    /// @notice Seizing a frozen indefinite deposit never pays its accrued reward. With the pool exactly at the
    ///         reserve the treasury gets principal only, the reserve is untouched and the periodical staker is
    ///         still paid at maturity.
    function test_indefiniteSeize_cannotBreachReserve() external {
        uint256 principal = 10_000e18;
        uint256 reserved = _openBothDeposits(principal, principal);

        vm.warp(block.timestamp + 10 days);
        assertGt(staking.getDeposit(indefiniteStaker, 0).rewardGenerated, 0, "reward accrued");
        _freezeAndSeize(indefiniteStaker, 0);

        assertEq(token.balanceOf(treasury), principal, "principal only: accrued reward is not collectable");
        assertEq(staking.rewardPool(), reserved, "reserve untouched");
        assertEq(staking.userDataList(Types.DataType.CLAIM, indefiniteStaker), 0);
        assertTrue(staking.checkDepositStatus(indefiniteStaker, 0) == ProgramManager.DepositStatus.SEIZED);

        vm.warp(staking.getDeposit(periodicalStaker, 0).stakingEndDate);
        uint256 balBefore = token.balanceOf(periodicalStaker);
        vm.prank(periodicalStaker);
        staking.claimDeposit(0);
        assertEq(token.balanceOf(periodicalStaker) - balBefore, principal + reserved);
    }

    /// @notice With an EMPTY pool a frozen periodical deposit is still seizable (never reverts): principal goes
    ///         to the treasury, only ITS reservation is released, and the other periodical deposit keeps its
    ///         reservation and is paid in full after a top-up.
    function test_periodicalSeize_emptyPool_neverReverts_releasesOnlyOwnReserve() external {
        uint256 principal = 10_000e18;
        uint256 reserved = staking.calculateReward(principal, APY, PERIOD);
        _stakeV(staking, periodicalStaker, 0, PERIOD, principal);
        _stakeV(staking, indefiniteStaker, 0, PERIOD, principal); // second periodical deposit
        assertEq(staking.totalDataList(Types.DataType.REWARD_EXPECTED), 2 * reserved);
        assertEq(staking.rewardPool(), 0);

        _freezeAndSeize(indefiniteStaker, 0);
        assertEq(token.balanceOf(treasury), principal, "principal only");
        assertEq(staking.totalDataList(Types.DataType.REWARD_EXPECTED), reserved, "only the seized reserve released");
        assertEq(staking.userDataList(Types.DataType.REWARD_EXPECTED, indefiniteStaker), 0);
        assertEq(staking.getDeposit(indefiniteStaker, 0).rewardGenerated, 0, "unpaid reward zeroed on the record");
        assertEq(token.balanceOf(address(staking)), staking.totalDataList(Types.DataType.STAKING) + staking.rewardPool());

        vm.warp(staking.getDeposit(periodicalStaker, 0).stakingEndDate);
        vm.prank(owner);
        staking.provideReward(reserved);
        uint256 balBefore = token.balanceOf(periodicalStaker);
        vm.prank(periodicalStaker);
        staking.claimDeposit(0);
        assertEq(token.balanceOf(periodicalStaker) - balBefore, principal + reserved);
        assertEq(staking.rewardPool(), 0);
    }

    /// @notice With a pool that covers every reservation, seizing a periodical deposit sends principal only: the
    ///         pool is untouched, the seized reservation becomes collectable and the other one stays reserved.
    function test_periodicalSeize_coveredPool_principalOnly_keepsOtherReserve() external {
        uint256 principal = 10_000e18;
        uint256 reserved = staking.calculateReward(principal, APY, PERIOD);
        vm.prank(owner);
        staking.provideReward(2 * reserved);
        _stakeV(staking, periodicalStaker, 0, PERIOD, principal);
        _stakeV(staking, indefiniteStaker, 0, PERIOD, principal);

        _freezeAndSeize(indefiniteStaker, 0);
        assertEq(token.balanceOf(treasury), principal, "principal only");
        assertEq(staking.rewardPool(), 2 * reserved, "pool untouched");
        assertEq(staking.totalDataList(Types.DataType.REWARD_EXPECTED), reserved);
        assertEq(staking.getCollectableReward(), reserved, "released reservation is collectable");
        assertEq(staking.userDataList(Types.DataType.CLAIM, indefiniteStaker), 0);

        vm.warp(staking.getDeposit(periodicalStaker, 0).stakingEndDate);
        uint256 balBefore = token.balanceOf(periodicalStaker);
        vm.prank(periodicalStaker);
        staking.claimDeposit(0);
        assertEq(token.balanceOf(periodicalStaker) - balBefore, principal + reserved);
    }
}
