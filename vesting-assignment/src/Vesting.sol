// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

contract Vesting {
    event ERC20Released(address indexed token, uint256 amount);

    uint256 public constant MONTH = 30 days;
    uint256 public constant CLIFF_MONTHS = 12;
    uint256 public constant VESTING_MONTHS = 24;

    address public immutable beneficiary;
    IERC20 public immutable token;

    uint256 public immutable start;
    uint256 public immutable cliffEnd;

    uint256 public released;

    constructor(address _beneficiary, address _token) {
        require(_beneficiary != address(0), "beneficiary=0");
        require(_token != address(0), "token=0");
        beneficiary = _beneficiary;
        token = IERC20(_token);

        start = block.timestamp;
        cliffEnd = start + CLIFF_MONTHS * MONTH;
    }

    function release() external {
        uint256 vested = vestedAmount(block.timestamp);
        uint256 releasable = vested - released;
        require(releasable > 0, "nothing to release");

        released += releasable;

        emit ERC20Released(address(token), releasable);
        require(token.transfer(beneficiary, releasable), "transfer failed");
    }

    function totalAllocation() public view returns (uint256) {
        return token.balanceOf(address(this)) + released;
    }

    function vestedAmount(uint256 timestamp) public view returns (uint256) {
        // 合约管理的总代币（当前余额 + 已释放）
        uint256 total = totalAllocation();
        // ====== 1️⃣ Cliff 判断 ======
        // 在第13个月之前，全部锁定
        if (timestamp < cliffEnd + MONTH) {
            return 0;
        }
        // ====== 2️⃣ 计算已过多少个“完整月” ======
        // Solidity 整数除法自动向下取整
        // 例如：1.8个月 => 1个月
        uint256 monthsUnlocked = (timestamp - cliffEnd) / MONTH;
        // ====== 3️⃣ 封顶保护 ======
        // 最多只解锁24个月
        if (monthsUnlocked > VESTING_MONTHS) {
            monthsUnlocked = VESTING_MONTHS;
        }
        // ====== 4️⃣ 计算已解锁总量 ======
        // 解锁比例 = 已过月数 / 24
        return (total * monthsUnlocked) / VESTING_MONTHS;
    }


    function releasableAmount() external view returns (uint256) {
        return vestedAmount(block.timestamp) - released;
    }
}
