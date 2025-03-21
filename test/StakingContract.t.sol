// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/StakingContract.sol";
import "./mocks/MockERC20.sol";

contract StakingContractTest is Test {

    error EnforcedPause();
    StakingContract public staking;
    MockERC20 public token;
    
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    
    uint256 public constant INITIAL_BALANCE = 1000 * 1e18;
    
    function setUp() public {
        token = new MockERC20();
        staking = new StakingContract(address(token));
        
        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);
        
        vm.prank(alice);
        token.approve(address(staking), type(uint256).max);
        vm.prank(bob);
        token.approve(address(staking), type(uint256).max);
    }

    function testInitialSetup() public {
        assertEq(address(staking.stakingToken()), address(token));
        assertEq(staking.currentRewardRate(), staking.INITIAL_APR());
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
        
        vm.warp(block.timestamp + staking.MIN_LOCK_DURATION() + 1);
        
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
            staking.currentRewardRate() < staking.INITIAL_APR(),
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
        uint256 expectedReturn = (stakeAmount * (100 - staking.EMERGENCY_WITHDRAW_PENALTY())) / 100;
        
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
        assertEq(details.timeUntilUnlock, staking.MIN_LOCK_DURATION());
        assertFalse(details.canWithdraw);
        
        // Test after lock period
        vm.warp(block.timestamp + staking.MIN_LOCK_DURATION() + 1);
        
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
            staking.MIN_LOCK_DURATION()
        );
        
        // Advance half the lock duration
        vm.warp(block.timestamp + staking.MIN_LOCK_DURATION() / 2);
        assertEq(
            staking.getTimeUntilUnlock(alice),
            staking.MIN_LOCK_DURATION() / 2
        );
        
        // Advance past lock duration
        vm.warp(block.timestamp + staking.MIN_LOCK_DURATION());
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
        
        uint256 expectedReturn = (stakeAmount * (100 - staking.EMERGENCY_WITHDRAW_PENALTY())) / 100;
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
} 