pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {

    /// @notice 协议手续费接收地址
    /// 如果该地址 != 0，则 Pair 在 mint/burn 时会通过 _mintFee()
    /// 给该地址铸造一小部分 LP（协议抽成）
    address public feeTo;

    /// @notice feeToSetter 有权限修改 feeTo
    /// 相当于“协议治理者/管理员”
    address public feeToSetter;

    /// @notice 记录每对 token 的 Pair 地址
    /// getPair[token0][token1] => pair address
    /// 用双层 mapping 实现 O(1) 查询
    mapping(address => mapping(address => address)) public getPair;

    /// @notice 所有已创建的 Pair 地址数组
    /// 用于链上枚举或前端查询
    address[] public allPairs;

    /// @notice 创建 Pair 时触发的事件
    /// 前端和 indexer（如 TheGraph）会监听它
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    /// @notice 构造函数：设置 feeToSetter
    /// 部署 Factory 时指定“治理者”
    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    /// @notice 返回所有 Pair 数量
    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    /// @notice 创建新的交易对 Pair（核心函数）
    function createPair(address tokenA, address tokenB) external returns (address pair) {

        /// 1️⃣ 不允许相同 token
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');

        /// 2️⃣ 排序 token 地址（小的在前）
        /// 原理：
        /// 保证 tokenA/tokenB 和 tokenB/tokenA
        /// 创建的是同一个 Pair
        (address token0, address token1) =
            tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        /// 3️⃣ 禁止 0 地址
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');

        /// 4️⃣ 防止重复创建
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS');

        /// 5️⃣ 获取 Pair 合约字节码
        bytes memory bytecode = type(UniswapV2Pair).creationCode;

        /// 6️⃣ CREATE2 的 salt
        /// 用 token0+token1 做 hash
        /// 👉 使 Pair 地址可预测
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));

        /// 7️⃣ 使用 CREATE2 部署 Pair
        /// create2(value, codePtr, codeSize, salt)
        /// 特点：
        /// Pair 地址 = keccak256(0xff + factory + salt + bytecode)
        /// 👉 地址可提前计算（pairFor）
        /// bytecode的前32个字节是长度，后面才是真正的字节码。add(bytecode, 32)是跳过长度字段，指向真正代码开始位置
        /// mload(bytecode)是把字节码的前32个字节读入，即字节码长度
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        /// 8️⃣ 初始化 Pair（设置 token0/token1）
        IUniswapV2Pair(pair).initialize(token0, token1);

        /// 9️⃣ 双向映射记录
        /// 为什么双向？
        /// 方便查询，不用再排序
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;

        /// 🔟 记录到数组
        allPairs.push(pair);

        /// 触发事件
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    /// @notice 设置协议手续费接收地址
    /// 只有 feeToSetter 能调用
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    /// @notice 修改治理者地址
    /// 相当于移交控制权
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
