# Token Vesting with Cliff & Monthly Release

这是一个基于 Solidity 实现的 **ERC20 代币锁仓（Vesting）合约**，支持  
**12 个月 Cliff + 随后 24 个月按月线性释放（每月释放 1/24）**，并使用 **Foundry** 进行时间模拟测试。

---

## 合约功能概述

- 合约部署后立即开始计算 Cliff（锁定期）
- **前 12 个月（Cliff 期）不可释放任何代币**
- 从 **第 13 个月开始**，每过 1 个月解锁 **总代币的 1/24**
- 最长释放周期：**36 个月（12 + 24）**
- 受益人需主动调用 `release()` 领取当前已解锁的 ERC20
- 支持多次调用 `release()`，只会释放“新增可领取部分”

---

## Vesting 规则说明

| 阶段 | 时间 | 可释放比例 |
|----|----|----|
| Cliff | 第 0–12 个月 | 0 |
| 线性释放 | 第 13–36 个月 | 每月 1/24 |
| 完全释放 | ≥36 个月 | 100% |

> ⚠️ 链上无“自然月”概念，合约中采用 **1 month = 30 days** 作为时间单位（行业常见做法）

---

## 合约参数

| 参数 | 说明 |
|----|----|
| `beneficiary` | 受益人地址 |
| `token` | 锁定的 ERC20 代币地址 |
| `start` | 合约部署时间 |
| `cliffEnd` | Cliff 结束时间（start + 12 months） |

---

## 主要方法说明

### `release()`

- 将**当前已解锁但尚未领取**的 ERC20 转给受益人
- 若当前无可领取额度，将直接 revert

### `vestedAmount(uint256 timestamp)`

- 返回在指定时间点下**理论上已解锁的代币总量**

### `releasableAmount()`

- 返回当前时间点下**可领取但尚未领取**的代币数量

---

## 项目结构

```text
.
├── src
│   ├── Vesting.sol        # Vesting 合约
│   └── MockERC20.sol      # 测试用 ERC20
└── test
    └── Vesting.t.sol      # Foundry 时间模拟测试
