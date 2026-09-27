# Trickle (TRKL)

Trickle is a **Sepolia-only test toy**: stake TRKL and share donated Sepolia test ETH streamed over seven days. It promises **no yield or return**. There is no price oracle, percentage APR, guaranteed funding, or real-money deployment in this contribution.

This repository delivers the two contracts, Foundry tests, vendored dependencies, and ABI documentation. It does not deploy or broadcast transactions. A separate assignment produces `launch.json` from accepted source, followed by independent review. Services handle source publication, signed artifact and policy linkage, admission, deployment, and then the frontend.

## Build and test

Use Foundry with **Solidity 0.8.26**, pinned in `foundry.toml`. The build targets Cancun, uses 200 optimizer runs, and sets `bytecode_hash = "none"`. All Solidity dependencies are ordinary files under `lib/`; their upstream versions, archive hashes, and licenses are recorded in [lib/DEPENDENCIES.md](lib/DEPENDENCIES.md). No dependency downloads, submodules, FFI, filesystem cheatcode permissions, environment variables, private keys, or RPC endpoints are needed for the tests. The verifier supplies the pinned compiler.

```sh
forge build
forge test
forge fmt --check
```

The suite includes token supply/transfer/allowance checks, factory-style construction, runtime size/opcode checks, success and failure paths for all staking operations, stream boundaries, zero-stake carry, restreaming, active top-ups, small-stake precision, failed token transfers, failed ETH receivers, and reentry attempts against all six mutating entry points. Two fuzz tests vary transfer amounts and two-staker timing/amount/funding combinations. The stateful campaign varies five stakers, amounts, time, claims, exits, donations, and restreams with 256 sequences of 128 calls. It checks:

```text
ETH paid + sum(earned) + carry + future scheduled ETH <= ETH notified
contract ETH balance + ETH paid == ETH notified
contract TRKL balance == totalStaked == sum(stakedOf)
liquid TRKL + staked TRKL == 1e27
```

Each random sequence also finishes the stream and withdraws/claims for every participant. The balance equalities assume no unsolicited transfers in the campaign. Build-time lint heuristics may flag timestamp checks and ETH calls; these are required for streaming and caller payouts, and every mutating entry point has `nonReentrant` protection.

## Contracts and deployment parameters

| Identifier | Source | Nonpayable constructor | Factory input |
| --- | --- | --- | --- |
| `LaunchToken` | `src/LaunchToken.sol` | No arguments | Launch token, deployed first |
| `ETHStakingRewards` | `src/ETHStakingRewards.sol` | `address token_` | `["$token"]` |

Deploy through the project factory on **Sepolia, chain ID 11155111**. `LaunchToken` has name **Trickle**, symbol **TRKL**, 18 decimals, and a one-time mint of **1,000,000,000 TRKL (10^27 minor units)** to its deployer. Factory construction therefore mints the entire supply to the factory for the protocol's LP/reward allocation. There are no mint, burn, owner, fee, pause, blocklist, or upgrade entry points.

`ETHStakingRewards` checks that the token address is nonzero and contains code, then stores it immutably. The manifest/reviewer must ensure this address is the actual `LaunchToken`; the constructor does not certify arbitrary token behavior. There is no owner argument or use of the deployer as an authority. It needs no initial TRKL or ETH, makes no constructor transfer, and needs no initialization calls. There are no proxies, privileged beneficiaries, rescue functions, or admin/upgrade paths. Chain selection is the deployment service's responsibility; the bytecode itself does not gate by chain ID.

The manifest contribution must use kind `evm_project`, launch token `LaunchToken`, and the single application identifier `ETHStakingRewards`, referencing `$token`. The ETH/TRKL launch pool is seeded by the factory; users obtain TRKL by swapping Sepolia ETH there. Policy, reward distribution, opening price derivation, signed artifact linkage, deployment addresses, and publication outcomes belong to the services and independent manifest review. No live addresses or signed artifacts are asserted here.

## Staking and reward behavior

1. Obtain TRKL in the launch pool and call `LaunchToken.approve(stakingAddress, amount)`.
2. Call `stake(amount)` with a positive amount in TRKL minor units. The contract checkpoints rewards and pulls exactly that amount with `SafeERC20.safeTransferFrom`.
3. Call `withdraw(amount)` for a positive amount no greater than your stake. It checkpoints rewards and returns TRKL to you with `safeTransfer`. Withdrawal never requires an ETH payout or active stream.
4. Call `getReward()` to claim your earned ETH, or `exit()` to withdraw all your TRKL and claim atomically. Payouts and withdrawals always go to the caller. An empty claim/exit succeeds without a transfer. Claiming twice at the same timestamp cannot pay twice.

TRKL is a plain ERC-20: no transfer fees, rebasing, or callbacks. Crediting the requested transfer amount relies on that deployment assumption. Fee-on-transfer and rebasing tokens are unsupported. The contract has no lockup or minimum staking balance. Staking and withdrawing within one block earns zero. A late staker earns only after joining; future rewards are shared pro rata among the stake present during each interval.

Anyone can call `notifyRewardAmount()` with at least **0.001 ETH**. This is a nonrefundable donation, with no donor privileges. It is the only normal ETH entry point; the contract has no receive/fallback function.

| Situation | Result |
| --- | --- |
| No active stream (`now >= periodFinish`) | Start a 604,800-second stream from `msg.value + carry`; integer `rewardRate = budget / 604800`; division remainder stays in carry. |
| Active stream (`now < periodFinish`) | Put all `msg.value` in carry. The current rate and finish remain unchanged. |
| Time passes while `totalStaked == 0` | Scheduled ETH for that interval goes to carry, never to the next entrant retroactively. |
| Finished stream with stake present and carry at least 0.001 ETH | Anyone may call `restream()` to start a new seven-day stream from carry alone, without a new donation. |
| Carry below 0.001 ETH, or no stake present | `restream()` reverts. Carry remains available for a later qualifying stream. |

Every successful stake, withdrawal, claim, exit, donation, and restream checkpoints elapsed rewards. `carry()` includes elapsed empty-stake intervals before any transaction materializes them. Repeated reads do not change accounting. Rewards stop at `periodFinish`; `currentRate()` returns zero at and after that timestamp, while `rewardRate` retains the last scheduled rate. A future stream never consumes unclaimed rewards from an earlier stream.

There is no automatic renewal or keeper. A participant must submit a qualifying donation or `restream()` transaction. Donations can start a stream with no stake, in which case its unused scheduled ETH becomes carry. There is no cancellation, donor refund, or expiry on earned claims. Timestamp boundaries follow chain time; small validator timing effects are inherent to the specified per-second stream.

## Precision, custody, and failure handling

The accounting uses a cumulative `rewardPerToken` index scaled by `1e18`, `userRewardPerTokenPaid`, and per-user stored rewards. Global and user calculations round down and use full-precision `Math.mulDiv`. The invariant is an inequality because integer rounding can leave unallocated ETH dust. For each global checkpoint, the index division discards less than `totalStaked / 1e18` wei of aggregate fractional entitlement (at most a strict bound of 1 gwei at the full TRKL supply); each user checkpoint can discard less than one additional wei. Frequent checkpoints can accumulate this loss, and a tiny stake among large stakes may earn zero. There is no minimum positive payout guarantee. A single one-minor-unit staker can earn the whole scheduled stream.

The specified rate-division remainder and empty-stake emissions are carried. Index/user rounding dust is **not** put into carry because doing so naively can overlap still-accruing entitlements. Dust cannot be swept. Neither accidental direct TRKL transfers nor forced ETH (which the EVM can deliver without calling a function) creates a stake, a donation, or carry. Such excess assets also have no recovery path. Use the documented entry points.

All six mutating functions are guarded against reentrancy. State is settled before token and ETH interactions. A claim sets `rewards[msg.sender]` to zero before using `call` to pay ETH. If a receiver rejects ETH, the entire claim reverts and the claim remains owed. A failed `exit()` also rolls back its TRKL withdrawal; that caller can still use `withdraw()` separately to recover principal. One failing receiver cannot block other users. A receiver that permanently rejects ETH cannot redirect its claim to another account, because payouts must be caller-only.

## ABI and frontend handoff

Machine-readable exports are [LaunchToken.json](docs/abi/LaunchToken.json) and [ETHStakingRewards.json](docs/abi/ETHStakingRewards.json). Human-readable signatures, units, events, errors, and UI calculations are in [docs/ABI.md](docs/ABI.md). To regenerate after source changes:

```sh
forge inspect src/LaunchToken.sol:LaunchToken abi --json > docs/abi/LaunchToken.json
forge inspect src/ETHStakingRewards.sol:ETHStakingRewards abi --json > docs/abi/ETHStakingRewards.json
```

After services deploy the reviewed artifacts, the frontend assignment builds one small page labelled `lab-staking-rewards`, statically exported as `dist/index.html`. It must enforce Sepolia and read the token address from `staking.token()`. It displays stake, earned ETH, `currentRate()`, time to finish, wallet TRKL balance/allowance, and ETH per day per 1,000,000 TRKL staked. It provides approve, stake, withdraw, claim, exit, and donate controls using contract views only, with no backend, indexer, oracle, percentage APR, or in-page swap. It explains the launch-pool source of TRKL and repeats that this only moves Sepolia test ETH and promises no yield or return. GitHub publication and IPFS hosting are approved downstream responsibilities.

## Review status and responsibilities

These are implementation tests and contributor self-checks, **not an independent security audit**. The separate adversarial reviewer must inspect accepted source and the generated manifest, including token linkage, constructor execution, conservation across changing balances and rates, top-ups, small-stake precision and repeated checkpoint loss, empty-stake intervals, and all payout/reentrancy paths. Concrete source, constructor, policy, or authorization conflicts remain review findings. Review notes and limitations are provided in [docs/REVIEW_HANDOFF.md](docs/REVIEW_HANDOFF.md). Services must obtain that independent review before release, publish/attest the accepted source, apply the pinned policy, admit and deploy the reviewed artifacts, and provide verified deployment addresses to the frontend contributor.
