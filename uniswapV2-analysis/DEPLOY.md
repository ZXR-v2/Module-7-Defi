# Uniswap V2 本地部署说明（Foundry）

本仓库为**统一 Foundry 工程**：在根目录一次编译 Core + Periphery，并支持本地部署。

## 1. 工程结构

- **v2-core/**：Uniswap V2 核心（Factory、Pair、UniswapV2ERC20 等）
- **v2-periphery/contracts/**：周边（Router02、UniswapV2Library、Migrator 等）
- **foundry.toml**（根目录）：以 `v2-periphery/contracts` 为 `src`，通过 remapping 引入 v2-core 与 uniswap-lib
- **script/Deploy.s.sol**：部署脚本（WETH、Factory、Router02）

周边库的 **pairFor** 使用 CREATE2 推导 Pair 地址，依赖 **init_code_hash**（Pair 创建字节码的 keccak256）。  
该 hash 必须与**本工程当前编译出的 UniswapV2Pair 的 creation bytecode** 一致，否则 Router 算出的 Pair 地址会错误。

## 2. 获取并更新 init_code_hash

在仓库根目录执行：

```bash
# 1. 编译（会同时编译 v2-core 的 Pair）
forge build

# 2. 得到 Pair 的 creation bytecode 的 keccak256（即 init_code_hash）
cast keccak $(forge inspect UniswapV2Pair bytecode)
# 输出示例：0xe4bb86aacf000f26feb63fc943244ca2be161301fde89f87c3e096f6547d9282
```

将得到的 **64 位十六进制**（去掉前缀 `0x`）填入：

**文件**：`v2-periphery/contracts/libraries/UniswapV2Library.sol`  
**位置**：`pairFor` 函数中的 `hex'...'` 常量。

例如当前为：

```solidity
hex'e4bb86aacf000f26feb63fc943244ca2be161301fde89f87c3e096f6547d9282'
```

若你本地编译得到的 hash 不同（例如换了 Solidity 版本或优化选项），替换为你的 hash，然后**再次执行** `forge build`。

## 3. 本地部署

### 3.1 启动本地节点

```bash
anvil
```

### 3.2 执行部署脚本

**从 v2-periphery 目录**（推荐，与上面编译方式 A 一致）：

```bash
cd v2-periphery
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

或从**仓库根目录**（需根目录 `forge build` 已成功）：

```bash
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

脚本会依次部署：

1. **WETH9**（与 IWETH 兼容的 WETH）
2. **UniswapV2Factory**（feeToSetter 为部署者地址）
3. **UniswapV2Router02**（factory + WETH）

默认使用 Anvil 第一个账户私钥；若需指定私钥，可修改 `script/Deploy.s.sol` 中的 `deployerPrivateKey` 或配合使用 `--private-key`。

### 3.3 仅模拟（不广播）

```bash
forge script script/Deploy.s.sol
```

## 4. 编译说明

- **方式 A（推荐）**：先单独编译 Core，再编译 Periphery，并保证 init_code_hash 来自当前 Pair 字节码。
  1. 在 **v2-core** 目录：`forge build`（使用 solc 0.5.16）。
  2. 在 v2-core 目录执行：`cast keccak $(forge inspect UniswapV2Pair bytecode)`，得到 init_code_hash。
  3. 将得到的 64 位十六进制写入 **v2-periphery/contracts/libraries/UniswapV2Library.sol** 的 `pairFor` 中。
  4. 在 **v2-periphery** 目录：`forge build`（会拉取 v2-core 的 0.5.16 依赖；若报错 “No solc version =0.5.16”，见下方）。
- **方式 B**：在**仓库根目录**使用根目录的 `foundry.toml` 执行 `forge build`，会一次性编译 Periphery + Core，同样需先按步骤 2 更新 init_code_hash。根目录构建也需本机有 solc 0.5.16。

**若出现 “No solc version exists that matches =0.5.16”**：  
可用**两段式部署**（无需在 v2-periphery 安装 0.5.16）：

1. **在 v2-core 部署 Factory**（v2-core 使用 solc 0.5.16，可单独编译）。  
   > **重要**：`--constructor-args` 是可变参数，**必须放在命令最后**，否则后面的 `--rpc-url` / `--private-key` 等会被当作构造函数参数吞掉。

   **方式 A — 用私钥（通用）**：
   ```bash
   cd v2-core
   forge create UniswapV2Factory \
     --rpc-url http://127.0.0.1:8545 \
     --broadcast \
     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
     --constructor-args 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
   ```

   **方式 B — Anvil 已解锁账户（无需私钥）**：
   ```bash
   cd v2-core
   forge create UniswapV2Factory \
     --rpc-url http://127.0.0.1:8545 \
     --broadcast \
     --unlocked --from 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
     --constructor-args 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
   ```

   **说明**：`0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` 是 Anvil 默认第一个账户（feeToSetter），可换成任意治理地址。  
   记下输出中的 `Deployed to: 0x...` 作为 Factory 地址，我部署的地址为0x5FbDB2315678afecb367f032d93F642f64180aa3

2. **在 v2-periphery 打开 `script/Deploy.s.sol`**，把常量 `FACTORY` 改成上一步的地址。

3. **在 v2-periphery 执行**：
   ```bash
   forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
   ```
   该脚本只部署 WETH 和 Router02（仅用 0.6.6），不再 import Factory。

## 5. 小结

| 步骤 | 命令 / 操作 |
|------|------------------|
| 编译 | 在根目录 `forge build` |
| 查 init_code_hash | `cast keccak $(forge inspect UniswapV2Pair bytecode)` |
| 更新 hash | 将结果（64 位 hex，无 0x）写入 `UniswapV2Library.sol` 的 pairFor |
| 再次编译 | 在 v2-periphery 或根目录 `forge build` |
| 部署 | `anvil` 后 `cd v2-periphery && forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast` |

这样周边代码库 pairFor 中的 **init_code_hash** 与本工程编译的 Pair 一致，本地部署的 Router 能正确推导 Pair 地址。
