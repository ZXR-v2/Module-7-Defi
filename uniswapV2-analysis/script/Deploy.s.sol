// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;

import "@uniswap/v2-core/contracts/UniswapV2Factory.sol";
import "periphery/UniswapV2Router02.sol";
import "periphery/test/WETH9.sol";

interface Vm {
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
    function addr(uint256 privateKey) external view returns (address);
}

/**
 * @title Deploy
 * @notice 本地部署 Uniswap V2 Core + Periphery：WETH、Factory、Router02
 *
 * 使用前请确保 init_code_hash 已与本工程编译的 Pair 一致（见下方说明）。
 *
 * 运行（Anvil 本地）：
 *   anvil
 *   forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
 *
 * 或仅模拟：
 *   forge script script/Deploy.s.sol
 */
contract Deploy {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function run() external returns (address weth, address factory, address router) {
        // 默认使用 Anvil 第一个账户私钥；链上部署可设置环境变量 PRIVATE_KEY
        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

        vm.startBroadcast(deployerPrivateKey);

        // 1. 部署 WETH（与 IWETH 兼容的 WETH9）
        WETH9 _weth = new WETH9();
        weth = address(_weth);

        // 2. 部署 Factory，feeToSetter 设为部署者
        address feeToSetter = vm.addr(deployerPrivateKey);
        UniswapV2Factory _factory = new UniswapV2Factory(feeToSetter);
        factory = address(_factory);

        // 3. 部署 Router02
        UniswapV2Router02 _router = new UniswapV2Router02(factory, weth);
        router = address(_router);

        vm.stopBroadcast();

        // 日志便于在链上或前端使用
        emit Deployed(weth, factory, router, feeToSetter);
    }

    event Deployed(address weth, address factory, address router, address feeToSetter);
}
