// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract StakingContract is ReentrancyGuard, Pausable, Ownable {
    // State variables
    IERC20 public stakingToken;
    
    // Constants
    uint256 public initialApr;
    uint256 public minLockDuration;
    uint256 public aprReductionPerThousand;
    uint256 public emergencyWithdrawPenalty;
    
    uint256 public constant REWARDS_PER_MINUTE_PRECISION = 1e18;
    uint256 public constant PRECISION = 1e18;
    
    // Storage variables
    uint256 public totalStaked;
    uint256 public currentRewardRate; // Current APR
    
    struct UserInfo {
        uint256 stakedAmount;
        uint256 lastStakeTimestamp;
        uint256 rewardDebt;
        uint256 pendingRewards;
    }
    
    mapping(address => UserInfo) public userInfo;
    
    // Add this struct after the UserInfo struct
    struct UserDetails {
        uint256 stakedAmount;
        uint256 lastStakeTimestamp;
        uint256 pendingRewards;
        uint256 timeUntilUnlock;
        bool canWithdraw;
    }
    
    // Events
    event Staked(
        address indexed user,
        uint256 amount,
        uint256 timestamp,
        uint256 newTotalStaked,
        uint256 currentRewardRate
    );

    event Withdrawn(
        address indexed user,
        uint256 amount,
        uint256 timestamp,
        uint256 newTotalStaked,
        uint256 currentRewardRate,
        uint256 rewardsAccrued
    );

    event RewardsClaimed(
        address indexed user,
        uint256 amount,
        uint256 timestamp,
        uint256 newPendingRewards,
        uint256 totalStaked
    );

    event RewardRateUpdated(
        uint256 oldRate,
        uint256 newRate,
        uint256 timestamp,
        uint256 totalStaked
    );

    event EmergencyWithdrawn(
        address indexed user,
        uint256 amount,
        uint256 penalty,
        uint256 timestamp,
        uint256 newTotalStaked
    );

    event StakingInitialized(
        address indexed stakingToken,
        uint256 initialRewardRate,
        uint256 timestamp
    );

    event StakingPaused(uint256 timestamp);
    event StakingUnpaused(uint256 timestamp);
    
    constructor(
        address _stakingToken,
        uint256 _initialApr,
        uint256 _minLockDuration,
        uint256 _aprReductionPerThousand,
        uint256 _emergencyWithdrawPenalty
    ) Ownable(msg.sender) {
        require(_stakingToken != address(0), "Invalid token address");
        require(_initialApr > 0, "Invalid APR");
        require(_minLockDuration > 0, "Invalid lock duration");
        require(_aprReductionPerThousand > 0, "Invalid reduction rate");
        require(_emergencyWithdrawPenalty <= 100, "Invalid penalty");
        
        stakingToken = IERC20(_stakingToken);
        initialApr = _initialApr;
        minLockDuration = _minLockDuration;
        aprReductionPerThousand = _aprReductionPerThousand;
        emergencyWithdrawPenalty = _emergencyWithdrawPenalty;
        currentRewardRate = _initialApr;
        
        emit StakingInitialized(_stakingToken, _initialApr, block.timestamp);
    }
    
    // Core functions
    function stake(uint256 _amount) external nonReentrant whenNotPaused {
        require(_amount > 0, "Cannot stake 0");
        require(_amount <= stakingToken.balanceOf(msg.sender), "Insufficient balance");
        
        // Update rewards before modifying stake
        _updateRewards(msg.sender);
        
        // Transfer tokens to contract
        require(stakingToken.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        
        // Update user info
        UserInfo storage user = userInfo[msg.sender];
        user.stakedAmount += _amount;
        user.lastStakeTimestamp = block.timestamp;
        
        // Update total staked
        totalStaked += _amount;
        
        // Update reward rate based on new total staked
        _updateRewardRate();
        
        emit Staked(
            msg.sender,
            _amount,
            block.timestamp,
            totalStaked,
            currentRewardRate
        );
    }
    
    function withdraw(uint256 _amount) external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        require(_amount > 0, "Cannot withdraw 0");
        require(_amount <= user.stakedAmount, "Insufficient staked amount");
        require(
            block.timestamp >= user.lastStakeTimestamp + minLockDuration,
            "Lock duration not met"
        );
        
        // Update rewards before withdrawal
        _updateRewards(msg.sender);
        
        // Update user info
        user.stakedAmount -= _amount;
        totalStaked -= _amount;
        
        // Transfer tokens back to user
        require(stakingToken.transfer(msg.sender, _amount), "Transfer failed");
        
        // Update reward rate
        _updateRewardRate();
        
        emit Withdrawn(
            msg.sender,
            _amount,
            block.timestamp,
            totalStaked,
            currentRewardRate,
            user.pendingRewards
        );
    }
    
    function emergencyWithdraw() external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        require(user.stakedAmount > 0, "No stake to withdraw");
        
        uint256 amount = user.stakedAmount;
        uint256 penalty = (amount * emergencyWithdrawPenalty) / 100;
        uint256 withdrawAmount = amount - penalty;
        
        // Reset user info
        user.stakedAmount = 0;
        user.pendingRewards = 0;
        user.rewardDebt = 0;
        
        totalStaked -= amount;
        
        // Transfer tokens minus penalty
        require(stakingToken.transfer(msg.sender, withdrawAmount), "Transfer failed");
        
        emit EmergencyWithdrawn(
            msg.sender,
            withdrawAmount,
            penalty,
            block.timestamp,
            totalStaked
        );
    }
    
    function claimRewards() external nonReentrant whenNotPaused {
        _updateRewards(msg.sender);
        UserInfo storage user = userInfo[msg.sender];
        
        uint256 rewards = user.pendingRewards;
        require(rewards > 0, "No rewards to claim");
        
        user.pendingRewards = 0;
        user.rewardDebt = 0;
        
        require(stakingToken.transfer(msg.sender, rewards), "Transfer failed");
        
        emit RewardsClaimed(
            msg.sender,
            rewards,
            block.timestamp,
            user.pendingRewards,
            totalStaked
        );
    }
    
    // Internal functions
    function _updateRewards(address _user) internal {
        UserInfo storage user = userInfo[_user];
        if (user.stakedAmount == 0) {
            return;
        }
        
        uint256 timeElapsed = block.timestamp - user.lastStakeTimestamp;
        uint256 minutesElapsed = timeElapsed / 60;
        
        if (minutesElapsed > 0) {
            // Use scaling factor for precision
            uint256 scalingFactor = 1e18;
            uint256 annualRate = currentRewardRate * scalingFactor / 100; // Convert percentage to decimal
            uint256 minutesPerYear = 365 days / 1 minutes;
            
            uint256 rewardPerMinute = (user.stakedAmount * annualRate) / (minutesPerYear * scalingFactor);
            uint256 newRewards = rewardPerMinute * minutesElapsed;
            
            user.pendingRewards += newRewards;
            user.lastStakeTimestamp = block.timestamp;
        }
    }
    
    function _updateRewardRate() internal {
        uint256 newRate = initialApr;
        
        // Avoid division by zero and ensure proper scaling
        if (totalStaked >= 1000 * 1e18) {
            uint256 scalingFactor = 1e18;
            uint256 thousandTokens = (totalStaked * scalingFactor) / (1000 * 1e18);
            uint256 reduction = (thousandTokens * aprReductionPerThousand) / scalingFactor;
            
            // Ensure we don't underflow when subtracting reduction
            newRate = reduction >= initialApr ? 10 : initialApr - reduction;
        }
        
        if (newRate != currentRewardRate) {
            uint256 oldRate = currentRewardRate;
            currentRewardRate = newRate;
            emit RewardRateUpdated(oldRate, newRate, block.timestamp, totalStaked);
        }
    }
    
    // View functions
    function getPendingRewards(address _user) public view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        if (user.stakedAmount == 0) {
            return user.pendingRewards;
        }
        
        uint256 timeElapsed = block.timestamp - user.lastStakeTimestamp;
        uint256 minutesElapsed = timeElapsed / 60;

        if (minutesElapsed > 0) {
            // Use same scaling factor logic as _updateRewards
            uint256 scalingFactor = 1e18;
            uint256 annualRate = currentRewardRate * scalingFactor / 100;
            uint256 minutesPerYear = 365 days / 1 minutes;
            
            uint256 rewardPerMinute = (user.stakedAmount * annualRate) / (minutesPerYear * scalingFactor);
            uint256 newRewards = rewardPerMinute * minutesElapsed;
            
            return user.pendingRewards + newRewards;
        }
        
        return user.pendingRewards;
    }
    
    function getTimeUntilUnlock(address _user) external view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        if (block.timestamp >= user.lastStakeTimestamp + minLockDuration) {
            return 0;
        }
        return user.lastStakeTimestamp + minLockDuration - block.timestamp;
    }
    
    // Add this view function before the admin functions
    function getUserDetails(address _user) external view returns (UserDetails memory) {
        UserInfo storage user = userInfo[_user];
        uint256 timeUntilUnlock = block.timestamp >= user.lastStakeTimestamp + minLockDuration ? 
            0 : 
            user.lastStakeTimestamp + minLockDuration - block.timestamp;
            
        return UserDetails({
            stakedAmount: user.stakedAmount,
            lastStakeTimestamp: user.lastStakeTimestamp,
            pendingRewards: getPendingRewards(_user),
            timeUntilUnlock: timeUntilUnlock,
            canWithdraw: block.timestamp >= user.lastStakeTimestamp + minLockDuration
        });
    }
    
    function getTotalRewards() external view returns (uint256) {
        uint256 contractBalance = stakingToken.balanceOf(address(this));
        // Ensure we don't underflow
        require(contractBalance >= totalStaked, "Invalid state: balance < staked");
        return contractBalance - totalStaked;
    }
    
    // Admin functions
    function pause() external onlyOwner {
        _pause();
        emit StakingPaused(block.timestamp);
    }
    
    function unpause() external onlyOwner {
        _unpause();
        emit StakingUnpaused(block.timestamp);
    }

    // Add emergency token recovery for wrong tokens sent to contract
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAddress != address(stakingToken), "Cannot recover staking token");
        IERC20(tokenAddress).transfer(owner(), tokenAmount);
        emit TokenRecovered(tokenAddress, tokenAmount, block.timestamp);
    }

    event TokenRecovered(
        address indexed token,
        uint256 amount,
        uint256 timestamp
    );

    // Add setter functions
    function setInitialApr(uint256 _newApr) external onlyOwner {
        require(_newApr > 0, "Invalid APR");
        initialApr = _newApr;
    }

    function setMinLockDuration(uint256 _newDuration) external onlyOwner {
        require(_newDuration > 0, "Invalid duration");
        minLockDuration = _newDuration;
    }

    function setAprReductionPerThousand(uint256 _newReduction) external onlyOwner {
        require(_newReduction > 0, "Invalid reduction");
        aprReductionPerThousand = _newReduction;
    }

    function setEmergencyWithdrawPenalty(uint256 _newPenalty) external onlyOwner {
        require(_newPenalty <= 100, "Invalid penalty");
        emergencyWithdrawPenalty = _newPenalty;
    }
} 