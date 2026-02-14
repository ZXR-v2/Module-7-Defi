// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;

import "../contracts/UniswapV2Router02.sol";
import "../contracts/test/WETH9.sol";

interface Vm {
    function startBroadcast(uint256 privateKey) external;
    function stopBroadcast() external;
    function addr(uint256 privateKey) external view returns (address);
}

/**
 * @title Deploy
 * @notice 仅部署 WETH + Router02（只用 0.6.6，避免 solc 0.5.16）。
 * Factory 需先在 v2-core 目录用 forge create 部署，再把地址填到 FACTORY 常量后运行本脚本。
 *
 * 步骤：
 * 1) 在 v2-core 部署 Factory:
 *    cd ../v2-core && forge create UniswapV2Factory --constructor-args <FEE_TO_SETTER_ADDRESS> --rpc-url http://127.0.0.1:8545 --private-key 0xac0974...
 *    记下 Deployed to: 0x...
 * 2) 把下面 FACTORY 改成该地址
 * 3) 在 v2-periphery: forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
 */
contract Deploy {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    /// 填你已部署的 UniswapV2Factory 地址（先运行上面 v2-core 的 forge create）
    address constant FACTORY = 0x5FbDB2315678afecb367f032d93F642f64180aa3;

    function run() external returns (address weth, address router) {
        require(FACTORY != address(0), "Set FACTORY to your deployed UniswapV2Factory address");

        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

        vm.startBroadcast(deployerPrivateKey);

        WETH9 _weth = new WETH9();
        weth = address(_weth);

        UniswapV2Router02 _router = new UniswapV2Router02(FACTORY, weth);
        router = address(_router);

        vm.stopBroadcast();

        emit Deployed(FACTORY, weth, router);
    }

    event Deployed(address factory, address weth, address router);
}