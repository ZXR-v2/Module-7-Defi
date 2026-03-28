// SPDX-License-Identifier: MIT
pragma solidity =0.5.16;

/// @dev 无业务逻辑：让 Foundry 在任意 `forge test --match-*` 下都编译 UniswapV2Factory，
///      以便测试中 `deployCode("UniswapV2Factory.sol:UniswapV2Factory", ...)` 能解析到 artifact。
import "v2-core/UniswapV2Factory.sol";
