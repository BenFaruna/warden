// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Mimics USDT-style tokens whose transfer() returns NOTHING (no bool).
///      A naive `IERC20.transfer` call would revert decoding the empty return data;
///      SafeERC20 must handle it. Used to prove the vault works with such tokens.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        // intentionally no return value
    }
}
