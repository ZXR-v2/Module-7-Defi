pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath  for uint;
    using UQ112x112 for uint224;

    /// @notice 最小流动性锁定量（1000）
    /// 原理：首次创建池子时，会铸造 MINIMUM_LIQUIDITY 给 address(0) 永久锁死，
    /// 使得 totalSupply 永远 > 0，避免“池子被完全清空后 totalSupply 回到 0”
    /// 导致的边界状态切换问题（取整/初始化反复等风险）。
    uint public constant MINIMUM_LIQUIDITY = 10**3;

    /// @notice ERC20 transfer selector，用于 low-level call 兼容“非标准 ERC20”
    /// 有些 token transfer 不返回 bool；Uniswap 用这种写法：
    /// - success 必须为 true
    /// - data 为空（不返回值）或 decode 后为 true
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    /// @notice 工厂合约地址（Factory 是 Pair 的“全局配置源”）
    /// Pair 在 _mintFee() 中会读取 factory.feeTo() 判断是否开启协议费。
    address public factory;
    address public token0;
    address public token1;

    /// @dev reserves 不是“实时余额”，而是 Pair 自己记录的“上次操作结束时快照”
    /// 用 uint112 是为了打包存储省 gas（两边 reserve + timestamp 可以挤进更少槽位）
    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves

    /// @notice 价格累计（TWAP 预言机用）
    /// 核心思想：每次 update 时，把“当前价格 * 时间间隔”累加到 cumulative 里，
    /// 外部用 (cumNow - cumThen) / (tNow - tThen) 得到时间加权均价。
    uint public price0CumulativeLast;
    uint public price1CumulativeLast;

    /// @notice kLast = reserve0*reserve1（最近一次“流动性事件”后记录）
    /// “流动性事件”指 mint/burn。用于 _mintFee() 计算协议费（若开启）。
    uint public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    /// @dev 简易重入锁：mint/burn/swap/skim/sync 都加 lock
    /// 目的：防止在一次 swap 的回调（flash swap）中重入再次 swap/mint/burn
    /// 破坏本次执行中 _reserve 快照与 balance 推导输入量(amountIn)的对应关系。
    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    /// @notice 返回 reserves 快照（不是实时 balance）
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    /// @dev 安全转账：兼容“返回值不标准”的 ERC20
    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    /// @notice 构造函数：factory = 部署者（Factory 用 CREATE2 部署 Pair 后，msg.sender 就是 Factory）
    constructor() public {
        factory = msg.sender;
    }

    /// @notice initialize 仅由 Factory 调用一次，写入 token0/token1
    /// 为什么不是构造函数传参？
    /// 因为 Factory 用 CREATE2 部署 Pair 时，常用“先部署空壳，再初始化”模式来更灵活/省事。
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    /// @dev _update：把 reserves 快照同步到真实余额，并在“每区块首次更新”时累积价格
    /// 注意 balance0/balance1 是 token.balanceOf(pair)，是真实余额；_reserve0/_reserve1 是旧快照。
    /// 关键原理：
    /// - Pair 在 mint/burn/swap 里先读 balance，再做结算/校验，最后 _update 写回 reserve
    /// - reserves 是“账本快照”，balance 是“链上真实余额”
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        // uint112 上限检查：避免把过大余额写入 reserve 溢出
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');

        // blockTimestampLast 用 uint32 存，2^32 秒会回绕；Uniswap 设计上“允许回绕”
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired

        // 只有当：
        // 1) 跨越了时间（timeElapsed>0）
        // 2) reserves 非 0（池子已初始化）
        // 才累积价格（TWAP）
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // 价格 = reserve1/reserve0（token0 的价格用 token1 计价）
            // 用 UQ112x112 做定点数编码，防止精度损失
            // cumulative += price * timeElapsed
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }

        // 写入新的快照
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;

        emit Sync(reserve0, reserve1);
    }

    /// @dev _mintFee：协议费机制（可开关）
    /// 规则（V2 经典设计）：
    /// - swap 手续费 0.3% 始终存在并留在池子里（归 LP）
    /// - 若 Factory.feeTo != 0（协议费开启），则把“LP 收益的一部分”铸成 LP token 给 feeTo
    /// - 不是每笔 swap 都结算，而是在 mint/burn（流动性事件）时结算，省 gas
    /// - 目标效果约等价于：协议抽走 LP 收益的 1/6（即 0.3% 的六分之一 ≈ 0.05%）
    ///
    /// 为什么用 sqrt(k)？
    /// - k = x*y，池子规模线性增长时 k 二次增长
    /// - LP 的“价值尺度”更贴近 sqrt(k)，所以用 sqrt(k) 衡量“真实规模增长”
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        address feeTo = IUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint _kLast = kLast; // gas savings

        if (feeOn) {
            if (_kLast != 0) {
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                uint rootKLast = Math.sqrt(_kLast);

                // 只有池子规模增长（通常来自 swap fee 留在池子里）才会铸协议费
                if (rootK > rootKLast) {
                    // 这个公式是为了让协议拿到“规模增长的约 1/6”
                    // 结果是：给 feeTo 铸一些 LP token，使协议成为“一个很小的 LP 股东”
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            // 协议费关闭时，把 kLast 清零，避免下次开启时用旧数据结算
            kLast = 0;
        }
    }

    /// @notice mint：加流动性 -> 铸 LP token
    /// 重要：这个函数“低层”，假设外部调用者（通常 Router）已经做了安全检查、并把 token 转入 Pair
    ///
    /// 关键原理：Pair 不接受 amount0/amount1 参数，而是用：
    /// amount0 = balance0 - reserve0
    /// amount1 = balance1 - reserve1
    /// 来推导本次实际注入量（兼容 fee-on-transfer 等 token）
    function mint(address to) external lock returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings

        // 真实余额（链上最终态）
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));

        // 本次新增量 = 真实余额 - 旧快照
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);

        // totalSupply 可能在 _mintFee 中被改变（给 feeTo 铸了 LP），所以这里重新缓存一次
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee

        if (_totalSupply == 0) {
            // 第一次初始化池子：liquidity ~ sqrt(amount0*amount1)
            // 再减去 MINIMUM_LIQUIDITY，让其中 1000 永久锁死（address(0)）
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);

            // 永久锁定：确保 totalSupply 永远不为 0（防边界状态）
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            // 非首次：按比例铸造，取 min 防止单边投入改变价格（单边多出来的等于“白送池子”）
            liquidity = Math.min(
                amount0.mul(_totalSupply) / _reserve0,
                amount1.mul(_totalSupply) / _reserve1
            );
        }

        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity);

        // 操作结束：更新 reserves 快照 + 累积价格
        _update(balance0, balance1, _reserve0, _reserve1);

        // 若协议费开启，记录最新 kLast（仅在“流动性事件”后更新）
        if (feeOn) kLast = uint(reserve0).mul(reserve1);

        emit Mint(msg.sender, amount0, amount1);
    }

    /// @notice burn：移除流动性 -> 烧 LP token -> 按份额返还两种 token
    /// 通常流程：用户把 LP token 转给 Pair（或 Router 先转），然后调用 burn(to)
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings

        // 真实余额
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));

        // Pair 自己持有的 LP 数量 = 本次要 burn 的数量（因为用户已把 LP 转到 Pair）
        uint liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);

        // totalSupply 可能被 _mintFee 改过，所以重新读
        uint _totalSupply = totalSupply;

        // 赎回按份额：liquidity/totalSupply 的比例，分走 balance0/balance1
        // 注意用 balance（真实余额）而不是 reserve（快照），保证“按真实资产”分配
        amount0 = liquidity.mul(balance0) / _totalSupply;
        amount1 = liquidity.mul(balance1) / _totalSupply;

        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');

        // 销毁 LP
        _burn(address(this), liquidity);

        // 返还两种 token
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);

        // 转出后余额变了，必须重新读 balance 再 update
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));

        _update(balance0, balance1, _reserve0, _reserve1);

        if (feeOn) kLast = uint(reserve0).mul(reserve1);

        emit Burn(msg.sender, amount0, amount1, to);
    }

    /// @notice swap：交易引擎（token0<->token1 兑换），并支持 flash swap 回调
    ///
    /// 核心执行模型（非常重要）：
    /// 1) 校验输出量 <= reserves
    /// 2) “先乐观转出”（optimistic transfer）
    /// 3) 若 data 非空，调用 to 的回调（flash swap）
    /// 4) 回调结束后读取最终 balance
    /// 5) 用 balance 与 reserves 的差值反推 amountIn（不信任外部传参）
    /// 6) 做含 0.3% 手续费的不变量校验（K check）
    /// 7) 更新 reserves
    ///
    /// 重要：Pair 本身通常不计算“你能拿多少 out”，它只做校验；
    /// 具体 out 通常由 Router/Library 计算后传入。
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');

        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;

        { // scope for _token{0,1}, avoids stack too deep errors
            address _token0 = token0;
            address _token1 = token1;

            // 防止把输出直接转给 token 合约本身（一些奇怪边界/回调风险）
            require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');

            // 先把用户想要的 token 转出去（乐观转出）
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out);
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out);

            // flash swap：允许 to 合约在回调里使用拿到的资产做套利/还款
            // 只要回调结束后把“应付的输入+手续费”补回 Pair，K 校验能过就行。
            if (data.length > 0) {
                IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
            }

            // 回调之后读取最终真实余额
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }

        // 反推输入量：
        // “操作后余额” 与 “操作前应有余额（reserve - out）” 的差额，就是本次 in
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;

        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');

        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
            // 手续费 0.3% 的实现方式：
            // 把 balance * 1000 作为基准，然后从输入里扣 3/1000（即 0.3%）
            // 等价于：只有 997/1000 的输入参与做市
            uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
            uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));

            // K 校验（含手续费）：保证做市商不亏
            // balanceAdjusted0 * balanceAdjusted1 >= reserve0 * reserve1 * 1000^2
            // 若你想拿更多 out 或少给 in，就过不了这个 require，会 revert。
            require(
                balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000**2),
                'UniswapV2: K'
            );
        }

        // 最后更新快照（把 balance 写入 reserve）
        _update(balance0, balance1, _reserve0, _reserve1);

        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /// @notice skim：把“多出来的余额（balance - reserve）”转走
    /// 用途：如果有人直接转 token 到 Pair（不通过 mint/swap），会造成 balance>reserve
    /// skim 可以把差额取走（通常用于纠偏/清算/某些特殊场景）
    function skim(address to) external lock {
        address _token0 = token0;
        address _token1 = token1;
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    /// @notice sync：强制把 reserves 更新为当前真实余额
    /// 用途：同上，解决“有人直接转币进 Pair 导致 reserve 与 balance 不一致”的问题
    function sync() external lock {
        _update(
            IERC20(token0).balanceOf(address(this)),
            IERC20(token1).balanceOf(address(this)),
            reserve0,
            reserve1
        );
    }
}
