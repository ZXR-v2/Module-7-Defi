# UniswapV2 Periphery 合约说明

基于 `UniswapV2Router02.sol`、`UniswapV2Library.sol`、`UniswapV2LiquidityMathLibrary.sol`、`UniswapV2Migrator.sol` 内注释整理。

---

## 整体架构（Core vs Periphery vs Library）

- **Pair（core）**：只做“资金池引擎”——swap / mint / burn、K 校验、reserve 更新；不做路径、滑点、路径计算。
- **Router（periphery）**：负责“用户体验层”——路径、滑点、转账、ETH/WETH 包装、多跳 swap。
- **Library**：负责“数学 + 地址推导”——pairFor、getReserves、quote、getAmountOut、getAmountsOut 等。

Router 特点：

1. 所有用户级接口都带 **deadline**，防止交易被过期执行（防 MEV/延迟）。
2. **ETH 不能直接进 Pair**（Pair 只管 ERC20），Router 用 **WETH** 包装。
3. **Router02** 相比 Router01 增加 **SupportingFeeOnTransferTokens** 系列，兼容转账扣税币。

**滑点**：`amountMin = amountDesired - (amountDesired * 0.01)` 表示约 1% 滑点容忍度。

---

# UniswapV2Router02

构造函数传入 **factory** 和 **WETH** 地址。Router 是与 Pair 交互的入口，用于添加/移除流动性、兑换、获取报价等。

## 状态与修饰符

| 名称 | 说明 |
|------|------|
| `factory` | 用于查找/创建 Pair，以及在 Library 中推导 pair 地址 |
| `WETH` | 把 ETH 包装成 ERC20，让 Pair 能处理 ETH 相关交易 |
| `ensure(deadline)` | 校验 `deadline >= block.timestamp`，防过期执行 |

**receive()**：只接受来自 **WETH 合约** 的 ETH（即 `IWETH.withdraw()` 时回到 Router），避免他人直接打 ETH 导致资产滞留或逻辑混乱。

---

## 添加流动性

### _addLiquidity（内部核心算法）

- **输入**：amountADesired / amountBDesired（愿意提供的最大数量）、amountAMin / amountBMin（滑点保护）。
- **输出**：amountA / amountB（计算出的最优注入数量）。

**逻辑**：

1. 若池子不存在：先 `Factory.createPair`。
2. 用 `UniswapV2Library.getReserves` 读当前储备。
3. 若池子为空（reserveA=reserveB=0）：直接按 desired 注入（初始化）。
4. 若池子已有资产：按当前比例注入——
   - 用 `quote(amountADesired, reserveA, reserveB)` 算 B 的最优值；
   - 若 amountBOptimal ≤ amountBDesired，用 (amountADesired, amountBOptimal)，并校验 amountBOptimal ≥ amountBMin；
   - 否则用 amountBDesired 反算 amountAOptimal，用 (amountAOptimal, amountBDesired)，并校验 amountAOptimal ≥ amountAMin。

注意：`quote` 只做比例换算（不含 0.3% 交易费），用于加流动性配比。

### addLiquidity（两个 ERC20）

1. `_addLiquidity` 得到 amountA、amountB。
2. `pair = UniswapV2Library.pairFor(factory, tokenA, tokenB)`（CREATE2 推导，无需链上 getPair）。
3. `TransferHelper.safeTransferFrom` 将 tokenA、tokenB 转入 Pair。
4. `IUniswapV2Pair(pair).mint(to)`：Pair 内部按 balance−reserve 计算 liquidity 并铸 LP 给 to。

### addLiquidityETH（token + ETH）

- Pair 只收 ERC20，所以：用户发 ETH → Router 调 `WETH.deposit{value: amountETH}()` → 把 WETH 转入 Pair → `Pair.mint(to)`。
- 若 `msg.value > amountETH`，多余 ETH 退还给用户（dust refund）。

---

## 移除流动性

### removeLiquidity（两个 ERC20）

1. 用 `pairFor` 找到 Pair。
2. 把 LP 从用户 `transferFrom` 到 **Pair**（不是 Router）。
3. 调 `Pair.burn(to)`：Pair 按份额把两种 token 直接转给 to。
4. burn 返回 (amount0, amount1) 对应 token0/token1，用 `sortTokens` 映射回 (amountA, amountB)。
5. 校验 amountA ≥ amountAMin、amountB ≥ amountBMin。

### removeLiquidityETH（token + ETH）

1. 调 `removeLiquidity(token, WETH, ..., to: address(this))`，Pair 把 token 和 WETH 转到 Router。
2. Router 把 token 转给用户。
3. Router 调 `WETH.withdraw(amountETH)`，再把 ETH 转给用户。

### removeLiquidityWithPermit / removeLiquidityETHWithPermit

- 用 **permit**（EIP-2612）一步完成“授权 + 移除流动性”，无需先 approve 再第二笔交易。
- `approveMax`：true 授权 uint(-1)，false 只授权本次 liquidity。

### removeLiquidityETHSupportingFeeOnTransferTokens

- **扣税币**：Pair burn 给 Router 的 token 可能少于“理论值”。
- 做法：不信任 burn 返回值，按 **Router 实际余额** `IERC20(token).balanceOf(address(this))` 转给用户；amountTokenMin 校验仍在 removeLiquidity 内部（基于 Pair 计算），实际到手的 token 可能更少。

---

## 兑换（Swap）

### _swap（多跳执行器，标准 token）

- **输入**：amounts（由 getAmountsOut/In 预先算好）、path（如 [USDC, WETH, DAI]）、_to（最终收款地址）。
- 对每一跳 (input → output)：
  1. 取 amountOut = amounts[i+1]。
  2. sortTokens 得到 token0，组装 (amount0Out, amount1Out)。
  3. to：若非最后一跳则 to = 下一跳 Pair 地址；否则 to = _to。
  4. 调 `Pair.swap(amount0Out, amount1Out, to, new bytes(0))`（data 空，不触发 flash swap）。

**前提**：调用 _swap 前，第一跳的输入 token 已转入第一跳 Pair。

### swapExactTokensForTokens（固定输入，最小输出）

1. `getAmountsOut(factory, amountIn, path)` 得到 amounts（含 0.3% 费）。
2. 校验 `amounts[last] >= amountOutMin`。
3. 把 path[0] 的 amountIn 转入第一跳 Pair。
4. `_swap(amounts, path, to)`。

### swapTokensForExactTokens（固定输出，最大输入）

1. `getAmountsIn(factory, amountOut, path)` 反推 amounts[0]。
2. 校验 `amounts[0] <= amountInMax`。
3. 转 amounts[0] 到第一跳 Pair，再 _swap。

### swapExactETHForTokens / swapTokensForExactETH / swapExactTokensForETH / swapETHForExactTokens

- **ETH 相关**：path[0]=WETH 或 path[last]=WETH；Router 做 deposit/withdraw，把 WETH 当 ERC20 参与 path；输出为 ETH 时先打到 Router 再 withdraw 再转 ETH 给用户。
- **swapETHForExactTokens**：getAmountsIn 算需要多少 WETH，deposit 后转第一跳 Pair，多余 ETH 退回。

### _swapSupportingFeeOnTransferTokens（扣税币多跳）

- 标准 _swap 假设“转入 Pair 的量 = amounts[i]”，扣税币会导致 Pair 实际收到更少。
- 做法：**不用 amounts**；每一跳用  
  `amountInput = IERC20(input).balanceOf(pair) - reserveInput`  
  得到真实输入，再用 `getAmountOut(amountInput, reserveInput, reserveOutput)` 算本跳输出；与 Pair.swap“只信余额”一致。

### swapExactTokensForTokensSupportingFeeOnTransferTokens 等

- 不返回 amounts；用 **最终代币余额差** 校验：`balanceAfter - balanceBefore >= amountOutMin`。
- 输出为 ETH 时，用 Router 收到的 WETH 余额做 amountOut 校验，再 withdraw 转 ETH。

---

## Router 内暴露的 Library 函数

| 函数 | 说明 |
|------|------|
| `quote(amountA, reserveA, reserveB)` | amountB = amountA * reserveB / reserveA（加流动性比例，无手续费） |
| `getAmountOut(amountIn, reserveIn, reserveOut)` | 单跳输出，含 0.3% 费：`(amountIn*997*reserveOut)/(reserveIn*1000+amountIn*997)` |
| `getAmountIn(amountOut, reserveIn, reserveOut)` | 单跳反推输入（含费） |
| `getAmountsOut(amountIn, path)` | 多跳输出数组 |
| `getAmountsIn(amountOut, path)` | 多跳反推输入数组 |

---

# UniswapV2Library

Periphery 的“数学 + 地址推导”库；Router 的 add/remove/swap 都依赖它。Pair 不依赖此库；Factory 创建 Pair，**pairFor** 让 Router 无需查 `Factory.getPair` 也能定位 Pair。

## sortTokens(tokenA, tokenB)

- 返回 (token0, token1)，且 token0 < token1。
- 保证 pairFor 的 salt 一致（A/B 与 B/A 得到同一 Pair）；getReserves 能按 tokenA/tokenB 对齐；_swap 中可判断 input==token0 以构造 (amount0Out, amount1Out)。
- 校验 tokenA != tokenB、token0 != address(0)。

## pairFor(factory, tokenA, tokenB)

- **CREATE2 地址**：  
  `pair = address(keccak256(0xff ++ factory ++ salt ++ init_code_hash))[12:]`  
  其中 salt = keccak256(token0, token1)，init_code_hash = keccak256(Pair 创建字节码)。
- 不做任何外部调用，节省 gas；若改了 Pair 源码或编译选项，需重新计算并替换 init_code_hash。

## getReserves(factory, tokenA, tokenB)

- 通过 pairFor 取 Pair，调 `getReserves()` 得到 (reserve0, reserve1)。
- 按 tokenA/tokenB 顺序对齐后返回 (reserveA, reserveB)。

## quote(amountA, reserveA, reserveB)

- 比例换算：amountB = amountA * reserveB / reserveA。
- 用于 _addLiquidity 的“按现价注入”；**不包含** 0.3% 手续费。

## getAmountOut(amountIn, reserveIn, reserveOut)

- 含 0.3% 费：amountInWithFee = amountIn * 997，  
  `amountOut = (amountInWithFee * reserveOut) / (reserveIn*1000 + amountInWithFee)`。
- Router 用其做报价与滑点；Pair.swap 链上做 K 校验。

## getAmountIn(amountOut, reserveIn, reserveOut)

- getAmountOut 的反推：  
  `amountIn = (reserveIn * amountOut * 1000) / ((reserveOut - amountOut) * 997) + 1`。  
  +1 补偿整数除法向下取整。

## getAmountsOut(factory, amountIn, path)

- 逐跳 getReserves + getAmountOut，返回 amounts[]，amounts[0]=amountIn。
- 用于“固定输入”类 swap 的滑点校验（amounts[last] >= amountOutMin）。

## getAmountsIn(factory, amountOut, path)

- 从 path 末尾往前逐跳 getAmountIn，返回 amounts[]，amounts[last]=amountOut。
- 用于“固定输出”类 swap 的输入上限（amounts[0] <= amountInMax）。  
  标准 token 假设；扣税币用 Router 的 SupportingFeeOnTransferTokens 系列。

---

# UniswapV2LiquidityMathLibrary

用于 **LP 价值评估** 和 **按真实价格校正后的估值**，不做 swap/add/remove（由 Router/Pair 负责）。依赖 UniswapV2Library（pairFor、getReserves、getAmountOut）、IUniswapV2Pair（totalSupply、kLast）、IUniswapV2Factory（feeTo）、Babylonian.sqrt、FullMath.mulDiv。

## computeProfitMaximizingTrade(truePriceTokenA, truePriceTokenB, reserveA, reserveB)

- 给定外部真实价格比与池子储备，计算**利润最大化套利**的方向与输入量。
- 返回 (aToB, amountIn)：A→B 还是 B→A，以及 amountIn；amountIn=0 表示无需/无法套利。
- 用池内价格与真实价格比较定方向；用考虑 0.3% 费的 AMM 等式解析求 amountIn（Babylonian.sqrt + FullMath.mulDiv）。

## getReservesAfterArbitrage(factory, tokenA, tokenB, truePriceTokenA, truePriceTokenB)

- 先 getReserves，再 computeProfitMaximizingTrade 得到方向与 amountIn。
- 用 getAmountOut 模拟该笔 swap 对储备的影响，返回**套利后的** (reserveA, reserveB)（用于抗操纵估值）。

## computeLiquidityValue(reservesA, reservesB, totalSupply, liquidityAmount, feeOn, kLast)

- 给定池子参数，计算某数量 LP 对应的底层 token 数量。
- 份额：tokenAAmount = reservesA * liquidityAmount / totalSupply，tokenB 同理。
- 若 feeOn 且 kLast>0 且 sqrt(k)>sqrt(kLast)，先按 Pair._mintFee 的公式把“协议费 LP”加到 totalSupply 上再算份额（反映稀释）。

## getLiquidityValue(factory, tokenA, tokenB, liquidityAmount)

- 从链上读 Pair 的 reserves、totalSupply、kLast，factory.feeTo 得 feeOn，再调 computeLiquidityValue。
- 注意：直接用当前 reserves 易被 sandwich/闪电贷操纵；更稳健用 getLiquidityValueAfterArbitrageToPrice。

## getLiquidityValueAfterArbitrageToPrice(factory, tokenA, tokenB, truePriceTokenA, truePriceTokenB, liquidityAmount)

- 用真实价格先 getReservesAfterArbitrage 得到“套利后储备”，再 computeLiquidityValue。
- 抗操纵：真实价格 + 模拟套利后的 reserves，估值更稳。

---

# UniswapV2Migrator

**V1 → V2 流动性迁移器**：一键把 Uniswap V1 的 LP 迁移到 V2。V1 是 Token/ETH 池，V2 支持任意 Token/Token、更优路由与标准 LP。Migrator 让用户不必手动拆池再加池。

## 依赖

- **IUniswapV1Factory**：查 V1 exchange。
- **IUniswapV1Exchange**：执行 removeLiquidity。
- **IUniswapV2Router01**：在 V2 执行 addLiquidityETH。
- **TransferHelper**：安全 approve/transfer。

## 构造函数与 receive

- 构造：`_factoryV1`（V1 factory）、`_router`（V2 router）。
- **receive()**：允许接收 ETH；V1 removeLiquidity 会把 ETH 打到调用者，Migrator 需接收后再用于 V2 addLiquidity。

## migrate(token, amountTokenMin, amountETHMin, to, deadline)

1. 用 factoryV1.getExchange(token) 取 V1 exchange。
2. 用户 V1 LP 数量，并 transferFrom 到本合约。
3. 调用 V1 `removeLiquidity`，得到 ETH + Token。
4. TransferHelper.safeApprove(token, router, amountTokenV1)。
5. 调用 V2 `router.addLiquidityETH{value: amountETHV1}(...)`，新 LP mint 给 to。
6. 若 token 有剩余：approve 归零后把多余 token 转回 msg.sender；若 ETH 有剩余：把多余 ETH 转回 msg.sender。

这是一次性迁移工具，不是长期基础设施。
