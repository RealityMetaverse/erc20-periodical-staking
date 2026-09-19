// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "./V050Base.sol";

/// @notice Absolute gas budgets for the hot paths (design item 9, spec section 11). All state is prepared in setUp so
///         each test body runs as a separate transaction with cold storage access, like a real call. The bounds are
///         the first measurement plus about 10% headroom; a regression such as unpacking PackedDeposit, a second
///         controller call or reintroducing per-user phase-period cells blows through them.
contract GasBudgetTest is V050Base {
    uint256 internal constant AMOUNT = 1_000 * ONE;
    uint256 internal constant CLAIM_ALL_COUNT = 10;

    // Measured on v0.4.0 (via_ir, runs 200): stake 152,113 (v0.3.0 with controller: 272,708), claimDeposit 182,096,
    // withdrawDeposit 135,233, claimAll over 10 deposits 331,793.
    uint256 internal constant STAKE_REPEAT_BUDGET = 167_000;
    uint256 internal constant CLAIM_DEPOSIT_BUDGET = 200_000;
    uint256 internal constant WITHDRAW_DEPOSIT_BUDGET = 149_000;
    uint256 internal constant CLAIM_ALL_10_BUDGET = 365_000;

    uint256 internal bobDeposit;
    uint256 internal adminDeposit;

    function setUp() public override {
        super.setUp();
        // alice: earlier stake into the same cell, so the repeat stake hits warm non-zero cells and nonce word.
        stakeFor(alice, P30, AMOUNT);
        // bob: one periodical deposit that matures below.
        bobDeposit = stakeFor(bob, P30, AMOUNT);
        // admin: a 90-day deposit that is still TIME_LEFT after the warp.
        adminDeposit = stakeFor(admin, P90, AMOUNT);
        // carol: ten matured deposits for claimAll.
        for (uint256 i = 0; i < CLAIM_ALL_COUNT; i++) {
            stakeFor(carol, P30, AMOUNT);
        }
        _warpDays(31);
    }

    function _check(string memory label, uint256 used, uint256 budget) internal {
        emit log_named_uint(label, used);
        if (budget != 0) assertLe(used, budget, label);
    }

    function test_gas_repeatStakeWithVoucher() external {
        Types.StakeVoucher memory v = voucherFor(alice, P30, 0, 0);
        bytes memory sig = signVoucher(v);
        uint256 expected = _baseApy(v.phase, P30);

        vm.prank(alice);
        uint256 g = gasleft();
        staking.stakeWithVoucher(v, sig, AMOUNT, expected);
        uint256 used = g - gasleft();

        _check("stakeWithVoucher (repeat)", used, STAKE_REPEAT_BUDGET);
        assertEq(_cell(alice, v.phase, P30), 2 * AMOUNT);
    }

    function test_gas_claimDeposit() external {
        assertEq(uint8(_status(bob, bobDeposit)), uint8(ProgramManager.DepositStatus.READY_TO_CLAIM));
        vm.prank(bob);
        uint256 g = gasleft();
        staking.claimDeposit(bobDeposit);
        uint256 used = g - gasleft();

        _check("claimDeposit", used, CLAIM_DEPOSIT_BUDGET);
        assertEq(uint8(_status(bob, bobDeposit)), uint8(ProgramManager.DepositStatus.CLAIMED));
    }

    function test_gas_withdrawDeposit() external {
        assertEq(uint8(_status(admin, adminDeposit)), uint8(ProgramManager.DepositStatus.TIME_LEFT));
        vm.prank(admin);
        uint256 g = gasleft();
        staking.withdrawDeposit(adminDeposit);
        uint256 used = g - gasleft();

        _check("withdrawDeposit", used, WITHDRAW_DEPOSIT_BUDGET);
        assertEq(uint8(_status(admin, adminDeposit)), uint8(ProgramManager.DepositStatus.WITHDRAWN));
    }

    function test_gas_claimAll10() external {
        vm.prank(carol);
        uint256 g = gasleft();
        staking.claimAll();
        uint256 used = g - gasleft();

        _check("claimAll (10 deposits)", used, CLAIM_ALL_10_BUDGET);
        assertEq(staking.stakerActiveDepositStartIndex(carol), CLAIM_ALL_COUNT);
        assertEq(_cell(carol, 0, P30), 0);
    }
}
