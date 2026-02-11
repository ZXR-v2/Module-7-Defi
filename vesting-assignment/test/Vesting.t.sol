// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@/Vesting.sol";
import "@/MockERC20.sol";

contract VestingTest is Test {
    uint256 constant MONTH = 30 days;
    uint256 constant ALLOCATION = 1_000_000 ether;

    address deployer = address(0xA11CE);
    address beneficiary = address(0xB0B);

    MockERC20 token;
    Vesting vest;

    function setUp() public {
        vm.startPrank(deployer);

        token = new MockERC20("Mock", "MOCK");
        token.mint(deployer, ALLOCATION);

        vest = new Vesting(beneficiary, address(token));

        // 部署后转入 100 万
        token.transfer(address(vest), ALLOCATION);

        vm.stopPrank();
    }

    function test_CliffBefore_NoRelease() public {
        vm.startPrank(beneficiary);

        // 刚部署：不可领取
        vm.expectRevert("nothing to release");
        vest.release();

        // 11个月：不可领取
        vm.warp(vest.start() + 11 * MONTH);
        vm.expectRevert("nothing to release");
        vest.release();

        // 12个月（cliffEnd）：仍不可领取（从第13个月开始每月解锁）
        vm.warp(vest.start() + 12 * MONTH);
        vm.expectRevert("nothing to release");
        vest.release();

        vm.stopPrank();
    }

    function test_MonthlyUnlock_1of24() public {
        // 到第13个月（cliffEnd+1month）解锁 1/24
        vm.warp(vest.start() + 13 * MONTH);

        uint256 vested = vest.vestedAmount(block.timestamp);
        assertEq(vested, ALLOCATION / 24);

        vm.prank(beneficiary);
        vest.release();

        assertEq(token.balanceOf(beneficiary), ALLOCATION / 24);
        assertEq(vest.released(), ALLOCATION / 24);

        // 同一个月内再 release，不应再给
        vm.prank(beneficiary);
        vm.expectRevert("nothing to release");
        vest.release();
    }

    function test_MonthlyUnlock_2of24() public {
        // 第13个月 release 一次
        vm.warp(vest.start() + 13 * MONTH);
        vm.prank(beneficiary);
        vest.release();
        assertEq(token.balanceOf(beneficiary), ALLOCATION / 24);

        // 第14个月：累计应为 2/24，再 release 应补齐到 2/24
        vm.warp(vest.start() + 14 * MONTH);
        vm.prank(beneficiary);
        vest.release();

        assertEq(token.balanceOf(beneficiary), (ALLOCATION * 2) / 24);
    }

    function test_FullVesting_After36Months() public {
        // 12 + 24 = 36个月后应全额解锁
        vm.warp(vest.start() + 36 * MONTH);

        vm.prank(beneficiary);
        vest.release();

        assertEq(token.balanceOf(beneficiary), ALLOCATION);
        assertEq(token.balanceOf(address(vest)), 0);

        // 再 release 没有
        vm.prank(beneficiary);
        vm.expectRevert("nothing to release");
        vest.release();
    }

    function test_MidMonth_NoExtraUnlock() public {
        // 第13个月刚开始可领取 1/24
        vm.warp(vest.start() + 13 * MONTH);
        vm.prank(beneficiary);
        vest.release();
        assertEq(token.balanceOf(beneficiary), ALLOCATION / 24);

        // 13.5个月（中间）仍旧只有 1/24（按月阶梯解锁）
        vm.warp(vest.start() + 13 * MONTH + 15 days);
        vm.prank(beneficiary);
        vm.expectRevert("nothing to release");
        vest.release();
    }
}
