// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {StakingVault} from "../src/StakingVault.sol";

/// @dev Second handler, complementary to `StakingVaultHandler`: six actors from a whale holding
/// a third of the supply down to a dust account holding a few hundred wei, full-balance
/// operations, warps that land exactly on unlock times and period ends, adversarial calls that
/// must revert, and per-actor and monotonicity ghosts. Every guarded call is expected to
/// succeed, so the suite runs with fail_on_revert; an unexpected revert is a finding.
contract LifecycleHandler is Test {
    uint256 internal constant PRECISION = 1e18;

    LaunchToken public immutable token;
    StakingVault public immutable vault;

    address[] public actors;
    address internal currentActor;

    // Per-actor ghosts.
    mapping(address => uint256) public deposited;
    mapping(address => uint256) public withdrawn;
    mapping(address => uint256) public claimed;
    mapping(address => uint256) public fundedBy;
    mapping(address => uint256) public donatedBy;
    mapping(address => uint256) public initialBalance;

    // Global ghosts.
    uint256 public totalFunded;
    uint256 public totalDonated;
    uint256 public totalClaimed;
    uint256 public vaultCalls;
    uint256 public maxRewardPerToken;
    uint256 public maxPeriodFinish;
    uint256 public maxLastUpdateTime;

    // Violations recorded by handler post-conditions, asserted by the invariants.
    bool public rewardPerTokenDecreased;
    bool public periodFinishDecreased;
    bool public rateLoweredWhileActive;
    bool public lastUpdateTimeDecreased;
    bool public lockBroken;
    bool public principalMismatch;
    bool public rewardMismatch;
    bool public adversarialCallSucceeded;
    uint256 public adversarialAttempts;

    constructor(LaunchToken token_, StakingVault vault_, address[] memory actors_) {
        token = token_;
        vault = vault_;
        actors = actors_;
        for (uint256 i; i < actors_.length; ++i) {
            initialBalance[actors_[i]] = token_.balanceOf(actors_[i]);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    modifier useActor(uint256 seed) {
        currentActor = actors[seed % actors.length];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    /// @dev Snapshots the stream's monotonic figures before a call and checks them after it.
    modifier tracked() {
        uint256 rptBefore = vault.rewardPerToken();
        uint256 finishBefore = vault.periodFinish();
        uint256 rateBefore = vault.rewardRate();
        uint256 lastUpdateBefore = vault.lastUpdateTime();
        bool wasActive = block.timestamp < finishBefore;
        _;
        vaultCalls += 1;
        uint256 rptAfter = vault.rewardPerToken();
        if (rptAfter < rptBefore) rewardPerTokenDecreased = true;
        if (vault.periodFinish() < finishBefore) periodFinishDecreased = true;
        if (wasActive && vault.rewardRate() < rateBefore) rateLoweredWhileActive = true;
        if (vault.lastUpdateTime() < lastUpdateBefore) lastUpdateTimeDecreased = true;
        if (rptAfter > maxRewardPerToken) maxRewardPerToken = rptAfter;
        if (vault.periodFinish() > maxPeriodFinish) maxPeriodFinish = vault.periodFinish();
        if (vault.lastUpdateTime() > maxLastUpdateTime) maxLastUpdateTime = vault.lastUpdateTime();
    }

    // ---------------------------------------------------------------------------------------
    // Staker actions (guarded so that every call is expected to succeed)
    // ---------------------------------------------------------------------------------------

    function stake(uint256 seed, uint256 amount) external useActor(seed) tracked {
        uint256 balance = token.balanceOf(currentActor);
        if (balance == 0) return;
        // One call in five stakes the whole balance (full-amount operation).
        amount = seed % 5 == 0 ? balance : bound(amount, 1, balance);
        uint256 stakedBefore = vault.stakedBalance(currentActor);
        uint256 earnedBefore = vault.earned(currentActor);
        vault.stake(amount);
        deposited[currentActor] += amount;
        if (vault.stakedBalance(currentActor) != stakedBefore + amount) principalMismatch = true;
        if (vault.unlockTime(currentActor) != block.timestamp + vault.LOCK_PERIOD()) lockBroken = true;
        if (vault.earned(currentActor) != earnedBefore) rewardMismatch = true;
    }

    function withdraw(uint256 seed, uint256 amount) external useActor(seed) tracked {
        uint256 staked = vault.stakedBalance(currentActor);
        if (staked == 0 || block.timestamp < vault.unlockTime(currentActor)) return;
        amount = seed % 5 == 0 ? staked : bound(amount, 1, staked);
        uint256 before = token.balanceOf(currentActor);
        uint256 earnedBefore = vault.earned(currentActor);
        vault.withdraw(amount);
        withdrawn[currentActor] += amount;
        if (token.balanceOf(currentActor) - before != amount) principalMismatch = true;
        if (vault.stakedBalance(currentActor) != staked - amount) principalMismatch = true;
        if (vault.earned(currentActor) != earnedBefore) rewardMismatch = true;
    }

    function claim(uint256 seed) external useActor(seed) tracked {
        uint256 before = token.balanceOf(currentActor);
        uint256 owed = vault.earned(currentActor);
        uint256 stakedBefore = vault.stakedBalance(currentActor);
        vault.claim();
        uint256 paid = token.balanceOf(currentActor) - before;
        claimed[currentActor] += paid;
        totalClaimed += paid;
        if (paid != owed || vault.earned(currentActor) != 0) rewardMismatch = true;
        if (vault.stakedBalance(currentActor) != stakedBefore) principalMismatch = true;
    }

    function exit(uint256 seed) external useActor(seed) tracked {
        uint256 staked = vault.stakedBalance(currentActor);
        if (staked == 0 || block.timestamp < vault.unlockTime(currentActor)) return;
        uint256 before = token.balanceOf(currentActor);
        uint256 owed = vault.earned(currentActor);
        vault.exit();
        uint256 received = token.balanceOf(currentActor) - before;
        withdrawn[currentActor] += staked;
        claimed[currentActor] += received - staked;
        totalClaimed += received - staked;
        if (received != staked + owed) rewardMismatch = true;
        if (vault.stakedBalance(currentActor) != 0 || vault.earned(currentActor) != 0) principalMismatch = true;
    }

    // ---------------------------------------------------------------------------------------
    // Funding
    // ---------------------------------------------------------------------------------------

    /// @dev Rewards streamed since the last checkpoint while nothing was staked. The vault moves
    /// them into `undistributed` on its next call; until then they are in no view.
    function pendingUndistributed() public view returns (uint256) {
        if (vault.totalStaked() != 0) return 0;
        uint256 applicable = vault.lastTimeRewardApplicable();
        uint256 last = vault.lastUpdateTime();
        return applicable > last ? (vault.rewardRate() * (applicable - last)) / PRECISION : 0;
    }

    /// @dev Smallest amount a mid-period funding needs so that the new rate is not below the
    /// current one: ceil(rate * duration / 1e18) minus what is already parked or scheduled.
    function _minimumFunding() internal view returns (uint256) {
        if (block.timestamp >= vault.periodFinish()) return 0;
        uint256 need = (vault.rewardRate() * vault.rewardsDuration() + PRECISION - 1) / PRECISION;
        uint256 have = vault.undistributed() + pendingUndistributed() + vault.remainingRewards();
        return need > have ? need - have : 0;
    }

    function fund(uint256 seed, uint256 amount) external useActor(seed) tracked {
        uint256 balance = token.balanceOf(currentActor);
        uint256 minimum = _minimumFunding();
        if (minimum == 0) minimum = 1;
        if (balance < minimum) return;
        amount = bound(amount, minimum, balance);
        uint256 rateBefore = vault.rewardRate();
        uint256 finishBefore = vault.periodFinish();
        vault.fundRewards(amount);
        fundedBy[currentActor] += amount;
        totalFunded += amount;
        if (block.timestamp < finishBefore && vault.rewardRate() < rateBefore) rateLoweredWhileActive = true;
    }

    /// @dev Restart leftovers with a zero-amount call whenever the vault would accept it.
    function fundZero(uint256 seed) external useActor(seed) tracked {
        uint256 have = vault.undistributed() + pendingUndistributed() + vault.remainingRewards();
        if (have == 0) return;
        if (_minimumFunding() != 0) return;
        uint256 rateBefore = vault.rewardRate();
        bool wasActive = block.timestamp < vault.periodFinish();
        vault.fundRewards(0);
        if (vault.undistributed() != 0) rewardMismatch = true;
        if (wasActive && vault.rewardRate() < rateBefore) rateLoweredWhileActive = true;
    }

    /// @dev Someone sending tokens straight to the vault. Tracked so the dust bound can allow for it.
    function donate(uint256 seed, uint256 amount) external useActor(seed) tracked {
        uint256 balance = token.balanceOf(currentActor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance / 10 + 1);
        if (amount > balance) return;
        token.transfer(address(vault), amount);
        donatedBy[currentActor] += amount;
        totalDonated += amount;
    }

    // ---------------------------------------------------------------------------------------
    // Time
    // ---------------------------------------------------------------------------------------

    function warp(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 8 days);
        vm.warp(block.timestamp + seconds_);
    }

    function warpToUnlock(uint256 seed) external {
        uint256 unlockAt = vault.unlockTime(actors[seed % actors.length]);
        if (unlockAt > block.timestamp) vm.warp(unlockAt);
    }

    function warpToPeriodFinish(uint256 seed) external {
        uint256 finish = vault.periodFinish();
        if (finish <= block.timestamp) return;
        // Land on the end, or one second either side of it.
        uint256 target = seed % 3 == 0 ? finish - 1 : (seed % 3 == 1 ? finish : finish + 1);
        if (target > block.timestamp) vm.warp(target);
    }

    // ---------------------------------------------------------------------------------------
    // Adversarial calls that must revert and must change nothing
    // ---------------------------------------------------------------------------------------

    function attemptEarlyWithdraw(uint256 seed) external useActor(seed) tracked {
        uint256 staked = vault.stakedBalance(currentActor);
        if (staked == 0 || block.timestamp >= vault.unlockTime(currentActor)) return;
        adversarialAttempts += 1;
        uint256 before = token.balanceOf(currentActor);
        (bool ok,) = address(vault).call(abi.encodeCall(StakingVault.withdraw, (staked)));
        if (ok) adversarialCallSucceeded = true;
        (ok,) = address(vault).call(abi.encodeCall(StakingVault.exit, ()));
        if (ok) adversarialCallSucceeded = true;
        if (vault.stakedBalance(currentActor) != staked || token.balanceOf(currentActor) != before) lockBroken = true;
    }

    function attemptOverWithdraw(uint256 seed) external useActor(seed) tracked {
        uint256 staked = vault.stakedBalance(currentActor);
        adversarialAttempts += 1;
        uint256 before = token.balanceOf(currentActor);
        (bool ok,) = address(vault).call(abi.encodeCall(StakingVault.withdraw, (staked + 1)));
        if (ok) adversarialCallSucceeded = true;
        // Someone else's whole position, from an account that does not hold it.
        uint256 other = vault.totalStaked() - staked;
        if (other > staked) {
            (ok,) = address(vault).call(abi.encodeCall(StakingVault.withdraw, (other)));
            if (ok) adversarialCallSucceeded = true;
        }
        if (vault.stakedBalance(currentActor) != staked || token.balanceOf(currentActor) != before) {
            principalMismatch = true;
        }
    }

    function attemptSlowStream(uint256 seed) external useActor(seed) tracked {
        uint256 minimum = _minimumFunding();
        if (minimum < 2) return; // nothing to undercut
        adversarialAttempts += 1;
        if (token.balanceOf(currentActor) < minimum - 1) return;
        uint256 rateBefore = vault.rewardRate();
        uint256 finishBefore = vault.periodFinish();
        (bool ok,) = address(vault).call(abi.encodeCall(StakingVault.fundRewards, (minimum - 1)));
        if (ok) {
            // Keep the ghosts honest even on the way to a failure report.
            adversarialCallSucceeded = true;
            fundedBy[currentActor] += minimum - 1;
            totalFunded += minimum - 1;
        }
        (ok,) = address(vault).call(abi.encodeCall(StakingVault.fundRewards, (0)));
        if (ok) adversarialCallSucceeded = true;
        if (vault.rewardRate() != rateBefore || vault.periodFinish() != finishBefore) rateLoweredWhileActive = true;
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract StakingVaultLifecycleInvariantTest is Test {
    uint256 internal constant START = 1_700_000_000;
    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    /// Rounding the vault may strand per call: the per-token accumulator loses at most
    /// totalStaked / 1e18 wei (< 1e9 wei with the whole supply staked) plus a few floors of 1 wei.
    uint256 internal constant MAX_DUST_PER_CALL = SUPPLY / PRECISION + 8;

    LaunchToken internal token;
    StakingVault internal vault;
    LifecycleHandler internal handler;
    address[] internal actors;

    function setUp() public {
        vm.warp(START);
        token = new LaunchToken();
        vault = new StakingVault(address(token), 7 days);

        uint256[6] memory balances = [
            uint256(300_000_000 ether), // whale
            300_000_000 ether, // second whale
            10_000_000 ether, // ordinary staker
            10_000_000 ether, // ordinary staker
            500, // dust account: a few hundred wei
            100_000_000 ether // programme funder
        ];
        for (uint256 i; i < balances.length; ++i) {
            address actor = makeAddr(string.concat("lifecycle", vm.toString(i)));
            actors.push(actor);
            token.transfer(actor, balances[i]);
            vm.prank(actor);
            token.approve(address(vault), type(uint256).max);
        }
        handler = new LifecycleHandler(token, vault, actors);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](13);
        selectors[0] = LifecycleHandler.stake.selector;
        selectors[1] = LifecycleHandler.withdraw.selector;
        selectors[2] = LifecycleHandler.claim.selector;
        selectors[3] = LifecycleHandler.exit.selector;
        selectors[4] = LifecycleHandler.fund.selector;
        selectors[5] = LifecycleHandler.fundZero.selector;
        selectors[6] = LifecycleHandler.donate.selector;
        selectors[7] = LifecycleHandler.warp.selector;
        selectors[8] = LifecycleHandler.warpToUnlock.selector;
        selectors[9] = LifecycleHandler.warpToPeriodFinish.selector;
        selectors[10] = LifecycleHandler.attemptEarlyWithdraw.selector;
        selectors[11] = LifecycleHandler.attemptOverWithdraw.selector;
        selectors[12] = LifecycleHandler.attemptSlowStream.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _sumEarned() internal view returns (uint256 sum) {
        for (uint256 i; i < actors.length; ++i) {
            sum += vault.earned(actors[i]);
        }
    }

    function _sumStaked() internal view returns (uint256 sum) {
        for (uint256 i; i < actors.length; ++i) {
            sum += vault.stakedBalance(actors[i]);
        }
    }

    /// @dev Everything the vault owes, has scheduled, or has parked, including the slice that
    /// streamed while nothing was staked and has not yet been checkpointed into `undistributed`.
    function _liabilities() internal view returns (uint256) {
        return vault.totalStaked() + _sumEarned() + vault.remainingRewards() + vault.undistributed()
            + handler.pendingUndistributed();
    }

    /// @dev Start balance, minus what the actor put in, plus what came back out.
    function _explainedBalance(address a) internal view returns (uint256) {
        return handler.initialBalance(a) + handler.withdrawn(a) + handler.claimed(a) - handler.deposited(a)
            - handler.fundedBy(a) - handler.donatedBy(a);
    }

    // ---------------------------------------------------------------------------------------
    // Conservation
    // ---------------------------------------------------------------------------------------

    /// Internal accounting equals external reality: what the vault holds covers principal, owed
    /// rewards, the scheduled remainder and the parked pool.
    function invariant_balanceCoversAllLiabilities() public view {
        assertGe(token.balanceOf(address(vault)), _liabilities());
    }

    /// Nothing meaningful is ever stranded: the excess over liabilities is the donations plus
    /// bounded rounding dust. A leak proportional to amounts would break this.
    function invariant_strandedValueIsOnlyDonationsAndRoundingDust() public view {
        uint256 excess = token.balanceOf(address(vault)) - _liabilities();
        assertLe(excess, handler.totalDonated() + (handler.vaultCalls() + 1) * MAX_DUST_PER_CALL + actors.length);
    }

    /// Sum of parts equals the tracked whole, and the whole equals deposits minus withdrawals.
    function invariant_totalStakedMatchesAccountsAndGhosts() public view {
        assertEq(vault.totalStaked(), _sumStaked());
        uint256 netDeposited;
        for (uint256 i; i < actors.length; ++i) {
            netDeposited += handler.deposited(actors[i]) - handler.withdrawn(actors[i]);
        }
        assertEq(vault.totalStaked(), netDeposited);
    }

    /// Per actor: nobody withdraws more principal than they put in, and the position equals
    /// their own deposits minus their own withdrawals. No other account's calls move it.
    function invariant_perActorPrincipalConserved() public view {
        for (uint256 i; i < actors.length; ++i) {
            address a = actors[i];
            assertLe(handler.withdrawn(a), handler.deposited(a));
            assertEq(vault.stakedBalance(a), handler.deposited(a) - handler.withdrawn(a));
        }
    }

    /// Rewards paid plus rewards owed never exceed rewards funded (donations are not rewards).
    function invariant_rewardsPaidAndOwedNeverExceedFunded() public view {
        assertLe(handler.totalClaimed() + _sumEarned(), handler.totalFunded());
    }

    /// Per actor: the tokens they hold are exactly their start minus what they put in, plus
    /// what they took out. Nothing else credits or debits them.
    function invariant_perActorTokenBalanceExplained() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), _explainedBalance(actors[i]));
        }
    }

    // ---------------------------------------------------------------------------------------
    // Locks and access
    // ---------------------------------------------------------------------------------------

    /// A locked position cannot be reduced: every early withdraw or exit reverted and moved nothing.
    function invariant_lockIsNeverBypassed() public view {
        assertFalse(handler.lockBroken(), "principal moved while locked");
        for (uint256 i; i < actors.length; ++i) {
            assertLe(vault.unlockTime(actors[i]), block.timestamp + vault.LOCK_PERIOD());
        }
    }

    /// Every adversarial call reverted; nobody withdrew more than their stake or anyone else's.
    function invariant_adversarialCallsAlwaysRevert() public view {
        assertFalse(handler.adversarialCallSucceeded(), "a call that must revert succeeded");
        assertFalse(handler.principalMismatch(), "principal moved by other than its owner's exact amount");
    }

    // ---------------------------------------------------------------------------------------
    // Stream state machine
    // ---------------------------------------------------------------------------------------

    /// The per-token accumulator never goes backwards, across calls and across time.
    function invariant_rewardPerTokenMonotonic() public view {
        assertFalse(handler.rewardPerTokenDecreased());
        assertGe(vault.rewardPerToken(), handler.maxRewardPerToken());
    }

    /// Period end and checkpoint only move forward; the checkpoint never passes the period end
    /// or the present.
    function invariant_streamClockMonotonic() public view {
        assertFalse(handler.periodFinishDecreased());
        assertFalse(handler.lastUpdateTimeDecreased());
        assertGe(vault.periodFinish(), handler.maxPeriodFinish());
        assertLe(vault.lastUpdateTime(), vault.periodFinish());
        assertLe(vault.lastUpdateTime(), block.timestamp);
    }

    /// Nobody can slow an active stream, and the stream never promises more than one period.
    function invariant_rateNeverLoweredWhileActive() public view {
        assertFalse(handler.rateLoweredWhileActive());
        if (block.timestamp < vault.periodFinish()) {
            assertLe(vault.periodFinish() - block.timestamp, vault.rewardsDuration());
            assertGt(vault.rewardRate(), 0);
        } else {
            assertEq(vault.remainingRewards(), 0);
        }
    }

    /// Claims pay exactly what `earned` reported, withdrawals pay exactly the amount, and neither
    /// changes the other figure.
    function invariant_payoutsMatchViews() public view {
        assertFalse(handler.rewardMismatch(), "a payout differed from the view or disturbed the other figure");
    }

    // ---------------------------------------------------------------------------------------
    // Liveness: after any sequence, everyone can leave with exactly their principal
    // ---------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 200
    function testFuzz_afterAnySequenceEveryoneCanExitWithExactPrincipal(uint256 seed, uint8 stepCount) public {
        uint256 steps = bound(stepCount, 5, 60);
        for (uint256 i; i < steps; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 action = r % 13;
            uint256 x = uint256(keccak256(abi.encode(r, "x")));
            if (action == 0) handler.stake(r, x);
            else if (action == 1) handler.withdraw(r, x);
            else if (action == 2) handler.claim(r);
            else if (action == 3) handler.exit(r);
            else if (action == 4) handler.fund(r, x);
            else if (action == 5) handler.fundZero(r);
            else if (action == 6) handler.donate(r, x);
            else if (action == 7) handler.warp(x);
            else if (action == 8) handler.warpToUnlock(r);
            else if (action == 9) handler.warpToPeriodFinish(r);
            else if (action == 10) handler.attemptEarlyWithdraw(r);
            else if (action == 11) handler.attemptOverWithdraw(r);
            else handler.attemptSlowStream(r);
        }

        // Past every lock and past the period: everyone leaves.
        vm.warp(block.timestamp + 8 days);
        for (uint256 i; i < actors.length; ++i) {
            address a = actors[i];
            uint256 staked = vault.stakedBalance(a);
            uint256 owed = vault.earned(a);
            uint256 before = token.balanceOf(a);
            vm.prank(a);
            if (staked > 0) vault.exit();
            else vault.claim();
            assertEq(token.balanceOf(a) - before, staked + owed, "exit paid other than principal plus rewards");
            assertEq(vault.stakedBalance(a), 0);
            assertEq(vault.earned(a), 0);
            // Principal came back in full: the only money the actor is out is what they funded or donated.
            assertEq(
                token.balanceOf(a),
                handler.initialBalance(a) + handler.claimed(a) + owed - handler.fundedBy(a) - handler.donatedBy(a),
                "an actor did not get their whole principal back"
            );
        }
        assertEq(vault.totalStaked(), 0);
        uint256 leftover = token.balanceOf(address(vault)) - vault.remainingRewards() - vault.undistributed()
            - handler.pendingUndistributed();
        assertLe(leftover, handler.totalDonated() + (handler.vaultCalls() + actors.length + 1) * MAX_DUST_PER_CALL);
        assertFalse(handler.adversarialCallSucceeded());
        assertFalse(handler.lockBroken());
        assertFalse(handler.principalMismatch());
        assertFalse(handler.rewardMismatch());
        assertFalse(handler.rateLoweredWhileActive());
    }
}
