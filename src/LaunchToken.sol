// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Trickle (TRKL), the fixed-supply Sepolia launch token.
/// @dev The factory receives the entire supply; there are no privileged functions.
contract LaunchToken is ERC20 {
    constructor() ERC20("Trickle", "TRKL") {
        _mint(msg.sender, 1_000_000_000 * 10 ** 18);
    }
}
