// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";
import {ReentrantToken, ITokenHookReceiver} from "./mocks/ReentrantToken.sol";

/// @dev A staker that is a contract and tries to re-enter the vault from inside the token's
/// transfer hook. Every attempt is caught and recorded so the outer call completes and the
/// test can inspect what happened.
contract ReentrantStaker is ITokenHookReceiver {
    enum Mode {
        None,
        Withdraw,
        Claim,
        Stake,
        Exit,
        Fund
    }

    StakingVault public immutable vault;
    ReentrantToken public immutable token;
    Mode public mode;
    uint256 public attempts;
    bytes public lastError;

    constructor(StakingVault vault_, ReentrantToken token_) {
        vault = vault_;
        token = token_;
        token_.approve(address(vault_), type(uint256).max);
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function stake(uint256 amount) external {
        vault.stake(amount);
    }

    function withdraw(uint256 amount) external {
        vault.withdraw(amount);
    }

    function claim() external {
        vault.claim();
    }

    function exit() external {
        vault.exit();
    }

    function onTokenMoved(address, address, uint256) external {
        if (mode == Mode.None) return;
        Mode current = mode;
        mode = Mode.None; // one attempt per hook, no infinite recursion
        attempts += 1;
        bytes memory data;
        if (current == Mode.Withdraw) data = abi.encodeCall(StakingVault.withdraw, (1));
        else if (current == Mode.Claim) data = abi.encodeCall(StakingVault.claim, ());
        else if (current == Mode.Stake) data = abi.encodeCall(StakingVault.stake, (1));
        else if (current == Mode.Exit) data = abi.encodeCall(StakingVault.exit, ());
        else data = abi.encodeCall(StakingVault.fundRewards, (1));
        (bool ok, bytes memory err) = address(vault).call(data);
        require(!ok, "re-entrant call succeeded");
        lastError = err;
    }
}

/// forge-config: default.fuzz.runs = 1000
/// @dev Adversarial and boundary cases that the main suite does not reach: rounding at the rate
/// floor, period and lock boundaries to the second, extreme amounts, repeated cycles, hostile
/// tokens, re-entrancy, and calls from accounts that are not who the code assumed.
contract StakingVaultEdgeTest is Test {
    uint256 internal constant START = 1_700_000_000;
    uint256 internal constant DURATION = 7 days;
    uint256 internal constant LOCK = 7 days;
    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    /// A reward that gives a non-round rate, so rounding at the floor is exercised.
    uint256 internal constant ODD_REWARD = 1 ether + 7;
    /// A rounding allowance in wei for figures derived from the per-token accumulator.
    uint256 internal constant DUST = 1e3;

    LaunchToken internal token;
    StakingVault internal vault;

    address internal deployer;
    address internal alice;
    address internal bob;
    address internal whale;
    address internal funder;

    event Staked(address indexed account, uint256 amount, uint256 unlockTime);
    event RewardsFunded(address indexed funder, uint256 amount, uint256 rewardRate, uint256 periodFinish);

    function setUp() public {
        vm.warp(START);
        deployer = makeAddr("deployer");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        whale = makeAddr("whale");
        funder = makeAddr("funder");

        vm.prank(deployer);
        token = new LaunchToken();
        vault = new StakingVault(address(token), DURATION);

        vm.startPrank(deployer);
        token.transfer(alice, 10_000_000 ether);
        token.transfer(bob, 10_000_000 ether);
        token.transfer(whale, 900_000_000 ether);
        token.transfer(funder, 70_000_000 ether);
        vm.stopPrank();

        address[4] memory users = [alice, bob, whale, funder];
        for (uint256 i; i < users.length; ++i) {
            vm.prank(users[i]);
            token.approve(address(vault), type(uint256).max);
        }
    }

    function _stake(address who, uint256 amount) internal {
        vm.prank(who);
        vault.stake(amount);
    }

    function _fund(uint256 amount) internal {
        vm.prank(funder);
        vault.fundRewards(amount);
    }

    function _tryFund(address who, uint256 amount) internal returns (bool ok, bytes memory err) {
        vm.prank(who);
        (ok, err) = address(vault).call(abi.encodeCall(StakingVault.fundRewards, (amount)));
    }

    // ---------------------------------------------------------------------------------------
    // Rate floor: rounding at the boundary
    // ---------------------------------------------------------------------------------------

    /// The README says a mid-period top-up must be "at least what the current period has already
    /// streamed". With a non-round rate the exact streamed figure can fall short by rounding; two
    /// extra wei always clears the floor. This pins the real boundary so integrators can rely on it.
    function test_topUpOfExactStreamedAmountCanRevertByRounding() public {
        _stake(alice, 100 ether);
        _fund(ODD_REWARD);
        uint256 rate = vault.rewardRate();
        vm.warp(START + 12_345);
        uint256 streamed = (rate * 12_345) / PRECISION;

        (bool ok, bytes memory err) = _tryFund(funder, streamed);
        assertFalse(ok, "exact streamed amount accepted");
        assertEq(bytes4(err), StakingVault.RewardRateTooLow.selector);
        // Nothing changed on the failed call.
        assertEq(vault.rewardRate(), rate);
        assertEq(vault.periodFinish(), START + DURATION);

        _fund(streamed + 2);
        assertGe(vault.rewardRate(), rate);
        assertEq(vault.periodFinish(), START + 12_345 + DURATION);
    }

    function testFuzz_minimumTopUpIsStreamedPlusTwoWei(uint256 reward, uint256 elapsed, uint256 stakeAmount) public {
        // The funder holds 70M: the top-up below never exceeds the initial reward, so 35M each fits.
        reward = bound(reward, 1, 35_000_000 ether);
        elapsed = bound(elapsed, 1, DURATION - 1);
        stakeAmount = bound(stakeAmount, 1, 10_000_000 ether);
        _stake(alice, stakeAmount);
        _fund(reward);
        uint256 rate = vault.rewardRate();
        vm.warp(START + elapsed);
        uint256 streamed = (rate * elapsed) / PRECISION;

        if (streamed > 0) {
            (bool ok, bytes memory err) = _tryFund(funder, streamed - 1);
            if (streamed - 1 == 0) {
                assertFalse(ok, "zero top-up accepted mid period");
            } else {
                assertFalse(ok, "below-streamed top-up accepted");
                assertEq(bytes4(err), StakingVault.RewardRateTooLow.selector);
            }
        }
        uint256 earnedBefore = vault.earned(alice);
        uint256 snapshot = vm.snapshotState();
        _fund(streamed + 2);
        assertGe(vault.rewardRate(), rate, "rate lowered by a top-up");
        assertEq(vault.periodFinish(), START + elapsed + DURATION);
        assertEq(vault.earned(alice), earnedBefore, "top-up changed what was already earned");
        // Everything that was promised is still scheduled (within rounding).
        assertGe(vault.remainingRewards() + 2, (rate * DURATION) / PRECISION);
        vm.revertToState(snapshot);
    }

    function test_sameSecondRefundIsHarmlessRestart() public {
        _stake(alice, 100 ether);
        _fund(604_800 ether); // rate exactly 1e36
        uint256 rate = vault.rewardRate();
        // Zero-amount re-fund in the same second: rate and finish unchanged, nothing gained.
        vm.prank(bob);
        vault.fundRewards(0);
        assertEq(vault.rewardRate(), rate);
        assertEq(vault.periodFinish(), START + DURATION);
        assertEq(vault.remainingRewards(), 604_800 ether);
        // One wei in the same second is accepted and cannot lower the rate.
        vm.prank(bob);
        vault.fundRewards(1);
        assertGe(vault.rewardRate(), rate);
    }

    function test_fundOneSecondBeforeFinishStillEnforcesFloor() public {
        _stake(alice, 100 ether);
        _fund(604_800 ether);
        vm.warp(START + DURATION - 1);
        (bool ok, bytes memory err) = _tryFund(bob, 1 ether);
        assertFalse(ok);
        assertEq(bytes4(err), StakingVault.RewardRateTooLow.selector);
        assertEq(vault.rewardRate(), 1e36);
    }

    function test_fundAtExactPeriodFinishStartsFreshPeriodAtAnyRate() public {
        _stake(alice, 100 ether);
        _fund(604_800 ether);
        vm.warp(START + DURATION);
        uint256 earnedBefore = vault.earned(alice);
        assertApproxEqAbs(earnedBefore, 604_800 ether, DUST);
        vm.prank(bob);
        vault.fundRewards(1 ether);
        assertEq(vault.rewardRate(), (1 ether * PRECISION) / DURATION);
        assertEq(vault.periodFinish(), START + 2 * DURATION);
        // The first period's rewards are untouched by the new, slower period.
        assertEq(vault.earned(alice), earnedBefore);
        vm.warp(START + 2 * DURATION);
        assertApproxEqAbs(vault.earned(alice), earnedBefore + 1 ether, DUST);
    }

    function test_undistributedCannotBeRestartedMidPeriodButCanAtFinish() public {
        _fund(604_800 ether);
        vm.warp(START + 3 days); // 3 days streamed into `undistributed`
        _stake(alice, 100 ether);
        assertEq(vault.undistributed(), 3 days * 1 ether);
        vm.warp(START + 4 days); // alice has earned 1 day
        (bool ok, bytes memory err) = _tryFund(bob, 0);
        assertFalse(ok, "zero top-up accepted while stakers are owed part of the period");
        assertEq(bytes4(err), StakingVault.RewardRateTooLow.selector);

        vm.warp(START + DURATION);
        vm.prank(bob);
        vault.fundRewards(0);
        assertEq(vault.undistributed(), 0);
        // The re-streamed rate is 3 days' worth over 7 days, which rounds down by at most 1 wei.
        assertApproxEqAbs(vault.remainingRewards(), 3 days * 1 ether, 1);
        assertApproxEqAbs(vault.earned(alice), 4 days * 1 ether, DUST);
        vm.warp(START + 2 * DURATION);
        assertApproxEqAbs(vault.earned(alice), 7 days * 1 ether, DUST);
    }

    /// With the launch duration (7 days) even a one-wei funding streams at a non-zero rate.
    function test_launchDurationNeverTruncatesRateToZero() public {
        _stake(alice, 1);
        _fund(1);
        assertGt(vault.rewardRate(), 0);
        assertEq(vault.rewardRate(), PRECISION / DURATION);
        vm.warp(START + DURATION);
        // The single wei is either earned or stays as sub-wei rounding; never owed to nobody at a non-zero rate.
        assertLe(vault.earned(alice), 1);
    }

    // ---------------------------------------------------------------------------------------
    // Lock boundaries and lock resets
    // ---------------------------------------------------------------------------------------

    function test_claimDoesNotResetLock() public {
        _stake(alice, 100 ether);
        _fund(604_800 ether);
        vm.warp(START + 3 days);
        vm.prank(alice);
        vault.claim();
        assertEq(vault.unlockTime(alice), START + LOCK);
        vm.warp(START + LOCK);
        vm.prank(alice);
        vault.withdraw(100 ether);
    }

    function test_withdrawDoesNotResetLockForRemainder() public {
        _stake(alice, 100 ether);
        vm.warp(START + LOCK + 5 days);
        vm.prank(alice);
        vault.withdraw(1 ether);
        assertEq(vault.unlockTime(alice), START + LOCK);
        vm.prank(alice);
        vault.withdraw(99 ether);
        assertEq(vault.stakedBalance(alice), 0);
    }

    function test_restakeAfterUnlockRelocksWholeRemainder() public {
        _stake(alice, 100 ether);
        vm.warp(START + LOCK);
        vm.prank(alice);
        vault.withdraw(40 ether);
        _stake(alice, 1);
        assertEq(vault.unlockTime(alice), START + LOCK + LOCK);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.StillLocked.selector, START + 2 * LOCK));
        vault.withdraw(1);
        vm.warp(START + 2 * LOCK - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.StillLocked.selector, START + 2 * LOCK));
        vault.withdraw(60 ether);
    }

    function test_stakeTwiceInSameBlockSumsAndLocksOnce() public {
        vm.startPrank(alice);
        vault.stake(1);
        vault.stake(2);
        vm.stopPrank();
        assertEq(vault.stakedBalance(alice), 3);
        assertEq(vault.totalStaked(), 3);
        assertEq(vault.unlockTime(alice), START + LOCK);
    }

    function test_exitInStakeBlockReverts() public {
        _stake(alice, 100 ether);
        _fund(604_800 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.StillLocked.selector, START + LOCK));
        vault.exit();
        assertEq(vault.stakedBalance(alice), 100 ether);
    }

    /// A builder nudging the timestamp by a few seconds moves the unlock by exactly that much.
    function testFuzz_lockIsExactlySevenDaysFromLatestStake(uint256 firstAt, uint256 secondAt) public {
        firstAt = bound(firstAt, START, START + 365 days);
        secondAt = bound(secondAt, firstAt, firstAt + 30 days);
        vm.warp(firstAt);
        _stake(alice, 1 ether);
        assertEq(vault.unlockTime(alice), firstAt + 7 days);
        vm.warp(secondAt);
        _stake(alice, 1 ether);
        assertEq(vault.unlockTime(alice), secondAt + 7 days);
        vm.warp(secondAt + 7 days - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.StillLocked.selector, secondAt + 7 days));
        vault.withdraw(2 ether);
        vm.warp(secondAt + 7 days);
        vm.prank(alice);
        vault.withdraw(2 ether);
        assertEq(token.balanceOf(alice), 10_000_000 ether);
    }

    // ---------------------------------------------------------------------------------------
    // Rewards after a full unstake, exit without a position
    // ---------------------------------------------------------------------------------------

    function test_fullUnstakeKeepsAccruedRewardsAndStopsFurtherAccrual() public {
        _stake(alice, 100 ether);
        _stake(bob, 100 ether);
        _fund(604_800 ether);
        vm.warp(START + LOCK);
        vm.prank(alice);
        vault.withdraw(100 ether);
        uint256 owed = vault.earned(alice);
        assertApproxEqAbs(owed, 604_800 ether / 2, DUST);
        // A new period streams only to bob; alice's figure is frozen.
        _fund(604_800 ether);
        vm.warp(START + LOCK + DURATION);
        assertEq(vault.earned(alice), owed);
        // exit() has nothing to withdraw and reverts; claim() is the path for a closed position.
        vm.prank(alice);
        vm.expectRevert(StakingVault.ZeroAmount.selector);
        vault.exit();
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        vault.claim();
        assertEq(token.balanceOf(alice) - before, owed);
        assertEq(vault.earned(alice), 0);
    }

    function test_rewardPerTokenNeverDecreasesAndFreezesAfterFinish() public {
        _stake(alice, 100 ether);
        _fund(ODD_REWARD);
        uint256 last = vault.rewardPerToken();
        uint256 atFinish;
        for (uint256 t = 6 hours; t <= DURATION + 3 days; t += 6 hours) {
            vm.warp(START + t);
            uint256 now_ = vault.rewardPerToken();
            assertGe(now_, last);
            if (t == DURATION) atFinish = now_;
            if (t > DURATION) assertEq(now_, atFinish, "accumulator moved after the period ended");
            last = now_;
        }
        assertGt(atFinish, 0);
        assertLe(vault.lastUpdateTime(), vault.periodFinish());
    }

    // ---------------------------------------------------------------------------------------
    // Extreme amounts and dust positions
    // ---------------------------------------------------------------------------------------

    function test_wholeSupplyMinusRewardsCanBeStakedAndReturned() public {
        // Every token not held by the funder is staked by the whale and the others.
        uint256 rest = token.balanceOf(deployer);
        vm.prank(deployer);
        token.transfer(whale, rest);
        uint256 whaleBalance = token.balanceOf(whale);
        _stake(whale, whaleBalance);
        _stake(alice, 10_000_000 ether);
        _stake(bob, 10_000_000 ether);
        _fund(70_000_000 ether);
        assertEq(token.balanceOf(address(vault)), SUPPLY);
        vm.warp(START + DURATION);
        uint256 total = vault.earned(whale) + vault.earned(alice) + vault.earned(bob);
        assertLe(total, 70_000_000 ether);
        assertGe(total + DUST + SUPPLY / PRECISION, 70_000_000 ether);
        vm.startPrank(whale);
        vault.exit();
        vm.stopPrank();
        assertGe(token.balanceOf(whale), whaleBalance);
        assertEq(vault.stakedBalance(whale), 0);
        assertGe(token.balanceOf(address(vault)), vault.totalStaked() + vault.earned(alice) + vault.earned(bob));
    }

    function test_dustFundingAgainstHugeStakeLosesAtMostRoundingWei() public {
        _stake(whale, 900_000_000 ether);
        _fund(1 ether);
        vm.warp(START + DURATION);
        // At most totalStaked / 1e18 wei (here 9e8) is lost in the per-token accumulator per checkpoint.
        assertGe(vault.earned(whale), 1 ether - 900_000_000 - 1);
        assertLe(vault.earned(whale), 1 ether);
    }

    function test_oneWeiStakerBesideWhaleEarnsNothingButCanStillExit() public {
        _stake(whale, 900_000_000 ether);
        _stake(alice, 1);
        _fund(1 ether);
        vm.warp(START + DURATION);
        assertEq(vault.earned(alice), 0);
        assertGe(vault.earned(whale), 1 ether - 900_000_000 - 1);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        vault.exit();
        assertEq(token.balanceOf(alice), before + 1);
        assertEq(vault.stakedBalance(alice), 0);
    }

    function test_oneWeiStakerAloneEarnsWholeStream() public {
        _stake(alice, 1);
        _fund(604_800 ether);
        vm.warp(START + DURATION);
        assertEq(vault.earned(alice), 604_800 ether);
        vm.prank(alice);
        vault.exit();
        assertEq(token.balanceOf(alice), 10_000_000 ether + 604_800 ether);
    }

    function test_fiftyTopUpsAccumulateIntoOneClaimableStream() public {
        _stake(alice, 100 ether);
        uint256 funded;
        for (uint256 i; i < 50; ++i) {
            vm.warp(START + i * 1 hours);
            // Each top-up must clear the floor: streamed so far in this period plus a margin.
            uint256 streamed = vault.rewardRate() * (block.timestamp - vault.lastUpdateTime()) / PRECISION;
            uint256 amount = streamed + 1 ether;
            _fund(amount);
            funded += amount;
        }
        assertEq(vault.periodFinish(), START + 49 hours + DURATION);
        vm.warp(vault.periodFinish());
        uint256 owed = vault.earned(alice);
        assertLe(owed, funded);
        assertGe(owed + 50 * (100 + 4), funded);
        vm.prank(alice);
        vault.claim();
        assertEq(token.balanceOf(alice), 10_000_000 ether - 100 ether + owed);
    }

    // ---------------------------------------------------------------------------------------
    // Round trips: no profit from cycling principal
    // ---------------------------------------------------------------------------------------

    function testFuzz_stakeWithdrawCyclesNeverProfitWithoutRewards(uint256 amount, uint8 cycles) public {
        amount = bound(amount, 1, 10_000_000 ether);
        uint256 n = bound(cycles, 1, 12);
        for (uint256 i; i < n; ++i) {
            _stake(alice, amount);
            vm.warp(block.timestamp + LOCK);
            vm.prank(alice);
            vault.exit();
            assertEq(token.balanceOf(alice), 10_000_000 ether, "round trip changed the balance");
        }
        assertEq(token.balanceOf(address(vault)), 0);
        assertEq(vault.totalStaked(), 0);
    }

    function testFuzz_stakeWithdrawCyclesWithRewardsNeverExceedFunding(uint256 amount, uint256 reward, uint8 cycles)
        public
    {
        amount = bound(amount, 1, 10_000_000 ether);
        reward = bound(reward, 1, 70_000_000 ether);
        uint256 n = bound(cycles, 1, 6);
        _fund(reward);
        for (uint256 i; i < n; ++i) {
            _stake(alice, amount);
            vm.warp(block.timestamp + LOCK);
            vm.prank(alice);
            vault.exit();
        }
        assertLe(token.balanceOf(alice), 10_000_000 ether + reward);
        assertGe(token.balanceOf(alice), 10_000_000 ether);
        assertGe(token.balanceOf(address(vault)), vault.undistributed() + vault.remainingRewards());
    }

    // ---------------------------------------------------------------------------------------
    // Conservation across periods with churn
    // ---------------------------------------------------------------------------------------

    function testFuzz_rewardsConservedAcrossTwoPeriodsWithChurn(uint256 a, uint256 b, uint256 r1, uint256 r2, uint256 t)
        public
    {
        a = bound(a, 1, 10_000_000 ether);
        b = bound(b, 1, 10_000_000 ether);
        r1 = bound(r1, 1, 35_000_000 ether);
        r2 = bound(r2, 1, 35_000_000 ether);
        t = bound(t, 0, 3 * DURATION);
        _stake(alice, a);
        _fund(r1);
        vm.warp(START + LOCK);
        vm.prank(alice);
        vault.withdraw(a);
        _stake(bob, b);
        _fund(r2);
        vm.warp(START + LOCK + t);

        uint256 owed = vault.earned(alice) + vault.earned(bob);
        uint256 liabilities = owed + vault.remainingRewards() + vault.undistributed() + vault.totalStaked();
        assertGe(token.balanceOf(address(vault)), liabilities, "vault owes more than it holds");
        // What is not owed, scheduled or parked is rounding dust: a few checkpoints of < 1 wei each
        // plus the accumulator's totalStaked / 1e18 wei.
        assertLe(token.balanceOf(address(vault)) - liabilities, 6 * ((a + b) / PRECISION + 2));
    }

    // ---------------------------------------------------------------------------------------
    // Hostile tokens and re-entrancy
    // ---------------------------------------------------------------------------------------

    function test_tokenThatDeliversNothingIsRejected() public {
        FeeOnTransferToken burn = new FeeOnTransferToken(10_000, 1_000 ether); // 100% fee
        StakingVault burnVault = new StakingVault(address(burn), DURATION);
        burn.approve(address(burnVault), type(uint256).max);
        vm.expectRevert(StakingVault.ZeroAmount.selector);
        burnVault.stake(10 ether);
        vm.expectRevert(StakingVault.ZeroAmount.selector);
        burnVault.fundRewards(10 ether);
        assertEq(burnVault.totalStaked(), 0);
        assertEq(burnVault.rewardRate(), 0);
    }

    function test_eventsReportReceivedNotRequested() public {
        FeeOnTransferToken fee = new FeeOnTransferToken(100, 1_000 ether); // 1% fee
        StakingVault feeVault = new StakingVault(address(fee), DURATION);
        fee.approve(address(feeVault), type(uint256).max);
        vm.expectEmit(true, true, true, true, address(feeVault));
        emit Staked(address(this), 99 ether, START + LOCK);
        feeVault.stake(100 ether);
        vm.expectEmit(true, true, true, true, address(feeVault));
        emit RewardsFunded(address(this), 99 ether, (99 ether * PRECISION) / DURATION, START + DURATION);
        feeVault.fundRewards(100 ether);
    }

    function test_reentrancyFromTokenHooksIsBlockedOnEveryEntryPoint() public {
        ReentrantToken hook = new ReentrantToken(1_000 ether);
        StakingVault hookVault = new StakingVault(address(hook), DURATION);
        ReentrantStaker attacker = new ReentrantStaker(hookVault, hook);
        hook.transfer(address(attacker), 100 ether);
        hook.approve(address(hookVault), type(uint256).max);

        // Re-enter during stake's transferFrom (sender-side hook).
        attacker.setMode(ReentrantStaker.Mode.Stake);
        attacker.stake(50 ether);
        assertEq(attacker.attempts(), 1);
        assertEq(bytes4(attacker.lastError()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(hookVault.stakedBalance(address(attacker)), 50 ether);

        hookVault.fundRewards(70 ether);
        vm.warp(START + LOCK);

        // Re-enter during claim's transfer (recipient-side hook).
        attacker.setMode(ReentrantStaker.Mode.Claim);
        uint256 before = hook.balanceOf(address(attacker));
        uint256 owed = hookVault.earned(address(attacker));
        attacker.claim();
        assertEq(attacker.attempts(), 2);
        assertEq(bytes4(attacker.lastError()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(hook.balanceOf(address(attacker)) - before, owed, "claim paid other than once");

        // Re-enter withdraw, exit and fundRewards during a withdrawal.
        ReentrantStaker.Mode[3] memory modes =
            [ReentrantStaker.Mode.Withdraw, ReentrantStaker.Mode.Exit, ReentrantStaker.Mode.Fund];
        for (uint256 i; i < modes.length; ++i) {
            attacker.setMode(modes[i]);
            before = hook.balanceOf(address(attacker));
            attacker.withdraw(10 ether);
            assertEq(attacker.attempts(), 3 + i);
            assertEq(bytes4(attacker.lastError()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
            assertEq(hook.balanceOf(address(attacker)) - before, 10 ether, "withdraw paid other than once");
        }
        assertEq(hookVault.stakedBalance(address(attacker)), 20 ether);
        assertGe(hook.balanceOf(address(hookVault)), hookVault.totalStaked());
    }

    // ---------------------------------------------------------------------------------------
    // Callers who are not who the code assumed
    // ---------------------------------------------------------------------------------------

    function test_noEntryPointActsOnAnotherAccountsPosition() public {
        _stake(alice, 100 ether);
        _fund(604_800 ether);
        vm.warp(START + LOCK);
        address attacker = makeAddr("attacker");
        string[12] memory signatures = [
            "stakeFor(address,uint256)",
            "withdrawFor(address,uint256)",
            "claimFor(address)",
            "claim(address)",
            "getReward(address)",
            "exitFor(address)",
            "notifyRewardAmount(uint256)",
            "setRewardRate(uint256)",
            "setPeriodFinish(uint256)",
            "initialize(address,uint256)",
            "upgradeTo(address)",
            "renounceOwnership()"
        ];
        uint256 vaultBalance = token.balanceOf(address(vault));
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(attacker);
            (bool ok,) = address(vault).call(abi.encodeWithSignature(signatures[i], alice, uint256(100 ether)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(vault.stakedBalance(alice), 100 ether);
        assertEq(token.balanceOf(address(vault)), vaultBalance);
        assertEq(token.balanceOf(attacker), 0);
        assertApproxEqAbs(vault.earned(alice), 604_800 ether, DUST);
    }

    function test_vaultRejectsEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(vault).call{value: 1}("");
        assertFalse(ok);
        vm.prank(alice);
        (ok,) = address(vault).call{value: 1}(abi.encodeCall(StakingVault.claim, ()));
        assertFalse(ok);
        assertEq(address(vault).balance, 0);
    }

    function test_claimByNonStakerAfterOthersEarnPaysNothing() public {
        _stake(alice, 100 ether);
        _fund(604_800 ether);
        vm.warp(START + DURATION);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vault.claim();
        assertEq(token.balanceOf(stranger), 0);
        assertApproxEqAbs(vault.earned(alice), 604_800 ether, DUST);
    }

    function test_donationIsNeverPaidToAnyone() public {
        _stake(alice, 100 ether);
        _fund(604_800 ether);
        vm.prank(bob);
        token.transfer(address(vault), 1_000 ether);
        vm.warp(START + DURATION);
        vm.prank(alice);
        vault.exit();
        vm.prank(bob);
        vault.claim();
        // Only the donation (plus rounding dust) remains and nobody can reach it.
        assertGe(token.balanceOf(address(vault)), 1_000 ether);
        assertLe(token.balanceOf(address(vault)), 1_000 ether + DUST);
        assertEq(vault.earned(alice), 0);
        assertEq(vault.earned(bob), 0);
        assertEq(vault.remainingRewards(), 0);
        assertEq(vault.undistributed(), 0);
    }
}
