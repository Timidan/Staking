// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/StakingContract.sol";
import "./mocks/MockERC20.sol";

contract StakingContractTest is Test {

    error EnforcedPause();

    // Add events
    event Staked(address indexed user, uint256 amount, uint256 timestamp, uint256 newTotalStaked, uint256 currentRewardRate);
    event Withdrawn(address indexed user, uint256 amount, uint256 timestamp, uint256 newTotalStaked, uint256 currentRewardRate, uint256 rewardsAccrued);
    event RewardsClaimed(address indexed user, uint256 amount, uint256 timestamp, uint256 newPendingRewards, uint256 totalStaked);
    event RewardRateUpdated(uint256 oldRate, uint256 newRate, uint256 timestamp, uint256 totalStaked);
    event EmergencyWithdrawn(address indexed user, uint256 amount, uint256 penalty, uint256 timestamp, uint256 newTotalStaked);
    event StakingPaused(uint256 timestamp);
    event StakingUnpaused(uint256 timestamp);
    event StakingInitialized(address indexed stakingToken, uint256 initialRewardRate, uint256 timestamp);
    event TokenRecovered(address indexed token, uint256 amount, uint256 timestamp);

    StakingContract public staking;
    MockERC20 public token;
    
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    
    uint256 public constant INITIAL_BALANCE = 1000 * 1e18;
    
    // Add default config values
    uint256 public constant DEFAULT_APR = 250;
    uint256 public constant DEFAULT_LOCK_DURATION = 1 days;
    uint256 public constant DEFAULT_APR_REDUCTION = 5;
    uint256 public constant DEFAULT_WITHDRAW_PENALTY = 50;
    
    function setUp() public {
        token = new MockERC20();
        staking = new StakingContract(
            address(token),
            DEFAULT_APR,
            DEFAULT_LOCK_DURATION,
            DEFAULT_APR_REDUCTION,
            DEFAULT_WITHDRAW_PENALTY
        );
        
        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);
        
        vm.prank(alice);
        token.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        token.approve(address(staking), type(uint256).max);
    }

    function testInitialSetup() public {
        assertEq(address(staking.stakingToken()), address(token));
        assertEq(staking.currentRewardRate(), DEFAULT_APR);
        assertEq(staking.initialApr(), DEFAULT_APR);
        assertEq(staking.minLockDuration(), DEFAULT_LOCK_DURATION);
        assertEq(staking.aprReductionPerThousand(), DEFAULT_APR_REDUCTION);
        assertEq(staking.emergencyWithdrawPenalty(), DEFAULT_WITHDRAW_PENALTY);
        assertEq(staking.totalStaked(), 0);
    }
    
    function testStaking() public {
        uint256 stakeAmount = 100 * 1e18;
        
        vm.prank(alice);
        staking.stake(stakeAmount);
        
        (uint256 stakedAmount, uint256 lastStakeTimestamp, , ) = staking.userInfo(alice);
        assertEq(stakedAmount, stakeAmount);
        assertEq(lastStakeTimestamp, block.timestamp);
        assertEq(staking.totalStaked(), stakeAmount);
    }
    
    function testFailWithdrawBeforeLockPeriod() public {
        uint256 stakeAmount = 100 * 1e18;
        
        vm.prank(alice);
        staking.stake(stakeAmount);
        
        vm.prank(alice);
        staking.withdraw(stakeAmount);
    }
    
    function testWithdrawAfterLockPeriod() public {
        uint256 stakeAmount = 100 * 1e18;
        
        vm.prank(alice);
        staking.stake(stakeAmount);
        
        vm.warp(block.timestamp + staking.minLockDuration() + 1);
        
        vm.prank(alice);
        staking.withdraw(stakeAmount);
        
        (uint256 stakedAmount, , , ) = staking.userInfo(alice);
        assertEq(stakedAmount, 0);
        assertEq(staking.totalStaked(), 0);
    }
    
    function testRewardCalculation() public {
        uint256 stakeAmount = 100 * 1e18;
        
        vm.prank(alice);
        staking.stake(stakeAmount);
        
        // Advance time by 1 minute
        vm.warp(block.timestamp + 60);
        
        uint256 pendingRewards = staking.getPendingRewards(alice);
        assertTrue(pendingRewards > 0, "Should have accumulated rewards");
    }
    
    function testRewardRateReduction() public {
        uint256 largeStake = 1000 * 1e18; // 1000 tokens
        
        vm.prank(alice);
        staking.stake(largeStake);
        
        assertTrue(
            staking.currentRewardRate() < staking.initialApr(),
            "Rate should have decreased"
        );
    }
    
    function testEmergencyWithdraw() public {
        uint256 stakeAmount = 100 * 1e18;
        
        vm.prank(alice);
        staking.stake(stakeAmount);
        
        uint256 balanceBefore = token.balanceOf(alice);
        
        vm.prank(alice);
        staking.emergencyWithdraw();
        uint256 balanceAfter = token.balanceOf(alice);
        uint256 expectedReturn = (stakeAmount * (100 - staking.emergencyWithdrawPenalty())) / 100;
        
        assertEq(balanceAfter - balanceBefore, expectedReturn);
    }
    function testPause() public {
        staking.pause();
        
        vm.expectRevert((EnforcedPause.selector));
        vm.prank(alice);
        staking.stake(100 * 1e18);
    }
    
    function testGetUserDetails() public {
        uint256 stakeAmount = 100 * 1e18;
        
        vm.prank(alice);
        staking.stake(stakeAmount);
        
        StakingContract.UserDetails memory details = staking.getUserDetails(alice);
        
        assertEq(details.stakedAmount, stakeAmount);
        assertEq(details.lastStakeTimestamp, block.timestamp);
        assertEq(details.pendingRewards, 0); // No rewards yet as no time passed
        assertEq(details.timeUntilUnlock, staking.minLockDuration());
        assertFalse(details.canWithdraw);
        
        // Test after lock period
        vm.warp(block.timestamp + staking.minLockDuration() + 1);
        
        details = staking.getUserDetails(alice);
        assertTrue(details.canWithdraw);
        assertEq(details.timeUntilUnlock, 0);
        assertTrue(details.pendingRewards > 0);
    }
    
    function testGetTimeUntilUnlock() public {
        uint256 stakeAmount = 100 * 1e18;
        
        vm.prank(alice);
        staking.stake(stakeAmount);
        
        assertEq(
            staking.getTimeUntilUnlock(alice),
            DEFAULT_LOCK_DURATION
        );
        
        // Advance half the lock duration
        vm.warp(block.timestamp + DEFAULT_LOCK_DURATION / 2);
        assertEq(
            staking.getTimeUntilUnlock(alice),
            DEFAULT_LOCK_DURATION / 2
        );
        
        // Advance past lock duration
        vm.warp(block.timestamp + DEFAULT_LOCK_DURATION);
        assertEq(staking.getTimeUntilUnlock(alice), 0);
    }
    
    function testGetTotalRewards() public {
        uint256 stakeAmount = 100 * 1e18;
        
        // Mint extra tokens to contract to simulate rewards
        token.mint(address(staking), 10 * 1e18);
        
        vm.prank(alice);
        staking.stake(stakeAmount);
        
        assertEq(staking.getTotalRewards(), 10 * 1e18);
    }
    
    function testGetTotalRewardsRevert() public {
        uint256 stakeAmount = 100 * 1e18;
        
        vm.prank(alice);
        staking.stake(stakeAmount);
        
        // Simulate token loss (hack/drain)
        vm.prank(address(staking));
        token.transfer(address(0x1), 50 * 1e18);
        
        vm.expectRevert("Invalid state: balance < staked");
        staking.getTotalRewards();
    }
    
    function testRewardCalculationPrecision() public {
        // Test with small but not tiny stake amount
        uint256 smallStake = 1e6; // 0.000001 tokens
        token.mint(alice, smallStake); // Add this line to ensure enough balance
        
        vm.prank(alice);
        staking.stake(smallStake);
        
        // Advance 1 minute
        vm.warp(block.timestamp + 60);
        
        uint256 rewards = staking.getPendingRewards(alice);
        // Verify rewards are calculated without complete loss of precision
        assertTrue(rewards > 0, "Should accrue some rewards even with minimal stake");
    }
    
    function testRewardCalculationLargeStake() public {
        // Test with very large stake amount
        uint256 largeStake = 1_000_000 * 1e18;
        token.mint(alice, largeStake);
        
        vm.prank(alice);
        staking.stake(largeStake);
        
        // Advance 1 year
        vm.warp(block.timestamp + 365 days);
        
        uint256 rewards = staking.getPendingRewards(alice);
        // Verify rewards are calculated without overflow
        assertTrue(rewards > 0, "Should handle large stake amounts");
    }
    
    function testRewardRateDecrease() public {
        uint256 initialRate = staking.currentRewardRate();
        uint256 stakeAmount = 1000 * 1e18; // 1000 tokens
        uint256 largeStakeAmount = stakeAmount * 100; // For second stake
        
        // Mint enough tokens for both stakes
        token.mint(alice, stakeAmount + largeStakeAmount);
        
        vm.startPrank(alice);
        staking.stake(stakeAmount);
        uint256 newRate = staking.currentRewardRate();
        assertTrue(newRate < initialRate, "Rate should decrease");
        assertTrue(newRate >= 10, "Rate should not go below minimum");
        
        // Stake more to test minimum rate
        staking.stake(largeStakeAmount);
        uint256 finalRate = staking.currentRewardRate();
        assertEq(finalRate, 10, "Should hit minimum rate");
        vm.stopPrank();
    }
    
    function testEmergencyWithdrawPrecision() public {
        uint256 stakeAmount = 100 * 1e18;
        
        vm.prank(alice);
        staking.stake(stakeAmount);
        
        uint256 expectedReturn = (stakeAmount * (100 - 50)) / 100; // 50% penalty hardcoded
        uint256 expectedPenalty = stakeAmount - expectedReturn;
        
        vm.prank(alice);
        staking.emergencyWithdraw();
        
        // Verify precision in penalty calculation
        assertEq(
            token.balanceOf(alice),
            INITIAL_BALANCE - stakeAmount + expectedReturn,
            "Should return correct amount after penalty"
        );
        assertEq(
            token.balanceOf(address(staking)),
            expectedPenalty,
            "Should keep correct penalty amount"
        );
    }
    
    function testStakingEvents() public {
        uint256 stakeAmount = 100 * 1e18;
        
        vm.expectEmit(true, false, false, true);
        emit Staked(
            alice,
            stakeAmount,
            block.timestamp,
            stakeAmount,
            staking.initialApr()  // currentRewardRate
        );
        
        vm.prank(alice);
        staking.stake(stakeAmount);
    }
    
    function testWithdrawEvents() public {
        uint256 stakeAmount = 100 * 1e18;
        
        vm.prank(alice);
        staking.stake(stakeAmount);
        
        uint256 withdrawTime = block.timestamp + staking.minLockDuration() + 1;
        vm.warp(withdrawTime);
        
        // Get pending rewards before withdrawal
        uint256 pendingRewards = staking.getPendingRewards(alice);
        
        vm.expectEmit(true, false, false, true);
        emit Withdrawn(
            alice,
            stakeAmount,
            withdrawTime,
            0, // newTotalStaked
            staking.initialApr(),
            pendingRewards // Include actual pending rewards
        );
        
        vm.prank(alice);
        staking.withdraw(stakeAmount);
    }
    
    function testRewardClaimEvents() public {
        uint256 stakeAmount = 100 * 1e18;
        
        vm.prank(alice);
        staking.stake(stakeAmount);
        
        // Advance time to accumulate rewards
        vm.warp(block.timestamp + 60);
        
        uint256 expectedRewards = staking.getPendingRewards(alice);
        
        vm.expectEmit(true, false, false, true);
        emit RewardsClaimed(
            alice,
            expectedRewards,
            block.timestamp,
            0, // newPendingRewards
            stakeAmount // totalStaked
        );
        
        vm.prank(alice);
        staking.claimRewards();
    }
    
    function testRewardRateUpdateEvents() public {
        uint256 largeStake = 10_000 * 1e18;
        token.mint(alice, largeStake);
        
        uint256 oldRate = staking.currentRewardRate();
        
        vm.expectEmit(false, false, false, true);
        emit RewardRateUpdated(
            oldRate,
            oldRate - 50, // Expected new rate after 10k tokens
            block.timestamp,
            largeStake
        );
        
        vm.prank(alice);
        staking.stake(largeStake);
    }
    
    function testEmergencyWithdrawEvents() public {
        uint256 stakeAmount = 100 * 1e18;
        
        vm.prank(alice);
        staking.stake(stakeAmount);
        
        uint256 penalty = (stakeAmount * staking.emergencyWithdrawPenalty()) / 100;
        uint256 withdrawAmount = stakeAmount - penalty;
        
        vm.expectEmit(true, false, false, true);
        emit EmergencyWithdrawn(
            alice,
            withdrawAmount,
            penalty,
            block.timestamp,
            0 // newTotalStaked
        );
        
        vm.prank(alice);
        staking.emergencyWithdraw();
    }
    
    function testPauseEvents() public {
        vm.expectEmit(false, false, false, true);
        emit StakingPaused(block.timestamp);
        staking.pause();
        
        vm.expectEmit(false, false, false, true);
        emit StakingUnpaused(block.timestamp);
        staking.unpause();
    }
    
    function testInitializationEvent() public {
        address newTokenAddress = address(new MockERC20());
        
        vm.expectEmit(true, false, false, true);
        emit StakingInitialized(
            newTokenAddress,
            staking.initialApr(),
            block.timestamp
        );
        
        StakingContract newStaking = new StakingContract(newTokenAddress, staking.initialApr(), staking.minLockDuration(), staking.aprReductionPerThousand(), staking.emergencyWithdrawPenalty());
    }
    
    function testTokenRecoveryEvent() public {
        // Deploy a different token to recover
        MockERC20 wrongToken = new MockERC20();
        uint256 amount = 100 * 1e18;
        wrongToken.mint(address(staking), amount);
        
        vm.expectEmit(true, false, false, true);
        emit TokenRecovered(
            address(wrongToken),
            amount,
            block.timestamp
        );
        
        staking.recoverERC20(address(wrongToken), amount);
    }

    // Add test for config setters
    function testConfigSetters() public {
        uint256 newApr = 300;
        uint256 newLockDuration = 2 days;
        uint256 newReduction = 10;
        uint256 newPenalty = 25;

        staking.setInitialApr(newApr);
        staking.setMinLockDuration(newLockDuration);
        staking.setAprReductionPerThousand(newReduction);
        staking.setEmergencyWithdrawPenalty(newPenalty);

        assertEq(staking.initialApr(), newApr);
        assertEq(staking.minLockDuration(), newLockDuration);
        assertEq(staking.aprReductionPerThousand(), newReduction);
        assertEq(staking.emergencyWithdrawPenalty(), newPenalty);
    }

    // Add test for config validation
    function testConfigValidation() public {
        vm.expectRevert("Invalid APR");
        staking.setInitialApr(0);

        vm.expectRevert("Invalid duration");
        staking.setMinLockDuration(0);

        vm.expectRevert("Invalid reduction");
        staking.setAprReductionPerThousand(0);

        vm.expectRevert("Invalid penalty");
        staking.setEmergencyWithdrawPenalty(101);
    }
} 
