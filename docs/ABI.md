# Contract ABI reference

Solidity 0.8.26 exports are under `docs/abi/`. Constructors are nonpayable. Only `ETHStakingRewards.notifyRewardAmount()` is payable. All amounts are unsigned integers; frontend calculations should use bigint or equivalent integer arithmetic.

## LaunchToken

No constructor arguments. Name `Trickle`, symbol `TRKL`, decimals `18`, fixed supply `1000000000000000000000000000` minor units minted to the constructor caller.

| Signature | Result / units |
| --- | --- |
| `name()`, `symbol()` | `string` metadata |
| `decimals()` | `uint8`, 18 |
| `totalSupply()` | `uint256`, TRKL minor units |
| `balanceOf(address)` | `uint256`, TRKL minor units |
| `allowance(address owner,address spender)` | `uint256`, TRKL minor units |
| `approve(address spender,uint256 amount)` | `bool`, replaces allowance; max uint means unlimited |
| `transfer(address to,uint256 amount)` | `bool`, exact transfer |
| `transferFrom(address from,address to,uint256 amount)` | `bool`, exact transfer subject to allowance |

Events: `Transfer(address indexed from,address indexed to,uint256 value)` and `Approval(address indexed owner,address indexed spender,uint256 value)`. Transfers to zero revert. OpenZeppelin ERC-6093 custom errors for invalid senders/receivers/approvers/spenders, insufficient balance, and insufficient allowance are included in the JSON ABI. There is no permit interface or privileged extension.

## ETHStakingRewards

Constructor: `constructor(address token_)`. In the manifest, use `["$token"]`.

| Signature | Behavior |
| --- | --- |
| `stake(uint256 amount)` | Pull positive TRKL amount using the caller's prior approval. |
| `withdraw(uint256 amount)` | Return positive TRKL amount to caller; preserve earned ETH. |
| `getReward()` | Pay caller's earned ETH; zero reward is a no-op. |
| `exit()` | Atomically withdraw all caller stake and claim; empty exit is a no-op. |
| `notifyRewardAmount()` payable | Donate at least 0.001 ETH; start a finished stream or queue in carry during an active stream. |
| `restream()` | Start a finished stream using at least 0.001 ETH carry, with positive total stake. Any caller. |

| View | Return (`uint256` unless noted) |
| --- | --- |
| `token()` | `address`, immutable TRKL contract |
| `DURATION()` | 604800 seconds |
| `MIN_REWARD()` | 1000000000000000 ETH wei |
| `totalStaked()` | TRKL minor units credited to all stakers |
| `stakedOf(address account)` | TRKL minor units credited to account |
| `earned(address account)` | ETH wei currently claimable, including elapsed rewards |
| `rewardPerToken()` | Cumulative ETH wei per TRKL minor unit scaled by 1e18, including elapsed rewards |
| `rewardRate()` | Stored scheduled ETH wei/second; does not become zero on expiry |
| `currentRate()` | Live scheduled ETH wei/second, zero at/after finish |
| `periodFinish()` | Stream end, Unix timestamp seconds; zero before first stream |
| `carry()` | Unscheduled ETH wei including pending empty-stake emissions |
| `lastTimeRewardApplicable()` | `min(block.timestamp, periodFinish)` |
| `lastUpdateTime()` | Timestamp of last materialized global reward checkpoint, capped at finish |
| `rewardPerTokenStored()` | Materialized index; use `rewardPerToken()` for the live value |
| `userRewardPerTokenPaid(address)` | Index at account's last checkpoint |
| `rewards(address)` | Materialized account claim; use `earned(account)` for the live value |

Events:

```solidity
event Staked(address indexed account, uint256 amount);     // TRKL minor units
event Withdrawn(address indexed account, uint256 amount); // TRKL minor units
event RewardPaid(address indexed account, uint256 amount);// ETH wei
event RewardAdded(uint256 amount, uint256 rate, uint256 periodFinish);
```

For `RewardAdded`, `amount` is the fresh ETH sent to `notifyRewardAmount`, or the recycled carry budget in `restream`. On an active top-up, the event's rate and finish describe the unchanged active stream; `amount` is not an immediate increase in distributed rewards. Read `carry()` to show queued funding. When starting from a fresh donation plus carry, the effective budget includes both even though the event amount is only the fresh donation.

Application errors: `InvalidToken()`, `ZeroAmount()`, `InsufficientStake()`, `RewardTooSmall()`, `StreamActive()`, `NoStake()`, `InsufficientCarry()`, `ETHTransferFailed()`. Library errors include `ReentrancyGuardReentrantCall()`, `SafeERC20FailedOperation(address)`, and `MathOverflowedMulDiv()`. Token call errors may bubble through SafeERC20. An arbitrary transfer fee/rebasing token is unsupported even if deployment accepts its address.

For UI display, use the latest chain timestamp, not the computer's clock:

```text
timeRemaining = max(periodFinish - latestBlock.timestamp, 0)
stakeTRKL = stakedOf(wallet) / 1e18
earnedETH = earned(wallet) / 1e18
```

With positive total stake, the instantaneous normalized stream indicator is:

```text
weiPerDayPerMillionTRKL = currentRate * 86400 * (1_000_000 * 1e18) / totalStaked
ETHPerDayPerMillionTRKL = weiPerDayPerMillionTRKL / 1e18
```

This is a current-rate normalization, not a price-based APR, promised payout, or seven-day forecast. If total stake is zero, show “No active stake — scheduled ETH goes to carry.” If expired, display zero current rate. A sub-day remaining stream only pays until its finish, and any changing stake changes the share. Use bigint before formatting decimals. Re-read views after confirmed transactions and refresh on new blocks; events alone do not reflect time accrual.
