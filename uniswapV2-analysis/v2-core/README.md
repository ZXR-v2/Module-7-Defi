# UniswapV2 Core 合约说明

基于 `UniswapV2Factory.sol` 与 `UniswapV2Pair.sol` 内注释整理。

---

# UniswapV2Factory

在构造函数中传入一个设置 `feeTo` 的权限者地址（`feeToSetter`），主要用于创建两种 token 的交易对，并为其部署一个 `UniswapV2Pair` 合约用于管理该交易对；Factory 还负责协议手续费的配置。

## 状态变量与事件

| 名称 | 说明 |
|------|------|
| `feeTo` | 协议手续费接收地址。若 != 0，则 Pair 在 mint/burn 时会通过 `_mintFee()` 给该地址铸造一小部分 LP（协议抽成） |
| `feeToSetter` | 有权限修改 `feeTo` 的地址，相当于「协议治理者/管理员」 |
| `getPair` | 双层 mapping：`getPair[token0][token1] => pair`，实现 O(1) 查询 |
| `allPairs` | 所有已创建的 Pair 地址数组，用于链上枚举或前端查询 |
| `PairCreated` | 创建 Pair 时触发的事件，前端和 indexer（如 TheGraph）会监听 |

## 合约方法

- `feeTo()`：返回收取手续费的地址
- `feeToSetter()`：返回设置手续费收取地址的权限地址
- `getPair(address tokenA, address tokenB)`：获取两个 token 的交易对地址
- `allPairs(uint)`：返回指定下标的交易对地址
- `allPairsLength()`：返回所有交易对的数量
- `createPair(address tokenA, address tokenB)`：创建两个 token 的交易对
- `setFeeTo(address)`：更改收取手续费地址（仅 `feeToSetter` 可调用）
- `setFeeToSetter(address)`：更改治理者地址，相当于移交控制权（仅当前 `feeToSetter` 可调用）

在 Uniswap 协议中，`feeTo` 用于指定手续费接收地址。当用户在 Uniswap 上进行交易时，一定比例的交易手续费会被收取并分配：一部分给流动性提供者，一部分可发送到 `feeTo` 地址（由协议费机制决定）。

---

## createPair(address tokenA, address tokenB) returns (address pair)

创建新交易对的核心逻辑（与合约内注释对应）：

1. **不允许相同 token**：`tokenA != tokenB`
2. **排序 token 地址**：保证 `(tokenA,tokenB)` 与 `(tokenB,tokenA)` 创建的是同一个 Pair，取 `token0 = min(tokenA,tokenB)`，`token1 = max(...)`
3. **禁止 0 地址**：`token0 != address(0)`
4. **防止重复创建**：`getPair[token0][token1] == address(0)`
5. **获取 Pair 合约字节码**：`type(UniswapV2Pair).creationCode`
6. **CREATE2 的 salt**：`keccak256(abi.encodePacked(token0, token1))`，使 Pair 地址可预测
7. **使用 CREATE2 部署 Pair**：  
   - 公式：`Pair 地址 = keccak256(0xff + factory + salt + bytecode)`  
   - `bytecode` 前 32 字节是长度，后面才是代码；`add(bytecode, 32)` 跳过长度指向代码起始，`mload(bytecode)` 读取长度

```solidity
bytes32 salt = keccak256(abi.encodePacked(token0, token1));
bytes memory bytecode = type(UniswapV2Pair).creationCode;
assembly {
    // add(bytecode, 32)：跳过长度字段，指向真正代码开始位置
    // mload(bytecode)：读取字节码长度
    pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
}
```

8. **初始化 Pair**：`IUniswapV2Pair(pair).initialize(token0, token1)`
9. **双向映射**：`getPair[token0][token1]` 与 `getPair[token1][token0]` 都写入，方便查询时不用再排序
10. **记录并事件**：`allPairs.push(pair)`，`emit PairCreated(...)`

> 内联汇编：在 Solidity 中嵌入汇编代码，对 EVM 有更细粒度的控制。

---

# UniswapV2Pair

构造函数中 `factory = msg.sender`（由 UniswapV2Factory 部署）。合约继承 UniswapV2ERC20，用于管理并操作交易对，托管两种 token；LP token 即 UniswapV2ERC20。

## 状态变量与常量

| 名称 | 说明 |
|------|------|
| `MINIMUM_LIQUIDITY` | 最小流动性锁定量（1000）。首次创建池子时铸造给 `address(0)` 永久锁死，使 `totalSupply` 永远 > 0，避免池子被完全清空后的边界问题（取整/初始化反复等） |
| `SELECTOR` | `transfer(address,uint256)` 的 selector，用于 low-level call 兼容「非标准 ERC20」：有的 token 的 `transfer` 不返回 bool；要求 `success == true` 且 `data` 为空或 decode 为 true |
| `factory` | 工厂合约地址；Pair 在 `_mintFee()` 中通过 `factory.feeTo()` 判断是否开启协议费 |
| `token0`, `token1` | 交易对中两种 token（已按地址排序） |
| `reserve0`, `reserve1`, `blockTimestampLast` | 储备与时间戳快照，不是实时余额；用 uint112 打包存储省 gas |
| `price0CumulativeLast`, `price1CumulativeLast` | 价格累计，供 TWAP 预言机使用：每次 update 时把「当前价格 × 时间间隔」累加，外部用 `(cumNow - cumThen) / (tNow - tThen)` 得时间加权均价 |
| `kLast` | 最近一次「流动性事件」（mint/burn）后的 `reserve0*reserve1`，用于 `_mintFee()` 计算协议费 |
| `unlocked` | 简易重入锁；mint/burn/swap/skim/sync 均加 `lock`，防止在 swap 回调（flash swap）中重入破坏 reserve 与 balance 的对应关系 |

## 对外主要方法（LP token = UniswapV2ERC20）

- `permit(...)`：校验签名有效性，通过则执行授权
- `mint(address to)`：加流动性，铸造 LP token（带 `lock`）
- `burn(address to)`：销毁 LP token，按份额返还两种 token（带 `lock`）
- `swap(uint amount0Out, uint amount1Out, address to, bytes calldata data)`：在池中兑换，并支持 flash swap 回调
- `skim(address to)`：把「余额 − 储备」的差额转给 `to`，用于有人直接转 token 进 Pair 后的纠偏
- `sync()`：强制把 reserves 更新为当前真实余额
- `initialize(address, address)`：仅由 Factory 调用一次，设置 `token0`/`token1`（CREATE2 常用「先部署空壳再初始化」模式）

---

## permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s)

```solidity
address recoveredAddress = ecrecover(digest, v, r, s);
require(recoveredAddress != address(0) && recoveredAddress == owner, 'UniswapV2: INVALID_SIGNATURE');
_approve(owner, spender, value);
```

用户签名一笔授权，该方法校验签名有效性；通过则对 `owner -> spender` 授权 `value`。

---

## mint(address to) lock returns (uint liquidity)

**重要**：此为「低层」接口，假设调用者（通常为 Router）已做安全检查并把 token 转入 Pair。Pair 不接收 `amount0`/`amount1` 参数，而是用：

- `amount0 = balance0 - reserve0`
- `amount1 = balance1 - reserve1`

推导本次实际注入量（兼容 fee-on-transfer 等 token）。

流程概要：

1. 取当前 reserves 与真实余额
2. 本次新增量 = 真实余额 − 旧快照
3. 调用 `_mintFee`
4. 若 `totalSupply == 0`：首次初始化，`liquidity = sqrt(amount0*amount1) - MINIMUM_LIQUIDITY`，并将 `MINIMUM_LIQUIDITY` 铸给 `address(0)` 永久锁定
5. 否则：按比例铸造，取 `min(amount0*totalSupply/reserve0, amount1*totalSupply/reserve1)` 防止单边投入改变价格
6. `_mint(to, liquidity)`，`_update(...)`，若协议费开启则更新 `kLast`

```solidity
(uint112 _reserve0, uint112 _reserve1, ) = getReserves();
uint balance0 = IERC20(token0).balanceOf(address(this));
uint balance1 = IERC20(token1).balanceOf(address(this));
uint amount0 = balance0.sub(_reserve0);
uint amount1 = balance1.sub(_reserve1);
// _mintFee ...
liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
_mint(to, liquidity);
_update(balance0, balance1, _reserve0, _reserve1);
```

---

## burn(address to) lock returns (uint amount0, uint amount1)

通常流程：用户（或 Router）先把 LP token 转给 Pair，再调用 `burn(to)`。

1. 要销毁的 LP 数量 = `balanceOf[address(this)]`（因 LP 已转入本合约）
2. 调用 `_mintFee`
3. 按份额分配：`amount0 = liquidity * balance0 / totalSupply`，`amount1 = liquidity * balance1 / totalSupply`（用真实余额保证按真实资产分配）
4. `_burn`、转出两种 token、重新读 balance 后 `_update`，若协议费开启则更新 `kLast`

```solidity
uint liquidity = balanceOf[address(this)];
// _mintFee ...
amount0 = liquidity.mul(balance0) / _totalSupply;
amount1 = liquidity.mul(balance1) / _totalSupply;
_safeTransfer(_token0, to, amount0);
_safeTransfer(_token1, to, amount1);
// 重新读 balance 再 _update
```

---

## swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) lock

交易引擎（token0 ↔ token1），并支持 **flash swap** 回调。

**核心执行模型**：

1. 校验 `amount0Out`/`amount1Out` 至少一个 > 0，且均小于对应 reserve
2. **乐观转出**：先把请求的 token 转给 `to`
3. 若 `data.length > 0`，调用 `IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data)`（闪电贷/套利等）
4. 回调结束后读取最终 `balance0`/`balance1`
5. 用 balance 与「reserve − out」反推 **amountIn**（不信任外部传参）
6. 做含 **0.3% 手续费** 的不变量校验（K check）：  
   `balance0Adjusted * balance1Adjusted >= reserve0 * reserve1 * 1000^2`，其中 adjusted 为对输入扣 0.3% 后的余额
7. `_update` 更新 reserves

Pair 本身一般不计算「你能拿多少 out」，只做校验；具体 out 通常由 Router/Library 计算后传入。  
使用方式：① 在 Router 中用户先把要换出的 token 转入 Pair，再传入要取的 token 数量和 data；② 或直接调用 swap 在回调中套利，只要回调结束后满足 K 与手续费条件即可。

---

## 合约内部方法

### _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private

把 reserves 快照同步到真实余额，并在「每区块首次更新」时累积 TWAP 价格。

- `balance0`/`balance1`：`token.balanceOf(pair)`，真实余额  
- `_reserve0`/`_reserve1`：旧快照  
- 做 uint112 上限检查，防止溢出  
- 若 `timeElapsed > 0` 且 reserves 非 0：  
  `price0CumulativeLast += (reserve1/reserve0) * timeElapsed`（用 UQ112x112 定点数），同理 `price1CumulativeLast`  
- 写回 `reserve0 = balance0`，`reserve1 = balance1`，`blockTimestampLast`，并 `emit Sync`

```solidity
price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
reserve0 = uint112(balance0);
reserve1 = uint112(balance1);
```

---

### _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn)

协议费机制（可开关）：

- **Swap 手续费 0.3%** 始终存在并留在池子里（归 LP）
- 若 `Factory.feeTo != 0`，则在 mint/burn（流动性事件）时，把「LP 收益的一部分」铸成 LP 给 `feeTo`，效果约等于协议抽走 LP 收益的 1/6（约 0.05%）
- 不是每笔 swap 都结算协议费，而是在流动性事件时结算，省 gas

**为什么用 sqrt(k)**：k = x*y，池子规模线性增长时 k 二次增长；LP 的「价值尺度」更贴近 sqrt(k)，用 sqrt(k) 衡量真实规模增长。

逻辑概要：

1. `feeOn = (factory.feeTo() != address(0))`
2. 若 `feeOn` 且 `kLast != 0`：计算 `rootK = sqrt(reserve0*reserve1)`，`rootKLast = sqrt(kLast)`
3. 若 `rootK > rootKLast`：  
   `liquidity = totalSupply * (rootK - rootKLast) / (rootK*5 + rootKLast)`，若 `liquidity > 0` 则 `_mint(feeTo, liquidity)`
4. 若协议费关闭且 `kLast != 0`，将 `kLast` 置 0，避免下次开启时用旧数据

```solidity
uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
uint rootKLast = Math.sqrt(_kLast);
uint numerator = totalSupply.mul(rootK.sub(rootKLast));
uint denominator = rootK.mul(5).add(rootKLast);
uint liquidity = numerator / denominator;
if (liquidity > 0) _mint(feeTo, liquidity);
```
