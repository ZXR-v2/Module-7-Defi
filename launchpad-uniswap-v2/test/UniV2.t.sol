// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "solmate/tokens/WETH.sol";
import "solmate/tokens/ERC20.sol";

// --- Uniswap interfaces (0.8-safe) ---
interface IUniswapV2Factory {
    function createPair(address, address) external returns (address);
    function getPair(address, address) external view returns (address);
}

interface IUniswapV2Router02 {
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);

    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);
}

contract TestToken is ERC20 {
    constructor() ERC20("Test", "TEST", 18) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract UniV2Test is Test {
    IUniswapV2Factory factory;
    IUniswapV2Router02 router;
    WETH weth;
    TestToken token;

    address alice = address(0x123);

    function setUp() public {
        weth = new WETH();

        // 部署 Uniswap V2 合约（关键：不 import 源码）
        address factoryAddr =
            deployCode("UniswapV2Factory.sol:UniswapV2Factory", abi.encode(address(this)));

        address routerAddr =
            deployCode("UniswapV2Router02.sol:UniswapV2Router02", abi.encode(factoryAddr, address(weth)));

        factory = IUniswapV2Factory(factoryAddr);
        router = IUniswapV2Router02(routerAddr);

        token = new TestToken();
        token.mint(address(this), 1_000_000 ether);

        vm.deal(alice, 10 ether);
    }

    function test_addLiquidity_and_swap() public {
        token.approve(address(router), type(uint256).max);

        router.addLiquidityETH{value: 10 ether}(
            address(token),
            100_000 ether,
            0,
            0,
            address(this),
            block.timestamp
        );

        vm.startPrank(alice);

        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(token);

        uint[] memory amounts = router.swapExactETHForTokens{value: 1 ether}(
            0,
            path,
            alice,
            block.timestamp
        );

        vm.stopPrank();

        assertEq(amounts[0], 1 ether);
        assertGt(amounts[1], 0);
        assertEq(token.balanceOf(alice), amounts[1]);
    }

}
