// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ETHStakingRewards} from "../../src/ETHStakingRewards.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PayoutReceiver {
    ETHStakingRewards public immutable staking;
    bool public rejectETH;
    bool public attack;
    uint256 public blockedCalls;
    uint256 public rewardsDuringCallback;
    uint256 public received;

    constructor(ETHStakingRewards staking_) {
        staking = staking_;
    }

    function setMode(bool rejectETH_, bool attack_) external {
        rejectETH = rejectETH_;
        attack = attack_;
    }

    function stake(uint256 amount) external {
        staking.token().approve(address(staking), amount);
        staking.stake(amount);
    }

    function withdraw(uint256 amount) external {
        staking.withdraw(amount);
    }

    function claim() external {
        staking.getReward();
    }

    function exit() external {
        staking.exit();
    }

    receive() external payable {
        require(!rejectETH, "receiver rejects ETH");
        require(msg.sender == address(staking), "unexpected payer");
        received += msg.value;
        if (!attack) return;
        rewardsDuringCallback = staking.rewards(address(this));
        bytes[6] memory calls = [
            abi.encodeCall(staking.stake, (1)),
            abi.encodeCall(staking.withdraw, (1)),
            abi.encodeCall(staking.getReward, ()),
            abi.encodeCall(staking.exit, ()),
            abi.encodeCall(staking.notifyRewardAmount, ()),
            abi.encodeCall(staking.restream, ())
        ];
        for (uint256 i; i < calls.length; ++i) {
            uint256 value = i == 4 ? 0.001 ether : 0;
            (bool success, bytes memory data) = address(staking).call{value: value}(calls[i]);
            require(!success, "reentry succeeded");
            require(
                keccak256(data)
                    == keccak256(abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)),
                "wrong reentry error"
            );
            ++blockedCalls;
        }
    }
}
