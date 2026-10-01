# Launch token staking vault

A single-token staking vault for the launch token. Stakers lock their tokens for 7 days, anyone can
fund rewards in the same token, rewards stream per second pro rata to stake, and nobody can touch
stakers' principal: the vault has no owner, no pause, no sweep and no upgrade path.

| Contract | File | Role |
|---|---|---|
| `LaunchToken` | `src/LaunchToken.sol` | The fixed-supply launch token (staked and paid as rewards) |
| `StakingVault` | `src/StakingVault.sol` | The staking vault |

Toolchain: Foundry with `solc = "0.8.26"` pinned in `foundry.toml`, `bytecode_hash = "none"`,
no ffi and no filesystem permissions. forge-std 1.16.2 and the OpenZeppelin 5.7.0 files the
contracts import are vendored under `lib/` as ordinary files, so the project builds offline.

```
forge build
forge test
forge fmt --check
```

## LaunchToken

`LaunchToken` ("Stake Launch Token", `STK`) is a plain OpenZeppelin ERC-20 with 18 decimals and
exactly 1,000,000,000 tokens (10^27 minor units) minted once to `msg.sender` in a constructor that
takes no arguments. There is no mint, owner, pause, blocklist, fee or upgrade function. At launch
the ProjectFactory deploys it, holds the whole supply and splits it; nothing in this project
mints, holds or forwards any of that supply.

The brief asked only for a vault around "the launch token", so there is nothing it requested
that the standard token does not do. The vault is funded by ordinary transfers from whoever
chooses to fund it; the token itself grants no share of the supply to the vault or to anyone.

## StakingVault

### Behaviour

- **Stake.** `stake(amount)` pulls `amount` tokens from the caller (approval required) and
  credits them to the caller's position. Each stake locks the caller's *whole* position for
  `LOCK_PERIOD` (7 days) counted from that stake, including tokens staked earlier. Only the
  caller's own position can be staked into; there is no `stakeFor`, so nobody can extend someone
  else's lock.
- **Withdraw.** Once `block.timestamp >= unlockTime[account]`, `withdraw(amount)` returns up to
  the whole position. Partial withdrawals are allowed and do not start a new lock.
- **Rewards.** `fundRewards(amount)` can be called by anyone. The funded tokens stream over
  `rewardsDuration` seconds (a constructor parameter; 7 days at launch) at a constant per-second
  rate. Every second's rewards are split among the stakers in proportion to their stake at that
  second. `earned(account)` shows what an account can claim; `claim()` pays it out at any time,
  locked or not. `exit()` withdraws the whole position and claims in one call.
- **Funding while a period runs.** The unstreamed remainder is rolled into a fresh period of
  `rewardsDuration`, and the new rate must be at least the current rate, otherwise the call
  reverts with `RewardRateTooLow`. This stops anyone from slowing an active stream with dust
  deposits. In practice a mid-period top-up has to be at least what the current period has
  already streamed; smaller contributions can wait until the period ends.
- **Rewards while nobody is staked.** Those seconds' rewards are kept in `undistributed` and
  included in the next funding (which may be a zero-amount call once the period has ended), so
  they are re-streamed rather than stranded or handed to the first staker.
- **Principal safety.** Rewards are only ever paid out of what was funded; principal is only
  ever returned to the account that staked it. There is no privileged role.

### Accounting

The vault follows the Synthetix StakingRewards accumulator (`rewardPerTokenStored`,
`userRewardPerTokenPaid`, `rewards`) with the reward rate scaled by `PRECISION = 1e18` so that
small reward amounts do not round to zero. Division rounds down everywhere, so rounding dust
(a few wei per checkpoint) stays in the vault and is never owed to anyone. The invariant suite
checks that the vault's balance always covers principal, rewards already owed, the unstreamed
remainder and the undistributed pool.

Deposits measure the balance before and after the transfer and credit what actually arrived,
so a fee-on-transfer token could not make the vault owe more than it holds. The launch token
has no fee; this is a defensive measure only.

### Assumptions and known behaviours

- **Lock resets on every stake.** Adding to a position restarts the 7-day lock for the whole
  position. Stakers who want independent lock windows should use separate addresses.
- **Rewards are not locked.** `claim()` works during the lock. Only principal is time-locked.
- **Timestamps.** The lock and the stream compare `block.timestamp`. A block builder can shift a
  timestamp by a few seconds; that can move a withdrawal or a reward checkpoint by that much and
  nothing more.
- **Direct transfers.** Tokens sent to the vault with a plain `transfer` are not rewards and not
  principal. They stay in the vault with no way to recover them (there is no sweep by design).
  Use `fundRewards` to add rewards.
- **Funding is permissionless and irreversible.** Anyone can fund; funded tokens cannot be
  withdrawn by the funder. A funding call made while nobody is staked is held as `undistributed`
  until the next funding call, so a funder who wants a stream to start immediately should check
  `totalStaked` first, or stake first.
- **Zero stakes.** `stake(0)`, `withdraw(0)` and `exit()` with no position revert with
  `ZeroAmount`; `claim()` with nothing earned is a no-op.
- **Reentrancy.** The vault only calls the launch token, which has no hooks. All external
  functions are still `nonReentrant` and follow checks-effects-interactions.
- **Gas.** No loops over user-controlled data; every call is O(1).

### Deployment parameters

`StakingVault` has a nonpayable constructor and is fully configured by it:

| Argument | Type | Launch value | Meaning |
|---|---|---|---|
| `token_` | `address` | `$token` | The launch token, staked and paid as rewards |
| `rewardsDuration_` | `uint256` | `604800` (7 days) | Length of every reward period started by `fundRewards` |

Suggested manifest entry: identifier `StakingVault`, constructor arguments `["$token", "604800"]`.
There is no owner argument because there is no owner. Constructors run with the factory as
`msg.sender`; the vault does not read `msg.sender` in its constructor and holds nothing at
deployment. `LOCK_PERIOD` is a constant 7 days as the brief requires.

`rewardsDuration` is the one deployment choice. 7 days matches the lock, so a staker who stays
for one lock sees one full period. A longer duration spreads each funding thinner; a shorter one
makes top-ups mid-period more demanding (see the rate rule above). It cannot be changed after
deployment.

`script/Deploy.s.sol` deploys the token and the vault for local or testnet use. Its `run()` reads
`REWARDS_DURATION` from the environment (default 7 days) and broadcasts; `deploy(Config)` takes the
configuration explicitly and is what the tests call. The production launch goes through the
factory and does not use the script.

### Operational responsibilities

- **Funding rewards.** Nobody is obliged to fund. Whoever runs the programme (the project team,
  typically) should fund after there is stake in the vault, and should size mid-period top-ups
  to at least what the current period has streamed, or wait for `periodFinish`. `remainingRewards()`
  and `rewardRate()` expose the figures needed.
- **No admin.** There is no key to protect and no pause. A bug cannot be patched in place; the
  remedy would be a new vault and a user migration, which is why an independent adversarial
  review before release is required.
- **Explorer verification.** After deployment, verify the source with `forge verify-contract`
  (`bytecode_hash = "none"`, solc 0.8.26, optimizer 200 runs, EVM cancun). This belongs to the
  network's deployer.
- **Monitoring.** `Staked`, `Withdrawn`, `RewardPaid` and `RewardsFunded` events cover every
  state change.

## Tests

| File | What it covers |
|---|---|
| `test/LaunchToken.t.sol` | Supply, decimals, exact transfer, no mint or admin entry points |
| `test/StakingVault.t.sol` | Constructor validation; stake, lock reset, withdraw at and before the boundary, partial and over-withdraw; pro-rata and per-second accrual, late joiners, period end; funding rules (rate floor, rollover, undistributed, zero-amount restart); claim and exit; principal safety (no admin selectors, non-stakers, direct transfers, fee-on-transfer credit); fuzzed lock boundary, exact principal return and pro-rata bounds |
| `test/StakingVault.invariant.t.sol` | Handler-driven invariants over four actors: balance covers principal, owed rewards and the unstreamed remainder; per-account stakes sum to the total; principal conservation; claims never exceed funding; lock bounds; period bounds |
| `test/Deploy.t.sol` | The deploy function wires the vault to the token and rejects a zero duration |

Tests fix `block.timestamp` with `vm.warp`, derive addresses with `makeAddr`, read no
environment variables and pass in any order and in parallel.

Tests passing do not constitute a security audit. The vault holds other people's funds and needs
a separate adversarial review by an independent contributor before release. Slither and Mythril
were not run (not provided in this environment); forge's built-in linter and fuzzer ran.
