// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.6;

import "./Ownable.sol";

/// @notice Precaution to prevent logic address storage collisions between GuniLev.sol
/// and GuniLevProxy.sol. All implementation contracts must inherit from this.
contract Proxiable is Ownable {
    address public levLogic;

    function setLevLogic(address _levLogic) internal onlyOwner() {
        levLogic = _levLogic;
    }
}