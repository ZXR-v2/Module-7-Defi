// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "solmate/tokens/WETH.sol";
import "../src/MemeFactory.sol";
import "../src/MemeToken.sol";

interface IUniswapV2Factory {
    function getPair(address, address) external view returns (address);
}

interface IUniswapV2Router02 {
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);
}

contract MemeFactoryTest is Test {
    WETH public weth;
    address public uniswapFactoryAddr;
    address public routerAddr;
    IUniswapV2Factory public uniswapFactory;
    IUniswapV2Router02 public router;

    MemeFactory public memeFactory;

    address public issuer = address(0x1);
    address public alice = address(0x2);
    address public bob = address(0x3);

    address public memeToken;
    uint256 constant TOTAL_SUPPLY = 1_000_000 ether;
    uint256 constant PER_MINT = 1000 ether;
    uint256 constant PRICE = 0.001 ether; // 1 token = 0.001 ETH

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

        vm.deal(issuer, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function test_deployMeme_and_mintMeme_addsLiquidity() public {
        vm.startPrank(issuer);

        memeToken = memeFactory.deployMeme("MEME", TOTAL_SUPPLY, PER_MINT, PRICE);
        assertTrue(memeFactory.isMeme(memeToken));
        assertEq(MemeToken(memeToken).issuer(), issuer);

        // 首次 mint：总价 = 1000 * 0.001 = 1 ETH；5% 项目费、5% 流动性、90% 发行方
        uint256 totalCost = (PER_MINT * PRICE) / 1e18; // 1 ether
        uint256 projectFee = (totalCost * memeFactory.PROJECT_FEE_PERCENT()) / 100;
        uint256 liquidityEth = (totalCost * memeFactory.LIQUIDITY_PERCENT()) / 100;
        uint256 issuerFee = totalCost - projectFee - liquidityEth;

        address projectOwnerAddr = memeFactory.projectOwner();
        uint256 projectOwnerBefore = projectOwnerAddr.balance;
        uint256 issuerBalanceBefore = issuer.balance;

        memeFactory.mintMeme{value: totalCost}(memeToken);

        assertEq(MemeToken(memeToken).balanceOf(issuer), PER_MINT);

        address pair = uniswapFactory.getPair(memeToken, address(weth));
        assertTrue(pair != address(0), "Pair should exist after first mint");

        // 项目方：应收到 5% 项目费（且 LP 也发给 projectOwner，这里只断言 ETH）
        assertEq(projectOwnerAddr.balance - projectOwnerBefore, projectFee, "Project owner should receive 5% fee");

        // 发行方：支付 totalCost 后应收回 90% 的 issuerFee
        assertEq(issuer.balance, issuerBalanceBefore - totalCost + issuerFee, "Issuer should receive 90% issuer fee");

        // 交易所（Uniswap 池子）：5% 的 ETH 作为流动性进入 pair（以 WETH 形式）
        assertEq(weth.balanceOf(pair), liquidityEth, "Pair should hold 5% liquidity ETH");

        vm.stopPrank();
    }

    function test_buyMeme_whenUniswapPriceBetterOrEqual() public {
        vm.startPrank(issuer);
        memeToken = memeFactory.deployMeme("MEME", TOTAL_SUPPLY, PER_MINT, PRICE);
        uint256 totalCost = (PER_MINT * PRICE) / 1e18;
        memeFactory.mintMeme{value: totalCost}(memeToken);
        vm.stopPrank();

        address pair = uniswapFactory.getPair(memeToken, address(weth));
        uint256 pairWethBefore = weth.balanceOf(pair);

        uint256 bobEthBefore = bob.balance;
        uint256 bobTokenBefore = MemeToken(memeToken).balanceOf(bob);
        // 使用较小金额以减少 AMM 滑点，使 DEX 能给出不低于（约）起始价格的 token
        uint256 ethSpend = 0.001 ether;
        uint256 minOutAtMintPrice = (ethSpend * 1e18) / PRICE; // 1 token (18 decimals)

        vm.prank(bob);
        memeFactory.buyMeme{value: ethSpend}(memeToken);

        // Bob 支付的 ETH 减少 exactly ethSpend
        assertEq(bobEthBefore - bob.balance, ethSpend, "Bob should spend exact ethSpend");

        uint256 bobTokenAfter = MemeToken(memeToken).balanceOf(bob);
        assertGe(bobTokenAfter - bobTokenBefore, minOutAtMintPrice * 97 / 100, "Should get at least ~mint-price equivalent (97% tolerance)");

        // 交易所（pair）：swap 进入的 ETH 以 WETH 形式进入池子
        assertEq(weth.balanceOf(pair) - pairWethBefore, ethSpend, "Pair should receive swap ETH as WETH");
    }

    function test_buyMeme_revertsWhenNoPair() public {
        vm.startPrank(issuer);
        memeToken = memeFactory.deployMeme("MEME", TOTAL_SUPPLY, PER_MINT, PRICE);
        vm.stopPrank();
        // 未 mint 则未 addLiquidity，Router 不会 createPair，故 Token/WETH pair 不存在
        address pair = uniswapFactory.getPair(memeToken, address(weth));
        assertEq(pair, address(0), "Pair should not exist before any mint");

        uint256 bobEthBefore = bob.balance;
        uint256 ethSpend = 0.1 ether;

        vm.prank(bob);
        vm.expectRevert("No pair");
        memeFactory.buyMeme{value: ethSpend}(memeToken);

        // revert 后 Bob 的 ETH 不应被扣
        assertEq(bob.balance, bobEthBefore, "Bob ETH unchanged after revert");
    }

    function test_feeAndLiquidityPercent() public view {
        assertEq(memeFactory.PROJECT_FEE_PERCENT(), 5);
        assertEq(memeFactory.LIQUIDITY_PERCENT(), 5);
    }

    receive() external payable {}
}
