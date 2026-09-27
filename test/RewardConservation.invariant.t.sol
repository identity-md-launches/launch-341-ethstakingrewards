// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {ETHStakingRewards} from "../src/ETHStakingRewards.sol";

contract RewardHandler is Test {
    LaunchToken public immutable token;
    ETHStakingRewards public immutable staking;
    address[5] public actors = [address(0x1001), address(0x1002), address(0x1003), address(0x1004), address(0x1005)];
    uint256 public totalNotified;
    uint256 public totalPaid;

    constructor(LaunchToken token_, ETHStakingRewards staking_) {
        token = token_;
        staking = staking_;
    }

    function stake(uint256 actorSeed, uint256 rawAmount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 available = token.balanceOf(actor);
        if (available == 0) return;
        uint256 amount = bound(rawAmount, 1, available);
        vm.prank(actor);
        staking.stake(amount);
    }

    function withdraw(uint256 actorSeed, uint256 rawAmount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 available = staking.stakedOf(actor);
        if (available == 0) return;
        uint256 amount = bound(rawAmount, 1, available);
        vm.prank(actor);
        staking.withdraw(amount);
    }

    function claim(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 before = actor.balance;
        vm.prank(actor);
        staking.getReward();
        totalPaid += actor.balance - before;
    }

    function exit(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 before = actor.balance;
        vm.prank(actor);
        staking.exit();
        totalPaid += actor.balance - before;
    }

    function notify(uint256 rawAmount) external {
        uint256 amount = bound(rawAmount, 0.001 ether, 10 ether);
        uint256 oldFinish = staking.periodFinish();
        uint256 oldRate = staking.rewardRate();
        uint256 oldCarry = staking.carry();
        staking.notifyRewardAmount{value: amount}();
        totalNotified += amount;
        if (block.timestamp < oldFinish) {
            assertEq(staking.periodFinish(), oldFinish, "top-up extended stream");
            assertEq(staking.rewardRate(), oldRate, "top-up changed rate");
            assertEq(staking.carry(), oldCarry + amount, "top-up not carried");
        } else {
            assertEq(staking.periodFinish(), block.timestamp + 7 days);
            assertEq(staking.rewardRate(), (oldCarry + amount) / 7 days);
            assertEq(staking.carry(), (oldCarry + amount) % 7 days);
        }
    }

    function elapse(uint32 rawSeconds) external {
        vm.warp(block.timestamp + bound(rawSeconds, 0, 21 days));
    }

    function restream() external {
        if (block.timestamp < staking.periodFinish() || staking.totalStaked() == 0 || staking.carry() < 0.001 ether) {
            return;
        }
        uint256 budget = staking.carry();
        staking.restream();
        assertEq(staking.periodFinish(), block.timestamp + 7 days);
        assertEq(staking.rewardRate(), budget / 7 days);
        assertEq(staking.carry(), budget % 7 days);
    }
}

contract RewardConservationInvariantTest is StdInvariant, Test {
    LaunchToken private token;
    ETHStakingRewards private staking;
    RewardHandler private handler;

    function setUp() public {
        vm.warp(1_000_000);
        token = new LaunchToken();
        staking = new ETHStakingRewards(address(token));
        handler = new RewardHandler(token, staking);
        vm.deal(address(handler), 1_000_000 ether);
        for (uint256 i; i < 5; ++i) {
            address actor = handler.actors(i);
            token.transfer(actor, token.totalSupply() / 5);
            vm.prank(actor);
            token.approve(address(staking), type(uint256).max);
        }

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.stake.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.exit.selector;
        selectors[4] = handler.notify.selector;
        selectors[5] = handler.elapse.selector;
        selectors[6] = handler.restream.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_rewardsNeverExceedNotifiedETH() public view {
        uint256 earnedSum;
        uint256 paidSum;
        for (uint256 i; i < 5; ++i) {
            address actor = handler.actors(i);
            earnedSum += staking.earned(actor);
            paidSum += actor.balance;
        }
        uint256 scheduled;
        if (block.timestamp < staking.periodFinish()) {
            scheduled = (staking.periodFinish() - block.timestamp) * staking.rewardRate();
        }
        assertEq(paidSum, handler.totalPaid());
        assertLe(paidSum + earnedSum + staking.carry() + scheduled, handler.totalNotified());
        assertEq(address(staking).balance + paidSum, handler.totalNotified());
    }

    function invariant_allTRKLDepositsRemainBacked() public view {
        uint256 stakeSum;
        uint256 liquidSum;
        for (uint256 i; i < 5; ++i) {
            address actor = handler.actors(i);
            stakeSum += staking.stakedOf(actor);
            liquidSum += token.balanceOf(actor);
        }
        assertEq(stakeSum, staking.totalStaked());
        assertEq(token.balanceOf(address(staking)), stakeSum);
        assertEq(liquidSum + stakeSum, 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    function invariant_currentRateReflectsExpiry() public view {
        assertEq(staking.currentRate(), block.timestamp < staking.periodFinish() ? staking.rewardRate() : 0);
    }

    /// @dev Every random sequence can be unwound without trapping any participant's principal or claim.
    function afterInvariant() public {
        if (block.timestamp < staking.periodFinish()) vm.warp(staking.periodFinish());
        for (uint256 i; i < 5; ++i) {
            handler.exit(i);
            assertEq(staking.earned(handler.actors(i)), 0);
            assertEq(token.balanceOf(handler.actors(i)), 1e27 / 5);
        }
        assertEq(staking.totalStaked(), 0);
        invariant_rewardsNeverExceedNotifiedETH();
        invariant_allTRKLDepositsRemainBacked();
    }
}
