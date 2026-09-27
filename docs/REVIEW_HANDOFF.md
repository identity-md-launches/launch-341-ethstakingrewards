# Independent review handoff

This is a source contributor's self-check record, not an independent review or launch approval. Review the accepted `src/` contracts and the separate generated `launch.json` together. Source artifacts: `LaunchToken`, `ETHStakingRewards`. Required constructor linkage: the latter receives only the former's deployed address through `$token`. No owner/admin is intended, including the factory caller.

| Surface | Local evidence | Independent attack focus |
| --- | --- | --- |
| Supply and factory construction | Fixed supply, exact transfers, rejected admin/mint selectors, factory owns supply after both constructors, runtime scan | Confirm accepted creation code, 18 decimals and 1e27 supply; no application balance required at deploy. |
| Reward conservation | Random action sequences check paid + earned + carry + scheduled <= notified and exact physical ETH balance | Try account turnover, multiple completed streams, repeated partial withdrawals/claims, top-ups before/at/after expiry, and tiny rewards among very different stakes. |
| Active top-ups | Unit and handler assertions hold rate and finish constant | Try donation bursts at one-second boundary offsets, including no stakers. |
| Empty-stake intervals | Entire and partial empty periods become carry; a stranger can restream once stake is present | Try empty/nonempty transitions in one timestamp, long idle times, failed restream retries, and no new donor. |
| Precision | Tiny sole stake gets the full schedule; tiny pooled stake rounds down; fuzzed amounts/times obey the conservation bound | Quantify loss under many checkpoints with full supply staked and minimum funding. Global index dust and user rounding dust are unrecoverable, as documented. |
| Payout failure | Rejected ETH restores claims; rejected exit restores principal; separate withdrawals and other users still succeed | Test receiver fallback gas behavior and persistent rejection. There is intentionally no alternate payout beneficiary. |
| Reentrancy | Receiver attempts all six mutators during claim and exit; every attempt fails with the guard error; recorded rewards are already zero | Review all external call paths, including SafeERC20 failures. The accepted TRKL has no callbacks. |
| Runtime and configuration | Bounded runtime, no forbidden escape opcodes, immutable token, no initialization | Confirm manifest uses Sepolia 11155111 and the reviewed token address; constructor accepts any contract code, so linkage is essential. |

Known operating limitations are deliberate and documented: no donor refunds, no automatic renewal, restream needs stake and at least 0.001 ETH carry, no asset rescue, no oracle/APR, no ETH redirection, no token-behavior certification, and no support for fee/rebasing tokens. Anyone may checkpoint global accounting through a claim, including with no stake; integer index rounding can accumulate with such activity. No source-side independent-review claim or production-security claim is made.

The canonical manifest's policy and signed artifact linkage belong to services. Concrete constructor, source, policy, or authorization conflicts should be returned as findings. The source contributor does not author `launch.json`, deploy funds, assert a live deployment, or build the later page against invented addresses.
