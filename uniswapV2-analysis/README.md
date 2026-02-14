# UniswapV2 代码分析

本仓库对 Uniswap V2 的 **Core** 与 **Periphery** 合约进行了中文注释与说明。具体注释请查看各 `.sol` 文件；架构与接口说明见子目录 README。

---

## 介绍

![Uniswap V2 架构示意](Encephalogram.png)

Uniswap V2 是以太坊上的去中心化交易协议，提供无需信任的代币兑换与流动性管理。本仓库特点：

1. **去中心化交易**：通过智能合约执行兑换与流动性操作，无需中心化交易所或托管。
2. **自动化做市商（AMM）**：流动性提供者向池子注入资产，通过常量乘积 \(x \cdot y = k\) 定价，并从 0.3% 交易手续费中分成。
3. **ERC-20 支持**：支持任意 ERC-20 交易对；任何人可创建新池并添加流动性。
4. **流动性挖矿与协议费**：可选协议费（`feeTo`）与 LP 激励；流动性提供者需注意无常损失风险。

---

## 仓库结构

| 目录 | 说明 | 详细文档 |
|------|------|----------|
| **v2-core/** | 核心合约：Factory、Pair、UniswapV2ERC20 等（Solidity 0.5.16） | [v2-core/README.md](v2-core/README.md) |
| **v2-periphery/** | 周边合约：Router02、Library、Migrator 等（Solidity 0.6.6） | [v2-periphery/README.md](v2-periphery/README.md) |

### Core（v2-core）

- **UniswapV2Factory**：创建交易对、管理 `feeTo`/`feeToSetter`；通过 CREATE2 部署 Pair，地址可预测。
- **UniswapV2Pair**：单一代币对的资金池——swap、mint、burn、K 校验、TWAP 累积、协议费（`_mintFee`）、flash swap 回调；LP token 为 UniswapV2ERC20。

详见 [v2-core/README.md](v2-core/README.md) 中的状态变量、事件、`createPair`/`mint`/`burn`/`swap` 及内部方法（`_update`、`_mintFee`）说明。

### Periphery（v2-periphery）

- **UniswapV2Router02**：用户入口——路径与滑点、ETH/WETH 包装、add/remove 流动性、多跳 swap；带 deadline、支持扣税代币（SupportingFeeOnTransferTokens）。
- **UniswapV2Library**：pairFor（CREATE2）、getReserves、quote、getAmountOut/In、getAmountsOut/In 等数学与地址推导。
- **UniswapV2LiquidityMathLibrary**：LP 价值与套利后储备/估值（抗操纵）。
- **UniswapV2Migrator**：V1 → V2 流动性一键迁移。

详见 [v2-periphery/README.md](v2-periphery/README.md) 中的 Router 添加/移除流动性、swap 系列及 Library/Migrator 说明。

---

## 本地部署

使用 Foundry 在本地（如 Anvil）部署 Core + Periphery 的步骤、init_code_hash 更新、两段式部署（无 solc 0.5.16 时）等，见：

- **[DEPLOY.md](DEPLOY.md)** — 编译、init_code_hash、部署命令与常见问题。

---

## 文档与反馈

- 合约内中文注释：见各 `v2-core/contracts/*.sol`、`v2-periphery/contracts/*.sol`。
- 架构与接口梳理：见 [v2-core/README.md](v2-core/README.md) 与 [v2-periphery/README.md](v2-periphery/README.md)。

如有错误或改进建议，欢迎反馈。
