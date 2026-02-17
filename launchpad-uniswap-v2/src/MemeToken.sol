// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol";
import "openzeppelin-contracts-upgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";

/**
 * @title MemeToken
 * @dev ERC20代币实现合约，作为最小代理(EIP-1167)的模板
 *
 * 关键改动：
 * 1) 在实现合约 constructor 中调用 _disableInitializers()
 *    - 防止任何人直接对 implementation 调用 initialize()
 *    - implementation 只作为“模板”，不能被当作真正的 token 使用
 */
contract MemeToken is Initializable, ERC20Upgradeable {
    string public constant FIXED_NAME = "Meme Token";

    uint256 public maxSupply;
    uint256 public perMint;
    uint256 public price;

    address public issuer;  // Meme发行者
    address public factory; // 工厂合约地址

    event Minted(address indexed to, uint256 amount);

    /// @dev 禁用实现合约本身的初始化，避免被外部直接 initialize
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev 初始化函数，替代构造函数（用于最小代理实例）
     */
    function initialize(
        string memory _symbol,
        uint256 _maxSupply,
        uint256 _perMint,
        uint256 _price,
        address _issuer,
        address _factory
    ) external initializer {
        require(_maxSupply > 0, "Invalid max supply");
        require(_perMint > 0 && _perMint <= _maxSupply, "Invalid per mint");

        __ERC20_init(FIXED_NAME, _symbol);

        maxSupply = _maxSupply;
        perMint = _perMint;
        price = _price;

        issuer = _issuer;
        factory = _factory;
    }

    /**
     * @dev 铸造代币，只能由工厂合约调用（用户每次购买 perMint 数量）
     */
    function mint(address to) external returns (uint256) {
        require(msg.sender == factory, "Only factory can mint");
        require(totalSupply() + perMint <= maxSupply, "Exceeds max supply");

        _mint(to, perMint);
        emit Minted(to, perMint);
        return perMint;
    }

    /**
     * @dev 为添加流动性铸造指定数量到 to，仅工厂可调用
     */
    function mintLiquidity(address to, uint256 amount) external returns (uint256) {
        require(msg.sender == factory, "Only factory can mint");
        require(amount > 0 && totalSupply() + amount <= maxSupply, "Exceeds max supply");

        _mint(to, amount);
        emit Minted(to, amount);
        return amount;
    }
}