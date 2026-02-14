pragma solidity >=0.5.0;

/**
 * UniswapV2OracleLibrary（V2 TWAP 预言机辅助库）
 *
 * 这个库用于：
 * 👉 读取/构造 Uniswap V2 的“累计价格”（cumulative price）
 * 👉 从而支持 TWAP（Time-Weighted Average Price，时间加权平均价）预言机
 *
 * ⚠️ 重要定位：
 * - 它不是预言机本身
 * - 而是“构建 TWAP 预言机时的辅助工具”
 *
 * 典型 TWAP 使用流程：
 * 1️⃣ 在时间点 T0 记录：
 *     price0CumulativeLast、price1CumulativeLast、timestamp
 *
 * 2️⃣ 过一段时间 Δt 后，在 T1 再读取一次
 *
 * 3️⃣ TWAP = (累计价格差) / Δt
 *
 * 这样得到的是：
 * 👉 一段时间内的平均价格
 * 👉 抗闪电贷/短时操纵
 *
 * 与 v2-core 的关系：
 * - Pair 在每次 _update() 时都会维护：
 *     price0CumulativeLast
 *     price1CumulativeLast
 * - 它们本质是：
 *     “价格 × 时间”的累加积分
 *
 * 本库的关键设计：
 * 👉 允许在不调用 sync() 的情况下，
 *     反事实（counterfactual）推导出“当前应有的累计价格”
 * 👉 节省 gas + 减少对 Pair 状态写入
 */

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import '@uniswap/lib/contracts/libraries/FixedPoint.sol';

// 具有与计算平均价格有关的预言机辅助方法的库
library UniswapV2OracleLibrary {
    using FixedPoint for *;

    /**
     * currentBlockTimestamp
     *
     * 返回：
     * 👉 当前区块时间戳（限制在 uint32 范围）
     *
     * 为什么要 % 2**32？
     * - Uniswap V2 Pair 内部使用 uint32 存时间戳
     * - 并“允许溢出”作为设计的一部分
     * - uint32 回绕（wrap-around）仍可正确计算时间差
     *
     * 这是经典的：
     * 👉 “模 2^32 时间戳设计”
     * 在长期运行的 AMM 中更省 gas
     */
    function currentBlockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp % 2 ** 32);
    }

    /**
     * currentCumulativePrices
     *
     * 作用：
     * 👉 获取“当前时刻”的累计价格（cumulative price）
     * 👉 即使 Pair 在本区块尚未调用 sync/_update
     *
     * 返回：
     * - price0Cumulative
     * - price1Cumulative
     * - blockTimestamp（当前时间）
     *
     * 关键思想：反事实（counterfactual）累计价格
     *
     * 正常情况下：
     * - Pair 只在 _update() 时更新 cumulative price
     * - 若本区块尚未发生 swap/mint/burn，
     *   cumulative price 还停留在旧值
     *
     * 本函数做的事：
     * 👉 用当前储备 + 经过时间
     *    模拟“如果更新了应有的累计价格”
     *
     * 这样：
     * ❌ 不需要调用 sync（省 gas）
     * ❌ 不需要写链上状态
     * ✅ 仍可构建 TWAP
     *
     * 技术细节：
     *
     * 1️⃣ 先读取：
     *     price0CumulativeLast
     *     price1CumulativeLast
     *     reserves
     *     blockTimestampLast
     *
     * 2️⃣ 若时间未变化：
     *     直接返回即可
     *
     * 3️⃣ 若时间变化：
     *     模拟：
     *
     *     priceCumulative += price * timeElapsed
     *
     *     其中：
     *     price = reserve1/reserve0（或反之）
     *
     * 4️⃣ FixedPoint.fraction：
     *     使用 UQ112x112 定点数格式
     *     保证高精度价格表示
     *
     * 关于“溢出是被允许的”：
     * - uint32 时间戳溢出可安全用于差值计算
     * - 累计价格加法溢出同样被设计为可用
     * - 因为 TWAP 只关心差值
     */
    function currentCumulativePrices(
        address pair
    )
        internal
        view
        returns (
            uint price0Cumulative,
            uint price1Cumulative,
            uint32 blockTimestamp
        )
    {
        // 当前时间（uint32 范围）
        blockTimestamp = currentBlockTimestamp();

        // 读取 Pair 已记录的累计价格
        price0Cumulative = IUniswapV2Pair(pair).price0CumulativeLast();
        price1Cumulative = IUniswapV2Pair(pair).price1CumulativeLast();

        // 读取储备和上次更新时间
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) =
            IUniswapV2Pair(pair).getReserves();

        // 若自上次更新以来经过了时间
        if (blockTimestampLast != blockTimestamp) {
            // 时间差（允许溢出）
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;

            // 反事实累计：
            // price0 = reserve1 / reserve0
            price0Cumulative +=
                uint(FixedPoint.fraction(reserve1, reserve0)._x) *
                timeElapsed;

            // price1 = reserve0 / reserve1
            price1Cumulative +=
                uint(FixedPoint.fraction(reserve0, reserve1)._x) *
                timeElapsed;
        }
    }
}
