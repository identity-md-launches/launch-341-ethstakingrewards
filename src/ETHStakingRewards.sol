// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Stake TRKL to share donated Sepolia test ETH. No yield or return is promised.
/// @dev Intended exclusively for the plain, fixed-supply LaunchToken. No owner or initialization calls.
contract ETHStakingRewards is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant DURATION = 7 days;
    uint256 public constant MIN_REWARD = 0.001 ether;
    uint256 private constant SCALE = 1e18;

    IERC20 public immutable token;
    uint256 public totalStaked;
    mapping(address account => uint256 amount) public stakedOf;

    uint256 public rewardRate;
    uint256 public periodFinish;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    mapping(address account => uint256 index) public userRewardPerTokenPaid;
    mapping(address account => uint256 amount) public rewards;
    uint256 private _carry;

    error InvalidToken();
    error ZeroAmount();
    error InsufficientStake();
    error RewardTooSmall();
    error StreamActive();
    error NoStake();
    error InsufficientCarry();
    error ETHTransferFailed();

    event Staked(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event RewardPaid(address indexed account, uint256 amount);
    /// @dev amount is fresh ETH for notifyRewardAmount, or the carry budget for restream.
    /// During a top-up rate and periodFinish remain the active stream's parameters.
    event RewardAdded(uint256 amount, uint256 rate, uint256 periodFinish);

    /// @param token_ The deployed TRKL address, supplied as $token by the project factory.
    constructor(address token_) {
        if (token_ == address(0) || token_.code.length == 0) revert InvalidToken();
        token = IERC20(token_);
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    /// @notice ETH wei per second; a completed stream reports zero.
    function currentRate() external view returns (uint256) {
        return block.timestamp < periodFinish ? rewardRate : 0;
    }

    /// @notice Unscheduled ETH, including elapsed time with no stake even before a checkpoint.
    function carry() public view returns (uint256) {
        if (totalStaked == 0) {
            return _carry + (lastTimeRewardApplicable() - lastUpdateTime) * rewardRate;
        }
        return _carry;
    }

    /// @notice Cumulative ETH reward per TRKL minor unit, scaled by 1e18.
    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        uint256 emitted = (lastTimeRewardApplicable() - lastUpdateTime) * rewardRate;
        return rewardPerTokenStored + Math.mulDiv(emitted, SCALE, totalStaked);
    }

    /// @notice Claimable ETH wei, with both divisions rounded down.
    function earned(address account) public view returns (uint256) {
        return
            rewards[account] + Math.mulDiv(stakedOf[account], rewardPerToken() - userRewardPerTokenPaid[account], SCALE);
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _updateReward(msg.sender);
        totalStaked += amount;
        stakedOf[msg.sender] += amount;
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _updateReward(msg.sender);
        _withdraw(msg.sender, amount);
    }

    function getReward() external nonReentrant {
        _updateReward(msg.sender);
        _payReward(msg.sender);
    }

    /// @notice Withdraw all of the caller's TRKL and claim ETH atomically; an empty exit is a no-op.
    function exit() external nonReentrant {
        _updateReward(msg.sender);
        uint256 amount = stakedOf[msg.sender];
        if (amount != 0) _withdraw(msg.sender, amount);
        _payReward(msg.sender);
    }

    /// @notice Donate at least 0.001 ETH. A running stream is never extended or repriced.
    function notifyRewardAmount() external payable nonReentrant {
        if (msg.value < MIN_REWARD) revert RewardTooSmall();
        _updateReward(address(0));
        if (block.timestamp < periodFinish) {
            _carry += msg.value;
        } else {
            _startStream(msg.value + _carry);
        }
        emit RewardAdded(msg.value, rewardRate, periodFinish);
    }

    /// @notice Start a finished stream again using carry alone, provided someone is staking.
    function restream() external nonReentrant {
        if (block.timestamp < periodFinish) revert StreamActive();
        _updateReward(address(0));
        if (totalStaked == 0) revert NoStake();
        uint256 amount = _carry;
        if (amount < MIN_REWARD) revert InsufficientCarry();
        _startStream(amount);
        emit RewardAdded(amount, rewardRate, periodFinish);
    }

    function _startStream(uint256 amount) private {
        rewardRate = amount / DURATION;
        _carry = amount % DURATION;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + DURATION;
    }

    function _updateReward(address account) private {
        uint256 applicable = lastTimeRewardApplicable();
        uint256 emitted = (applicable - lastUpdateTime) * rewardRate;
        if (totalStaked == 0) {
            _carry += emitted;
        } else {
            rewardPerTokenStored += Math.mulDiv(emitted, SCALE, totalStaked);
        }
        lastUpdateTime = applicable;
        if (account != address(0)) {
            rewards[
                account
            ] += Math.mulDiv(stakedOf[account], rewardPerTokenStored - userRewardPerTokenPaid[account], SCALE);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    function _withdraw(address account, uint256 amount) private {
        if (amount > stakedOf[account]) revert InsufficientStake();
        stakedOf[account] -= amount;
        totalStaked -= amount;
        token.safeTransfer(account, amount);
        emit Withdrawn(account, amount);
    }

    function _payReward(address account) private {
        uint256 amount = rewards[account];
        if (amount == 0) return;
        rewards[account] = 0;
        (bool success,) = payable(account).call{value: amount}("");
        if (!success) revert ETHTransferFailed();
        emit RewardPaid(account, amount);
    }
}
