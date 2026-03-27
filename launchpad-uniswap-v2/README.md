# Meme Launchpad (Uniswap V2)

基于 **Foundry** 与 **Uniswap V2** 的 Meme 代币发行与交易合约：使用最小代理（EIP-1167）部署 Meme 代币，并将部分资金通过 Uniswap V2 添加流动性，支持从 DEX 购买。

## 功能概览

- **MemeFactory**：最小代理工厂，部署并登记 Meme 代币。
- **费用与流动性**：
  - 项目方收费 **5%**（`PROJECT_FEE_PERCENT`）；
  - 每次 mint 时，支付金额的 **5%** 作为 ETH，按**起始价格**折算对应 Token，调用 Uniswap V2 Router **addLiquidityETH** 添加流动性（首次添加即按 mint 价格建池）。
- **mintMeme**：用户支付 ETH，按设定价格铸造 Meme 代币；同时完成 5% 项目费、5% 流动性添加与 90% 发行方分成。
- **buyMeme**：当 Uniswap 上价格不劣于起始价格（含约 3% 滑点容差）时，用户可通过 **swapExactETHForTokens** 用 ETH 在 DEX 上购买 Meme。
- **MemeTwapOracle（TWAP）**：基于 Uniswap V2 Pair 的 **累计价格（`price0/1CumulativeLast`）** 计算 Meme/WETH 池的时间加权平均价，用于需要抗操纵参考价的场景（借贷、清算、展示等）。实现思路与 Uniswap v2-periphery 中的 `ExampleOracleSimple` 一致，**不修改** MemeFactory / Pair，仅只读 Factory 与 Pair 状态。

## TWAP（`MemeTwapOracle`）说明

Uniswap V2 在每个区块首次与池子交互时更新累计价格；本合约在链下可读「当前累计价」的基础上，用与官方一致的 **UQ112×112** 编码与当前储备推算块内 counterfactual 累计价（与 `UniswapV2OracleLibrary.currentCumulativePrices` 等价）。

**使用流程：**

1. **前提**：目标 Meme 已在链上存在 **Meme/WETH** 交易对且有流动性（例如已通过 `mintMeme` 完成首次加池）。
2. **`register(memeToken)`**：登记该 Meme，从 Uniswap V2 Factory 解析 `getPair(memeToken, weth)`，并记录初始累计价与时间戳；同一 `memeToken` 只能注册一次。
3. **等待至少 `minPeriod` 秒**（构造函数传入；测试可用较小值，主网建议 **≥ 300**）。
4. **`update(memeToken)`**：任何人可调用；若距上次观测已超过 `minPeriod`，则用累计价差除以时间得到 **TWAP 平均价**（UQ112），并更新快照。
5. **查询**：
   - `consultMemeInEth(memeToken, amountMeme)`：按**最近一次成功 `update`** 得到的 TWAP，估算 `amountMeme`（18 位小数）可兑得的 **WETH（wei）**；
   - `twapEthPer1e18Meme(memeToken)`：1 个 Meme（`1e18` 最小单位）在 TWAP 下对应多少 wei 的 ETH。

**注意：**

- 首次成功 `update` 之前，`consultMemeInEth` / `twapEthPer1e18Meme` 会 revert（尚无可用平均价）。
- TWAP 反映的是 **两次 `update` 之间** 的平均价，而非任意滑动窗口；若需更长窗口，应定期调用 `update` 或由链下根据累计价自行换算。
- 实现内联 UQ112 数学，**不依赖** `solidity-lib` 的 `FixedPoint`，以便在 **Solc 0.8.29** 等版本下直接编译通过。

## 合约结构

| 合约 | 说明 |
|------|------|
| `src/MemeFactory.sol` | 工厂：部署 Meme、mintMeme（含 addLiquidity）、buyMeme |
| `src/MemeToken.sol` | Meme 代币实现（ERC20 + 可升级初始化），作为最小代理模板 |
| `src/MemeTwapOracle.sol` | TWAP 预言机：对 Meme/WETH Pair 做 `register` / `update` / `consultMemeInEth` |

- 工厂依赖外部传入的 **Uniswap V2 Router** 与 **WETH** 地址（构造函数 `_router`, `_weth`）。
- 本仓库通过 `deployCode` 使用预编译的 Uniswap V2 Factory / Router 进行测试；`lib/v2-periphery` 中的 **UniswapV2Library** 已按当前构建的 UniswapV2Pair 更新 **init code hash**，以保证 `pairFor` 与真实部署地址一致。

### 对 v2-core 的修改（编译兼容）

`lib/v2-core/contracts/UniswapV2ERC20.sol` 中有一处修改，否则在现有 Foundry/Solc 下会因 Yul 语法报错而编译不通过：

- **位置**：构造函数内 assembly 块（约第 27 行）。
- **原代码**：`chainId := chainid`（旧版 Yul 中 `chainid` 为操作数写法）。
- **修改为**：`chainId := chainid()`（新版本中作为内置函数调用）。

```solidity
assembly {
    chainId := chainid()
}
```

该文件被 **UniswapV2Pair** 继承，因此修改会影响 Pair 的字节码；若今后再次改动 v2-core 中与 Pair 相关的代码，需要重新计算 UniswapV2Pair 的 creation code 的 keccak256，并更新 `lib/v2-periphery/contracts/libraries/UniswapV2Library.sol` 里的 init code hash。

## 依赖

- [Foundry](https://book.getfoundry.sh/)（Forge、Cast 等）
- Uniswap V2：`lib/v2-core`、`lib/v2-periphery`
- OpenZeppelin Upgradeable：`lib/openzeppelin-contracts-upgradeable`
- Solmate：`lib/solmate`（测试中的 WETH 等）

## 快速开始

### 安装 Foundry

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### 克隆与依赖

```bash
git clone https://github.com/<your-username>/launchpad-uniswap-v2.git
cd launchpad-uniswap-v2
# lib 已随仓库提交，一般无需再执行 forge install
forge build
```

### 构建

```bash
forge build
```

### 测试

需运行**全部测试**以编译 Uniswap V2 相关合约并生成正确 artifact（否则 `deployCode` 可能找不到 Factory/Router）：

```bash
forge test
```

带详细 trace：

```bash
forge test -vvv
```

当前测试包括：

- **UniV2.t.sol**：Uniswap V2 添加流动性与 ETH→Token 兑换。
- **MemeFactory.t.sol**：部署 Meme、mint 添加流动性、费用比例、`buyMeme`（含无 pair 时 revert、DEX 购买与最小输出断言）。
- **MemeTwapOracle.t.sol**：`register` / `update` / `consult` 与 `minPeriod` 行为；用 `vm.warp` 与多笔 **Router `swapExactETHForTokens`** 模拟不同时刻交易，校验 TWAP 与池子瞬时价的差异（因 `buyMeme` 有 97% 起始价保护，多笔小单易 revert，测试中池上成交通过 Router 直接模拟）。

### 格式化

```bash
forge fmt
```

### 部署说明

部署 **MemeFactory** 时需传入已部署的 Uniswap V2 Router 与 WETH 地址：

```solidity
new MemeFactory(routerAddress, wethAddress);
```

部署 **MemeTwapOracle** 时需传入 **Uniswap V2 Factory**（用于 `getPair`）、**WETH** 与 **最小更新间隔**（秒）：

```solidity
new MemeTwapOracle(uniswapV2FactoryAddress, wethAddress, minPeriodSeconds);
```

主网 / 测试网需先部署或引用现有 Uniswap V2 Factory、Router 与 WETH。

## 项目结构（简要）

```
launchpad-uniswap-v2/
├── src/
│   ├── MemeFactory.sol    # 工厂与 Uniswap V2 集成
│   ├── MemeToken.sol      # Meme 代币实现
│   ├── MemeTwapOracle.sol # Meme/WETH TWAP（V2 累计价）
│   └── Counter.sol        # 占位（供 script 编译）
├── test/
│   ├── MemeFactory.t.sol  # 工厂与 buyMeme 测试
│   ├── MemeTwapOracle.t.sol # TWAP 与多时刻 swap 模拟
│   ├── UniV2.t.sol        # Uniswap V2 基础测试
│   ├── ImportV2Core.sol
│   └── ImportV2Periphery.sol
├── script/
├── lib/
│   ├── v2-core/
│   ├── v2-periphery/
│   ├── openzeppelin-contracts-upgradeable/
│   └── ...
├── foundry.toml
└── remappings.txt
```

## 上传到 GitHub（提交所有项目文件）

本仓库应**完整上传**所有项目文件（含 `lib/`、`src/`、`test/`、`script/`、`.github/`、`foundry.toml`、`remappings.txt` 等），以便他人克隆后可直接 `forge build` / `forge test`，无需再执行 `forge install`。

### 方式一：launchpad-uniswap-v2 作为独立仓库根目录（推荐）

1. 在 GitHub 新建空仓库（如 `launchpad-uniswap-v2`），不要勾选 “Add a README”.
2. 在本地进入项目目录，添加远程并推送（**本仓库已包含完整 lib 与初始提交**）：

```bash
cd launchpad-uniswap-v2
git remote add origin https://github.com/<your-username>/launchpad-uniswap-v2.git
git push -u origin main
```

若使用 SSH：`git remote add origin git@github.com:<your-username>/launchpad-uniswap-v2.git`

若在 Windows 下执行 `git commit` 出现 `unknown option 'trailer'`，可使用 git 完整路径提交，例如：`"D:\Git\cmd\git.exe" commit --no-verify -m "消息"`，或在 WSL 中执行 git 命令。

### 方式二：当前已在父目录的 git 仓库中

若 `launchpad-uniswap-v2` 位于父仓库（如 `Module-7-Defi`）内，且希望**仅把该子目录**推送到单独 GitHub 仓库：

```bash
cd /path/to/Module-7-Defi
git subtree split -P launchpad-uniswap-v2 -b launchpad-only
cd launchpad-uniswap-v2
git init
git pull ../ launchpad-only
git add .
git commit -m "Initial commit: Meme Launchpad with Uniswap V2"
git remote add origin https://github.com/<your-username>/launchpad-uniswap-v2.git
git push -u origin main
```

或：将 `launchpad-uniswap-v2` 文件夹**复制到新目录**，在新目录中 `git init`，然后执行方式一中的 `git add .`、`commit`、`remote`、`push`。

### 确保所有文件被跟踪

- 不要遗漏 `lib/`（v2-core、v2-periphery、openzeppelin-contracts-upgradeable、solmate、forge-std 等），否则他人克隆后无法直接编译。
- `.gitignore` 已忽略 `cache/`、`out/`、`.env`，其余项目文件均应提交。

## 参考

- [Foundry Book](https://book.getfoundry.sh/)
- [Uniswap V2](https://github.com/Uniswap/v2-core)
- [Uniswap V2 文档：价格预言机](https://docs.uniswap.org/contracts/v2/guides/smart-contract-integration/building-an-oracle)（累计价与 TWAP 背景）
- [EIP-1167 最小代理](https://eips.ethereum.org/EIPS/eip-1167)
