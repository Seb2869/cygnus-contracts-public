// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { IStToken } from "./interfaces/IStToken.sol";

contract WstToken is ERC20Permit {
    using SafeERC20 for IERC20;

    address public immutable stToken;

    constructor(address _stToken)
        ERC20Permit("Wrapped liquid stacked Token")
        ERC20("Wrapped Cygnus USD", "wcgUSD")
    {
        stToken = _stToken;
    }

    function decimals() public view override returns (uint8) {
        return IERC20Metadata(stToken).decimals();
    }

    function wrap(uint256 _amount) external returns (uint256) {
        require(_amount > 0, "wstToken: can't wrap zero stToken");
        uint256 wstTokenAmount = IStToken(stToken).previewDeposit(_amount);
        _mint(msg.sender, wstTokenAmount);
        IERC20(stToken).safeTransferFrom(msg.sender, address(this), _amount);
        return wstTokenAmount;
    }

    function unwrap(uint256 _amount) external returns (uint256) {
        require(_amount > 0, "wstToken: zero amount unwrap not allowed");
        uint256 stTokenAmount = IStToken(stToken).previewRedeem(_amount);
        _burn(msg.sender, _amount);
        IERC20(stToken).safeTransfer(msg.sender, stTokenAmount);
        return stTokenAmount;
    }
}