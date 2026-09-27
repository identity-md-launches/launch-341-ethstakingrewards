// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {ETHStakingRewards} from "../src/ETHStakingRewards.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PayoutReceiver} from "./helpers/PayoutReceiver.sol";
import {FailingToken} from "./helpers/FailingToken.sol";

contract ETHStakingRewardsTest is Test {
    LaunchToken private token;
    ETHStakingRewards private staking;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant DONOR = address(0xD0102);
    uint256 private constant DURATION = 7 days;
    uint256 private constant RATE = 1e12;
    uint256 private constant BUDGET = RATE * DURATION;

    function setUp() public {
        vm.warp(1_000_000);
        vm.chainId(11155111);
        token = new LaunchToken();
        staking = new ETHStakingRewards(address(token));
        token.transfer(ALICE, 1_000_000 ether);
        token.transfer(BOB, 1_000_000 ether);
        vm.prank(ALICE);
        token.approve(address(staking), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(staking), type(uint256).max);
        vm.deal(DONOR, 1000 ether);
    }

    function test_initialStateAndConstructorValidation() public {
        assertEq(address(staking.token()), address(token));
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.rewardPerToken(), 0);
        assertEq(staking.currentRate(), 0);
        assertEq(staking.carry(), 0);
        assertEq(staking.earned(ALICE), 0);
        assertEq(token.balanceOf(address(staking)), 0);
        vm.expectRevert(ETHStakingRewards.InvalidToken.selector);
        new ETHStakingRewards(address(0));
        vm.expectRevert(ETHStakingRewards.InvalidToken.selector);
        new ETHStakingRewards(ALICE);
    }

    function test_stakeWithdrawAndEvents() public {
        vm.expectEmit(true, false, false, true, address(staking));
        emit ETHStakingRewards.Staked(ALICE, 4 ether);
        _stake(ALICE, 4 ether);
        _stake(BOB, 6 ether);
        assertEq(staking.totalStaked(), 10 ether);
        assertEq(staking.stakedOf(ALICE), 4 ether);
        assertEq(token.balanceOf(address(staking)), 10 ether);
        uint256 before = token.balanceOf(ALICE);
        vm.expectEmit(true, false, false, true, address(staking));
        emit ETHStakingRewards.Withdrawn(ALICE, 1 ether);
        vm.prank(ALICE);
        staking.withdraw(1 ether);
        assertEq(staking.stakedOf(ALICE), 3 ether);
        assertEq(staking.totalStaked(), 9 ether);
        assertEq(token.balanceOf(ALICE), before + 1 ether);
    }

    function test_zeroAndExcessWithdrawalsRevert() public {
        vm.prank(ALICE);
        vm.expectRevert(ETHStakingRewards.ZeroAmount.selector);
        staking.stake(0);
        vm.prank(ALICE);
        vm.expectRevert(ETHStakingRewards.ZeroAmount.selector);
        staking.withdraw(0);
        _stake(ALICE, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(ETHStakingRewards.InsufficientStake.selector);
        staking.withdraw(1 ether + 1);
        vm.prank(BOB);
        vm.expectRevert(ETHStakingRewards.InsufficientStake.selector);
        staking.withdraw(1);
        assertEq(staking.totalStaked(), 1 ether);
    }

    function test_stakeRequiresAllowanceAndBalanceAndRollsBack() public {
        vm.prank(ALICE);
        token.approve(address(staking), 0);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(staking), 0, 1 ether)
        );
        staking.stake(1 ether);
        vm.prank(ALICE);
        token.approve(address(staking), type(uint256).max);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 1_000_000 ether, 1_000_000 ether + 1
            )
        );
        staking.stake(1_000_000 ether + 1);
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.stakedOf(ALICE), 0);
    }

    function test_getRewardPaysOnlyCallerAndCannotPayTwice() public {
        _stake(ALICE, 1 ether);
        _notify(BUDGET);
        vm.warp(block.timestamp + 1 days);
        uint256 expected = RATE * 1 days;
        assertEq(staking.earned(ALICE), expected);
        vm.prank(BOB);
        staking.getReward();
        assertEq(BOB.balance, 0);
        assertEq(staking.earned(ALICE), expected);
        vm.expectEmit(true, false, false, true, address(staking));
        emit ETHStakingRewards.RewardPaid(ALICE, expected);
        vm.prank(ALICE);
        staking.getReward();
        assertEq(ALICE.balance, expected);
        assertEq(staking.earned(ALICE), 0);
        assertEq(staking.rewards(ALICE), 0);
        vm.prank(ALICE);
        staking.getReward();
        assertEq(ALICE.balance, expected);
    }

    function test_withdrawPreservesEarnedAndExitIsAtomic() public {
        _stake(ALICE, 4 ether);
        _notify(BUDGET);
        vm.warp(block.timestamp + 1 days);
        vm.prank(ALICE);
        staking.withdraw(3 ether);
        assertEq(staking.earned(ALICE), RATE * 1 days);
        assertEq(ALICE.balance, 0);
        vm.warp(block.timestamp + 1 days);
        vm.prank(ALICE);
        staking.exit();
        assertEq(ALICE.balance, RATE * 2 days);
        assertEq(token.balanceOf(ALICE), 1_000_000 ether);
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.stakedOf(ALICE), 0);
        assertEq(staking.earned(ALICE), 0);
        vm.prank(ALICE);
        staking.exit();
        assertEq(ALICE.balance, RATE * 2 days);
    }

    function test_stakeWithdrawInSameBlockEarnsNothing() public {
        _notify(BUDGET);
        vm.warp(block.timestamp + 1 days);
        _stake(ALICE, 1 ether);
        vm.prank(ALICE);
        staking.withdraw(1 ether);
        vm.prank(ALICE);
        staking.getReward();
        assertEq(staking.earned(ALICE), 0);
        assertEq(ALICE.balance, 0);
        assertEq(staking.carry(), RATE * 1 days);
    }

    function test_midPeriodStakerOnlyEarnsFromJoining() public {
        _stake(ALICE, 1 ether);
        _notify(BUDGET);
        vm.warp(block.timestamp + 2 days);
        _stake(BOB, 3 ether);
        assertEq(staking.earned(BOB), 0);
        vm.warp(block.timestamp + 2 days);
        assertEq(staking.earned(ALICE), RATE * 2 days + RATE * 2 days / 4);
        assertEq(staking.earned(BOB), RATE * 2 days * 3 / 4);
    }

    function test_topUpOnlyAddsCarryAndDoesNotChangeStream() public {
        _stake(ALICE, 1 ether);
        _notify(BUDGET + 17);
        uint256 finish = staking.periodFinish();
        vm.warp(block.timestamp + 3 days);
        vm.expectEmit(false, false, false, true, address(staking));
        emit ETHStakingRewards.RewardAdded(1 ether, RATE, finish);
        _notify(1 ether);
        assertEq(staking.carry(), 1 ether + 17);
        assertEq(staking.rewardRate(), RATE);
        assertEq(staking.currentRate(), RATE);
        assertEq(staking.periodFinish(), finish);
        assertEq(staking.earned(ALICE), RATE * 3 days);
        vm.warp(finish);
        assertEq(staking.earned(ALICE), BUDGET);
        assertEq(staking.currentRate(), 0);
        assertEq(staking.rewardRate(), RATE);
        _notify(0.001 ether);
        uint256 nextBudget = 1.001 ether + 17;
        assertEq(staking.rewardRate(), nextBudget / DURATION);
        assertEq(staking.carry(), nextBudget % DURATION);
        assertEq(staking.periodFinish(), finish + DURATION);
        assertEq(staking.earned(ALICE), BUDGET);
    }

    function test_zeroStakeWholePeriodIsCarriedAndRestreamedWithoutDonor() public {
        _notify(BUDGET + 5);
        vm.warp(staking.periodFinish() + 3 days);
        assertEq(staking.carry(), BUDGET + 5);
        assertEq(staking.rewardPerToken(), 0);
        assertEq(staking.earned(ALICE), 0);
        _stake(ALICE, 1 ether);
        assertEq(staking.carry(), BUDGET + 5);
        vm.prank(BOB);
        staking.restream();
        assertEq(staking.rewardRate(), RATE);
        assertEq(staking.carry(), 5);
        vm.warp(staking.periodFinish());
        vm.prank(ALICE);
        staking.exit();
        assertEq(ALICE.balance, BUDGET);
        assertEq(address(staking).balance, 5);
    }

    function test_zeroStakeIntervalsAreCarriedExactlyOnce() public {
        _notify(BUDGET);
        vm.warp(block.timestamp + 1 days);
        assertEq(staking.carry(), RATE * 1 days);
        assertEq(staking.carry(), RATE * 1 days);
        _stake(ALICE, 1 ether);
        vm.warp(block.timestamp + 2 days);
        vm.prank(ALICE);
        staking.exit();
        vm.warp(block.timestamp + 1 days);
        assertEq(staking.carry(), RATE * 2 days);
        _notify(0.001 ether);
        assertEq(staking.carry(), RATE * 2 days + 0.001 ether);
        _stake(BOB, 1 ether);
        vm.warp(staking.periodFinish());
        assertEq(staking.earned(BOB), RATE * 3 days);
        staking.restream();
        uint256 recycled = RATE * 2 days + 0.001 ether;
        assertEq(staking.rewardRate(), recycled / DURATION);
        assertEq(staking.carry(), recycled % DURATION);
    }

    function test_notifyMinimumAndNoDirectETHEntry() public {
        vm.prank(DONOR);
        vm.expectRevert(ETHStakingRewards.RewardTooSmall.selector);
        staking.notifyRewardAmount{value: 0.001 ether - 1}();
        vm.prank(DONOR);
        vm.expectRevert(ETHStakingRewards.RewardTooSmall.selector);
        staking.notifyRewardAmount();
        vm.prank(DONOR);
        (bool emptySuccess,) = address(staking).call{value: 1 ether}("");
        assertFalse(emptySuccess);
        vm.prank(DONOR);
        (bool unknownSuccess,) = address(staking).call{value: 1 ether}(hex"deadbeef");
        assertFalse(unknownSuccess);
        assertEq(address(staking).balance, 0);
        _notify(0.001 ether);
        assertEq(staking.rewardRate(), 0.001 ether / DURATION);
        assertEq(staking.carry(), 0.001 ether % DURATION);
    }

    function test_restreamRequiresFinishedPeriodStakeAndMinimumCarry() public {
        vm.expectRevert(ETHStakingRewards.NoStake.selector);
        staking.restream();
        _stake(ALICE, 1 ether);
        vm.expectRevert(ETHStakingRewards.InsufficientCarry.selector);
        staking.restream();
        _notify(BUDGET);
        _notify(0.001 ether);
        vm.warp(staking.periodFinish() - 1);
        vm.expectRevert(ETHStakingRewards.StreamActive.selector);
        staking.restream();
        vm.warp(staking.periodFinish());
        assertEq(staking.currentRate(), 0);
        staking.restream();
        assertEq(staking.rewardRate(), 0.001 ether / DURATION);
        vm.expectRevert(ETHStakingRewards.StreamActive.selector);
        staking.restream();
    }

    function test_restreamRejectsNoStakersEvenWithEnoughCarry() public {
        _notify(BUDGET);
        vm.warp(staking.periodFinish());
        vm.expectRevert(ETHStakingRewards.NoStake.selector);
        staking.restream();
        assertEq(staking.carry(), BUDGET);
    }

    function test_rewardsStopAtFinishAndLateStakeHasNoRetroactiveReward() public {
        _stake(ALICE, 1 ether);
        _notify(BUDGET);
        vm.warp(staking.periodFinish() + 300 days);
        _stake(BOB, 1 ether);
        assertEq(staking.earned(ALICE), BUDGET);
        assertEq(staking.earned(BOB), 0);
        assertEq(staking.currentRate(), 0);
        assertEq(staking.lastUpdateTime(), staking.periodFinish());
    }

    function test_failedPayoutPreservesClaimAndDoesNotBlockOtherStakersOrWithdrawal() public {
        PayoutReceiver receiver = new PayoutReceiver(staking);
        token.transfer(address(receiver), 1 ether);
        receiver.stake(1 ether);
        _stake(ALICE, 1 ether);
        _notify(BUDGET);
        vm.warp(block.timestamp + 1 days);
        uint256 claim = RATE * 1 days / 2;
        receiver.setMode(true, false);
        vm.expectRevert(ETHStakingRewards.ETHTransferFailed.selector);
        receiver.claim();
        assertEq(staking.earned(address(receiver)), claim);
        assertEq(address(staking).balance, BUDGET);
        vm.expectRevert(ETHStakingRewards.ETHTransferFailed.selector);
        receiver.exit();
        assertEq(staking.stakedOf(address(receiver)), 1 ether);
        assertEq(token.balanceOf(address(receiver)), 0);
        vm.prank(ALICE);
        staking.getReward();
        assertEq(ALICE.balance, claim);
        receiver.withdraw(1 ether);
        assertEq(token.balanceOf(address(receiver)), 1 ether);
        assertEq(staking.earned(address(receiver)), claim);
        receiver.setMode(false, false);
        receiver.claim();
        assertEq(receiver.received(), claim);
        assertEq(staking.earned(address(receiver)), 0);
    }

    function test_ETHCallbackCannotReenterAnyMutationAndRewardIsZeroBeforeCall() public {
        PayoutReceiver receiver = new PayoutReceiver(staking);
        token.transfer(address(receiver), 1 ether);
        receiver.stake(1 ether);
        receiver.setMode(false, true);
        _notify(BUDGET);
        vm.warp(block.timestamp + 1 days);
        receiver.claim();
        assertEq(receiver.blockedCalls(), 6);
        assertEq(receiver.rewardsDuringCallback(), 0);
        assertEq(receiver.received(), RATE * 1 days);
        assertEq(staking.stakedOf(address(receiver)), 1 ether);
        assertEq(staking.totalStaked(), 1 ether);
        assertEq(staking.earned(address(receiver)), 0);
        vm.warp(staking.periodFinish());
        receiver.exit();
        assertEq(receiver.blockedCalls(), 12);
        assertEq(receiver.received(), BUDGET);
        assertEq(staking.totalStaked(), 0);
        assertEq(address(staking).balance, 0);
    }

    function test_falseReturningTokenRollsBackStakeAndWithdraw() public {
        FailingToken faulty = new FailingToken();
        ETHStakingRewards other = new ETHStakingRewards(address(faulty));
        faulty.approve(address(other), type(uint256).max);
        faulty.setFail(true);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(faulty)));
        other.stake(1 ether);
        assertEq(other.totalStaked(), 0);
        faulty.setFail(false);
        other.stake(1 ether);
        faulty.setFail(true);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(faulty)));
        other.withdraw(1 ether);
        assertEq(other.totalStaked(), 1 ether);
        assertEq(other.stakedOf(address(this)), 1 ether);
        assertEq(faulty.balanceOf(address(other)), 1 ether);
    }

    function test_oneTokenMinorUnitAsOnlyStakeEarnsWholeStream() public {
        _stake(ALICE, 1);
        _notify(BUDGET);
        vm.warp(staking.periodFinish());
        assertEq(staking.earned(ALICE), BUDGET);
        vm.prank(ALICE);
        staking.exit();
        assertEq(ALICE.balance, BUDGET);
    }

    function test_precisionForTinyStakeBesideLargeStakeRoundsDownWithoutOverpaying() public {
        _stake(ALICE, 1);
        _stake(BOB, 1_000_000 ether);
        _notify(BUDGET);
        vm.warp(staking.periodFinish());
        assertEq(staking.earned(ALICE), 0);
        assertLe(staking.earned(BOB), BUDGET);
        assertLt(BUDGET - staking.earned(BOB), 1_000_001);
        assertLe(staking.earned(ALICE) + staking.earned(BOB) + staking.carry(), BUDGET);
    }

    function testFuzz_twoStakersDifferentAmountsAndJoinTimes(
        uint128 rawA,
        uint128 rawB,
        uint32 rawJoin,
        uint32 rawEnd,
        uint96 rawBudget
    ) public {
        uint256 amountA = bound(rawA, 1, 1_000_000 ether);
        uint256 amountB = bound(rawB, 1, 1_000_000 ether);
        uint256 join = bound(rawJoin, 0, DURATION);
        uint256 end = bound(rawEnd, join, 2 * DURATION);
        uint256 budget = bound(rawBudget, 0.001 ether, 100 ether);
        uint256 start = block.timestamp;
        _stake(ALICE, amountA);
        _notify(budget);
        uint256 rate = budget / DURATION;
        vm.warp(start + join);
        _stake(BOB, amountB);
        vm.warp(start + end);
        uint256 elapsedTogether = (end > DURATION ? DURATION : end) - join;
        uint256 indexA = join * rate * 1e18 / amountA;
        uint256 indexTogether = elapsedTogether * rate * 1e18 / (amountA + amountB);
        assertEq(staking.earned(ALICE), amountA * (indexA + indexTogether) / 1e18);
        assertEq(staking.earned(BOB), amountB * indexTogether / 1e18);
        uint256 scheduled = end < DURATION ? (DURATION - end) * rate : 0;
        assertLe(staking.earned(ALICE) + staking.earned(BOB) + staking.carry() + scheduled, budget);
        vm.prank(ALICE);
        staking.exit();
        vm.prank(BOB);
        staking.exit();
        assertLe(ALICE.balance + BOB.balance + staking.carry() + scheduled, budget);
        assertEq(address(staking).balance + ALICE.balance + BOB.balance, budget);
    }

    function _stake(address account, uint256 amount) private {
        vm.prank(account);
        staking.stake(amount);
    }

    function _notify(uint256 amount) private {
        vm.prank(DONOR);
        staking.notifyRewardAmount{value: amount}();
    }
}
