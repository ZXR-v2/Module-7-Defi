pragma solidity =0.6.6;

/**
 * UniswapV2Router02（Periphery 核心入口）
 *
 * 你已经学完 v2-core（Factory + Pair）后，再看 Router 会非常清晰：
 *
 * - Pair（core）只做“资金池引擎”：swap/mint/burn + K 校验 + reserve 更新（不做参数计算）
 * - Router（periphery）负责“用户体验层”：路径、滑点、转账、ETH/WETH 处理、多跳 swap
 * - Library 负责“数学/地址推导”：pairFor/getReserves/quote/getAmountOut/getAmountsOut 等
 *
 * Router 的重要特点：
 * 1) 所有用户级接口都带 deadline：防止交易被“过期执行”（防 MEV/延迟风险）
 * 2) ETH 不能直接进 Pair（Pair 只管 ERC20），所以 Router 用 WETH 做包装
 * 3) Router02 相比 Router01 增加 SupportingFeeOnTransferTokens 系列函数（兼容转账扣税币）
 */

import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol';
import '@uniswap/lib/contracts/libraries/TransferHelper.sol';

import './interfaces/IUniswapV2Router02.sol';
import './libraries/UniswapV2Library.sol';
import './libraries/SafeMath.sol';
import './interfaces/IERC20.sol';
import './interfaces/IWETH.sol';

contract UniswapV2Router02 is IUniswapV2Router02 {
    using SafeMath for uint;

    /// @notice 核心依赖：Factory 与 WETH 地址是 Router 唯二需要持久化的全局配置
    /// - factory：用于查找/创建 Pair，以及在 Library 中推导 pair 地址
    /// - WETH：用于把 ETH 包装成 ERC20，让 Pair 能处理 ETH 相关业务
    address public immutable override factory;
    address public immutable override WETH;

    /// @notice deadline 校验：防止交易在很久以后才被执行（典型滑点/MEV 防护手段之一）
    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'UniswapV2Router: EXPIRED');
        _;
    }

    constructor(address _factory, address _WETH) public {
        factory = _factory;
        WETH = _WETH;
    }

    /**
     * @notice Router 接收 ETH 的方式是“非常克制的”：
     * - 只允许来自 WETH 合约的 ETH（即 IWETH.withdraw() 时回到 Router）
     * - 避免别人直接往 Router 打 ETH 导致资产滞留或逻辑混乱
     */
    receive() external payable {
        assert(msg.sender == WETH); // only accept ETH via fallback from the WETH contract
    }

    // ============================================================
    //                       ADD LIQUIDITY
    // ============================================================

    /**
     * @dev _addLiquidity：Router 添加流动性的“核心算法”
     *
     * 输入：
     * - amountADesired/amountBDesired：用户愿意提供的最大数量
     * - amountAMin/amountBMin：用户可接受的最小数量（滑点保护）
     *
     * 输出：
     * - amountA/amountB：Router 计算出的“最优注入数量”
     *
     * 原理：
     * 1) 如果池子还不存在：先创建 Pair（Factory.createPair）
     * 2) 读取当前 reserves（通过 Library.getReserves）
     * 3) 若池子为空（reserveA=reserveB=0）：直接按 desired 注入（初始化池子）
     * 4) 若池子已有资产：必须按当前池子比例注入，否则会改变价格
     *    - 用 quote(amountADesired, reserveA, reserveB) 计算 B 的最优值
     *    - 若最优 B 不超过用户愿意给的 B，则用 (amountADesired, amountBOptimal)
     *    - 否则反过来算 A 的最优值，用 (amountAOptimal, amountBDesired)
     *
     * 注意：
     * - quote 本质是比例换算：amountB = amountA * reserveB / reserveA
     * - 这一步只做“比例计算”，不涉及 0.3% 交易费（因为这是加流动性，不是 swap）
     */
    function _addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) internal virtual returns (uint amountA, uint amountB) {
        // create the pair if it doesn't exist yet
        // Router 层面确保 Pair 存在，减少用户心智负担；核心 Pair 自身不负责创建
        if (IUniswapV2Factory(factory).getPair(tokenA, tokenB) == address(0)) {
            IUniswapV2Factory(factory).createPair(tokenA, tokenB);
        }

        // 通过 Library 读取储备（内部会 sortTokens + pairFor + pair.getReserves）
        (uint reserveA, uint reserveB) = UniswapV2Library.getReserves(factory, tokenA, tokenB);

        // 如果是“第一次加池”（两个 reserve 都为 0），直接使用 desired 数量
        if (reserveA == 0 && reserveB == 0) {
            (amountA, amountB) = (amountADesired, amountBDesired);
        } else {
            // 按当前池子价格比例算出 B 的最优投入量
            uint amountBOptimal = UniswapV2Library.quote(amountADesired, reserveA, reserveB);

            if (amountBOptimal <= amountBDesired) {
                // 用户提供的 B 足够覆盖“最优 B”，则固定 A=amountADesired，B=amountBOptimal
                // 同时检查 B 不低于用户设置的最小值（滑点/保护）
                require(amountBOptimal >= amountBMin, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
                (amountA, amountB) = (amountADesired, amountBOptimal);
            } else {
                // 否则用户的 B 不够，反过来算：以 amountBDesired 为基准，求最优 A
                uint amountAOptimal = UniswapV2Library.quote(amountBDesired, reserveB, reserveA);

                // 理论上 amountAOptimal 一定 <= amountADesired，否则就与上面的分支矛盾
                assert(amountAOptimal <= amountADesired);

                require(amountAOptimal >= amountAMin, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
                (amountA, amountB) = (amountAOptimal, amountBDesired);
            }
        }
    }

    /**
     * @notice addLiquidity：给两个 ERC20 加流动性
     *
     * 与 core 的关系：
     * - Router 先把 tokenA/tokenB 转进 Pair
     * - 然后调用 Pair.mint(to) 铸造 LP（LP 的计算发生在 Pair.mint 内部）
     *
     * 技术细节：
     * - Pair 地址由 Library.pairFor(factory, tokenA, tokenB) 推导（CREATE2 可预测地址）
     * - TransferHelper.safeTransferFrom：兼容非标准 ERC20（不返回 bool）
     */
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint amountA, uint amountB, uint liquidity) {
        // 计算“最优投入数量”
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);

        // 推导 pair 地址（不需要链上查询 mapping）
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);

        // 将两种 token 转入 Pair（Pair 用 balance-reserve 计算实际注入量）
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);

        // Pair.mint 内部根据余额增量计算 liquidity，更新 reserves，并 mint LP 给 to
        liquidity = IUniswapV2Pair(pair).mint(to);
    }

    /**
     * @notice addLiquidityETH：给 token + ETH 加流动性
     *
     * 关键点：Pair 只接收 ERC20，不接收 ETH，所以 Router 使用 WETH 包装：
     * - 用户发 ETH（msg.value）
     * - Router 调 WETH.deposit{value: amountETH}()
     * - Router 把 WETH 转入 Pair
     * - Pair.mint(to)
     *
     * dust refund：若 msg.value > amountETH（用户多给了 ETH），退回多余 ETH
     */
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external virtual override payable ensure(deadline) returns (uint amountToken, uint amountETH, uint liquidity) {
        // 把 (token, WETH) 当成一对来做 _addLiquidity
        (amountToken, amountETH) = _addLiquidity(
            token,
            WETH,
            amountTokenDesired,
            msg.value,
            amountTokenMin,
            amountETHMin
        );

        address pair = UniswapV2Library.pairFor(factory, token, WETH);

        // ERC20 token 转入 Pair
        TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);

        // ETH -> WETH
        IWETH(WETH).deposit{value: amountETH}();

        // 把 WETH 转入 Pair
        assert(IWETH(WETH).transfer(pair, amountETH));

        // mint LP
        liquidity = IUniswapV2Pair(pair).mint(to);

        // refund dust eth, if any
        if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
    }

    // ============================================================
    //                      REMOVE LIQUIDITY
    // ============================================================

    /**
     * @notice removeLiquidity：移除两个 ERC20 的流动性
     *
     * 关键流程：
     * 1) 找到 Pair
     * 2) 把 LP（liquidity）从用户 transferFrom 到 Pair（注意：直接转到 Pair，不是 Router）
     * 3) 调 Pair.burn(to)：Pair 按份额把两种 token 直接转给 to
     * 4) Router 对 amountA/amountB 做最小值校验（滑点保护）
     *
     * 与 core 的关系：
     * - LP token 是 Pair 自身（继承 UniswapV2ERC20）发行的 ERC20
     * - Pair.burn 内部使用 balance/totalSupply 按比例分配并更新 reserves
     */
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountA, uint amountB) {
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);

        // 把 LP 直接送到 Pair（Pair.burn 会读取 balanceOf[address(this)]）
        IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair

        // Pair 返还 token0/token1 给 to
        (uint amount0, uint amount1) = IUniswapV2Pair(pair).burn(to);

        // burn 返回的是 (token0对应amount0, token1对应amount1)
        // 但用户传的是 tokenA/tokenB，顺序不一定等于 token0/token1
        // 所以要 sortTokens 来重新映射回 (amountA, amountB)
        (address token0,) = UniswapV2Library.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);

        // 最小值校验：防止滑点/夹子导致拿到的少于预期
        require(amountA >= amountAMin, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
    }

    /**
     * @notice removeLiquidityETH：移除 token + ETH 的流动性
     *
     * 实现方式：
     * 1) 调 removeLiquidity(token, WETH, ...) 并把 to 设置为 Router 自己
     *    => Pair 会把 token 和 WETH 转到 Router
     * 2) Router 把 token 转给用户
     * 3) Router 调 WETH.withdraw(amountETH) 把 WETH 换成 ETH
     * 4) Router 把 ETH 转给用户
     *
     * 为什么中间要 Router 接收？
     * - 因为 Pair 给的是 WETH，用户要的是 ETH，需要 Router 做 unwrap
     */
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountToken, uint amountETH) {
        (amountToken, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );

        // 把 token 转给用户
        TransferHelper.safeTransfer(token, to, amountToken);

        // WETH -> ETH
        IWETH(WETH).withdraw(amountETH);

        // ETH 转给用户
        TransferHelper.safeTransferETH(to, amountETH);
    }

    /**
     * @notice removeLiquidityWithPermit：用 permit 一步完成“授权 + 移除流动性”
     *
     * 背景：
     * - 移除流动性需要 Router 先拿到用户 LP 的 allowance
     * - 正常流程是：approve -> removeLiquidity（两笔交易）
     * - permit 支持签名授权：用户链下签名，Router 链上验证后直接获得 allowance
     *
     * approveMax：
     * - true：授权 uint(-1)（无限）
     * - false：只授权本次 liquidity
     */
    function removeLiquidityWithPermit(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual override returns (uint amountA, uint amountB) {
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        uint value = approveMax ? uint(-1) : liquidity;

        // LP token 的 permit 在 Pair(=UniswapV2ERC20)里实现（EIP-2612）
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);

        (amountA, amountB) = removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
    }

    /**
     * @notice removeLiquidityETHWithPermit：同上，但最后输出 ETH
     */
    function removeLiquidityETHWithPermit(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual override returns (uint amountToken, uint amountETH) {
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        uint value = approveMax ? uint(-1) : liquidity;
        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);

        (amountToken, amountETH) = removeLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to, deadline);
    }

    // ============================================================
    //     REMOVE LIQUIDITY (supporting fee-on-transfer tokens)
    // ============================================================

    /**
     * @notice removeLiquidityETHSupportingFeeOnTransferTokens
     *
     * fee-on-transfer token（转账扣税币）特点：
     * - Pair burn 给 Router 的 token 数量可能“少于理论值”（因为转账过程中扣了税）
     *
     * 处理方式：
     * - 不信任 Pair.burn 返回的 token 数量（它返回的是 burn 计算值，但到 Router 的实际到账可能更少）
     * - 直接以 Router 当前实际余额 IERC20(token).balanceOf(address(this)) 转给用户
     *
     * 这样可兼容扣税币，但也意味着：
     * - amountTokenMin 的校验发生在 removeLiquidity() 内部（基于 Pair.burn 计算结果）
     * - 真正到手的 token 可能更少（这是扣税币的本质风险）
     */
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountETH) {
        // 先把 (token, WETH) 的资产取到 Router（WETH 在 Router 中 unwrap 成 ETH）
        (, amountETH) = removeLiquidity(
            token,
            WETH,
            liquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            deadline
        );

        // 对“扣税币”：按 Router 实际余额转给用户
        TransferHelper.safeTransfer(token, to, IERC20(token).balanceOf(address(this)));

        // WETH -> ETH
        IWETH(WETH).withdraw(amountETH);
        TransferHelper.safeTransferETH(to, amountETH);
    }

    /**
     * @notice removeLiquidityETHWithPermitSupportingFeeOnTransferTokens：permit + 上述逻辑
     */
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline,
        bool approveMax, uint8 v, bytes32 r, bytes32 s
    ) external virtual override returns (uint amountETH) {
        address pair = UniswapV2Library.pairFor(factory, token, WETH);
        uint value = approveMax ? uint(-1) : liquidity;

        IUniswapV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);

        amountETH = removeLiquidityETHSupportingFeeOnTransferTokens(
            token, liquidity, amountTokenMin, amountETHMin, to, deadline
        );
    }

    // ============================================================
    //                           SWAP
    // ============================================================

    /**
     * @dev _swap：多跳 swap 的核心执行器（标准 token 版本）
     *
     * 输入：
     * - amounts：每一跳的输入输出数组（由 Library.getAmountsOut/In 预先算好）
     * - path：兑换路径，例如 [USDC, WETH, DAI]
     * - _to：最终收款地址
     *
     * 核心思想：
     * - 对于每一跳 (input -> output)：
     *   1) 计算本跳 amountOut（amounts[i+1]）
     *   2) 确定 token0/token1 以组装 (amount0Out, amount1Out)
     *   3) 决定本跳 swap 的 to 地址：
     *      - 如果还有下一跳：to = 下一跳 Pair 地址（让 output 直接进下一个池子）
     *      - 否则：to = 用户指定 _to
     *   4) 调 Pair.swap(...)
     *
     * 与 Pair.swap 的关系：
     * - Pair.swap 是“引擎”：只校验 K、推导 amountIn、更新 reserves
     * - Router._swap 负责“串联多跳、安排 token 流向”
     *
     * 注意注释：requires the initial amount to have already been sent to the first pair
     * 意味着：在调用 _swap 前，Router 已经把第一跳的输入 token 转入了第一跳 Pair
     */
    function _swap(uint[] memory amounts, address[] memory path, address _to) internal virtual {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);

            // 排序以匹配 Pair 的 token0/token1 定义
            (address token0,) = UniswapV2Library.sortTokens(input, output);

            uint amountOut = amounts[i + 1];

            // 根据 input 是否为 token0 决定输出到 amount0Out 还是 amount1Out
            (uint amount0Out, uint amount1Out) =
                input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));

            // to 的选择很关键：
            // - 如果不是最后一跳，让输出直接打到“下一跳 Pair”
            // - 如果是最后一跳，打给用户/指定地址
            address to = i < path.length - 2
                ? UniswapV2Library.pairFor(factory, output, path[i + 2])
                : _to;

            // 触发本跳 Pair 的 swap
            IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output)).swap(
                amount0Out, amount1Out, to, new bytes(0) // data=空 => 不触发 flash swap 回调
            );
        }
    }

    /**
     * @notice swapExactTokensForTokens：给定输入 amountIn，要求最小输出 amountOutMin
     *
     * 流程：
     * 1) 用 Library.getAmountsOut 计算每一跳 amounts（包含 0.3% fee 的公式）
     * 2) 检查最终输出 >= amountOutMin（滑点保护）
     * 3) 把输入 token 转到第一跳 Pair
     * 4) _swap 执行多跳
     *
     * 与 Library 的关系：
     * - getAmountsOut 内部会逐跳读取 reserves 并用 getAmountOut 计算
     */
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);

        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');

        // 把 amountIn 转入第一跳 Pair（之后 _swap 执行各跳 swap）
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );

        _swap(amounts, path, to);
    }

    /**
     * @notice swapTokensForExactTokens：给定想要输出 amountOut，限制最大输入 amountInMax
     *
     * 流程：
     * 1) 用 Library.getAmountsIn 反向计算需要的输入 amounts[0]
     * 2) 检查 amounts[0] <= amountInMax（上限保护）
     * 3) transfer 输入到第一跳 Pair
     * 4) _swap
     */
    function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');

        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );

        _swap(amounts, path, to);
    }

    /**
     * @notice swapExactETHForTokens：输入是 ETH，输出是 tokens
     *
     * 技术细节：
     * - path[0] 必须是 WETH（因为 Pair 只认识 ERC20）
     * - msg.value 作为 amountIn
     * - Router 把 ETH deposit 成 WETH，然后把 WETH 转进第一跳 Pair
     * - _swap 执行多跳，最终 token 发给 to
     */
    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        virtual
        override
        payable
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');

        amounts = UniswapV2Library.getAmountsOut(factory, msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');

        // ETH -> WETH
        IWETH(WETH).deposit{value: amounts[0]}();

        // 将 WETH 送入第一跳 Pair
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));

        _swap(amounts, path, to);
    }

    /**
     * @notice swapTokensForExactETH：输出是 ETH，输入是 tokens（反向计算输入）
     *
     * 流程：
     * 1) path 最后必须是 WETH
     * 2) getAmountsIn 计算需要输入多少 token
     * 3) transfer token 到第一跳 Pair
     * 4) _swap，把最终 WETH 打到 Router
     * 5) Router withdraw WETH -> ETH
     * 6) 转 ETH 给用户
     */
    function swapTokensForExactETH(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        virtual
        override
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');

        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');

        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );

        // 最终输出是 WETH，先打到 Router 再 unwrap
        _swap(amounts, path, address(this));

        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    /**
     * @notice swapExactTokensForETH：给定 token 输入，输出 ETH（固定输入）
     *
     * 与 swapTokensForExactETH 的区别：
     * - 这里固定 amountIn，通过 getAmountsOut 计算最终输出
     * - 最后一步仍然输出 WETH，然后 Router unwrap 成 ETH
     */
    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        virtual
        override
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');

        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');

        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amounts[0]
        );

        _swap(amounts, path, address(this));

        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
    }

    /**
     * @notice swapETHForExactTokens：想要固定输出 amountOut，输入 ETH（上限 msg.value）
     *
     * 流程：
     * - getAmountsIn 计算需要多少 WETH（即多少 ETH）
     * - deposit 需要的那部分 ETH -> WETH
     * - 多余 ETH 退回（refund dust）
     */
    function swapETHForExactTokens(
        uint amountOut,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        virtual
        override
        payable
        ensure(deadline)
        returns (uint[] memory amounts)
    {
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');

        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= msg.value, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');

        IWETH(WETH).deposit{value: amounts[0]}();
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));

        _swap(amounts, path, to);

        // refund dust eth, if any
        if (msg.value > amounts[0]) TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]);
    }

    // ============================================================
    //     SWAP (supporting fee-on-transfer tokens)
    // ============================================================

    /**
     * @dev _swapSupportingFeeOnTransferTokens：兼容“转账扣税币”的多跳 swap
     *
     * 为什么标准 _swap 不适用？
     * - 标准 _swap 假设：amounts[i]（输入）能完整到达 Pair
     * - 但扣税币会让 Pair 实际收到的 input < Router 预期转入数量
     * - 于是按预先计算的 amounts 做 swap 很可能失败（K 校验 / 输出不匹配）
     *
     * 解决方案（核心思想）：
     * - 不再使用 amounts 数组
     * - 每一跳都用 “pair 当前余额 - reserveInput” 推导真实 amountInput
     *   amountInput = IERC20(input).balanceOf(pair) - reserveInput
     * - 再用 getAmountOut(amountInput, reserveInput, reserveOutput) 计算本跳 amountOutput
     *
     * 注意：这与 Pair.swap 的设计哲学一致 —— “只信余额变化，不信外部参数”
     */
    function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to) internal virtual {
        for (uint i; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = UniswapV2Library.sortTokens(input, output);

            IUniswapV2Pair pair = IUniswapV2Pair(UniswapV2Library.pairFor(factory, input, output));

            uint amountInput;
            uint amountOutput;

            { // scope to avoid stack too deep errors
                (uint reserve0, uint reserve1,) = pair.getReserves();
                (uint reserveInput, uint reserveOutput) = input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);

                // 关键：真实输入量 = pair 当前余额 - 之前的 reserveInput
                // 因为 token 可能扣税，Router 只看真正到账了多少
                amountInput = IERC20(input).balanceOf(address(pair)).sub(reserveInput);

                // 用真实 amountInput 计算输出
                amountOutput = UniswapV2Library.getAmountOut(amountInput, reserveInput, reserveOutput);
            }

            (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOutput) : (amountOutput, uint(0));

            // 仍然采用“输出直达下一跳 Pair”的优化
            address to = i < path.length - 2
                ? UniswapV2Library.pairFor(factory, output, path[i + 2])
                : _to;

            pair.swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    /**
     * @notice swapExactTokensForTokensSupportingFeeOnTransferTokens
     *
     * 与标准版本的关键区别：
     * - 不返回 amounts（因为实际输入会因扣税变化，无法事先准确给出每跳 amounts）
     * - 用 “最终代币余额差” 作为输出校验：
     *   balanceAfter - balanceBefore >= amountOutMin
     *
     * 技术细节：
     * - 先把 amountIn 转入第一跳 Pair（注意：实际到 Pair 的可能更少）
     * - 然后 _swapSupportingFeeOnTransferTokens 逐跳用实际余额推导
     */
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) {
        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amountIn
        );

        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);

        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }

    /**
     * @notice swapExactETHForTokensSupportingFeeOnTransferTokens
     *
     * 逻辑同上，只是输入从 ETH 变成 WETH：
     * - deposit ETH -> WETH
     * - 送入第一跳 Pair
     * - 用最终余额差校验输出
     */
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        virtual
        override
        payable
        ensure(deadline)
    {
        require(path[0] == WETH, 'UniswapV2Router: INVALID_PATH');

        uint amountIn = msg.value;

        IWETH(WETH).deposit{value: amountIn}();
        assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn));

        uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
        _swapSupportingFeeOnTransferTokens(path, to);

        require(
            IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
            'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT'
        );
    }

    /**
     * @notice swapExactTokensForETHSupportingFeeOnTransferTokens
     *
     * 输出 ETH 的方式：
     * - 路径末尾必须是 WETH
     * - _swapSupportingFeeOnTransferTokens 让最终 WETH 打到 Router
     * - Router unwrap WETH -> ETH 给用户
     *
     * 输出校验：
     * - 这里用 Router 收到的 WETH 余额作为 amountOut
     */
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    )
        external
        virtual
        override
        ensure(deadline)
    {
        require(path[path.length - 1] == WETH, 'UniswapV2Router: INVALID_PATH');

        TransferHelper.safeTransferFrom(
            path[0],
            msg.sender,
            UniswapV2Library.pairFor(factory, path[0], path[1]),
            amountIn
        );

        // 最终 WETH 先到 Router
        _swapSupportingFeeOnTransferTokens(path, address(this));

        uint amountOut = IERC20(WETH).balanceOf(address(this));
        require(amountOut >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');

        IWETH(WETH).withdraw(amountOut);
        TransferHelper.safeTransferETH(to, amountOut);
    }

    // ============================================================
    //                    LIBRARY FUNCTIONS
    // ============================================================

    /**
     * @notice quote：用于加流动性时的比例换算（不含手续费）
     * amountB = amountA * reserveB / reserveA
     */
    function quote(uint amountA, uint reserveA, uint reserveB) public pure virtual override returns (uint amountB) {
        return UniswapV2Library.quote(amountA, reserveA, reserveB);
    }

    /**
     * @notice getAmountOut：单跳输出计算（含 0.3% 手续费）
     *
     * 公式：
     * amountOut = (amountIn*997*reserveOut) / (reserveIn*1000 + amountIn*997)
     *
     * 关系：
     * - swapExactTokensForTokens 等函数内部先用 getAmountsOut（多跳版本）
     * - 多跳版本会逐跳调用 getAmountOut
     */
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut)
        public
        pure
        virtual
        override
        returns (uint amountOut)
    {
        return UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    /**
     * @notice getAmountIn：单跳反推输入（含手续费）
     * 想要固定 amountOut，需要输入多少 amountIn
     */
    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut)
        public
        pure
        virtual
        override
        returns (uint amountIn)
    {
        return UniswapV2Library.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    /**
     * @notice getAmountsOut：多跳输出数组（标准 token 情况）
     * 输入 amountIn，返回每一跳的 amounts
     */
    function getAmountsOut(uint amountIn, address[] memory path)
        public
        view
        virtual
        override
        returns (uint[] memory amounts)
    {
        return UniswapV2Library.getAmountsOut(factory, amountIn, path);
    }

    /**
     * @notice getAmountsIn：多跳反推输入数组
     * 固定最终输出 amountOut，反推起点需要多少输入
     */
    function getAmountsIn(uint amountOut, address[] memory path)
        public
        view
        virtual
        override
        returns (uint[] memory amounts)
    {
        return UniswapV2Library.getAmountsIn(factory, amountOut, path);
    }
}
