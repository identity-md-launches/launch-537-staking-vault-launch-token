// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {StakingVault} from "../src/StakingVault.sol";

/// @dev Drives the vault with a fixed set of actors. Inputs are bounded so that most calls
/// succeed; calls that would revert for a legitimate reason (lock, empty stake) are skipped so
/// the invariants are checked against a meaningful state space.
contract StakingVaultHandler is Test {
    LaunchToken public immutable token;
    StakingVault public immutable vault;

    address[] public actors;
    address internal currentActor;

    uint256 public ghostStaked;
    uint256 public ghostWithdrawn;
    uint256 public ghostFunded;
    uint256 public ghostClaimed;

    constructor(LaunchToken token_, StakingVault vault_, address[] memory actors_) {
        token = token_;
        vault = vault_;
        actors = actors_;
    }

    modifier useActor(uint256 seed) {
        currentActor = actors[seed % actors.length];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function stake(uint256 seed, uint256 amount) external useActor(seed) {
        uint256 balance = token.balanceOf(currentActor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vault.stake(amount);
        ghostStaked += amount;
    }

    function withdraw(uint256 seed, uint256 amount) external useActor(seed) {
        uint256 staked = vault.stakedBalance(currentActor);
        if (staked == 0 || block.timestamp < vault.unlockTime(currentActor)) return;
        amount = bound(amount, 1, staked);
        vault.withdraw(amount);
        ghostWithdrawn += amount;
    }

    function claim(uint256 seed) external useActor(seed) {
        uint256 before = token.balanceOf(currentActor);
        vault.claim();
        ghostClaimed += token.balanceOf(currentActor) - before;
    }

    function exit(uint256 seed) external useActor(seed) {
        uint256 staked = vault.stakedBalance(currentActor);
        if (staked == 0 || block.timestamp < vault.unlockTime(currentActor)) return;
        uint256 before = token.balanceOf(currentActor);
        vault.exit();
        ghostWithdrawn += staked;
        ghostClaimed += token.balanceOf(currentActor) - before - staked;
    }

    function fund(uint256 seed, uint256 amount) external useActor(seed) {
        uint256 balance = token.balanceOf(currentActor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        // A mid-period top-up must keep the rate; skip when it would not.
        if (block.timestamp < vault.periodFinish()) {
            uint256 total = amount + vault.undistributed() + vault.remainingRewards();
            if ((total * 1e18) / vault.rewardsDuration() < vault.rewardRate()) return;
        }
        vault.fundRewards(amount);
        ghostFunded += amount;
    }

    function warp(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 10 days);
        vm.warp(block.timestamp + seconds_);
    }

    /// @dev Someone sending tokens straight to the vault must never break the accounting.
    function donate(uint256 seed, uint256 amount) external useActor(seed) {
        uint256 balance = token.balanceOf(currentActor);
        if (balance == 0) return;
        amount = bound(amount, 1, balance / 10 + 1);
        if (amount > balance) return;
        token.transfer(address(vault), amount);
    }
}

contract StakingVaultInvariantTest is Test {
    uint256 internal constant START = 1_700_000_000;
    uint256 internal constant ACTORS = 4;

    LaunchToken internal token;
    StakingVault internal vault;
    StakingVaultHandler internal handler;
    address[] internal actors;

    function setUp() public {
        vm.warp(START);
        token = new LaunchToken();
        vault = new StakingVault(address(token), 7 days);

        for (uint256 i; i < ACTORS; ++i) {
            address actor = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(actor);
            token.transfer(actor, 1_000_000 ether);
            vm.prank(actor);
            token.approve(address(vault), type(uint256).max);
        }
        handler = new StakingVaultHandler(token, vault, actors);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = StakingVaultHandler.stake.selector;
        selectors[1] = StakingVaultHandler.withdraw.selector;
        selectors[2] = StakingVaultHandler.claim.selector;
        selectors[3] = StakingVaultHandler.exit.selector;
        selectors[4] = StakingVaultHandler.fund.selector;
        selectors[5] = StakingVaultHandler.warp.selector;
        selectors[6] = StakingVaultHandler.donate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _sumStaked() internal view returns (uint256 sum) {
        for (uint256 i; i < actors.length; ++i) {
            sum += vault.stakedBalance(actors[i]);
        }
    }

    function _sumEarned() internal view returns (uint256 sum) {
        for (uint256 i; i < actors.length; ++i) {
            sum += vault.earned(actors[i]);
        }
    }

    /// Principal is always fully backed by the vault's balance.
    function invariant_balanceCoversPrincipal() public view {
        assertGe(token.balanceOf(address(vault)), vault.totalStaked());
    }

    /// Principal plus every reward already owed is backed by the vault's balance.
    function invariant_balanceCoversPrincipalAndOwedRewards() public view {
        assertGe(token.balanceOf(address(vault)), vault.totalStaked() + _sumEarned());
    }

    /// Principal, owed rewards, the unstreamed remainder and the undistributed pool never exceed
    /// what the vault holds (rounding dust only ever stays in the vault).
    function invariant_balanceCoversAllLiabilities() public view {
        uint256 liabilities = vault.totalStaked() + _sumEarned() + vault.remainingRewards() + vault.undistributed();
        assertGe(token.balanceOf(address(vault)), liabilities);
    }

    /// The sum of per-account stakes equals the recorded total.
    function invariant_totalStakedMatchesAccounts() public view {
        assertEq(vault.totalStaked(), _sumStaked());
    }

    /// Principal is conserved: everything staked is either still staked or was withdrawn by its
    /// owner. Nothing else moves it.
    function invariant_principalConserved() public view {
        assertEq(handler.ghostStaked(), handler.ghostWithdrawn() + vault.totalStaked());
    }

    /// Rewards paid out never exceed rewards funded.
    function invariant_claimedNeverExceedsFunded() public view {
        assertLe(handler.ghostClaimed() + _sumEarned(), handler.ghostFunded());
    }

    /// Nobody's lock lies in the past of their last stake by more than the lock period.
    function invariant_unlockWithinLockPeriod() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertLe(vault.unlockTime(actors[i]), block.timestamp + vault.LOCK_PERIOD());
        }
    }

    /// The stream never promises more than the period can deliver.
    function invariant_remainingRewardsBoundedByPeriod() public view {
        if (block.timestamp >= vault.periodFinish()) {
            assertEq(vault.remainingRewards(), 0);
        } else {
            assertLe(vault.periodFinish() - block.timestamp, vault.rewardsDuration());
        }
    }
}
