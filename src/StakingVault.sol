// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title StakingVault
/// @notice Single-token staking vault for the launch token. Stakers lock their tokens for
/// `LOCK_PERIOD` (7 days), anyone can fund rewards in the same token, and rewards stream to
/// stakers per second, pro rata to their stake. There is no owner: nobody can move, pause or
/// sweep stakers' principal.
///
/// @dev Accounting follows the Synthetix StakingRewards model with two changes:
///  - `rewardRate` is scaled by `PRECISION` so small reward amounts do not round to zero;
///  - reward seconds that elapse while nothing is staked are tracked in `undistributed` and
///    rolled into the next funding instead of being stranded.
///
/// Funding while a period is active rolls the unstreamed remainder into a fresh period of
/// `rewardsDuration`, and the resulting rate must not be lower than the current one. That
/// stops an attacker from slowing an active stream down with dust deposits; it means a
/// mid-period top-up must be at least what the current period has already streamed.
///
/// Principal and rewards share one token balance. Every outflow is bounded by what the caller
/// staked or by rewards that were funded, so `token.balanceOf(vault) >= totalStaked + owed
/// rewards` at all times; see the invariant tests.
contract StakingVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------
    // Constants and immutables
    // ---------------------------------------------------------------------------------------

    /// @notice Time a staker's whole position stays locked after their latest stake.
    uint256 public constant LOCK_PERIOD = 7 days;

    /// @notice Fixed-point scale for `rewardRate`, `rewardPerTokenStored` and `userRewardPerTokenPaid`.
    uint256 public constant PRECISION = 1e18;

    /// @notice The token that is staked and the token rewards are paid in.
    IERC20 public immutable token;

    /// @notice Length of every reward period started by `fundRewards`, in seconds.
    uint256 public immutable rewardsDuration;

    // ---------------------------------------------------------------------------------------
    // Reward stream state
    // ---------------------------------------------------------------------------------------

    /// @notice Timestamp at which the current reward period ends (0 before the first funding).
    uint256 public periodFinish;

    /// @notice Reward tokens streamed per second, scaled by `PRECISION`.
    uint256 public rewardRate;

    /// @notice Last timestamp the reward accumulator was brought up to date.
    uint256 public lastUpdateTime;

    /// @notice Accumulated rewards per staked token, scaled by `PRECISION`.
    uint256 public rewardPerTokenStored;

    /// @notice Rewards that streamed while `totalStaked` was zero; rolled into the next funding.
    uint256 public undistributed;

    // ---------------------------------------------------------------------------------------
    // Staker state
    // ---------------------------------------------------------------------------------------

    /// @notice Sum of all stakers' principal held by the vault.
    uint256 public totalStaked;

    /// @notice Principal staked per account.
    mapping(address account => uint256 amount) public stakedBalance;

    /// @notice Timestamp from which an account may withdraw its principal.
    mapping(address account => uint256 timestamp) public unlockTime;

    /// @notice `rewardPerTokenStored` snapshot at the account's last checkpoint.
    mapping(address account => uint256 paid) public userRewardPerTokenPaid;

    /// @notice Rewards accrued but not yet claimed by the account, in token units.
    mapping(address account => uint256 amount) public rewards;

    // ---------------------------------------------------------------------------------------
    // Events and errors
    // ---------------------------------------------------------------------------------------

    event Staked(address indexed account, uint256 amount, uint256 unlockTime);
    event Withdrawn(address indexed account, uint256 amount);
    event RewardPaid(address indexed account, uint256 amount);
    event RewardsFunded(address indexed funder, uint256 amount, uint256 rewardRate, uint256 periodFinish);

    error ZeroAddress();
    error ZeroAmount();
    error ZeroDuration();
    error StillLocked(uint256 unlockTime);
    error InsufficientStake(uint256 staked, uint256 requested);
    error RewardRateTooLow(uint256 currentRate, uint256 proposedRate);

    // ---------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------

    /// @param token_ The launch token (staked and paid as rewards).
    /// @param rewardsDuration_ Length in seconds of each reward period started by `fundRewards`.
    constructor(address token_, uint256 rewardsDuration_) {
        if (token_ == address(0)) revert ZeroAddress();
        if (rewardsDuration_ == 0) revert ZeroDuration();
        token = IERC20(token_);
        rewardsDuration = rewardsDuration_;
    }

    // ---------------------------------------------------------------------------------------
    // Staker actions
    // ---------------------------------------------------------------------------------------

    /// @notice Stake `amount` tokens for the caller. Locks the caller's whole position for
    /// `LOCK_PERIOD` from now, including tokens staked earlier.
    /// @dev Pulls tokens with `transferFrom`; the caller must have approved the vault.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _updateReward(msg.sender);

        uint256 received = _pull(amount);
        totalStaked += received;
        stakedBalance[msg.sender] += received;
        uint256 unlockAt = block.timestamp + LOCK_PERIOD;
        unlockTime[msg.sender] = unlockAt;

        emit Staked(msg.sender, received, unlockAt);
    }

    /// @notice Withdraw `amount` of the caller's principal once their lock has expired.
    function withdraw(uint256 amount) external nonReentrant {
        _withdraw(amount);
    }

    /// @notice Pay out the caller's accrued rewards. Rewards are never locked.
    function claim() external nonReentrant {
        _claim();
    }

    /// @notice Withdraw the caller's whole principal and claim all accrued rewards.
    function exit() external nonReentrant {
        _withdraw(stakedBalance[msg.sender]);
        _claim();
    }

    // ---------------------------------------------------------------------------------------
    // Funding
    // ---------------------------------------------------------------------------------------

    /// @notice Add `amount` tokens to the reward stream. Anyone may call this.
    /// @dev Starts a new period of `rewardsDuration` seconds. If a period is still running, its
    /// unstreamed remainder and any `undistributed` rewards are included, and the new rate must
    /// be at least the current rate. `amount` may be zero only to restart a stream from
    /// leftovers once no period is active (or when nothing has streamed yet).
    function fundRewards(uint256 amount) external nonReentrant {
        _updateReward(address(0));

        uint256 received = amount == 0 ? 0 : _pull(amount);
        uint256 total = received + undistributed;
        uint256 currentRate = rewardRate;
        bool active = block.timestamp < periodFinish;
        if (active) {
            uint256 remaining = periodFinish - block.timestamp;
            total += (currentRate * remaining) / PRECISION;
        }
        if (total == 0) revert ZeroAmount();

        uint256 newRate = (total * PRECISION) / rewardsDuration;
        if (active && newRate < currentRate) revert RewardRateTooLow(currentRate, newRate);

        undistributed = 0;
        rewardRate = newRate;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;

        emit RewardsFunded(msg.sender, received, newRate, periodFinish);
    }

    // ---------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------

    /// @notice The latest timestamp at which rewards are still streaming.
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /// @notice Accumulated rewards per staked token including time since the last checkpoint.
    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        uint256 elapsed = lastTimeRewardApplicable() - lastUpdateTime;
        return rewardPerTokenStored + (rewardRate * elapsed) / totalStaked;
    }

    /// @notice Rewards `account` could claim right now.
    function earned(address account) public view returns (uint256) {
        return
            rewards[account] + (stakedBalance[account] * (rewardPerToken() - userRewardPerTokenPaid[account]))
                / PRECISION;
    }

    /// @notice Rewards left to stream in the current period (zero when no period is active).
    function remainingRewards() external view returns (uint256) {
        if (block.timestamp >= periodFinish) return 0;
        return (rewardRate * (periodFinish - block.timestamp)) / PRECISION;
    }

    // ---------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------

    function _withdraw(uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        uint256 staked = stakedBalance[msg.sender];
        if (amount > staked) revert InsufficientStake(staked, amount);
        uint256 unlockAt = unlockTime[msg.sender];
        if (block.timestamp < unlockAt) revert StillLocked(unlockAt);
        _updateReward(msg.sender);

        stakedBalance[msg.sender] = staked - amount;
        totalStaked -= amount;

        emit Withdrawn(msg.sender, amount);
        token.safeTransfer(msg.sender, amount);
    }

    function _claim() private {
        _updateReward(msg.sender);
        uint256 reward = rewards[msg.sender];
        if (reward == 0) return;
        rewards[msg.sender] = 0;

        emit RewardPaid(msg.sender, reward);
        token.safeTransfer(msg.sender, reward);
    }

    /// @dev Brings the global accumulator up to date, then checkpoints `account` (skipped for
    /// the zero address). While nothing is staked the streamed rewards go to `undistributed`.
    function _updateReward(address account) private {
        uint256 applicable = lastTimeRewardApplicable();
        if (totalStaked == 0) {
            if (applicable > lastUpdateTime) {
                undistributed += (rewardRate * (applicable - lastUpdateTime)) / PRECISION;
            }
        } else {
            rewardPerTokenStored = rewardPerToken();
        }
        lastUpdateTime = applicable;

        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    /// @dev Pulls `amount` from the caller and returns what actually arrived, so a token that
    /// takes a fee on transfer cannot make the vault owe more than it holds.
    function _pull(uint256 amount) private returns (uint256 received) {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();
    }
}
