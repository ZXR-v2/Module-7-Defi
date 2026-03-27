// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "solmate/tokens/WETH.sol";
import "../src/MemeFactory.sol";
import "../src/MemeToken.sol";
import "../src/MemeTwapOracle.sol";

interface IUniswapV2Factory {
    function getPair(address, address) external view returns (address);
}

interface IUniswapV2Router02 {
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);
}

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

/// @dev 从池子储备读取「瞬时」ETH/MEME（仅测试对比用，非 TWAP）
library SpotPriceLib {
    function ethWeiPer1e18Meme(address pair, address meme) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        address t0 = IUniswapV2Pair(pair).token0();
        if (t0 == meme) {
            return (uint256(r1) * 1e18) / uint256(r0);
        }
        return (uint256(r0) * 1e18) / uint256(r1);
    }
}

contract MemeTwapOracleTest is Test {
    using SpotPriceLib for address;

    WETH public weth;
    address public uniswapFactoryAddr;
    address public routerAddr;
    IUniswapV2Factory public uniswapFactory;
    IUniswapV2Router02 public router;
    MemeFactory public memeFactory;
    MemeTwapOracle public oracle;

    /// @dev 用 Router 直接换仓，避免 buyMeme 的 97% 起始价下限在多笔交易后收紧导致 revert；池子仍为 LaunchPad 首次 mint 所建
    function _swapEthForMeme(address user, uint256 ethIn) internal {
        vm.prank(user);
        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = memeToken;
        router.swapExactETHForTokens{value: ethIn}(0, path, user, block.timestamp);
    }

    address public issuer = address(0x1);
    address public alice = address(0x2);
    address public bob = address(0x3);

    address public memeToken;
    uint256 constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 constant PER_MINT = 1000 ether;
    uint256 constant PRICE = 0.001 ether;

    /// @dev 测试用短窗口，便于 `warp` 模拟多笔交易
    uint32 constant TWAP_PERIOD = 100;

    function setUp() public {
        weth = new WETH();

        uniswapFactoryAddr = deployCode(
            "UniswapV2Factory.sol:UniswapV2Factory",
            abi.encode(address(this))
        );
        routerAddr = deployCode(
            "UniswapV2Router02.sol:UniswapV2Router02",
            abi.encode(uniswapFactoryAddr, address(weth))
        );

        uniswapFactory = IUniswapV2Factory(uniswapFactoryAddr);
        router = IUniswapV2Router02(routerAddr);
        memeFactory = new MemeFactory(routerAddr, address(weth));
        oracle = new MemeTwapOracle(uniswapFactoryAddr, address(weth), TWAP_PERIOD);

        vm.deal(issuer, 200 ether);
        vm.deal(alice, 200 ether);
        vm.deal(bob, 200 ether);

        vm.startPrank(issuer);
        memeToken = memeFactory.deployMeme("MEME", TOTAL_SUPPLY, PER_MINT, PRICE);
        uint256 totalCost = (PER_MINT * PRICE) / 1e18;
        memeFactory.mintMeme{value: totalCost}(memeToken);
        vm.stopPrank();

        oracle.register(memeToken);
    }

    /// @dev 在多个时间点做 swap，再 `update`；TWAP 应介于窗口内价格之间，且与窗口末瞬时价可区分（大 swap 在末尾）
    function test_twapAcrossMultipleSwapsDiffersFromEndSpot() public {
        address pair = uniswapFactory.getPair(memeToken, address(weth));
        assertTrue(pair != address(0));

        uint256 spotInitial = pair.ethWeiPer1e18Meme(memeToken);

        // t + 20：小额买入
        vm.warp(block.timestamp + 20);
        _swapEthForMeme(alice, 0.002 ether);

        // t + 50
        vm.warp(block.timestamp + 30);
        _swapEthForMeme(bob, 0.003 ether);

        // t + 90：较大一笔，拉高末尾瞬时价
        vm.warp(block.timestamp + 40);
        _swapEthForMeme(alice, 0.015 ether);

        uint256 spotEnd = pair.ethWeiPer1e18Meme(memeToken);

        // 满足 minPeriod：从 register 起累计约 105s ≥ 100
        vm.warp(block.timestamp + 15);

        oracle.update(memeToken);

        uint256 twap = oracle.twapEthPer1e18Meme(memeToken);

        assertGt(twap, 0, "TWAP > 0");
        assertGt(spotEnd, spotInitial, "spot moved after buys");
        assertLt(twap, spotEnd, "TWAP below terminal spot after late pump");
        assertGt(twap, spotInitial, "TWAP above initial spot (window includes buys)");
    }

    /// @dev 第二次 update：在新窗口内只做小额交易，TWAP 应随新窗口变化
    function test_secondUpdateWindow() public {
        address pair = uniswapFactory.getPair(memeToken, address(weth));

        vm.warp(block.timestamp + TWAP_PERIOD);
        oracle.update(memeToken);
        uint256 twap1 = oracle.twapEthPer1e18Meme(memeToken);

        // 新窗口：多次小额 swap
        vm.warp(block.timestamp + 30);
        _swapEthForMeme(bob, 0.005 ether);
        vm.warp(block.timestamp + 40);
        _swapEthForMeme(alice, 0.005 ether);

        vm.warp(block.timestamp + TWAP_PERIOD);
        oracle.update(memeToken);
        uint256 twap2 = oracle.twapEthPer1e18Meme(memeToken);

        assertGt(twap2, twap1, "second window TWAP should reflect new buys");
        assertGt(pair.ethWeiPer1e18Meme(memeToken), 0);
    }

    function test_registerRevertsIfNoPair() public {
        MemeTwapOracle fresh = new MemeTwapOracle(uniswapFactoryAddr, address(weth), TWAP_PERIOD);
        vm.expectRevert(MemeTwapOracle.PairNotFound.selector);
        fresh.register(address(0xBEEF));
    }

    function test_updateRevertsBeforePeriod() public {
        vm.expectRevert(MemeTwapOracle.PeriodNotElapsed.selector);
        oracle.update(memeToken);
    }

    function test_consultRevertsBeforeUpdate() public {
        MemeTwapOracle fresh = new MemeTwapOracle(uniswapFactoryAddr, address(weth), TWAP_PERIOD);
        fresh.register(memeToken);
        vm.expectRevert(MemeTwapOracle.NoAverageYet.selector);
        fresh.consultMemeInEth(memeToken, 1e18);
    }

    receive() external payable {}
}
