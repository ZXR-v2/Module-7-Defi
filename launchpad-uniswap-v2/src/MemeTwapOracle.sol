// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Uniswap V2 Pair（仅 TWAP 所需字段）
interface IUniswapV2PairForTwap {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

interface IUniswapV2FactoryForTwap {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/**
 * @title MemeTwapOracle
 * @dev 对 LaunchPad（MemeFactory）在 Uniswap V2 上的 Meme/WETH 池做 V2 风格 TWAP。
 *      与 Uniswap `ExampleOracleSimple` 相同思路：先 `register` 记录起点，间隔至少 `minPeriod` 后 `update` 刷新平均价，再用 `consultMemeInEth` 查询。
 *      UQ112×112 与累计价逻辑对齐 v2-core `UniswapV2Pair._update`，不依赖旧版 solidity-lib（避免高版本 Solc 编译失败）。
 */
contract MemeTwapOracle {
    IUniswapV2FactoryForTwap public immutable uniswapFactory;
    address public immutable weth;
    /// @dev 两次 `update` 之间的最短时间（秒），测试可用较小值，主网建议 ≥ 300
    uint32 public immutable minPeriod;

    struct Slot {
        address pair;
        uint32 blockTimestampLast;
        uint256 price0CumulativeLast;
        uint256 price1CumulativeLast;
        /// @dev TWAP 平均价（UQ112×112 的 uint224 尾数，与 pair 累计价同构）
        uint224 price0AverageX;
        uint224 price1AverageX;
        bool hasAverage;
    }

    mapping(address => Slot) public slots;

    error PairNotFound();
    error AlreadyRegistered();
    error NotRegistered();
    error PeriodNotElapsed();
    error NoAverageYet();

    uint224 private constant Q112 = 2 ** 112;

    constructor(address _uniswapFactory, address _weth, uint32 _minPeriod) {
        uniswapFactory = IUniswapV2FactoryForTwap(_uniswapFactory);
        weth = _weth;
        minPeriod = _minPeriod;
    }

    /// @notice 为某个 Meme 代币注册池子并记录初始累计价（需在链上已有 Meme/WETH 流动性）
    function register(address memeToken) external {
        if (slots[memeToken].pair != address(0)) revert AlreadyRegistered();
        address pair = uniswapFactory.getPair(memeToken, weth);
        if (pair == address(0)) revert PairNotFound();

        IUniswapV2PairForTwap p = IUniswapV2PairForTwap(pair);
        (uint112 r0, uint112 r1,) = p.getReserves();
        require(r0 != 0 && r1 != 0, "no liquidity");

        Slot storage s = slots[memeToken];
        s.pair = pair;
        s.price0CumulativeLast = p.price0CumulativeLast();
        s.price1CumulativeLast = p.price1CumulativeLast();
        (, , s.blockTimestampLast) = p.getReserves();
    }

    /// @notice 经过至少 `minPeriod` 秒后更新 TWAP 平均价（可被任何人调用）
    function update(address memeToken) external {
        Slot storage s = slots[memeToken];
        if (s.pair == address(0)) revert NotRegistered();

        (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp) =
            _currentCumulativePrices(s.pair);

        uint32 timeElapsed;
        unchecked {
            timeElapsed = blockTimestamp - s.blockTimestampLast;
        }
        if (timeElapsed < minPeriod) revert PeriodNotElapsed();

        s.price0AverageX = uint224((price0Cumulative - s.price0CumulativeLast) / timeElapsed);
        s.price1AverageX = uint224((price1Cumulative - s.price1CumulativeLast) / timeElapsed);

        s.price0CumulativeLast = price0Cumulative;
        s.price1CumulativeLast = price1Cumulative;
        s.blockTimestampLast = blockTimestamp;
        s.hasAverage = true;
    }

    /// @notice 按最近一次成功 `update` 的 TWAP，计算 `amountMeme`（18 位）可换得的 WETH（wei）
    function consultMemeInEth(address memeToken, uint256 amountMeme) external view returns (uint256) {
        return _consultMemeInEth(memeToken, amountMeme);
    }

    /// @notice 1e18 最小单位的 Meme 在 TWAP 下值多少 wei 的 ETH（便捷读数）
    function twapEthPer1e18Meme(address memeToken) external view returns (uint256) {
        return _consultMemeInEth(memeToken, 1e18);
    }

    function _consultMemeInEth(address memeToken, uint256 amountMeme) private view returns (uint256 ethWeiOut) {
        Slot storage s = slots[memeToken];
        if (!s.hasAverage) revert NoAverageYet();

        address t0 = IUniswapV2PairForTwap(s.pair).token0();
        if (memeToken == t0) {
            ethWeiOut = _uq112MulDecode(s.price0AverageX, amountMeme);
        } else {
            require(IUniswapV2PairForTwap(s.pair).token1() == memeToken, "not meme pair");
            ethWeiOut = _uq112MulDecode(s.price1AverageX, amountMeme);
        }
    }

    /// @dev UQ112×112 × amount → 整数部分（wei），等价于 Uniswap FixedPoint.mul(...).decode144()
    function _uq112MulDecode(uint224 priceX, uint256 amount) private pure returns (uint256) {
        if (amount == 0) return 0;
        uint256 px = uint256(priceX);
        uint256 prod = px * amount;
        require(prod / amount == px, "mul overflow");
        return prod >> 112;
    }

    /// @dev reserve1/reserve0 的 UQ112 编码，与 `UniswapV2Pair._update` 一致
    function _encodePrice(uint112 reserveNum, uint112 reserveDen) private pure returns (uint224) {
        return uint224((uint256(reserveNum) * Q112) / uint256(reserveDen));
    }

    /// @dev 与 UniswapV2OracleLibrary.currentCumulativePrices 一致（含当前块内 counterfactual）
    function _currentCumulativePrices(address pair)
        private
        view
        returns (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp)
    {
        blockTimestamp = uint32(block.timestamp % 2 ** 32);
        IUniswapV2PairForTwap p = IUniswapV2PairForTwap(pair);
        price0Cumulative = p.price0CumulativeLast();
        price1Cumulative = p.price1CumulativeLast();

        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = p.getReserves();
        if (blockTimestampLast != blockTimestamp && reserve0 != 0 && reserve1 != 0) {
            unchecked {
                uint32 timeElapsed = blockTimestamp - blockTimestampLast;
                price0Cumulative += uint256(_encodePrice(reserve1, reserve0)) * uint256(timeElapsed);
                price1Cumulative += uint256(_encodePrice(reserve0, reserve1)) * uint256(timeElapsed);
            }
        }
    }
}
