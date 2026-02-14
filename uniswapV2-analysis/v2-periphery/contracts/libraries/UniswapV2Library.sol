pragma solidity >=0.5.0;

/**
 * UniswapV2Library（Periphery 的“数学大脑 + 地址推导器”）
 *
 * 这个库在 Uniswap V2 Periphery 里地位非常核心：
 *
 * 1) 负责“纯计算/少外部依赖”的工具函数：
 *    - sortTokens：统一 token 顺序（匹配 Pair.token0/token1）
 *    - quote：按储备比例换算（用于加流动性）
 *    - getAmountOut / getAmountIn：带 0.3% 手续费的 swap 数学公式（用于报价与滑点）
 *    - getAmountsOut / getAmountsIn：多跳路径的链式计算
 *
 * 2) 负责“Pair 地址推导（CREATE2）”：
 *    - pairFor：不做链上查询，直接用 CREATE2 公式推导 Pair 地址
 *
 * 3) 负责“读取 Pair 储备”：
 *    - getReserves：通过 pairFor + pair.getReserves 获取并按 tokenA/tokenB 顺序返回
 *
 * 与其他合约的关系（非常重要）：
 * - Router02 几乎所有 add/remove/swap 都依赖这个库
 *   - _addLiquidity 依赖：getReserves + quote
 *   - swapExactTokensForTokens 依赖：getAmountsOut
 *   - swapTokensForExactTokens 依赖：getAmountsIn
 *   - _swap 内部依赖：sortTokens + pairFor（计算每跳 Pair 和 token0/token1）
 * - Pair（core）不依赖这个库；Pair 只做引擎验证与状态更新
 * - Factory（core）创建 Pair；而 pairFor 让 Router “无需查询 Factory.getPair”也能定位 Pair
 */

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import "./SafeMath.sol";

library UniswapV2Library {
    using SafeMath for uint;

    /**
     * @notice sortTokens：对两个 token 地址排序，返回 (token0, token1)
     *
     * 原理：
     * - Uniswap V2 的 Pair 合约内部固定存储 token0/token1，且要求 token0 < token1
     * - 无论外部传入顺序 (A,B) 还是 (B,A)，都应映射到同一个 token0/token1
     *
     * 用途：
     * - 保证 pairFor 的 salt 一致（避免 A/B 与 B/A 推导出两个不同 Pair 地址）
     * - 保证 getReserves 返回值能正确对应 tokenA/tokenB
     * - Router._swap 中判断 input==token0 以构造 (amount0Out, amount1Out)
     *
     * 技术细节：
     * - 用地址大小比较实现排序
     * - 防止同地址、零地址
     */
    function sortTokens(address tokenA, address tokenB)
        internal
        pure
        returns (address token0, address token1)
    {
        require(tokenA != tokenB, 'UniswapV2Library: IDENTICAL_ADDRESSES');
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2Library: ZERO_ADDRESS');
    }

    /**
     * @notice pairFor：在不做任何外部调用的情况下，计算 tokenA/tokenB 对应 Pair 的 CREATE2 地址
     *
     * 原理（CREATE2 地址公式）：
     * pair = address( keccak256(
     *   0xff ++ factory ++ salt ++ init_code_hash
     * ) )[12:]   // 取后20字节作为地址
     *
     * 其中：
     * - factory：Factory 合约地址（部署 Pair 的合约）
     * - salt：keccak256(token0, token1)（token 排序后）
     * - init_code_hash：Pair 创建字节码的 keccak256 哈希（固定常量，和 Pair 代码版本强绑定）
     *
     * 用途：
     * - Router 不必调用 Factory.getPair 查询链上存储（节省 gas）
     * - 多跳 swap 中快速定位每一跳的 Pair 地址
     *
     * 技术细节（为什么这里直接写死 init_code_hash）：
     * - Uniswap 官方 Router 与 Core 是一套固定版本配套发布
     * - Pair 的 creationCode 也是固定的，所以 init_code_hash 可写死为常量
     * - 如果你换了 Pair 源码（哪怕只改一点），init_code_hash 会变化，pairFor 会算错地址
     *
     * ⚠️ 注意：
     * - 你这里用的 hex'96e8...' 是 Uniswap V2 官方 Pair init code hash
     * - 若你本地改过 Pair（比如加了日志/改了编译器优化），必须重新计算并替换这个 hash
     */
    function pairFor(address factory, address tokenA, address tokenB)
        internal
        pure
        returns (address pair)
    {
        (address token0, address token1) = sortTokens(tokenA, tokenB);

        // 这里的 address(uint(keccak256(...))) 在某些版本里会写成：
        // address(uint160(uint(keccak256(...))))
        // 本质都是：取 keccak256 的低 160 位作为地址
        pair = address(uint(keccak256(abi.encodePacked(
                hex'ff',
                factory,
                keccak256(abi.encodePacked(token0, token1)), // salt
                //官方版本的init_code_hash:hex'96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f'
                hex'e4bb86aacf000f26feb63fc943244ca2be161301fde89f87c3e096f6547d9282' // 我的UniswapV2的init_code_hash，直接cast keccak $(forge inspect UniswapV2Pair bytecode)即可
            ))));
    }

    /**
     * @notice getReserves：读取并“对齐顺序”后的储备量 (reserveA, reserveB)
     *
     * 原理：
     * - Pair.getReserves() 返回的是 (reserve0, reserve1)，对应 Pair.token0/token1
     * - 但调用者传入的是 tokenA/tokenB，顺序可能不是 token0/token1
     * - 所以需要：
     *   1) sortTokens(tokenA, tokenB) 得到 token0
     *   2) 调 pairFor 获取 Pair 地址
     *   3) 从 Pair 读取 reserve0/reserve1
     *   4) 如果 tokenA == token0，则 reserveA=reserve0；否则 reserveA=reserve1（对齐输出）
     *
     * 用途：
     * - Router._addLiquidity：需要 reserves 来用 quote 算最优投入比例
     * - getAmountsOut / getAmountsIn：逐跳需要 reserves 来用 getAmountOut/In 计算
     *
     * 与 core 的关系：
     * - 这里是库里为数不多的“外部调用”（call Pair.getReserves）
     * - Pair 的 reserve 是核心状态，Router/Library 只读取，不修改
     */
    function getReserves(address factory, address tokenA, address tokenB)
        internal
        view
        returns (uint reserveA, uint reserveB)
    {
        (address token0,) = sortTokens(tokenA, tokenB);

        // 通过 pairFor 定位 Pair，然后读取 (reserve0, reserve1)
        (uint reserve0, uint reserve1,) =
            IUniswapV2Pair(pairFor(factory, tokenA, tokenB)).getReserves();

        // 对齐到 tokenA/tokenB 的顺序
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    /**
     * @notice quote：给定 amountA 和储备对 (reserveA, reserveB)，返回等价的 amountB
     *
     * 原理（保持池子价格不变的比例换算）：
     * price = reserveB / reserveA
     * => amountB = amountA * reserveB / reserveA
     *
     * 用途：
     * - Router._addLiquidity 用它来计算“按现有价格注入”的另一侧最优数量
     *
     * 重要区别：
     * - quote 不包含交易手续费（0.3%）！
     *   因为它用于“加流动性配比”，不是 swap 报价
     */
    function quote(uint amountA, uint reserveA, uint reserveB)
        internal
        pure
        returns (uint amountB)
    {
        require(amountA > 0, 'UniswapV2Library: INSUFFICIENT_AMOUNT');
        require(reserveA > 0 && reserveB > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        amountB = amountA.mul(reserveB) / reserveA;
    }

    /**
     * @notice getAmountOut：给定输入 amountIn 和储备 (reserveIn, reserveOut)，计算最大输出 amountOut（含 0.3% 手续费）
     *
     * 原理（Constant Product AMM + 手续费）：
     * - Uniswap V2 swap 收取 0.3% 手续费：只有 99.7% 的输入计入“有效输入”
     * - 有效输入：amountInWithFee = amountIn * 997
     * - 为了保持 k = x*y，推导出：
     *
     * amountOut = (amountInWithFee * reserveOut) / (reserveIn*1000 + amountInWithFee)
     *
     * 用途：
     * - Router.swapExactTokensForTokens 先用 getAmountsOut 计算整条路径输出
     * - SupportingFeeOnTransferTokens 版本里也会用它（但 amountIn 由余额差推导）
     *
     * 与 Pair.swap 的关系：
     * - Pair.swap 会在链上做“K校验”（用 balanceAdjusted 形式）
     * - Library 这里是“前置报价”：预测输出，提供滑点控制依据
     */
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut)
        internal
        pure
        returns (uint amountOut)
    {
        require(amountIn > 0, 'UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');

        uint amountInWithFee = amountIn.mul(997);
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = reserveIn.mul(1000).add(amountInWithFee);

        // amountOut = ( amountIn * 997 * reserveOut ) / ( reserveIn * 1000 + amountIn * 997 )
        amountOut = numerator / denominator;
    }

    /**
     * @notice getAmountIn：给定期望输出 amountOut 和储备 (reserveIn, reserveOut)，反推所需输入 amountIn（含 0.3% 手续费）
     *
     * 原理：
     * - getAmountOut 的反函数（反推输入）
     * - 推导结果（官方实现）：
     *
     * amountIn = floor( reserveIn * amountOut * 1000 / ((reserveOut - amountOut) * 997) ) + 1
     *
     * 为什么要 +1？
     * - Solidity 整数除法向下取整，+1 保证“输入足够”达到目标输出
     *
     * 用途：
     * - Router.swapTokensForExactTokens / swapTokensForExactETH / swapETHForExactTokens
     *   这些“固定输出、限制最大输入”的函数会先用 getAmountsIn 计算起点输入
     */
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut)
        internal
        pure
        returns (uint amountIn)
    {
        require(amountOut > 0, 'UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');

        uint numerator = reserveIn.mul(amountOut).mul(1000);
        uint denominator = reserveOut.sub(amountOut).mul(997);

        // amountIn = ( reserveIn * amountOut * 1000 ) / ( (reserveOut - amountOut) * 997 ) + 1
        amountIn = (numerator / denominator).add(1);
    }

    /**
     * @notice getAmountsOut：对多跳路径执行链式 getAmountOut 计算
     *
     * 输入：
     * - amountIn：起点输入数量
     * - path：交易路径，例如 [USDC, WETH, DAI]
     *
     * 输出：
     * - amounts：长度等于 path.length
     *   amounts[0] = amountIn
     *   amounts[i+1] = 第 i 跳 swap 后的输出
     *
     * 原理：
     * - 每一跳都需要读取该交易对 reserves（getReserves）
     * - 然后用 getAmountOut 计算下一跳输出
     *
     * 用途：
     * - Router.swapExactTokensForTokens 等“固定输入”函数
     *   用 amounts[last] 与 amountOutMin 比较做滑点保护
     *
     * 与 Router._swap 的关系：
     * - Router 先用 getAmountsOut 算好每跳 amountOut
     * - 然后 _swap 按这些 amountOut 去调用每一跳 Pair.swap
     */
    function getAmountsOut(address factory, uint amountIn, address[] memory path)
        internal
        view
        returns (uint[] memory amounts)
    {
        require(path.length >= 2, 'UniswapV2Library: INVALID_PATH');

        amounts = new uint[](path.length);
        amounts[0] = amountIn;

        for (uint i; i < path.length - 1; i++) {
            (uint reserveIn, uint reserveOut) = getReserves(factory, path[i], path[i + 1]);
            amounts[i + 1] = getAmountOut(amounts[i], reserveIn, reserveOut);
        }
    }

    /**
     * @notice getAmountsIn：对多跳路径执行链式 getAmountIn 反推计算
     *
     * 输入：
     * - amountOut：终点期望输出数量
     * - path：交易路径，例如 [USDC, WETH, DAI]
     *
     * 输出：
     * - amounts：长度等于 path.length
     *   amounts[last] = amountOut
     *   amounts[i-1] = 为得到 amounts[i] 所需的输入
     *
     * 原理：
     * - 从后往前反推，每一跳都读取 reserves，然后用 getAmountIn 反推输入
     *
     * 用途：
     * - Router.swapTokensForExactTokens 等“固定输出”函数
     *   用 amounts[0] 与 amountInMax 比较做输入上限保护
     *
     * 注意：
     * - 这套计算是“标准 token”假设（转账不扣税）
     * - 若是 fee-on-transfer token，Router02 会用 SupportingFeeOnTransferTokens 版本
     *   通过“余额差”推导真实输入，避免预估 amounts 失真
     */
    function getAmountsIn(address factory, uint amountOut, address[] memory path)
        internal
        view
        returns (uint[] memory amounts)
    {
        require(path.length >= 2, 'UniswapV2Library: INVALID_PATH');

        amounts = new uint[](path.length);
        amounts[amounts.length - 1] = amountOut;

        for (uint i = path.length - 1; i > 0; i--) {
            (uint reserveIn, uint reserveOut) = getReserves(factory, path[i - 1], path[i]);
            amounts[i - 1] = getAmountIn(amounts[i], reserveIn, reserveOut);
        }
    }
}
