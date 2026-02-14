pragma solidity >=0.5.0;

/**
 * UniswapV2LiquidityMathLibrary（LP 价值评估 + “按真实价格校正后的”LP 价值）
 *
 * 这个库的目标不是做 swap 或 add/remove liquidity（这些由 Router/Pair 负责），
 * 而是回答一个更“估值/风控/分析”类的问题：
 *
 * 1) 我手里这一部分 LP（liquidityAmount）在池子里到底值多少 tokenA / tokenB？
 * 2) 如果考虑协议费（feeOn）导致 totalSupply 可能被“增发协议 LP”（_mintFee 逻辑），那价值如何变化？
 * 3) 如果池子价格被操纵（例如 sandwich），能不能用“外部真实价格”先假设套利回归后再估值？
 *
 * 依赖关系（重要）：
 * - 依赖 UniswapV2Library：
 *   - pairFor/getReserves/getAmountOut（读取储备、模拟套利 swap）
 * - 依赖 v2-core：
 *   - IUniswapV2Pair：读取 totalSupply、kLast（协议费相关）
 *   - IUniswapV2Factory：读取 feeTo（判断 feeOn）
 * - 依赖 @uniswap/lib：
 *   - Babylonian.sqrt：平方根（用于 sqrt(k)）
 *   - FullMath.mulDiv：高精度乘除（避免中间溢出/精度损失）
 *
 * 常见使用场景：
 * - 前端/分析器：展示 LP 的“底层资产份额”（比如你 LP 对应多少 USDC 和 WETH）
 * - 风控/估值：在外部价格（oracle/观察到的真实价格）下估算 LP 实际价值
 * - 研究/套利分析：推导“套利把价格推回真实价格”的最优输入量（利润最大化交易）
 */

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import '@uniswap/lib/contracts/libraries/Babylonian.sol';
import '@uniswap/lib/contracts/libraries/FullMath.sol';

import './SafeMath.sol';
import './UniswapV2Library.sol';

// 库包含一些用于处理一对流动性份额的数学，例如计算它们的确切值（就底层代币而言）
library UniswapV2LiquidityMathLibrary {
    using SafeMath for uint256;

    /**
     * computeProfitMaximizingTrade：计算“利润最大化套利交易”的方向与输入量
     *
     * 目标：
     * - 给定外部真实价格 truePriceTokenA/truePriceTokenB（A 相对 B 的价值比）
     * - 给定池子当前储备 reserveA/reserveB
     * - 计算：为了把池子价格推向真实价格，套利者“最赚钱”的那一笔交易应该：
     *   - 方向是 A -> B 还是 B -> A
     *   - 输入 amountIn 应该是多少
     *
     * 背景知识（和 Pair.swap 的关系）：
     * - Uniswap V2 的“池内价格”近似为 reserveB/reserveA（忽略手续费的直觉）
     * - 若池内价格与外部真实价格偏离，就存在套利空间
     * - 套利者会交易直到边际利润趋于 0；“利润最大化”的输入量可解析求解
     *
     * 参数含义：
     * - truePriceTokenA / truePriceTokenB：外部真实价格比（可来自预言机或观察市场）
     *   直觉：A 的真实价值 / B 的真实价值
     * - reserveA / reserveB：池子储备（注意是按 tokenA/tokenB 对齐后的储备）
     *
     * 返回：
     * - aToB：是否 A -> B
     * - amountIn：套利输入量（若为 0 表示无需套利或无利润空间）
     *
     * 技术细节：
     * 1) aToB 的判断：
     *    FullMath.mulDiv(reserveA, truePriceTokenB, reserveB) < truePriceTokenA
     *    直觉上是在比较“池内隐含价格”与“外部真实价格”
     *
     * 2) amountIn 的推导：
     *    - invariant = reserveA * reserveB = k
     *    - 考虑 0.3% 手续费（997/1000），解出使价格到达“最优点”的输入量
     *    - Babylonian.sqrt + FullMath.mulDiv 用于精确计算 sqrt 与乘除，避免溢出
     *
     * 3) leftSide < rightSide 时返回 (false, 0)：
     *    代表在该方向下不存在正的套利输入量（或会导致无意义解）
     */
    function computeProfitMaximizingTrade(
        uint256 truePriceTokenA,
        uint256 truePriceTokenB,
        uint256 reserveA,
        uint256 reserveB
    ) internal pure returns (bool aToB, uint256 amountIn) {
        // 判断套利方向：若池内 A 相对 B “更便宜/更贵”，决定是 A->B 还是 B->A
        aToB = FullMath.mulDiv(reserveA, truePriceTokenB, reserveB) < truePriceTokenA;

        // k = reserveA * reserveB
        uint256 invariant = reserveA.mul(reserveB);

        // leftSide/rightSide 是从“考虑手续费的 AMM 等式”解析推导出来的两边，推导过程用到求导数
        // 目的是求出把价格推到利润最大化点所需的 amountIn
        uint256 leftSide = Babylonian.sqrt(
            FullMath.mulDiv(
                invariant.mul(1000),
                aToB ? truePriceTokenA : truePriceTokenB,
                (aToB ? truePriceTokenB : truePriceTokenA).mul(997)
            )
        );
        uint256 rightSide = (aToB ? reserveA.mul(1000) : reserveB.mul(1000)) / 997;

        // 若 leftSide < rightSide，则推导出的 amountIn 为负或无意义，视为不做套利
        if (leftSide < rightSide) return (false, 0);

        // 计算将价格移动到利润最大化价格必须发送的数量
        amountIn = leftSide.sub(rightSide);
    }

    /**
     * getReservesAfterArbitrage：假设发生一次“利润最大化套利”后，池子储备会变成多少
     *
     * 目标：
     * - 你要估值 LP 时，不希望用“被操纵的 reserve”（比如被 sandwich 暂时扭曲）
     * - 给定真实价格 truePriceTokenA/truePriceTokenB
     * - 先计算套利最优交易（方向 + amountIn）
     * - 再用 UniswapV2Library.getAmountOut 模拟这一笔 swap 对储备的影响
     * - 得到“套利把价格推向真实价格后”的 reserveA/reserveB（用于更稳健估值）
     *
     * 与 Router/Pair 的关系：
     * - 这里不真正执行链上 swap，只是数学模拟（pure/view）
     * - swap 的输出计算复用 UniswapV2Library.getAmountOut（与 Router 报价一致）
     *
     * 返回：
     * - reserveA/reserveB：模拟套利后的储备（按 tokenA/tokenB 对齐顺序）
     */
    function getReservesAfterArbitrage(
        address factory,
        address tokenA,
        address tokenB,
        uint256 truePriceTokenA,
        uint256 truePriceTokenB
    ) internal view returns (uint256 reserveA, uint256 reserveB) {
        // 在交换之前先获取储备（按 tokenA/tokenB 对齐）
        (reserveA, reserveB) = UniswapV2Library.getReserves(factory, tokenA, tokenB);

        require(reserveA > 0 && reserveB > 0, 'UniswapV2ArbitrageLibrary: ZERO_PAIR_RESERVES');

        // 然后计算多少交换套利到真实价格（方向 + 输入量）
        (bool aToB, uint256 amountIn) = computeProfitMaximizingTrade(
            truePriceTokenA,
            truePriceTokenB,
            reserveA,
            reserveB
        );

        // amountIn=0 表示无需套利或不可套利，直接返回原储备
        if (amountIn == 0) {
            return (reserveA, reserveB);
        }

        // 现在模拟该套利交易对储备的影响（相当于“把一笔 swap 的结果应用到 reserve 上”）
        if (aToB) {
            // A -> B：A 增加 amountIn，B 减少 amountOut
            uint amountOut = UniswapV2Library.getAmountOut(amountIn, reserveA, reserveB);
            reserveA += amountIn;
            reserveB -= amountOut;
        } else {
            // B -> A：B 增加 amountIn，A 减少 amountOut
            uint amountOut = UniswapV2Library.getAmountOut(amountIn, reserveB, reserveA);
            reserveB += amountIn;
            reserveA -= amountOut;
        }
    }

    /**
     * computeLiquidityValue：给定“池子参数”，计算某数量 LP 的底层资产价值（tokenAAmount, tokenBAmount）
     *
     * 最核心的 LP 价值公式（忽略协议费影响的直觉版本）：
     * - 你持有的 liquidityAmount / totalSupply 代表你占整个池子的份额
     * - 所以你对应的 tokenAAmount = reservesA * liquidityAmount / totalSupply
     * - tokenBAmount 同理
     *
     * 但这里多考虑了一个重要点：feeOn（协议费开启）时 totalSupply 会“被动变大”
     *
     * 与 Pair._mintFee 的关系（必须对应起来看）：
     * - Pair 在 mint/burn 时会调用 _mintFee
     * - feeOn 且 kLast>0 时，会根据 sqrt(k) 的增长给 feeTo 地址 mint 一部分 LP
     * - 这相当于对所有 LP 持有人“轻微稀释”
     *
     * 所以在估值时：
     * - 如果 feeOn && kLast>0 && sqrt(k) > sqrt(kLast)
     *   需要先把“应该被增发的 feeLiquidity”加到 totalSupply 上
     * - 再按份额计算你的底层资产数量
     *
     * 参数：
     * - reservesA/reservesB：当前（或校正后）的储备
     * - totalSupply：LP 总供应量
     * - liquidityAmount：你要估值的 LP 数量
     * - feeOn：是否开启协议费（factory.feeTo != 0）
     * - kLast：Pair.kLast（仅 feeOn 时有效）
     *
     * 返回：
     * - tokenAAmount/tokenBAmount：该 LP 份额对应的底层资产数量
     */
    function computeLiquidityValue(
        uint256 reservesA,
        uint256 reservesB,
        uint256 totalSupply,
        uint256 liquidityAmount,
        bool feeOn,
        uint kLast
    ) internal pure returns (uint256 tokenAAmount, uint256 tokenBAmount) {
        // 若开启协议费且 kLast>0，模拟 _mintFee 对 totalSupply 的影响（增发给 feeTo）
        if (feeOn && kLast > 0) {
            uint rootK = Babylonian.sqrt(reservesA.mul(reservesB));
            uint rootKLast = Babylonian.sqrt(kLast);

            // sqrt(k) 增长才会触发协议费 LP 的铸造
            if (rootK > rootKLast) {
                // 这一段公式与 Pair._mintFee 保持一致（本质：1/6 sqrt(k) 增长的铸造规则）
                uint numerator1 = totalSupply;
                uint numerator2 = rootK.sub(rootKLast);
                uint denominator = rootK.mul(5).add(rootKLast);

                // FullMath.mulDiv 做高精度乘除，避免 numerator1*numerator2 先溢出
                uint feeLiquidity = FullMath.mulDiv(numerator1, numerator2, denominator);

                // totalSupply 扩大：等价于把协议费铸造“计入稀释”
                totalSupply = totalSupply.add(feeLiquidity);
            }
        }

        // 按份额分配：你占总 LP 的比例 * 总储备
        return (
            reservesA.mul(liquidityAmount) / totalSupply,
            reservesB.mul(liquidityAmount) / totalSupply
        );
    }

    /**
     * getLiquidityValue：从链上读取 Pair 的当前参数，计算 liquidityAmount 的底层资产价值
     *
     * 流程：
     * 1) 用 UniswapV2Library.getReserves 获取 reservesA/reservesB（按 tokenA/tokenB 对齐）
     * 2) 定位 Pair（pairFor）并读取：
     *    - totalSupply（LP 总量）
     *    - kLast（协议费用到）
     * 3) 读取 factory.feeTo 判断 feeOn
     * 4) 调 computeLiquidityValue 做最终估值
     *
     * ⚠️ 风险提示（源码注释也强调了）：
     * - 这里直接用“当前 reserves”，容易被短期操纵（sandwich / 闪电贷扭曲池子价格）
     * - 所以更稳健的做法是用 getLiquidityValueAfterArbitrageToPrice（带真实价格校正）
     */
    function getLiquidityValue(
        address factory,
        address tokenA,
        address tokenB,
        uint256 liquidityAmount
    ) internal view returns (uint256 tokenAAmount, uint256 tokenBAmount) {
        // 读取当前储备
        (uint256 reservesA, uint256 reservesB) = UniswapV2Library.getReserves(factory, tokenA, tokenB);

        // 定位 Pair 并读取关键参数
        IUniswapV2Pair pair = IUniswapV2Pair(UniswapV2Library.pairFor(factory, tokenA, tokenB));

        // 协议费开关：feeTo != 0 即 feeOn
        bool feeOn = IUniswapV2Factory(factory).feeTo() != address(0);

        // 只有 feeOn 时 kLast 才有意义；否则当作 0
        uint kLast = feeOn ? pair.kLast() : 0;

        uint totalSupply = pair.totalSupply();

        return computeLiquidityValue(reservesA, reservesB, totalSupply, liquidityAmount, feeOn, kLast);
    }

    /**
     * getLiquidityValueAfterArbitrageToPrice：在“外部真实价格”下，计算 liquidityAmount 的底层资产价值（抗操纵）
     *
     * 目标：
     * - 给定 tokenA/tokenB 的真实价格比 truePriceTokenA/truePriceTokenB（可来自预言机）
     * - 先假设套利者用利润最大化交易把池子价格推回真实价格附近
     * - 用套利后的 reserves 来估值 LP
     *
     * 为什么这更抗操纵？
     * - 攻击者可以在一个区块内用闪电贷扭曲池子 reserves
     * - 直接 getLiquidityValue 会把“扭曲的 reserves”当真
     * - 但真实价格（抗操纵源） + 模拟套利后 reserves，能把估值拉回更合理水平
     *
     * 流程：
     * 1) 读取 feeOn / kLast / totalSupply
     * 2) 检查 liquidityAmount 合法（>0 且 <= totalSupply）
     * 3) 调 getReservesAfterArbitrage 计算“套利后储备”
     * 4) 调 computeLiquidityValue 输出 LP 对应底层资产数量
     */
    function getLiquidityValueAfterArbitrageToPrice(
        address factory,
        address tokenA,
        address tokenB,
        uint256 truePriceTokenA,
        uint256 truePriceTokenB,
        uint256 liquidityAmount
    ) internal view returns (uint256 tokenAAmount, uint256 tokenBAmount) {
        bool feeOn = IUniswapV2Factory(factory).feeTo() != address(0);
        IUniswapV2Pair pair = IUniswapV2Pair(UniswapV2Library.pairFor(factory, tokenA, tokenB));
        uint kLast = feeOn ? pair.kLast() : 0;
        uint totalSupply = pair.totalSupply();

        // 这也会检查 totalSupply > 0，并保证 liquidityAmount 合法
        require(
            totalSupply >= liquidityAmount && liquidityAmount > 0,
            'ComputeLiquidityValue: LIQUIDITY_AMOUNT'
        );

        // 先用真实价格模拟套利回归后的储备
        (uint reservesA, uint reservesB) = getReservesAfterArbitrage(
            factory,
            tokenA,
            tokenB,
            truePriceTokenA,
            truePriceTokenB
        );

        // 再在“更合理的储备”上估值
        return computeLiquidityValue(reservesA, reservesB, totalSupply, liquidityAmount, feeOn, kLast);
    }
}
