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
} 