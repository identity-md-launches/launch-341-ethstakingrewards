// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Exercise SafeERC20 rollback. Such a configurable token is not a supported launch token.
contract FailingToken is ERC20 {
    bool public fail;

    constructor() ERC20("Fixture", "FIX") {
        _mint(msg.sender, 1e27);
    }

    function setFail(bool value) external {
        fail = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (fail) return false;
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (fail) return false;
        return super.transferFrom(from, to, amount);
    }
}
