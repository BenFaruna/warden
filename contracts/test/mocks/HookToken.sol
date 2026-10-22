// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface ITokenReceiver {
    function onTokensReceived() external;
}

/// @dev ERC-20 that calls back into contract recipients on transfer, like ERC-777 hooks.
///      Used to prove the vault resists token-callback reentrancy.
contract HookToken is ERC20 {
    constructor() ERC20("Hook Token", "HOOK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to.code.length > 0 && from != address(0)) {
            ITokenReceiver(to).onTokensReceived();
        }
    }
}
