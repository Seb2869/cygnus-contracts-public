// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IPausable } from "./interfaces/IPausable.sol";

contract CgTimelockController is TimelockController {

    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    ) TimelockController(minDelay, proposers, executors, admin) {}

    function pause(address target) external onlyRoleOrOpenRole(EXECUTOR_ROLE) {
        IPausable(target).pause();
    }

}