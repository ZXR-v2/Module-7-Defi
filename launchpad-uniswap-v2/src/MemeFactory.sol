// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MemeToken.sol";

/// @notice 仅用于与 Uniswap V2 Router/Factory 交互的接口（避免直接 import 0.6 合约）
interface IUniswapV2Router02Like {
    function factory() external view returns (address);
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

/// @notice Uniswap V2 Factory 的 getPair 接口，用于查询 Token/WETH 交易对是否存在
interface IUniswapV2FactoryLike {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/**
 * @title MemeFactory
 * @dev 使用最小代理模式创建 Meme 代币的工厂合约；与 Uniswap V2 集成添加流动性并支持 buyMeme 从 DEX 购买。
 */
contract MemeFactory {
    address public immutable implementation;  // MemeToken 实现合约（EIP-1167 模板）
    address public immutable projectOwner;   // 项目方地址，收取 5% 费用及 LP
    address public immutable router;        // Uniswap V2 Router02，用于 addLiquidity / swap
    address public immutable weth;          // WETH 地址，Router 与 pair 使用

    /// @dev 项目方收费比例 5%
    uint256 public constant PROJECT_FEE_PERCENT = 5;
    /// @dev 用于添加流动性的 ETH 比例 5%（按 mint 价格折算对应 Token）
    uint256 public constant LIQUIDITY_PERCENT = 5;

    address[] public allMemes;
    mapping(address => bool) public isMeme;

    event MemeDeployed(
        address indexed memeToken,
        address indexed issuer,
        string symbol,
        uint256 maxSupply,
        uint256 perMint,
        uint256 price
    );

    event MemeMinted(
        address indexed memeToken,
        address indexed minter,
        uint256 amount,
        uint256 cost,
        uint256 projectFee,
        uint256 liquidityEth,
        uint256 issuerFee
    );

    event LiquidityAdded(
        address indexed memeToken,
        uint256 amountToken,
        uint256 amountETH,
        uint256 liquidity
    );

    event MemeBought(
        address indexed memeToken,
        address indexed buyer,
        uint256 ethIn,
        uint256 tokenOut
    );

    /// @param _router Uniswap V2 Router02 合约地址
    /// @param _weth   WETH 合约地址（与 Router 部署时使用的 WETH 一致）
    constructor(address _router, address _weth) {
        implementation = address(new MemeToken());
        projectOwner = msg.sender;
        router = _router;
        weth = _weth;
    }

    /**
     * @dev 部署新的 Meme 代币（EIP-1167 最小代理）
     * @param symbol     代币符号，如 "MEME"
     * @param totalSupply 总供应量（18 位小数）
     * @param perMint    每次 mint 数量（18 位小数）
     * @param price      每个整代币价格 wei（1 代币 = 1e18 最小单位）
     * @return memeToken 新部署的 Meme 代币地址
     */
    function deployMeme(
        string memory symbol,
        uint256 totalSupply,
        uint256 perMint,
        uint256 price
    ) external returns (address memeToken) {
        require(totalSupply > 0, "Invalid total supply");
        require(perMint > 0 && perMint <= totalSupply, "Invalid per mint");

        memeToken = _clone(implementation);
        MemeToken(memeToken).initialize(
            symbol,
            totalSupply,
            perMint,
            price,
            msg.sender,
            address(this)
        );

        allMemes.push(memeToken);
        isMeme[memeToken] = true;

        emit MemeDeployed(memeToken, msg.sender, symbol, totalSupply, perMint, price);
    }

    /**
     * @dev 铸造 Meme 代币：5% 项目费、5% 用于 Uniswap 流动性、90% 给发行方；首次加池按 mint 价格。
     * @param tokenAddr 已由本工厂 deploy 的 Meme 代币地址
     */
    function mintMeme(address tokenAddr) external payable {
        require(isMeme[tokenAddr], "Not a valid meme token");

        MemeToken meme = MemeToken(tokenAddr);
        uint256 perMint = meme.perMint();
        uint256 price = meme.price();

        // 总价 = 本次铸造数量 × 单价；price 为每 1e18 最小单位的 wei 价，故除以 1e18
        uint256 totalCost = (perMint * price) / 1e18;
        require(msg.value >= totalCost, "Insufficient payment");

        uint256 projectFee = (totalCost * PROJECT_FEE_PERCENT) / 100;
        uint256 liquidityEth = (totalCost * LIQUIDITY_PERCENT) / 100;
        uint256 issuerFee = totalCost - projectFee - liquidityEth;

        // 1. 先给用户铸造 perMint 数量
        uint256 minted = meme.mint(msg.sender);
        require(minted == perMint, "Mint failed");

        // 2. 用 5% ETH + 按起始价折算的 Token 添加 Uniswap 流动性（LP 发给 projectOwner）
        if (liquidityEth > 0) {
            _addLiquidityForMeme(tokenAddr, meme, liquidityEth, price);
        }

        // 3. 转 5% 给项目方
        if (projectFee > 0) {
            (bool ok,) = projectOwner.call{value: projectFee}("");
            require(ok, "Project fee transfer failed");
        }

        // 4. 转 90% 给该 Meme 的发行方
        if (issuerFee > 0) {
            (bool ok,) = meme.issuer().call{value: issuerFee}("");
            require(ok, "Issuer fee transfer failed");
        }

        // 多付的 ETH 原路退回
        if (msg.value > totalCost) {
            (bool ok,) = msg.sender.call{value: msg.value - totalCost}("");
            require(ok, "Refund failed");
        }

        emit MemeMinted(tokenAddr, msg.sender, minted, totalCost, projectFee, liquidityEth, issuerFee);
    }

    /**
     * @dev 通过 Uniswap 用 ETH 购买 Meme；要求 DEX 能给出的数量不低于起始价折算量的约 97%（留手续费与滑点容差）。
     * @param tokenAddr 已由本工厂 deploy 且已在 Uniswap 有 Token/WETH 池的 Meme 代币地址
     */
    function buyMeme(address tokenAddr) external payable {
        require(isMeme[tokenAddr], "Not a valid meme token");
        require(msg.value > 0, "Zero ETH");

        MemeToken meme = MemeToken(tokenAddr);
        address factory = IUniswapV2Router02Like(router).factory();
        address pair = IUniswapV2FactoryLike(factory).getPair(tokenAddr, weth);
        require(pair != address(0), "No pair");

        uint256 price = meme.price();
        // 按起始价至少应得 token 数量；97/100 为容差，避免 0.3% 手续费与滑点导致 revert
        uint256 amountOutMin = (msg.value * 1e18 * 97) / (price * 100);

        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = tokenAddr;

        uint256[] memory amounts =
            IUniswapV2Router02Like(router).swapExactETHForTokens{value: msg.value}(
                amountOutMin,
                path,
                msg.sender,
                block.timestamp
            );

        emit MemeBought(tokenAddr, msg.sender, msg.value, amounts[amounts.length - 1]);
    }

    /// @return 已部署的 Meme 代币数量
    function getMemeCount() external view returns (uint256) {
        return allMemes.length;
    }

    /// @param index 索引
    /// @return 该索引对应的 Meme 代币地址
    function getMeme(uint256 index) external view returns (address) {
        require(index < allMemes.length, "Index out of bounds");
        return allMemes[index];
    }

    /**
     * @dev 将 liquidityEth 与按起始价折算的 Token 通过 Router 添加进 Token/WETH 池，LP 发给 projectOwner
     * @param tokenAddr    Meme 代币地址
     * @param meme         Meme 代币合约引用
     * @param liquidityEth 用于加池的 ETH 数量（wei）
     * @param price        当前 Meme 起始价（wei per 1e18 最小单位）
     */
    function _addLiquidityForMeme(address tokenAddr, MemeToken meme, uint256 liquidityEth, uint256 price) private {
        // 按起始价：liquidityEth 可兑换的 token 数量（18 位小数）
        uint256 tokenAmount = (liquidityEth * 1e18) / price;
        uint256 remaining = meme.maxSupply() - meme.totalSupply();
        if (tokenAmount > remaining) tokenAmount = remaining;

        if (tokenAmount == 0) {
            (bool ok,) = projectOwner.call{value: liquidityEth}("");
            require(ok, "Liquidity eth transfer failed");
            return;
        }
        // 铸给本工厂，再由工厂授权 Router 并参与 addLiquidityETH
        meme.mintLiquidity(address(this), tokenAmount);
        meme.approve(router, tokenAmount);
        (uint256 amountToken, uint256 amountETH, uint256 liquidity) =
            IUniswapV2Router02Like(router).addLiquidityETH{value: liquidityEth}(
                tokenAddr, tokenAmount, 0, 0, projectOwner, block.timestamp
            );
        // Router 可能因比例舍入少用部分 token，剩余转给项目方
        if (amountToken < tokenAmount) {
            meme.transfer(projectOwner, tokenAmount - amountToken);
        }
        emit LiquidityAdded(tokenAddr, amountToken, amountETH, liquidity);
    }

    /// @dev EIP-1167 最小代理克隆
    /// @param _implementation 实现合约地址（MemeToken）
    /// @return instance 新克隆的代理地址
    function _clone(address _implementation) private returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, _implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create(0, ptr, 0x37)
        }
        require(instance != address(0), "Clone failed");
    }
}
