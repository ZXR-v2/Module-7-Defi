pragma solidity =0.6.6;

/**
 * UniswapV2Migrator（V1 → V2 流动性迁移器）
 *
 * 作用：
 * 👉 帮助用户把 Uniswap V1 的 LP 流动性，一键迁移到 Uniswap V2
 *
 * 背景：
 * - Uniswap V1 是“每个 token 对应一个 ETH 池”
 *   即：Token/ETH 二元池
 * - V2 引入：
 *   👉 任意 Token/Token
 *   👉 更优定价与路由
 *   👉 更标准的 LP token 机制
 *
 * 因此官方提供 Migrator：
 * 👉 让用户无需手动拆池/加池
 * 👉 一次交易完成迁移
 *
 * 工作流程（核心逻辑）：
 * 1️⃣ 从 V1 取出用户 LP（removeLiquidity）
 * 2️⃣ 得到 Token + ETH
 * 3️⃣ 用 Router 在 V2 中 addLiquidityETH
 * 4️⃣ 把新 LP mint 给用户
 * 5️⃣ 多余 Token/ETH 退回
 *
 * 与其他合约关系：
 * - IUniswapV1Factory：
 *     查找 V1 的 exchange 地址
 * - IUniswapV1Exchange：
 *     执行 removeLiquidity
 * - IUniswapV2Router01：
 *     在 V2 中 addLiquidityETH
 * - TransferHelper：
 *     安全 approve / transfer
 *
 * ⚠️ 重要：
 * 这是一次性迁移工具，不是长期基础设施
 */

import '@uniswap/lib/contracts/libraries/TransferHelper.sol';

import './interfaces/IUniswapV2Migrator.sol';
import './interfaces/V1/IUniswapV1Factory.sol';
import './interfaces/V1/IUniswapV1Exchange.sol';
import './interfaces/IUniswapV2Router01.sol';
import './interfaces/IERC20.sol';

contract UniswapV2Migrator is IUniswapV2Migrator {

    /// @notice V1 工厂（用于查 exchange）
    IUniswapV1Factory immutable factoryV1;

    /// @notice V2 Router（用于 addLiquidity）
    IUniswapV2Router01 immutable router;

    /**
     * 构造函数
     *
     * _factoryV1：Uniswap V1 factory
     * _router：Uniswap V2 router
     */
    constructor(address _factoryV1, address _router) public {
        factoryV1 = IUniswapV1Factory(_factoryV1);
        router = IUniswapV2Router01(_router);
    }

    /**
     * receive()
     *
     * 允许接收 ETH。
     *
     * 为什么需要？
     * - V1 removeLiquidity 会把 ETH 直接发送到调用者
     * - 本合约需要接收这些 ETH 再用于 V2 addLiquidity
     *
     * 注：
     * - Router 中会严格限制 ETH 来源
     * - 这里不能做同样限制，否则 gas 过高
     */
    receive() external payable {}

    /**
     * migrate
     *
     * 一键迁移函数：
     * 👉 把用户在 V1 的 LP 转为 V2 的 LP
     *
     * 参数：
     * - token：对应的 ERC20 token
     * - amountTokenMin：V2 添加流动性的最小 token 量（滑点保护）
     * - amountETHMin：V2 添加流动性的最小 ETH 量（滑点保护）
     * - to：V2 LP 接收地址
     * - deadline：交易截止时间（防止过期执行）
     *
     * 流程分解：
     *
     * ① 找到 V1 的 exchange
     * ② 取出用户全部 V1 LP
     * ③ 调用 V1 removeLiquidity
     *    👉 得到 ETH + Token
     * ④ 授权 Router 使用 Token
     * ⑤ 调用 V2 addLiquidityETH
     *    👉 mint 新 LP
     * ⑥ 多余资产退回用户
     */
    function migrate(
        address token,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    )
        external
        override
    {
        /// ① 获取 V1 exchange
        IUniswapV1Exchange exchangeV1 =
            IUniswapV1Exchange(factoryV1.getExchange(token));

        /// ② 用户在 V1 的 LP 数量
        uint liquidityV1 = exchangeV1.balanceOf(msg.sender);

        /// ③ 把 LP 转入本合约
        require(
            exchangeV1.transferFrom(
                msg.sender,
                address(this),
                liquidityV1
            ),
            'TRANSFER_FROM_FAILED'
        );

        /// ④ 从 V1 移除流动性
        /// 得到 ETH + Token
        (uint amountETHV1, uint amountTokenV1) =
            exchangeV1.removeLiquidity(
                liquidityV1,
                1,          // 最小 ETH（设 1 减少失败概率）
                1,          // 最小 Token
                uint(-1)    // deadline = 无穷大
            );

        /// ⑤ 授权 Router 使用 Token
        TransferHelper.safeApprove(
            token,
            address(router),
            amountTokenV1
        );

        /// ⑥ 在 V2 添加流动性
        (uint amountTokenV2, uint amountETHV2,) =
            router.addLiquidityETH{value: amountETHV1}(
                token,
                amountTokenV1,
                amountTokenMin,
                amountETHMin,
                to,
                deadline
            );

        /**
         * ⑦ 处理多余资产
         *
         * addLiquidity 可能不会用完全部：
         * - Token
         * - 或 ETH
         */

        /// 若 Token 有剩余 → 退回
        if (amountTokenV1 > amountTokenV2) {
            // 安全做法：先把 allowance 归零
            TransferHelper.safeApprove(token, address(router), 0);

            TransferHelper.safeTransfer(
                token,
                msg.sender,
                amountTokenV1 - amountTokenV2
            );

        /// 否则 ETH 有剩余 → 退回
        } else if (amountETHV1 > amountETHV2) {
            // addLiquidityETH 保证二者之一被完全使用
            TransferHelper.safeTransferETH(
                msg.sender,
                amountETHV1 - amountETHV2
            );
        }
    }
}
