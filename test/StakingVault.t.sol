// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {StakingVault} from "../src/StakingVault.sol";
import {FeeOnTransferToken} from "./mocks/FeeOnTransferToken.sol";

contract StakingVaultTest is Test {
    uint256 internal constant START = 1_700_000_000;
    uint256 internal constant DURATION = 7 days;
    uint256 internal constant LOCK = 7 days;
    /// One token per second over a 7-day period: rewardRate == 1e36 exactly.
    uint256 internal constant REWARD = 604_800 ether;
    /// Rounding dust tolerated on reward figures (wei).
    uint256 internal constant DUST = 1e3;

    LaunchToken internal token;
    StakingVault internal vault;

    address internal deployer;
    address internal alice;
    address internal bob;
    address internal funder;

    event Staked(address indexed account, uint256 amount, uint256 unlockTime);
    event Withdrawn(address indexed account, uint256 amount);
    event RewardPaid(address indexed account, uint256 amount);
    event RewardsFunded(address indexed funder, uint256 amount, uint256 rewardRate, uint256 periodFinish);

    function setUp() public {
        vm.warp(START);
        deployer = makeAddr("deployer");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        funder = makeAddr("funder");

        vm.prank(deployer);
        token = new LaunchToken();
        vault = new StakingVault(address(token), DURATION);

        vm.startPrank(deployer);
        token.transfer(alice, 10_000_000 ether);
        token.transfer(bob, 10_000_000 ether);
        token.transfer(funder, 100_000_000 ether);
        vm.stopPrank();

        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        token.approve(address(vault), type(uint256).max);
        vm.prank(funder);
        token.approve(address(vault), type(uint256).max);
    }

    // ---------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------

    function _stake(address who, uint256 amount) internal {
        vm.prank(who);
        vault.stake(amount);
    }

    function _fund(uint256 amount) internal {
        vm.prank(funder);
        vault.fundRewards(amount);
    }

    // ---------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------

    function test_constructorSetsImmutables() public view {
        assertEq(address(vault.token()), address(token));
        assertEq(vault.rewardsDuration(), DURATION);
        assertEq(vault.LOCK_PERIOD(), 7 days);
        assertEq(vault.periodFinish(), 0);
        assertEq(vault.rewardRate(), 0);
        assertEq(vault.totalStaked(), 0);
    }

    function test_constructorRejectsZeroToken() public {
        vm.expectRevert(StakingVault.ZeroAddress.selector);
        new StakingVault(address(0), DURATION);
    }

    function test_constructorRejectsZeroDuration() public {
        vm.expectRevert(StakingVault.ZeroDuration.selector);
        new StakingVault(address(token), 0);
    }

    // ---------------------------------------------------------------------------------------
    // Staking
    // ---------------------------------------------------------------------------------------

    function test_stakeMovesTokensAndLocksForSevenDays() public {
        uint256 before = token.balanceOf(alice);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Staked(alice, 100 ether, START + LOCK);
        _stake(alice, 100 ether);

        assertEq(token.balanceOf(alice), before - 100 ether);
        assertEq(token.balanceOf(address(vault)), 100 ether);
        assertEq(vault.stakedBalance(alice), 100 ether);
        assertEq(vault.totalStaked(), 100 ether);
        assertEq(vault.unlockTime(alice), START + LOCK);
    }

    function test_stakeZeroReverts() public {
        vm.expectRevert(StakingVault.ZeroAmount.selector);
        _stake(alice, 0);
    }

    function test_stakeWithoutApprovalReverts() public {
        address carol = makeAddr("carol");
        vm.prank(deployer);
        token.transfer(carol, 1 ether);
        vm.prank(carol);
        vm.expectRevert();
        vault.stake(1 ether);
    }

    function test_stakeMoreThanBalanceReverts() public {
        uint256 tooMuch = token.balanceOf(alice) + 1;
        vm.prank(alice);
        vm.expectRevert();
        vault.stake(tooMuch);
    }

    function test_secondStakeResetsLockForWholePosition() public {
        _stake(alice, 100 ether);
        vm.warp(START + 5 days);
        _stake(alice, 50 ether);
        assertEq(vault.stakedBalance(alice), 150 ether);
        assertEq(vault.unlockTime(alice), START + 5 days + LOCK);

        vm.warp(START + LOCK);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.StillLocked.selector, START + 5 days + LOCK));
        vault.withdraw(100 ether);
    }

    function test_stakeOnlyAffectsCaller() public {
        _stake(alice, 100 ether);
        _stake(bob, 1 ether);
        assertEq(vault.unlockTime(alice), START + LOCK);
        assertEq(vault.stakedBalance(bob), 1 ether);
        assertEq(vault.stakedBalance(alice), 100 ether);
    }

    // ---------------------------------------------------------------------------------------
    // Withdrawing
    // ---------------------------------------------------------------------------------------

    function test_withdrawBeforeUnlockReverts() public {
        _stake(alice, 100 ether);
        vm.warp(START + LOCK - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.StillLocked.selector, START + LOCK));
        vault.withdraw(100 ether);
    }

    function test_withdrawAtExactUnlockSucceeds() public {
        _stake(alice, 100 ether);
        vm.warp(START + LOCK);
        vm.expectEmit(true, true, true, true, address(vault));
        emit Withdrawn(alice, 100 ether);
        vm.prank(alice);
        vault.withdraw(100 ether);
        assertEq(token.balanceOf(alice), 10_000_000 ether);
        assertEq(vault.stakedBalance(alice), 0);
        assertEq(vault.totalStaked(), 0);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_partialWithdrawKeepsRemainderStaked() public {
        _stake(alice, 100 ether);
        vm.warp(START + LOCK);
        vm.prank(alice);
        vault.withdraw(40 ether);
        assertEq(vault.stakedBalance(alice), 60 ether);
        assertEq(vault.totalStaked(), 60 ether);
        // The remainder stays withdrawable without a new lock.
        vm.prank(alice);
        vault.withdraw(60 ether);
        assertEq(vault.stakedBalance(alice), 0);
    }

    function test_withdrawMoreThanStakedReverts() public {
        _stake(alice, 100 ether);
        vm.warp(START + LOCK);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.InsufficientStake.selector, 100 ether, 101 ether));
        vault.withdraw(101 ether);
    }

    function test_withdrawZeroReverts() public {
        _stake(alice, 100 ether);
        vm.warp(START + LOCK);
        vm.prank(alice);
        vm.expectRevert(StakingVault.ZeroAmount.selector);
        vault.withdraw(0);
    }

    function test_nonStakerCannotWithdrawOthersPrincipal() public {
        _stake(alice, 100 ether);
        vm.warp(START + LOCK);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.InsufficientStake.selector, 0, 1));
        vault.withdraw(1);
        vm.prank(bob);
        vm.expectRevert(StakingVault.ZeroAmount.selector);
        vault.exit();
        assertEq(vault.stakedBalance(alice), 100 ether);
    }

    function test_noAdminEntryPointsCanTouchPrincipal() public {
        _stake(alice, 100 ether);
        address attacker = makeAddr("attacker");
        string[8] memory signatures = [
            "emergencyWithdraw()",
            "sweep(address)",
            "recoverERC20(address,uint256)",
            "rescueTokens(address,uint256)",
            "withdrawFor(address,uint256)",
            "transferOwnership(address)",
            "pause()",
            "setRewardsDuration(uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(attacker);
            (bool ok,) = address(vault).call(abi.encodeWithSignature(signatures[i], attacker, uint256(100 ether)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.balanceOf(address(vault)), 100 ether);
        assertEq(vault.stakedBalance(alice), 100 ether);
        assertEq(token.balanceOf(attacker), 0);
    }

    // ---------------------------------------------------------------------------------------
    // Funding
    // ---------------------------------------------------------------------------------------

    function test_fundRewardsStartsPeriod() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit RewardsFunded(funder, REWARD, 1e36, START + DURATION);
        _fund(REWARD);
        assertEq(vault.rewardRate(), 1e36);
        assertEq(vault.periodFinish(), START + DURATION);
        assertEq(vault.lastUpdateTime(), START);
        assertEq(token.balanceOf(address(vault)), REWARD);
        assertEq(vault.remainingRewards(), REWARD);
    }

    function test_anyoneCanFund() public {
        vm.prank(bob);
        vault.fundRewards(1 ether);
        assertEq(vault.periodFinish(), START + DURATION);
        assertEq(vault.rewardRate(), (1 ether * 1e18) / DURATION);
    }

    function test_fundZeroWithNothingPendingReverts() public {
        vm.expectRevert(StakingVault.ZeroAmount.selector);
        _fund(0);
    }

    function test_fundWithoutApprovalReverts() public {
        address carol = makeAddr("carol");
        vm.prank(deployer);
        token.transfer(carol, 1 ether);
        vm.prank(carol);
        vm.expectRevert();
        vault.fundRewards(1 ether);
    }

    function test_fundingDoesNotCreditStakeOrPrincipal() public {
        _fund(REWARD);
        assertEq(vault.totalStaked(), 0);
        assertEq(vault.stakedBalance(funder), 0);
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.InsufficientStake.selector, 0, 1));
        vault.withdraw(1);
    }

    function test_topUpMidPeriodRollsRemainderAndExtends() public {
        _stake(alice, 100 ether);
        _fund(REWARD);
        vm.warp(START + 3 days);
        // 3 days streamed (3/7 of REWARD); topping up with at least that keeps the rate.
        uint256 streamed = 3 days * 1 ether;
        _fund(streamed);
        assertEq(vault.periodFinish(), START + 3 days + DURATION);
        assertEq(vault.rewardRate(), 1e36);
        assertApproxEqAbs(vault.remainingRewards(), REWARD, DUST);
        assertApproxEqAbs(vault.earned(alice), streamed, DUST);
    }

    function test_topUpBelowCurrentRateReverts() public {
        _stake(alice, 100 ether);
        _fund(REWARD);
        vm.warp(START + 3 days);
        uint256 streamed = 3 days * 1 ether;
        uint256 proposed = ((REWARD - streamed + 1 ether) * 1e18) / DURATION;
        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.RewardRateTooLow.selector, 1e36, proposed));
        vault.fundRewards(1 ether);
        // The stream is untouched.
        assertEq(vault.rewardRate(), 1e36);
        assertEq(vault.periodFinish(), START + DURATION);
    }

    function test_fundZeroDuringPeriodCannotSlowStream() public {
        _stake(alice, 100 ether);
        _fund(REWARD);
        vm.warp(START + 1);
        vm.prank(bob);
        vm.expectRevert();
        vault.fundRewards(0);
    }

    function test_fundAfterPeriodEndsStartsFreshPeriod() public {
        _stake(alice, 100 ether);
        _fund(REWARD);
        vm.warp(START + DURATION + 1 days);
        _fund(2 * REWARD);
        assertEq(vault.rewardRate(), 2e36);
        assertEq(vault.periodFinish(), START + DURATION + 1 days + DURATION);
        assertApproxEqAbs(vault.earned(alice), REWARD, DUST);
    }

    // ---------------------------------------------------------------------------------------
    // Reward accrual
    // ---------------------------------------------------------------------------------------

    function test_singleStakerEarnsWholeStream() public {
        _stake(alice, 100 ether);
        _fund(REWARD);
        vm.warp(START + DURATION / 2);
        assertApproxEqAbs(vault.earned(alice), REWARD / 2, DUST);
        vm.warp(START + DURATION);
        assertApproxEqAbs(vault.earned(alice), REWARD, DUST);
        // Nothing accrues after the period ends.
        vm.warp(START + DURATION + 30 days);
        assertApproxEqAbs(vault.earned(alice), REWARD, DUST);
    }

    function test_rewardsSplitProRataToStake() public {
        _stake(alice, 100 ether);
        _stake(bob, 300 ether);
        _fund(REWARD);
        vm.warp(START + DURATION);
        assertApproxEqAbs(vault.earned(alice), REWARD / 4, DUST);
        assertApproxEqAbs(vault.earned(bob), (REWARD * 3) / 4, DUST);
    }

    function test_lateStakerOnlyEarnsFromJoining() public {
        _stake(alice, 100 ether);
        _fund(REWARD);
        vm.warp(START + DURATION / 2);
        _stake(bob, 100 ether);
        vm.warp(START + DURATION);
        // Alice: all of the first half plus half of the second half.
        assertApproxEqAbs(vault.earned(alice), (REWARD * 3) / 4, DUST);
        assertApproxEqAbs(vault.earned(bob), REWARD / 4, DUST);
    }

    function test_rewardsStreamPerSecond() public {
        _stake(alice, 100 ether);
        _fund(REWARD);
        vm.warp(START + 1);
        assertApproxEqAbs(vault.earned(alice), 1 ether, DUST);
        vm.warp(START + 1000);
        assertApproxEqAbs(vault.earned(alice), 1000 ether, DUST);
    }

    function test_noRewardsBeforeFunding() public {
        _stake(alice, 100 ether);
        vm.warp(START + 30 days);
        assertEq(vault.earned(alice), 0);
        assertEq(vault.rewardPerToken(), 0);
    }

    function test_rewardsWhileNobodyStakedRollIntoNextFunding() public {
        _fund(REWARD);
        vm.warp(START + DURATION + 1);
        assertEq(vault.earned(alice), 0);
        // Nothing streamed to anyone; the next funding re-streams it.
        _stake(alice, 100 ether);
        assertEq(vault.undistributed(), REWARD);
        _fund(1 ether);
        assertEq(vault.undistributed(), 0);
        assertApproxEqAbs(vault.remainingRewards(), REWARD + 1 ether, DUST);
        vm.warp(START + DURATION + 1 + DURATION);
        assertApproxEqAbs(vault.earned(alice), REWARD + 1 ether, DUST);
    }

    function test_undistributedTrackedWhenEveryoneExits() public {
        _stake(alice, 100 ether);
        _fund(REWARD);
        vm.warp(START + LOCK);
        vm.prank(alice);
        vault.exit();
        // Everyone left at the end of the lock, which equals the period end here; make the
        // stream outlive the stakers to test the gap.
        _fund(REWARD);
        vm.warp(START + LOCK + 2 days);
        _stake(bob, 1 ether);
        assertEq(vault.undistributed(), 2 days * 1 ether);
        assertEq(vault.earned(bob), 0);
    }

    function test_zeroAmountFundRestartsLeftoversWhenIdle() public {
        _fund(REWARD);
        vm.warp(START + DURATION);
        _stake(alice, 100 ether);
        assertEq(vault.undistributed(), REWARD);
        vm.prank(bob);
        vault.fundRewards(0);
        assertEq(vault.undistributed(), 0);
        assertEq(vault.rewardRate(), 1e36);
        assertEq(vault.periodFinish(), START + 2 * DURATION);
    }

    // ---------------------------------------------------------------------------------------
    // Claiming and exiting
    // ---------------------------------------------------------------------------------------

    function test_claimPaysAndResets() public {
        _stake(alice, 100 ether);
        _fund(REWARD);
        vm.warp(START + 1 days);
        uint256 expected = 1 days * 1 ether;
        uint256 before = token.balanceOf(alice);
        vm.expectEmit(true, false, false, false, address(vault));
        emit RewardPaid(alice, expected);
        vm.prank(alice);
        vault.claim();
        assertApproxEqAbs(token.balanceOf(alice) - before, expected, DUST);
        assertEq(vault.earned(alice), 0);
        assertEq(vault.rewards(alice), 0);
        // Principal is untouched and still locked.
        assertEq(vault.stakedBalance(alice), 100 ether);
        assertEq(token.balanceOf(address(vault)), 100 ether + REWARD - (token.balanceOf(alice) - before));
    }

    function test_claimWhileLockedIsAllowed() public {
        _stake(alice, 100 ether);
        _fund(REWARD);
        vm.warp(START + 1);
        vm.prank(alice);
        vault.claim();
        assertApproxEqAbs(token.balanceOf(alice), 10_000_000 ether - 100 ether + 1 ether, DUST);
    }

    function test_claimWithNothingEarnedIsNoop() public {
        uint256 before = token.balanceOf(bob);
        vm.prank(bob);
        vault.claim();
        assertEq(token.balanceOf(bob), before);
    }

    function test_claimTwiceDoesNotPayTwice() public {
        _stake(alice, 100 ether);
        _fund(REWARD);
        vm.warp(START + 1 days);
        vm.prank(alice);
        vault.claim();
        uint256 afterFirst = token.balanceOf(alice);
        vm.prank(alice);
        vault.claim();
        assertEq(token.balanceOf(alice), afterFirst);
    }

    function test_rewardsKeepAccruingAfterClaim() public {
        _stake(alice, 100 ether);
        _fund(REWARD);
        vm.warp(START + 1 days);
        vm.prank(alice);
        vault.claim();
        vm.warp(START + 2 days);
        assertApproxEqAbs(vault.earned(alice), 1 days * 1 ether, DUST);
    }

    function test_exitReturnsPrincipalAndRewards() public {
        _stake(alice, 100 ether);
        _fund(REWARD);
        vm.warp(START + LOCK);
        vm.prank(alice);
        vault.exit();
        assertApproxEqAbs(token.balanceOf(alice), 10_000_000 ether + REWARD, DUST);
        assertEq(vault.stakedBalance(alice), 0);
        assertEq(vault.totalStaked(), 0);
        assertEq(vault.earned(alice), 0);
        // Only rounding dust remains in the vault.
        assertLe(token.balanceOf(address(vault)), DUST);
    }

    function test_exitWhileLockedReverts() public {
        _stake(alice, 100 ether);
        _fund(REWARD);
        vm.warp(START + LOCK - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(StakingVault.StillLocked.selector, START + LOCK));
        vault.exit();
    }

    function test_withdrawnPrincipalStopsEarning() public {
        _stake(alice, 100 ether);
        _stake(bob, 100 ether);
        _fund(REWARD);
        vm.warp(START + LOCK);
        vm.prank(alice);
        vault.withdraw(100 ether);
        // Start a second stream; only bob is staked now.
        _fund(REWARD);
        vm.warp(START + LOCK + DURATION);
        assertApproxEqAbs(vault.earned(alice), REWARD / 2, DUST);
        assertApproxEqAbs(vault.earned(bob), REWARD / 2 + REWARD, DUST);
    }

    // ---------------------------------------------------------------------------------------
    // Principal safety and conservation
    // ---------------------------------------------------------------------------------------

    function test_rewardPayoutsNeverDipIntoPrincipal() public {
        _stake(alice, 100 ether);
        _stake(bob, 100 ether);
        _fund(REWARD);
        vm.warp(START + DURATION + 1);
        vm.prank(alice);
        vault.claim();
        vm.prank(bob);
        vault.claim();
        assertGe(token.balanceOf(address(vault)), vault.totalStaked());
        assertEq(vault.totalStaked(), 200 ether);
        vm.warp(START + LOCK + 1);
        vm.prank(alice);
        vault.withdraw(100 ether);
        vm.prank(bob);
        vault.withdraw(100 ether);
        assertGe(token.balanceOf(alice), 10_000_000 ether);
        assertGe(token.balanceOf(bob), 10_000_000 ether);
    }

    function test_directTransferDoesNotChangeAccounting() public {
        _stake(alice, 100 ether);
        vm.prank(bob);
        token.transfer(address(vault), 1_000 ether);
        assertEq(vault.totalStaked(), 100 ether);
        assertEq(vault.earned(alice), 0);
        assertEq(vault.remainingRewards(), 0);
    }

    function test_feeOnTransferTokenIsCreditedAtReceivedAmount() public {
        FeeOnTransferToken fee = new FeeOnTransferToken(100, 1_000_000 ether); // 1% fee
        StakingVault feeVault = new StakingVault(address(fee), DURATION);
        fee.transfer(alice, 1_000 ether);
        vm.startPrank(alice);
        fee.approve(address(feeVault), type(uint256).max);
        feeVault.stake(100 ether);
        vm.stopPrank();
        assertEq(feeVault.stakedBalance(alice), 99 ether);
        assertEq(feeVault.totalStaked(), 99 ether);
        assertEq(fee.balanceOf(address(feeVault)), 99 ether);

        fee.approve(address(feeVault), type(uint256).max);
        feeVault.fundRewards(100 ether);
        assertApproxEqAbs(feeVault.remainingRewards(), 99 ether, DUST);
        assertEq(fee.balanceOf(address(feeVault)), 198 ether);
    }

    function test_rewardTokenIsStakingToken() public view {
        assertEq(address(vault.token()), address(token));
        assertEq(IERC20(address(vault.token())).balanceOf(address(vault)), 0);
    }

    // ---------------------------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------------------------

    function testFuzz_withdrawReturnsExactlyWhatWasStaked(uint256 amount, uint256 wait) public {
        amount = bound(amount, 1, 10_000_000 ether);
        wait = bound(wait, LOCK, 365 days);
        _stake(alice, amount);
        _fund(REWARD);
        vm.warp(START + wait);
        vm.prank(alice);
        vault.withdraw(amount);
        assertEq(token.balanceOf(alice), 10_000_000 ether);
        assertEq(vault.stakedBalance(alice), 0);
        assertGe(token.balanceOf(address(vault)), vault.earned(alice));
    }

    function testFuzz_earnedNeverExceedsFundedAndRewardsAreProRata(uint256 a, uint256 b, uint256 reward, uint256 t)
        public
    {
        a = bound(a, 1, 10_000_000 ether);
        b = bound(b, 1, 10_000_000 ether);
        reward = bound(reward, 1, 100_000_000 ether);
        t = bound(t, 0, 2 * DURATION);
        _stake(alice, a);
        _stake(bob, b);
        _fund(reward);
        vm.warp(START + t);

        uint256 ea = vault.earned(alice);
        uint256 eb = vault.earned(bob);
        assertLe(ea + eb, reward);
        uint256 elapsed = t > DURATION ? DURATION : t;
        uint256 streamed = (vault.rewardRate() * elapsed) / 1e18;
        // Rounding loses at most 1 wei per staker plus (a + b) / 1e18 wei from the per-token accumulator.
        assertGe(ea + eb + (a + b) / 1e18 + 2, streamed);
        // Pro rata: ea / a == eb / b up to rounding.
        assertApproxEqAbs((ea * b) / 1e18, (eb * a) / 1e18, (a + b) / 1e18 + 1);
    }

    function testFuzz_lockBoundary(uint256 wait) public {
        wait = bound(wait, 0, 2 * LOCK);
        _stake(alice, 1 ether);
        vm.warp(START + wait);
        vm.prank(alice);
        if (wait < LOCK) {
            vm.expectRevert(abi.encodeWithSelector(StakingVault.StillLocked.selector, START + LOCK));
            vault.withdraw(1 ether);
        } else {
            vault.withdraw(1 ether);
            assertEq(vault.stakedBalance(alice), 0);
        }
    }
}
